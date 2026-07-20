local M = {}

local function strip_comments(xml)
  return (
    xml:gsub("<!%-%-(.-)%-%->", function(comment)
      local _, newlines = comment:gsub("\n", "\n")
      return string.rep("\n", newlines)
    end)
  )
end

local function mask_comments(xml)
  return (
    xml:gsub("<!%-%-(.-)%-%->", function(comment)
      return ("<!--" .. comment .. "-->"):gsub("[^\n]", " ")
    end)
  )
end

local function escape_pattern(value)
  return value:gsub("([^%w])", "%%%1")
end

local function tag_value(xml, tag)
  local escaped = escape_pattern(tag)
  return xml:match("<" .. escaped .. "%s*[^>]*>%s*([^<]-)%s*</" .. escaped .. "%s*>")
end

local function resolve_property(xml, value)
  local property = value and value:match("^%${([%w_.-]+)}$")
  if not property then
    return value
  end
  return tag_value(xml, property)
end

local function escape_xml(value)
  return tostring(value)
    :gsub("&", "&amp;")
    :gsub("<", "&lt;")
    :gsub(">", "&gt;")
    :gsub('"', "&quot;")
    :gsub("'", "&apos;")
end

function M.spring_boot_version(lines)
  local xml = strip_comments(table.concat(lines, "\n"))
  for parent in xml:gmatch("<parent[^>]*>(.-)</parent>") do
    if
      tag_value(parent, "groupId") == "org.springframework.boot"
      and tag_value(parent, "artifactId") == "spring-boot-starter-parent"
    then
      return resolve_property(xml, tag_value(parent, "version"))
    end
  end

  local management = xml:match("<dependencyManagement%s*[^>]*>(.-)</dependencyManagement%s*>")
  if management then
    for dependency in management:gmatch("<dependency%s*[^>]*>(.-)</dependency%s*>") do
      if
        tag_value(dependency, "groupId") == "org.springframework.boot"
        and tag_value(dependency, "artifactId") == "spring-boot-dependencies"
      then
        return resolve_property(xml, tag_value(dependency, "version"))
      end
    end
  end
end

