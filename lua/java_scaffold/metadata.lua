local M = {}

local function decode(raw)
  local ok, value = pcall(vim.json.decode, raw)
  if ok and type(value) == "table" then
    return value
  end
  return nil, "invalid Initializr JSON"
end

local function valid(value, validator)
  return not validator or validator(value)
end

local function read_cache(path, validator)
  if vim.fn.filereadable(path) ~= 1 then
    return nil, "cache unavailable"
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, "cache unreadable"
  end
  local value, decode_error = decode(table.concat(lines, "\n"))
  if not value then
    return nil, decode_error
  end
  if not valid(value, validator) then
    return nil, "cached Initializr JSON has unexpected structure"
  end
  return value
end

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

local function response_error(raw)
  if not non_empty_string(raw) then
    return nil
  end
  local value = decode(raw)
  if type(value) ~= "table" then
    return nil
  end
  for _, key in ipairs({ "message", "error" }) do
    if non_empty_string(value[key]) then
      return value[key]
    end
  end
  return nil
end

local function write_cache(path, raw)
  local parent = vim.fs.dirname(path)
  if vim.fn.mkdir(parent, "p") == 0 and vim.fn.isdirectory(parent) ~= 1 then
    return
  end
  local random, random_error = vim.uv.random(8)
  if not random then
    require("java_scaffold.log").add(
      "WARN",
      "metadata cache name failed: " .. tostring(random_error)
    )
    return
  end
  local suffix = random:gsub(".", function(char)
    return string.format("%02x", string.byte(char))
  end)
  local temporary = path .. ".tmp-" .. suffix
  local ok, err = pcall(vim.fn.writefile, vim.split(raw, "\n", { plain = true }), temporary)
  if not ok then
    require("java_scaffold.log").add("WARN", "metadata cache write failed: " .. tostring(err))
    return
  end
  local renamed, rename_error = vim.uv.fs_rename(temporary, path)
  if not renamed then
    pcall(vim.fn.delete, temporary)
    require("java_scaffold.log").add(
      "WARN",
      "metadata cache replace failed: " .. tostring(rename_error)
    )
  end
end

function M.http_get(url, callback)
  require("java_scaffold.process").run("curl", {
    "--fail-with-body",
    "--location",
    "--proto",
    "=https",
    "--silent",
    "--show-error",
    "--header",
    "Accept: application/vnd.initializr.v2.3+json",
    "--user-agent",
    "java-scaffold.nvim",
    url,
  }, { timeout = require("java_scaffold.config").get().spring.metadata_timeout }, function(result)
    if result.code ~= 0 then
      local stderr = vim.trim(result.stderr or "")
      local stdout = vim.trim(result.stdout or "")
      callback(
        response_error(stdout)
          or stderr ~= "" and stderr
          or stdout ~= "" and stdout
          or "HTTP request failed"
      )
      return
    end
    callback(nil, result.stdout)
  end)
end

function M.fetch_cached(url, cache_path, runner, callback, validator)
  runner = runner or M.http_get
  runner(url, function(fetch_error, raw)
    if not fetch_error and raw then
      local remote, decode_error = decode(raw)
      if remote and valid(remote, validator) then
        write_cache(cache_path, raw)
        callback(nil, remote, "remote")
        return
      end
      fetch_error = decode_error or "Initializr JSON has unexpected structure"
    end

    local cached, cache_error = read_cache(cache_path, validator)
    if cached then
      require("java_scaffold.log").add("WARN", "using cached Initializr metadata")
      callback(nil, cached, "cache")
      return
    end
    callback(fetch_error or cache_error or "Initializr metadata unavailable")
  end)
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

function M.cache_path(kind, version, url)
  local filename = kind
  if version then
    filename = filename .. "-" .. version:gsub("[^%w_.-]", "_")
  end
  return vim.fs.joinpath(
    vim.fn.stdpath("cache"),
    "java-scaffold.nvim",
    vim.fn.sha256(url),
    filename .. ".json"
  )
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
