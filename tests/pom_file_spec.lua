describe("POM file boundary", function()
  local pom_file = require("duke.pom_file")
  local temporary_directories = {}
  local buffers = {}

  local function temp_pom(lines)
    local directory = vim.fn.tempname()
    vim.fn.mkdir(directory, "p")
    temporary_directories[#temporary_directories + 1] = directory
    local path = vim.fs.joinpath(directory, "pom.xml")
    vim.fn.writefile(lines, path)
    return path
  end

  local function open(path)
    local buffer = vim.fn.bufadd(path)
    vim.fn.bufload(buffer)
    buffers[#buffers + 1] = buffer
    return buffer
  end

  local function original_lines()
    return {
      '<?xml version="1.0" encoding="UTF-8"?>',
      "<project>",
      "  <modelVersion>4.0.0</modelVersion>",
      "  <artifactId>demo</artifactId>",
      "  <version>1.0.0</version>",
      "</project>",
    }
  end

  local function edited_lines()
    local lines = original_lines()
    lines[5] = "  <version>2.0.0</version>"
    return lines
  end

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, "duke_pom_file_spec")
    for _, buffer in ipairs(buffers) do
      pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    end
    buffers = {}
    for _, directory in ipairs(temporary_directories) do
      vim.fn.delete(directory, "rf")
    end
    temporary_directories = {}
  end)

  it("saves a buffered edit without running write autocommands", function()
    local path = temp_pom(original_lines())
    local buffer = open(path)
    local fired = false
    local group = vim.api.nvim_create_augroup("duke_pom_file_spec", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePre", {
      group = group,
      buffer = buffer,
      callback = function()
        fired = true
        vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "REFORMATTED BY A FORMATTER" })
      end,
    })

    local saved, err = pom_file.save(path, edited_lines(), buffer, false)

    assert.is_nil(err)
    assert.is_true(saved)
    assert.is_false(fired)
    assert.same(edited_lines(), vim.fn.readfile(path))
    assert.same(edited_lines(), vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
    assert.is_false(vim.bo[buffer].modified)
  end)

  it("leaves a modified buffer unsaved and untouched on disk", function()
    local path = temp_pom(original_lines())
    local buffer = open(path)

    local saved, err = pom_file.save(path, edited_lines(), buffer, true)

    assert.is_nil(err)
    assert.is_false(saved)
    assert.same(original_lines(), vim.fn.readfile(path))
  end)

  it("writes through the filesystem when no buffer holds the POM", function()
    local path = temp_pom(original_lines())

    local saved, err = pom_file.save(path, edited_lines(), nil, nil)

    assert.is_nil(err)
    assert.is_true(saved)
    assert.same(edited_lines(), vim.fn.readfile(path))
  end)

  it("snapshots and compare-replaces loaded modified buffers", function()
    local path = temp_pom(original_lines())
    local buffer = open(path)
    vim.api.nvim_buf_set_lines(buffer, 4, 5, false, { "  <version>1.1.0</version>" })
    local before = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)

    local snapshot = assert(pom_file.snapshot(path))
    assert.equals(path, snapshot.path)
    assert.same(before, snapshot.lines)
    assert.equals(buffer, snapshot.buffer)
    assert.is_true(snapshot.modified)

    local saved, err = pom_file.replace(snapshot, edited_lines())
    assert.is_nil(err)
    assert.is_false(saved)
    assert.same(edited_lines(), vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
    assert.same(original_lines(), vim.fn.readfile(path))
  end)

  it("rejects stale snapshots before writing", function()
    local path = temp_pom(original_lines())
    local snapshot = assert(pom_file.snapshot(path))
    vim.fn.writefile({ "concurrent" }, path)

    local saved, err = pom_file.replace(snapshot, edited_lines())

    assert.is_nil(saved)
    assert.matches("stale", err)
    assert.same({ "concurrent" }, vim.fn.readfile(path))
  end)

  it("preserves a concurrent disk write before atomic rename", function()
    local path = temp_pom(original_lines())
    local snapshot = assert(pom_file.snapshot(path))
    local original_writefile = vim.fn.writefile
    vim.fn.writefile = function(lines, target)
      local result = original_writefile(lines, target)
      if target ~= path then
        original_writefile({ "concurrent during temporary write" }, path)
      end
      return result
    end

    local saved, err = pom_file.replace(snapshot, edited_lines())
    vim.fn.writefile = original_writefile

    assert.is_nil(saved)
    assert.matches("stale", err)
    assert.same({ "concurrent during temporary write" }, vim.fn.readfile(path))
  end)

  it("restores buffer lines when a clean-buffer save fails", function()
    local path = temp_pom(original_lines())
    local buffer = open(path)
    local snapshot = assert(pom_file.snapshot(path))
    local original_save = pom_file.save
    pom_file.save = function(_, lines)
      vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
      return nil, "injected save failure"
    end

    local saved, err = pom_file.replace(snapshot, edited_lines())
    pom_file.save = original_save

    assert.is_nil(saved)
    assert.matches("injected", err)
    assert.same(original_lines(), vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
    assert.same(original_lines(), vim.fn.readfile(path))
    assert.is_true(vim.bo[buffer].modified)
  end)
end)
