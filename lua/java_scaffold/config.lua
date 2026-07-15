local M = {}

local defaults = {
  group_id = "com.example",
  artifact_id = "demo",
  java_version = "auto",
  java_versions = {},
  java_homes = {},
  entry_selector = nil,
  maven = {
    command = "mvn",
    runner_java_version = "auto",
    wrapper = false,
    project_version = "1.0-SNAPSHOT",
    timeout = 180000,
    archetype = {
      group_id = "org.apache.maven.archetypes",
      artifact_id = "maven-archetype-quickstart",
      version = "1.5",
    },
  },
  gradle = {
    command = "gradle",
    runner_java_version = "auto",
    dsl = "kotlin",
    test_framework = "auto",
    timeout = 180000,
    default_project_type = "java-application",
    project_types = {
      { id = "java-application", name = "Java application" },
      { id = "java-library", name = "Java library" },
      { id = "java-gradle-plugin", name = "Gradle plugin" },
    },
  },
  spring = {
    metadata_url = "https://start.spring.io",
    dependencies_url = "https://start.spring.io/dependencies",
    starter_url = "https://start.spring.io/starter.tgz",
    project_type = "maven-project",
    language = "java",
    packaging = "jar",
    metadata_timeout = 30000,
    timeout = 60000,
  },
  handoff = {
    enabled = false,
    required_executables = {},
  },
}

local options = vim.deepcopy(defaults)

local function warn(key, expected)
  vim.schedule(function()
    vim.notify(
      string.format("java-scaffold.nvim: %s must be %s; using default", key, expected),
      vim.log.levels.WARN
    )
  end)
end

local function non_empty_string(value)
  return type(value) == "string" and value ~= ""
end

local function positive_number(value)
  return type(value) == "number" and value > 0
end

