if vim.g.loaded_java_scaffold then
  return
end
vim.g.loaded_java_scaffold = true

vim.api.nvim_create_user_command("JavaScaffoldNew", function()
  require("java_scaffold").new()
end, { desc = "Choose and create a Java project", force = true })

vim.api.nvim_create_user_command("JavaScaffoldMaven", function()
  require("java_scaffold").new_maven()
end, { desc = "Create a Maven Java project", force = true })

vim.api.nvim_create_user_command("JavaScaffoldGradle", function()
  require("java_scaffold").new_gradle()
end, { desc = "Create a Gradle Java project", force = true })

vim.api.nvim_create_user_command("JavaScaffoldSpring", function()
  require("java_scaffold").new_spring()
end, { desc = "Create a Spring Boot project", force = true })

vim.api.nvim_create_user_command("JavaScaffoldAddDependency", function()
  require("java_scaffold").add_dependency()
end, { desc = "Add Spring dependencies to pom.xml", force = true })

vim.api.nvim_create_user_command("JavaScaffoldClearCache", function()
  require("java_scaffold").clear_cache()
end, { desc = "Clear cached Spring Initializr metadata", force = true })

vim.api.nvim_create_user_command("JavaScaffoldLog", function()
  require("java_scaffold.log").show()
end, { desc = "Show java-scaffold.nvim log", force = true })

vim.api.nvim_create_user_command("JavaScaffoldHealth", function()
  local ok, err = pcall(vim.cmd.checkhealth, "java_scaffold")
  if not ok then
    require("java_scaffold.log").add("ERROR", "health check failed: " .. tostring(err))
    vim.notify("java-scaffold.nvim: health check failed", vim.log.levels.ERROR)
  end
end, { desc = "Check java-scaffold.nvim health", force = true })
