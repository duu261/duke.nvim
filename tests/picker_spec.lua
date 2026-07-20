describe("duke.picker", function()
  local original_select

  before_each(function()
    original_select = vim.ui.select
    package.loaded["duke.picker"] = nil
  end)

  after_each(function()
    vim.ui.select = original_select
    package.loaded["duke.picker"] = nil
  end)

  it("formats dependency state consistently", function()
    local format = require("duke.picker").format_dependency

    assert.equals(
      "com.example:demo  1.0  [installed]",
      format({
        group_id = "com.example",
        artifact_id = "demo",
        version = "1.0",
        installed = true,
      })
    )
    assert.equals(
      "com.example:demo  1.0 -> 2.0",
      format({
        group_id = "com.example",
        artifact_id = "demo",
        version = "1.0",
        latest_version = "2.0",
      })
    )
    assert.equals(
      "com.example:demo  1.0  (managed by parent)",
      format({
        group_id = "com.example",
        artifact_id = "demo",
        version = "1.0",
        managed_by = "parent",
      })
    )
  end)

  it("shows fallback multi-select count in prompt and Done row", function()
    local calls = {}
    vim.ui.select = function(choices, opts, callback)
      calls[#calls + 1] = { choices = choices, prompt = opts.prompt }
      if #calls == 1 then
        callback(choices[2])
      else
        callback(choices[1])
      end
    end

    local selected
    require("duke.picker").select_many({ "first", "second" }, {
      prompt = "Add dependencies",
    }, function(items)
      selected = items
    end)

    assert.equals("Add dependencies  (0 selected)", calls[1].prompt)
    assert.equals("[Done - 0 selected]", calls[1].choices[1].name)
    assert.equals("Add dependencies  (1 selected)", calls[2].prompt)
    assert.equals("[Done - 1 selected]", calls[2].choices[1].name)
    assert.same({ "first" }, selected)
  end)
end)
