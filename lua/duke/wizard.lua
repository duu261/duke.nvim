local M = {}

-- Require picker lazily inside each function so mock overrides in tests work.
-- Pattern matches init.lua and every other module in the codebase.

local function get_runtimes(_)
  return require("duke").java_runtimes()
end

local function notify_error(message)
  require("duke.log").add("ERROR", message)
  vim.notify("duke.nvim: " .. message, vim.log.levels.ERROR)
end

local function notify(message, level)
  vim.notify("duke.nvim: " .. message, level or vim.log.levels.INFO)
end

local java_lts_versions =
  { ["8"] = true, ["11"] = true, ["17"] = true, ["21"] = true, ["25"] = true }

local function format_java_version(version)
  local value = tostring(version)
  return java_lts_versions[value] and (value .. "  (LTS)") or value
end

local function cache_fallback_message(fallback)
  local age = require("duke.metadata").format_age(fallback.age_seconds)
  if fallback.reason == "schema" then
    return "Initializr metadata schema not recognized; using cached data from " .. age
  end
  return "Spring Initializr unreachable; using cached data from " .. age
end

-- Engine: runs steps sequentially. Each step is fn(state, callback).
-- callback(nil) aborts the sequence. callback(new_state) advances to next step.
-- on_complete(final_state) called after the last step succeeds.
function M.sequence(steps, on_complete)
  local state = {}
  local current = 1

  local function next_step()
    if current > #steps then
      on_complete(state)
      return
    end
    local step = steps[current]
    current = current + 1
    local ok, err = pcall(step, state, function(result)
      if result == nil then
        return -- cancelled, abort silently
      end
      state = result
      next_step()
    end)
    if not ok then
      notify_error("wizard step failed: " .. tostring(err))
    end
  end

  next_step()
end

-- Built-in steps: thin wrappers around require("duke.picker").

function M.select_one(items, opts, state_key)
  return function(state, callback)
    require("duke.picker").select_one(items, opts, function(choice)
      if not choice then
        callback(nil)
        return
      end
      state[state_key] = choice
      callback(state)
    end)
  end
end

function M.select_many(items, opts, state_key)
  return function(state, callback)
    require("duke.picker").select_many(items, opts, function(selected)
      if not selected then
        callback(nil)
        return
      end
      state[state_key] = selected
      callback(state)
    end)
  end
end

function M.input(prompt, default, state_key, opts)
  opts = opts or {}
  return function(state, callback)
    require("duke.picker").input(prompt, default, function(value)
      if value == nil then
        callback(nil)
        return
      end
      value = vim.trim(value)
      if value == "" and not opts.allow_empty then
        value = default
      end
      state[state_key] = value
      callback(state)
    end)
  end
end

