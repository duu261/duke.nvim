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

local function choose_java(available, configured, fallback, callback)
  if #available == 0 then
    callback(nil, "no Java versions available")
    return
  end
  local java = require("java_scaffold.java")
  local selected_default = java.default(configured, available, fallback)
  require("java_scaffold.picker").select_one(available, {
    prompt = "Java version",
    default = selected_default,
  }, function(selected)
    callback(selected)
  end)
end

local function prompt_coordinates(group_default, artifact_default, callback)
  local picker = require("java_scaffold.picker")
  picker.input("Group ID: ", group_default, function(group_id)
    if not group_id then
      return
    end
    picker.input("Artifact ID: ", artifact_default, function(artifact_id)
      if not artifact_id then
        return
      end
      local err = require("java_scaffold.maven").validate(group_id, artifact_id)
      if err then
        notify_error(err)
        return
      end
      callback(group_id, artifact_id)
    end)
  end)
end

local function prompt_project(group_default, artifact_default, callback)
  local picker = require("java_scaffold.picker")
  picker.input("Destination directory: ", vim.fn.getcwd(), function(value)
    if not value then
      return
    end
    value = vim.trim(value)
    if value == "" then
      notify_error("destination directory is required")
      return
    end
    local destination = vim.fs.normalize(vim.fn.fnamemodify(value, ":p"))
    if vim.fn.isdirectory(destination) ~= 1 then
      notify_error("destination directory does not exist: " .. destination)
      return
    end
    prompt_coordinates(group_default, artifact_default, function(group_id, artifact_id)
      callback(destination, group_id, artifact_id)
    end)
  end)
end

local function prompt_package(group_id, artifact_id, callback)
  local maven = require("java_scaffold.maven")
  local derived = maven.package_name(group_id, artifact_id)
  require("java_scaffold.picker").input("Package name: ", derived, function(package_name)
    if package_name == nil then
      return
    end
    package_name = vim.trim(package_name)
    if package_name == "" then
      package_name = derived
    end
    local package_error = maven.validate_package(package_name)
    if package_error then
      notify_error(package_error)
      return
    end
    callback(package_name)
  end)
end

