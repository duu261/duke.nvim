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
    heading("Modules", #(snapshot.modules or {}))
    for _, module in ipairs(snapshot.modules or {}) do
      node(module.id, { kind = "module", label = module.id, path = module.build_file, line = 1 })
    end
    lines[#lines + 1] = ""
    heading("Dependencies", #(snapshot.dependencies or {}))
    for _, dependency in ipairs(snapshot.dependencies or {}) do
      local module = module_by_id(snapshot, dependency.module_id)
      local suffix = dependency.version and ("  " .. dependency.version) or ""
      node(dependency.coordinate .. suffix, {
        kind = "dependency",
        label = dependency.coordinate,
        path = module and module.build_file,
        line = dependency.line,
      })
    end
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
      node(item.severity .. "  " .. item.message, {
        kind = "diagnostic",
        label = item.message,
      })
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "<CR> open  r resolve  / search  ? help  q close"

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

local function set_keymaps(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<CR>", function()
    open_node(selected_node())
  end, opts)
  vim.keymap.set("n", "r", function()
    refresh(true)
  end, opts)
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
