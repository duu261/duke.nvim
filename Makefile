PLENARY_DIR ?= deps/plenary.nvim
NVIM ?= nvim

test: $(PLENARY_DIR)
	NVIM_LOG_FILE=/tmp/duke-nvim-test.log $(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"

test-file: $(PLENARY_DIR)
	@test -n "$(FILE)" || { echo "usage: make test-file FILE=tests/example_spec.lua" >&2; exit 2; }
	@test -f "$(FILE)" || { echo "test file not found: $(FILE)" >&2; exit 2; }
	NVIM_LOG_FILE=/tmp/duke-nvim-test.log $(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedFile $(FILE)"

lint:
	stylua --check lua/ plugin/ tests/
	luacheck lua/ plugin/ tests/

format:
	stylua lua/ plugin/ tests/

$(PLENARY_DIR):
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $(PLENARY_DIR)

.PHONY: test test-file lint format
