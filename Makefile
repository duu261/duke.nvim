PLENARY_DIR ?= deps/plenary.nvim
NVIM ?= nvim

test: $(PLENARY_DIR)
	NVIM_LOG_FILE=/tmp/duke-nvim-test.log $(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"

lint:
	stylua --check lua/ plugin/ tests/
	luacheck lua/ plugin/ tests/

format:
	stylua lua/ plugin/ tests/

$(PLENARY_DIR):
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $(PLENARY_DIR)

.PHONY: test lint format