local function confirm_project(fields)
  local lines = { "Review project" }
  for _, field in ipairs(fields) do
    lines[#lines + 1] = field[1] .. ": " .. tostring(field[2])
  end
  return require("java_scaffold.picker").confirm(table.concat(lines, "\n"))
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

local function java_choices(config)
  local java = require("java_scaffold.java")
  local runtimes = M.java_runtimes()
  local versions = java.installed(config.java_versions, config.java_homes, runtimes)
  return java, runtimes, versions
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
  local function selected_archetype(archetype)
    if not archetype then
      return
    end
    prompt_project(config.group_id, config.artifact_id, function(destination, group_id, artifact_id)
      prompt_package(group_id, artifact_id, function(package_name)
        local java, runtimes, versions = java_choices(config)
        choose_java(
          versions,
          config.java_version,
          runtimes.active,
          function(java_version, java_error)
            if java_error then
              notify_error(java_error)
              return
            end
            if not java_version then
              return
            end
            local runner_version =
              java.default(config.maven.runner_java_version, versions, runtimes.active)
            local runner_env = java.runner_env(runner_version, config.java_homes, runtimes.homes)
            if
              not confirm_project({
                { "Destination", vim.fs.joinpath(destination, artifact_id) },
                { "Coordinates", group_id .. ":" .. artifact_id },
                { "Package", package_name },
                { "Build system", "Maven - " .. (archetype.name or archetype.artifact_id) },
                { "Java target", java_version },
                { "Runner JVM", runner_version or "system" },
              })
            then
              return
            end
            notify("detecting Maven runtime")
            java.maven_runtime_async(config.maven.command, function(detected_runtime)
              local maven_runtime = detected_runtime or runtimes.active
              if maven_runtime and tonumber(java_version) > tonumber(maven_runtime) then
                notify(
                  string.format(
                    "Java %s exceeds Maven runner Java %s; configure Maven runner JDK or toolchain",
                    java_version,
                    maven_runtime
                  ),
                  vim.log.levels.WARN
                )
              end
              notify("creating Maven project with Java " .. java_version)
              require("java_scaffold.maven").create({
                command = config.maven.command,
                cwd = destination,
                group_id = group_id,
                artifact_id = artifact_id,
                package_name = package_name,
                version = config.maven.project_version,
                wrapper = config.maven.wrapper,
                java_version = java_version,
                archetype = archetype,
                timeout = config.maven.timeout,
                env = runner_env,
              }, function(err, project_dir)
                if err then
                  notify_error(err)
                  return
                end
                finish_project(project_dir)
              end)
            end, config.maven.timeout, runner_env)
          end
        )
      end)
    end)
  end

  if #config.maven.archetypes == 1 then
    selected_archetype(config.maven.archetypes[1])
    return
  end
  require("java_scaffold.picker").select_one(config.maven.archetypes, {
    prompt = "Maven archetype",
    default = config.maven.archetypes[1],
    format_item = function(item)
      return item.name or (item.group_id .. ":" .. item.artifact_id .. ":" .. item.version)
    end,
  }, selected_archetype)
end

function M.new_gradle()
  local config = require("java_scaffold.config").get()
  prompt_project(config.group_id, config.artifact_id, function(destination, group_id, artifact_id)
    prompt_package(group_id, artifact_id, function(package_name)
      require("java_scaffold.picker").select_one(config.gradle.project_types, {
        prompt = "Gradle project type",
        default = config.gradle.default_project_type,
      }, function(project_type)
        if not project_type then
          return
        end
        require("java_scaffold.picker").select_one(config.gradle.languages, {
          prompt = "Gradle source language",
          default = "java",
        }, function(language)
          if not language then
            return
          end
          local init_type = require("java_scaffold.gradle").project_type(language, project_type.id)
          if not init_type then
            notify_error("unsupported Gradle source language and project type combination")
            return
          end
          require("java_scaffold.picker").select_one(config.gradle.dsls, {
            prompt = "Gradle DSL",
            default = config.gradle.dsl,
          }, function(dsl)
            if not dsl then
              return
            end
            local java, runtimes, versions = java_choices(config)
            choose_java(
              versions,
              config.java_version,
              runtimes.active,
              function(java_version, java_error)
                if java_error then
                  notify_error(java_error)
                  return
                end
                if not java_version then
                  return
                end
                local runner_version =
                  java.default(config.gradle.runner_java_version, versions, runtimes.active)
                local runner_env =
                  java.runner_env(runner_version, config.java_homes, runtimes.homes)
                if
                  not confirm_project({
                    { "Destination", vim.fs.joinpath(destination, artifact_id) },
                    { "Coordinates", group_id .. ":" .. artifact_id },
                    { "Package", package_name },
                    { "Build system", "Gradle - " .. project_type.name },
                    { "Source language", language },
                    { "Build DSL", dsl },
                    { "Java target", java_version },
                    { "Runner JVM", runner_version or "system" },
                  })
                then
                  return
                end
                notify("detecting Gradle runtime")
                java.gradle_runtime_async(config.gradle.command, function(detected_runtime)
                  if detected_runtime and tonumber(java_version) > tonumber(detected_runtime) then
                    notify(
                      string.format(
                        "Java %s exceeds Gradle runner Java %s; configure Gradle toolchain",
                        java_version,
                        detected_runtime
                      ),
                      vim.log.levels.WARN
                    )
                  end
                  notify("creating Gradle project with Java " .. java_version)
                  require("java_scaffold.gradle").create({
                    command = config.gradle.command,
                    cwd = destination,
                    group_id = group_id,
                    artifact_id = artifact_id,
                    package_name = package_name,
                    java_version = java_version,
                    project_type = init_type,
                    dsl = dsl,
                    test_framework = config.gradle.test_framework,
                    timeout = config.gradle.timeout,
                    env = runner_env,
                  }, function(err, project_dir)
                    if err then
                      notify_error(err)
                      return
                    end
                    finish_project(project_dir)
                  end)
                end, config.gradle.timeout, runner_env)
              end
            )
          end)
        end)
      end)
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

local function choose_spring_options(client, config, callback)
  local metadata = require("java_scaffold.metadata")
  local picker = require("java_scaffold.picker")
  local languages = metadata.values(client, "language")
  local packaging = metadata.values(client, "packaging")
  picker.select_one(languages, {
    prompt = "Spring language",
    default = config.spring.language,
  }, function(language)
    if not language then
      return
    end
    picker.select_one(packaging, {
      prompt = "Spring packaging",
      default = config.spring.packaging,
    }, function(selected_packaging)
      if selected_packaging then
        callback(language, selected_packaging)
      end
    end)
  end)
end

local function choose_spring_project_type(client, config, callback)
  local project_types = require("java_scaffold.metadata").project_types(client)
  if #project_types == 0 then
    callback({
      id = config.spring.project_type,
      build = config.spring.project_type:match("^gradle") and "gradle" or "maven",
    })
    return
  end
  require("java_scaffold.picker").select_one(project_types, {
    prompt = "Spring project type",
    default = config.spring.project_type,
    format_item = function(item)
      return item.name
    end,
  }, callback)
end

local function prompt_spring_fields(group_id, artifact_id, callback)
  local picker = require("java_scaffold.picker")
  local maven = require("java_scaffold.maven")
  local derived_package = maven.package_name(group_id, artifact_id)
  picker.input("Project name: ", artifact_id, function(name)
    if name == nil then
      return
    end
    name = vim.trim(name)
    if name == "" then
      name = artifact_id
    end
    picker.input("Description: ", "Demo project for Spring Boot", function(description)
      if description == nil then
        return
      end
      description = vim.trim(description)
      picker.input("Package name: ", derived_package, function(package_name)
        if package_name == nil then
          return
        end
        package_name = vim.trim(package_name)
        if package_name == "" then
          package_name = derived_package
        end
        local package_error = maven.validate_package(package_name)
        if package_error then
          notify_error(package_error)
          return
        end
        callback(name, description, package_name)
      end)
    end)
  end)
end

function M.new_spring()
  notify("loading Spring Initializr metadata")
  fetch_client(function(metadata_error, client)
    if metadata_error then
      notify_error(metadata_error)
      return
    end
    local config = require("java_scaffold.config").get()
    local metadata = require("java_scaffold.metadata")
    prompt_project(
      config.group_id,
      metadata.default(client, "artifactId", "demo"),
      function(destination, group_id, artifact_id)
        local versions = metadata.values(client, "javaVersion")
        choose_java(
          versions,
          config.java_version,
          metadata.default(client, "javaVersion", versions[#versions]),
          function(java_version, java_error)
            if java_error then
              notify_error(java_error)
              return
            end
            if not java_version then
              return
            end
            local boot_versions = metadata.values(client, "bootVersion")
            local default_boot = metadata.default(client, "bootVersion")
            if #boot_versions == 0 and default_boot then
              boot_versions = { default_boot }
            end
            require("java_scaffold.picker").select_one(boot_versions, {
              prompt = "Spring Boot version",
              default = default_boot,
            }, function(boot_version)
              if not boot_version then
                return
              end
              choose_spring_project_type(client, config, function(project_type)
                if not project_type then
                  return
                end
                prompt_spring_fields(
                  group_id,
                  artifact_id,
                  function(name, description, package_name)
                    fetch_catalog(boot_version, function(catalog_error, catalog)
                      if catalog_error then
                        notify_error(catalog_error)
                        return
                      end
                      local dependencies = {}
                      for _, item in ipairs(metadata.flatten_dependencies(client)) do
                        if catalog.dependencies[item.id] then
                          dependencies[#dependencies + 1] = item
                        end
                      end
                      require("java_scaffold.picker").select_many(dependencies, {
                        prompt = "Spring dependencies",
                        format_item = function(item)
                          return string.format("%s  [%s]", item.name, item.group)
                        end,
                      }, function(selected)
                        if not selected then
                          return
                        end
                        local dependency_ids = vim.tbl_map(function(item)
                          return item.id
                        end, selected)
                        choose_spring_options(client, config, function(language, packaging)
                          if
                            not confirm_project({
                              { "Destination", vim.fs.joinpath(destination, artifact_id) },
                              { "Coordinates", group_id .. ":" .. artifact_id },
                              { "Name", name },
                              { "Description", description == "" and "none" or description },
                              { "Package", package_name },
                              { "Build type", project_type.build },
                              { "Java target", java_version },
                              { "Runner JVM", "not used during generation" },
                              { "Spring Boot", boot_version },
                              { "Language", language },
                              { "Packaging", packaging },
                              {
                                "Dependencies",
                                #dependency_ids == 0 and "none"
                                  or table.concat(dependency_ids, ", "),
                              },
                            })
                          then
                            return
                          end
                          notify("creating Spring project with Java " .. java_version)
                          require("java_scaffold.spring").create({
                            url = config.spring.starter_url,
                            cwd = destination,
                            group_id = group_id,
                            artifact_id = artifact_id,
                            name = name,
                            description = description,
                            package_name = package_name,
                            java_version = java_version,
                            boot_version = boot_version,
                            dependencies = dependency_ids,
                            project_type = project_type.id,
                            build = project_type.build,
                            language = language,
                            packaging = packaging,
                            timeout = config.spring.timeout,
                          }, function(err, project_dir)
                            if err then
                              notify_error(err)
                              return
                            end
                            finish_project(project_dir)
                          end)
                        end)
                      end)
                    end)
                  end
                )
              end)
            end)
          end
        )
      end
    )
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
