describe("Duke log", function()
  before_each(function()
    package.loaded["duke.log"] = nil
  end)

  it("renders multiline details without leaking an editor error", function()
    local log = require("duke.log")
    log.add("ERROR", "Maven failed\nsecond line")

    assert.has_no.errors(log.show)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

    assert.matches("Maven failed$", lines[1])
    assert.equals("second line", lines[2])
    vim.cmd("bwipeout!")
  end)
end)
