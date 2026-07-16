local M = {}
local runtime_cache

local function notify_error(message)
  require("java_scaffold.log").add("ERROR", message)
  vim.notify("java-scaffold.nvim: " .. message, vim.log.levels.ERROR)
end

local function notify(message, level)
  vim.notify("java-scaffold.nvim: " .. message, level or vim.log.levels.INFO)
end

local function finish_project(project_dir)
  local config = require("java_scaffold.config").get()
  local entry_file = require("java_scaffold.project").entry(project_dir)
  if config.entry_selector then
    local ok, selected = pcall(config.entry_selector, project_dir, entry_file)
    if ok and type(selected) == "string" and selected ~= "" then
      entry_file = selected
    elseif not ok then
      require("java_scaffold.log").add("WARN", "entry_selector failed: " .. tostring(selected))
    end
  end
  vim.cmd.cd(vim.fn.fnameescape(project_dir))
  local event_ok, event_error = pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "JavaScaffoldProjectCreated",
    data = { project_dir = project_dir, entry_file = entry_file },
  })
  if not event_ok then
    require("java_scaffold.log").add(
      "WARN",
      "project-created event failed: " .. tostring(event_error)
    )
  end
  require("java_scaffold.handoff").open(project_dir, config.handoff, function(err, opened)
    if opened then
      notify("project ready: " .. project_dir)
      return
    end
    if err then
      require("java_scaffold.log").add("WARN", err)
      notify(err .. "; opening in current Neovim", vim.log.levels.WARN)
    end
    vim.cmd.edit(vim.fn.fnameescape(entry_file))
  end, entry_file)
end

function M.setup(opts)
  require("java_scaffold.config").setup(opts)
  runtime_cache = nil
end

function M.java_runtimes(opts)
  opts = opts or {}
  if opts.refresh then
    runtime_cache = nil
  end
  if not runtime_cache then
    local java = require("java_scaffold.java")
    local config = require("java_scaffold.config").get()
    runtime_cache = {
      active = java.active(),
      homes = java.discover_homes(config.java_homes),
    }
  end
  return vim.deepcopy(runtime_cache)
end

function M.select_runtime(opts)
  if opts ~= nil and type(opts) ~= "table" then
    return nil
  end
  opts = opts or {}
  local minimum = opts.min_version == nil and 0 or tonumber(opts.min_version)
  if not minimum or minimum < 0 or minimum % 1 ~= 0 then
    return nil
  end

  local runtimes = M.java_runtimes()
  local function selected(version)
    version = version and tostring(version) or nil
    local home = version and runtimes.homes[version] or nil
    if not home or tonumber(version) < minimum then
      return nil
    end
    return {
      version = version,
      home = home,
      executable = vim.fs.joinpath(home, "bin", "java"),
    }
  end

  if opts.prefer_active ~= false then
    local active = selected(runtimes.active)
    if active then
      return active
    end
  end

  local candidate
  for version in pairs(runtimes.homes) do
    local numeric = tonumber(version)
    if numeric and numeric >= minimum and (not candidate or numeric < tonumber(candidate)) then
      candidate = tostring(version)
    end
  end
  return selected(candidate)
end

function M.new()
  local workflows = {
    { id = "maven", name = "Maven quickstart" },
    { id = "gradle", name = "Gradle Java" },
    { id = "spring", name = "Spring Boot" },
  }
  require("java_scaffold.picker").select_one(workflows, {
    prompt = "Project generator",
    default = "maven",
    format_item = function(item)
      return item.name
    end,
  }, function(selected)
    if selected then
      M["new_" .. selected.id]()
    end
  end)
end

function M.new_maven()
  local config = require("java_scaffold.config").get()
  local wizard = require("java_scaffold.wizard")

  wizard.sequence(wizard.maven_steps(config), function(state)
    require("java_scaffold.maven").create({
      command = config.maven.command,
      cwd = state.destination,
      group_id = state.group_id,
      artifact_id = state.artifact_id,
      package_name = state.package_name,
      version = config.maven.project_version,
      wrapper = config.maven.wrapper,
      java_version = state.java_version,
      archetype = state.archetype,
      timeout = config.maven.timeout,
      env = state.maven_runner_env,
    }, function(err, project_dir)
      if err then
        notify_error(err)
        return
      end
      finish_project(project_dir)
    end)
  end)
end

