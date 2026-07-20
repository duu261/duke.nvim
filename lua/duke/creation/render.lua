local M = {}

local kind_names = {
  maven = "Maven",
  gradle = "Gradle",
  spring = "Spring Boot",
}

local function add_line(view, text, highlight)
  view.lines[#view.lines + 1] = text
  if highlight then
    view.highlights[#view.highlights + 1] = {
      group = highlight,
      line = #view.lines,
      col = 0,
      end_col = -1,
    }
  end
  return #view.lines
end

local function add_action(view, id, text, pane, enabled)
  local line = add_line(view, text)
  view.actions[#view.actions + 1] = {
    id = id,
    line = line,
    pane = view.layout == "narrow" and "main" or pane,
    enabled = enabled ~= false,
  }
end

local function display(value)
  if type(value) == "table" then
    if value.name then
      return value.name
    end
    if vim.islist(value) then
      return #value == 0 and "none" or table.concat(value, ", ")
    end
    return "selected"
  end
  if value == nil or value == "" then
    return "not set"
  end
  return tostring(value)
end

local function render_generators(view, snapshot)
  add_line(view, "Generator", "DukeHeading")
  for _, kind in ipairs({ "maven", "gradle", "spring" }) do
    local marker = snapshot.kind == kind and "●" or "○"
    add_action(view, "generator:" .. kind, "  " .. marker .. " " .. kind_names[kind], "generators")
  end
end

local function render_fields(view, snapshot)
  add_line(view, "")
  add_line(view, "Project settings", "DukeHeading")
  for _, field in ipairs(snapshot.fields or {}) do
    add_action(
      view,
      "field:" .. field.id,
      string.format("  %-18s %s", field.label, display(snapshot.values[field.id])),
      "fields"
    )
    if snapshot.errors and snapshot.errors[field.id] then
      add_line(view, "    ! " .. snapshot.errors[field.id], "DiagnosticError")
    end
  end
  add_line(view, "")
  add_line(view, "Destination preview: " .. display(snapshot.derived.project_dir))
end

local function render_status(view, snapshot)
  add_line(view, "")
  add_line(view, "Environment", "DukeHeading")
  local runtimes = snapshot.async and snapshot.async.runtimes or {}
  if runtimes.state == "loading" then
    add_line(view, "  Discovering Java runtimes...")
  else
    local version = snapshot.derived.maven_runner_version
      or snapshot.derived.gradle_runner_version
      or snapshot.derived.runner_version
      or "system"
    add_line(view, "  Runner JVM: " .. version)
  end
  if snapshot.banner then
    add_line(view, "  ! " .. snapshot.banner, "DiagnosticWarn")
  end
  if snapshot.busy then
    add_line(view, "  Creating project...")
  end
end

local function loading(snapshot)
  for _, status in pairs(snapshot.async or {}) do
    if status.state == "loading" then
      return true
    end
  end
  return false
end

local function wide_settings(snapshot, opts)
  local view = {
    layout = "wide",
    lines = {},
    highlights = {},
    actions = {},
  }
  add_line(view, "Duke Creation Center", "DukeHeading")
  add_line(view, "")

  local left = {
    { text = "Generator", heading = true },
  }
  for _, kind in ipairs({ "maven", "gradle", "spring" }) do
    local marker = snapshot.kind == kind and "●" or "○"
    left[#left + 1] = {
      text = marker .. " " .. kind_names[kind],
      action = "generator:" .. kind,
    }
  end
  left[#left + 1] = { text = "" }
  left[#left + 1] = { text = "Environment", heading = true }
  local runtime_status = snapshot.async and snapshot.async.runtimes or {}
  if runtime_status.state == "loading" then
    left[#left + 1] = { text = "Discovering Java runtimes..." }
  else
    local version = snapshot.derived.maven_runner_version
      or snapshot.derived.gradle_runner_version
      or snapshot.derived.runner_version
      or "system"
    left[#left + 1] = { text = "Runner JVM: " .. version }
  end
  if snapshot.busy then
    left[#left + 1] = { text = "Creating project..." }
  end

  local right = {
    { text = "Project settings", heading = true },
  }
  for _, field in ipairs(snapshot.fields or {}) do
    local text = string.format("%-18s %s", field.label, display(snapshot.values[field.id]))
    if snapshot.errors and snapshot.errors[field.id] then
      text = text .. "  ! " .. snapshot.errors[field.id]
    end
    right[#right + 1] = { text = text, action = "field:" .. field.id }
  end
  right[#right + 1] = { text = "" }
  right[#right + 1] = { text = "Destination preview: " .. display(snapshot.derived.project_dir) }

  local left_width = math.max(24, math.min(32, math.floor((opts.width or 120) * 0.27)))
  for index = 1, math.max(#left, #right) do
    local left_item = left[index] or { text = "" }
    local right_item = right[index] or { text = "" }
    local line = add_line(
      view,
      string.format("%-" .. left_width .. "s │ %s", left_item.text, right_item.text),
      (left_item.heading or right_item.heading) and "DukeHeading" or nil
    )
    if left_item.action then
      view.actions[#view.actions + 1] = {
        id = left_item.action,
        line = line,
        pane = "generators",
        col = 0,
        enabled = true,
      }
    end
    if right_item.action then
      view.actions[#view.actions + 1] = {
        id = right_item.action,
        line = line,
        pane = "fields",
        col = left_width + 3,
        enabled = true,
      }
    end
  end
  if snapshot.banner then
    add_line(view, "! " .. snapshot.banner, "DiagnosticWarn")
  end
  add_line(view, "")
  local valid = not snapshot.busy and not loading(snapshot) and not next(snapshot.errors or {})
  add_action(view, "create", valid and "Create" or "Create (unavailable)", "fields", valid)
  add_line(
    view,
    snapshot.help and "Enter edit  j/k move  Tab pane  c create  q cancel  ? help"
      or "Press ? for help"
  )
  return view
end

function M.settings(snapshot, opts)
  opts = opts or {}
  if (opts.layout or "wide") == "wide" then
    return wide_settings(snapshot, opts)
  end
  local view = {
    layout = opts.layout or "wide",
    lines = {},
    highlights = {},
    actions = {},
  }
  add_line(view, "Duke Creation Center", "DukeHeading")
  add_line(view, "")
  render_generators(view, snapshot)
  render_fields(view, snapshot)
  render_status(view, snapshot)
  add_line(view, "")
  local valid = not snapshot.busy and not loading(snapshot) and not next(snapshot.errors or {})
  add_action(view, "create", valid and "Create" or "Create (unavailable)", "fields", valid)
  if snapshot.help then
    add_line(view, "Enter edit  j/k move  Tab pane  c create  q cancel  ? help")
  else
    add_line(view, "Press ? for help")
  end
  return view
end

function M.dependencies(_snapshot, dependency_snapshot, opts)
  opts = opts or {}
  local view = {
    layout = opts.layout or "wide",
    lines = {},
    highlights = {},
    actions = {},
  }
  add_line(view, "Duke Creation Center - Spring dependencies", "DukeHeading")
  add_line(
    view,
    dependency_snapshot.query ~= "" and ("Search: " .. dependency_snapshot.query) or "Search: none"
  )
  add_line(view, "")
  add_line(view, "Categories", "DukeHeading")
  for index, category in ipairs(dependency_snapshot.categories or {}) do
    local marker = index == dependency_snapshot.category_index and "●" or "○"
    add_action(
      view,
      "dependency:category:" .. index,
      "  " .. marker .. " " .. category,
      "categories"
    )
  end
  add_line(view, "")
  add_line(view, "Dependencies", "DukeHeading")
  local selected = {}
  for _, id in ipairs(dependency_snapshot.selected_ids or {}) do
    selected[id] = true
  end
  for _, item in ipairs(dependency_snapshot.results or {}) do
    local marker = selected[item.id] and "✓" or " "
    add_action(
      view,
      "dependency:item:" .. item.id,
      string.format("  [%s] %s  %s", marker, item.name, item.description or ""),
      "results"
    )
  end
  add_line(view, "")
  add_line(
    view,
    string.format("Selected (%d)", dependency_snapshot.selected_count or 0),
    "DukeHeading"
  )
  for _, id in ipairs(dependency_snapshot.selected_ids or {}) do
    add_action(view, "dependency:selected:" .. id, "  " .. id, "selected")
  end
  add_line(view, "")
  add_line(view, "Space toggle  / search  Tab pane  Enter accept  b back  q cancel")
  if dependency_snapshot.pane == "results" then
    local item = (dependency_snapshot.results or {})[dependency_snapshot.result_index]
    view.cursor_action = item and ("dependency:item:" .. item.id) or nil
  elseif dependency_snapshot.pane == "selected" then
    local id = (dependency_snapshot.selected_ids or {})[dependency_snapshot.selected_index]
    view.cursor_action = id and ("dependency:selected:" .. id) or nil
  else
    view.cursor_action = "dependency:category:" .. tostring(dependency_snapshot.category_index or 1)
  end
  return view
end

return M
