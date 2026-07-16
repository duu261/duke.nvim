local M = {}
local runtime_cache

local function notify_error(message)
  require("duke.log").add("ERROR", message)
  vim.notify("duke.nvim: " .. message, vim.log.levels.ERROR)
end

local function notify(message, level)
  vim.notify("duke.nvim: " .. message, level or vim.log.levels.INFO)
end

local function finish_project(project_dir)
  local config = require("duke.config").get()
  local entry_file = require("duke.project").entry(project_dir)
  if config.entry_selector then
    local ok, selected = pcall(config.entry_selector, project_dir, entry_file)
    if ok and type(selected) == "string" and selected ~= "" then
      entry_file = selected
    elseif not ok then
      require("duke.log").add("WARN", "entry_selector failed: " .. tostring(selected))
    end
  end
  vim.cmd.cd(vim.fn.fnameescape(project_dir))
  local event_ok, event_error = pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "DukeProjectCreated",
    data = { project_dir = project_dir, entry_file = entry_file },
  })
  if not event_ok then
    require("duke.log").add("WARN", "project-created event failed: " .. tostring(event_error))
  end
  require("duke.handoff").open(project_dir, config.handoff, function(err, opened)
    if opened then
      notify("project ready: " .. project_dir)
      return
    end
    if err then
      require("duke.log").add("WARN", err)
      notify(err .. "; opening in current Neovim", vim.log.levels.WARN)
    end
    vim.cmd.edit(vim.fn.fnameescape(entry_file))
  end, entry_file)
end

function M.setup(opts)
  require("duke.config").setup(opts)
  runtime_cache = nil
end

