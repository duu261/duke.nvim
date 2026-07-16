if vim.g.loaded_duke then
  return
end
vim.g.loaded_duke = true

vim.api.nvim_create_user_command("DukeNew", function()
  require("duke").new()
end, { desc = "Choose and create a Java project", force = true })

vim.api.nvim_create_user_command("DukeMaven", function()
  require("duke").new_maven()
end, { desc = "Create a Maven Java project", force = true })

vim.api.nvim_create_user_command("DukeGradle", function()
  require("duke").new_gradle()
end, { desc = "Create a Gradle Java project", force = true })

vim.api.nvim_create_user_command("DukeSpring", function()
  require("duke").new_spring()
end, { desc = "Create a Spring Boot project", force = true })

vim.api.nvim_create_user_command("DukeModule", function()
  require("duke").new_module()
end, { desc = "Add a module to a Maven multi-module reactor", force = true })

vim.api.nvim_create_user_command("DukeAdd", function()
  require("duke").add_dependency()
end, { desc = "Add dependencies to pom.xml (Spring catalog or Maven Central)", force = true })

vim.api.nvim_create_user_command("DukeUpgrade", function()
  require("duke").update_dependency()
end, { desc = "Update a root pom.xml dependency from Maven Central", force = true })

vim.api.nvim_create_user_command("DukeOutdated", function()
  require("duke").outdated_dependencies()
end, { desc = "List outdated root pom.xml dependencies", force = true })

vim.api.nvim_create_user_command("DukeRemove", function()
  require("duke").remove_dependency()
end, { desc = "Remove confirmed root pom.xml dependencies", force = true })

vim.api.nvim_create_user_command("DukeClearCache", function()
  require("duke").clear_cache()
end, { desc = "Clear cached Spring Initializr metadata", force = true })

vim.api.nvim_create_user_command("DukeLog", function()
  require("duke.log").show()
end, { desc = "Show duke.nvim log", force = true })

vim.api.nvim_create_user_command("DukeHealth", function()
  local ok, err = pcall(vim.cmd.checkhealth, "duke")
  if not ok then
    require("duke.log").add("ERROR", "health check failed: " .. tostring(err))
    vim.notify("duke.nvim: health check failed", vim.log.levels.ERROR)
  end
end, { desc = "Check duke.nvim health", force = true })
