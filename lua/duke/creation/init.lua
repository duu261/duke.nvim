local M = {}

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

local adapters = {
  maven = "duke.maven",
  gradle = "duke.gradle",
  spring = "duke.spring",
}

local function refresh(session)
  if type(session.refresh) == "function" then
    session:refresh()
  end
end

local function guarded_callback(session, context, token, callback)
  return function(...)
    local args = { ... }
    local ok, err = xpcall(function()
      callback(unpack(args))
    end, debug.traceback)
    if ok then
      return
    end
    pcall(function()
      session.model:reject_async(token, context .. " failed")
      session.model:set_busy(false)
      session.model:set_banner(context .. " failed; see :DukeLog")
    end)
    pcall(function()
      require("duke.log").add("ERROR", context .. " failed: " .. tostring(err))
    end)
    pcall(vim.notify, "duke.nvim: " .. context .. " failed; see :DukeLog", vim.log.levels.ERROR)
    pcall(refresh, session)
  end
end

local function fallback_message(fallback)
  local metadata = require("duke.metadata")
  local age = metadata.format_age(fallback.age_seconds)
  if fallback.reason == "schema" then
    return "Initializr metadata schema not recognized; using cached data from " .. age
  end
  return "Spring Initializr unreachable; using cached data from " .. age
end

local function discover_runtimes(session, config)
  local token = session.model:begin_async("runtimes")
  if not token then
    return
  end
  local ok, result = pcall(function()
    local java = require("duke.java")
    local runtimes = {
      active = java.active(),
      homes = java.discover_homes(config.java_homes),
    }
    local versions = java.installed(config.java_versions, config.java_homes, runtimes)
    local current_target = session.model:snapshot().values.java_version
    local target = current_target ~= "auto" and current_target
      or java.default(config.java_version, versions, runtimes.active)
    local derived = {
      java_versions = versions,
      runtimes = runtimes,
    }
    local kind = session.model:snapshot().kind
    if kind == "maven" or kind == "gradle" then
      local tool = config[kind]
      local runner = java.default(tool.runner_java_version, versions, runtimes.active)
      derived[kind .. "_runner_version"] = runner
      derived[kind .. "_runner_env"] = java.runner_env(runner, config.java_homes, runtimes.homes)
    end
    return { values = { java_version = target }, derived = derived }
  end)
  if ok then
    session.model:resolve_async(token, result)
  else
    session.model:reject_async(token, result)
  end
  refresh(session)
  if not ok then
    return
  end
  local state = session.model:snapshot()
  local kind = state.kind
  if kind ~= "maven" and kind ~= "gradle" then
    return
  end
  local java = require("duke.java")
  local detect = java[kind .. "_runtime_async"]
  if type(detect) ~= "function" then
    return
  end
  local runner_token = session.model:begin_async("runner")
  local tool = config[kind]
  local env = state.derived[kind .. "_runner_env"]
  local start_ok, start_error = pcall(
    detect,
    tool.command,
    guarded_callback(session, "runner callback", runner_token, function(detected)
      local current = session.model:snapshot()
      local effective = detected
      if kind == "maven" and not effective then
        effective = current.derived.runtimes and current.derived.runtimes.active
      end
      session.model:resolve_async(runner_token, {
        derived = {
          [kind .. "_detected_runtime"] = effective,
        },
      })
      refresh(session)
    end),
    tool.timeout,
    env
  )
  if not start_ok then
    session.model:reject_async(runner_token, start_error)
    refresh(session)
  end
end

