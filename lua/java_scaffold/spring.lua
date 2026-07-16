local M = {}

function M.package_name(group_id, artifact_id)
  return require("java_scaffold.maven").package_name(group_id, artifact_id)
end

local function add_param(args, key, value)
  args[#args + 1] = "--data-urlencode"
  args[#args + 1] = key .. "=" .. value
end

function M.build_curl_args(opts)
  local args = {
    "--fail-with-body",
    "--location",
    "--proto",
    "=https",
    "--silent",
    "--show-error",
    "--get",
    opts.url,
  }
  add_param(args, "type", opts.project_type)
  add_param(args, "language", opts.language)
  add_param(args, "packaging", opts.packaging)
  add_param(args, "groupId", opts.group_id)
  add_param(args, "artifactId", opts.artifact_id)
  add_param(args, "name", opts.name or opts.artifact_id)
  add_param(
    args,
    "packageName",
    opts.package_name or M.package_name(opts.group_id, opts.artifact_id)
  )
  add_param(args, "javaVersion", opts.java_version)
  if opts.boot_version and opts.boot_version ~= "" then
    add_param(args, "bootVersion", opts.boot_version)
  end
  if opts.dependencies and #opts.dependencies > 0 then
    add_param(args, "dependencies", table.concat(opts.dependencies, ","))
  end
  add_param(args, "baseDir", opts.artifact_id)
  args[#args + 1] = "--output"
  args[#args + 1] = opts.output
  return args
end

local function unsafe_archive_member(output)
  for member in (output or ""):gmatch("[^\r\n]+") do
    local normalized = member:gsub("\\", "/")
    if normalized:match("^/") or normalized:match("^%a:/") then
      return member
    end
    for component in normalized:gmatch("[^/]+") do
      if component == ".." then
        return member
      end
    end
  end
  return nil
end

function M.create(opts, callback)
  local validation_error = require("java_scaffold.maven").validate(opts.group_id, opts.artifact_id)
  if validation_error then
    callback(validation_error)
    return
  end

  local target = vim.fs.joinpath(opts.cwd, opts.artifact_id)
  if vim.uv.fs_stat(target) then
    callback("target already exists: " .. target)
    return
  end

  local fs = require("java_scaffold.fs")
  local staging, staging_error = fs.make_staging(opts.cwd)
  if not staging then
    callback(staging_error)
    return
  end

  local archive = vim.fn.tempname() .. ".tgz"
  local curl_args = M.build_curl_args(vim.tbl_extend("force", opts, { output = archive }))
  require("java_scaffold.process").run(
    "curl",
    curl_args,
    { timeout = opts.timeout },
    function(download)
      if download.code ~= 0 then
        fs.cleanup(archive)
        fs.cleanup(staging)
        local detail = require("java_scaffold.process").detail(download)
        callback("Spring project download failed: " .. detail)
        return
      end

      require("java_scaffold.process").run(
        "tar",
        { "-tzf", archive },
        { timeout = opts.timeout },
        function(inspect)
          if inspect.code ~= 0 then
            fs.cleanup(archive)
            fs.cleanup(staging)
            local detail = require("java_scaffold.process").detail(inspect)
            callback("Spring archive inspection failed: " .. detail)
            return
          end
          local unsafe = unsafe_archive_member(inspect.stdout)
          if unsafe then
            fs.cleanup(archive)
            fs.cleanup(staging)
            callback("Spring archive contains unsafe path: " .. unsafe)
            return
          end
          require("java_scaffold.process").run(
            "tar",
            { "-xzf", archive, "-C", staging },
            { timeout = opts.timeout },
            function(extract)
              fs.cleanup(archive)
              if extract.code ~= 0 then
                fs.cleanup(staging)
                local detail = require("java_scaffold.process").detail(extract)
                callback("Spring project extraction failed: " .. detail)
                return
              end
              local staged_project = vim.fs.joinpath(staging, opts.artifact_id)
              if not vim.uv.fs_stat(vim.fs.joinpath(staged_project, "pom.xml")) then
                fs.cleanup(staging)
                callback("Spring Initializr response contained no pom.xml")
                return
              end
              local promoted, promote_error = fs.promote(staged_project, target)
              fs.cleanup(staging)
              if not promoted then
                callback(promote_error)
                return
              end
              callback(nil, target)
            end
          )
        end
      )
    end
  )
end

return M
