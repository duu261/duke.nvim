local M = {}

local function clean_line(line)
  line = line:gsub("\27%[[0-9;]*m", "")
  return line:match("^%[INFO%] (.*)$") or line:match("^%[INFO%](.*)$") or line
end

local function is_tree_line(line)
  if line:match("^[%w_.-]+:[%w_.-]+:[%w_.-]+:") then
    return true
  end
  return line:match("^[| ]*[+\\]%- ") ~= nil
end

---@param stdout string
---@return string[]
function M.parse(stdout)
  local lines = {}
  if type(stdout) ~= "string" then
    return lines
  end
  for raw in stdout:gmatch("[^\r\n]+") do
    local line = clean_line(raw)
    if is_tree_line(line) then
      lines[#lines + 1] = line
    end
  end
  return lines
end

---@param coordinate string
---@return string|nil
function M.coordinate_error(coordinate)
  if type(coordinate) ~= "string" or not coordinate:match("^[%w_.-]+:[%w_.-]+$") then
    return "use groupId:artifactId"
  end
  return nil
end

local function failure_detail(result)
  local detail = vim.trim(result.stderr or "")
  if detail == "" then
    detail = vim.trim(result.stdout or "")
  end
  if detail == "" then
    detail = "mvn exited with code " .. tostring(result.code)
  end
  return detail
end

---@param pom_path string
---@param coordinate string|nil
---@param opts { command: string|nil, timeout: number|nil, env: table|nil }|nil
---@param callback fun(err: string|nil, lines: string[]|nil)
function M.inspect(pom_path, coordinate, opts, callback)
  opts = opts or {}
  local args = {
    "dependency:tree",
    "-Dverbose",
    "-Dstyle.color=never",
  }
  if coordinate then
    args[#args + 1] = "-Dincludes=" .. coordinate
  end
  vim.list_extend(args, { "--batch-mode", "-f", pom_path })

  require("duke.process").run(
    opts.command or "mvn",
    args,
    { cwd = vim.fs.dirname(pom_path), env = opts.env, timeout = opts.timeout },
    function(result)
      if result.code ~= 0 then
        require("duke.log").add("ERROR", "mvn dependency:tree failed: " .. failure_detail(result))
        callback("Maven dependency tree failed; see :DukeLog")
        return
      end

      local lines = M.parse(result.stdout)
      if coordinate then
        local present = false
        for _, line in ipairs(lines) do
          if line:find(coordinate .. ":", 1, true) then
            present = true
            break
          end
        end
        if not present then
          callback(coordinate .. " is not on the dependency tree")
          return
        end
      elseif #lines == 0 then
        callback("Maven returned no dependency tree; see :DukeLog")
        return
      end

      callback(nil, lines)
    end
  )
end

return M
