local pom = require("duke.pom")

local M = {}

local function escape_pattern(value)
  return (value:gsub("([^%w])", "%%%1"))
end

local function split_coordinate(coordinate)
  if type(coordinate) ~= "string" then
    return nil
  end
  local group_id, artifact_id = coordinate:match("^([^:]+):([^:]+)$")
  if
    not group_id
    or not artifact_id
    or not group_id:match("^[%w_.-]+$")
    or not artifact_id:match("^[%w_.-]+$")
  then
    return nil
  end
  return group_id, artifact_id
end

local function replacement(line, tag, expected, value)
  local escaped = escape_pattern(tag)
  local prefix, current, suffix =
    line:match("^(%s*<" .. escaped .. ">)(.-)(</" .. escaped .. ">%s*)$")
  if not prefix or current ~= expected then
    return nil, "repair target is stale or shares a line with other XML"
  end
  return prefix .. value .. suffix
end

local function declaration_matches(declarations, coordinate)
  local matches = {}
  for _, declaration in ipairs(declarations or {}) do
    if declaration.coordinate == coordinate then
      matches[#matches + 1] = declaration
    end
  end
  return matches
end

local function find_upgrade(model, target)
  if target.writable == false then
    return nil, nil, "repair owner is not writable"
  end
  if target.kind == "profile" or target.kind == "external_parent" or target.kind == "unknown" then
    return nil, nil, "repair owner is not writable"
  end
  if target.property then
    local property = model.properties[target.property]
    if not property then
      return nil, nil, "repair property is missing"
    end
    if property.value:find("${", 1, true) then
      return nil, nil, "chained properties are not supported"
    end
    if #(property.other_consumers or {}) > 0 or #(target.other_consumers or {}) > 0 then
      return nil, nil, "property has other consumers"
    end
    return property.line, property.value, nil, target.property
  end

  local coordinate = target.owner_coordinate or target.coordinate
  local declarations = target.kind == "dependency" and model.dependencies
    or model.dependency_management
  local matches = declaration_matches(declarations, coordinate)
  if #matches ~= 1 then
    return nil, nil, "repair owner has multiple direct dependencies or is missing"
  end
  local declaration = matches[1]
  if not declaration.version or not declaration.version_line then
    return nil, nil, "repair owner has no explicit version"
  end
  return declaration.version_line, declaration.version, nil, "version"
end

local function exclusion_exists(lines, dependency, excluded_coordinate)
  local group_id, artifact_id = split_coordinate(excluded_coordinate)
  if not group_id then
    return false
  end
  local block =
    table.concat(vim.list_slice(lines, dependency.start_line, dependency.end_line), "\n")
  local pattern = "<exclusion>%s*<groupId>%s*"
    .. escape_pattern(group_id)
    .. "%s*</groupId>%s*<artifactId>%s*"
    .. escape_pattern(artifact_id)
    .. "%s*</artifactId>%s*</exclusion>"
  return block:find(pattern) ~= nil
end

local function exclusion_insertion(lines, dependency, coordinates)
  local open_line
  local close_line
  for line = dependency.start_line + 1, dependency.end_line - 1 do
    local value = lines[line]
    if value:match("^%s*<exclusions>%s*$") then
      if open_line then
        return nil, nil, "multiple exclusions blocks are not supported"
      end
      open_line = line
    elseif value:match("^%s*</exclusions>%s*$") then
      close_line = line
    elseif value:match("^%s*<exclusions%s*/>%s*$") then
      return nil, nil, "self-closing exclusions XML is not supported"
    end
  end
  if
    (open_line and not close_line)
    or (close_line and not open_line)
    or (open_line and close_line <= open_line)
  then
    return nil, nil, "malformed exclusions XML"
  end

  local insertion_line = close_line or dependency.end_line
  local base_indent = (lines[insertion_line]:match("^(%s*)") or "")
  local result = {}
  if not close_line then
    result[#result + 1] = base_indent .. "  <exclusions>"
    base_indent = base_indent .. "  "
  end
  for _, coordinate in ipairs(coordinates) do
    local group_id, artifact_id = split_coordinate(coordinate)
    if not group_id then
      return nil, nil, "invalid excluded coordinate"
    end
    result[#result + 1] = base_indent .. "  <exclusion>"
    result[#result + 1] = base_indent .. "    <groupId>" .. group_id .. "</groupId>"
    result[#result + 1] = base_indent .. "    <artifactId>" .. artifact_id .. "</artifactId>"
    result[#result + 1] = base_indent .. "  </exclusion>"
  end
  if not close_line then
    result[#result + 1] = base_indent:sub(1, -3) .. "  </exclusions>"
  end
  return insertion_line, result
end

function M.apply(lines, repairs)
  if type(lines) ~= "table" or type(repairs) ~= "table" or #repairs == 0 then
    return nil, nil, "repairs must be a non-empty list"
  end
  local model, model_err = pom.model(lines)
  if not model then
    return nil, nil, model_err
  end

  local replacements = {}
  local exclusions = {}
  local identities = {}
  local changes = {}
  for _, item in ipairs(repairs) do
    if item.kind == "upgrade" then
      local target = item.target or {}
      local identity = "upgrade:"
        .. tostring(target.property or target.owner_coordinate or target.coordinate)
      if identities[identity] then
        return nil, nil, "repair targets overlap"
      end
      identities[identity] = true
      if
        type(item.new_version) ~= "string"
        or item.new_version == ""
        or item.new_version:find("%s")
        or item.new_version:find("[<>&]")
      then
        return nil, nil, "new version must be a non-empty token"
      end
      local line, before, err, tag = find_upgrade(model, target)
      if not line then
        return nil, nil, err
      end
      if target.requested_version and target.requested_version ~= before then
        return nil, nil, "repair target version is stale"
      end
      if before ~= item.new_version then
        if replacements[line] then
          return nil, nil, "repair targets overlap"
        end
        local after, replace_err = replacement(lines[line], tag, before, item.new_version)
        if not after then
          return nil, nil, replace_err
        end
        replacements[line] = after
        changes[#changes + 1] = {
          kind = "upgrade",
          coordinate = target.owner_coordinate or target.coordinate,
          property = target.property,
          before = before,
          after = item.new_version,
        }
      end
    elseif item.kind == "exclude" then
      local identity = "exclude:"
        .. tostring(item.direct_coordinate)
        .. ":"
        .. tostring(item.excluded_coordinate)
      if identities[identity] then
        return nil, nil, "repair targets overlap"
      end
      identities[identity] = true
      local matches = declaration_matches(model.dependencies, item.direct_coordinate)
      if #matches ~= 1 then
        return nil, nil, "exclusion requires one direct dependency"
      end
      local dependency = matches[1]
      if not exclusion_exists(lines, dependency, item.excluded_coordinate) then
        local group = exclusions[dependency.coordinate]
          or { dependency = dependency, coordinates = {} }
        group.coordinates[#group.coordinates + 1] = item.excluded_coordinate
        exclusions[dependency.coordinate] = group
        changes[#changes + 1] = {
          kind = "exclude",
          direct_coordinate = item.direct_coordinate,
          excluded_coordinate = item.excluded_coordinate,
        }
      end
    else
      return nil, nil, "unsupported repair kind"
    end
  end

  local updated = vim.deepcopy(lines)
  for line, value in pairs(replacements) do
    updated[line] = value
  end
  local insertions = {}
  for _, group in pairs(exclusions) do
    table.sort(group.coordinates)
    local line, insertion, err = exclusion_insertion(lines, group.dependency, group.coordinates)
    if not line then
      return nil, nil, err
    end
    insertions[#insertions + 1] = { line = line, lines = insertion }
  end
  table.sort(insertions, function(left, right)
    return left.line > right.line
  end)
  for _, insertion in ipairs(insertions) do
    for index = #insertion.lines, 1, -1 do
      table.insert(updated, insertion.line, insertion.lines[index])
    end
  end
  table.sort(changes, function(left, right)
    local left_key = left.coordinate or left.direct_coordinate or ""
    local right_key = right.coordinate or right.direct_coordinate or ""
    if left.kind ~= right.kind then
      return left.kind < right.kind
    end
    return left_key < right_key
  end)
  return updated, changes
end

return M
