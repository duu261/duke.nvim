describe("project entry", function()
  local project
  local root

  before_each(function()
    package.loaded["duke.project"] = nil
    project = require("duke.project")
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("prefers generated application Java source", function()
    local source = vim.fs.joinpath(root, "app", "src", "main", "java", "com", "demo")
    vim.fn.mkdir(source, "p")
    vim.fn.writefile({ "class Other {}" }, vim.fs.joinpath(source, "Other.java"))
    local application = vim.fs.joinpath(source, "DemoApplication.java")
    vim.fn.writefile({ "class DemoApplication {}" }, application)
    vim.fn.writefile({ "plugins {}" }, vim.fs.joinpath(root, "build.gradle.kts"))

    assert.equals(application, project.entry(root))
  end)

  it("falls back to build file when no Java source exists", function()
    local build = vim.fs.joinpath(root, "build.gradle.kts")
    vim.fn.writefile({ "plugins {}" }, build)

    assert.equals(build, project.entry(root))
  end)
end)
