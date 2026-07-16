local M = {}

function M.entry(project_dir)
  local sources = vim.fn.globpath(project_dir, "**/src/main/java/**/*.java", false, true)
  table.sort(sources, function(left, right)
    local function score(path)
      local name = vim.fs.basename(path)
      if name:match("Application%.java$") then
        return 1
      end
      if name == "App.java" or name == "Main.java" then
        return 2
      end
      return 3
    end
    local left_score = score(left)
    local right_score = score(right)
    return left_score == right_score and left < right or left_score < right_score
  end)
  if sources[1] then
    return sources[1]
  end
  for _, name in ipairs({ "pom.xml", "build.gradle.kts", "build.gradle", "settings.gradle.kts" }) do
    local candidates = vim.fn.globpath(project_dir, "**/" .. name, false, true)
    if candidates[1] then
      return candidates[1]
    end
  end
  return project_dir
end

return M