local function string_list(value, allow_empty)
  if type(value) ~= "table" or (not allow_empty and #value == 0) then
    return false
  end
  for _, item in ipairs(value) do
    if not non_empty_string(item) then
      return false
    end
  end
  return true
end

local function validate(opts)
  for _, key in ipairs({ "maven", "gradle", "spring", "handoff" }) do
    if type(opts[key]) ~= "table" then
      warn(key, "a table")
      opts[key] = vim.deepcopy(defaults[key])
    end
  end
  if type(opts.maven.archetype) ~= "table" then
    warn("maven.archetype", "a table")
    opts.maven.archetype = vim.deepcopy(defaults.maven.archetype)
  end

  if not non_empty_string(opts.group_id) then
    warn("group_id", "a non-empty string")
    opts.group_id = defaults.group_id
  end
  if
    not non_empty_string(opts.java_version)
    or (opts.java_version ~= "auto" and not opts.java_version:match("^%d+$"))
  then
    warn("java_version", "'auto' or a numeric version string")
    opts.java_version = defaults.java_version
  end
  if not non_empty_string(opts.artifact_id) then
    warn("artifact_id", "a non-empty string")
    opts.artifact_id = defaults.artifact_id
  end
  local valid_java_versions = type(opts.java_versions) == "table"
  if valid_java_versions then
    for _, version in ipairs(opts.java_versions) do
      if not tostring(version):match("^%d+$") then
        valid_java_versions = false
        break
      end
    end
  end
  if not valid_java_versions then
    warn("java_versions", "a list of numeric versions")
    opts.java_versions = vim.deepcopy(defaults.java_versions)
  end
  local valid_java_homes = type(opts.java_homes) == "table"
  local normalized_java_homes = {}
  if valid_java_homes then
    for version, path in pairs(opts.java_homes) do
      if not tostring(version):match("^%d+$") or not non_empty_string(path) then
        valid_java_homes = false
        break
      end
      normalized_java_homes[tostring(version)] = path
    end
  end
  if not valid_java_homes then
    warn("java_homes", "a numeric-version to path map")
    opts.java_homes = vim.deepcopy(defaults.java_homes)
  else
    opts.java_homes = normalized_java_homes
  end
  if opts.entry_selector ~= nil and type(opts.entry_selector) ~= "function" then
    warn("entry_selector", "a function or nil")
    opts.entry_selector = defaults.entry_selector
  end
  if not non_empty_string(opts.maven.command) then
    warn("maven.command", "a non-empty string")
    opts.maven.command = defaults.maven.command
  end
  if type(opts.maven.wrapper) ~= "boolean" then
    warn("maven.wrapper", "a boolean")
    opts.maven.wrapper = defaults.maven.wrapper
  end
  if
    not non_empty_string(opts.maven.runner_java_version)
    or (
      opts.maven.runner_java_version ~= "auto"
      and not opts.maven.runner_java_version:match("^%d+$")
    )
  then
    warn("maven.runner_java_version", "'auto' or a numeric version string")
    opts.maven.runner_java_version = defaults.maven.runner_java_version
  end
  if not non_empty_string(opts.maven.project_version) then
    warn("maven.project_version", "a non-empty string")
    opts.maven.project_version = defaults.maven.project_version
  end
  if not positive_number(opts.maven.timeout) then
    warn("maven.timeout", "a positive number")
    opts.maven.timeout = defaults.maven.timeout
  end
  for _, key in ipairs({ "group_id", "artifact_id", "version" }) do
    if not non_empty_string(opts.maven.archetype[key]) then
      warn("maven.archetype." .. key, "a non-empty string")
      opts.maven.archetype[key] = defaults.maven.archetype[key]
    end
  end

  for _, key in ipairs({ "command", "dsl", "test_framework", "default_project_type" }) do
    if not non_empty_string(opts.gradle[key]) then
      warn("gradle." .. key, "a non-empty string")
      opts.gradle[key] = defaults.gradle[key]
    end
  end
  if
    not non_empty_string(opts.gradle.runner_java_version)
    or (
      opts.gradle.runner_java_version ~= "auto"
      and not opts.gradle.runner_java_version:match("^%d+$")
    )
  then
    warn("gradle.runner_java_version", "'auto' or a numeric version string")
    opts.gradle.runner_java_version = defaults.gradle.runner_java_version
  end
  if not positive_number(opts.gradle.timeout) then
    warn("gradle.timeout", "a positive number")
    opts.gradle.timeout = defaults.gradle.timeout
  end
  local valid_project_types = type(opts.gradle.project_types) == "table"
    and #opts.gradle.project_types > 0
  if valid_project_types then
    for _, project_type in ipairs(opts.gradle.project_types) do
      if
        type(project_type) ~= "table"
        or not non_empty_string(project_type.id)
        or not non_empty_string(project_type.name)
      then
        valid_project_types = false
        break
      end
    end
  end
  if not valid_project_types then
    warn("gradle.project_types", "a non-empty list of id/name tables")
    opts.gradle.project_types = vim.deepcopy(defaults.gradle.project_types)
  end

  for _, key in ipairs({
    "metadata_url",
    "dependencies_url",
    "starter_url",
    "project_type",
    "language",
    "packaging",
  }) do
    if not non_empty_string(opts.spring[key]) then
      warn("spring." .. key, "a non-empty string")
      opts.spring[key] = defaults.spring[key]
    end
  end
  for _, key in ipairs({ "metadata_timeout", "timeout" }) do
    if not positive_number(opts.spring[key]) then
      warn("spring." .. key, "a positive number")
      opts.spring[key] = defaults.spring[key]
    end
  end

  if type(opts.handoff.enabled) ~= "boolean" then
    warn("handoff.enabled", "a boolean")
    opts.handoff.enabled = defaults.handoff.enabled
  end
  if opts.handoff.command ~= nil and not string_list(opts.handoff.command, false) then
    warn("handoff.command", "a non-empty argument list")
    opts.handoff.command = nil
  end
  if not string_list(opts.handoff.required_executables, true) then
    warn("handoff.required_executables", "a list")
    opts.handoff.required_executables = vim.deepcopy(defaults.handoff.required_executables)
  end
end

function M.setup(opts)
  if type(opts) ~= "table" then
    warn("setup options", "a table")
    opts = {}
  end
  options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  validate(options)
end

function M.get()
  return options
end

return M
