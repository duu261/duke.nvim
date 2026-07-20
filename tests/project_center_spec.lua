describe("Java Project Center", function()
  local project_center
  local root
  local original_window
  local original_buffer
  local original_cwd

  before_each(function()
    package.loaded["duke.project_center"] = nil
    package.loaded["duke.workspace"] = nil
    project_center = require("duke.project_center")
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({
      "<project>",
      "  <groupId>com.acme</groupId>",
      "  <artifactId>app</artifactId>",
      "  <version>1.0.0</version>",
      "</project>",
    }, vim.fs.joinpath(root, "pom.xml"))
    original_window = vim.api.nvim_get_current_win()
    original_buffer = vim.api.nvim_get_current_buf()
    original_cwd = vim.fn.getcwd()
  end)

  after_each(function()
    project_center.close()
    if vim.api.nvim_buf_is_valid(original_buffer) then
      vim.bo[original_buffer].modified = false
    end
    vim.cmd.cd(vim.fn.fnameescape(original_cwd))
    vim.fn.delete(root, "rf")
    package.loaded["duke.project_center"] = nil
    package.loaded["duke.workspace"] = nil
  end)

  it("opens local data without stealing focus or changing editor state", function()
    vim.api.nvim_buf_set_lines(original_buffer, 0, -1, false, { "unsaved work" })
    vim.bo[original_buffer].modified = true

    project_center.toggle({ path = root })
    assert.is_true(vim.wait(1000, function()
      local state = project_center.state()
      return state and state.snapshot ~= nil
    end))

    local state = project_center.state()
    assert.equals(original_window, vim.api.nvim_get_current_win())
    assert.equals(original_buffer, vim.api.nvim_get_current_buf())
    assert.equals(original_cwd, vim.fn.getcwd())
    assert.is_true(vim.bo[original_buffer].modified)
    assert.equals("duke-project-center", vim.bo[state.buf].filetype)
    assert.matches(
      "Modules %(1%)",
      table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
    )
    assert.is_table(vim.b[state.buf].duke_project_center_nodes)
    local refresh_mapping = vim.tbl_filter(function(mapping)
      return mapping.lhs == "r" or mapping.lhs == "u"
    end, vim.api.nvim_buf_get_keymap(state.buf, "n"))
    assert.equals(2, #refresh_mapping)

    project_center.toggle({ path = root })
    assert.is_nil(project_center.state())
  end)

  it("ignores completion after the sidebar closes", function()
    local pending
    package.loaded["duke.workspace"] = {
      inspect = function(_, callback)
        pending = callback
      end,
    }
    package.loaded["duke.project_center"] = nil
    project_center = require("duke.project_center")

    project_center.toggle({ path = root })
    project_center.close()
    pending(nil, { root = root, state = "local", modules = {}, diagnostics = {} })

    assert.is_nil(project_center.state())
  end)

  it("renders resolved versions and analysis counts", function()
    package.loaded["duke.workspace"] = {
      inspect = function(_, callback)
        callback(nil, {
          root = root,
          state = "resolved",
          kind = "maven",
          modules = {
            { id = "com.acme:app", build_file = vim.fs.joinpath(root, "pom.xml") },
          },
          dependencies = {
            {
              coordinate = "com.acme:managed",
              module_id = "com.acme:app",
              line = 4,
            },
            {
              coordinate = "com.acme:property",
              module_id = "com.acme:app",
              version = "${lib.version}",
              line = 8,
            },
          },
          configuration = {},
          diagnostics = {},
          analysis = {
            dependencies = {
              {
                coordinate = "com.acme:managed",
                module_id = "com.acme:app",
                version = "2.0.0",
                direct = true,
              },
              {
                coordinate = "com.acme:property",
                module_id = "com.acme:app",
                version = "3.0.0",
                direct = true,
              },
              {
                coordinate = "com.acme:transitive",
                module_id = "com.acme:app",
                version = "4.0.0",
                direct = false,
              },
            },
            findings = { conflicts = {}, drift = {}, duplicates = {}, unknown = {} },
          },
        })
      end,
    }
    package.loaded["duke.project_center"] = nil
    project_center = require("duke.project_center")

    project_center.toggle({ path = root })
    assert.is_true(vim.wait(1000, function()
      local state = project_center.state()
      return state and state.snapshot ~= nil
    end))

    local state = project_center.state()
    local rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
    assert.matches("com.acme:managed  2.0.0 %(managed%)", rendered)
    assert.is_truthy(rendered:find("com.acme:property  ${lib.version} -> 3.0.0", 1, true))
    assert.matches("Resolved nodes %(3%)", rendered)
    assert.matches("Transitive dependencies  1", rendered)
    assert.matches("Conflicts  0", rendered)
    assert.matches("Version drift  0", rendered)
    assert.matches("Duplicate declarations  0", rendered)
  end)

  it("lists every sidebar action in help", function()
    project_center.toggle({ path = root })
    assert.is_true(vim.wait(1000, function()
      local state = project_center.state()
      return state and state.snapshot ~= nil
    end))

    local state = project_center.state()
    vim.api.nvim_set_current_win(state.win)
    vim.api.nvim_feedkeys("?", "x", false)

    local help = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.matches("u     Plan upgrades for the active Maven module", help)
    vim.cmd.close()
  end)
end)
