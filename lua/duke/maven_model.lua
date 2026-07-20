local build = require("duke.build")
local pom = require("duke.pom")
local process = require("duke.process")

local M = {}

local EFFECTIVE_GOAL = "org.apache.maven.plugins:maven-help-plugin:3.5.2:effective-pom"
local TREE_GOAL = "org.apache.maven.plugins:maven-dependency-plugin:3.11.0:tree"
local MAX_SOURCES = 128
local MAX_SOURCE_LENGTH = 256
local MAX_OUTPUT_BYTES = 8 * 1024 * 1024

local function output_path()
  return vim.fn.tempname()
end

local function cleanup(path)
  pcall(vim.fn.delete, path)
end

local function read_lines(path)
  local stat, stat_err = vim.uv.fs_stat(path)
  if not stat then
    return nil, "cannot inspect Maven output: " .. tostring(stat_err)
  end
  if stat.size > MAX_OUTPUT_BYTES then
    return nil, "Maven inspection output exceeds size limit"
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, "cannot read Maven inspection output: " .. tostring(lines)
  end
  return lines
end

local function split_coordinate(value)
  local parts = {}
  for part in value:gmatch("[^:]+") do
    parts[#parts + 1] = part
  end
  if #parts < 4 then
    return nil
  end
  local classifier
  local version_index = 4
  local scope_index = 5
  if #parts >= 6 then
    classifier = parts[4]
    version_index = 5
    scope_index = 6
  end
  return {
    coordinate = parts[1] .. ":" .. parts[2],
    type = parts[3],
    classifier = classifier,
    version = parts[version_index],
    scope = parts[scope_index],
    children = {},
  }
end

local function parse_text_tree(lines)
  local root
  local stack = {}
  for _, raw in ipairs(lines) do
    local line = raw:gsub("^%[INFO%]%s*", "")
    local prefix, payload = line:match("^([|%s]*[%+\\]%-)%s+(.+)$")
    local depth = 0
    if prefix then
      depth = math.floor(#prefix / 3) + 1
    else
      payload = line:match("^%s*(%S.*)$")
    end
    if payload then
      local artifact, omitted =
        payload:match("^%((.-)%s+%-%s+omitted for conflict with%s+([^%)]+)%)$")
      if artifact then
        payload = artifact
      end
      local node = split_coordinate(payload)
      if node then
        node.omitted_for_conflict = omitted
        if depth == 0 then
          root = node
        elseif stack[depth - 1] then
          stack[depth - 1].children[#stack[depth - 1].children + 1] = node
        else
          return nil, "invalid Maven dependency tree text depth"
        end
        stack[depth] = node
        for index = depth + 1, #stack do
          stack[index] = nil
        end
      end
    end
  end
  if not root then
    return nil, "invalid Maven dependency tree output"
  end
  return root
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
  local model, model_err = pom.model(lines, { effective = true })
  if not model then
    return nil, model_err
  end
  local sources = {}
  for effective_line, line in ipairs(lines) do
    local comment = line:match("<!%-%-%s*(.-)%s*%-%->")
    local source, line_number
    if comment then
      source, line_number = comment:match("^(.-), line (%d+)%s*$")
    end
    source = source and vim.trim(source) or nil
    if source and source ~= "" and #source <= MAX_SOURCE_LENGTH then
      sources[#sources + 1] = {
        source = source,
        line = tonumber(line_number),
        effective_line = effective_line,
      }
      if #sources == MAX_SOURCES then
        break
      end
    end
  end
  model.sources = sources
  return model
end

local function parse_tree(path)
  local lines, read_err = read_lines(path)
  if not lines then
    return nil, read_err
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if ok then
    return normalize_tree(decoded)
  end
  return parse_text_tree(lines)
end

local function run_goal(module, goal, output_argument, opts, callback)
  local path
  local finished = false
  local function finish(err, value)
    if finished then
      return
    end
    finished = true
    if path then
      cleanup(path)
    end
    pcall(callback, err, value)
  end

  local started, start_err = pcall(function()
    local selected = build.maven(module.build_file, opts.maven_command or "mvn")
    path = output_path()
    local args = { "-q", "-N" }
    vim.list_extend(args, { "-f", module.build_file, goal })
    if goal == TREE_GOAL then
      args[#args + 1] = "-DoutputType=json"
      args[#args + 1] = "-Dverbose"
    elseif goal == EFFECTIVE_GOAL then
      args[#args + 1] = "-Dverbose"
    end
    args[#args + 1] = output_argument .. path

    local result_called = false
    process.run(selected.command, args, {
      cwd = selected.cwd,
      env = opts.env,
      timeout = opts.timeout,
    }, function(result)
      if result_called then
        return
      end
      result_called = true
      local handled, handle_err = pcall(function()
        if type(result) ~= "table" or type(result.code) ~= "number" then
          error("invalid Maven process result")
        end
        if result.code ~= 0 then
          finish("Maven inspection failed: " .. process.detail(result))
          return
        end
        local value, err
        if goal == EFFECTIVE_GOAL then
          value, err = parse_effective(path)
        else
          value, err = parse_tree(path)
        end
        finish(err, value)
      end)
      if not handled then
        finish("Maven inspection callback failed: " .. tostring(handle_err))
      end
    end)
  end)
  if not started then
    finish("Maven inspection failed: " .. tostring(start_err))
  end
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

M.EFFECTIVE_GOAL = EFFECTIVE_GOAL
M.TREE_GOAL = TREE_GOAL
M.read_output = read_lines

return M
