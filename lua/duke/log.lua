local M = {}

local entries = {}
local max_entries = 500

function M.add(level, message)
  entries[#entries + 1] = string.format("[%s] %s %s", level, os.date("%H:%M:%S"), message)
  if #entries > max_entries then
    table.remove(entries, 1)
  end
end

function M.show()
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].filetype = "log"
  local lines = {}
  for _, entry in ipairs(entries) do
    vim.list_extend(lines, vim.split(entry, "\n", { plain = true }))
  end
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buffer)
end

return M
