local M = {}

local function canonical(path)
  if type(path) ~= "string" or path:sub(1, 1) ~= "/" then
    return nil
  end
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

local function module_coordinate(module)
  local coordinates = module.model and module.model.coordinates or {}
  if coordinates.group_id and coordinates.artifact_id then
    return coordinates.group_id .. ":" .. coordinates.artifact_id
  end
  return module.id
end

local function source_coordinate(source)
  if type(source) ~= "string" then
    return nil
  end
  local group_id, artifact_id = source:match("^([^:%s]+):([^:%s]+):")
  if group_id and artifact_id then
    return group_id .. ":" .. artifact_id
  end
end

local function parent_coordinate(module)
  local parent = module.model and module.model.parent or {}
  if type(parent.group_id) == "string" and type(parent.artifact_id) == "string" then
    return parent.group_id .. ":" .. parent.artifact_id
  end
end

local function in_profile(model, line)
  for _, range in ipairs(model.profile_ranges or {}) do
    if line >= range.start_line and line <= range.end_line then
      return range
    end
  end
end

local function declarations(module, coordinate)
  local matches = {}
  for _, declaration in ipairs(module.model.dependencies or {}) do
    if declaration.coordinate == coordinate then
      matches[#matches + 1] = declaration
    end
  end
  for _, declaration in ipairs(module.model.dependency_management or {}) do
    if declaration.coordinate == coordinate then
      matches[#matches + 1] = declaration
    end
  end
  return matches
end

local function effective_declaration(module, coordinate)
  local effective = module.resolved and module.resolved.effective or {}
  for _, declaration in ipairs(effective.dependencies or {}) do
    if declaration.coordinate == coordinate and declaration.version then
      return declaration
    end
  end
  for _, declaration in ipairs(effective.dependency_management or {}) do
    if declaration.coordinate == coordinate and declaration.version then
      return declaration
    end
  end
end

local function effective_source(module, declaration)
  if not declaration then
    return nil
  end
  local effective = module.resolved and module.resolved.effective or {}
  local line = declaration.version_line or declaration.start_line
  for _, source in ipairs(effective.sources or {}) do
    if source.effective_line == line then
      return source
    end
  end
end

local function property_owner(module, declaration)
  local name = declaration.version and declaration.version:match("^%${([%w_.-]+)}$")
  local property = name and module.model.properties and module.model.properties[name]
  if not property then
    return nil
  end
  return name, property
end

local function base_row(module, node)
  return {
    module_id = module.id,
    coordinate = node.coordinate,
    selected_version = node.version,
    ownership_chain = {},
    writable = false,
  }
end

local function blocked(module, node, kind, reason, source)
  local row = base_row(module, node)
  row.kind = kind
  row.blocked_reason = reason
  if source then
    row.ownership_chain[1] = vim.deepcopy(source)
  end
  return row
end

local function owned(module, node, owner_module, declaration, kind, source)
  local row = base_row(module, node)
  local property_name, property = property_owner(owner_module, declaration)
  row.kind = kind
  if kind ~= "imported_bom" and property_name then
    row.kind = "property"
  end
  row.requested_version = property and property.value or declaration.version
  row.owner_coordinate = declaration.coordinate
  row.pom_path = owner_module.build_file
  row.line = property and property.line or declaration.version_line or declaration.start_line
  row.property = property_name
  row.consumers = property and vim.deepcopy(property.consumers or {}) or {}
  row.writable = true
  row.ownership_chain = {
    {
      kind = kind,
      pom_path = owner_module.build_file,
      line = row.line,
      source = source and source.source or nil,
    },
  }
  return row
end

local function resolve_node(module, node, modules_by_path, modules_by_coordinate, all_modules)
  local effective = effective_declaration(module, node.coordinate)
  local source = effective_source(module, effective)
  if not source then
    return blocked(module, node, "unknown", "effective origin unavailable")
  end

  local source_path = canonical(source.source)
  local source_module = source_path and modules_by_path[source_path] or nil
  if source_module then
    local profile = in_profile(source_module.model, source.line)
    if profile then
      return blocked(
        module,
        node,
        "profile",
        "version is owned by profile " .. tostring(profile.id or "unknown"),
        source
      )
    end

    local coordinate_matches = declarations(source_module, node.coordinate)
    if #coordinate_matches > 1 then
      return blocked(
        module,
        node,
        "unknown",
        "multiple candidates in " .. source_module.build_file,
        source
      )
    end
    local exact = {}
    for _, declaration in ipairs(coordinate_matches) do
      if source.line == (declaration.version_line or declaration.start_line) then
        exact[#exact + 1] = declaration
      end
    end
    if #exact == 1 then
      local kind = exact[1].managed and "dependency_management" or "dependency"
      if source_module ~= module then
        kind = "local_parent"
      end
      return owned(module, node, source_module, exact[1], kind, source)
    end
    return blocked(module, node, "unknown", "origin does not match a local declaration", source)
  end

  local source_owner = modules_by_coordinate[source_coordinate(source.source)]
  if source_owner then
    local profile = in_profile(source_owner.model, source.line)
    if profile then
      return blocked(
        module,
        node,
        "profile",
        "version is owned by profile " .. tostring(profile.id or "unknown"),
        source
      )
    end
    local coordinate_matches = declarations(source_owner, node.coordinate)
    if #coordinate_matches > 1 then
      return blocked(module, node, "unknown", "multiple local-parent candidates", source)
    end
    local candidates = {}
    for _, declaration in ipairs(coordinate_matches) do
      if source.line == (declaration.version_line or declaration.start_line) then
        candidates[#candidates + 1] = declaration
      end
    end
    if #candidates == 1 then
      local kind = candidates[1].managed and "dependency_management" or "dependency"
      if source_owner ~= module then
        kind = "local_parent"
      end
      return owned(module, node, source_owner, candidates[1], kind, source)
    end
    if #candidates > 1 then
      return blocked(module, node, "unknown", "multiple local-parent candidates", source)
    end
  end

  if source_coordinate(source.source) == parent_coordinate(module) then
    return blocked(module, node, "external_parent", "version owner is outside reactor", source)
  end

  local bom_coordinate = source_coordinate(source.source)
  local bom_candidates = {}
  for _, candidate_module in ipairs(all_modules) do
    for _, declaration in ipairs(candidate_module.model.dependency_management or {}) do
      if declaration.imported_bom and declaration.coordinate == bom_coordinate then
        bom_candidates[#bom_candidates + 1] = {
          module = candidate_module,
          declaration = declaration,
        }
      end
    end
  end
  if #bom_candidates == 1 then
    local candidate = bom_candidates[1]
    return owned(module, node, candidate.module, candidate.declaration, "imported_bom", source)
  end
  if #bom_candidates > 1 then
    return blocked(module, node, "unknown", "multiple imported BOM candidates", source)
  end

  if source_path then
    return blocked(module, node, "external_parent", "version owner is outside reactor", source)
  end
  return blocked(module, node, "unknown", "origin has no matching local owner", source)
end

local function walk(node, visit)
  for _, child in ipairs(node.children or {}) do
    visit(child)
    walk(child, visit)
  end
end

function M.resolve(snapshot)
  if type(snapshot) ~= "table" or type(snapshot.modules) ~= "table" then
    return {}
  end
  local modules_by_path = {}
  local modules_by_coordinate = {}
  for _, module in ipairs(snapshot.modules) do
    local path = canonical(module.build_file)
    if path then
      modules_by_path[path] = module
    end
    modules_by_coordinate[module_coordinate(module)] = module
  end

  local rows = {}
  for _, module in ipairs(snapshot.modules) do
    local tree = module.resolved and module.resolved.tree
    if tree then
      walk(tree, function(node)
        local key = tostring(module.id) .. "\0" .. tostring(node.coordinate)
        if not rows[key] then
          rows[key] =
            resolve_node(module, node, modules_by_path, modules_by_coordinate, snapshot.modules)
        end
      end)
    end
  end
  return rows
end

return M
