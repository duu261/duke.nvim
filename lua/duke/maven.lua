local M = {}

local reserved_words = {}
for _, word in ipairs({
  "abstract",
  "assert",
  "boolean",
  "break",
  "byte",
  "case",
  "catch",
  "char",
  "class",
  "const",
  "continue",
  "default",
  "do",
  "double",
  "else",
  "enum",
  "extends",
  "final",
  "finally",
  "float",
  "for",
  "goto",
  "if",
  "implements",
  "import",
  "instanceof",
  "int",
  "interface",
  "long",
  "native",
  "new",
  "package",
  "private",
  "protected",
  "public",
  "return",
  "short",
  "static",
  "strictfp",
  "super",
  "switch",
  "synchronized",
  "this",
  "throw",
  "throws",
  "transient",
  "try",
  "void",
  "volatile",
  "while",
  "true",
  "false",
  "null",
  "_",
}) do
  reserved_words[word] = true
end

local function sanitize_segment(segment)
  local clean = segment:gsub("[^%w_]", "")
  if clean:match("^%d") then
    clean = "_" .. clean
  end
  return clean
end

function M.package_name(group_id, artifact_id)
  local parts = {}
  for part in group_id:gmatch("[^.]+") do
    local clean = sanitize_segment(part)
    if clean ~= "" then
      parts[#parts + 1] = clean
    end
  end
  local artifact = sanitize_segment(artifact_id)
  if artifact ~= "" then
    parts[#parts + 1] = artifact
  end
  return table.concat(parts, ".")
end

function M.validate_package(package_name)
  if
    type(package_name) ~= "string"
    or package_name == ""
    or package_name:sub(1, 1) == "."
    or package_name:sub(-1) == "."
    or package_name:find("..", 1, true)
    or package_name:find("%s")
  then
    return "package name contains invalid segments"
  end
  for segment in package_name:gmatch("[^.]+") do
    if not segment:match("^[%a_$][%w_$]*$") or reserved_words[segment] then
      return "package name contains invalid segments"
    end
  end
end

function M.validate(group_id, artifact_id)
  if
    type(group_id) ~= "string"
    or group_id == ""
    or not group_id:match("^[%w_.-]+$")
    or group_id:find("..", 1, true)
  then
    return "groupId contains invalid characters"
  end
  if
    type(artifact_id) ~= "string"
    or artifact_id == ""
    or not artifact_id:match("^[%w][%w_.-]*$")
  then
    return "artifactId contains invalid characters"
  end
end

function M.build_args(opts)
  return {
    "-B",
    "archetype:generate",
    "-DarchetypeGroupId=" .. opts.archetype.group_id,
    "-DarchetypeArtifactId=" .. opts.archetype.artifact_id,
    "-DarchetypeVersion=" .. opts.archetype.version,
    "-DgroupId=" .. opts.group_id,
    "-DartifactId=" .. opts.artifact_id,
    "-Dversion=" .. opts.version,
    "-Dpackage=" .. (opts.package_name or M.package_name(opts.group_id, opts.artifact_id)),
    "-DjavaCompilerVersion=" .. opts.java_version,
    "-DoutputDirectory=" .. (opts.output_directory or opts.cwd),
    "-DinteractiveMode=false",
  }
end

local wrapper_files = {
  "mvnw",
  "mvnw.cmd",
  ".mvn/wrapper/maven-wrapper.properties",
}

local function wrapper_args()
  return { "-B", "wrapper:wrapper", "-Dtype=only-script" }
end

function M.create(opts, callback)
  require("duke.generator").run(opts, M.adapter, callback)
end

M.adapter = {
  validate = function(opts)
    local err = M.validate(opts.group_id, opts.artifact_id)
    if err then
      return err
    end
    return M.validate_package(opts.package_name or M.package_name(opts.group_id, opts.artifact_id))
  end,

  execute = function(opts, staging, callback)
    local staged_project = vim.fs.joinpath(staging, opts.artifact_id)
    local args = M.build_args(vim.tbl_extend("force", opts, { output_directory = staging }))
    local process = require("duke.process")

    local function generate_wrapper()
      process.run(
        opts.command,
        wrapper_args(),
        { cwd = staged_project, timeout = opts.timeout, env = opts.env },
        function(result)
          if result.code ~= 0 then
            callback("Maven Wrapper generation failed: " .. process.detail(result))
            return
          end
          for _, relative in ipairs(wrapper_files) do
            if not vim.uv.fs_stat(vim.fs.joinpath(staged_project, relative)) then
              callback("Maven Wrapper output missing " .. relative)
              return
            end
          end
          callback(nil)
        end
      )
    end

    process.run(
      opts.command,
      args,
      { cwd = opts.cwd, timeout = opts.timeout, env = opts.env },
      function(result)
        if result.code ~= 0 then
          callback("Maven project creation failed: " .. process.detail(result))
          return
        end
        if not vim.uv.fs_stat(vim.fs.joinpath(staged_project, "pom.xml")) then
          callback("Maven exited successfully but no pom.xml was created")
          return
        end
        if opts.wrapper then
          generate_wrapper()
          return
        end
        callback(nil)
      end
    )
  end,
}

return M