local function structure(lines)
  local stack = {}
  local found = {}
  local xml = strip_comments(table.concat(lines, "\n"))
  local line_number = 1
  local previous_position = 1

  for position, closing, qualified_name, attributes in xml:gmatch("()<(%/?)([%w_:.-]+)([^>]*)>") do
    local _, newlines = xml:sub(previous_position, position - 1):gsub("\n", "\n")
    line_number = line_number + newlines
    previous_position = position

    local name = qualified_name:match("([^:]+)$")
    if closing == "/" then
      local parent = stack[#stack - 1]
      if name == "dependencies" and stack[#stack] == "dependencies" and parent == "project" then
        found.dependencies_close = line_number
      elseif name == "project" and stack[#stack] == "project" then
        found.project_close = line_number
      end
      if stack[#stack] == name then
        table.remove(stack)
      end
    elseif not attributes:match("/%s*$") then
      if name == "project" then
        found.project_open = line_number
      end
      if name == "dependencies" and stack[#stack] == "project" then
        found.dependencies_open = line_number
      end
      stack[#stack + 1] = name
    elseif name == "dependencies" and stack[#stack] == "project" then
      found.dependencies_self_closing = line_number
    end
  end

  return found
end

local function existing_coordinates(lines, first, last)
  local result = {}
  if not first or not last then
    return result
  end
  local full_xml = strip_comments(table.concat(lines, "\n"))
  local xml = strip_comments(table.concat(vim.list_slice(lines, first, last), "\n"))
  for dependency in xml:gmatch("<dependency%s*[^>]*>(.-)</dependency%s*>") do
    local group_id = resolve_property(full_xml, tag_value(dependency, "groupId"))
    local artifact_id = resolve_property(full_xml, tag_value(dependency, "artifactId"))
    local dependency_type = resolve_property(full_xml, tag_value(dependency, "type"))
    local classifier = resolve_property(full_xml, tag_value(dependency, "classifier"))
    if
      group_id
      and artifact_id
      and (not dependency_type or dependency_type == "jar")
      and (not classifier or classifier == "")
    then
      result[group_id .. ":" .. artifact_id] = true
    end
  end
  return result
end

local function dependency_lines(dependency, indent)
  local lines = {
    indent .. "<dependency>",
    indent .. "  <groupId>" .. escape_xml(dependency.group_id) .. "</groupId>",
    indent .. "  <artifactId>" .. escape_xml(dependency.artifact_id) .. "</artifactId>",
  }
  if dependency.version then
    lines[#lines + 1] = indent .. "  <version>" .. escape_xml(dependency.version) .. "</version>"
  end
  if dependency.scope and dependency.scope ~= "compile" then
    lines[#lines + 1] = indent .. "  <scope>" .. escape_xml(dependency.scope) .. "</scope>"
  end
  lines[#lines + 1] = indent .. "</dependency>"
  return lines
end

local function dependency_structure(lines)
  local positions = structure(lines)
  if not positions.project_close then
    return nil, "pom.xml has no closing project element"
  end
  if
    positions.project_open == positions.project_close
    or (positions.dependencies_open and positions.dependencies_open == positions.dependencies_close)
  then
    return nil, "compact one-line project/dependencies XML is not supported"
  end
  if positions.dependencies_self_closing then
    return nil, "self-closing root dependencies element is not supported"
  end

  local raw_xml = table.concat(lines, "\n")
  local xml = mask_comments(raw_xml)
  local full_xml = strip_comments(raw_xml)
  local stack = {}
  local dependencies = {}
  local root_dependencies_seen = false
  local line_number = 1
  local previous_position = 1

  for position, closing, qualified_name, attributes, finish in
    xml:gmatch("()<(%/?)([%w_:.-]+)([^>]*)>()")
  do
    local _, newlines = xml:sub(previous_position, position - 1):gsub("\n", "\n")
    line_number = line_number + newlines
    previous_position = position

    local name = qualified_name:match("([^:]+)$")
    if closing == "/" then
      local node = stack[#stack]
      if not node or node.name ~= name then
        return nil, "malformed pom.xml element nesting"
      end
      table.remove(stack)

      if node.field then
        local content = raw_xml:sub(node.content_start, position - 1)
        if mask_comments(content):find("<", 1, true) then
          return nil, "nested XML in dependency " .. node.field .. " is not supported"
        end
        local value = content:match("^%s*(.-)%s*$")
        if not value or value == "" then
          return nil, "empty dependency " .. node.field .. " is not supported"
        end
        if node.dependency[node.field] ~= nil then
          return nil, "duplicate dependency " .. node.field .. " is not supported"
        end
        node.dependency[node.field] = value
        if node.field == "version" then
          local leading = content:match("^(%s*)") or ""
          local trailing = content:match("(%s*)$") or ""
          node.dependency.version_line = node.start_line
          node.dependency._version_start = node.content_start + #leading
          node.dependency._version_end = position - 1 - #trailing
        end
      elseif node.kind == "dependency" then
        if node.start_line == line_number then
          return nil, "compact one-line dependency XML is not supported"
        end
        local line_start = raw_xml:sub(1, node.start_byte - 1):match(".*\n()") or 1
        local line_finish = raw_xml:find("\n", finish, true) or (#raw_xml + 1)
        if
          not raw_xml:sub(line_start, node.start_byte - 1):match("^%s*$")
          or not raw_xml:sub(finish, line_finish - 1):match("^%s*$")
        then
          return nil, "dependency blocks sharing lines with other XML are not supported"
        end
        if not node.group_id or not node.artifact_id then
          return nil, "root dependency is missing groupId or artifactId"
        end

        node.end_line = line_number
        node._end_byte = finish - 1
        node._block = raw_xml:sub(node._start_byte, node._end_byte)
        node._line_block = table.concat(vim.list_slice(lines, node.start_line, node.end_line), "\n")
        node.group_id = resolve_property(full_xml, node.group_id)
        node.artifact_id = resolve_property(full_xml, node.artifact_id)
        if not node.group_id or not node.artifact_id then
          return nil, "root dependency coordinate property cannot be resolved"
        end
        node.index = #dependencies + 1
        dependencies[#dependencies + 1] = node
      end
    else
      local parent = stack[#stack]
      local self_closing = attributes:match("/%s*$") ~= nil
      local kind
      if name == "project" and not parent then
        kind = "project"
      elseif name == "dependencies" and parent and parent.kind == "project" then
        if root_dependencies_seen then
          return nil, "multiple root dependencies elements are not supported"
        end
        root_dependencies_seen = true
        kind = "root_dependencies"
      elseif name == "dependency" and parent and parent.kind == "root_dependencies" then
        if self_closing then
          return nil, "self-closing root dependency element is not supported"
        end
        kind = "dependency"
      end

      if not self_closing then
        local node = {
          name = name,
          kind = kind,
          start_line = line_number,
          start_byte = position,
          content_start = finish,
        }
        if kind == "dependency" then
          node._start_byte = position
        elseif
          parent
          and parent.kind == "dependency"
          and (name == "groupId" or name == "artifactId" or name == "version")
        then
          node.field = name == "groupId" and "group_id"
            or (name == "artifactId" and "artifact_id" or "version")
          node.dependency = parent
        end
        stack[#stack + 1] = node
      elseif
        parent
        and parent.kind == "dependency"
        and (name == "groupId" or name == "artifactId" or name == "version")
      then
        return nil, "self-closing dependency " .. name .. " is not supported"
      end
    end
  end

  if #stack > 0 then
    return nil, "pom.xml has unclosed elements"
  end
  return dependencies
end

local function ownership_structure(lines)
  local raw_xml = table.concat(lines, "\n")
  local xml = mask_comments(raw_xml)
  local full_xml = strip_comments(raw_xml)
  local stack = {}
  local managed_dependencies = {}
  local profile_ranges = {}
  local line_number = 1
  local previous_position = 1

  for position, closing, qualified_name, attributes, finish in
    xml:gmatch("()<(%/?)([%w_:.-]+)([^>]*)>()")
  do
    local _, newlines = xml:sub(previous_position, position - 1):gsub("\n", "\n")
    line_number = line_number + newlines
    previous_position = position

    local name = qualified_name:match("([^:]+)$")
    if closing == "/" then
      local node = stack[#stack]
      if not node or node.name ~= name then
        return nil, nil, "malformed pom.xml element nesting"
      end
      table.remove(stack)

      if node.field then
        local content = raw_xml:sub(node.content_start, position - 1)
        if mask_comments(content):find("<", 1, true) then
          return nil, nil, "nested XML in managed dependency " .. node.field .. " is not supported"
        end
        local value = content:match("^%s*(.-)%s*$")
        if not value or value == "" then
          return nil, nil, "empty managed dependency " .. node.field .. " is not supported"
        end
        if node.target[node.field] ~= nil then
          return nil, nil, "duplicate managed dependency " .. node.field .. " is not supported"
        end
        node.target[node.field] = value
        if node.field == "version" then
          local leading = content:match("^(%s*)") or ""
          local trailing = content:match("(%s*)$") or ""
          node.target.version_line = node.start_line
          node.target._version_start = node.content_start + #leading
          node.target._version_end = position - 1 - #trailing
        end
      elseif node.kind == "managed_dependency" then
        if node.start_line == line_number then
          return nil, nil, "compact managed dependency XML is not supported"
        end
        if not node.group_id or not node.artifact_id then
          return nil, nil, "managed dependency is missing groupId or artifactId"
        end
        node.end_line = line_number
        node._end_byte = finish - 1
        node.group_id = resolve_property(full_xml, node.group_id)
        node.artifact_id = resolve_property(full_xml, node.artifact_id)
        if not node.group_id or not node.artifact_id then
          return nil, nil, "managed dependency coordinate property cannot be resolved"
        end
        node.kind = "dependency_management"
        node.coordinate = node.group_id .. ":" .. node.artifact_id
        node.managed = true
        node.imported_bom = node.type == "pom" and node.scope == "import"
        managed_dependencies[#managed_dependencies + 1] = node
      elseif node.kind == "profile" then
        profile_ranges[#profile_ranges + 1] = {
          id = node.id,
          start_line = node.start_line,
          end_line = line_number,
        }
      elseif node.kind == "profile_id" then
        local content = raw_xml:sub(node.content_start, position - 1)
        node.profile.id = content:match("^%s*(.-)%s*$")
      end
    else
      local parent = stack[#stack]
      local self_closing = attributes:match("/%s*$") ~= nil
      local kind
      if name == "project" and not parent then
        kind = "project"
      elseif name == "dependencyManagement" and parent and parent.kind == "project" then
        kind = "root_dependency_management"
      elseif name == "dependencies" and parent and parent.kind == "root_dependency_management" then
        kind = "managed_dependencies"
      elseif name == "dependency" and parent and parent.kind == "managed_dependencies" then
        kind = "managed_dependency"
      elseif name == "profiles" and parent and parent.kind == "project" then
        kind = "profiles"
      elseif name == "profile" and parent and parent.kind == "profiles" then
        kind = "profile"
      elseif name == "id" and parent and parent.kind == "profile" then
        kind = "profile_id"
      end

      if
        kind
        and self_closing
        and kind ~= "profiles"
        and kind ~= "profile"
        and kind ~= "profile_id"
      then
        return nil, nil, "self-closing " .. name .. " element is not supported"
      end
      if kind == "profile" and self_closing then
        profile_ranges[#profile_ranges + 1] = {
          start_line = line_number,
          end_line = line_number,
        }
      end
      if not self_closing then
        local node = {
          name = name,
          kind = kind,
          start_line = line_number,
          content_start = finish,
          _start_byte = position,
        }
        if
          parent
          and parent.kind == "managed_dependency"
          and (
            name == "groupId"
            or name == "artifactId"
            or name == "version"
            or name == "scope"
            or name == "type"
            or name == "classifier"
          )
        then
          node.field = name == "groupId" and "group_id"
            or (name == "artifactId" and "artifact_id" or name)
          node.target = parent
        elseif kind == "profile_id" then
          node.profile = parent
        end
        stack[#stack + 1] = node
      end
    end
  end

  if #stack > 0 then
    return nil, nil, "pom.xml has unclosed elements"
  end
  return managed_dependencies, profile_ranges
end

function M.list(lines)
  return dependency_structure(lines)
end

function M.update_version(lines, dependency, new_version)
  local updated = vim.deepcopy(lines)
  local property = dependency.version and dependency.version:match("^%${([%w_.-]+)}$")
  if property then
    return updated, "dependency version uses property " .. property
  end
  if not dependency.version or not dependency._version_start or not dependency._version_end then
    return updated, "dependency has no explicit version element"
  end
  if type(new_version) ~= "string" or new_version == "" then
    return updated, "new dependency version must be a non-empty string"
  end

  local xml = table.concat(updated, "\n")
  if xml:sub(dependency._start_byte, dependency._end_byte) ~= dependency._block then
    return updated, "dependency block changed; run command again"
  end
  local replaced = xml:sub(1, dependency._version_start - 1)
    .. escape_xml(new_version)
    .. xml:sub(dependency._version_end + 1)
  return vim.split(replaced, "\n", { plain = true })
end

function M.remove(lines, dependencies)
  local updated = vim.deepcopy(lines)
  local ranges = {}
  local seen = {}

  for _, dependency in ipairs(dependencies) do
    if
      type(dependency.start_line) ~= "number"
      or type(dependency.end_line) ~= "number"
      or not dependency._line_block
    then
      return updated, 0, "invalid dependency position"
    end
    if seen[dependency.start_line] then
      return updated, 0, "dependency selected more than once"
    end
    seen[dependency.start_line] = true
    if
      table.concat(vim.list_slice(lines, dependency.start_line, dependency.end_line), "\n")
      ~= dependency._line_block
    then
      return updated, 0, "dependency block changed; run command again"
    end
    ranges[#ranges + 1] = { first = dependency.start_line, last = dependency.end_line }
  end

  table.sort(ranges, function(left, right)
    return left.first > right.first
  end)
  for _, range in ipairs(ranges) do
    for _ = range.first, range.last do
      table.remove(updated, range.first)
    end
  end
  return updated, #ranges
end

function M.insert(lines, dependencies)
  local updated = vim.deepcopy(lines)
  local positions = structure(updated)
  if not positions.project_close then
    return updated, 0, "pom.xml has no closing project element"
  end
  if
    positions.project_open == positions.project_close
    or (positions.dependencies_open and positions.dependencies_open == positions.dependencies_close)
  then
    return updated, 0, "compact one-line project/dependencies XML is not supported"
  end
  if positions.dependencies_self_closing then
    return updated, 0, "self-closing root dependencies element is not supported"
  end

  local existing =
    existing_coordinates(updated, positions.dependencies_open, positions.dependencies_close)
  local additions = {}
  local added = 0
  local close_line = positions.dependencies_close or positions.project_close
  local close_indent = updated[close_line]:match("^%s*") or ""
  local block_indent = positions.dependencies_close and close_indent or (close_indent .. "  ")
  local dependency_indent = block_indent .. "  "

  if not positions.dependencies_close then
    additions[#additions + 1] = block_indent .. "<dependencies>"
  end

  for _, dependency in ipairs(dependencies) do
    local coordinate = dependency.group_id .. ":" .. dependency.artifact_id
    if not existing[coordinate] then
      vim.list_extend(additions, dependency_lines(dependency, dependency_indent))
      existing[coordinate] = true
      added = added + 1
    end
  end

  if not positions.dependencies_close then
    additions[#additions + 1] = block_indent .. "</dependencies>"
  end
  if added == 0 then
    return updated, 0
  end

  for offset, line in ipairs(additions) do
    table.insert(updated, close_line + offset - 1, line)
  end
  return updated, added
end

local function is_property(value)
  return type(value) == "string" and value:match("^%${[^}]+}$") ~= nil
end

local function parent_structure(lines)
  local positions = structure(lines)
  if not positions.project_close then
    return nil, "pom.xml has no closing project element"
  end
  if positions.project_open == positions.project_close then
    return nil, "compact one-line project XML is not supported"
  end

  local raw_xml = table.concat(lines, "\n")
  local xml = mask_comments(raw_xml)
  local stack = {}
  local parent
  local line_number = 1
  local previous_position = 1

  for position, closing, qualified_name, attributes, finish in
    xml:gmatch("()<(%/?)([%w_:.-]+)([^>]*)>()")
  do
    local _, newlines = xml:sub(previous_position, position - 1):gsub("\n", "\n")
    line_number = line_number + newlines
    previous_position = position

    local name = qualified_name:match("([^:]+)$")
    if closing == "/" then
      local node = stack[#stack]
      if not node or node.name ~= name then
        return nil, "malformed pom.xml element nesting"
      end
      table.remove(stack)

      if node.field then
        local content = raw_xml:sub(node.content_start, position - 1)
        if mask_comments(content):find("<", 1, true) then
          return nil, "nested XML in parent " .. node.field .. " is not supported"
        end
        local value = content:match("^%s*(.-)%s*$")
        if not value or value == "" then
          return nil, "empty parent " .. node.field .. " is not supported"
        end
        if node.target[node.field] ~= nil then
          return nil, "duplicate parent " .. node.field .. " is not supported"
        end
        node.target[node.field] = value
        if node.field == "version" then
          local leading = content:match("^(%s*)") or ""
          local trailing = content:match("(%s*)$") or ""
          node.target._version_start = node.content_start + #leading
          node.target._version_end = position - 1 - #trailing
        end
      elseif node.kind == "parent" then
        if node.start_line == line_number then
          return nil, "compact one-line parent XML is not supported"
        end
        node.end_line = line_number
        node._end_byte = finish - 1
        node._block = raw_xml:sub(node._start_byte, node._end_byte)
        parent = node
      end
    else
      local owner = stack[#stack]
      local self_closing = attributes:match("/%s*$") ~= nil
      local kind
      if name == "project" and not owner then
        kind = "project"
      elseif name == "parent" and owner and owner.kind == "project" then
        if self_closing then
          return nil, "self-closing parent element is not supported"
        end
        kind = "parent"
      end

      if not self_closing then
        local node = {
          name = name,
          kind = kind,
          start_line = line_number,
          start_byte = position,
          content_start = finish,
        }
        if kind == "parent" then
          node._start_byte = position
        elseif
          owner
          and owner.kind == "parent"
          and (name == "groupId" or name == "artifactId" or name == "version")
        then
          node.field = name == "groupId" and "group_id"
            or (name == "artifactId" and "artifact_id" or "version")
          node.target = owner
        end
        stack[#stack + 1] = node
      elseif
        owner
        and owner.kind == "parent"
        and (name == "groupId" or name == "artifactId" or name == "version")
      then
        return nil, "self-closing parent " .. name .. " is not supported"
      end
    end
  end

  if #stack > 0 then
    return nil, "pom.xml has unclosed elements"
  end

  return parent
end

function M.parent(lines)
  local node, err = parent_structure(lines)
  if err then
    return nil, err
  end
  if not node then
    return nil, "pom.xml has no <parent> element"
  end
  if
    node.group_id ~= "org.springframework.boot"
    or node.artifact_id ~= "spring-boot-starter-parent"
  then
    return nil, "pom.xml parent is not the Spring Boot starter parent"
  end
  return node
end

local function reactor_structure(lines)
  local positions = structure(lines)
  if not positions.project_close then
    return nil, "pom.xml has no closing project element"
  end
  if positions.project_open == positions.project_close then
    return nil, "compact one-line project XML is not supported"
  end

  local raw_xml = table.concat(lines, "\n")
  local xml = mask_comments(raw_xml)
  local stack = {}
  local project = {}
  local parent = {}
  local line_number = 1
  local previous_position = 1

  for position, closing, qualified_name, attributes, finish in
    xml:gmatch("()<(%/?)([%w_:.-]+)([^>]*)>()")
  do
    local _, newlines = xml:sub(previous_position, position - 1):gsub("\n", "\n")
    line_number = line_number + newlines
    previous_position = position

    local name = qualified_name:match("([^:]+)$")
    if closing == "/" then
      local node = stack[#stack]
      if not node or node.name ~= name then
        return nil, "malformed pom.xml element nesting"
      end
      table.remove(stack)

      if node.field and node.target then
        local content = raw_xml:sub(node.content_start, position - 1)
        if mask_comments(content):find("<", 1, true) then
          return nil, "nested XML in reactor " .. node.field .. " is not supported"
        end
        local value = content:match("^%s*(.-)%s*$")
        if not value or value == "" then
          return nil, "empty reactor " .. node.field .. " is not supported"
        end
        if node.target[node.field] ~= nil then
          return nil, "duplicate reactor " .. node.field .. " is not supported"
        end
        node.target[node.field] = value
      end
    else
      local owner = stack[#stack]
      local self_closing = attributes:match("/%s*$") ~= nil
      local kind
      if name == "project" and not owner then
        kind = "project"
      elseif name == "parent" and owner and owner.kind == "project" then
        kind = "parent"
      end

      if not self_closing then
        local node = {
          name = name,
          kind = kind,
          content_start = finish,
        }
        if
          owner
          and owner.kind == "project"
          and (
            name == "groupId"
            or name == "artifactId"
            or name == "version"
            or name == "packaging"
          )
        then
          node.field = name == "groupId" and "group_id"
            or (name == "artifactId" and "artifact_id" or name)
          node.target = project
        elseif
          owner
          and owner.kind == "parent"
          and (name == "groupId" or name == "artifactId" or name == "version")
        then
          node.field = name == "groupId" and "group_id"
            or (name == "artifactId" and "artifact_id" or "version")
          node.target = parent
        end
        stack[#stack + 1] = node
      elseif
        owner
        and (
          (
            owner.kind == "project"
            and (
              name == "groupId"
              or name == "artifactId"
              or name == "version"
              or name == "packaging"
            )
          )
          or (
            owner.kind == "parent"
            and (name == "groupId" or name == "artifactId" or name == "version")
          )
        )
      then
        return nil, "self-closing reactor " .. name .. " is not supported"
      end
    end
  end

  if #stack > 0 then
    return nil, "pom.xml has unclosed elements"
  end

  return {
    project = project,
    parent = parent,
  }
end

function M.reactor(lines)
  local fields, err = reactor_structure(lines)
  if not fields then
    return nil, err
  end

  local project = fields.project
  local parent = fields.parent

  if not project.artifact_id then
    return nil, "reactor artifactId is missing"
  end
  if is_property(project.artifact_id) then
    return nil, "reactor artifactId property is not supported"
  end

  local group_id = project.group_id or parent.group_id
  local version = project.version or parent.version
  if not group_id then
    return nil, "reactor groupId is missing"
  end
  if not version then
    return nil, "reactor version is missing"
  end
  if is_property(group_id) or is_property(project.group_id) or is_property(parent.group_id) then
    return nil, "reactor groupId property is not supported"
  end
  if is_property(version) or is_property(project.version) or is_property(parent.version) then
    return nil, "reactor version property is not supported"
  end

  if not project.packaging then
    return nil, "reactor packaging is missing (jar default is not eligible)"
  end
  if is_property(project.packaging) then
    return nil, "reactor packaging property is not supported"
  end
  if project.packaging ~= "pom" then
    return nil, "reactor packaging must be pom"
  end

  return {
    group_id = group_id,
    artifact_id = project.artifact_id,
    version = version,
    packaging = project.packaging,
  }
end

local function modules_structure(lines)
  local positions = structure(lines)
  if not positions.project_close then
    return nil, "pom.xml has no closing project element"
  end
  if positions.project_open == positions.project_close then
    return nil, "compact one-line project/modules XML is not supported"
  end

  local raw_xml = table.concat(lines, "\n")
  local xml = mask_comments(raw_xml)
  local stack = {}
  local modules = {}
  local module_entries = {}
  local root_modules
  local root_modules_seen = false
  local line_number = 1
  local previous_position = 1

  for position, closing, qualified_name, attributes, finish in
    xml:gmatch("()<(%/?)([%w_:.-]+)([^>]*)>()")
  do
    local _, newlines = xml:sub(previous_position, position - 1):gsub("\n", "\n")
    line_number = line_number + newlines
    previous_position = position

    local name = qualified_name:match("([^:]+)$")
    if closing == "/" then
      local node = stack[#stack]
      if not node or node.name ~= name then
        return nil, "malformed pom.xml element nesting"
      end
      table.remove(stack)

      if node.kind == "module" then
        local content = raw_xml:sub(node.content_start, position - 1)
        if mask_comments(content):find("<", 1, true) then
          return nil, "nested XML in module element is not supported"
        end
        local value = content:match("^%s*(.-)%s*$")
        if not value or value == "" then
          return nil, "empty module element is not supported"
        end
        local parent = stack[#stack]
        if parent and parent.kind == "root_modules" and parent.start_line == line_number then
          return nil, "compact one-line project/modules XML is not supported"
        end
        local line_start = raw_xml:sub(1, node.start_byte - 1):match(".*\n()") or 1
        local line_finish = raw_xml:find("\n", finish, true) or (#raw_xml + 1)
        if
          not raw_xml:sub(line_start, node.start_byte - 1):match("^%s*$")
          or not raw_xml:sub(finish, line_finish - 1):match("^%s*$")
        then
          return nil, "module elements sharing lines with other XML are not supported"
        end
        modules[#modules + 1] = value
        module_entries[#module_entries + 1] = {
          path = value,
          line = node.start_line,
        }
      elseif node.kind == "root_modules" then
        if node.start_line == line_number then
          return nil, "compact one-line project/modules XML is not supported"
        end
        node.close_line = line_number
        root_modules = node
      end
    else
      local owner = stack[#stack]
      local self_closing = attributes:match("/%s*$") ~= nil
      local kind
      if name == "project" and not owner then
        kind = "project"
      elseif name == "modules" and owner and owner.kind == "project" then
        if root_modules_seen then
          return nil, "multiple root modules elements are not supported"
        end
        root_modules_seen = true
        if self_closing then
          return nil, "self-closing root modules element is not supported"
        end
        kind = "root_modules"
      elseif name == "module" and owner and owner.kind == "root_modules" then
        if self_closing then
          return nil, "self-closing module element is not supported"
        end
        kind = "module"
      end

      if not self_closing then
        stack[#stack + 1] = {
          name = name,
          kind = kind,
          start_line = line_number,
          start_byte = position,
          content_start = finish,
        }
      end
    end
  end

  if #stack > 0 then
    return nil, "pom.xml has unclosed elements"
  end

  return {
    project_close = positions.project_close,
    root_modules = root_modules,
    modules = modules,
    module_entries = module_entries,
  }
end

local function property_structure(lines)
  local positions = structure(lines)
  if not positions.project_close then
    return nil, "pom.xml has no closing project element"
  end
  if positions.project_open == positions.project_close then
    return nil, "compact one-line project/properties XML is not supported"
  end

  local raw_xml = table.concat(lines, "\n")
  local xml = mask_comments(raw_xml)
  local stack = {}
  local properties = {}
  local root_properties_seen = false
  local line_number = 1
  local previous_position = 1

  for position, closing, qualified_name, attributes, finish in
    xml:gmatch("()<(%/?)([%w_:.-]+)([^>]*)>()")
  do
    local _, newlines = xml:sub(previous_position, position - 1):gsub("\n", "\n")
    line_number = line_number + newlines
    previous_position = position

    local name = qualified_name:match("([^:]+)$")
    if closing == "/" then
      local node = stack[#stack]
      if not node or node.name ~= name then
        return nil, "malformed pom.xml element nesting"
      end
      table.remove(stack)

      if node.kind == "property" then
        local content = raw_xml:sub(node.content_start, position - 1)
        if mask_comments(content):find("<", 1, true) then
          return nil, "nested XML in project property " .. node.name .. " is not supported"
        end
        local value = content:match("^%s*(.-)%s*$")
        if not value or value == "" then
          return nil, "empty project property " .. node.name .. " is not supported"
        end
        if properties[node.name] then
          return nil, "duplicate project property " .. node.name .. " is not supported"
        end
        local line_start = raw_xml:sub(1, node._start_byte - 1):match(".*\n()") or 1
        local line_finish = raw_xml:find("\n", finish, true) or (#raw_xml + 1)
        if
          not raw_xml:sub(line_start, node._start_byte - 1):match("^%s*$")
          or not raw_xml:sub(finish, line_finish - 1):match("^%s*$")
        then
          return nil, "project properties sharing lines with other XML are not supported"
        end

        local leading = content:match("^(%s*)") or ""
        local trailing = content:match("(%s*)$") or ""
        node.kind = "property"
        node.value = value
        node.line = node.start_line
        node._value_start = node.content_start + #leading
        node._value_end = position - 1 - #trailing
        node._end_byte = finish - 1
        node._block = raw_xml:sub(node._start_byte, node._end_byte)
        node.consumers = {}
        node.consumer_refs = {}
        properties[node.name] = node
      end
    else
      local owner = stack[#stack]
      local self_closing = attributes:match("/%s*$") ~= nil
      local kind
      if name == "project" and not owner then
        kind = "project"
      elseif name == "properties" and owner and owner.kind == "project" then
        if root_properties_seen then
          return nil, "multiple root properties elements are not supported"
        end
        root_properties_seen = true
        if self_closing then
          return nil, "self-closing root properties element is not supported"
        end
        kind = "root_properties"
      elseif owner and owner.kind == "root_properties" then
        if self_closing then
          return nil, "self-closing project property " .. name .. " is not supported"
        end
        kind = "property"
      end

      if not self_closing then
        stack[#stack + 1] = {
          name = name,
          kind = kind,
          start_line = line_number,
          content_start = finish,
          _start_byte = position,
        }
      end
    end
  end

  if #stack > 0 then
    return nil, "pom.xml has unclosed elements"
  end
  return properties
end

local function annotate_property_uses(lines, properties, dependencies)
  local xml = mask_comments(table.concat(lines, "\n"))
  for name, property in pairs(properties) do
    property.other_consumers = {}
    local reference = "${" .. name .. "}"
    local offset = 1
    while true do
      local first, last = xml:find(reference, offset, true)
      if not first then
        break
      end
      local known = false
      for _, dependency in ipairs(dependencies) do
        if
          dependency.version == reference
          and dependency._version_start
          and first >= dependency._version_start
          and last <= dependency._version_end
        then
          known = true
          break
        end
      end
      if not known then
        local _, newlines = xml:sub(1, first - 1):gsub("\n", "\n")
        property.other_consumers[#property.other_consumers + 1] = {
          kind = "other",
          line = newlines + 1,
        }
      end
      offset = last + 1
    end
  end
end

function M.dependency_version_sources(lines, dependencies)
  local properties, properties_err = property_structure(lines)
  if not properties then
    return nil, properties_err
  end
  for _, dependency in ipairs(dependencies) do
    local property_name = dependency.version and dependency.version:match("^%${([%w_.-]+)}$")
    local property = property_name and properties[property_name] or nil
    if property then
      property.consumers[#property.consumers + 1] = dependency.group_id
        .. ":"
        .. dependency.artifact_id
    end
  end
  for _, property in pairs(properties) do
    table.sort(property.consumers)
  end
  annotate_property_uses(lines, properties, dependencies)

  local sources = {}
  for _, dependency in ipairs(dependencies) do
    if dependency.version then
      local property_name = dependency.version:match("^%${([%w_.-]+)}$")
      local property = property_name and properties[property_name] or nil
      if property and not property.value:find("${", 1, true) then
        sources[dependency] = {
          kind = "property",
          property = property_name,
          version = property.value,
          consumers = vim.deepcopy(property.consumers),
          other_consumers = vim.deepcopy(property.other_consumers),
        }
      elseif not property_name then
        sources[dependency] = { kind = "dependency", version = dependency.version }
      end
    end
  end
  return sources
end

function M.model(lines, opts)
  opts = opts or {}
  local fields, fields_err = reactor_structure(lines)
  if not fields then
    return nil, fields_err
  end
  local dependencies, dependencies_err = dependency_structure(lines)
  if not dependencies then
    return nil, dependencies_err
  end
  local modules = { module_entries = {} }
  local properties = {}
  if not opts.effective then
    local modules_err
    modules, modules_err = modules_structure(lines)
    if not modules then
      return nil, modules_err
    end
    local properties_err
    properties, properties_err = property_structure(lines)
    if not properties then
      return nil, properties_err
    end
  end
  local managed_dependencies, profile_ranges, ownership_err = ownership_structure(lines)
  if not managed_dependencies then
    return nil, ownership_err
  end

  local project = fields.project
  local parent = fields.parent
  local group_id = project.group_id or parent.group_id
  local version = project.version or parent.version
  if not project.artifact_id then
    return nil, "project artifactId is missing"
  end
  if not group_id then
    return nil, "project groupId is missing"
  end
  if not version then
    return nil, "project version is missing"
  end
  if
    is_property(project.artifact_id)
    or is_property(group_id)
    or is_property(project.group_id)
    or is_property(parent.group_id)
    or is_property(version)
    or is_property(project.version)
    or is_property(parent.version)
  then
    return nil, "property-backed project coordinates are not supported"
  end
  local packaging = project.packaging or "jar"
  if is_property(packaging) then
    return nil, "property-backed project packaging is not supported"
  end

  local versioned_declarations = {}
  vim.list_extend(versioned_declarations, dependencies)
  vim.list_extend(versioned_declarations, managed_dependencies)
  for _, dependency in ipairs(versioned_declarations) do
    dependency.kind = "dependency"
    if dependency.managed then
      dependency.kind = "dependency_management"
    end
    dependency.coordinate = dependency.group_id .. ":" .. dependency.artifact_id
    local property_name = dependency.version and dependency.version:match("^%${([%w_.-]+)}$")
    if property_name and properties[property_name] then
      local property = properties[property_name]
      local consumers = property.consumers
      consumers[#consumers + 1] = dependency.coordinate
      property.consumer_refs[#property.consumer_refs + 1] = {
        kind = "dependency",
        coordinate = dependency.coordinate,
        line = dependency.start_line,
      }
    end
  end
  for _, property in pairs(properties) do
    table.sort(property.consumers)
  end
  annotate_property_uses(lines, properties, versioned_declarations)

  return {
    coordinates = {
      group_id = group_id,
      artifact_id = project.artifact_id,
      version = version,
    },
    packaging = packaging,
    modules = modules.module_entries,
    dependencies = dependencies,
    dependency_management = managed_dependencies,
    properties = properties,
    profile_ranges = profile_ranges,
    spring_boot_version = M.spring_boot_version(lines),
  }
end

function M.update_versions(lines, changes)
  local updated = vim.deepcopy(lines)
  if type(changes) ~= "table" or #changes == 0 then
    return updated, "version changes must be a non-empty list"
  end

  local xml = table.concat(lines, "\n")
  local replacements = {}
  local seen = {}
  for _, change in ipairs(changes) do
    local target = change.target
    if type(target) ~= "table" then
      return updated, "version change target is invalid"
    end
    if type(change.new_version) ~= "string" or change.new_version == "" then
      return updated, "new dependency version must be a non-empty string"
    end

    local first
    local last
    if target.kind == "property" then
      first = target._value_start
      last = target._value_end
    elseif target.kind == "dependency" then
      if target.version and target.version:match("^%${([%w_.-]+)}$") then
        return updated, "dependency version uses a property; update the property target"
      end
      first = target._version_start
      last = target._version_end
    else
      return updated, "version change target kind is invalid"
    end
    if
      not first
      or not last
      or not target._start_byte
      or not target._end_byte
      or not target._block
    then
      return updated, "version change target has no editable value"
    end
    if seen[first] then
      return updated, "duplicate version change target"
    end
    seen[first] = true
    if xml:sub(target._start_byte, target._end_byte) ~= target._block then
      return updated, "version change target changed; run command again"
    end
    replacements[#replacements + 1] = {
      first = first,
      last = last,
      value = escape_xml(change.new_version),
    }
  end

  table.sort(replacements, function(left, right)
    return left.first > right.first
  end)
  for index = 2, #replacements do
    if replacements[index].last >= replacements[index - 1].first then
      return updated, "overlapping version change targets"
    end
  end
  for _, replacement in ipairs(replacements) do
    xml = xml:sub(1, replacement.first - 1) .. replacement.value .. xml:sub(replacement.last + 1)
  end
  return vim.split(xml, "\n", { plain = true })
end

function M.insert_module(lines, module_name)
  local updated = vim.deepcopy(lines)
  if type(module_name) ~= "string" or module_name == "" then
    return updated, 0, "module name must be a non-empty string"
  end

  local info, err = modules_structure(updated)
  if not info then
    return updated, 0, err
  end

  for _, existing in ipairs(info.modules) do
    if existing == module_name then
      return updated, 0
    end
  end

  local escaped = escape_xml(module_name)
  local additions = {}
  local close_line
  if info.root_modules then
    close_line = info.root_modules.close_line
    local close_indent = updated[close_line]:match("^%s*") or ""
    additions[1] = close_indent .. "  <module>" .. escaped .. "</module>"
  else
    close_line = info.project_close
    local close_indent = updated[close_line]:match("^%s*") or ""
    local block_indent = close_indent .. "  "
    additions = {
      block_indent .. "<modules>",
      block_indent .. "  <module>" .. escaped .. "</module>",
      block_indent .. "</modules>",
    }
  end

  for offset, line in ipairs(additions) do
    table.insert(updated, close_line + offset - 1, line)
  end
  return updated, 1
end

return M
