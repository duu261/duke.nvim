---Spring Initializr transport: HTTP fetch, cache read/write, fallback logic.
---Pure I/O. Does not interpret the data beyond JSON decode + structural validation.

local M = {}

local function non_empty_string(value)
  return type(value) == "string" and value ~= ""
end

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

local function age_seconds(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or not stat.mtime or not stat.mtime.sec then
    return 0
  end
  local delta = os.time() - stat.mtime.sec
  return delta > 0 and delta or 0
end

local function plural(count, unit)
  return count .. " " .. unit .. (count == 1 and "" or "s") .. " ago"
end

function M.format_age(seconds)
  seconds = seconds or 0
  if seconds < 60 then
    return "just now"
  end
  if seconds < 3600 then
    return plural(math.floor(seconds / 60), "minute")
  end
  if seconds < 86400 then
    return plural(math.floor(seconds / 3600), "hour")
  end
  return plural(math.floor(seconds / 86400), "day")
end

local function write_cache(path, raw)
  local parent = vim.fs.dirname(path)
  if vim.fn.mkdir(parent, "p") == 0 and vim.fn.isdirectory(parent) ~= 1 then
    return
  end
  local random, random_error = vim.uv.random(8)
  if not random then
    require("duke.log").add("WARN", "metadata cache name failed: " .. tostring(random_error))
    return
  end
  local suffix = random:gsub(".", function(char)
    return string.format("%02x", string.byte(char))
  end)
  local temporary = path .. ".tmp-" .. suffix
  local ok, err = pcall(vim.fn.writefile, vim.split(raw, "\n", { plain = true }), temporary)
  if not ok then
    require("duke.log").add("WARN", "metadata cache write failed: " .. tostring(err))
    return
  end
  local renamed, rename_error = vim.uv.fs_rename(temporary, path)
  if not renamed then
    pcall(vim.fn.delete, temporary)
    require("duke.log").add("WARN", "metadata cache replace failed: " .. tostring(rename_error))
  end
end

function M.http_get(url, callback)
  require("duke.process").run("curl", {
    "--fail-with-body",
    "--location",
    "--proto",
    "=https",
    "--silent",
    "--show-error",
    "--header",
    "Accept: application/vnd.initializr.v2.3+json",
    "--user-agent",
    "duke.nvim",
    url,
  }, { timeout = require("duke.config").get().spring.metadata_timeout }, function(result)
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
    local reason = "fetch"
    if not fetch_error and raw then
      local remote, decode_error = decode(raw)
      if remote and valid(remote, validator) then
        write_cache(cache_path, raw)
        callback(nil, remote, "remote")
        return
      end
      fetch_error = decode_error or "Initializr JSON has unexpected structure"
      reason = "schema"
    end

    local cached, cache_error = read_cache(cache_path, validator)
    if cached then
      require("duke.log").add("WARN", "using cached Initializr metadata")
      callback(nil, cached, "cache", {
        reason = reason,
        detail = fetch_error,
        age_seconds = age_seconds(cache_path),
      })
      return
    end
    callback(fetch_error or cache_error or "Initializr metadata unavailable")
  end)
end

function M.cache_dir()
  return vim.fs.joinpath(vim.fn.stdpath("cache"), "duke.nvim")
end

function M.cache_path(kind, version, url)
  local filename = kind
  if version then
    filename = filename .. "-" .. version:gsub("[^%w_.-]", "_")
  end
  return vim.fs.joinpath(M.cache_dir(), vim.fn.sha256(url), filename .. ".json")
end

function M.clear_cache(path)
  path = path or M.cache_dir()
  if not vim.uv.fs_stat(path) then
    return true
  end
  local ok, result = pcall(vim.fn.delete, path, "rf")
  if not ok or result ~= 0 then
    return nil, "cannot clear Initializr cache: " .. path
  end
  return true
end

return M
