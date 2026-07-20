local events = require("duke.events")
local completion = require("duke.completion")
local pom_file = require("duke.pom_file")
local pom_repair = require("duke.pom_repair")
local transaction = require("duke.pom_transaction")

local M = {}

local diagnoses = {}
local plans = {}
local default_ttl_ms = 15 * 60 * 1000
local registry_limit = 32

local function same_or_child(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function canonical_file(path)
  if type(path) ~= "string" or path == "" then
    return nil, "reactor contains an invalid POM path"
  end
  local normalized = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local real = vim.uv.fs_realpath(normalized)
  if not real then
    return nil, "reactor POM does not exist"
  end
  real = vim.fs.normalize(real)
  if real ~= normalized then
    return nil, "symlinked reactor POMs are not writable"
  end
  return real
end

local function evict(registry, time)
  for id, value in pairs(registry) do
    if value.expires_at <= time then
      registry[id] = nil
    end
  end
end

local function registry_size(registry)
  local count = 0
  for _ in pairs(registry) do
    count = count + 1
  end
  return count
end

local function trim(registry)
  while registry_size(registry) >= registry_limit do
    local oldest_id
    local oldest_time
    for id, value in pairs(registry) do
      if not oldest_time or value.created_at < oldest_time then
        oldest_id = id
        oldest_time = value.created_at
      end
    end
    registry[oldest_id] = nil
  end
end

local function random_id()
  for _ = 1, 4 do
    local bytes, err = vim.uv.random(24)
    if not bytes then
      return nil, "cannot create reactor plan ID: " .. tostring(err)
    end
    local encoded = bytes:gsub(".", function(char)
      return string.format("%02x", string.byte(char))
    end)
    if not diagnoses[encoded] and not plans[encoded] then
      return encoded
    end
  end
  return nil, "cannot create unique reactor plan ID"
end

local function relative_label(root, path)
  local relative = vim.fs.relpath(root, path)
  return relative and relative ~= "" and relative or vim.fs.basename(path)
end

local function redacted_text(value, root)
  if type(value) ~= "string" then
    return value
  end
  return value:gsub(vim.pesc(root .. "/"), "")
end

local function public_ownership(owner, root)
  if type(owner) ~= "table" then
    return nil
  end
  local result = {
    kind = owner.kind,
    pom_label = owner.pom_path and relative_label(root, owner.pom_path) or nil,
    line = owner.line,
    property = owner.property,
    consumers = vim.deepcopy(owner.consumers or {}),
    writable = owner.writable == true,
    blocked_reason = redacted_text(owner.blocked_reason, root),
  }
  if type(owner.owners) == "table" then
    result.owners = vim.tbl_map(function(item)
      return {
        kind = item.kind,
        pom_label = item.pom_path and relative_label(root, item.pom_path) or nil,
        line = item.line,
        property = item.property,
        consumers = vim.deepcopy(item.consumers or {}),
        writable = item.writable == true,
        blocked_reason = redacted_text(item.blocked_reason, root),
      }
    end, owner.owners)
  end
  return result
end

local function public_finding(finding, root)
  return {
    id = finding.id,
    kind = finding.kind,
    severity = finding.severity,
    coordinate = finding.coordinate,
    module_id = finding.module_id,
    requested_versions = vim.deepcopy(finding.requested_versions or {}),
    selected_version = finding.selected_version,
    paths = vim.deepcopy(finding.paths or {}),
    consumers = vim.deepcopy(finding.consumers or {}),
    repairable = finding.repairable == true,
    repair_actions = vim.deepcopy(finding.repair_actions or {}),
    blocked_reason = redacted_text(finding.blocked_reason, root),
    ownership = public_ownership(finding.ownership, root),
  }
end

function M.capture(snapshot, opts)
  if type(snapshot) ~= "table" or snapshot.kind ~= "maven" then
    return nil, "reactor diagnosis requires a Maven workspace snapshot"
  end
  local root = vim.uv.fs_realpath(snapshot.root or "")
  if not root then
    return nil, "reactor diagnosis requires an existing root"
  end
  root = vim.fs.normalize(root)
  local modules = {}
  local module_order = {}
  local modules_by_id = {}
  for index, module in ipairs(snapshot.modules or {}) do
    local path, path_err = canonical_file(module.build_file)
    if not path then
      return nil, path_err
    end
    if not same_or_child(path, root) then
      return nil, "reactor POM is outside workspace root"
    end
    if modules[path] then
      return nil, "reactor contains duplicate canonical POM paths"
    end
    modules[path] = true
    module_order[path] = index
    if type(module.id) ~= "string" or modules_by_id[module.id] then
      return nil, "reactor contains invalid or duplicate module IDs"
    end
    modules_by_id[module.id] = path
  end
  if not next(modules) then
    return nil, "reactor diagnosis requires at least one module"
  end

  local findings = snapshot.analysis and snapshot.analysis.findings or {}
  local finding_ids = {}
  local public_findings = {}
  for _, original in ipairs(findings) do
    local finding = vim.deepcopy(original)
    if type(finding.id) ~= "string" or finding_ids[finding.id] then
      return nil, "reactor diagnosis contains invalid finding IDs"
    end
    if finding.ownership then
      local owners = finding.ownership.owners or { finding.ownership }
      for _, owner in ipairs(owners) do
        if owner.pom_path then
          local path, path_err = canonical_file(owner.pom_path)
          if not path then
            return nil, path_err
          end
          if not modules[path] then
            return nil, "repair owner is not a reactor module POM"
          end
          owner.pom_path = path
        end
      end
    end
    if finding.exclusion then
      local path, path_err = canonical_file(finding.exclusion.pom_path)
      if not path then
        return nil, path_err
      end
      if not modules[path] then
        return nil, "exclusion owner is not a reactor module POM"
      end
      finding.exclusion.pom_path = path
    end
    finding_ids[finding.id] = vim.deepcopy(finding)
    public_findings[#public_findings + 1] = public_finding(finding, root)
  end

  local time = vim.uv.now()
  evict(diagnoses, time)
  trim(diagnoses)
  local id, id_err = random_id()
  if not id then
    return nil, id_err
  end
  diagnoses[id] = {
    root = root,
    root_pom = vim.fs.joinpath(root, "pom.xml"),
    findings = finding_ids,
    modules = modules,
    modules_by_id = modules_by_id,
    module_order = module_order,
    created_at = time,
    expires_at = time + ((opts and opts.ttl_ms) or default_ttl_ms),
  }
  local warnings = snapshot.analysis
      and snapshot.analysis.doctor
      and snapshot.analysis.doctor.warnings
    or {}
  local active_profiles = snapshot.analysis
      and snapshot.analysis.doctor
      and snapshot.analysis.doctor.active_profiles
    or {}
  return {
    id = id,
    kind = "maven",
    state = snapshot.state,
    root_label = vim.fs.basename(root),
    deep = snapshot.analysis and snapshot.analysis.doctor and snapshot.analysis.doctor.deep == true
      or false,
    active_profiles = vim.tbl_map(function(profile)
      return redacted_text(profile, root)
    end, active_profiles),
    warnings = vim.tbl_map(function(warning)
      return redacted_text(warning, root)
    end, warnings),
    findings = public_findings,
  }
end

local function selected_repairs(diagnosis, requested)
  if type(requested) ~= "table" or #requested == 0 then
    return nil, "repairs must be a non-empty list"
  end
  local seen = {}
  local grouped = {}
  local coordinates = {}
  for _, selection in ipairs(requested) do
    local finding = type(selection) == "table" and diagnosis.findings[selection.finding_id] or nil
    if not finding then
      return nil, "unknown repair finding ID"
    end
    if seen[finding.id] then
      return nil, "duplicate repair finding ID"
    end
    seen[finding.id] = true
    if selection.action == "exclude" then
      local path_value = finding.paths and finding.paths[selection.path_index or 0]
      local direct = path_value and path_value[2]
      local exclusion = finding.exclusion
      if
        finding.kind ~= "version_conflict"
        or not direct
        or type(exclusion) ~= "table"
        or exclusion.writable ~= true
        or exclusion.direct_coordinate ~= direct
      then
        return nil, "exclusion requires a valid dependency path"
      end
      local repair = {
        kind = "exclude",
        direct_coordinate = direct,
        excluded_coordinate = finding.coordinate,
      }
      local path = exclusion.pom_path
      if not path or diagnosis.modules_by_id[finding.module_id] ~= path then
        return nil, "exclusion module is not in the reactor"
      end
      grouped[path] = grouped[path] or {}
      grouped[path][#grouped[path] + 1] = repair
    elseif type(selection.new_version) == "string" and selection.new_version ~= "" then
      if
        type(finding.ownership) ~= "table"
        or finding.ownership.writable ~= true
        or (finding.repair_actions and finding.repair_actions.upgrade ~= true)
      then
        return nil, finding.blocked_reason or "finding has no writable version owner"
      end
      local targets = finding.ownership.kind == "reactor_alignment" and finding.ownership.owners
        or { finding.ownership }
      if type(targets) ~= "table" or #targets == 0 then
        return nil, "repair owner is not a reactor module POM"
      end
      for _, target in ipairs(targets) do
        local path = target.pom_path
        if not diagnosis.modules[path] then
          return nil, "repair owner is not a reactor module POM"
        end
        local repair = {
          kind = "upgrade",
          new_version = selection.new_version,
          target = vim.deepcopy(target),
        }
        repair.target.coordinate = finding.coordinate
        repair.target.consumers = vim.deepcopy(repair.target.consumers or finding.consumers or {})
        grouped[path] = grouped[path] or {}
        grouped[path][#grouped[path] + 1] = repair
      end
    else
      return nil, "repair requires new_version or exclusion action"
    end
    coordinates[finding.coordinate] = true
  end
  local values = vim.tbl_keys(coordinates)
  table.sort(values)
  return grouped, values
end

function M.build(opts, callback)
  if type(callback) ~= "function" then
    completion.log("ERROR", "reactor plan callback is required")
    return
  end
  local finish = completion.once(callback, "reactor plan")
  local ok, internal_err = pcall(function()
    if type(opts) ~= "table" or type(opts.diagnosis_id) ~= "string" then
      finish("diagnosis_id must be a non-empty string")
      return
    end
    local time = vim.uv.now()
    evict(diagnoses, time)
    local diagnosis = diagnoses[opts.diagnosis_id]
    if not diagnosis then
      finish("unknown or expired reactor diagnosis")
      return
    end
    local grouped, coordinates_or_err = selected_repairs(diagnosis, opts.repairs)
    if not grouped then
      finish(coordinates_or_err)
      return
    end
    local entries = {}
    local all_changes = {}
    local modified_buffer_count = 0
    for path, repairs in pairs(grouped) do
      local snapshot, snapshot_err = pom_file.snapshot(path)
      if not snapshot then
        finish(snapshot_err)
        return
      end
      if snapshot.modified then
        modified_buffer_count = modified_buffer_count + 1
      end
      local after, changes, repair_err = pom_repair.apply(snapshot.lines, repairs)
      if not after then
        finish(repair_err)
        return
      end
      entries[#entries + 1] = {
        pom_path = path,
        before = vim.deepcopy(snapshot.lines),
        after = after,
        changes = changes,
        repairs = vim.deepcopy(repairs),
        order = diagnosis.module_order[path],
      }
    end
    table.sort(entries, function(left, right)
      if left.order ~= right.order then
        return left.order < right.order
      end
      return left.pom_path < right.pom_path
    end)
    for _, entry in ipairs(entries) do
      vim.list_extend(all_changes, vim.deepcopy(entry.changes))
    end
    if #all_changes == 0 then
      finish("selected repairs produce no changes")
      return
    end
    local id, id_err = random_id()
    if not id then
      finish(id_err)
      return
    end
    evict(plans, time)
    trim(plans)
    plans[id] = {
      root = diagnosis.root,
      root_pom = diagnosis.root_pom,
      entries = vim.deepcopy(entries),
      coordinates = coordinates_or_err,
      changes = vim.deepcopy(all_changes),
      created_at = time,
      expires_at = time + default_ttl_ms,
    }
    local files = {}
    for _, entry in ipairs(entries) do
      files[#files + 1] = {
        pom_label = relative_label(diagnosis.root, entry.pom_path),
        changes = vim.deepcopy(entry.changes),
      }
    end
    finish(nil, {
      id = id,
      preview = {
        file_count = #files,
        modified_buffer_count = modified_buffer_count,
        change_count = #all_changes,
        files = files,
      },
      coordinates = vim.deepcopy(coordinates_or_err),
    })
  end)
  if not ok then
    finish("reactor plan failed: " .. tostring(internal_err))
  end
end

function M.apply(descriptor, callback)
  if type(callback) ~= "function" then
    completion.log("ERROR", "reactor apply callback is required")
    return
  end
  local finish = completion.once(callback, "reactor apply")
  local id = type(descriptor) == "table" and descriptor.id or nil
  local time = vim.uv.now()
  evict(plans, time)
  local plan = type(id) == "string" and plans[id] or nil
  if not plan then
    finish("unknown or expired reactor plan")
    return
  end
  plans[id] = nil
  for _, entry in ipairs(plan.entries) do
    local after, changes, repair_err = pom_repair.apply(entry.before, entry.repairs)
    if
      not after
      or not vim.deep_equal(after, entry.after)
      or not vim.deep_equal(changes, entry.changes)
    then
      finish(
        "reactor plan no longer matches canonical repair: " .. tostring(repair_err or "mismatch")
      )
      return
    end
  end
  local started, start_err = pcall(transaction.apply, plan.root, plan.entries, function(err, result)
    if result then
      result.root = plan.root
      result.coordinates = vim.deepcopy(plan.coordinates)
      result.changes = vim.deepcopy(plan.changes)
    end
    if not err and result and result.ok and #result.changed_files > 0 then
      events.build_changed(plan.root_pom, "repair_reactor", {
        root = plan.root,
        build_files = vim.deepcopy(result.changed_files),
        coordinates = vim.deepcopy(plan.coordinates),
        changes = vim.deepcopy(plan.changes),
        saved = #result.modified_buffers == 0,
      })
    end
    finish(err, result)
  end)
  if not started then
    finish("cannot start reactor transaction: " .. tostring(start_err))
  end
end

function M.discard(descriptor)
  local id = type(descriptor) == "table" and descriptor.id or nil
  if type(id) ~= "string" then
    return false
  end
  if diagnoses[id] then
    diagnoses[id] = nil
    return true
  end
  if plans[id] then
    plans[id] = nil
    return true
  end
  return false
end

return M
