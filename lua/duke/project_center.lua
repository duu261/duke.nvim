local M = {}

local namespace = vim.api.nvim_create_namespace("duke_project_center")
local center

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

local function resolved_dependency_versions(snapshot)
  local versions = {}
  local analysis = snapshot and snapshot.analysis
  for _, dependency in ipairs((analysis and analysis.dependencies) or {}) do
    if dependency.direct then
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
  local nodes = {}
  local function heading(label, count)
    lines[#lines + 1] = string.format("%s (%d)", label, count)
  end
  local function node(label, value)
    lines[#lines + 1] = "  " .. label
    nodes[#lines] = value
  end

  if snapshot then
    local resolved_versions = resolved_dependency_versions(snapshot)
    heading("Modules", #(snapshot.modules or {}))
    for _, module in ipairs(snapshot.modules or {}) do
      node(module.id, { kind = "module", label = module.id, path = module.build_file, line = 1 })
    end
    lines[#lines + 1] = ""
    heading("Dependencies", #(snapshot.dependencies or {}))
    for _, dependency in ipairs(snapshot.dependencies or {}) do
      local module = module_by_id(snapshot, dependency.module_id)
      local resolved = resolved_versions[dependency.module_id .. "\0" .. dependency.coordinate]
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
        path = module and module.build_file,
        line = dependency.line,
      })
    end
    lines[#lines + 1] = ""
    if snapshot.analysis then
      local dependencies = snapshot.analysis.dependencies or {}
      local findings = snapshot.analysis.findings or {}
      local transitive = 0
      for _, dependency in ipairs(dependencies) do
        if not dependency.direct then
          transitive = transitive + 1
        end
      end
      heading("Resolved nodes", #dependencies)
      node("Transitive dependencies  " .. transitive, { kind = "analysis" })
      node("Conflicts  " .. #(findings.conflicts or {}), { kind = "analysis" })
      node("Version drift  " .. #(findings.drift or {}), { kind = "analysis" })
      node("Duplicate declarations  " .. #(findings.duplicates or {}), { kind = "analysis" })
      lines[#lines + 1] = ""
    end
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
      node(item.severity .. "  " .. item.message, {
        kind = "diagnostic",
        label = item.message,
      })
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "<CR> open  r resolve  u upgrade  / search  ? help  q close"

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

local function open_node(node)
  if not node or not node.path or not vim.uv.fs_stat(node.path) then
    return
  end
  local target = center and center.origin_win
  if not target or not vim.api.nvim_win_is_valid(target) then
    target = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(target)
  vim.cmd.edit(vim.fn.fnameescape(node.path))
  if node.line then
    pcall(vim.api.nvim_win_set_cursor, target, { node.line, 0 })
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
  render(center.snapshot, resolve and "resolving" or "loading")
  require("duke.workspace").inspect(
    { path = center.path, resolve = resolve },
    function(err, snapshot)
      if not valid_buffer() or not center or generation ~= center.generation then
        return
      end
      if err then
        render(center.snapshot, "failed")
        require("duke.log").add("ERROR", err)
        return
      end
      center.snapshot = snapshot
      render(snapshot)
    end
  )
end

local function show_help()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "Duke Project Center",
    "",
    "<CR>  Open module build file or Spring configuration",
    "r     Resolve workspace through Maven or Gradle wrapper",
    "u     Plan upgrades for the active Maven module",
    "/     Search visible project nodes",
    "q     Close Project Center",
  })
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = buf, silent = true })
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = 64,
    height = 6,
    row = math.max(0, math.floor((vim.o.lines - 6) / 2)),
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
    choices[#choices + 1] = node
  end
  table.sort(choices, function(left, right)
    return left.label < right.label
  end)
  require("duke.picker").select_one(choices, {
    prompt = "Duke Project Center",
    format_item = function(item)
      return item.label
    end,
  }, open_node)
end

local function show_plan_preview(descriptor)
  local lines = { "Before", "" }
  vim.list_extend(lines, descriptor.preview.before)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "After"
  lines[#lines + 1] = ""
  vim.list_extend(lines, descriptor.preview.after)
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
    title = "Maven upgrade plan",
    title_pos = "center",
  })
  return win
end

local function plan_upgrades()
  local snapshot = center and center.snapshot
  if not snapshot or snapshot.kind ~= "maven" or not snapshot.active_module then
    vim.notify("duke.nvim: select an active Maven module before planning upgrades")
    return
  end
  local module = module_by_id(snapshot, snapshot.active_module)
  local choices = {}
  for _, dependency in ipairs(snapshot.dependencies or {}) do
    if dependency.module_id == snapshot.active_module and dependency.version then
      choices[#choices + 1] = dependency
    end
  end
  require("duke.picker").select_many(choices, {
    prompt = "Plan Maven upgrades",
    format_item = function(item)
      return item.coordinate .. "  " .. item.version
    end,
  }, function(selected)
    if not selected or #selected == 0 or not valid_buffer() then
      return
    end
    local changes = {}
    for _, dependency in ipairs(selected) do
      changes[#changes + 1] = { coordinate = dependency.coordinate }
    end
    require("duke.api").plan_upgrades({
      pom_path = module.build_file,
      changes = changes,
    }, function(err, descriptor)
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
      require("duke.api").apply_plan(descriptor, function(apply_err)
        if apply_err then
          vim.notify("duke.nvim: " .. apply_err, vim.log.levels.ERROR)
          return
        end
        vim.notify("duke.nvim: Maven upgrade plan applied")
        refresh(false)
      end)
    end)
  end)
end

local function set_keymaps(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<CR>", function()
    open_node(selected_node())
  end, opts)
  vim.keymap.set("n", "r", function()
    refresh(true)
  end, opts)
  vim.keymap.set("n", "u", plan_upgrades, opts)
  vim.keymap.set("n", "?", show_help, opts)
  vim.keymap.set("n", "/", search_nodes, opts)
end

function M.toggle(opts)
  if valid_buffer() then
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
  }
  set_keymaps(buf)
  render(nil, "loading")
  refresh(false)
  if vim.api.nvim_win_is_valid(origin_win) then
    vim.api.nvim_set_current_win(origin_win)
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
      })
    or nil
end

return M
