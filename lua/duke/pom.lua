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
  }
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
