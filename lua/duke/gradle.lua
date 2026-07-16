local M = {}

function M.test_framework(java_version, configured)
  if configured ~= "auto" then
    return configured
  end
  return tonumber(java_version) < 17 and "junit" or "junit-jupiter"
end

function M.project_type(language, project_type)
  if
    type(project_type) ~= "string"
    or not vim.tbl_contains({ "java", "kotlin", "groovy" }, language)
  then
    return nil
  end
  local suffix = project_type:match("^java%-(application)$")
    or project_type:match("^java%-(library)$")
    or project_type:match("^java%-(gradle%-plugin)$")
  if not suffix then
    return nil
  end
  return language .. "-" .. suffix
end

function M.build_args(opts)
  return {
    "init",
    "--type",
    opts.project_type,
    "--dsl",
    opts.dsl,
    "--test-framework",
    M.test_framework(opts.java_version, opts.test_framework),
    "--package",
    opts.package_name or require("duke.maven").package_name(opts.group_id, opts.artifact_id),
    "--into",
    opts.output_directory,
    "--project-name",
    opts.artifact_id,
    "--no-split-project",
    "--java-version",
    opts.java_version,
    "--use-defaults",
    "--no-incubating",
  }
end

local function generated(path)
  local build = vim.fn.globpath(path, "**/build.gradle", false, true)
  vim.list_extend(build, vim.fn.globpath(path, "**/build.gradle.kts", false, true))
  local settings = vim.fn.filereadable(vim.fs.joinpath(path, "settings.gradle")) == 1
    or vim.fn.filereadable(vim.fs.joinpath(path, "settings.gradle.kts")) == 1
  return #build > 0 and settings
end

function M.create(opts, callback)
  require("duke.generator").run(opts, M.adapter, callback)
end

M.adapter = {
  validate = function(opts)
    local maven = require("duke.maven")
    local err = maven.validate(opts.group_id, opts.artifact_id)
    if err then
      return err
    end
    return maven.validate_package(
      opts.package_name or maven.package_name(opts.group_id, opts.artifact_id)
    )
  end,

  execute = function(opts, staging, callback)
    local staged_project = vim.fs.joinpath(staging, opts.artifact_id)
    local args = M.build_args(vim.tbl_extend("force", opts, {
      output_directory = staged_project,
    }))

    require("duke.process").run(opts.command, args, {
      cwd = opts.cwd,
      env = opts.env,
      timeout = opts.timeout,
    }, function(result)
      if result.code ~= 0 then
        local detail = require("duke.process").detail(result)
        callback("Gradle project creation failed: " .. detail)
        return
      end
      if not generated(staged_project) then
        callback("Gradle exited successfully but no build files were created")
        return
      end
      callback(nil)
    end)
  end,
}

return M
