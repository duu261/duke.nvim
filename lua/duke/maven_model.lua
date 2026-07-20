local build = require("duke.build")
local pom = require("duke.pom")
local process = require("duke.process")

local M = {}

local EFFECTIVE_GOAL = "org.apache.maven.plugins:maven-help-plugin:3.5.2:effective-pom"
local TREE_GOAL = "org.apache.maven.plugins:maven-dependency-plugin:3.11.0:tree"

local function output_path()
  return vim.fn.tempname()
end

local function cleanup(path)
  pcall(vim.fn.delete, path)
end

local function read_lines(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, "cannot read Maven inspection output: " .. tostring(lines)
  end
  return lines
end

local function normalize_tree(node)
  if
    type(node) ~= "table"
    or type(node.groupId) ~= "string"
    or type(node.artifactId) ~= "string"
  then
    return nil, "Maven dependency tree contains an invalid node"
  end
  local normalized = {
    coordinate = node.groupId .. ":" .. node.artifactId,
    version = node.version,
    scope = node.scope,
    type = node.type,
    classifier = node.classifier,
    omitted_for_conflict = node.omittedForConflict,
    children = {},
  }
  for _, child in ipairs(node.children or {}) do
    local parsed, err = normalize_tree(child)
    if not parsed then
      return nil, err
    end
    normalized.children[#normalized.children + 1] = parsed
  end
  return normalized
end

local function parse_effective(path)
  local lines, read_err = read_lines(path)
  if not lines then
    return nil, read_err
  end
  return pom.model(lines)
end

local function parse_tree(path)
  local lines, read_err = read_lines(path)
  if not lines then
    return nil, read_err
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok then
    return nil, "invalid Maven dependency tree JSON: " .. tostring(decoded)
  end
  return normalize_tree(decoded)
end

local function run_goal(module, goal, output_argument, opts, callback)
  local selected = build.maven(module.build_file, opts.maven_command or "mvn")
  local path = output_path()
  local args = { "-q" }
  if goal == EFFECTIVE_GOAL then
    args[#args + 1] = "-N"
  end
  vim.list_extend(args, { "-f", module.build_file, goal })
  if goal == TREE_GOAL then
    args[#args + 1] = "-DoutputType=json"
    args[#args + 1] = "-Dverbose"
  end
  args[#args + 1] = output_argument .. path
  process.run(selected.command, args, {
    cwd = selected.cwd,
    env = opts.env,
    timeout = opts.timeout,
  }, function(result)
    if result.code ~= 0 then
      cleanup(path)
      callback("Maven inspection failed: " .. process.detail(result))
      return
    end
    local value, err
    if goal == EFFECTIVE_GOAL then
      value, err = parse_effective(path)
    else
      value, err = parse_tree(path)
    end
    cleanup(path)
    callback(err, value)
  end)
end

function M.enrich(snapshot, opts, callback)
  opts = opts or {}
  local enriched = vim.deepcopy(snapshot)
  enriched.diagnostics = enriched.diagnostics or {}
  local index = 1
  local partial = false
  local finished = false

  local function finish()
    if finished then
      return
    end
    finished = true
    enriched.state = partial and "partial" or "resolved"
    pcall(callback, nil, enriched)
  end

  local function next_module()
    local module = enriched.modules[index]
    if not module then
      finish()
      return
    end
    index = index + 1
    run_goal(module, EFFECTIVE_GOAL, "-Doutput=", opts, function(effective_err, effective)
      if effective_err then
        partial = true
        enriched.diagnostics[#enriched.diagnostics + 1] = {
          code = "maven_goal_failed",
          severity = "warning",
          message = module.id .. ": " .. effective_err,
        }
        next_module()
        return
      end
      run_goal(module, TREE_GOAL, "-DoutputFile=", opts, function(tree_err, tree)
        if tree_err then
          partial = true
          enriched.diagnostics[#enriched.diagnostics + 1] = {
            code = "maven_goal_failed",
            severity = "warning",
            message = module.id .. ": " .. tree_err,
          }
        else
          module.resolved = {
            effective = effective,
            tree = tree,
          }
        end
        next_module()
      end)
    end)
  end

  next_module()
end

return M