function M.confirm(title, fields_fn)
  return function(state, callback)
    local fields = fields_fn(state)
    local lines = { title }
    for _, field in ipairs(fields) do
      lines[#lines + 1] = field[1] .. ": " .. tostring(field[2])
    end
    local confirmed = require("duke.picker").confirm(table.concat(lines, "\n"))
    if not confirmed then
      callback(nil)
      return
    end
    callback(state)
  end
end

-- Domain-specific steps.

function M.project_dir(_)
  return function(state, callback)
    require("duke.picker").input("Destination directory: ", vim.fn.getcwd(), function(value)
      if value == nil then
        callback(nil)
        return
      end
      value = vim.trim(value)
      if value == "" then
        notify_error("destination directory is required")
        callback(nil)
        return
      end
      local destination = vim.fs.normalize(vim.fn.fnamemodify(value, ":p"))
      if vim.fn.isdirectory(destination) ~= 1 then
        notify_error("destination directory does not exist: " .. destination)
        callback(nil)
        return
      end
      state.destination = destination
      callback(state)
    end)
  end
end

function M.coordinates(config)
  return function(state, callback)
    local artifact_default = state._artifact_default or config.artifact_id
    require("duke.picker").input("Group ID: ", config.group_id, function(group_id)
      if not group_id then
        callback(nil)
        return
      end
      require("duke.picker").input("Artifact ID: ", artifact_default, function(artifact_id)
        if not artifact_id then
          callback(nil)
          return
        end
        local err = require("duke.maven").validate(group_id, artifact_id)
        if err then
          notify_error(err)
          callback(nil)
          return
        end
        state.group_id = group_id
        state.artifact_id = artifact_id
        callback(state)
      end)
    end)
  end
end

function M.package_name(_)
  return function(state, callback)
    local maven = require("duke.maven")
    local derived = maven.package_name(state.group_id, state.artifact_id)
    require("duke.picker").input("Package name: ", derived, function(package_name)
      if package_name == nil then
        callback(nil)
        return
      end
      package_name = vim.trim(package_name)
      if package_name == "" then
        package_name = derived
      end
      local package_error = maven.validate_package(package_name)
      if package_error then
        notify_error(package_error)
        callback(nil)
        return
      end
      state.package_name = package_name
      callback(state)
    end)
  end
end

function M.java_version(config)
  return function(state, callback)
    local java = require("duke.java")
    local runtimes = get_runtimes(config)
    local versions = java.installed(config.java_versions, config.java_homes, runtimes)
    if #versions == 0 then
      notify_error("no Java versions available")
      callback(nil)
      return
    end
    local selected_default = java.default(config.java_version, versions, runtimes.active)
    require("duke.picker").select_one(versions, {
      prompt = "Java version",
      default = selected_default,
      format_item = format_java_version,
    }, function(java_version)
      if not java_version then
        callback(nil)
        return
      end
      state.java_version = java_version
      state._runtimes = runtimes
      state._versions = versions
      callback(state)
    end)
  end
end

function M.runner_preview(config, build_tool)
  return function(state, callback)
    local java = require("duke.java")
    local versions = state._versions
    local runtimes = state._runtimes
    if not versions then
      runtimes = get_runtimes(config)
      versions = java.installed(config.java_versions, config.java_homes, runtimes)
    end
    local tool_config = config[build_tool]
    local runner_key = build_tool .. "_runner_version"
    local runner_env_key = build_tool .. "_runner_env"
    state[runner_key] = java.default(tool_config.runner_java_version, versions, runtimes.active)
    state[runner_env_key] = java.runner_env(state[runner_key], config.java_homes, runtimes.homes)
    callback(state)
  end
end

function M.runner_check(config, build_tool)
  return function(state, callback)
    local java = require("duke.java")
    local runtimes = state._runtimes or get_runtimes(config)
    local versions = state._versions
      or java.installed(config.java_versions, config.java_homes, runtimes)

    local runner_key = build_tool .. "_runner_version"
    local runner_env_key = build_tool .. "_runner_env"
    local tool_config = config[build_tool]

    local runner_version = java.default(tool_config.runner_java_version, versions, runtimes.active)
    state[runner_key] = runner_version
    state[runner_env_key] = java.runner_env(runner_version, config.java_homes, runtimes.homes)

    local tool_command = tool_config.command
    local detect_fn = build_tool == "maven" and java.maven_runtime_async
      or java.gradle_runtime_async
    local tool_label = build_tool == "maven" and "Maven" or "Gradle"

    notify("detecting " .. tool_label .. " runtime")
    detect_fn(tool_command, function(detected_runtime)
      if build_tool == "maven" then
        local maven_runtime = detected_runtime or runtimes.active
        if maven_runtime and tonumber(state.java_version) > tonumber(maven_runtime) then
          notify(
            string.format(
              "Java %s exceeds Maven runner Java %s; configure Maven runner JDK or toolchain",
              state.java_version,
              maven_runtime
            ),
            vim.log.levels.WARN
          )
        end
      elseif detected_runtime and tonumber(state.java_version) > tonumber(detected_runtime) then
        notify(
          string.format(
            "Java %s exceeds Gradle runner Java %s; configure Gradle toolchain",
            state.java_version,
            detected_runtime
          ),
          vim.log.levels.WARN
        )
      end
      notify("creating " .. tool_label .. " project with Java " .. state.java_version)
      callback(state)
    end, tool_config.timeout, state[runner_env_key])
  end
end

function M.gradle_project_type(_)
  return function(state, callback)
    local init_type = require("duke.gradle").project_type(state.language, state.project_type.id)
    if not init_type then
      notify_error("unsupported Gradle source language and project type combination")
      callback(nil)
      return
    end
    state.gradle_project_type = init_type
    callback(state)
  end
end

function M.spring_java_version(config)
  return function(state, callback)
    local metadata = require("duke.metadata")
    local client = state.spring_client
    local versions = metadata.values(client, "javaVersion")
    if #versions == 0 then
      notify_error("no Java versions available")
      callback(nil)
      return
    end
    local fallback = metadata.default(client, "javaVersion", versions[#versions])
    local default_version = require("duke.java").default(config.java_version, versions, fallback)
    require("duke.picker").select_one(versions, {
      prompt = "Java version",
      default = default_version,
      format_item = format_java_version,
    }, function(java_version)
      if not java_version then
        callback(nil)
        return
      end
      state.java_version = java_version
      callback(state)
    end)
  end
end

function M.spring_metadata_fetch(config)
  return function(state, callback)
    local progress = require("duke.progress").task("Loading Spring Initializr metadata")
    local metadata = require("duke.metadata")
    metadata.fetch_cached(
      config.spring.metadata_url,
      metadata.cache_path("metadata", nil, config.spring.metadata_url),
      nil,
      function(fetch_error, client, source, fallback)
        if fetch_error then
          progress:fail()
          notify_error(fetch_error)
          callback(nil)
          return
        end
        progress:done()
        if source == "cache" and fallback then
          notify(cache_fallback_message(fallback))
        end
        state.spring_client = client
        callback(state)
      end,
      metadata.is_client
    )
  end
end

function M.spring_boot_version(_)
  return function(state, callback)
    local metadata = require("duke.metadata")
    local client = state.spring_client
    local boot_versions = metadata.values(client, "bootVersion")
    local default_boot = metadata.default(client, "bootVersion")
    if #boot_versions == 0 and default_boot then
      boot_versions = { default_boot }
    end
    require("duke.picker").select_one(boot_versions, {
      prompt = "Spring Boot version",
      default = default_boot,
    }, function(boot_version)
      if not boot_version then
        callback(nil)
        return
      end
      state.boot_version = boot_version
      callback(state)
    end)
  end
end

function M.spring_project_type(config)
  return function(state, callback)
    local metadata = require("duke.metadata")
    local project_types = metadata.project_types(state.spring_client)
    if #project_types == 0 then
      state.spring_project_type = {
        id = config.spring.project_type,
        build = config.spring.project_type:match("^gradle") and "gradle" or "maven",
      }
      callback(state)
      return
    end
    require("duke.picker").select_one(project_types, {
      prompt = "Spring project type",
      default = config.spring.project_type,
      format_item = function(item)
        return item.name
      end,
    }, function(project_type)
      if not project_type then
        callback(nil)
        return
      end
      state.spring_project_type = project_type
      callback(state)
    end)
  end
end

function M.spring_fields(_)
  local maven = require("duke.maven")
  return function(state, callback)
    local derived_package = maven.package_name(state.group_id, state.artifact_id)
    require("duke.picker").input("Project name: ", state.artifact_id, function(name)
      if name == nil then
        callback(nil)
        return
      end
      state.name = vim.trim(name) ~= "" and vim.trim(name) or state.artifact_id
      require("duke.picker").input(
        "Description: ",
        "Demo project for Spring Boot",
        function(description)
          if description == nil then
            callback(nil)
            return
          end
          state.description = vim.trim(description)
          require("duke.picker").input("Package name: ", derived_package, function(package_name)
            if package_name == nil then
              callback(nil)
              return
            end
            package_name = vim.trim(package_name)
            if package_name == "" then
              package_name = derived_package
            end
            local package_error = maven.validate_package(package_name)
            if package_error then
              notify_error(package_error)
              callback(nil)
              return
            end
            state.package_name = package_name
            callback(state)
          end)
        end
      )
    end)
  end
end

function M.spring_dependencies(_)
  return function(state, callback)
    local metadata = require("duke.metadata")
    local catalog = state.spring_catalog
    local client = state.spring_client
    local dependencies = {}
    for _, item in ipairs(metadata.flatten_dependencies(client)) do
      if catalog.dependencies[item.id] then
        dependencies[#dependencies + 1] = item
      end
    end
    require("duke.picker").select_many(dependencies, {
      prompt = "Spring dependencies",
      format_item = function(item)
        return string.format("%s  [%s]", item.name, item.group)
      end,
    }, function(selected)
      if not selected then
        callback(nil)
        return
      end
      state.dependency_ids = vim.tbl_map(function(item)
        return item.id
      end, selected)
      callback(state)
    end)
  end
end

function M.spring_options(config)
  return function(state, callback)
    local metadata = require("duke.metadata")
    local client = state.spring_client
    local languages = metadata.values(client, "language")
    require("duke.picker").select_one(languages, {
      prompt = "Spring language",
      default = config.spring.language,
    }, function(language)
      if not language then
        callback(nil)
        return
      end
      state.spring_language = language
      local packaging_options = metadata.values(client, "packaging")
      require("duke.picker").select_one(packaging_options, {
        prompt = "Spring packaging",
        default = config.spring.packaging,
      }, function(packaging)
        if packaging then
          state.spring_packaging = packaging
          callback(state)
        else
          callback(nil)
        end
      end)
    end)
  end
end

-- Pre-built step sequences.

function M.maven_steps(config)
  local steps = {}
  if #config.maven.archetypes > 1 then
    steps[#steps + 1] = M.select_one(config.maven.archetypes, {
      prompt = "Maven archetype",
      default = config.maven.archetypes[1],
      format_item = function(item)
        return item.name or (item.group_id .. ":" .. item.artifact_id .. ":" .. item.version)
      end,
    }, "archetype")
  else
    steps[#steps + 1] = function(state, callback)
      state.archetype = config.maven.archetypes[1]
      callback(state)
    end
  end
  steps[#steps + 1] = M.project_dir(config)
  steps[#steps + 1] = M.coordinates(config)
  steps[#steps + 1] = M.package_name(config)
  steps[#steps + 1] = M.java_version(config)
  steps[#steps + 1] = M.runner_preview(config, "maven")
  steps[#steps + 1] = M.confirm("Review Maven project", function(state)
    return {
      { "Destination", vim.fs.joinpath(state.destination, state.artifact_id) },
      { "Coordinates", state.group_id .. ":" .. state.artifact_id },
      { "Package", state.package_name },
      {
        "Build system",
        "Maven - "
          .. (
            state.archetype and (state.archetype.name or state.archetype.artifact_id)
            or config.maven.archetypes[1].name
          ),
      },
      { "Java target", state.java_version },
      { "Runner JVM", state.maven_runner_version or "system" },
    }
  end)
  steps[#steps + 1] = M.runner_check(config, "maven")
  return steps
end

function M.gradle_steps(config)
  return {
    M.project_dir(config),
    M.coordinates(config),
    M.package_name(config),
    M.select_one(config.gradle.project_types, {
      prompt = "Gradle project type",
      default = config.gradle.default_project_type,
    }, "project_type"),
    M.select_one(config.gradle.languages, {
      prompt = "Gradle source language",
      default = "java",
    }, "language"),
    M.gradle_project_type(config),
    M.select_one(config.gradle.dsls, {
      prompt = "Gradle DSL",
      default = config.gradle.dsl,
    }, "dsl"),
    M.java_version(config),
    M.runner_preview(config, "gradle"),
    M.confirm("Review Gradle project", function(state)
      return {
        { "Destination", vim.fs.joinpath(state.destination, state.artifact_id) },
        { "Coordinates", state.group_id .. ":" .. state.artifact_id },
        { "Package", state.package_name },
        { "Build system", "Gradle - " .. state.project_type.name },
        { "Source language", state.language },
        { "Build DSL", state.dsl },
        { "Java target", state.java_version },
        { "Runner JVM", state.gradle_runner_version or "system" },
      }
    end),
    M.runner_check(config, "gradle"),
  }
end

function M.spring_steps(config)
  return {
    M.spring_metadata_fetch(config),
    function(state, callback)
      local metadata = require("duke.metadata")
      state._artifact_default = metadata.default(state.spring_client, "artifactId", "demo")
      callback(state)
    end,
    M.project_dir(config),
    M.coordinates(config),
    M.spring_java_version(config),
    M.spring_boot_version(config),
    M.spring_project_type(config),
    M.spring_fields(config),
    function(state, callback)
      -- fetch catalog between fields and dependency picker
      local metadata = require("duke.metadata")
      local url = config.spring.dependencies_url
        .. "?bootVersion="
        .. vim.uri_encode(state.boot_version)
      metadata.fetch_cached(
        url,
        metadata.cache_path("dependencies", state.boot_version, config.spring.dependencies_url),
        nil,
        function(catalog_error, catalog, source, fallback)
          if catalog_error then
            notify_error(catalog_error)
            callback(nil)
            return
          end
          if source == "cache" and fallback then
            notify(cache_fallback_message(fallback))
          end
          state.spring_catalog = catalog
          callback(state)
        end,
        metadata.is_catalog
      )
    end,
    M.spring_dependencies(config),
    M.spring_options(config),
    M.confirm("Review Spring project", function(state)
      return {
        { "Destination", vim.fs.joinpath(state.destination, state.artifact_id) },
        { "Coordinates", state.group_id .. ":" .. state.artifact_id },
        { "Name", state.name },
        { "Description", state.description == "" and "none" or state.description },
        { "Package", state.package_name },
        { "Build type", state.spring_project_type.build },
        { "Java target", state.java_version },
        { "Runner JVM", "not used during generation" },
        { "Spring Boot", state.boot_version },
        { "Language", state.spring_language },
        { "Packaging", state.spring_packaging },
        {
          "Dependencies",
          #(state.dependency_ids or {}) == 0 and "none" or table.concat(state.dependency_ids, ", "),
        },
      }
    end),
  }
end

return M
