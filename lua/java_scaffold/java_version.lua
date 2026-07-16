---Java version string parsing. Pure functions, no I/O.
---Input: version command output strings. Output: major version numbers.

local M = {}

function M.parse_version(output)
  if type(output) ~= "string" then
    return nil
  end
  local quoted = output:match('version%s+"([^"]+)"') or output:match("openjdk%s+([%d._]+)")
  if not quoted then
    return nil
  end
  local legacy = quoted:match("^1%.(%d+)")
  return legacy or quoted:match("^(%d+)")
end

function M.parse_maven_version(output)
  if type(output) ~= "string" then
    return nil
  end
  return output:match("Java version:%s*(%d+)")
end

function M.parse_gradle_version(output)
  if type(output) ~= "string" then
    return nil
  end
  return output:match("Launcher JVM:%s*(%d+)") or output:match("JVM:%s*(%d+)")
end

return M