function M.java_runtimes(opts)
  opts = opts or {}
  if opts.refresh then
    runtime_cache = nil
  end
  if not runtime_cache then
    local java = require("duke.java")
    local config = require("duke.config").get()
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
  require("duke.picker").select_one(workflows, {
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
  local config = require("duke.config").get()
  local wizard = require("duke.wizard")

  wizard.sequence(wizard.maven_steps(config), function(state)
    require("duke.maven").create({
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
  local config = require("duke.config").get()
  local wizard = require("duke.wizard")

  wizard.sequence(wizard.gradle_steps(config), function(state)
    require("duke.gradle").create({
      command = config.gradle.command,
      cwd = state.destination,
      group_id = state.group_id,
      artifact_id = state.artifact_id,
      package_name = state.package_name,
      java_version = state.java_version,
      project_type = state.gradle_project_type,
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
  local config = require("duke.config").get()
  require("duke.metadata").fetch_cached(
    config.spring.metadata_url,
    require("duke.metadata").cache_path("metadata", nil, config.spring.metadata_url),
    nil,
    callback,
    require("duke.metadata").is_client
  )
end

local function fetch_catalog(boot_version, callback)
  local config = require("duke.config").get()
  local url = config.spring.dependencies_url .. "?bootVersion=" .. vim.uri_encode(boot_version)
  require("duke.metadata").fetch_cached(
    url,
    require("duke.metadata").cache_path(
      "dependencies",
      boot_version,
      config.spring.dependencies_url
    ),
    nil,
    callback,
    require("duke.metadata").is_catalog
  )
end

function M.new_spring()
  local config = require("duke.config").get()
  local wizard = require("duke.wizard")

  wizard.sequence(wizard.spring_steps(config), function(state)
    require("duke.spring").create({
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
  local ok, err = require("duke.metadata").clear_cache()
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
  local maven = require("duke.maven")
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
  if require("duke.pom").spring_boot_version(latest_lines) then
    notify_error("pom.xml became a Spring Boot project; run command again")
    return
  end
  local updated, added, insert_error = require("duke.pom").insert(latest_lines, selected)
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
  require("duke.maven_central").versions(
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
      require("duke.picker").select_one(versions, {
        prompt = "Maven Central version",
        default = dependency.version,
      }, function(version)
        if not version then
          return
        end
        local chosen = vim.deepcopy(dependency)
        chosen.version = version
        require("duke.picker").select_one({ "compile", "test", "provided", "runtime" }, {
          prompt = "Maven dependency scope",
          default = "compile",
        }, function(scope)
          if not scope then
            return
          end
          if scope ~= "compile" then
            chosen.scope = scope
          end
          insert_maven_dependencies(pom_path, { chosen })
        end)
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
  local boot_version = require("duke.pom").spring_boot_version(lines)
  if not boot_version then
    require("duke.picker").input("Maven Central search: ", "", function(term)
      if not term or vim.trim(term) == "" then
        return
      end
      term = vim.trim(term)
      notify("searching Maven Central for " .. term)
      require("duke.maven_central").search(term, function(search_error, choices)
        if search_error then
          notify_error(search_error)
          return
        end
        if #choices == 0 then
          notify("no Maven Central dependencies found")
          return
        end
        require("duke.picker").select_many(choices, {
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
      local metadata = require("duke.metadata")
      local choices = {}
      for _, item in ipairs(metadata.flatten_dependencies(client)) do
        local coordinate = catalog.dependencies and catalog.dependencies[item.id]
        if metadata.is_direct(coordinate) then
          choices[#choices + 1] = item
        end
      end
      require("duke.picker").select_many(choices, {
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
        local latest_boot_version = require("duke.pom").spring_boot_version(latest_lines)
        if latest_boot_version ~= boot_version then
          notify_error("pom.xml Spring Boot version changed; run command again")
          return
        end
        local updated, added, insert_error = require("duke.pom").insert(latest_lines, dependencies)
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

local function dependency_label(dependency)
  return dependency.group_id .. ":" .. dependency.artifact_id
end

local function same_dependency(left, right)
  return left
    and right
    and left.group_id == right.group_id
    and left.artifact_id == right.artifact_id
end

function M.update_dependency()
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
  local dependencies, list_error = require("duke.pom").list(lines)
  if list_error then
    notify_error(list_error)
    return
  end

  local choices = {}
  local hidden = 0
  for _, dependency in ipairs(dependencies) do
    if dependency.version then
      choices[#choices + 1] = dependency
    else
      hidden = hidden + 1
    end
  end
  if hidden > 0 then
    local noun = hidden == 1 and "dependency" or "dependencies"
    notify(
      string.format("%d managed %s hidden because no explicit version is present", hidden, noun)
    )
  end
  if #choices == 0 then
    notify("no root dependencies with explicit versions found")
    return
  end

  require("duke.picker").select_one(choices, {
    prompt = "Update Maven dependency",
    format_item = function(dependency)
      return string.format("%s  %s", dependency_label(dependency), dependency.version)
    end,
  }, function(selected)
    if not selected then
      return
    end
    local property = selected.version:match("^%${([%w_.-]+)}$")
    if property then
      notify_error("cannot update dependency version property " .. property)
      return
    end

    require("duke.maven_central").versions(
      selected.group_id,
      selected.artifact_id,
      function(version_error, versions)
        if version_error then
          notify_error(version_error)
          return
        end
        if #versions == 0 then
          notify("no Maven Central versions found for " .. dependency_label(selected))
          return
        end
        if not vim.tbl_contains(versions, selected.version) then
          versions[#versions + 1] = selected.version
        end
        require("duke.picker").select_one(versions, {
          prompt = "Maven Central version",
          default = versions[1],
          format_item = function(version)
            return version == selected.version and (version .. "  (current)") or version
          end,
        }, function(version)
          if not version then
            return
          end
          if version == selected.version then
            notify(dependency_label(selected) .. " already uses version " .. version)
            return
          end

          local latest_lines, buffer, was_modified = read_pom(pom_path)
          if not latest_lines then
            notify_error("cannot reread " .. pom_path)
            return
          end
          local latest_dependencies, latest_error = require("duke.pom").list(latest_lines)
          if latest_error then
            notify_error(latest_error)
            return
          end
          local latest = latest_dependencies[selected.index]
          if not same_dependency(latest, selected) or latest.version ~= selected.version then
            notify_error("pom.xml dependency changed; run command again")
            return
          end
          local updated, update_error =
            require("duke.pom").update_version(latest_lines, latest, version)
          if update_error then
            notify_error(update_error)
            return
          end
          local saved = save_pom(pom_path, updated, buffer, was_modified)
          local suffix = saved and "" or " (buffer left unsaved)"
          notify(
            string.format("updated %s to version %s%s", dependency_label(latest), version, suffix)
          )
        end)
      end
    )
  end)
end

function M.remove_dependency()
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
  local dependencies, list_error = require("duke.pom").list(lines)
  if list_error then
    notify_error(list_error)
    return
  end
  if #dependencies == 0 then
    notify("no root dependencies found")
    return
  end

  require("duke.picker").select_many(dependencies, {
    prompt = "Remove Maven dependencies",
    format_item = dependency_label,
  }, function(selected)
    if not selected or #selected == 0 then
      return
    end
    local labels = vim.tbl_map(function(dependency)
      return "- " .. dependency_label(dependency)
    end, selected)
    local confirmation = "Remove dependencies?\n\n" .. table.concat(labels, "\n")
    if not require("duke.picker").confirm(confirmation, "Remove") then
      return
    end

    local latest_lines, buffer, was_modified = read_pom(pom_path)
    if not latest_lines then
      notify_error("cannot reread " .. pom_path)
      return
    end
    local latest_dependencies, latest_error = require("duke.pom").list(latest_lines)
    if latest_error then
      notify_error(latest_error)
      return
    end
    local latest_selected = {}
    for _, dependency in ipairs(selected) do
      local latest = latest_dependencies[dependency.index]
      if not same_dependency(latest, dependency) then
        notify_error("pom.xml dependencies changed; run command again")
        return
      end
      latest_selected[#latest_selected + 1] = latest
    end

    local updated, removed, remove_error = require("duke.pom").remove(latest_lines, latest_selected)
    if remove_error then
      notify_error(remove_error)
      return
    end
    local saved = save_pom(pom_path, updated, buffer, was_modified)
    local suffix = saved and "" or " (buffer left unsaved)"
    notify(string.format("removed %d dependencies%s", removed, suffix))
  end)
end

return M
