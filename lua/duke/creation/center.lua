local M = {}

local namespace = vim.api.nvim_create_namespace("duke_creation_center")
local next_session = 0
local active_session

local Session = {}
Session.__index = Session

local java_lts_versions = {
  ["8"] = true,
  ["11"] = true,
  ["17"] = true,
  ["21"] = true,
  ["25"] = true,
}

local function format_java_version(version)
  local value = tostring(version)
  return java_lts_versions[value] and (value .. "  (LTS)") or value
end

function M.choose_layout(columns, lines, preference)
  if preference == "wide" then
    return "wide"
  end
  if preference == "compact" or preference == "narrow" then
    return "narrow"
  end
  return (columns < 100 or lines < 28) and "narrow" or "wide"
end

local function valid_buffer(self)
  return self.buf and vim.api.nvim_buf_is_valid(self.buf)
end

local function valid_window(self)
  return self.win and vim.api.nvim_win_is_valid(self.win)
end

local function cursor_for_action(self)
  local action = self.rendered_view.actions[self.action_index]
  if action and valid_window(self) then
    pcall(vim.api.nvim_win_set_cursor, self.win, { action.line, action.col or 0 })
  end
end

local function render(self)
  if self.closed or not valid_buffer(self) then
    return false
  end
  local previous_action = self.rendered_view
      and self.rendered_view.actions[self.action_index or 1]
      and self.rendered_view.actions[self.action_index or 1].id
    or nil
  local snapshot = self.model:snapshot()
  snapshot.help = self.help
  local render_module = require("duke.creation.render")
  local render_opts = { layout = self.layout, width = self.width, height = self.height }
  if self.view == "dependencies" and self.dependency_view then
    self.rendered_view =
      render_module.dependencies(snapshot, self.dependency_view:snapshot(), render_opts)
  else
    self.rendered_view = render_module.settings(snapshot, render_opts)
  end
  local desired_action = self.rendered_view.cursor_action or previous_action
  if desired_action then
    for index, action in ipairs(self.rendered_view.actions) do
      if action.id == desired_action then
        self.action_index = index
        break
      end
    end
  end
  self.action_index = math.max(1, math.min(self.action_index or 1, #self.rendered_view.actions))
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, self.rendered_view.lines)
  vim.bo[self.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.buf, namespace, 0, -1)
  for _, highlight in ipairs(self.rendered_view.highlights) do
    pcall(vim.api.nvim_buf_set_extmark, self.buf, namespace, highlight.line - 1, highlight.col, {
      end_col = highlight.end_col,
      hl_group = highlight.group,
    })
  end
  cursor_for_action(self)
  return true
end

local function report_callback_error(self, context, err)
  local detail = context .. " failed: " .. tostring(err)
  pcall(function()
    require("duke.log").add("ERROR", detail)
  end)
  if self and self.model then
    pcall(self.model.set_busy, self.model, false)
    pcall(self.model.set_banner, self.model, context .. " failed; see :DukeLog")
    pcall(render, self)
  end
  pcall(vim.notify, "duke.nvim: " .. context .. " failed; see :DukeLog", vim.log.levels.ERROR)
end

local function guarded(self, context, callback)
  return function(...)
    local args = { ... }
    local ok, err = xpcall(function()
      callback(unpack(args))
    end, debug.traceback)
    if not ok then
      report_callback_error(self, context, err)
    end
  end
end

local function restore_origin(self)
  if self.layout ~= "narrow" or not self.origin then
    return
  end
  local origin = self.origin
  if vim.api.nvim_win_is_valid(origin.win) and vim.api.nvim_buf_is_valid(origin.buf) then
    pcall(vim.api.nvim_win_set_buf, origin.win, origin.buf)
    pcall(vim.api.nvim_set_current_win, origin.win)
    pcall(vim.fn.winrestview, origin.view)
    pcall(vim.api.nvim_win_set_cursor, origin.win, origin.cursor)
  end
  pcall(vim.cmd.cd, vim.fn.fnameescape(origin.cwd))
end

local function close(self, restore, buffer_closing)
  if self.closed or self.closing then
    return false
  end
  self.closing = true
  self.model:close()
  if restore then
    restore_origin(self)
  end
  if self.layout == "wide" and valid_window(self) then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  if not buffer_closing and valid_buffer(self) then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  self.closed = true
  self.closing = false
  if active_session == self then
    active_session = nil
  end
  return true
end

function Session:snapshot()
  return {
    id = self.id,
    layout = self.layout,
    buf = self.buf,
    win = self.win,
    view = self.view,
    model = self.model:snapshot(),
  }
end

function Session:rendered()
  return vim.deepcopy(self.rendered_view)
end

function Session:is_open()
  return not self.closed and valid_buffer(self) and valid_window(self)
end

function Session:move(delta)
  if not self:is_open() or self.model:snapshot().busy then
    return false
  end
  if self.view == "dependencies" then
    self.dependency_view:move(delta)
    render(self)
    return true
  end
  if self.layout == "wide" then
    local current = self.rendered_view.actions[self.action_index]
    local pane_indices = {}
    for index, action in ipairs(self.rendered_view.actions) do
      if action.pane == current.pane then
        pane_indices[#pane_indices + 1] = index
      end
    end
    local position = vim.fn.index(pane_indices, self.action_index) + 1
    position = math.max(1, math.min(position + delta, #pane_indices))
    self.action_index = pane_indices[position]
  else
    self.action_index =
      math.max(1, math.min(self.action_index + delta, #self.rendered_view.actions))
  end
  cursor_for_action(self)
  return true
end

function Session:cycle_pane(delta)
  if self.view == "dependencies" then
    return self:dependency_cycle(delta)
  end
  if self.layout ~= "wide" then
    return self:move(delta)
  end
  local panes = { "generators", "fields" }
  local current = self.rendered_view.actions[self.action_index]
  local pane_index = vim.fn.index(panes, current.pane) + 1
  local target_pane = panes[((pane_index - 1 + delta) % #panes) + 1]
  for index, action in ipairs(self.rendered_view.actions) do
    if action.pane == target_pane then
      self.action_index = index
      cursor_for_action(self)
      return true
    end
  end
  return false
end

local function field_by_id(snapshot, id)
  for _, field in ipairs(snapshot.fields or {}) do
    if field.id == id then
      return field
    end
  end
end

local function edit_field(self, id)
  local snapshot = self.model:snapshot()
  local field = field_by_id(snapshot, id)
  if not field then
    return nil, "unknown creation field: " .. tostring(id)
  end
  local picker = require("duke.picker")
  local current = snapshot.values[id]
  if field.editor == "dependencies" then
    local items = snapshot.derived.spring_dependency_items or {}
    if #items == 0 then
      self.model:set_banner("Spring dependency catalog is not ready")
      render(self)
      return false
    end
    self.dependency_view = require("duke.creation.spring_dependencies").new(items, current)
    self.view = "dependencies"
    self.action_index = 1
    render(self)
    return true
  end
  if field.editor == "input" then
    picker.input(
      field.label .. ": ",
      current,
      guarded(self, "field edit", function(value)
        if value ~= nil and self:is_open() then
          value = vim.trim(value)
          if id == "destination" and value ~= "" then
            value = vim.fs.normalize(vim.fn.fnamemodify(value, ":p"))
            if vim.fn.isdirectory(value) ~= 1 then
              self.model:set_banner("destination directory does not exist: " .. value)
              render(self)
              return
            end
          end
          self.model:set(id, value)
          render(self)
        end
      end)
    )
    return true
  end
  if field.editor == "select" then
    local choices = field.choices
      or snapshot.derived[field.id .. "_choices"]
      or snapshot.derived.java_versions
      or {}
    if #choices == 0 then
      self.model:set_banner(field.label .. " choices are not ready")
      render(self)
      return false
    end
    picker.select_one(
      choices,
      {
        prompt = field.label,
        default = current,
        format_item = id == "java_version" and format_java_version or nil,
      },
      guarded(self, "field selection", function(value)
        if value ~= nil and self:is_open() then
          if field.id:match("_id$") and type(value) == "table" then
            value = value.id
          end
          self.model:set(id, value)
          render(self)
          if id == "boot_version" and self.discover_fn then
            local scope = "catalog"
            local ok, err = pcall(self.discover_fn, self, scope)
            if not ok then
              self.model:set_banner(err)
              require("duke.log").add("ERROR", tostring(err))
              render(self)
            end
          end
        end
      end)
    )
    return true
  end
  return false
end

local function activate(self, action_id)
  if not self:is_open() or self.model:snapshot().busy then
    return false
  end
  if self.view == "dependencies" then
    local category = action_id and action_id:match("^dependency:category:(%d+)$")
    if category then
      self.dependency_view:set_category(category)
      render(self)
      return true
    end
    local item = action_id and action_id:match("^dependency:item:(.+)$")
    if item then
      self.dependency_view:set_result(item)
      self.dependency_view:toggle()
      render(self)
      return true
    end
    return self:dependency_accept()
  end
  action_id = action_id or (self.rendered_view.actions[self.action_index] or {}).id
  local kind = action_id and action_id:match("^generator:(.+)$")
  if kind then
    local changed = self.model:switch(kind)
    render(self)
    if changed and self.discover_fn then
      local ok, err = pcall(self.discover_fn, self, "all")
      if not ok then
        self.model:set_banner(err)
        require("duke.log").add("ERROR", tostring(err))
        render(self)
      end
    end
    return changed == true
  end
  local field = action_id and action_id:match("^field:(.+)$")
  if field then
    return edit_field(self, field)
  end
  if action_id == "create" then
    return self:submit()
  end
  return false
end

function Session:activate(action_id)
  local ok, result, err = pcall(activate, self, action_id)
  if ok then
    return result, err
  end
  pcall(self.model.set_banner, self.model, result)
  pcall(function()
    require("duke.log").add("ERROR", tostring(result))
  end)
  pcall(render, self)
  return false
end

function Session:submit()
  if not self:is_open() then
    return false
  end
  local request, errors = self.model:request()
  if not request then
    if errors then
      local snapshot = self.model:snapshot()
      for index, action in ipairs(self.rendered_view.actions) do
        local field = action.id:match("^field:(.+)$")
        if field and snapshot.errors[field] then
          self.action_index = index
          break
        end
      end
      cursor_for_action(self)
    end
    return false
  end
  local target = vim.fs.joinpath(request.cwd, request.artifact_id)
  local stat_ok, stat = pcall(vim.uv.fs_stat, target)
  if stat_ok and stat then
    self.model:set_banner("target already exists: " .. target)
    render(self)
    return false
  end
  if self.confirm then
    local confirm_ok, confirmed = pcall(require("duke.picker").confirm, "Create project?", "Create")
    if not confirm_ok then
      report_callback_error(self, "creation confirmation", confirmed)
      return false
    end
    if not confirmed then
      return false
    end
  end
  self.model:set_banner(nil)
  self.model:set_busy(true)
  render(self)
  local completed = false
  local kind = self.model:snapshot().kind
  local ok, start_error = pcall(
    self.submit_fn,
    kind,
    vim.deepcopy(request),
    guarded(self, "generator callback", function(err, dir)
      if completed or self.closed then
        return
      end
      completed = true
      if err then
        self.model:set_busy(false)
        self.model:set_banner(err)
        require("duke.log").add("ERROR", tostring(err))
        render(self)
        return
      end
      close(self, false)
      local finish_ok, finish_error = pcall(self.finish_fn, dir)
      if not finish_ok then
        require("duke.log").add("ERROR", "project finish failed: " .. tostring(finish_error))
      end
    end)
  )
  if not ok then
    completed = true
    self.model:set_busy(false)
    self.model:set_banner(start_error)
    require("duke.log").add("ERROR", tostring(start_error))
    render(self)
    return false
  end
  return true
end

function Session:cancel(force)
  if not self:is_open() then
    return false
  end
  local snapshot = self.model:snapshot()
  if snapshot.busy then
    return false
  end
  local dependency_dirty = self.dependency_view and self.dependency_view:dirty()
  if not force and (snapshot.dirty or dependency_dirty) then
    local confirm_ok, confirmed =
      pcall(require("duke.picker").confirm, "Discard project creation changes?", "Discard")
    if not confirm_ok then
      report_callback_error(self, "cancel confirmation", confirmed)
      return false
    end
    if not confirmed then
      return false
    end
  end
  return close(self, true)
end

function Session:dependency_focus(pane)
  if self.view ~= "dependencies" then
    return false
  end
  local changed = self.dependency_view:focus(pane)
  render(self)
  return changed == true
end

function Session:dependency_cycle(delta)
  if self.view ~= "dependencies" then
    return false
  end
  self.dependency_view:cycle_pane(delta)
  render(self)
  return true
end

function Session:dependency_toggle()
  if self.view ~= "dependencies" then
    return false
  end
  local changed = self.dependency_view:toggle()
  render(self)
  return changed
end

local function leave_dependencies(self, selected)
  self.model:set("dependency_ids", selected)
  self.view = "settings"
  self.dependency_view = nil
  self.action_index = 1
  render(self)
  return true
end

function Session:dependency_accept()
  if self.view ~= "dependencies" then
    return false
  end
  return leave_dependencies(self, self.dependency_view:accept())
end

function Session:dependency_back()
  if self.view ~= "dependencies" then
    return false
  end
  return leave_dependencies(self, self.dependency_view:back())
end

function Session:dependency_search()
  if self.view ~= "dependencies" then
    return false
  end
  require("duke.picker").input(
    "Spring dependency search: ",
    self.dependency_view:snapshot().query,
    guarded(self, "dependency search", function(value)
      if value ~= nil and self:is_open() and self.view == "dependencies" then
        self.dependency_view:set_query(value)
        render(self)
      end
    end)
  )
  return true
end

function Session:refresh()
  return render(self)
end

local function set_keymaps(self)
  local opts = { buffer = self.buf, silent = true, nowait = true }
  vim.keymap.set(
    "n",
    "j",
    guarded(self, "navigation", function()
      self:move(1)
    end),
    opts
  )
  vim.keymap.set(
    "n",
    "k",
    guarded(self, "navigation", function()
      self:move(-1)
    end),
    opts
  )
  vim.keymap.set(
    "n",
    "<Tab>",
    guarded(self, "pane navigation", function()
      if self.view == "dependencies" then
        self:dependency_cycle(1)
      else
        self:cycle_pane(1)
      end
    end),
    opts
  )
  vim.keymap.set(
    "n",
    "<S-Tab>",
    guarded(self, "pane navigation", function()
      if self.view == "dependencies" then
        self:dependency_cycle(-1)
      else
        self:cycle_pane(-1)
      end
    end),
    opts
  )
  vim.keymap.set(
    "n",
    "<CR>",
    guarded(self, "action", function()
      self:activate()
    end),
    opts
  )
  vim.keymap.set(
    "n",
    "c",
    guarded(self, "creation", function()
      self:submit()
    end),
    opts
  )
  vim.keymap.set(
    "n",
    "?",
    guarded(self, "help", function()
      self.help = not self.help
      render(self)
    end),
    opts
  )
  vim.keymap.set(
    "n",
    "q",
    guarded(self, "cancel", function()
      self:cancel()
    end),
    opts
  )
  vim.keymap.set(
    "n",
    "<Space>",
    guarded(self, "dependency toggle", function()
      self:dependency_toggle()
    end),
    opts
  )
  vim.keymap.set(
    "n",
    "/",
    guarded(self, "dependency search", function()
      self:dependency_search()
    end),
    opts
  )
  vim.keymap.set(
    "n",
    "b",
    guarded(self, "dependency back", function()
      self:dependency_back()
    end),
    opts
  )
end

function M.open(opts)
  assert(type(opts) == "table" and opts.model, "creation model is required")
  if active_session and active_session:is_open() then
    if not active_session:cancel(true) then
      pcall(vim.api.nvim_set_current_win, active_session.win)
      pcall(opts.model.close, opts.model)
      return active_session
    end
  end
  next_session = next_session + 1
  local layout = M.choose_layout(vim.o.columns, vim.o.lines, opts.layout)
  local origin_win = vim.api.nvim_get_current_win()
  local origin_buf = vim.api.nvim_get_current_buf()
  local startup_origin = {
    win = origin_win,
    buf = origin_buf,
    view = vim.fn.winsaveview(),
    cursor = vim.api.nvim_win_get_cursor(origin_win),
    cwd = vim.fn.getcwd(),
  }
  local width = math.max(40, math.floor(vim.o.columns * 0.85))
  local height = math.max(12, math.floor((vim.o.lines - vim.o.cmdheight) * 0.9))
  local buf
  local win
  local self
  local ok, result = xpcall(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "duke-creation"

    local origin
    if layout == "wide" then
      win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = math.min(width, vim.o.columns - 2),
        height = math.min(height, vim.o.lines - vim.o.cmdheight - 2),
        row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        style = "minimal",
        border = "rounded",
        title = " Duke Creation Center ",
        title_pos = "center",
      })
    else
      origin = startup_origin
      win = origin_win
      vim.api.nvim_win_set_buf(win, buf)
    end

    self = setmetatable({
      id = next_session,
      model = opts.model,
      config = opts.config,
      submit_fn = opts.submit,
      finish_fn = opts.finish,
      discover_fn = opts.discover,
      confirm = opts.confirm ~= false,
      layout = layout,
      width = width,
      height = height,
      origin = origin,
      buf = buf,
      win = win,
      action_index = 1,
      help = false,
      view = "settings",
      closed = false,
      closing = false,
    }, Session)
    self.augroup = vim.api.nvim_create_augroup("DukeCreationCenter" .. self.id, { clear = true })
    vim.api.nvim_create_autocmd({ "BufWipeout", "WinClosed" }, {
      group = self.augroup,
      callback = guarded(self, "Creation Center cleanup", function(event)
        if not self.closing and (event.buf == self.buf or tonumber(event.match) == self.win) then
          close(self, self.layout == "narrow", event.event == "BufWipeout")
        end
      end),
    })
    set_keymaps(self)
    render(self)
    if self.discover_fn then
      local discover_ok, err = pcall(self.discover_fn, self, "all")
      if not discover_ok then
        self.model:set_banner(err)
        require("duke.log").add("ERROR", tostring(err))
        render(self)
      end
    end
    active_session = self
    return self
  end, debug.traceback)
  if ok then
    return result
  end

  if self and self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  end
  if win and win ~= origin_win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if vim.api.nvim_win_is_valid(origin_win) and vim.api.nvim_buf_is_valid(origin_buf) then
    pcall(vim.api.nvim_set_current_win, origin_win)
    pcall(vim.api.nvim_win_set_buf, origin_win, origin_buf)
    pcall(vim.fn.winrestview, startup_origin.view)
    pcall(vim.api.nvim_win_set_cursor, origin_win, startup_origin.cursor)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  pcall(vim.cmd.cd, vim.fn.fnameescape(startup_origin.cwd))
  pcall(opts.model.close, opts.model)
  error(result, 0)
end

return M
