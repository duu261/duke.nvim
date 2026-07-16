---Shared generator pipeline.
---
---Owns staging creation, target collision detection, promotion, and cleanup.
---Each generator plugs in as an adapter with two hooks:
---  validate(opts) -> nil | error
---  execute(opts, staging, callback(err))
---
---The pipeline uses only opts.cwd and opts.artifact_id.
---Everything else passes through to the adapter unchanged.

local M = {}

---Run a generator adapter through the standard pipeline.
---@param opts table Must include cwd and artifact_id.
---@param adapter table { validate = function, execute = function }
---@param callback function Called with (err, project_dir).
function M.run(opts, adapter, callback)
  local validation_error = adapter.validate(opts)
  if validation_error then
    callback(validation_error)
    return
  end

  local target = vim.fs.joinpath(opts.cwd, opts.artifact_id)
  if vim.uv.fs_stat(target) then
    callback("target already exists: " .. target)
    return
  end

  local fs = require("duke.fs")
  local staging, staging_error = fs.make_staging(opts.cwd)
  if not staging then
    callback(staging_error)
    return
  end

  adapter.execute(opts, staging, function(execute_error)
    if execute_error then
      fs.cleanup(staging)
      callback(execute_error)
      return
    end

    local staged_project = vim.fs.joinpath(staging, opts.artifact_id)
    local promoted, promote_error = fs.promote(staged_project, target)
    fs.cleanup(staging)
    if not promoted then
      callback(promote_error)
      return
    end

    callback(nil, target)
  end)
end

return M