local function discover_catalog(session, config)
  local state = session.model:snapshot()
  if state.kind ~= "spring" or not state.values.boot_version then
    return
  end
  local token = session.model:begin_async("catalog")
  local metadata = require("duke.metadata")
  local boot_version = state.values.boot_version
  local url = config.spring.dependencies_url .. "?bootVersion=" .. vim.uri_encode(boot_version)
  metadata.fetch_cached(
    url,
    metadata.cache_path("dependencies", boot_version, config.spring.dependencies_url),
    nil,
    guarded_callback(session, "catalog callback", token, function(err, catalog, source, fallback)
      if err then
        session.model:reject_async(token, err)
        refresh(session)
        return
      end
      local current = session.model:snapshot()
      local items = {}
      for _, item in ipairs(metadata.flatten_dependencies(current.derived.spring_client or {})) do
        if catalog.dependencies[item.id] then
          items[#items + 1] = item
        end
      end
      if
        session.model:resolve_async(token, {
          derived = {
            spring_catalog = catalog,
            spring_dependency_items = items,
            spring_catalog_source = source,
          },
        })
        and source == "cache"
        and fallback
      then
        session.model:set_banner(fallback_message(fallback))
      end
      refresh(session)
    end),
    metadata.is_catalog
  )
end

local function discover_spring(session, config)
  if session.model:snapshot().kind ~= "spring" then
    return
  end
  local token = session.model:begin_async("metadata")
  local metadata = require("duke.metadata")
  metadata.fetch_cached(
    config.spring.metadata_url,
    metadata.cache_path("metadata", nil, config.spring.metadata_url),
    nil,
    guarded_callback(
      session,
      "Spring metadata callback",
      token,
      function(err, client, source, fallback)
        if err then
          session.model:reject_async(token, err)
          refresh(session)
          return
        end
        local java_versions = metadata.values(client, "javaVersion")
        local boot_versions = metadata.values(client, "bootVersion")
        local languages = metadata.values(client, "language")
        local packaging = metadata.values(client, "packaging")
        local project_types = metadata.project_types(client)
        local boot = metadata.default(client, "bootVersion", boot_versions[1])
        local current_target = session.model:snapshot().values.java_version
        local target = current_target ~= "auto" and current_target
          or require("duke.java").default(
            config.java_version,
            java_versions,
            metadata.default(client, "javaVersion", java_versions[#java_versions])
          )
        local project_type
        for _, candidate in ipairs(project_types) do
          if candidate.id == config.spring.project_type then
            project_type = candidate
            break
          end
        end
        project_type = project_type
          or project_types[1]
          or {
            id = config.spring.project_type,
            build = config.spring.project_type:match("^gradle") and "gradle" or "maven",
          }
        if
          session.model:resolve_async(token, {
            values = {
              java_version = target,
              boot_version = boot,
              spring_project_type = project_type,
              spring_language = metadata.default(client, "language", config.spring.language),
              spring_packaging = metadata.default(client, "packaging", config.spring.packaging),
            },
            derived = {
              spring_client = client,
              java_versions = java_versions,
              boot_version_choices = boot_versions,
              spring_project_type_choices = project_types,
              spring_language_choices = languages,
              spring_packaging_choices = packaging,
              spring_metadata_source = source,
            },
          })
          and source == "cache"
          and fallback
        then
          session.model:set_banner(fallback_message(fallback))
        end
        refresh(session)
        discover_catalog(session, config)
      end
    ),
    metadata.is_client
  )
end

local function discover(session, config, scope)
  if scope == "catalog" then
    discover_catalog(session, config)
    return
  end
  discover_runtimes(session, config)
  discover_spring(session, config)
end

local function submit(kind, request, callback)
  local module_name = adapters[kind]
  if not module_name then
    callback("unknown project generator: " .. tostring(kind))
    return
  end
  local ok, start_error = pcall(function()
    require(module_name).create(vim.deepcopy(request), callback)
  end)
  if not ok then
    callback("project creation failed to start: " .. tostring(start_error))
  end
end

function M.open(opts)
  local ok, result = xpcall(function()
    opts = opts or {}
    local config = require("duke.config").get()
    local creation = require("duke.creation.model").new(config, {
      kind = opts.kind,
      cwd = vim.fn.getcwd(),
    })
    return require("duke.creation.center").open({
      model = creation,
      config = config,
      layout = opts.layout or config.creation.layout,
      submit = submit,
      finish = finish_project,
      discover = function(session, scope)
        discover(session, config, scope)
      end,
    })
  end, debug.traceback)
  if ok then
    return result
  end
  pcall(function()
    require("duke.log").add("ERROR", result)
  end)
  pcall(vim.notify, "duke.nvim: could not open Creation Center; see :DukeLog", vim.log.levels.ERROR)
  return nil
end

return M
