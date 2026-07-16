---Public API facade. Delegates to java_version (pure parsing) and java_home (I/O + discovery).
---@see java_scaffold.java_version
---@see java_scaffold.java_home

local version = require("java_scaffold.java_version")
local home = require("java_scaffold.java_home")

return {
  -- Version parsing (pure)
  parse_version = version.parse_version,
  parse_maven_version = version.parse_maven_version,
  parse_gradle_version = version.parse_gradle_version,

  -- Runtime detection (I/O)
  active = home.active,
  maven_runtime = home.maven_runtime,
  gradle_runtime = home.gradle_runtime,
  maven_runtime_async = home.maven_runtime_async,
  gradle_runtime_async = home.gradle_runtime_async,

  -- JDK discovery
  home_version = home.home_version,
  discover_homes = home.discover_homes,

  -- Composed helpers
  installed = home.installed,
  home = home.home,
  runner_env = home.runner_env,
  default = home.default,
}
