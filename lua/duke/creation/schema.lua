local M = {}

local kinds = {
  maven = true,
  gradle = true,
  spring = true,
}

local common_fields = {
  { id = "destination", label = "Destination", editor = "input" },
  { id = "group_id", label = "Group ID", editor = "input" },
  { id = "artifact_id", label = "Artifact ID", editor = "input" },
  { id = "package_name", label = "Package", editor = "input" },
}

local function copy_fields(fields)
  return vim.deepcopy(fields)
end

local function append(fields, values)
  for _, value in ipairs(values) do
    fields[#fields + 1] = vim.deepcopy(value)
  end
  return fields
end

local function first(values, fallback)
  return type(values) == "table" and values[1] or fallback
end

function M.valid_kind(kind)
  return kinds[kind] == true
end

function M.defaults(kind, config, context)
  if not M.valid_kind(kind) then
    return nil, "unknown project generator: " .. tostring(kind)
  end
  context = context or {}
  local values = {
    destination = context.cwd or vim.fn.getcwd(),
    group_id = config.group_id,
    artifact_id = config.artifact_id,
    package_name = require("duke.maven").package_name(config.group_id, config.artifact_id),
    java_version = config.java_version,
  }
  if kind == "maven" then
    values.archetype = first(config.maven.archetypes)
  elseif kind == "gradle" then
    values.gradle_project_type_id = config.gradle.default_project_type
    values.language = "java"
    values.dsl = config.gradle.dsl
  else
    values.name = config.artifact_id
    values.description = "Demo project for Spring Boot"
    values.dependency_ids = {}
    values.spring_language = config.spring.language
    values.spring_packaging = config.spring.packaging
  end
  return values
end

function M.fields(kind, config, _snapshot)
  if not M.valid_kind(kind) then
    return {}
  end
  local fields = copy_fields(common_fields)
  if kind == "maven" then
    append(fields, {
      {
        id = "archetype",
        label = "Archetype",
        editor = "select",
        choices = config.maven.archetypes,
      },
      { id = "java_version", label = "Java target", editor = "select" },
    })
  elseif kind == "gradle" then
    append(fields, {
      {
        id = "gradle_project_type_id",
        label = "Project type",
        editor = "select",
        choices = config.gradle.project_types,
      },
      {
        id = "language",
        label = "Language",
        editor = "select",
        choices = config.gradle.languages,
      },
      { id = "dsl", label = "Build DSL", editor = "select", choices = config.gradle.dsls },
      { id = "java_version", label = "Java target", editor = "select" },
    })
  else
    append(fields, {
      { id = "name", label = "Name", editor = "input" },
      { id = "description", label = "Description", editor = "input" },
      { id = "boot_version", label = "Spring Boot", editor = "select" },
      { id = "spring_project_type", label = "Build type", editor = "select" },
      { id = "spring_language", label = "Language", editor = "select" },
      { id = "spring_packaging", label = "Packaging", editor = "select" },
      { id = "java_version", label = "Java target", editor = "select" },
      { id = "dependency_ids", label = "Dependencies", editor = "dependencies" },
    })
  end
  return fields
end

local function blank(value)
  return type(value) ~= "string" or vim.trim(value) == ""
end

function M.validate(kind, config, snapshot)
  local errors = {}
  if not M.valid_kind(kind) then
    errors.kind = "unknown project generator"
    return errors
  end
  local values = snapshot.values or {}
  if blank(values.destination) then
    errors.destination = "destination is required"
  end
  local maven = require("duke.maven")
  if maven.validate(values.group_id, "valid") then
    errors.group_id = "group ID contains invalid characters"
  end
  if maven.validate("valid", values.artifact_id) then
    errors.artifact_id = "artifact ID contains invalid characters"
  end
  errors.package_name = maven.validate_package(values.package_name)
  if blank(values.java_version) then
    errors.java_version = "Java target is required"
  else
    local derived = snapshot.derived or {}
    local detected = derived[kind .. "_detected_runtime"]
    if
      detected
      and tonumber(values.java_version)
      and tonumber(values.java_version) > tonumber(detected)
    then
      errors.java_version = string.format(
        "Java target %s exceeds %s runner Java %s",
        values.java_version,
        kind == "maven" and "Maven" or "Gradle",
        detected
      )
    elseif
      kind == "spring"
      and type(derived.java_versions) == "table"
      and #derived.java_versions > 0
      and not vim.tbl_contains(derived.java_versions, values.java_version)
    then
      errors.java_version = "Java target is unavailable for selected Spring Boot version"
    end
  end

  if kind == "maven" and type(values.archetype) ~= "table" then
    errors.archetype = "Maven archetype is required"
  elseif kind == "gradle" then
    local project_type =
      require("duke.gradle").project_type(values.language, values.gradle_project_type_id)
    if not project_type then
      errors.gradle_project_type_id = "unsupported Gradle project type"
    end
    if not vim.tbl_contains(config.gradle.dsls, values.dsl) then
      errors.dsl = "unsupported Gradle DSL"
    end
  elseif kind == "spring" then
    if blank(values.name) then
      errors.name = "project name is required"
    end
    if blank(values.boot_version) then
      errors.boot_version = "Spring Boot version is required"
    end
    if type(values.spring_project_type) ~= "table" then
      errors.spring_project_type = "Spring project type is required"
    end
    if blank(values.spring_language) then
      errors.spring_language = "Spring language is required"
    end
    if blank(values.spring_packaging) then
      errors.spring_packaging = "Spring packaging is required"
    end
    local catalog = snapshot.derived and snapshot.derived.spring_catalog
    if type(catalog) ~= "table" or type(catalog.dependencies) ~= "table" then
      errors.dependency_ids = "Spring dependency catalog is not ready"
    else
      local missing = {}
      for _, id in ipairs(values.dependency_ids or {}) do
        if not catalog.dependencies[id] then
          missing[#missing + 1] = id
        end
      end
      if #missing > 0 then
        errors.dependency_ids = "Spring dependencies unavailable for selected Boot: "
          .. table.concat(missing, ", ")
      end
    end
  end
  return errors
end

function M.request(kind, config, snapshot)
  local errors = M.validate(kind, config, snapshot)
  if next(errors) then
    return nil, errors
  end
  local values = snapshot.values
  local derived = snapshot.derived or {}
  local common = {
    cwd = values.destination,
    group_id = values.group_id,
    artifact_id = values.artifact_id,
    package_name = values.package_name,
    java_version = values.java_version,
  }
  local request
  if kind == "maven" then
    request = vim.tbl_extend("force", common, {
      command = config.maven.command,
      version = config.maven.project_version,
      wrapper = config.maven.wrapper,
      archetype = values.archetype,
      timeout = config.maven.timeout,
      env = derived.maven_runner_env,
    })
  elseif kind == "gradle" then
    request = vim.tbl_extend("force", common, {
      command = config.gradle.command,
      project_type = require("duke.gradle").project_type(
        values.language,
        values.gradle_project_type_id
      ),
      dsl = values.dsl,
      test_framework = config.gradle.test_framework,
      timeout = config.gradle.timeout,
      env = derived.gradle_runner_env,
    })
  else
    request = vim.tbl_extend("force", common, {
      url = config.spring.starter_url,
      name = values.name,
      description = values.description,
      boot_version = values.boot_version,
      dependencies = values.dependency_ids,
      project_type = values.spring_project_type.id,
      build = values.spring_project_type.build,
      language = values.spring_language,
      packaging = values.spring_packaging,
      timeout = config.spring.timeout,
    })
  end
  return vim.deepcopy(request)
end

return M
