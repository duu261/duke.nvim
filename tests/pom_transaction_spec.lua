describe("POM transaction", function()
  local directories = {}
  local real_pom_file

  local function temp_dir()
    local directory = vim.fn.tempname()
    vim.fn.mkdir(directory, "p")
    directories[#directories + 1] = directory
    return directory
  end

  local function write_pom(directory, name, value)
    local path = vim.fs.joinpath(directory, name)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile({ value }, path)
    return path
  end

  local function load_transaction(boundary)
    package.loaded["duke.pom_transaction"] = nil
    package.loaded["duke.pom_file"] = boundary or real_pom_file
    return require("duke.pom_transaction")
  end

  before_each(function()
    package.loaded["duke.pom_file"] = nil
    real_pom_file = require("duke.pom_file")
  end)

  after_each(function()
    package.loaded["duke.pom_transaction"] = nil
    package.loaded["duke.pom_file"] = nil
    for _, directory in ipairs(directories) do
      vim.fn.delete(directory, "rf")
    end
    directories = {}
  end)

  it("applies parent first and returns one success receipt", function()
    local root = temp_dir()
    local parent = write_pom(root, "pom.xml", "parent-before")
    local child = write_pom(root, "child/pom.xml", "child-before")
    local transaction = load_transaction()
    local count = 0
    local result

    transaction.apply(root, {
      { pom_path = child, before = { "child-before" }, after = { "child-after" }, changes = {} },
      { pom_path = parent, before = { "parent-before" }, after = { "parent-after" }, changes = {} },
    }, function(err, value)
      assert.is_nil(err)
      count = count + 1
      result = value
    end)

    assert.is_true(vim.wait(100, function()
      return result ~= nil
    end))
    assert.equals(1, count)
    assert.is_true(result.ok)
    assert.equals("complete", result.phase)
    assert.equals(root, result.root)
    assert.same({ parent, child }, result.changed_files)
    assert.same({}, result.modified_buffers)
    assert.same({ "parent-after" }, vim.fn.readfile(parent))
    assert.same({ "child-after" }, vim.fn.readfile(child))
  end)

  it("aborts preflight without writes", function()
    local root = temp_dir()
    local parent = write_pom(root, "pom.xml", "current")
    local transaction = load_transaction()
    local result

    transaction.apply(root, {
      { pom_path = parent, before = { "stale" }, after = { "after" }, changes = {} },
    }, function(_, value)
      result = value
    end)

    assert.is_true(vim.wait(100, function()
      return result ~= nil
    end))
    assert.is_false(result.ok)
    assert.equals("preflight", result.phase)
    assert.same({ "current" }, vim.fn.readfile(parent))
  end)

  it("rolls back an earlier write after a later failure", function()
    local root = temp_dir()
    local parent = write_pom(root, "pom.xml", "parent-before")
    local child = write_pom(root, "child/pom.xml", "child-before")
    local calls = 0
    local boundary = vim.tbl_extend("force", {}, real_pom_file)
    boundary.replace = function(snapshot, lines)
      calls = calls + 1
      if calls == 2 then
        return nil, "injected failure"
      end
      return real_pom_file.replace(snapshot, lines)
    end
    local transaction = load_transaction(boundary)
    local result

    transaction.apply(root, {
      { pom_path = parent, before = { "parent-before" }, after = { "parent-after" }, changes = {} },
      { pom_path = child, before = { "child-before" }, after = { "child-after" }, changes = {} },
    }, function(_, value)
      result = value
    end)

    assert.is_true(vim.wait(100, function()
      return result ~= nil
    end))
    assert.is_false(result.ok)
    assert.equals("rollback", result.phase)
    assert.equals(root, result.root)
    assert.same({ parent }, result.applied)
    assert.same({ parent }, result.restored)
    assert.same({ parent }, result.rolled_back)
    assert.equals("injected failure", result.message)
    assert.same({ "parent-before" }, vim.fn.readfile(parent))
    assert.same({ "child-before" }, vim.fn.readfile(child))
  end)

  it("preserves concurrent content during rollback conflict", function()
    local root = temp_dir()
    local parent = write_pom(root, "pom.xml", "parent-before")
    local child = write_pom(root, "child/pom.xml", "child-before")
    local calls = 0
    local boundary = vim.tbl_extend("force", {}, real_pom_file)
    boundary.replace = function(snapshot, lines)
      calls = calls + 1
      if calls == 2 then
        vim.fn.writefile({ "user concurrent contents" }, parent)
        return nil, "injected failure"
      end
      return real_pom_file.replace(snapshot, lines)
    end
    local transaction = load_transaction(boundary)
    local result

    transaction.apply(root, {
      { pom_path = parent, before = { "parent-before" }, after = { "parent-after" }, changes = {} },
      { pom_path = child, before = { "child-before" }, after = { "child-after" }, changes = {} },
    }, function(_, value)
      result = value
    end)

    assert.is_true(vim.wait(100, function()
      return result ~= nil
    end))
    assert.equals("rollback_conflict", result.phase)
    assert.same({ parent }, result.applied)
    assert.same({}, result.restored)
    assert.same({ parent }, result.conflicted)
    assert.equals("injected failure", result.message)
    assert.equals("user concurrent contents", vim.fn.readfile(parent)[1])
  end)
end)
