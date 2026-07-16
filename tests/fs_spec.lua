describe("Filesystem staging", function()
  local fs
  local temporary_directories = {}

  before_each(function()
    package.loaded["duke.fs"] = nil
    fs = require("duke.fs")
  end)

  after_each(function()
    for _, path in ipairs(temporary_directories) do
      vim.fn.delete(path, "rf")
    end
    temporary_directories = {}
  end)

  local function temp_dir()
    local path = vim.fn.tempname()
    vim.fn.mkdir(path, "p")
    temporary_directories[#temporary_directories + 1] = path
    return path
  end

  describe("make_staging", function()
    it("creates a staging directory under the parent", function()
      local parent = temp_dir()
      local staging = fs.make_staging(parent)

      assert.is_string(staging)
      assert.equals(parent, vim.fs.dirname(staging))
      assert.is_truthy(vim.uv.fs_stat(staging))
      assert.is_truthy(staging:match("%.duke%-"))
    end)

    it("creates unique names across consecutive calls", function()
      local parent = temp_dir()
      local a = fs.make_staging(parent)
      local b = fs.make_staging(parent)

      assert.not_equals(a, b)
      assert.is_truthy(vim.uv.fs_stat(a))
      assert.is_truthy(vim.uv.fs_stat(b))
    end)

    it("retries when a random name collides with an existing directory", function()
      local parent = temp_dir()
      local original_random = vim.uv.random
      local calls = 0

      vim.uv.random = function(bytes)
        calls = calls + 1
        if calls == 1 then
          -- First call: return bytes that produce hex "ab" repeated
          return string.rep("\171", bytes) -- 0xAB = 171
        end
        -- Subsequent calls: use real random
        return original_random(bytes)
      end

      -- Pre-create the directory that the first random name would produce
      local conflict = vim.fs.joinpath(parent, ".duke-" .. ("ab"):rep(8))
      vim.fn.mkdir(conflict, "p")

      local staging = fs.make_staging(parent)

      -- Restore before assertions so cleanup works
      vim.uv.random = original_random

      assert.is_truthy(vim.uv.fs_stat(staging))
      assert.not_equals(conflict, staging)
      assert.equals(2, calls) -- first hit EEXIST, second succeeded
    end)
  end)

  describe("cleanup", function()
    it("removes an existing directory tree", function()
      local parent = temp_dir()
      local staging = fs.make_staging(parent)
      local nested = vim.fs.joinpath(staging, "sub")
      vim.fn.mkdir(nested, "p")
      vim.fn.writefile({ "data" }, vim.fs.joinpath(nested, "file.txt"))

      fs.cleanup(staging)

      assert.is_nil(vim.uv.fs_stat(staging))
    end)

    it("does not throw when the path is nil", function()
      fs.cleanup(nil)
    end)

    it("does not throw when the path does not exist", function()
      fs.cleanup("/tmp/duke-nonexistent-zzz")
    end)
  end)

  describe("promote", function()
    it("renames the staged directory to the target", function()
      local parent = temp_dir()
      local staging = fs.make_staging(parent)
      vim.fn.writefile({ "generated" }, vim.fs.joinpath(staging, "output.txt"))
      local target = vim.fs.joinpath(parent, "final-project")

      local ok, err = fs.promote(staging, target)

      assert.is_true(ok)
      assert.is_nil(err)
      assert.is_nil(vim.uv.fs_stat(staging))
      assert.is_truthy(vim.uv.fs_stat(target))
      assert.equals("generated", vim.fn.readfile(vim.fs.joinpath(target, "output.txt"))[1])
    end)

    it("rejects promotion when the target already exists", function()
      local parent = temp_dir()
      local staging = fs.make_staging(parent)
      vim.fn.writefile({ "staged" }, vim.fs.joinpath(staging, "file.txt"))
      local target = vim.fs.joinpath(parent, "final-project")
      vim.fn.mkdir(target, "p")
      vim.fn.writefile({ "existing" }, vim.fs.joinpath(target, "sentinel"))

      local ok, err = fs.promote(staging, target)

      assert.is_nil(ok)
      assert.matches("target already exists", err)
      -- target preserved
      assert.equals("existing", vim.fn.readfile(vim.fs.joinpath(target, "sentinel"))[1])
      -- staging still exists (not cleaned up by promote)
      assert.is_truthy(vim.uv.fs_stat(staging))
    end)
  end)
end)
