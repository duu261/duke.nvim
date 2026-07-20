describe("build change events", function()
  before_each(function()
    package.loaded["duke.events"] = nil
    package.loaded["duke.build"] = nil
    package.loaded["duke.log"] = nil
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, "DukeEventsSpec")
    package.loaded["duke.events"] = nil
    package.loaded["duke.build"] = nil
    package.loaded["duke.log"] = nil
  end)

  it("emits one Maven event with aggregate reactor details", function()
    package.loaded["duke.build"] = {
      maven = function(path, command)
        assert.equals("/repo/pom.xml", path)
        assert.equals("mvn", command)
        return { root = "/repo", build_file = path }
      end,
    }
    local received = {}
    local group = vim.api.nvim_create_augroup("DukeEventsSpec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "DukeBuildChanged",
      callback = function(args)
        received[#received + 1] = args.data
      end,
    })

    require("duke.events").build_changed("/repo/pom.xml", "repair_reactor", {
      build_files = { "/repo/pom.xml", "/repo/app/pom.xml" },
      coordinates = { "com.acme:library" },
      changes = { { kind = "upgrade" } },
      saved = true,
    })

    assert.equals(1, #received)
    assert.equals("maven", received[1].kind)
    assert.equals("/repo", received[1].root)
    assert.equals("repair_reactor", received[1].operation)
    assert.equals(2, #received[1].build_files)
  end)

  it("contains build resolution and autocmd failures", function()
    local logged = {}
    package.loaded["duke.log"] = {
      add = function(level, message)
        logged[#logged + 1] = level .. ":" .. message
      end,
    }
    package.loaded["duke.build"] = {
      maven = function()
        error("broken build resolver")
      end,
    }

    assert.has_no.errors(function()
      require("duke.events").build_changed("/repo/pom.xml", "repair_reactor")
    end)
    assert.matches("broken build resolver", table.concat(logged, "\n"))
  end)
end)
