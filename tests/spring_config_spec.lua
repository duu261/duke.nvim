describe("Spring configuration discovery", function()
  local spring_config
  local root

  before_each(function()
    package.loaded["duke.spring_config"] = nil
    spring_config = require("duke.spring_config")
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
    package.loaded["duke.spring_config"] = nil
  end)

  local function write(relative, lines)
    local path = vim.fs.joinpath(root, relative)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(lines, path)
    return path
  end

  it("returns file metadata and filename profiles without values", function()
    local main =
      write("src/main/resources/application.properties", { "secret.token=do-not-return" })
    local dev = write("src/main/resources/application-dev.yml", { "secret:", "  token: hidden" })
    local test = write("src/test/resources/application-test.yaml", { "server:", "  port: 0" })

    local result = spring_config.inspect({ root = root })

    assert.same({
      { format = "properties", path = main, profile = nil, scope = "main" },
      { format = "yaml", path = dev, profile = "dev", scope = "main" },
      { format = "yaml", path = test, profile = "test", scope = "test" },
    }, result.files)
    assert.equals(1, #result.diagnostics)
    assert.matches("mixed", result.diagnostics[1].message)
    assert.is_nil(vim.tbl_get(result, "files", 1, "values"))
    assert.is_nil(vim.inspect(result):find("do%-not%-return"))
  end)

  it("ignores unrelated resource files", function()
    write("src/main/resources/banner.txt", { "hello" })
    write("src/main/resources/application-dev.json", { "{}" })

    local result = spring_config.inspect({ root = root })

    assert.same({}, result.files)
    assert.same({}, result.diagnostics)
  end)
end)
