local completion = require("duke.completion")
local pom_file = require("duke.pom_file")

local M = {}

local function same_lines(left, right)
  if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then
    return false
  end
  for index, line in ipairs(left) do
    if right[index] ~= line then
      return false
    end
  end
  return true
end

local function root_pom(root)
  if vim.fs.basename(root) == "pom.xml" then
    return vim.fs.normalize(root)
  end
  return vim.fs.joinpath(vim.fs.normalize(root), "pom.xml")
end

local function ordered(root, entries)
  local result = vim.deepcopy(entries)
  local parent = root_pom(root)
  table.sort(result, function(left, right)
    local left_order = left.order or (vim.fs.normalize(left.pom_path) == parent and 0 or 1)
    local right_order = right.order or (vim.fs.normalize(right.pom_path) == parent and 0 or 1)
    if left_order ~= right_order then
      return left_order < right_order
    end
    return left.pom_path < right.pom_path
  end)
  return result
end

local function failure(root, phase, message, applied)
  local applied_paths = vim.tbl_map(function(entry)
    return entry.pom_path
  end, applied or {})
  return {
    ok = false,
    root = root,
    phase = phase,
    error = message,
    message = message,
    applied = applied_paths,
    changed_files = {},
    modified_buffers = {},
    restored = {},
    rolled_back = {},
    conflicted = {},
  }
end

function M.apply(root, entries, callback)
  if type(callback) ~= "function" then
    completion.log("ERROR", "POM transaction callback is required")
    return
  end
  local finish = completion.once(callback, "POM transaction")
  local ok, internal_err = pcall(function()
    if type(root) ~= "string" or type(entries) ~= "table" or #entries == 0 then
      finish("POM transaction requires a root and entries")
      return
    end
    local sorted = ordered(root, entries)
    local snapshots = {}
    local seen = {}
    for _, entry in ipairs(sorted) do
      if
        type(entry.pom_path) ~= "string"
        or type(entry.before) ~= "table"
        or type(entry.after) ~= "table"
      then
        finish("POM transaction contains an invalid entry")
        return
      end
      if seen[entry.pom_path] then
        finish("POM transaction contains duplicate paths")
        return
      end
      seen[entry.pom_path] = true
      local snapshot, snapshot_err = pom_file.snapshot(entry.pom_path)
      if not snapshot or not same_lines(snapshot.lines, entry.before) then
        local result = failure(root, "preflight", snapshot_err or (entry.pom_path .. " is stale"))
        finish(nil, result)
        return
      end
      snapshots[entry.pom_path] = snapshot
    end

    local applied = {}
    local modified_buffers = {}
    for _, entry in ipairs(sorted) do
      if not same_lines(entry.before, entry.after) then
        local saved, replace_err = pom_file.replace(snapshots[entry.pom_path], entry.after)
        if saved == nil then
          local result = failure(root, "rollback", replace_err, applied)
          for index = #applied, 1, -1 do
            local applied_entry = applied[index]
            local current = pom_file.snapshot(applied_entry.pom_path)
            if current and same_lines(current.lines, applied_entry.after) then
              local restored = pom_file.replace(current, applied_entry.before)
              if restored ~= nil then
                result.rolled_back[#result.rolled_back + 1] = applied_entry.pom_path
                result.restored[#result.restored + 1] = applied_entry.pom_path
              else
                result.conflicted[#result.conflicted + 1] = applied_entry.pom_path
              end
            else
              result.conflicted[#result.conflicted + 1] = applied_entry.pom_path
            end
          end
          table.sort(result.rolled_back)
          table.sort(result.restored)
          table.sort(result.conflicted)
          if #result.conflicted > 0 then
            result.phase = "rollback_conflict"
          end
          finish(nil, result)
          return
        end
        applied[#applied + 1] = entry
        if saved == false then
          modified_buffers[#modified_buffers + 1] = entry.pom_path
        end
      end
    end

    local changed_files = {}
    for _, entry in ipairs(applied) do
      changed_files[#changed_files + 1] = entry.pom_path
    end
    finish(nil, {
      ok = true,
      root = root,
      phase = "complete",
      changed_files = changed_files,
      modified_buffers = modified_buffers,
      changes = vim.tbl_map(function(entry)
        return vim.deepcopy(entry.changes or {})
      end, applied),
    })
  end)
  if not ok then
    finish("POM transaction failed: " .. tostring(internal_err))
  end
end

return M
