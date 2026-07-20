local M = {}

local function key(module_id, coordinate)
  return module_id .. "\0" .. coordinate
end

local function index_declarations(module)
  local declarations = {}
  for _, dependency in ipairs(module.model.dependencies or {}) do
    local list = declarations[dependency.coordinate] or {}
    list[#list + 1] = dependency
    declarations[dependency.coordinate] = list
  end
  return declarations
end

local function effective_versions(module)
  local versions = {}
  local effective = module.resolved and module.resolved.effective
  for _, dependency in ipairs((effective and effective.dependencies) or {}) do
    versions[dependency.coordinate] = dependency.version
  end
  return versions
end

function M.analyze(snapshot)
  local analysis = {
    modules = {},
    dependencies = {},
    findings = {
      drift = {},
      duplicates = {},
      conflicts = {},
      unknown = {},
    },
    paths = {},
  }
  local resolved_versions = {}

  for _, module in ipairs(snapshot.modules or {}) do
    analysis.modules[#analysis.modules + 1] = module.id
    local declarations = index_declarations(module)
    local effective = effective_versions(module)
    for coordinate, owners in pairs(declarations) do
      if #owners > 1 then
        analysis.findings.duplicates[#analysis.findings.duplicates + 1] = {
          coordinate = coordinate,
          module_id = module.id,
          lines = vim.tbl_map(function(owner)
            return owner.start_line
          end, owners),
        }
      end
    end

    local root = module.resolved and module.resolved.tree
    local function walk(node, path, depth)
      for _, child in ipairs(node.children or {}) do
        local child_path = vim.deepcopy(path)
        child_path[#child_path + 1] = child.coordinate
        local owners = declarations[child.coordinate]
        local owner = owners and owners[1] or nil
        local property_name = owner and owner.version and owner.version:match("^%${([%w_.-]+)}$")
        local entry = {
          coordinate = child.coordinate,
          module_id = module.id,
          version = child.version,
          scope = child.scope,
          depth = depth,
          direct = depth == 1,
          raw_owner = owner,
          effective_version = effective[child.coordinate],
          property = property_name,
          property_consumers = property_name
              and module.model.properties
              and module.model.properties[property_name]
              and module.model.properties[property_name].consumer_refs
            or nil,
        }
        analysis.dependencies[#analysis.dependencies + 1] = entry
        local paths = analysis.paths[key(module.id, child.coordinate)] or {}
        paths[#paths + 1] = child_path
        analysis.paths[key(module.id, child.coordinate)] = paths

        if not owner then
          analysis.findings.unknown[#analysis.findings.unknown + 1] = entry
        end
        if child.omitted_for_conflict or child.omittedForConflict then
          analysis.findings.conflicts[#analysis.findings.conflicts + 1] = {
            coordinate = child.coordinate,
            module_id = module.id,
            omitted = child.version,
            selected = child.omitted_for_conflict or child.omittedForConflict,
            path = child_path,
          }
        else
          local versions = resolved_versions[child.coordinate] or {}
          versions[child.version or "unknown"] = true
          resolved_versions[child.coordinate] = versions
        end
        walk(child, child_path, depth + 1)
      end
    end
    if root then
      walk(root, { module.id }, 1)
    end
  end

  for coordinate, versions in pairs(resolved_versions) do
    local values = vim.tbl_keys(versions)
    table.sort(values)
    if #values > 1 then
      analysis.findings.drift[#analysis.findings.drift + 1] = {
        coordinate = coordinate,
        versions = values,
      }
    end
  end
  for _, findings in pairs(analysis.findings) do
    table.sort(findings, function(left, right)
      if left.coordinate ~= right.coordinate then
        return left.coordinate < right.coordinate
      end
      return (left.module_id or "") < (right.module_id or "")
    end)
  end
  return analysis
end

function M.paths(analysis, coordinate, module_id)
  return vim.deepcopy(analysis.paths[key(module_id, coordinate)] or {})
end

local function unique_sorted(values)
  local seen = {}
  local result = {}
  for _, value in ipairs(values or {}) do
    if value ~= nil and not seen[value] then
      seen[value] = true
      result[#result + 1] = value
    end
  end
  table.sort(result)
  return result
end

local function owner_for(rows, module_id, coordinate)
  if module_id then
    return rows[key(module_id, coordinate)]
  end
  local matches = {}
  local identities = {}
  for row_key, row in pairs(rows or {}) do
    if row_key:sub(-#coordinate) == coordinate and row.coordinate == coordinate then
      local identity = table.concat({ row.kind or "", row.pom_path or "", row.line or "" }, "\0")
      if not identities[identity] then
        identities[identity] = true
        matches[#matches + 1] = row
      end
    end
  end
  if #matches == 1 then
    return matches[1]
  end
end

local function alignment_owner(rows, coordinate)
  local owners = {}
  local identities = {}
  local consumers = {}
  local consumer_seen = {}
  local blocked_reason
  for _, row in pairs(rows or {}) do
    if row.coordinate == coordinate then
      if row.writable ~= true then
        blocked_reason = blocked_reason or row.blocked_reason or "alignment owner is not writable"
      elseif type(row.pom_path) == "string" then
        local identity = table.concat({
          row.kind or "",
          row.pom_path,
          row.line or "",
          row.property or "",
        }, "\0")
        if not identities[identity] then
          identities[identity] = true
          owners[#owners + 1] = vim.deepcopy(row)
          for _, consumer in ipairs(row.consumers or {}) do
            if not consumer_seen[consumer] then
              consumer_seen[consumer] = true
              consumers[#consumers + 1] = consumer
            end
          end
        end
      else
        blocked_reason = blocked_reason or "alignment owner has no local POM"
      end
    end
  end
  table.sort(owners, function(left, right)
    if left.pom_path ~= right.pom_path then
      return left.pom_path < right.pom_path
    end
    return (left.line or 0) < (right.line or 0)
  end)
  table.sort(consumers)
  if blocked_reason or #owners < 2 then
    return {
      kind = "reactor_alignment",
      owners = owners,
      consumers = consumers,
      writable = false,
      blocked_reason = blocked_reason or "alignment requires multiple proven local owners",
    }
  end
  return {
    kind = "reactor_alignment",
    owners = owners,
    consumers = consumers,
    writable = true,
  }
end

local function decorate(finding, rows, analysis)
  local owner = finding.ownership or owner_for(rows, finding.module_id, finding.coordinate)
  finding.ownership = owner and vim.deepcopy(owner) or nil
  finding.paths = finding.paths
    or vim.deepcopy(
      finding.module_id and analysis.paths[key(finding.module_id, finding.coordinate)] or {}
    )
  finding.consumers = owner and vim.deepcopy(owner.consumers or {}) or {}
  finding.selected_version = finding.selected_version or (owner and owner.selected_version)
  if finding.force_blocked then
    finding.repairable = false
  else
    finding.repairable = owner ~= nil and owner.writable == true
  end
  if not finding.repairable and not finding.blocked_reason then
    finding.blocked_reason = owner and owner.blocked_reason or "writable owner unavailable"
  end
  finding.force_blocked = nil
  return finding
end

function M.repairable(analysis, ownership_rows, usage)
  analysis = analysis or {}
  ownership_rows = ownership_rows or {}
  usage = usage or {}
  local grouped = analysis.findings or {}
  local findings = {}

  for _, conflict in ipairs(grouped.conflicts or {}) do
    findings[#findings + 1] = decorate({
      kind = "version_conflict",
      severity = "warning",
      coordinate = conflict.coordinate,
      module_id = conflict.module_id,
      requested_versions = unique_sorted({ conflict.omitted, conflict.selected }),
      selected_version = conflict.selected,
      paths = conflict.path and { vim.deepcopy(conflict.path) } or nil,
    }, ownership_rows, analysis)
  end
  for _, drift in ipairs(grouped.drift or {}) do
    findings[#findings + 1] = decorate({
      kind = "version_drift",
      severity = "warning",
      coordinate = drift.coordinate,
      module_id = drift.module_id,
      requested_versions = unique_sorted(drift.versions),
      ownership = alignment_owner(ownership_rows, drift.coordinate),
    }, ownership_rows, analysis)
  end
  for _, duplicate in ipairs(grouped.duplicates or {}) do
    findings[#findings + 1] = decorate({
      kind = "duplicate_declaration",
      severity = "info",
      coordinate = duplicate.coordinate,
      module_id = duplicate.module_id,
      lines = vim.deepcopy(duplicate.lines or {}),
      force_blocked = true,
      blocked_reason = "duplicate declarations require manual resolution",
    }, ownership_rows, analysis)
  end
  for _, unknown in ipairs(grouped.unknown or {}) do
    findings[#findings + 1] = decorate({
      kind = "unknown_ownership",
      severity = "info",
      coordinate = unknown.coordinate,
      module_id = unknown.module_id,
      force_blocked = true,
    }, ownership_rows, analysis)
  end

  local mediated_seen = {}
  for _, dependency in ipairs(analysis.dependencies or {}) do
    local requested = dependency.raw_owner and dependency.raw_owner.version
    if requested and dependency.version and requested ~= dependency.version then
      local mediated_key = key(dependency.module_id, dependency.coordinate)
      if not mediated_seen[mediated_key] then
        mediated_seen[mediated_key] = true
        findings[#findings + 1] = decorate({
          kind = "mediated_version",
          severity = "warning",
          coordinate = dependency.coordinate,
          module_id = dependency.module_id,
          requested_versions = unique_sorted({ requested, dependency.version }),
          selected_version = dependency.version,
        }, ownership_rows, analysis)
      end
    end
  end

  local function add_usage(kind, severity, items)
    for _, item in ipairs(items or {}) do
      local coordinate = type(item) == "table" and item.coordinate or item
      local module_id = type(item) == "table" and item.module_id or nil
      findings[#findings + 1] = decorate({
        kind = kind,
        severity = severity,
        coordinate = coordinate,
        module_id = module_id,
        force_blocked = true,
        blocked_reason = module_id and "usage repair requires explicit action"
          or "usage finding lacks module attribution",
      }, ownership_rows, analysis)
    end
  end
  add_usage("used_undeclared", "warning", usage.used_undeclared)
  add_usage("unused_declared", "info", usage.unused_declared)

  local severity_order = { error = 1, warning = 2, info = 3 }
  table.sort(findings, function(left, right)
    local left_severity = severity_order[left.severity] or 99
    local right_severity = severity_order[right.severity] or 99
    if left_severity ~= right_severity then
      return left_severity < right_severity
    end
    if left.kind ~= right.kind then
      return left.kind < right.kind
    end
    if left.coordinate ~= right.coordinate then
      return left.coordinate < right.coordinate
    end
    return (left.module_id or "") < (right.module_id or "")
  end)

  local base_counts = {}
  for _, finding in ipairs(findings) do
    local base = finding.kind .. ":" .. finding.coordinate
    base_counts[base] = (base_counts[base] or 0) + 1
  end
  local suffix_counts = {}
  for _, finding in ipairs(findings) do
    local base = finding.kind .. ":" .. finding.coordinate
    if base_counts[base] == 1 then
      finding.id = base
    else
      local suffix = finding.module_id or "reactor"
      local candidate = base .. ":" .. suffix
      suffix_counts[candidate] = (suffix_counts[candidate] or 0) + 1
      finding.id = candidate
      if suffix_counts[candidate] > 1 then
        finding.id = candidate .. ":" .. suffix_counts[candidate]
      end
    end
  end
  return findings
end

return M
