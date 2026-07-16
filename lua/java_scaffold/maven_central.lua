local M = {}

local function non_empty_string(value)
  return type(value) == "string" and value ~= ""
end

function M.build_search_args(url, term, rows)
  return {
    "--fail-with-body",
    "--location",
    "--proto",
    "=https",
    "--silent",
    "--show-error",
    "--get",
    "--data-urlencode",
    "q=" .. term,
    "--data-urlencode",
    "rows=" .. tostring(rows),
    "--data-urlencode",
    "wt=json",
    "--user-agent",
    "java-scaffold.nvim",
    url,
  }
end

function M.build_versions_args(url, group_id, artifact_id, rows)
  return {
    "--fail-with-body",
    "--location",
    "--proto",
    "=https",
    "--silent",
    "--show-error",
    "--get",
    "--data-urlencode",
    string.format('q=g:"%s" AND a:"%s"', group_id, artifact_id),
    "--data-urlencode",
    "core=gav",
    "--data-urlencode",
    "rows=" .. tostring(rows),
    "--data-urlencode",
    "sort=timestamp desc",
    "--data-urlencode",
    "wt=json",
    "--user-agent",
    "java-scaffold.nvim",
    url,
  }
end

function M.is_search_result(value)
  if
    type(value) ~= "table"
    or type(value.response) ~= "table"
    or not vim.islist(value.response.docs)
  then
    return false
  end
  return true
end

local function process_error(result)
  local detail = vim.trim(result.stderr or "")
  if detail == "" then
    detail = vim.trim(result.stdout or "")
  end
  if result.code == 28 then
    return "Maven Central search timed out; retry later"
  end
  if result.code == 22 and detail:find("429", 1, true) then
    return "Maven Central rate-limited (HTTP 429); retry later"
  end
  return "Maven Central search failed: " .. (detail ~= "" and detail or "HTTP request failed")
end

local function request(args, callback, runner)
  local config = require("java_scaffold.config").get().maven
  runner = runner or require("java_scaffold.process").run
  runner("curl", args, { timeout = config.central_search_timeout }, function(result)
    if result.code ~= 0 then
      callback(process_error(result))
      return
    end
    local ok, value = pcall(vim.json.decode, result.stdout or "")
    if not ok or not M.is_search_result(value) then
      callback("Maven Central response has unexpected structure")
      return
    end
    callback(nil, value.response.docs)
  end)
end

function M.search(term, callback, runner)
  local config = require("java_scaffold.config").get().maven
  request(
    M.build_search_args(config.central_search_url, term, config.central_search_rows),
    function(err, docs)
      if err then
        callback(err)
        return
      end
      local dependencies = {}
      for _, doc in ipairs(docs) do
        if
          type(doc) == "table"
          and non_empty_string(doc.g)
          and non_empty_string(doc.a)
          and non_empty_string(doc.latestVersion)
          and (doc.p == nil or type(doc.p) == "string")
          and doc.p ~= "pom"
        then
          dependencies[#dependencies + 1] = {
            group_id = doc.g,
            artifact_id = doc.a,
            version = doc.latestVersion,
            packaging = doc.p,
          }
        end
      end
      callback(nil, dependencies)
    end,
    runner
  )
end

function M.versions(group_id, artifact_id, callback, runner)
  local config = require("java_scaffold.config").get().maven
  request(
    M.build_versions_args(
      config.central_search_url,
      group_id,
      artifact_id,
      config.central_search_rows
    ),
    function(err, docs)
      if err then
        callback(err)
        return
      end
      local versions = {}
      local seen = {}
      for _, doc in ipairs(docs) do
        if type(doc) == "table" and non_empty_string(doc.v) and not seen[doc.v] then
          seen[doc.v] = true
          versions[#versions + 1] = doc.v
        end
      end
      callback(nil, versions)
    end,
    runner
  )
end

return M