function M.new_gradle()
  local config = require("java_scaffold.config").get()
  local wizard = require("java_scaffold.wizard")

  wizard.sequence(wizard.gradle_steps(config), function(state)
    local init_type =
      require("java_scaffold.gradle").project_type(state.language, state.project_type.id)
    if not init_type then
      notify_error("unsupported Gradle source language and project type combination")
      return
    end
    require("java_scaffold.gradle").create({
      command = config.gradle.command,
      cwd = state.destination,
      group_id = state.group_id,
      artifact_id = state.artifact_id,
      package_name = state.package_name,
      java_version = state.java_version,
      project_type = init_type,
      dsl = state.dsl,
      test_framework = config.gradle.test_framework,
      timeout = config.gradle.timeout,
      env = state.gradle_runner_env,
    }, function(err, project_dir)
      if err then
        notify_error(err)
        return
      end
      finish_project(project_dir)
    end)
  end)
end

local function fetch_client(callback)
  local config = require("java_scaffold.config").get()
  require("java_scaffold.metadata").fetch_cached(
    config.spring.metadata_url,
    require("java_scaffold.metadata").cache_path("metadata", nil, config.spring.metadata_url),
    nil,
    callback,
    require("java_scaffold.metadata").is_client
  )
end

local function fetch_catalog(boot_version, callback)
  local config = require("java_scaffold.config").get()
  local url = config.spring.dependencies_url .. "?bootVersion=" .. vim.uri_encode(boot_version)
  require("java_scaffold.metadata").fetch_cached(
    url,
    require("java_scaffold.metadata").cache_path(
      "dependencies",
      boot_version,
      config.spring.dependencies_url
    ),
    nil,
    callback,
    require("java_scaffold.metadata").is_catalog
  )
end

function M.new_spring()
  local config = require("java_scaffold.config").get()
  local wizard = require("java_scaffold.wizard")

  wizard.sequence(wizard.spring_steps(config), function(state)
    require("java_scaffold.spring").create({
      url = config.spring.starter_url,
      cwd = state.destination,
      group_id = state.group_id,
      artifact_id = state.artifact_id,
      name = state.name,
      description = state.description,
      package_name = state.package_name,
      java_version = state.java_version,
      boot_version = state.boot_version,
      dependencies = state.dependency_ids,
      project_type = state.spring_project_type.id,
      build = state.spring_project_type.build,
      language = state.spring_language,
      packaging = state.spring_packaging,
      timeout = config.spring.timeout,
    }, function(err, project_dir)
      if err then
        notify_error(err)
        return
      end
      finish_project(project_dir)
    end)
  end)
end

function M.clear_cache()
  local ok, err = require("java_scaffold.metadata").clear_cache()
  if not ok then
    notify_error(err)
    return false
  end
  notify("Initializr cache cleared")
  return true
end

local function nearest_pom()
  local buffer_path = vim.api.nvim_buf_get_name(0)
  local start = buffer_path ~= "" and vim.fs.dirname(buffer_path) or vim.fn.getcwd()
  return vim.fs.find("pom.xml", { upward = true, path = start })[1]
end

local function read_pom(path)
  local buffer = vim.fn.bufnr(path)
  if buffer ~= -1 and vim.api.nvim_buf_is_loaded(buffer) then
    return vim.api.nvim_buf_get_lines(buffer, 0, -1, false), buffer, vim.bo[buffer].modified
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  return lines
end

local function save_pom(path, lines, buffer, was_modified)
  if buffer then
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    if was_modified then
      return false
    end
    vim.api.nvim_buf_call(buffer, function()
      vim.cmd("silent write")
    end)
    return true
  end
  vim.fn.writefile(lines, path)
  return true
end

local function insert_maven_dependencies(pom_path, selected)
  local maven = require("java_scaffold.maven")
  for _, dependency in ipairs(selected) do
    local coordinate_error = maven.validate(dependency.group_id, dependency.artifact_id)
    if coordinate_error then
      notify_error("invalid Maven Central coordinate: " .. coordinate_error)
      return
    end
  end
  local latest_lines, buffer, was_modified = read_pom(pom_path)
  if not latest_lines then
    notify_error("cannot reread " .. pom_path)
    return
  end
  if require("java_scaffold.pom").spring_boot_version(latest_lines) then
    notify_error("pom.xml became a Spring Boot project; run command again")
    return
  end
  local updated, added, insert_error = require("java_scaffold.pom").insert(latest_lines, selected)
  if insert_error then
    notify_error(insert_error)
    return
  end
  if added == 0 then
    notify("selected dependencies already exist")
    return
  end
  local saved = save_pom(pom_path, updated, buffer, was_modified)
  local suffix = saved and "" or " (buffer left unsaved)"
  notify(string.format("added %d dependencies%s", added, suffix))
