local M = {}
local runtime_cache

local function notify_error(message)
  require("duke.log").add("ERROR", message)
  vim.notify("duke.nvim: " .. message, vim.log.levels.ERROR)
end

local function notify(message, level)
  vim.notify("duke.nvim: " .. message, level or vim.log.levels.INFO)
end

local function cache_fallback_message(fallback)
  local age = require("duke.metadata").format_age(fallback.age_seconds)
  if fallback.reason == "schema" then
    return "Initializr metadata schema not recognized; using cached data from " .. age
  end
  return "Spring Initializr unreachable; using cached data from " .. age
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

function M.new_module()
  local reactor_dir = vim.fn.getcwd()
  local wizard = require("duke.wizard")

  local function derive_package_default(artifact_id)
    local lines = require("duke.pom_file").read(vim.fs.joinpath(reactor_dir, "pom.xml"))
    if not lines then
      return ""
    end
    local reactor = require("duke.pom").reactor(lines)
    if not reactor then
      return ""
    end
    return require("duke.maven").package_name(reactor.group_id, artifact_id)
  end

  local steps = {
    wizard.input("Artifact ID: ", "", "artifact_id"),
    function(state, callback)
      local derived = derive_package_default(state.artifact_id)
      require("duke.picker").input("Package name: ", derived, function(value)
        if value == nil then
          callback(nil)
          return
        end
        value = vim.trim(value)
        if value == "" then
          value = derived ~= "" and derived or nil
        end
        state.package_name = value
        callback(state)
      end)
    end,
    wizard.confirm("Add Maven module", function(state)
      return {
        { "Reactor", reactor_dir },
        { "Artifact ID", state.artifact_id },
        { "Package", state.package_name or "derived from reactor" },
        { "Module directory", vim.fs.joinpath(reactor_dir, state.artifact_id or "") },
      }
    end),
  }

  wizard.sequence(steps, function(state)
    require("duke.api").add_module({
      reactor_dir = reactor_dir,
      artifact_id = state.artifact_id,
      package_name = state.package_name,
    }, function(result)
      if not result.ok then
        notify_error(result.error)
        return
      end
      local entry_file = require("duke.project").entry(result.module_dir)
      vim.cmd.edit(vim.fn.fnameescape(entry_file))
      notify("module ready: " .. result.module_dir)
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
  return require("duke.pom_file").read(path)
end

local function save_pom(path, lines, buffer, was_modified)
  local saved, err = require("duke.pom_file").save(path, lines, buffer, was_modified)
  if saved == nil then
    error(err)
  end
  return saved
end

local function installed_coordinates(lines)
  local dependencies, list_error = require("duke.pom").list(lines)
  if list_error then
    return nil, list_error
  end
  local installed = {}
  for _, dependency in ipairs(dependencies) do
    installed[dependency.group_id .. ":" .. dependency.artifact_id] = true
  end
  return installed
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
        local picker_lines = read_pom(pom_path)
        if not picker_lines then
          notify_error("cannot reread " .. pom_path)
          return
        end
        if require("duke.pom").spring_boot_version(picker_lines) then
          notify_error("pom.xml became a Spring Boot project; run command again")
          return
        end
        local installed, list_error = installed_coordinates(picker_lines)
        if list_error then
          notify_error(list_error)
          return
        end
        require("duke.picker").select_many(choices, {
          prompt = "Add Maven Central dependencies",
          format_item = function(item)
            local coordinate = item.group_id .. ":" .. item.artifact_id
            local suffix = installed[coordinate] and " [installed]" or ""
            return string.format("%s  %s%s", coordinate, item.version, suffix)
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
  fetch_client(function(client_error, client, client_source, client_fallback)
    if client_error then
      notify_error(client_error)
      return
    end
    if client_source == "cache" and client_fallback then
      notify(cache_fallback_message(client_fallback))
    end
    fetch_catalog(boot_version, function(catalog_error, catalog, catalog_source, catalog_fallback)
      if catalog_error then
        notify_error(catalog_error)
        return
      end
      if catalog_source == "cache" and catalog_fallback then
        notify(cache_fallback_message(catalog_fallback))
      end
      local picker_lines = read_pom(pom_path)
      if not picker_lines then
        notify_error("cannot reread " .. pom_path)
        return
      end
      local picker_boot_version = require("duke.pom").spring_boot_version(picker_lines)
      if picker_boot_version ~= boot_version then
        notify_error("pom.xml Spring Boot version changed; run command again")
        return
      end
      local installed, list_error = installed_coordinates(picker_lines)
      if list_error then
        notify_error(list_error)
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
          local coordinate = catalog.dependencies and catalog.dependencies[item.id]
          local key = coordinate and (coordinate.groupId .. ":" .. coordinate.artifactId)
          local suffix = key and installed[key] and " [installed]" or ""
          return string.format("%s  [%s]%s", item.name, item.group, suffix)
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

local function select_dependency_upgrade(pom_path, selected, available_versions)
  local versions = vim.deepcopy(available_versions)
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
    local updated, update_error = require("duke.pom").update_version(latest_lines, latest, version)
    if update_error then
      notify_error(update_error)
      return
    end
    local saved = save_pom(pom_path, updated, buffer, was_modified)
    local suffix = saved and "" or " (buffer left unsaved)"
    notify(string.format("updated %s to version %s%s", dependency_label(latest), version, suffix))
  end)
end

local function upgrade_dependency(pom_path, selected, available_versions)
  local property = selected.version:match("^%${([%w_.-]+)}$")
  if property then
    notify_error("cannot update dependency version property " .. property)
    return
  end
  if available_versions then
    select_dependency_upgrade(pom_path, selected, available_versions)
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
      select_dependency_upgrade(pom_path, selected, versions)
    end
  )
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
    upgrade_dependency(pom_path, selected)
  end)
end

function M.upgrade_boot_parent()
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
  local parent, parent_error = require("duke.pom").parent(lines)
  if not parent then
    notify_error(parent_error)
    return
  end
  local property = parent.version and parent.version:match("^%${([%w_.-]+)}$")
  if property then
    notify_error("cannot update parent version property " .. property)
    return
  end

  require("duke.maven_central").versions(
    "org.springframework.boot",
    "spring-boot-starter-parent",
    function(version_error, versions)
      if version_error then
        notify_error(version_error)
        return
      end
      if not versions or #versions == 0 then
        notify("no Maven Central versions found for spring-boot-starter-parent")
        return
      end
      local choices = vim.deepcopy(versions)
      if not vim.tbl_contains(choices, parent.version) then
        choices[#choices + 1] = parent.version
      end
      require("duke.picker").select_one(choices, {
        prompt = "Spring Boot parent version",
        default = choices[1],
        format_item = function(version)
          return version == parent.version and (version .. "  (current)") or version
        end,
      }, function(version)
        if not version then
          return
        end
        if version == parent.version then
          notify("Spring Boot parent already uses version " .. version)
          return
        end
        if
          not require("duke.picker").confirm(
            string.format("Upgrade Spring Boot parent %s -> %s?", parent.version, version),
            "Upgrade"
          )
        then
          return
        end

        local latest_lines, buffer, was_modified = read_pom(pom_path)
        if not latest_lines then
          notify_error("cannot reread " .. pom_path)
          return
        end
        local latest_parent, latest_error = require("duke.pom").parent(latest_lines)
        if not latest_parent then
          notify_error(latest_error)
          return
        end
        if latest_parent.version ~= parent.version then
          notify_error("pom.xml parent changed; run command again")
          return
        end
        local updated, update_error =
          require("duke.pom").update_version(latest_lines, latest_parent, version)
        if update_error then
          notify_error(update_error)
          return
        end
        local saved = save_pom(pom_path, updated, buffer, was_modified)
        local suffix = saved and "" or " (buffer left unsaved)"
        notify("upgraded Spring Boot parent to " .. version .. suffix)
      end)
    end
  )
end

local function skipped_outdated_notice(managed, property_backed)
  local parts = {}
  if managed > 0 then
    parts[#parts + 1] =
      string.format("%d managed %s", managed, managed == 1 and "dependency" or "dependencies")
  end
  if property_backed > 0 then
    parts[#parts + 1] = string.format(
      "%d property-backed %s",
      property_backed,
      property_backed == 1 and "dependency" or "dependencies"
    )
  end
  return table.concat(parts, " and ") .. " skipped"
end

function M.outdated_dependencies()
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
  local skipped = managed + property_backed
  if #candidates == 0 then
    if skipped > 0 then
      notify(skipped_outdated_notice(managed, property_backed) .. "; no dependencies to check")
    else
      notify("no root dependencies with literal explicit versions found")
    end
    return
  end
  if skipped > 0 then
    notify(skipped_outdated_notice(managed, property_backed))
  end

  local outdated = {}
  local checked = 0
  local index = 1
  local function present(unchecked, lookup_error)
    if unchecked > 0 then
      local noun = unchecked == 1 and "dependency" or "dependencies"
      notify(
        string.format(
          "%d %s not checked after Maven Central error: %s",
          unchecked,
          noun,
          lookup_error
        ),
        vim.log.levels.WARN
      )
    end
    if #outdated == 0 then
      if unchecked == 0 then
        notify(string.format("%d dependencies checked, all up to date", checked))
      end
      return
    end
    require("duke.picker").select_one(outdated, {
      prompt = "Outdated Maven dependencies",
      format_item = function(item)
        return string.format(
          "%s  %s -> %s",
          dependency_label(item.dependency),
          item.dependency.version,
          item.latest
        )
      end,
    }, function(selected)
      if selected then
        upgrade_dependency(pom_path, selected.dependency, selected.versions)
      end
    end)
  end

  local function inspect_next()
    if index > #candidates then
      present(0)
      return
    end
    local dependency = candidates[index]
    require("duke.maven_central").versions(
      dependency.group_id,
      dependency.artifact_id,
      function(version_error, versions)
        if version_error then
          present(#candidates - index + 1, version_error)
          return
        end
        checked = checked + 1
        local latest = versions[1]
        if latest and latest ~= dependency.version then
          outdated[#outdated + 1] = {
            dependency = dependency,
            latest = latest,
            versions = versions,
          }
        end
        index = index + 1
        inspect_next()
      end
    )
  end
  inspect_next()
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

function M.create(kind, opts, callback)
  require("duke.api").create(kind, opts, callback)
end

function M.add(opts, callback)
  require("duke.api").add(opts, callback)
end

function M.add_module(opts, callback)
  require("duke.api").add_module(opts, callback)
end

function M.upgrade(opts, callback)
  require("duke.api").upgrade(opts, callback)
end

function M.upgrade_parent(opts, callback)
  require("duke.api").upgrade_parent(opts, callback)
end

function M.outdated(opts, callback)
  require("duke.api").outdated(opts, callback)
end

function M.remove(opts, callback)
  require("duke.api").remove(opts, callback)
end

return M
