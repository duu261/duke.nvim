local M = {}

local function log_failure(pattern, err)
  local ok, logger = pcall(require, "duke.log")
  if ok then
    pcall(logger.add, "WARN", pattern .. " event failed: " .. tostring(err))
  end
end

---@param pom_path string
---@param operation string
---@param details? table
function M.build_changed(pom_path, operation, details)
  local ok, err = pcall(function()
    local build = require("duke.build").maven(pom_path, "mvn")
    local data = vim.tbl_extend("force", details or {}, {
      kind = "maven",
      root = build.root,
      build_file = build.build_file,
      operation = operation,
    })
    vim.api.nvim_exec_autocmds("User", {
      pattern = "DukeBuildChanged",
      modeline = false,
      data = data,
    })
  end)
  if not ok then
    log_failure("DukeBuildChanged", err)
  end
end

return M
