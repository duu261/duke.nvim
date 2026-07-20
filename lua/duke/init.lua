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
  return require("duke.creation").open({})
end

function M.new_maven()
  return require("duke.creation").open({ kind = "maven" })
end

function M.new_gradle()
  return require("duke.creation").open({ kind = "gradle" })
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
  return require("duke.creation").open({ kind = "spring" })
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

local function save_pom(path, lines, buffer, was_modified, event)
  local saved, err = require("duke.pom_file").save(path, lines, buffer, was_modified)
  if saved == nil then
    error(err)
  end
  require("duke.events").build_changed(path, event.operation, {
    coordinates = event.coordinates,
    saved = saved,
  })
  return saved
end

local function dependency_coordinates(dependencies)
  return vim.tbl_map(function(dependency)
    return dependency.group_id .. ":" .. dependency.artifact_id
  end, dependencies)
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

local function dependency_summary(dependency)
  local coordinate = dependency.group_id .. ":" .. dependency.artifact_id
  if dependency.version then
    coordinate = coordinate .. ":" .. dependency.version
  end
  if dependency.scope then
    coordinate = coordinate .. " [" .. dependency.scope .. "]"
  end
  return coordinate
end

local function confirm_dependency_add(dependencies)
  local lines = { "Add dependencies to pom.xml?" }
  for _, dependency in ipairs(dependencies) do
    lines[#lines + 1] = dependency_summary(dependency)
  end
  return require("duke.picker").confirm(table.concat(lines, "\n"), "Add")
end

local function dependencies_not_installed(lines, dependencies)
  local installed, list_error = installed_coordinates(lines)
  if list_error then
    return nil, list_error
  end
  local result = {}
  for _, dependency in ipairs(dependencies) do
    local key = dependency.group_id .. ":" .. dependency.artifact_id
    if not installed[key] then
      result[#result + 1] = dependency
    end
  end
  return result
end

local function added_message(added, dependencies, suffix)
  if added ~= #dependencies then
    return string.format("added %d dependencies%s", added, suffix)
  end
  local coordinates = vim.tbl_map(dependency_summary, dependencies)
  return string.format("added %s%s", table.concat(coordinates, ", "), suffix)
end

local function insert_maven_dependencies(pom_path, selected)
  local maven = require("duke.maven")
  for _, dependency in ipairs(selected) do
    local coordinate_error = maven.validate(dependency.group_id, dependency.artifact_id)
    if coordinate_error then
      notify_error("invalid Maven Central coordinate: " .. coordinate_error)
      return
    end
    dependency.description = nil
    dependency.timestamp = nil
  end
  if not confirm_dependency_add(selected) then
    return
  end
  local latest_lines, buffer, was_modified = read_pom(pom_path)
  if not latest_lines then
    notify_error("cannot reread " .. pom_path)
    return
  end
  local expected_added, list_error = dependencies_not_installed(latest_lines, selected)
  if list_error then
    notify_error(list_error)
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
  local saved = save_pom(pom_path, updated, buffer, was_modified, {
    operation = "add_dependency",
    coordinates = dependency_coordinates(expected_added),
  })
  local suffix = saved and "" or " (buffer left unsaved)"
  notify(added_message(added, expected_added, suffix))
end

local function fetch_versions_display(group_id, artifact_id, callback)
  local maven = require("duke.maven_central")
  if maven.versions_display then
    maven.versions_display(group_id, artifact_id, callback)
  else
    maven.versions(group_id, artifact_id, function(err, versions)
      if err then
        callback(err)
        return
      end
      local items = {}
      for _, v in ipairs(versions) do
        items[#items + 1] = { value = v, name = v }
      end
      callback(nil, items)
    end)
  end
end

local function choose_maven_versions(pom_path, selected)
  if #selected ~= 1 then
    insert_maven_dependencies(pom_path, selected)
    return
  end
  local dependency = selected[1]
  fetch_versions_display(dependency.group_id, dependency.artifact_id, function(err, versions)
    if err then
      notify_error(err)
      return
    end
    if #versions == 0 then
      versions = { { name = dependency.version, value = dependency.version } }
    elseif
      not vim.tbl_contains(
        vim.tbl_map(function(v)
          return v.value
        end, versions),
        dependency.version
      )
    then
      table.insert(versions, 1, { name = dependency.version, value = dependency.version })
    end
    require("duke.picker").select_one(versions, {
      prompt = "Maven Central version for " .. dependency.group_id .. ":" .. dependency.artifact_id,
      default = dependency.version,
    }, function(item)
      if not item then
        return
      end
      local chosen = vim.deepcopy(dependency)
      chosen.version = item.value or item
      require("duke.picker").select_one({ "compile", "test", "provided", "runtime" }, {
        prompt = "Maven dependency scope for "
          .. chosen.group_id
          .. ":"
          .. chosen.artifact_id
          .. ":"
          .. chosen.version,
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
  end)
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
            return require("duke.picker").format_dependency({
              group_id = item.group_id,
              artifact_id = item.artifact_id,
              version = item.version,
              installed = installed[coordinate] == true,
            })
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

  local progress =
    require("duke.progress").task("Loading dependencies for Spring Boot " .. boot_version)
  fetch_client(function(client_error, client, client_source, client_fallback)
    if client_error then
      progress:fail()
      notify_error(client_error)
      return
    end
    if client_source == "cache" and client_fallback then
      notify(cache_fallback_message(client_fallback))
    end
    fetch_catalog(boot_version, function(catalog_error, catalog, catalog_source, catalog_fallback)
      if catalog_error then
        progress:fail()
        notify_error(catalog_error)
        return
      end
      if catalog_source == "cache" and catalog_fallback then
        notify(cache_fallback_message(catalog_fallback))
      end
      local picker_lines = read_pom(pom_path)
      if not picker_lines then
        progress:fail()
        notify_error("cannot reread " .. pom_path)
        return
      end
      local picker_boot_version = require("duke.pom").spring_boot_version(picker_lines)
      if picker_boot_version ~= boot_version then
        progress:fail()
        notify_error("pom.xml Spring Boot version changed; run command again")
        return
      end
      local installed, list_error = installed_coordinates(picker_lines)
      if list_error then
        progress:fail()
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
      progress:done()
      require("duke.picker").select_many(choices, {
        prompt = "Add Spring dependencies",
        format_item = function(item)
          local coordinate = catalog.dependencies and catalog.dependencies[item.id]
          local key = coordinate and (coordinate.groupId .. ":" .. coordinate.artifactId)
          return require("duke.picker").format_dependency({
            group_id = coordinate.groupId,
            artifact_id = coordinate.artifactId,
            label = item.name .. " [" .. item.group .. "]",
            installed = key and installed[key] == true,
          })
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
        if not confirm_dependency_add(dependencies) then
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
        local expected_added, latest_list_error =
          dependencies_not_installed(latest_lines, dependencies)
        if latest_list_error then
          notify_error(latest_list_error)
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
        local saved = save_pom(pom_path, updated, buffer, was_modified, {
          operation = "add_dependency",
          coordinates = dependency_coordinates(expected_added),
        })
        local suffix = saved and "" or " (buffer left unsaved)"
        notify(added_message(added, expected_added, suffix))
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

local function resolve_managed_dependencies(pom_path, dependencies, callback)
  local progress = require("duke.progress").task("Resolving managed dependencies")
  require("duke.managed").resolve(pom_path, dependencies, function(err, resolved)
    if err then
      progress:fail()
    else
      progress:done()
    end
    callback(err, resolved)
  end)
end

local function select_dependency_upgrade(pom_path, selected, available_versions)
  local versions = {}
  local seen = {}
  for _, v in ipairs(available_versions) do
    local value = type(v) == "table" and v.value or v
    local name = type(v) == "table" and v.name or v
    if not seen[value] then
      seen[value] = true
      versions[#versions + 1] = { value = value, name = name }
    end
  end
  if #versions == 0 then
    notify("no Maven Central versions found for " .. dependency_label(selected))
    return
  end
  if not seen[selected.version] then
    versions[#versions + 1] = {
      value = selected.version,
      name = selected.version .. "  (current)",
    }
  end
  require("duke.picker").select_one(versions, {
    prompt = "Maven Central version for " .. dependency_label(selected),
    default = versions[1].value,
    format_item = function(version)
      return version.value == versions[1].value and (version.name .. "  (latest)") or version.name
    end,
  }, function(item)
    if not item then
      return
    end
    local version = type(item) == "table" and (item.value or item) or item
    if version == selected.version then
      notify(dependency_label(selected) .. " already uses version " .. version)
      return
    end
    if selected.property then
      require("duke.change_plan").build({
        pom_path = pom_path,
        changes = { { coordinate = dependency_label(selected), new_version = version } },
      }, function(plan_error, descriptor)
        if plan_error then
          notify_error(plan_error)
          return
        end
        local affected = table.concat(descriptor.affected_coordinates, "\n")
        if
          not require("duke.picker").confirm(
            string.format(
              "Upgrade property %s?\n%s -> %s\nAffected dependencies:\n%s",
              selected.property,
              selected.version,
              version,
              affected
            ),
            "Upgrade"
          )
        then
          require("duke.change_plan").discard(descriptor)
          return
        end
        require("duke.change_plan").apply(descriptor, function(apply_error, result)
          if apply_error then
            notify_error(apply_error)
            return
          end
          local suffix = result.saved and "" or " (buffer left unsaved)"
          notify(
            string.format("updated %s to version %s%s", dependency_label(selected), version, suffix)
          )
        end)
      end)
      return
    end
    if
      not require("duke.picker").confirm(
        string.format(
          "Upgrade %s?\n%s -> %s",
          dependency_label(selected),
          selected.version,
          version
        ),
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
    local saved = save_pom(pom_path, updated, buffer, was_modified, {
      operation = "upgrade_dependency",
      coordinates = dependency_coordinates({ latest }),
    })
    local suffix = saved and "" or " (buffer left unsaved)"
    notify(string.format("updated %s to version %s%s", dependency_label(latest), version, suffix))
  end)
end

local function upgrade_dependency(pom_path, selected, available_versions)
  local property = selected.property
    or (selected.version and selected.version:match("^%${([%w_.-]+)}$"))
  if property and not selected.property then
    notify_error("cannot update dependency version property " .. property)
    return
  end
  if available_versions then
    select_dependency_upgrade(pom_path, selected, available_versions)
    return
  end
  fetch_versions_display(selected.group_id, selected.artifact_id, function(version_error, versions)
    if version_error then
      notify_error(version_error)
      return
    end
    select_dependency_upgrade(pom_path, selected, versions)
  end)
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
  local version_sources = require("duke.pom").dependency_version_sources(lines, dependencies)

  local explicit = {}
  local managed_deps = {}
  for _, dependency in ipairs(dependencies) do
    if dependency.version then
      local source = version_sources and version_sources[dependency]
      if source and source.kind == "property" then
        dependency.declared_version = dependency.version
        dependency.version = source.version
        dependency.property = source.property
      end
      explicit[#explicit + 1] = dependency
    else
      managed_deps[#managed_deps + 1] = dependency
    end
  end

  local managing_parent_name = nil
  if #managed_deps > 0 then
    local parent = require("duke.pom").parent(lines)
    if parent then
      managing_parent_name = parent.artifact_id
    end
  end

  local function show_picker(managed_notice)
    if managed_notice then
      notify(managed_notice, vim.log.levels.WARN)
    end
    local choices = {}
    for _, dep in ipairs(explicit) do
      choices[#choices + 1] = dep
    end
    for _, dep in ipairs(managed_deps) do
      if dep.version then
        choices[#choices + 1] = dep
      end
    end
    if #choices == 0 then
      notify("no root dependencies found")
      return
    end

    require("duke.picker").select_one(choices, {
      prompt = "Update Maven dependency",
      format_item = function(dependency)
        return require("duke.picker").format_dependency({
          group_id = dependency.group_id,
          artifact_id = dependency.artifact_id,
          version = dependency.version,
          managed_by = dependency.managed and (managing_parent_name or "parent POM") or nil,
        })
      end,
    }, function(selected)
      if not selected then
        return
      end
      if selected.managed then
        notify(
          string.format(
            "%s version is managed by %s; use :DukeBootUpgrade to upgrade the parent",
            dependency_label(selected),
            managing_parent_name or "parent POM"
          )
        )
        return
      end
      if not selected.version then
        notify_error(
          "cannot upgrade " .. dependency_label(selected) .. " without an explicit version"
        )
        return
      end
      upgrade_dependency(pom_path, selected)
    end)
  end

  if #managed_deps > 0 then
    resolve_managed_dependencies(pom_path, managed_deps, function(mvn_error, resolved)
      if mvn_error then
        local noun = #managed_deps == 1 and "dependency" or "dependencies"
        notify(
          string.format(
            "%d managed %s hidden because mvn dependency:list failed",
            #managed_deps,
            noun
          ),
          vim.log.levels.WARN
        )
        show_picker(nil)
        return
      end
      for _, dep in ipairs(managed_deps) do
        local key = dep.group_id .. ":" .. dep.artifact_id
        dep.version = resolved[key]
        dep.managed = true
      end
      show_picker(nil)
    end)
  else
    show_picker(nil)
  end
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
  local function raw_version_contains_property(pom_lines)
    local xml = table.concat(pom_lines, "\n")
    local parent = xml:match("<parent[^>]*>(.-)</parent>")
    if parent then
      local v = parent:match("<version>([^<]*)</version>")
      if v and v:find("${", 1, true) then
        return v
      end
    end
    local management = xml:match("<dependencyManagement%s*[^>]*>(.-)</dependencyManagement%s*>")
    if management then
      for dep in management:gmatch("<dependency%s*[^>]*>(.-)</dependency%s*>") do
        local g = dep:match("<groupId>([^<]*)</groupId>")
        local a = dep:match("<artifactId>([^<]*)</artifactId>")
        if g == "org.springframework.boot" and a == "spring-boot-dependencies" then
          local v = dep:match("<version>([^<]*)</version>")
          if v and v:find("${", 1, true) then
            return v
          end
        end
      end
    end
  end

  local property_version = raw_version_contains_property(lines)
  if property_version then
    local property = property_version:match("^%${([%w_.-]+)}$")
    if property then
      notify_error("cannot update Boot version property " .. property)
    else
      notify_error("cannot update Boot version containing property " .. property_version)
    end
    return
  end

  local boot_version = require("duke.pom").spring_boot_version(lines)
  if not boot_version then
    notify_error("no Spring Boot version found in parent or dependencyManagement")
    return
  end
  local parent, _ = require("duke.pom").parent(lines)
  local is_parent = parent
    and parent.group_id == "org.springframework.boot"
    and parent.artifact_id == "spring-boot-starter-parent"

  if not is_parent then
    notify(
      string.format(
        "Spring Boot %s managed by spring-boot-dependencies in dependencyManagement;"
          .. " upgrading the BOM version is not yet supported",
        boot_version
      )
    )
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
        local saved = save_pom(pom_path, updated, buffer, was_modified, {
          operation = "upgrade_parent",
          coordinates = { "org.springframework.boot:spring-boot-starter-parent" },
        })
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
  local managed_deps = {}
  local property_backed = 0
  local version_sources = require("duke.pom").dependency_version_sources(lines, dependencies)
  for _, dependency in ipairs(dependencies) do
    if not dependency.version then
      managed_deps[#managed_deps + 1] = dependency
    elseif dependency.version:find("${", 1, true) then
      local source = version_sources and version_sources[dependency]
      if source then
        dependency.declared_version = dependency.version
        dependency.version = source.version
        dependency.property = source.property
        candidates[#candidates + 1] = dependency
      else
        property_backed = property_backed + 1
      end
    else
      candidates[#candidates + 1] = dependency
    end
  end

  local managing_parent_name = nil
  if #managed_deps > 0 then
    local parent = require("duke.pom").parent(lines)
    if parent then
      managing_parent_name = parent.artifact_id
    end
  end

  local outdated = {}
  local checked = 0
  local index = 1
  local progress

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
        return require("duke.picker").format_dependency({
          group_id = item.dependency.group_id,
          artifact_id = item.dependency.artifact_id,
          version = item.dependency.version,
          latest_version = item.latest,
          managed_by = item.dependency.managed and (managing_parent_name or "parent") or nil,
        })
      end,
    }, function(selected)
      if selected then
        if selected.dependency.managed then
          notify(
            string.format(
              "%s version is managed by %s; use :DukeBootUpgrade to upgrade the parent",
              dependency_label(selected.dependency),
              managing_parent_name or "parent POM"
            )
          )
          return
        end
        upgrade_dependency(pom_path, selected.dependency, selected.versions)
      end
    end)
  end

  local function inspect_next()
    if index > #candidates then
      progress:done()
      present(0)
      return
    end
    local dependency = candidates[index]
    require("duke.maven_central").versions(
      dependency.group_id,
      dependency.artifact_id,
      function(version_error, versions)
        if version_error then
          progress:fail()
          present(#candidates - index + 1, version_error)
          return
        end
        checked = checked + 1
        progress:next()
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

  local function start_inspect(managed_skipped, managed_notice)
    if managed_notice then
      notify(managed_notice, vim.log.levels.WARN)
    end
    local skipped = managed_skipped + property_backed
    if #candidates == 0 then
      if skipped > 0 then
        notify(
          skipped_outdated_notice(managed_skipped, property_backed) .. "; no dependencies to check"
        )
      else
        notify("no root dependencies with literal explicit versions found")
      end
      return
    end
    if skipped > 0 then
      notify(skipped_outdated_notice(managed_skipped, property_backed))
    end
    progress = require("duke.progress").batch(#candidates, "Checking Maven Central")
    inspect_next()
  end

  if #managed_deps > 0 then
    resolve_managed_dependencies(pom_path, managed_deps, function(mvn_error, resolved)
      if mvn_error then
        start_inspect(#managed_deps, mvn_error)
      else
        local unresolved = 0
        for _, dep in ipairs(managed_deps) do
          local key = dep.group_id .. ":" .. dep.artifact_id
          local resolved_version = resolved[key]
          if resolved_version then
            dep.version = resolved_version
            dep.managed = true
            candidates[#candidates + 1] = dep
          else
            unresolved = unresolved + 1
          end
        end
        start_inspect(unresolved, nil)
      end
    end)
  else
    start_inspect(0, nil)
  end
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
    format_item = function(dependency)
      return require("duke.picker").format_dependency(dependency)
    end,
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
    local saved = save_pom(pom_path, updated, buffer, was_modified, {
      operation = "remove_dependency",
      coordinates = dependency_coordinates(latest_selected),
    })
    local suffix = saved and "" or " (buffer left unsaved)"
    notify(string.format("removed %d dependencies%s", removed, suffix))
  end)
end

local function render_scratch(lines, title)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "duke"
  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = buf, silent = true })
  local widest = 1
  for _, line in ipairs(lines) do
    widest = math.max(widest, vim.fn.strdisplaywidth(line))
  end
  local width = math.max(1, math.min(widest + 2, math.max(1, vim.o.columns - 4)))
  local height = math.max(1, math.min(#lines, math.max(1, vim.o.lines - 4)))
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "single",
    title = title,
    title_pos = "center",
  })
end

local function run_dependency_insight(pom_path, coordinate)
  local insight = require("duke.dependency_insight")
  if coordinate then
    coordinate = vim.trim(coordinate)
    local coordinate_error = insight.coordinate_error(coordinate)
    if coordinate_error then
      notify_error("invalid coordinate '" .. coordinate .. "'; " .. coordinate_error)
      return
    end
  end

  local label = coordinate and ("Resolving why " .. coordinate .. " is present")
    or "Resolving Maven dependency tree"
  local progress = require("duke.progress").task(label)
  local maven_config = require("duke.config").get().maven
  insight.inspect(pom_path, coordinate, {
    command = maven_config.command,
    timeout = maven_config.timeout,
  }, function(err, lines)
    if err then
      if coordinate and err:find("is not on the dependency tree", 1, true) then
        progress:done()
        notify(err)
      else
        progress:fail()
        notify_error(err)
      end
      return
    end
    progress:done()
    local title = coordinate and ("DukeWhy " .. coordinate) or "DukeTree"
    render_scratch(lines, title)
  end)
end

function M.dependency_tree()
  local pom_path = nearest_pom()
  if not pom_path then
    notify_error("no pom.xml found in current directory or parents")
    return
  end
  run_dependency_insight(pom_path)
end

local function input_dependency_why(pom_path)
  require("duke.picker").input("Maven coordinate (groupId:artifactId): ", "", function(input)
    if not input or vim.trim(input) == "" then
      return
    end
    run_dependency_insight(pom_path, input)
  end)
end

function M.dependency_why(coordinate)
  local pom_path = nearest_pom()
  if not pom_path then
    notify_error("no pom.xml found in current directory or parents")
    return
  end
  if coordinate then
    run_dependency_insight(pom_path, coordinate)
    return
  end

  local lines = read_pom(pom_path)
  if not lines then
    notify_error("cannot read " .. pom_path)
    return
  end
  local dependencies, list_error = require("duke.pom").list(lines)
  if list_error then
    require("duke.log").add("WARN", "cannot seed :DukeWhy picker: " .. list_error)
    input_dependency_why(pom_path)
    return
  end

  local custom = { custom = true }
  local choices = { custom }
  vim.list_extend(choices, dependencies)
  require("duke.picker").select_one(choices, {
    prompt = "Why is this dependency present?",
    default = custom,
    format_item = function(item)
      if item.custom then
        return "Enter another coordinate..."
      end
      return item.group_id .. ":" .. item.artifact_id
    end,
  }, function(selected)
    if not selected then
      return
    end
    if selected.custom then
      input_dependency_why(pom_path)
      return
    end
    run_dependency_insight(pom_path, selected.group_id .. ":" .. selected.artifact_id)
  end)
end

function M.help()
  render_scratch({
    "Duke commands",
    "Inside a Maven or Gradle workspace, :Duke opens Project Center.",
    "",
    "Create",
    "  :DukeNew          Choose Maven, Gradle, or Spring Boot",
    "  :DukeMaven        Create a Maven project",
    "  :DukeGradle       Create a Gradle project",
    "  :DukeSpring       Create a Spring Boot project",
    "  :DukeModule       Add a Maven reactor module",
    "",
    "Dependencies",
    "  :DukeAdd          Add dependencies",
    "  :DukeUpgrade      Upgrade one dependency",
    "  :DukeBootUpgrade  Upgrade Spring Boot parent",
    "  :DukeOutdated     Find outdated dependencies",
    "  :DukeRemove       Remove dependencies",
    "  :DukeTree         Show the resolved dependency tree",
    "  :DukeWhy          Explain why a dependency is present",
    "  :DukeDoctor       Diagnose and repair a Maven reactor",
    "",
    "Inspect",
    "  :DukeInfo         Show Maven Central versions",
    "  :DukeHealth       Check requirements",
    "  :DukeLog          Show operation details",
    "  :DukeClearCache   Clear Initializr cache",
    "",
    "Press q to close",
  }, "Duke")
end

local function show_coordinate_info(coord)
  local parts = vim.split(coord, ":", { plain = true })
  local group_id = parts[1]
  local artifact_id = parts[2]
  if not group_id or not artifact_id or group_id == "" or artifact_id == "" then
    notify_error("invalid coordinate '" .. coord .. "'; use groupId:artifactId")
    return
  end
  notify("looking up " .. coord)
  fetch_versions_display(group_id, artifact_id, function(err, items)
    if err then
      notify_error(err)
      return
    end
    local lines = {
      "Coordinate: " .. group_id .. ":" .. artifact_id,
      "Latest version: " .. (#items > 0 and items[1].name or "unknown"),
      "",
      "Recent versions:",
    }
    local count = math.min(#items, 15)
    for i = 1, count do
      lines[#lines + 1] = "  " .. items[i].name
    end
    if #items > count then
      lines[#lines + 1] = "  … and " .. (#items - count) .. " more"
    end
    if #items == 0 then
      lines[#lines + 1] = "  (none found)"
    end
    render_scratch(lines, "DukeInfo")
  end)
end

function M.info(coordinate)
  if coordinate then
    show_coordinate_info(coordinate)
    return
  end
  require("duke.picker").input("Maven coordinate (groupId:artifactId): ", "", function(input)
    if not input or vim.trim(input) == "" then
      return
    end
    show_coordinate_info(vim.trim(input))
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

function M.inspect(opts, callback)
  require("duke.api").inspect(opts, callback)
end

function M.project_center(opts)
  require("duke.project_center").toggle(opts)
end

function M.plan_upgrades(opts, callback)
  require("duke.api").plan_upgrades(opts, callback)
end

function M.apply_plan(plan, callback)
  require("duke.api").apply_plan(plan, callback)
end

function M.diagnose_workspace(opts, callback)
  require("duke.api").diagnose_workspace(opts, callback)
end

function M.plan_repairs(opts, callback)
  require("duke.api").plan_repairs(opts, callback)
end

function M.apply_reactor_plan(plan, callback)
  require("duke.api").apply_reactor_plan(plan, callback)
end

return M
