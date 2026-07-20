local M = {}

local namespace = vim.api.nvim_create_namespace("duke_project_center")
local center
local latest
local diagnose

local function valid_buffer()
  return center and center.buf and vim.api.nvim_buf_is_valid(center.buf)
end

local function valid_window()
  return center and center.win and vim.api.nvim_win_is_valid(center.win)
end

local function close()
  if valid_window() then
    pcall(vim.api.nvim_win_close, center.win, true)
  elseif valid_buffer() then
    pcall(vim.api.nvim_buf_delete, center.buf, { force = true })
  end
  center = nil
end

local function module_by_id(snapshot, id)
  for _, module in ipairs(snapshot.modules or {}) do
    if module.id == id then
      return module
    end
  end
end

local function module_for_node(snapshot, node)
  if not snapshot or not node then
    return nil
  end
  return module_by_id(snapshot, node.module_id or snapshot.active_module)
end

local function analysis_dependency(snapshot, coordinate, module_id, project_id)
  for _, dependency in ipairs((snapshot.analysis and snapshot.analysis.dependencies) or {}) do
    if
      dependency.coordinate == coordinate
      and (not module_id or dependency.module_id == module_id)
      and (not project_id or dependency.project_id == project_id)
    then
      return dependency
    end
  end
end

local function maven_java_target(module)
  local properties = module.model and module.model.properties or {}
  for _, name in ipairs({ "maven.compiler.release", "maven.compiler.target", "java.version" }) do
    if properties[name] and properties[name].value then
      return properties[name].value
    end
  end
end

local function jdtls_label(root)
  local ok, clients = pcall(vim.lsp.get_clients, { name = "jdtls" })
  if not ok then
    return "JDTLS  unknown"
  end
  for _, client in ipairs(clients) do
    local client_root = client.root_dir or (client.config and client.config.root_dir)
    if client_root and vim.fs.normalize(client_root) == vim.fs.normalize(root) then
      return "JDTLS  attached  " .. client_root
    end
  end
  return "JDTLS  not attached"
end

local function guarded(label, callback)
  return function(...)
    local ok, err = pcall(callback, ...)
    if not ok then
      require("duke.log").add("ERROR", "Project Center " .. label .. ": " .. tostring(err))
      pcall(vim.notify, "duke.nvim: Project Center action failed", vim.log.levels.ERROR)
    end
  end
end

local function resolved_dependency_versions(snapshot)
  local versions = {}
  local analysis = snapshot and snapshot.analysis
  for _, dependency in ipairs((analysis and analysis.dependencies) or {}) do
    if dependency.direct and dependency.module_id then
      versions[dependency.module_id .. "\0" .. dependency.coordinate] = dependency.version
    end
  end
  return versions
end

