---Spring Initializr data model: schema validation and transformation.
---Pure functions. No I/O, no cache paths, no HTTP.
---Input: decoded JSON tables. Output: validated/transformed data.

local M = {}

local function non_empty_string(value)
  return type(value) == "string" and value ~= ""
end

local function optional_string(value)
  return value == nil or type(value) == "string"
end

local function list_matches(value, predicate)
  if not vim.islist(value) then
    return false
  end
  for _, item in ipairs(value) do
    if not predicate(item) then
      return false
    end
  end
  return true
end

function M.is_client(value)
  local function choice(item)
    return type(item) == "table"
      and non_empty_string(item.id)
      and (item.name == nil or non_empty_string(item.name))
  end
  local function section(item)
    return type(item) == "table"
      and non_empty_string(item.default)
      and list_matches(item.values, choice)
  end
  local function dependency(item)
    return type(item) == "table"
      and non_empty_string(item.id)
      and non_empty_string(item.name)
      and optional_string(item.description)
  end
  local function group(item)
    return type(item) == "table"
      and (item.name == nil or non_empty_string(item.name))
      and list_matches(item.values, dependency)
  end

  return type(value) == "table"
    and section(value.bootVersion)
    and section(value.javaVersion)
    and section(value.language)
    and section(value.packaging)
    and type(value.dependencies) == "table"
    and list_matches(value.dependencies.values, group)
end

function M.is_catalog(value)
  if
    type(value) ~= "table"
    or type(value.dependencies) ~= "table"
    or vim.islist(value.dependencies)
  then
    return false
  end
  for id, dependency in pairs(value.dependencies) do
    if
      not non_empty_string(id)
      or type(dependency) ~= "table"
      or not non_empty_string(dependency.groupId)
      or not non_empty_string(dependency.artifactId)
    then
      return false
    end
    for _, key in ipairs({ "version", "scope", "bom", "repository" }) do
      if dependency[key] ~= nil and not non_empty_string(dependency[key]) then
        return false
      end
    end
  end
  return true
end

function M.flatten_dependencies(client)
  local result = {}
  local groups = client.dependencies and client.dependencies.values or {}
  for _, group in ipairs(groups) do
    for _, dependency in ipairs(group.values or {}) do
      result[#result + 1] = {
        id = dependency.id,
        name = dependency.name,
        description = dependency.description or "",
        group = group.name or "Other",
      }
    end
  end
  return result
end

function M.default(client, key, fallback)
  local section = client[key]
  return section and section.default or fallback
end

function M.values(client, key)
  local result = {}
  local section = client[key]
  for _, value in ipairs(section and section.values or {}) do
    result[#result + 1] = value.id
  end
  return result
end

function M.project_types(client)
  local result = {}
  local section = type(client) == "table" and client.type or nil
  for _, value in ipairs(type(section) == "table" and section.values or {}) do
    local tags = type(value) == "table" and value.tags or nil
    if
      type(tags) == "table"
      and tags.format == "project"
      and non_empty_string(value.id)
      and non_empty_string(value.name)
      and non_empty_string(tags.build)
    then
      result[#result + 1] = {
        id = value.id,
        name = value.name,
        build = tags.build,
      }
    end
  end
  return result
end

function M.resolve(catalog, selected_ids)
  local dependencies = {}
  local missing = {}
  local available = catalog.dependencies or {}
  for _, id in ipairs(selected_ids) do
    local item = available[id]
    if item and item.groupId and item.artifactId then
      dependencies[#dependencies + 1] = {
        group_id = item.groupId,
        artifact_id = item.artifactId,
        version = item.version,
        scope = item.scope,
      }
    else
      missing[#missing + 1] = id
    end
  end
  return dependencies, missing
end

function M.is_direct(item)
  if not item or not item.groupId or not item.artifactId or item.bom or item.repository then
    return false
  end
  local allowed_scopes = {
    compile = true,
    runtime = true,
    test = true,
    provided = true,
  }
  return item.scope == nil or allowed_scopes[item.scope] == true
end

return M