end

local function choose_maven_versions(pom_path, selected)
  if #selected ~= 1 then
    insert_maven_dependencies(pom_path, selected)
    return
  end
  local dependency = selected[1]
  require("java_scaffold.maven_central").versions(
    dependency.group_id,
    dependency.artifact_id,
    function(err, versions)
      if err then
        notify_error(err)
        return
      end
      if #versions == 0 then
        versions = { dependency.version }
      elseif not vim.tbl_contains(versions, dependency.version) then
        table.insert(versions, 1, dependency.version)
      end
      require("java_scaffold.picker").select_one(versions, {
        prompt = "Maven Central version",
        default = dependency.version,
      }, function(version)
        if not version then
          return
        end
        local chosen = vim.deepcopy(dependency)
        chosen.version = version
        insert_maven_dependencies(pom_path, { chosen })
      end)
    end
  )
end

function M.add_dependency()
  local pom_path = nearest_pom()
  if not pom_path then
    notify_error("no pom.xml found in current directory or parents")
    return
  end
  local lines = read_pom(pom_path)
  if not lines then
    notify_error("cannot read " .. pom_path)
    return
  end
  local boot_version = require("java_scaffold.pom").spring_boot_version(lines)
  if not boot_version then
    require("java_scaffold.picker").input("Maven Central search: ", "", function(term)
      if not term or vim.trim(term) == "" then
        return
      end
      term = vim.trim(term)
      notify("searching Maven Central for " .. term)
      require("java_scaffold.maven_central").search(term, function(search_error, choices)
        if search_error then
          notify_error(search_error)
          return
        end
        if #choices == 0 then
          notify("no Maven Central dependencies found")
          return
        end
        require("java_scaffold.picker").select_many(choices, {
          prompt = "Add Maven Central dependencies",
          format_item = function(item)
            return string.format("%s:%s  %s", item.group_id, item.artifact_id, item.version)
          end,
        }, function(selected)
          if not selected or #selected == 0 then
            return
          end
          choose_maven_versions(pom_path, selected)
        end)
      end)
    end)
    return
  end

  notify("loading dependencies for Spring Boot " .. boot_version)
  fetch_client(function(client_error, client)
    if client_error then
      notify_error(client_error)
      return
    end
    fetch_catalog(boot_version, function(catalog_error, catalog)
      if catalog_error then
        notify_error(catalog_error)
        return
      end
      local metadata = require("java_scaffold.metadata")
      local choices = {}
      for _, item in ipairs(metadata.flatten_dependencies(client)) do
        local coordinate = catalog.dependencies and catalog.dependencies[item.id]
        if metadata.is_direct(coordinate) then
          choices[#choices + 1] = item
        end
      end
      require("java_scaffold.picker").select_many(choices, {
        prompt = "Add Spring dependencies",
        format_item = function(item)
          return string.format("%s  [%s]", item.name, item.group)
        end,
      }, function(selected)
        if not selected or #selected == 0 then
          return
        end
        local ids = vim.tbl_map(function(item)
          return item.id
        end, selected)
        local dependencies, missing = metadata.resolve(catalog, ids)
        if #missing > 0 then
          notify_error("dependency coordinates unavailable: " .. table.concat(missing, ", "))
          return
        end
        local latest_lines, buffer, was_modified = read_pom(pom_path)
        if not latest_lines then
          notify_error("cannot reread " .. pom_path)
          return
        end
        local latest_boot_version = require("java_scaffold.pom").spring_boot_version(latest_lines)
        if latest_boot_version ~= boot_version then
          notify_error("pom.xml Spring Boot version changed; run command again")
          return
        end
        local updated, added, insert_error =
          require("java_scaffold.pom").insert(latest_lines, dependencies)
        if insert_error then
          notify_error(insert_error)
          return
        end
        if added == 0 then
          notify("selected dependencies already exist")
          return
        end
        local saved = save_pom(pom_path, updated, buffer, was_modified)
        local suffix = saved and "" or " (buffer left unsaved)"
        notify(string.format("added %d dependencies%s", added, suffix))
      end)
    end)
  end)
end

return M