local function render(snapshot, status)
  if not valid_buffer() then
    return
  end
  local lines = {
    "Duke Project Center",
    status or (snapshot and snapshot.state) or "loading",
    snapshot and snapshot.root or center.path,
    "",
  }
  if status == "failed" and center.error then
    local reason = tostring(center.error):match("^[^\r\n]+") or "workspace inspection failed"
    lines[#lines + 1] = "error  " .. reason:gsub("%s+", " ")
    lines[#lines + 1] = "press r to retry; l for :DukeLog"
    lines[#lines + 1] = ""
  end
  local nodes = {}
  local function heading(label, count)
    lines[#lines + 1] = count and string.format("%s (%d)", label, count) or label
  end
  local function node(label, value)
    lines[#lines + 1] = "  " .. label
    nodes[#lines] = value
  end

  if snapshot then
    local resolved_versions = resolved_dependency_versions(snapshot)
    heading("Workspace")
    node("root  " .. snapshot.root, {
      kind = "workspace",
      label = snapshot.root,
      path = snapshot.environment and snapshot.environment.build_file,
      line = 1,
    })
    if snapshot.active_module then
      local active = module_by_id(snapshot, snapshot.active_module)
      node("active  " .. snapshot.active_module, {
        kind = "module",
        label = snapshot.active_module,
        module_id = snapshot.active_module,
        path = active and active.build_file,
        line = 1,
      })
    end
    lines[#lines + 1] = ""
    heading("Modules", #(snapshot.modules or {}))
    for _, module in ipairs(snapshot.modules or {}) do
      local marker = module.id == snapshot.active_module and "* " or ""
      node(marker .. module.id, {
        kind = "module",
        label = module.id,
        module_id = module.id,
        path = module.build_file,
        line = 1,
      })
    end
    lines[#lines + 1] = ""
    heading("Dependencies", #(snapshot.dependencies or {}))
    for _, dependency in ipairs(snapshot.dependencies or {}) do
      local module = module_by_id(snapshot, dependency.module_id)
      local resolved = resolved_versions[dependency.module_id .. "\0" .. dependency.coordinate]
      local detail = analysis_dependency(
        snapshot,
        dependency.coordinate,
        dependency.module_id,
        dependency.project_id
      )
      local suffix = ""
      if resolved and not dependency.version then
        suffix = "  " .. resolved .. " (managed)"
      elseif resolved and resolved ~= dependency.version then
        suffix = "  " .. dependency.version .. " -> " .. resolved
      elseif dependency.version then
        suffix = "  " .. dependency.version
      end
      node(dependency.coordinate .. suffix, {
        kind = "dependency",
        label = dependency.coordinate,
        coordinate = dependency.coordinate,
        module_id = dependency.module_id,
        path = module and module.build_file,
        line = detail and detail.raw_owner and detail.raw_owner.start_line or dependency.line,
        detail = detail,
      })
    end
    lines[#lines + 1] = ""
    if snapshot.analysis then
      local dependencies = snapshot.analysis.dependencies or {}
      if snapshot.kind == "gradle" then
        local projects = snapshot.analysis.projects or {}
        heading("Gradle projects", #projects)
        for _, project in ipairs(projects) do
          node(project.id .. "  " .. project.name, {
            kind = "project",
            label = project.id,
            detail = project,
          })
        end
        lines[#lines + 1] = ""
        heading("Resolved dependencies", #dependencies)
        for _, dependency in ipairs(dependencies) do
          local requested = dependency.requested_version
          local version = dependency.version
          local suffix = version and ("  " .. version) or ""
          if requested and version and requested ~= version then
            suffix = "  " .. requested .. " -> " .. version
          end
          local context = string.format(
            "  [%s %s]",
            dependency.project_id or "unknown project",
            dependency.configuration or "unknown configuration"
          )
          node(dependency.coordinate .. suffix .. context, {
            kind = "dependency",
            label = dependency.coordinate,
            coordinate = dependency.coordinate,
            project_id = dependency.project_id,
            path_data = dependency.path,
            detail = dependency,
          })
        end
        lines[#lines + 1] = ""
      end
      local findings = snapshot.analysis.findings or {}
      local transitive = 0
      for _, dependency in ipairs(dependencies) do
        if not dependency.direct then
          transitive = transitive + 1
        end
      end
      heading("Resolved nodes", #dependencies)
      node("Transitive dependencies  " .. transitive, { kind = "analysis" })
      node("Conflicts  " .. #(findings.conflicts or {}), {
        kind = "finding",
        label = "Conflicts",
        findings = findings.conflicts or {},
      })
      node("Version drift  " .. #(findings.drift or {}), {
        kind = "finding",
        label = "Version drift",
        findings = findings.drift or {},
      })
      node("Duplicate declarations  " .. #(findings.duplicates or {}), {
        kind = "finding",
        label = "Duplicate declarations",
        findings = findings.duplicates or {},
      })
      node("Unknown ownership  " .. #(findings.unknown or {}), {
        kind = "finding",
        label = "Unknown ownership",
        findings = findings.unknown or {},
      })
      if snapshot.kind == "maven" then
        for _, dependency in ipairs(dependencies) do
          local module = module_by_id(snapshot, dependency.module_id)
          node(
            string.format(
              "%s  %s  [%s%s]",
              dependency.coordinate,
              dependency.version or "unknown",
              dependency.module_id or "unknown module",
              dependency.direct and " direct" or " transitive"
            ),
            {
              kind = "dependency",
              label = dependency.coordinate,
              coordinate = dependency.coordinate,
              module_id = dependency.module_id,
              path = module and module.build_file,
              line = dependency.raw_owner and dependency.raw_owner.start_line or nil,
              detail = dependency,
            }
          )
        end
      end
      lines[#lines + 1] = ""
    end
    local environment = snapshot.environment or {}
    heading("Environment")
    local environment_fields = {
      { "Wrapper", environment.wrapper },
      { "Build file", environment.build_file },
      { "Settings", environment.settings_file },
      { "Version catalog", environment.version_catalog },
      { "Gradle", environment.gradle_version },
      { "Runner JVM", environment.runner_java_version },
      { "Runner JAVA_HOME", environment.runner_java_home },
    }
    for _, field in ipairs(environment_fields) do
      if field[2] then
        node(field[1] .. "  " .. field[2], {
          kind = "environment",
          label = field[1],
          path = vim.uv.fs_stat(field[2]) and field[2] or nil,
          line = 1,
        })
      end
    end
    local java = snapshot.analysis and snapshot.analysis.java or {}
    for _, model in ipairs(java) do
      local target = model.language_version or model.target_compatibility
      if target then
        node(string.format("Java target  %s  %s", model.project_id, target), {
          kind = "environment",
          label = "Java target " .. model.project_id,
          detail = model,
        })
      end
    end
    local toolchains = snapshot.analysis and snapshot.analysis.toolchains or {}
    if #toolchains > 0 then
      node("Toolchains  " .. table.concat(toolchains, ", "), {
        kind = "environment",
        label = "Toolchains",
      })
    end
    if snapshot.kind == "maven" then
      for _, module in ipairs(snapshot.modules or {}) do
        local target = maven_java_target(module)
        if target then
          node(string.format("Java target  %s  %s", module.id, target), {
            kind = "environment",
            label = "Java target " .. module.id,
          })
        end
        local boot = module.model and module.model.spring_boot_version
        if boot then
          node(string.format("Spring Boot  %s  %s", module.id, boot), {
            kind = "environment",
            label = "Spring Boot " .. module.id,
          })
        end
      end
    end
    node(jdtls_label(snapshot.root), { kind = "environment", label = "JDTLS" })
    lines[#lines + 1] = ""
    heading("Spring configuration", #(snapshot.configuration or {}))
    for _, file in ipairs(snapshot.configuration or {}) do
      local profile = file.profile and (" [" .. file.profile .. "]") or ""
      node(file.scope .. profile .. "  " .. vim.fs.basename(file.path), {
        kind = "configuration",
        label = file.path,
        path = file.path,
        line = 1,
      })
    end
    lines[#lines + 1] = ""
    heading("Diagnostics", #(snapshot.diagnostics or {}))
    for _, item in ipairs(snapshot.diagnostics or {}) do
      local message =
        tostring(item.message or "unknown diagnostic"):gsub("[\r\n]+", " "):gsub("%s+", " ")
      node((item.severity or "warning") .. "  " .. message, {
        kind = "diagnostic",
        label = item.message,
      })
    end
  end
  local doctor = center.doctor
  if doctor then
    lines[#lines + 1] = ""
    local doctor_state = "idle"
    if doctor.busy then
      doctor_state = "loading"
    elseif doctor.error then
      doctor_state = "unresolved"
    elseif doctor.diagnosis then
      doctor_state = doctor.diagnosis.state or "resolved"
    end
    heading("Doctor  " .. doctor_state)
    if doctor.error then
      lines[#lines + 1] = "  error  " .. tostring(doctor.error):match("^[^\r\n]+"):gsub("%s+", " ")
    end
    local diagnosis = doctor.diagnosis
    if diagnosis then
      lines[#lines + 1] = "  Active profiles  "
        .. (
          #(diagnosis.active_profiles or {}) > 0 and table.concat(diagnosis.active_profiles, ", ")
          or "none"
        )
      heading("Warnings", #(diagnosis.warnings or {}))
      for _, warning in ipairs(diagnosis.warnings or {}) do
        lines[#lines + 1] = "  " .. tostring(warning):gsub("[\r\n]+", " ")
      end
      heading("Findings", #(diagnosis.findings or {}))
      for _, finding in ipairs(diagnosis.findings or {}) do
        local selected = doctor.selected_repairs[finding.id] and "* " or ""
        node(selected .. require("duke.picker").format_doctor_finding(finding), {
          kind = "doctor_finding",
          label = finding.coordinate,
          finding_id = finding.id,
          finding = finding,
          repairable = finding.repairable,
        })
        local owner = finding.ownership
        if owner then
          if type(owner.owners) == "table" then
            lines[#lines + 1] = string.format(
              "    owner %s  %d POMs",
              tostring(owner.kind or "reactor_alignment"),
              #owner.owners
            )
            for _, item in ipairs(owner.owners) do
              local location = item.pom_label or "unknown POM"
              if item.line then
                location = location .. ":" .. item.line
              end
              lines[#lines + 1] = "      owner "
                .. tostring(item.kind or "unknown")
                .. "  "
                .. location
            end
          else
            local location = owner.pom_label or "unknown POM"
            if owner.line then
              location = location .. ":" .. owner.line
            end
            lines[#lines + 1] = "    owner "
              .. tostring(owner.kind or "unknown")
              .. "  "
              .. location
          end
        end
        if not finding.repairable then
          lines[#lines + 1] = "    blocked "
            .. tostring(finding.blocked_reason or "writable owner unavailable")
        end
      end
    end
    if doctor.plan then
      lines[#lines + 1] = string.format(
        "  Plan  %d files  %d changes",
        doctor.plan.preview.file_count or 0,
        doctor.plan.preview.change_count or 0
      )
    end
    if doctor.receipt then
      lines[#lines + 1] = string.format(
        "  Receipt  fixed %d  remaining %d",
        doctor.receipt.fixed or 0,
        doctor.receipt.remaining or 0
      )
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "<CR> open  r resolve  a add  u upgrade  x remove  p paths  "
    .. "g declaration  d doctor  P plan  A apply  L deep  / search  l log  ? help  q close"

  vim.bo[center.buf].modifiable = true
  vim.api.nvim_buf_set_lines(center.buf, 0, -1, false, lines)
  vim.bo[center.buf].modifiable = false
  vim.b[center.buf].duke_project_center_nodes = nodes
  center.nodes = nodes
  vim.api.nvim_buf_clear_namespace(center.buf, namespace, 0, -1)
  vim.api.nvim_buf_set_extmark(center.buf, namespace, 1, 0, {
    end_col = #lines[2],
    hl_group = status == "failed" and "DiagnosticError" or "DiagnosticInfo",
  })
end

local function target_window()
  local target = center and center.origin_win
  if not target or not vim.api.nvim_win_is_valid(target) then
    target = vim.api.nvim_get_current_win()
  end
  return target
end

local function open_path(path, line)
  if not path or not vim.uv.fs_stat(path) then
    return
  end
  local target = target_window()
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.api.nvim_win_set_buf(target, buf)
  vim.api.nvim_set_current_win(target)
  if line then
    pcall(vim.api.nvim_win_set_cursor, target, { line, 0 })
  end
end

local function show_detail(title, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, "duke://" .. title:gsub("%s+", "-"))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "duke"
  vim.keymap.set("n", "q", "<Cmd>bdelete<CR>", { buffer = buf, silent = true })
  vim.api.nvim_win_set_buf(target_window(), buf)
  vim.api.nvim_set_current_win(target_window())
  return buf
end

local function dependency_detail(node)
  local detail = node.detail or {}
  local lines = {
    node.coordinate or node.label,
    "",
    "Module: " .. tostring(detail.module_id or node.module_id or "unknown"),
    "Requested version: "
      .. tostring(
        detail.requested_version or (detail.raw_owner and detail.raw_owner.version) or "unknown"
      ),
    "Selected version: " .. tostring(detail.version or "unknown"),
    "Effective version: " .. tostring(detail.effective_version or "unknown"),
    "Scope: " .. tostring(detail.scope or detail.configuration or "unknown"),
    "Ownership: " .. (detail.raw_owner and "raw declaration" or "unknown"),
  }
  if detail.property then
    lines[#lines + 1] = "Property: " .. detail.property
  end
  if detail.property_consumers and #detail.property_consumers > 0 then
    lines[#lines + 1] = "Consumers:"
    for _, consumer in ipairs(detail.property_consumers) do
      lines[#lines + 1] = "  " .. tostring(consumer.coordinate or consumer)
    end
  end
  return lines
end

local function finding_detail(node)
  local lines = { node.label, "" }
  if #node.findings == 0 then
    lines[#lines + 1] = "No proven findings"
  end
  for _, finding in ipairs(node.findings or {}) do
    local values = { finding.coordinate or "unknown" }
    if finding.module_id then
      values[#values + 1] = "module " .. finding.module_id
    end
    if finding.versions then
      values[#values + 1] = table.concat(finding.versions, ", ")
    end
    if finding.omitted or finding.selected then
      values[#values + 1] = tostring(finding.omitted) .. " -> " .. tostring(finding.selected)
    end
    if finding.lines then
      values[#values + 1] = "lines " .. table.concat(finding.lines, ", ")
    end
    if finding.path then
      values[#values + 1] = table.concat(finding.path, " -> ")
    end
    lines[#lines + 1] = table.concat(values, "  ")
  end
  return lines
end

local function doctor_finding_detail(finding)
  local lines = {
    finding.coordinate or "unknown",
    "",
    "Kind: " .. tostring(finding.kind or "unknown"),
    "Severity: " .. tostring(finding.severity or "unknown"),
    "Requested: " .. table.concat(finding.requested_versions or {}, ", "),
    "Selected: " .. tostring(finding.selected_version or "unknown"),
    "Repairable: " .. tostring(finding.repairable == true),
  }
  if finding.ownership then
    lines[#lines + 1] = "Owner: " .. tostring(finding.ownership.kind or "unknown")
    lines[#lines + 1] = "POM: " .. tostring(finding.ownership.pom_label or "unknown")
    lines[#lines + 1] = "Line: " .. tostring(finding.ownership.line or "unknown")
  end
  if finding.blocked_reason then
    lines[#lines + 1] = "Blocked: " .. finding.blocked_reason
  end
  if #(finding.paths or {}) > 0 then
    lines[#lines + 1] = "Paths:"
    for _, path in ipairs(finding.paths) do
      lines[#lines + 1] = "  " .. table.concat(path, " -> ")
    end
  end
  return lines
end

local function open_node(node)
  if not node then
    return
  end
  if node.kind == "dependency" and node.detail then
    show_detail("dependency-" .. node.label, dependency_detail(node))
  elseif node.kind == "doctor_finding" then
    show_detail("doctor-" .. node.label, doctor_finding_detail(node.finding))
  elseif node.kind == "finding" then
    show_detail("finding-" .. node.label, finding_detail(node))
  elseif node.detail then
    local lines = { node.label, "" }
    for key, value in pairs(node.detail) do
      lines[#lines + 1] = tostring(key) .. ": " .. tostring(value)
    end
    show_detail("detail-" .. node.label, lines)
  else
    open_path(node.path, node.line)
  end
end

local function selected_node()
  if not valid_buffer() then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return center.nodes and center.nodes[line]
end

local function refresh(resolve)
  if not valid_buffer() then
    return
  end
  center.generation = center.generation + 1
  local generation = center.generation
  center.error = nil
  render(center.snapshot, resolve and "resolving" or "loading")
  require("duke.workspace").inspect(
    { path = center.path, resolve = resolve },
    guarded("refresh completion", function(err, snapshot)
      if not valid_buffer() or not center or generation ~= center.generation then
        return
      end
      if err then
        center.error = err
        render(center.snapshot, "failed")
        require("duke.log").add("ERROR", err)
        return
      end
      center.error = nil
      center.snapshot = snapshot
      latest = { path = center.path, snapshot = vim.deepcopy(snapshot) }
      render(snapshot)
    end)
  )
end

local function dependency_paths(node)
  if node and node.kind == "doctor_finding" then
    local paths = node.finding.paths or {}
    if #paths == 0 then
      vim.notify("duke.nvim: no dependency paths recorded for this finding")
      return
    end
    local lines = { "Dependency paths", "" }
    for _, path in ipairs(paths) do
      lines[#lines + 1] = table.concat(path, " -> ")
    end
    show_detail("doctor-paths-" .. node.label, lines)
    return
  end
  if not node or node.kind ~= "dependency" then
    return
  end
  local paths = {}
  if node.path_data then
    paths[1] = node.path_data
  elseif center.snapshot and center.snapshot.analysis then
    paths = require("duke.dependency_analyzer").paths(
      center.snapshot.analysis,
      node.coordinate,
      node.module_id
    )
  end
  if #paths == 0 and center.snapshot.kind == "maven" then
    local module = module_for_node(center.snapshot, node)
    if module then
      open_path(module.build_file, 1)
      require("duke").dependency_why(node.coordinate)
    end
    return
  end
  local lines = { "Dependency paths", "" }
  for _, path in ipairs(paths) do
    lines[#lines + 1] = table.concat(path, " -> ")
  end
  show_detail("paths-" .. node.label, lines)
end

local function jump_to_declaration(node)
  if not node then
    return
  end
  if node.kind == "doctor_finding" then
    local owner = node.finding.ownership
    if not owner or not owner.pom_label or not center.snapshot then
      vim.notify("duke.nvim: owning declaration is unknown")
      return
    end
    local root = vim.fs.normalize(center.snapshot.root)
    local path = vim.fs.normalize(vim.fs.joinpath(root, owner.pom_label))
    if path ~= root and path:sub(1, #root + 1) ~= root .. "/" then
      vim.notify("duke.nvim: owning declaration is outside the workspace")
      return
    end
    open_path(path, owner.line)
    return
  end
  local module = module_for_node(center.snapshot, node)
  local path = node.path or (module and module.build_file)
  local line = node.line
  if node.detail and node.detail.raw_owner then
    line = node.detail.raw_owner.start_line
  end
  if node.kind == "dependency" and not line then
    vim.notify("duke.nvim: owning declaration is unknown")
    return
  end
  open_path(path, line)
end

local function module_action(node, action)
  local snapshot = center and center.snapshot
  if not snapshot or snapshot.kind ~= "maven" then
    vim.notify("duke.nvim: Maven action unavailable for this workspace")
    return
  end
  local module = module_for_node(snapshot, node)
  if not module then
    vim.notify("duke.nvim: select a Maven module or dependency")
    return
  end
  open_path(module.build_file, 1)
  require("duke")[action]()
end

local function show_help()
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {
    "Duke Project Center",
    "",
    "<CR>  Open module, declaration, configuration, or detail",
    "r     Resolve workspace through Maven or Gradle wrapper",
    "a     Add a dependency for the selected Maven module",
    "u     Plan upgrades for the active Maven module",
    "x     Remove dependencies from the selected Maven module",
    "p     Show dependency paths",
    "g     Jump to the owning declaration",
    "d     Run Maven Doctor",
    "L     Run deep Maven Doctor; may compile test sources",
    "u     Stage a version repair on a Doctor finding",
    "x     Stage an exclusion on a Doctor conflict",
    "c     Clear staged Doctor repairs",
    "P     Build and preview staged Doctor repairs",
    "A     Confirm and apply the current Doctor plan",
    "R     Refresh Doctor findings and compare the receipt",
    "/     Search visible project nodes",
    "l     Open :DukeLog",
    "?     Show this help",
    "q     Close Project Center",
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = buf, silent = true })
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = 64,
    height = #lines,
    row = math.max(0, math.floor((vim.o.lines - #lines) / 2)),
    col = math.max(0, math.floor((vim.o.columns - 64) / 2)),
    style = "minimal",
    border = "single",
    title = "Duke help",
    title_pos = "center",
  })
end

local function search_nodes()
  local choices = {}
  for _, node in pairs(center.nodes or {}) do
    if type(node.label) == "string" and node.label ~= "" then
      choices[#choices + 1] = node
    end
  end
  table.sort(choices, function(left, right)
    return left.label < right.label
  end)
  require("duke.picker").select_one(choices, {
    prompt = "Duke Project Center",
    format_item = function(item)
      return item.label
    end,
  }, guarded("search selection", open_node))
end

local function show_plan_preview(descriptor)
  local lines = {}
  if descriptor.preview.files then
    for _, file in ipairs(descriptor.preview.files) do
      lines[#lines + 1] = file.pom_label
      lines[#lines + 1] = ""
      for _, change in ipairs(file.changes or {}) do
        if change.kind == "upgrade" then
          lines[#lines + 1] = string.format(
            "  %s  %s -> %s",
            change.coordinate or change.property or "version",
            change.before,
            change.after
          )
          if #(change.consumers or {}) > 0 then
            lines[#lines + 1] = "    consumers  " .. table.concat(change.consumers, ", ")
          end
        else
          lines[#lines + 1] = string.format(
            "  exclude %s from %s",
            change.excluded_coordinate,
            change.direct_coordinate
          )
        end
      end
      lines[#lines + 1] = ""
    end
  else
    lines = { "Before", "" }
    vim.list_extend(lines, descriptor.preview.before)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "After"
    lines[#lines + 1] = ""
    vim.list_extend(lines, descriptor.preview.after)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "xml"
  local width = math.max(20, math.min(100, vim.o.columns - 4))
  local height = math.max(4, math.min(#lines, vim.o.lines - 4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "single",
    title = "Maven repair plan",
    title_pos = "center",
  })
  return win
end

local function plan_upgrades(node)
  local snapshot = center and center.snapshot
  if
    not snapshot
    or snapshot.kind ~= "maven"
    or not ((node and node.module_id) or snapshot.active_module)
  then
    vim.notify("duke.nvim: select an active Maven module before planning upgrades")
    return
  end
  local module_id = (node and node.module_id) or snapshot.active_module
  local module = module_by_id(snapshot, module_id)
  local choices = {}
  for _, dependency in ipairs(snapshot.dependencies or {}) do
    if dependency.module_id == module_id and dependency.version then
      choices[#choices + 1] = dependency
    end
  end

  local function build(selected)
    if not selected or #selected == 0 or not valid_buffer() then
      return
    end
    local changes = {}
    for _, dependency in ipairs(selected) do
      changes[#changes + 1] = { coordinate = dependency.coordinate }
    end
    require("duke.api").plan_upgrades(
      {
        pom_path = module.build_file,
        changes = changes,
      },
      guarded("plan completion", function(err, descriptor)
        if err or not valid_buffer() then
          vim.notify("duke.nvim: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        local preview = show_plan_preview(descriptor)
        local confirmed = require("duke.picker").confirm(
          string.format("Apply %d Maven version changes?", #descriptor.changes),
          "Apply"
        )
        if vim.api.nvim_win_is_valid(preview) then
          vim.api.nvim_win_close(preview, true)
        end
        if not confirmed then
          return
        end
        require("duke.api").apply_plan(
          descriptor,
          guarded("apply completion", function(apply_err)
            if apply_err then
              vim.notify("duke.nvim: " .. apply_err, vim.log.levels.ERROR)
              return
            end
            vim.notify("duke.nvim: Maven upgrade plan applied")
            refresh(false)
          end)
        )
      end)
    )
  end

  if node and node.kind == "dependency" then
    for _, dependency in ipairs(choices) do
      if dependency.coordinate == node.coordinate then
        build({ dependency })
        return
      end
    end
    vim.notify("duke.nvim: selected dependency has no writable Maven version")
    return
  end

  require("duke.picker").select_many(choices, {
    prompt = "Plan Maven upgrades",
    format_item = function(item)
      return item.coordinate .. "  " .. item.version
    end,
  }, guarded("upgrade selection", build))
end

local function doctor_finding(node)
  if node and node.kind == "doctor_finding" then
    return node.finding
  end
end

diagnose = function(deep)
  if not valid_buffer() or not center.doctor then
    return
  end
  center.doctor.generation = center.doctor.generation + 1
  local generation = center.doctor.generation
  center.doctor.busy = true
  center.doctor.error = nil
  render(center.snapshot)
  require("duke.api").diagnose_workspace(
    { path = center.path, deep = deep == true },
    guarded("Doctor completion", function(err, diagnosis)
      if
        not valid_buffer()
        or not center
        or not center.doctor
        or generation ~= center.doctor.generation
      then
        return
      end
      center.doctor.busy = false
      if err then
        center.doctor.error = err
        require("duke.log").add("ERROR", err)
        render(center.snapshot)
        return
      end
      center.doctor.error = nil
      center.doctor.diagnosis = diagnosis
      center.doctor.selected_repairs = {}
      center.doctor.plan = nil
      local receipt = center.doctor.receipt
      if receipt and receipt.pending then
        local current = {}
        for _, finding in ipairs(diagnosis.findings or {}) do
          current[finding.id] = true
        end
        local remaining = 0
        local total = 0
        for id in pairs(receipt.before_ids) do
          total = total + 1
          if current[id] then
            remaining = remaining + 1
          end
        end
        receipt.fixed = total - remaining
        receipt.remaining = remaining
        receipt.pending = false
      end
      render(center.snapshot)
    end)
  )
end

local function stage_upgrade(node)
  local finding = doctor_finding(node)
  if not finding then
    plan_upgrades(node)
    return
  end
  if not finding.repairable then
    vim.notify("duke.nvim: " .. tostring(finding.blocked_reason or "finding is not repairable"))
    return
  end
  require("duke.picker").input(
    "New version for " .. finding.coordinate .. ": ",
    finding.selected_version or "",
    guarded("Doctor version input", function(value)
      value = value and vim.trim(value) or ""
      if value == "" or not valid_buffer() then
        return
      end
      center.doctor.selected_repairs[finding.id] = {
        finding_id = finding.id,
        new_version = value,
      }
      center.doctor.plan = nil
      render(center.snapshot)
    end)
  )
end

local function stage_exclusion(node)
  local finding = doctor_finding(node)
  if not finding then
    module_action(node, "remove_dependency")
    return
  end
  if finding.kind ~= "version_conflict" or #(finding.paths or {}) == 0 then
    vim.notify("duke.nvim: selected finding has no excludable dependency path")
    return
  end
  local choices = {}
  for index, path in ipairs(finding.paths) do
    choices[#choices + 1] = { index = index, name = table.concat(path, " -> ") }
  end
  require("duke.picker").select_one(
    choices,
    {
      prompt = "Select dependency path to exclude",
      format_item = function(item)
        return item.name
      end,
    },
    guarded("Doctor exclusion selection", function(choice)
      if not choice or not valid_buffer() then
        return
      end
      center.doctor.selected_repairs[finding.id] = {
        finding_id = finding.id,
        action = "exclude",
        path_index = choice.index,
      }
      center.doctor.plan = nil
      render(center.snapshot)
    end)
  )
end

local function build_doctor_plan()
  local doctor = center and center.doctor
  if not doctor or not doctor.diagnosis or doctor.busy then
    return
  end
  local repairs = vim.tbl_values(doctor.selected_repairs)
  table.sort(repairs, function(left, right)
    return left.finding_id < right.finding_id
  end)
  if #repairs == 0 then
    vim.notify("duke.nvim: select at least one Doctor repair")
    return
  end
  doctor.generation = doctor.generation + 1
  local generation = doctor.generation
  doctor.busy = true
  doctor.error = nil
  render(center.snapshot)
  require("duke.api").plan_repairs(
    {
      diagnosis_id = doctor.diagnosis.id,
      repairs = repairs,
    },
    guarded("Doctor plan completion", function(err, descriptor)
      if not valid_buffer() or not center or generation ~= center.doctor.generation then
        return
      end
      center.doctor.busy = false
      if err then
        center.doctor.error = err
        render(center.snapshot)
        return
      end
      center.doctor.plan = descriptor
      render(center.snapshot)
      show_plan_preview(descriptor)
    end)
  )
end

local function apply_doctor_plan()
  local doctor = center and center.doctor
  if not doctor or not doctor.plan or doctor.busy then
    vim.notify("duke.nvim: build a Doctor plan before applying")
    return
  end
  local preview = doctor.plan.preview
  local consumers = {}
  local seen_consumers = {}
  for _, file in ipairs(preview.files or {}) do
    for _, change in ipairs(file.changes or {}) do
      for _, consumer in ipairs(change.consumers or {}) do
        if not seen_consumers[consumer] then
          seen_consumers[consumer] = true
          consumers[#consumers + 1] = consumer
        end
      end
    end
  end
  table.sort(consumers)
  local message = string.format(
    "Apply Maven repairs to %d file%s (%d modified buffer%s)?",
    preview.file_count or 0,
    preview.file_count == 1 and "" or "s",
    preview.modified_buffer_count or 0,
    preview.modified_buffer_count == 1 and "" or "s"
  )
  if #consumers > 0 then
    message = message .. "\nShared consumers: " .. table.concat(consumers, ", ")
  end
  if not require("duke.picker").confirm(message, "Apply") then
    require("duke.reactor_plan").discard(doctor.plan)
    doctor.plan = nil
    render(center.snapshot)
    return
  end
  local before_ids = {}
  for id in pairs(doctor.selected_repairs) do
    before_ids[id] = true
  end
  local descriptor = doctor.plan
  doctor.generation = doctor.generation + 1
  local generation = doctor.generation
  doctor.busy = true
  render(center.snapshot)
  require("duke.api").apply_reactor_plan(
    descriptor,
    guarded("Doctor apply completion", function(err, result)
      if not valid_buffer() or not center or generation ~= center.doctor.generation then
        return
      end
      center.doctor.busy = false
      if err or not result or not result.ok then
        center.doctor.error = err or (result and result.error) or "reactor repair failed"
        render(center.snapshot)
        return
      end
      center.doctor.plan = nil
      center.doctor.selected_repairs = {}
      center.doctor.receipt = {
        pending = true,
        before_ids = before_ids,
        fixed = 0,
        remaining = vim.tbl_count(before_ids),
        result = vim.deepcopy(result),
      }
      render(center.snapshot)
    end)
  )
end

local function confirm_deep_diagnosis()
  if
    require("duke.picker").confirm(
      "Deep Maven analysis may compile main and test sources. Continue?",
      "Analyze"
    )
  then
    diagnose(true)
  end
end

local function set_keymaps(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "q", guarded("close", close), opts)
  vim.keymap.set(
    "n",
    "<CR>",
    guarded("open", function()
      open_node(selected_node())
    end),
    opts
  )
  vim.keymap.set(
    "n",
    "r",
    guarded("refresh", function()
      refresh(true)
    end),
    opts
  )
  vim.keymap.set(
    "n",
    "a",
    guarded("add", function()
      module_action(selected_node(), "add_dependency")
    end),
    opts
  )
  vim.keymap.set(
    "n",
    "x",
    guarded("remove", function()
      stage_exclusion(selected_node())
    end),
    opts
  )
  vim.keymap.set(
    "n",
    "p",
    guarded("paths", function()
      dependency_paths(selected_node())
    end),
    opts
  )
  vim.keymap.set(
    "n",
    "g",
    guarded("declaration", function()
      jump_to_declaration(selected_node())
    end),
    opts
  )
  vim.keymap.set(
    "n",
    "u",
    guarded("upgrade", function()
      stage_upgrade(selected_node())
    end),
    opts
  )
  vim.keymap.set("n", "?", guarded("help", show_help), opts)
  vim.keymap.set(
    "n",
    "d",
    guarded("Doctor", function()
      diagnose(false)
    end),
    opts
  )
  vim.keymap.set("n", "L", guarded("deep Doctor", confirm_deep_diagnosis), opts)
  vim.keymap.set("n", "P", guarded("Doctor plan", build_doctor_plan), opts)
  vim.keymap.set("n", "A", guarded("Doctor apply", apply_doctor_plan), opts)
  vim.keymap.set(
    "n",
    "c",
    guarded("Doctor clear", function()
      if center and center.doctor then
        center.doctor.selected_repairs = {}
        center.doctor.plan = nil
        render(center.snapshot)
      end
    end),
    opts
  )
  vim.keymap.set(
    "n",
    "R",
    guarded("Doctor proof refresh", function()
      diagnose(false)
    end),
    opts
  )
  vim.keymap.set("n", "/", guarded("search", search_nodes), opts)
  vim.keymap.set("n", "l", guarded("log", require("duke.log").show), opts)
end

function M.toggle(opts)
  if valid_buffer() then
    if opts and opts.doctor then
      if valid_window() then
        vim.api.nvim_set_current_win(center.win)
      end
      if not center.doctor.busy then
        if opts.deep then
          confirm_deep_diagnosis()
        else
          diagnose(false)
        end
      end
      return
    end
    close()
    return
  end
  opts = opts or {}
  local path = opts.path
  path = path and path ~= "" and path or vim.api.nvim_buf_get_name(0)
  path = path ~= "" and path or vim.fn.getcwd()
  local origin_win = vim.api.nvim_get_current_win()
  vim.cmd("botright 42vnew")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "duke-project-center"
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  center = {
    buf = buf,
    win = win,
    origin_win = origin_win,
    path = path,
    generation = 0,
    snapshot = latest and latest.path == path and vim.deepcopy(latest.snapshot) or nil,
    doctor = {
      busy = false,
      generation = 0,
      diagnosis = nil,
      selected_repairs = {},
      plan = nil,
      receipt = nil,
      error = nil,
    },
  }
  set_keymaps(buf)
  if center.snapshot then
    render(center.snapshot)
  else
    render(nil, "loading")
    refresh(false)
  end
  if vim.api.nvim_win_is_valid(origin_win) then
    vim.api.nvim_set_current_win(origin_win)
  end
  if opts.doctor then
    if opts.deep then
      confirm_deep_diagnosis()
    else
      diagnose(false)
    end
  end
end

function M.close()
  close()
end

function M.state()
  return center
      and vim.deepcopy({
        buf = center.buf,
        win = center.win,
        path = center.path,
        snapshot = center.snapshot,
        doctor = center.doctor,
      })
    or nil
end

local function snapshot_owns_path(snapshot, path)
  path = vim.fs.normalize(path)
  for _, module in ipairs((snapshot and snapshot.modules) or {}) do
    if module.build_file and vim.fs.normalize(module.build_file) == path then
      return true
    end
  end
  for _, key in ipairs({ "build_file", "settings_file", "version_catalog", "wrapper" }) do
    local value = snapshot and snapshot.environment and snapshot.environment[key]
    if value and vim.fs.normalize(value) == path then
      return true
    end
  end
  return false
end

local cache_group = vim.api.nvim_create_augroup("duke_project_center_cache", { clear = true })
vim.api.nvim_create_autocmd("BufWritePost", {
  group = cache_group,
  callback = guarded("cache invalidation", function(args)
    local path = vim.api.nvim_buf_get_name(args.buf)
    if path == "" then
      return
    end
    if latest and snapshot_owns_path(latest.snapshot, path) then
      latest = nil
    end
    if center and center.snapshot and snapshot_owns_path(center.snapshot, path) then
      center.snapshot = nil
      center.doctor.generation = center.doctor.generation + 1
      center.doctor.busy = false
      center.doctor.diagnosis = nil
      center.doctor.selected_repairs = {}
      center.doctor.plan = nil
      center.doctor.error = nil
      refresh(false)
    end
  end),
})

return M
