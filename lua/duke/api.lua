local M = {}

local function log(level, message)
  local ok, logger = pcall(require, "duke.log")
  if ok then
    pcall(logger.add, level, message)
  end
end

local function completion(callback)
  local completed = false
  return function(result)
    if completed then
      return
    end
    completed = true
    if type(callback) ~= "function" then
      log("ERROR", "programmatic API callback must be a function")
      return
    end
    vim.schedule(function()
      local ok, err = pcall(callback, result)
      if not ok then
        log("ERROR", "programmatic API callback failed: " .. tostring(err))
      end
    end)
  end
end

local function fail(complete, fields, message)
  local result = vim.tbl_extend("force", fields or {}, { ok = false, error = tostring(message) })
  complete(result)
end

local function non_empty_string(value)
  return type(value) == "string" and value ~= ""
end

local function numeric_version(value)
  return non_empty_string(value) and value:match("^%d+$") ~= nil
end

local function positive_number(value)
  return type(value) == "number" and value > 0
end

local function absolute(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function validate_common_create(opts)
  if type(opts) ~= "table" then
    return "options must be a table"
  end
  for _, key in ipairs({ "cwd", "group_id", "artifact_id", "java_version" }) do
    if not non_empty_string(opts[key]) then
      return key .. " must be a non-empty string"
    end
  end
  local stat = vim.uv.fs_stat(absolute(opts.cwd))
  if not stat or stat.type ~= "directory" then
    return "cwd must be an existing directory"
  end
  if not numeric_version(opts.java_version) then
    return "java_version must be a numeric version string"
  end
  if opts.package_name ~= nil and not non_empty_string(opts.package_name) then
    return "package_name must be a non-empty string"
  end
end

local function runner_env(config, tool, override)
  if override ~= nil and not non_empty_string(override) then
    return nil, "runner_java_version must be 'auto' or a numeric version string"
  end
  local requested = override or config[tool].runner_java_version
  if requested ~= "auto" and not numeric_version(requested) then
    return nil, "runner_java_version must be 'auto' or a numeric version string"
  end
  local java = require("duke.java")
  local runtimes = {
    active = java.active(),
    homes = java.discover_homes(config.java_homes),
  }
  local versions = java.installed(config.java_versions, config.java_homes, runtimes)
  local version = java.default(requested, versions, runtimes.active)
  return java.runner_env(version, config.java_homes, runtimes.homes)
end

local function validate_optional_string(opts, key)
  return opts[key] == nil or non_empty_string(opts[key])
end

local function create_options(kind, opts)
  local common_error = validate_common_create(opts)
  if common_error then
    return nil, common_error
  end

  local config = require("duke.config").get()
  local maven = require("duke.maven")
  local normalized = {
    cwd = absolute(opts.cwd),
    group_id = opts.group_id,
    artifact_id = opts.artifact_id,
    package_name = opts.package_name or maven.package_name(opts.group_id, opts.artifact_id),
    java_version = opts.java_version,
  }

  if kind == "maven" then
    local archetype = opts.archetype or config.maven.archetypes[1]
    if type(archetype) ~= "table" then
      return nil, "archetype must be a table"
    end
    for _, key in ipairs({ "group_id", "artifact_id", "version" }) do
      if not non_empty_string(archetype[key]) then
        return nil, "archetype." .. key .. " must be a non-empty string"
      end
    end
    if not validate_optional_string(opts, "version") then
      return nil, "version must be a non-empty string"
    end
    if opts.wrapper ~= nil and type(opts.wrapper) ~= "boolean" then
      return nil, "wrapper must be a boolean"
    end
    if not validate_optional_string(opts, "command") then
      return nil, "command must be a non-empty string"
    end
    if opts.timeout ~= nil and not positive_number(opts.timeout) then
      return nil, "timeout must be a positive number"
    end
    local env, env_error = runner_env(config, "maven", opts.runner_java_version)
    if env_error then
      return nil, env_error
    end
    return vim.tbl_extend("force", normalized, {
      archetype = vim.deepcopy(archetype),
      version = opts.version or config.maven.project_version,
      wrapper = opts.wrapper == nil and config.maven.wrapper or opts.wrapper,
      command = opts.command or config.maven.command,
      timeout = opts.timeout or config.maven.timeout,
      env = env,
    })
  end

  if kind == "gradle" then
    local gradle = require("duke.gradle")
    local language = opts.language or "java"
    local project_type = opts.project_type or config.gradle.default_project_type
    local mapped_type = gradle.project_type(language, project_type)
    if not mapped_type then
      return nil, "unsupported Gradle source language and project type combination"
    end
    local dsl = opts.dsl or config.gradle.dsl
    local allowed_dsls = config.gradle.dsls or { "kotlin", "groovy" }
    if not non_empty_string(dsl) or not vim.tbl_contains(allowed_dsls, dsl) then
      return nil, "unsupported Gradle DSL"
    end
    if not validate_optional_string(opts, "test_framework") then
      return nil, "test_framework must be a non-empty string"
    end
    if not validate_optional_string(opts, "command") then
      return nil, "command must be a non-empty string"
    end
    if opts.timeout ~= nil and not positive_number(opts.timeout) then
      return nil, "timeout must be a positive number"
    end
    local env, env_error = runner_env(config, "gradle", opts.runner_java_version)
    if env_error then
      return nil, env_error
    end
    return vim.tbl_extend("force", normalized, {
      project_type = mapped_type,
      dsl = dsl,
      test_framework = opts.test_framework or config.gradle.test_framework,
      command = opts.command or config.gradle.command,
      timeout = opts.timeout or config.gradle.timeout,
      env = env,
    })
  end

  if kind == "spring" then
    if not non_empty_string(opts.boot_version) then
      return nil, "boot_version must be a non-empty string"
    end
    local project_type = opts.project_type or config.spring.project_type
    local builds = { ["maven-project"] = "maven", ["gradle-project"] = "gradle" }
    if not builds[project_type] then
      return nil, "unsupported Spring project_type"
    end
    local language = opts.language or config.spring.language
    if not vim.tbl_contains({ "java", "kotlin", "groovy" }, language) then
      return nil, "unsupported Spring language"
    end
    local packaging = opts.packaging or config.spring.packaging
    if not vim.tbl_contains({ "jar", "war" }, packaging) then
      return nil, "unsupported Spring packaging"
    end
    local dependencies = opts.dependencies or {}
    if type(dependencies) ~= "table" or not vim.islist(dependencies) then
      return nil, "dependencies must be a list of strings"
    end
    for _, dependency in ipairs(dependencies) do
      if not non_empty_string(dependency) then
        return nil, "dependencies must be a list of strings"
      end
    end
    for _, key in ipairs({ "name", "description", "url" }) do
      if opts[key] ~= nil and type(opts[key]) ~= "string" then
        return nil, key .. " must be a string"
      end
    end
    local url = opts.url or config.spring.starter_url
    if opts.name == "" or not non_empty_string(url) then
      return nil, "name and url must be non-empty strings"
    end
    if not url:match("^https://") then
      return nil, "url must use HTTPS"
    end
    if opts.timeout ~= nil and not positive_number(opts.timeout) then
      return nil, "timeout must be a positive number"
    end
    return vim.tbl_extend("force", normalized, {
      boot_version = opts.boot_version,
      dependencies = vim.deepcopy(dependencies),
      project_type = project_type,
      build = builds[project_type],
      language = language,
      packaging = packaging,
      name = opts.name or opts.artifact_id,
      description = opts.description or "",
      url = url,
      timeout = opts.timeout or config.spring.timeout,
    })
  end
end

function M.create(kind, opts, callback)
  local complete = completion(callback)
  if not vim.tbl_contains({ "maven", "gradle", "spring" }, kind) then
    fail(complete, { kind = kind }, "unknown project kind")
    return
  end
  local ok, normalized, validation_error = pcall(create_options, kind, opts)
  if not ok then
    fail(complete, { kind = kind }, normalized)
    return
  end
  if not normalized then
    fail(complete, { kind = kind }, validation_error)
    return
  end

  local adapter = require("duke." .. kind)
  local adapter_finished = false
  local started, startup_error = pcall(adapter.create, normalized, function(err, project_dir)
    if adapter_finished then
      return
    end
    adapter_finished = true
    if err then
      fail(complete, { kind = kind }, err)
      return
    end
    vim.schedule(function()
      local final_ok, final_error = pcall(function()
        local absolute_project = absolute(project_dir)
        local entry_file = absolute(require("duke.project").entry(absolute_project))
        local event_ok, event_error = pcall(vim.api.nvim_exec_autocmds, "User", {
          pattern = "DukeProjectCreated",
          data = { project_dir = absolute_project, entry_file = entry_file },
        })
        if not event_ok then
          log("WARN", "project-created event failed: " .. tostring(event_error))
        end
        complete({
          ok = true,
          kind = kind,
          project_dir = absolute_project,
          entry_file = entry_file,
        })
      end)
      if not final_ok then
        fail(complete, { kind = kind }, final_error)
      end
    end)
  end)
  if not started and not adapter_finished then
    fail(complete, { kind = kind }, startup_error)
  end
end

local function pom_request(opts, require_version)
  if type(opts) ~= "table" then
    return nil, "options must be a table"
  end
  if not non_empty_string(opts.pom_path) then
    return nil, "pom_path must be a non-empty string"
  end
  local path = absolute(opts.pom_path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil, "pom_path must identify an existing file"
  end
  if not non_empty_string(opts.group_id) or not non_empty_string(opts.artifact_id) then
    return nil, "group_id and artifact_id must be non-empty strings"
  end
  local coordinate_error = require("duke.maven").validate(opts.group_id, opts.artifact_id)
  if coordinate_error then
    return nil, coordinate_error
  end
  if require_version and not non_empty_string(opts.version) then
    return nil, "version must be a non-empty string"
  end
  return path
end

local function read_pom(path)
  local lines, buffer, was_modified, read_error = require("duke.pom_file").read(path)
  if not lines then
    return nil, nil, nil, read_error or ("cannot read " .. path)
  end
  return lines, buffer, was_modified
end

local function mutation_result(path, changed, count, saved)
  return { ok = true, pom_path = path, changed = changed, count = count, saved = saved }
end

local function save_mutation(complete, path, updated, buffer, was_modified, count)
  if count == 0 then
    complete(mutation_result(path, false, 0, true))
    return
  end
  local saved, save_error = require("duke.pom_file").save(path, updated, buffer, was_modified)
  if saved == nil then
    fail(complete, { pom_path = path }, save_error)
    return
  end
  complete(mutation_result(path, true, count, saved))
end

local function matching(dependencies, opts)
  local matches = {}
  for _, dependency in ipairs(dependencies) do
    if dependency.group_id == opts.group_id and dependency.artifact_id == opts.artifact_id then
      matches[#matches + 1] = dependency
    end
  end
  return matches
end

local function ambiguous_coordinates(dependencies)
  local seen = {}
  for _, dependency in ipairs(dependencies) do
    local coordinate = dependency.group_id .. ":" .. dependency.artifact_id
    if seen[coordinate] then
      return true
    end
    seen[coordinate] = true
  end
  return false
end

local function run_sync(callback, operation)
  local complete = completion(callback)
  local ok, err = pcall(operation, complete)
  if not ok then
    fail(complete, nil, err)
  end
end

function M.add(opts, callback)
  run_sync(callback, function(complete)
    local path, validation_error = pom_request(opts, true)
    if not path then
      fail(complete, nil, validation_error)
      return
    end
    local scope = opts.scope or "compile"
    if not vim.tbl_contains({ "compile", "test", "provided", "runtime" }, scope) then
      fail(complete, { pom_path = path }, "unsupported Maven dependency scope")
      return
    end
    local lines, buffer, was_modified, read_error = read_pom(path)
    if not lines then
      fail(complete, { pom_path = path }, read_error)
      return
    end
    local dependency = {
      group_id = opts.group_id,
      artifact_id = opts.artifact_id,
      version = opts.version,
      scope = scope ~= "compile" and scope or nil,
    }
    local updated, added, insert_error = require("duke.pom").insert(lines, { dependency })
    if insert_error then
      fail(complete, { pom_path = path }, insert_error)
      return
    end
    save_mutation(complete, path, updated, buffer, was_modified, added)
  end)
end

function M.add_module(opts, callback)
  local complete = completion(callback)
  local ok, unexpected = pcall(function()
    if type(opts) ~= "table" then
      fail(complete, nil, "options must be a table")
      return
    end
    if not non_empty_string(opts.reactor_dir) then
      fail(complete, nil, "reactor_dir must be a non-empty string")
      return
    end
    if not non_empty_string(opts.artifact_id) then
      fail(complete, nil, "artifact_id must be a non-empty string")
      return
    end
    require("duke.maven_module").create(opts, function(err, result)
      if err then
        fail(complete, {
          parent_pom = result and result.parent_pom,
          module_dir = result and result.module_dir,
          rolled_back = result and result.rolled_back or false,
        }, err)
        return
      end
      complete({
        ok = true,
        parent_pom = result.parent_pom,
        module_dir = result.module_dir,
        rolled_back = result.rolled_back or false,
      })
    end)
  end)
  if not ok then
    fail(complete, nil, unexpected)
  end
end

function M.upgrade(opts, callback)
  run_sync(callback, function(complete)
    local path, validation_error = pom_request(opts, true)
    if not path then
      fail(complete, nil, validation_error)
      return
    end
    local lines, buffer, was_modified, read_error = read_pom(path)
    if not lines then
      fail(complete, { pom_path = path }, read_error)
      return
    end
    local dependencies, list_error = require("duke.pom").list(lines)
    if list_error then
      fail(complete, { pom_path = path }, list_error)
      return
    end
    local matches = matching(dependencies, opts)
    if #matches ~= 1 then
      local message = #matches == 0 and "dependency not found" or "ambiguous duplicate dependencies"
      fail(complete, { pom_path = path }, message)
      return
    end
    if matches[1].version == opts.version then
      complete(mutation_result(path, false, 0, true))
      return
    end
    local updated, update_error =
      require("duke.pom").update_version(lines, matches[1], opts.version)
    if update_error then
      fail(complete, { pom_path = path }, update_error)
      return
    end
    save_mutation(complete, path, updated, buffer, was_modified, 1)
  end)
end

local function parent_pom_request(opts)
  if type(opts) ~= "table" then
    return nil, "options must be a table"
  end
  if not non_empty_string(opts.pom_path) then
    return nil, "pom_path must be a non-empty string"
  end
  local path = absolute(opts.pom_path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil, "pom_path must identify an existing file"
  end
  if not non_empty_string(opts.version) then
    return nil, "version must be a non-empty string"
  end
  return path
end

function M.upgrade_parent(opts, callback)
  run_sync(callback, function(complete)
    local path, validation_error = parent_pom_request(opts)
    if not path then
      fail(complete, nil, validation_error)
      return
    end
    local lines, buffer, was_modified, read_error = read_pom(path)
    if not lines then
      fail(complete, { pom_path = path }, read_error)
      return
    end
    local parent, parent_error = require("duke.pom").parent(lines)
    if not parent then
      fail(complete, { pom_path = path }, parent_error)
      return
    end
    if parent.version == opts.version then
      complete(mutation_result(path, false, 0, true))
      return
    end
    local updated, update_error = require("duke.pom").update_version(lines, parent, opts.version)
    if update_error then
      fail(complete, { pom_path = path }, update_error)
      return
    end
    save_mutation(complete, path, updated, buffer, was_modified, 1)
  end)
end

function M.remove(opts, callback)
  run_sync(callback, function(complete)
    local path, validation_error = pom_request(opts, false)
    if not path then
      fail(complete, nil, validation_error)
      return
    end
    local lines, buffer, was_modified, read_error = read_pom(path)
    if not lines then
      fail(complete, { pom_path = path }, read_error)
      return
    end
    local dependencies, list_error = require("duke.pom").list(lines)
    if list_error then
      fail(complete, { pom_path = path }, list_error)
      return
    end
    local matches = matching(dependencies, opts)
    if #matches > 1 then
      fail(complete, { pom_path = path }, "ambiguous duplicate dependencies")
      return
    end
    if #matches == 0 then
      complete(mutation_result(path, false, 0, true))
      return
    end
    local updated, removed, remove_error = require("duke.pom").remove(lines, matches)
    if remove_error then
      fail(complete, { pom_path = path }, remove_error)
      return
    end
    save_mutation(complete, path, updated, buffer, was_modified, removed)
  end)
end

local function outdated_result(path, dependencies, managed, property_backed, unchecked, warning)
  return {
    ok = true,
    pom_path = path,
    dependencies = dependencies,
    skipped = { managed = managed, property_backed = property_backed },
    unchecked = unchecked,
    warning = warning,
  }
end

function M.outdated(opts, callback)
  local complete = completion(callback)
  local ok, startup_error = pcall(function()
    if type(opts) ~= "table" or not non_empty_string(opts.pom_path) then
      fail(complete, nil, "pom_path must be a non-empty string")
      return
    end
    local has_group = opts.group_id ~= nil
    local has_artifact = opts.artifact_id ~= nil
    if has_group ~= has_artifact then
      fail(complete, nil, "group_id and artifact_id must be provided together")
      return
    end
    local path
    if has_group then
      local validation_error
      path, validation_error = pom_request(opts, false)
      if not path then
        fail(complete, nil, validation_error)
        return
      end
    else
      path = absolute(opts.pom_path)
      local stat = vim.uv.fs_stat(path)
      if not stat or stat.type ~= "file" then
        fail(complete, nil, "pom_path must identify an existing file")
        return
      end
    end
    local lines, _, _, read_error = read_pom(path)
    if not lines then
      fail(complete, { pom_path = path }, read_error)
      return
    end
    local dependencies, list_error = require("duke.pom").list(lines)
    if list_error then
      fail(complete, { pom_path = path }, list_error)
      return
    end
    if ambiguous_coordinates(dependencies) then
      fail(complete, { pom_path = path }, "ambiguous duplicate dependencies")
      return
    end
    if has_group then
      dependencies = matching(dependencies, opts)
      if #dependencies > 1 then
        fail(complete, { pom_path = path }, "ambiguous duplicate dependencies")
        return
      end
    end

    local candidates = {}
    local managed = 0
    local property_backed = 0
    for _, dependency in ipairs(dependencies) do
      if not dependency.version then
        managed = managed + 1
      elseif dependency.version:find("${", 1, true) then
        property_backed = property_backed + 1
      else
        candidates[#candidates + 1] = dependency
      end
    end
    if #candidates == 0 then
      complete(outdated_result(path, {}, managed, property_backed, 0, nil))
      return
    end

    local rows = {}
    local checked = 0
    local index = 1
    local function inspect_next()
      if index > #candidates then
        complete(outdated_result(path, rows, managed, property_backed, 0, nil))
        return
      end
      local dependency = candidates[index]
      local started, lookup_start_error = pcall(
        require("duke.maven_central").versions,
        dependency.group_id,
        dependency.artifact_id,
        function(lookup_error, versions)
          local callback_ok, callback_error = pcall(function()
            if lookup_error then
              local unchecked = #candidates - index + 1
              if checked == 0 then
                fail(complete, { pom_path = path }, lookup_error)
              else
                complete(
                  outdated_result(path, rows, managed, property_backed, unchecked, lookup_error)
                )
              end
              return
            end
            checked = checked + 1
            local latest = versions and versions[1]
            if latest and latest ~= dependency.version then
              rows[#rows + 1] = {
                group_id = dependency.group_id,
                artifact_id = dependency.artifact_id,
                current_version = dependency.version,
                latest_version = latest,
              }
            end
            index = index + 1
            inspect_next()
          end)
          if not callback_ok then
            fail(complete, { pom_path = path }, callback_error)
          end
        end
      )
      if not started then
        if checked == 0 then
          fail(complete, { pom_path = path }, lookup_start_error)
        else
          complete(
            outdated_result(
              path,
              rows,
              managed,
              property_backed,
              #candidates - index + 1,
              tostring(lookup_start_error)
            )
          )
        end
      end
    end
    inspect_next()
  end)
  if not ok then
    fail(complete, nil, startup_error)
  end
end

return M
