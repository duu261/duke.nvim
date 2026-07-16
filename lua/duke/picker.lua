local M = {}

local function display(item, formatter)
  if type(item) == "table" and item.__done then
    return item.name
  end
  if formatter then
    return formatter(item)
  end
  if type(item) == "table" then
    return item.name or item.id or vim.inspect(item)
  end
  return tostring(item)
end

local function telescope_modules()
  local ok, modules = pcall(function()
    return {
      pickers = require("telescope.pickers"),
      finders = require("telescope.finders"),
      config = require("telescope.config").values,
      actions = require("telescope.actions"),
      state = require("telescope.actions.state"),
      themes = require("telescope.themes"),
    }
  end)
  if not ok then
    return nil
  end
  return modules
end

local function default_index(items, default)
  for index, item in ipairs(items) do
    if
      item == default or (type(item) == "table" and (item.id == default or item.value == default))
    then
      return index
    end
  end
  return 1
end

function M.select_one(items, opts, callback)
  local telescope = telescope_modules()
  if not telescope then
    local choices = vim.deepcopy(items)
    local index = default_index(choices, opts.default)
    if index > 1 then
      local selected_default = table.remove(choices, index)
      table.insert(choices, 1, selected_default)
    end
    vim.ui.select(choices, {
      prompt = opts.prompt,
      format_item = function(item)
        return display(item, opts.format_item)
      end,
    }, callback)
    return
  end

  local picker_opts = telescope.themes.get_dropdown({
    default_selection_index = default_index(items, opts.default),
  })
  telescope.pickers
    .new(picker_opts, {
      prompt_title = opts.prompt,
      finder = telescope.finders.new_table({
        results = items,
        entry_maker = function(item)
          local text = display(item, opts.format_item)
          return { value = item, display = text, ordinal = text }
        end,
      }),
      sorter = telescope.config.generic_sorter(picker_opts),
      attach_mappings = function(prompt_buffer)
        telescope.actions.select_default:replace(function()
          local selected = telescope.state.get_selected_entry()
          telescope.actions.close(prompt_buffer)
          callback(selected and selected.value or nil)
        end)
        return true
      end,
    })
    :find()
end

local function fallback_many(items, opts, callback)
  local selected = {}
  local selected_ids = {}

  local function next_choice()
    local choices = { { __done = true, name = "[Done]" } }
    for _, item in ipairs(items) do
      local id = type(item) == "table" and (item.id or item.value) or item
      if not selected_ids[id] then
        choices[#choices + 1] = item
      end
    end
    vim.ui.select(choices, {
      prompt = opts.prompt,
      format_item = function(item)
        return display(item, opts.format_item)
      end,
    }, function(item)
      if not item then
        callback(nil)
      elseif item.__done then
        callback(selected)
      else
        local id = type(item) == "table" and (item.id or item.value) or item
        selected_ids[id] = true
        selected[#selected + 1] = item
        next_choice()
      end
    end)
  end

  next_choice()
end

function M.select_many(items, opts, callback)
  local telescope = telescope_modules()
  if not telescope then
    fallback_many(items, opts, callback)
    return
  end

  local done = { __done = true, name = opts.done_label or "[Done]" }
  local choices = { done }
  vim.list_extend(choices, items)
  local picker_opts = telescope.themes.get_dropdown({})
  telescope.pickers
    .new(picker_opts, {
      prompt_title = opts.prompt .. "  <Tab> toggle, <Enter> finish",
      finder = telescope.finders.new_table({
        results = choices,
        entry_maker = function(item)
          local text = display(item, opts.format_item)
          return { value = item, display = text, ordinal = text }
        end,
      }),
      sorter = telescope.config.generic_sorter(picker_opts),
      attach_mappings = function(prompt_buffer)
        telescope.actions.select_default:replace(function()
          local picker = telescope.state.get_current_picker(prompt_buffer)
          local entries = picker:get_multi_selection()
          local current = telescope.state.get_selected_entry()
          if #entries == 0 and current then
            entries = { current }
          end
          telescope.actions.close(prompt_buffer)

          local selected = {}
          local seen = {}
          for _, entry in ipairs(entries) do
            local item = entry.value
            local id = type(item) == "table" and (item.id or item.value) or item
            if not item.__done and not seen[id] then
              seen[id] = true
              selected[#selected + 1] = item
            end
          end
          callback(selected)
        end)
        return true
      end,
    })
    :find()
end

function M.input(prompt, default, callback)
  vim.ui.input({ prompt = prompt, default = default }, callback)
end

function M.confirm(message, action)
  return vim.fn.confirm(message, "&" .. (action or "Create") .. "\nC&ancel", 2, "Question") == 1
end

return M
