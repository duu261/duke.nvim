local build = require("duke.build")
local analyzer = require("duke.dependency_analyzer")
local completion = require("duke.completion")
local maven_model = require("duke.maven_model")
local ownership = require("duke.maven_ownership")
local process = require("duke.process")

local M = {}

local HELP_GOAL = "org.apache.maven.plugins:maven-help-plugin:3.5.2:active-profiles"
local ANALYZE_GOAL = "org.apache.maven.plugins:maven-dependency-plugin:3.11.0:analyze"

local function cleanup(path)
  pcall(vim.fn.delete, path)
end

local function detail(result)
  return process.detail(result, "unknown error")
end

local function parse_active_profiles(lines)
  local profiles = {}
  local seen = {}
  for _, raw in ipairs(lines) do
    local line = raw:gsub("^%[INFO%]%s*", "")
    local profile = line:match("^%s*%-%s+([^%s%(]+)")
    if profile and not seen[profile] then
      seen[profile] = true
      profiles[#profiles + 1] = profile
    end
  end
  return profiles
end

local function parse_usage(stdout)
  local usage = { used_undeclared = {}, unused_declared = {} }
  local seen = { used_undeclared = {}, unused_declared = {} }
  local section
  for raw in (stdout or ""):gmatch("[^\r\n]+") do
    local line = raw:gsub("^%[WARNING%]%s*", "")
    if line:find("Used undeclared dependencies found:", 1, true) then
      section = "used_undeclared"
    elseif line:find("Unused declared dependencies found:", 1, true) then
      section = "unused_declared"
    elseif line:find("dependencies found:", 1, true) then
      section = nil
    elseif section then
      local group_id, artifact_id = line:match("([%w_.-]+):([%w_.-]+):")
      if group_id and artifact_id then
        local coordinate = group_id .. ":" .. artifact_id
        if not seen[section][coordinate] then
          seen[section][coordinate] = true
          usage[section][#usage[section] + 1] = coordinate
        end
      end
    end
  end
  table.sort(usage.used_undeclared)
  table.sort(usage.unused_declared)
  return usage
end

local function add_warning(snapshot, warning)
  snapshot.analysis.doctor.warnings[#snapshot.analysis.doctor.warnings + 1] = warning
  snapshot.state = "partial"
end

function M.inspect(snapshot, opts, callback)
  opts = opts or {}
  if type(callback) ~= "function" then
    completion.log("ERROR", "Maven Doctor callback is required")
    return
  end

  local finish = completion.once(callback, "Maven Doctor")

  local function fail_internal(stage, err, result)
    completion.log("ERROR", "Maven Doctor " .. stage .. " failed: " .. tostring(err))
    finish("Maven Doctor inspection failed", result)
  end

  local function complete(enriched)
    local existing = enriched.analysis or {}
    local analyzed_ok, analyzed = pcall(analyzer.analyze, enriched)
    if not analyzed_ok then
      add_warning(enriched, "ownership analysis unavailable")
      completion.log("ERROR", "Maven Doctor dependency analysis failed: " .. tostring(analyzed))
      finish(nil, enriched)
      return
    end
    for name, value in pairs(analyzed) do
      existing[name] = value
    end
    existing.doctor = enriched.analysis.doctor

    local ownership_ok, rows = pcall(ownership.resolve, enriched)
    if not ownership_ok then
      add_warning(enriched, "ownership analysis unavailable")
      completion.log("ERROR", "Maven Doctor ownership analysis failed: " .. tostring(rows))
      rows = {}
    end
    existing.ownership = rows

    local findings_ok, findings = pcall(analyzer.repairable, analyzed, rows, existing.doctor.usage)
    if not findings_ok then
      add_warning(enriched, "repair analysis unavailable")
      completion.log("ERROR", "Maven Doctor repair analysis failed: " .. tostring(findings))
      findings = {}
    end
    existing.findings = findings
    enriched.analysis = existing
    finish(nil, enriched)
  end

  if type(snapshot) ~= "table" or snapshot.kind ~= "maven" then
    finish("Maven Doctor requires a Maven workspace snapshot")
    return
  end

  local on_enriched
  on_enriched = completion.guard_once(function(err, enriched)
    if err or type(enriched) ~= "table" then
      finish(err or "Maven Doctor received an invalid Maven snapshot", enriched)
      return
    end

    local module = enriched.modules and enriched.modules[1]
    if type(module) ~= "table" or type(module.build_file) ~= "string" then
      finish("Maven Doctor requires a Maven module build file", enriched)
      return
    end

    if enriched.analysis ~= nil and type(enriched.analysis) ~= "table" then
      error("invalid Maven analysis state")
    end
    enriched.analysis = enriched.analysis or {}
    enriched.analysis.doctor = {
      active_profiles = {},
      usage = { used_undeclared = {}, unused_declared = {} },
      warnings = {},
      deep = opts.deep == true,
    }

    local selected_ok, selected = pcall(build.maven, module.build_file, opts.maven_command or "mvn")
    if not selected_ok then
      add_warning(enriched, "active profiles unavailable")
      completion.log("ERROR", "Maven Doctor active profiles failed: " .. tostring(selected))
      complete(enriched)
      return
    end

    local path = vim.fn.tempname()
    local after_active
    after_active = completion.guard_once(function(result)
      if result.code ~= 0 then
        local message = detail(result)
        cleanup(path)
        add_warning(enriched, "active profiles unavailable")
        completion.log("ERROR", "Maven Doctor active profiles failed: " .. message)
      else
        local lines, read_err = maven_model.read_output(path)
        cleanup(path)
        if not lines then
          add_warning(enriched, "active profiles output unavailable")
          completion.log(
            "ERROR",
            "Maven Doctor active profiles output failed: " .. tostring(read_err)
          )
        else
          enriched.analysis.doctor.active_profiles = parse_active_profiles(lines)
        end
      end

      if not enriched.analysis.doctor.deep then
        complete(enriched)
        return
      end

      local after_deep
      after_deep = completion.guard_once(function(deep_result)
        if deep_result.code ~= 0 then
          local message = detail(deep_result)
          add_warning(enriched, "dependency analysis unavailable")
          completion.log("ERROR", "Maven Doctor dependency analysis failed: " .. message)
        else
          enriched.analysis.doctor.usage = parse_usage(deep_result.stdout)
        end
        complete(enriched)
      end, function(callback_err)
        fail_internal("dependency analysis callback", callback_err, enriched)
      end, "Maven Doctor dependency analysis")

      local started, run_err = pcall(process.run, selected.command, {
        "-q",
        "-f",
        module.build_file,
        ANALYZE_GOAL,
      }, {
        cwd = selected.cwd,
        env = opts.env,
        timeout = opts.timeout,
      }, after_deep)
      if not started then
        after_deep({ code = -1, stdout = "", stderr = tostring(run_err) })
      end
    end, function(callback_err)
      cleanup(path)
      fail_internal("active profiles callback", callback_err, enriched)
    end, "Maven Doctor active profiles")

    local started, run_err = pcall(process.run, selected.command, {
      "-q",
      "-f",
      module.build_file,
      HELP_GOAL,
      "-Doutput=" .. path,
    }, {
      cwd = selected.cwd,
      env = opts.env,
      timeout = opts.timeout,
    }, after_active)
    if not started then
      after_active({ code = -1, stdout = "", stderr = tostring(run_err) })
    end
  end, function(callback_err)
    fail_internal("enrichment callback", callback_err)
  end, "Maven Doctor enrichment")

  local ok, model_err = pcall(maven_model.enrich, snapshot, opts, on_enriched)
  if not ok then
    fail_internal("enrichment", model_err)
  end
end

M.HELP_GOAL = HELP_GOAL
M.ANALYZE_GOAL = ANALYZE_GOAL

return M
