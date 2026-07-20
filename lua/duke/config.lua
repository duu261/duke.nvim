local M = {}

local defaults = {
  group_id = "com.example",
  artifact_id = "demo",
  java_version = "auto",
  java_versions = {},
  java_homes = {},
  entry_selector = nil,
  creation = {
    layout = "auto",
  },
  maven = {
    command = "mvn",
    runner_java_version = "auto",
    wrapper = false,
    project_version = "1.0-SNAPSHOT",
    timeout = 180000,
    central_search_url = "https://search.maven.org/solrsearch/select",
    central_search_rows = 20,
    central_search_timeout = 15000,
    archetypes = {
      {
        name = "Maven quickstart",
        group_id = "org.apache.maven.archetypes",
        artifact_id = "maven-archetype-quickstart",
        version = "1.5",
      },
      {
        name = "Maven web application",
        group_id = "org.apache.maven.archetypes",
        artifact_id = "maven-archetype-webapp",
        version = "1.5",
      },
    },
  },
  gradle = {
    command = "gradle",
    runner_java_version = "auto",
    dsl = "kotlin",
    dsls = { "kotlin", "groovy" },
    languages = { "java", "kotlin", "groovy" },
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
      string.format("duke.nvim: %s must be %s; using default", key, expected),
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
  for _, key in ipairs({ "creation", "maven", "gradle", "spring", "handoff" }) do
    if type(opts[key]) ~= "table" then
      warn(key, "a table")
      opts[key] = vim.deepcopy(defaults[key])
    end
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
  if not vim.tbl_contains({ "auto", "wide", "compact" }, opts.creation.layout) then
    warn("creation.layout", "'auto', 'wide', or 'compact'")
    opts.creation.layout = defaults.creation.layout
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
  if not non_empty_string(opts.maven.central_search_url) then
    warn("maven.central_search_url", "a non-empty string")
    opts.maven.central_search_url = defaults.maven.central_search_url
  end
  if not positive_number(opts.maven.central_search_rows) then
    warn("maven.central_search_rows", "a positive number")
    opts.maven.central_search_rows = defaults.maven.central_search_rows
  end
  if not positive_number(opts.maven.central_search_timeout) then
    warn("maven.central_search_timeout", "a positive number")
    opts.maven.central_search_timeout = defaults.maven.central_search_timeout
  end
  local valid_archetypes = type(opts.maven.archetypes) == "table" and #opts.maven.archetypes > 0
  if valid_archetypes then
    for _, archetype in ipairs(opts.maven.archetypes) do
      if type(archetype) ~= "table" then
        valid_archetypes = false
        break
      end
      for _, key in ipairs({ "group_id", "artifact_id", "version" }) do
        if not non_empty_string(archetype[key]) then
          valid_archetypes = false
          break
        end
      end
      if not valid_archetypes then
        break
      end
      if archetype.name ~= nil and not non_empty_string(archetype.name) then
        valid_archetypes = false
        break
      end
    end
  end
  if not valid_archetypes then
    warn("maven.archetypes", "a non-empty list of archetype tables")
    opts.maven.archetypes = vim.deepcopy(defaults.maven.archetypes)
  end

  for _, key in ipairs({ "command", "dsl", "test_framework", "default_project_type" }) do
    if not non_empty_string(opts.gradle[key]) then
      warn("gradle." .. key, "a non-empty string")
      opts.gradle[key] = defaults.gradle[key]
    end
  end
  if not string_list(opts.gradle.dsls, false) then
    warn("gradle.dsls", "a non-empty list")
    opts.gradle.dsls = vim.deepcopy(defaults.gradle.dsls)
  end
  if not string_list(opts.gradle.languages, false) then
    warn("gradle.languages", "a non-empty list")
    opts.gradle.languages = vim.deepcopy(defaults.gradle.languages)
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
  if type(opts.maven) == "table" and opts.maven.archetypes ~= nil then
    options.maven.archetypes = vim.deepcopy(opts.maven.archetypes)
  elseif type(opts.maven) == "table" and type(opts.maven.archetype) == "table" then
    options.maven.archetypes = { vim.deepcopy(opts.maven.archetype) }
  end
  if type(opts.gradle) == "table" then
    for _, key in ipairs({ "dsls", "languages", "project_types" }) do
      if opts.gradle[key] ~= nil then
        options.gradle[key] = vim.deepcopy(opts.gradle[key])
      end
    end
  end
  validate(options)
end

function M.get()
  return options
end

return M
