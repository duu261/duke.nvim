local M = {}

local Model = {}
Model.__index = Model

local function refresh(self)
  self.state.derived.project_dir =
    vim.fs.joinpath(self.state.values.destination or "", self.state.values.artifact_id or "")
  self.state.errors =
    require("duke.creation.schema").validate(self.state.kind, self.config, self.state)
end

local function field_exists(self, key)
  for _, field in
    ipairs(require("duke.creation.schema").fields(self.state.kind, self.config, self.state))
  do
    if field.id == key then
      return true
    end
  end
  return false
end

function Model:snapshot()
  return vim.deepcopy(self.state)
end

function Model:set(key, value)
  if self.state.closed then
    return nil, "creation is closed"
  end
  if self.state.busy then
    return nil, "creation is busy"
  end
  if not field_exists(self, key) then
    return nil, "unknown creation field: " .. tostring(key)
  end
  self.state.values[key] = vim.deepcopy(value)
  if key == "package_name" then
    self.package_explicit = true
  elseif (key == "group_id" or key == "artifact_id") and not self.package_explicit then
    self.state.values.package_name =
      require("duke.maven").package_name(self.state.values.group_id, self.state.values.artifact_id)
  end
  self.state.dirty = true
  refresh(self)
  return true
end

function Model:switch(kind)
  local schema = require("duke.creation.schema")
  if not schema.valid_kind(kind) then
    return nil, "unknown project generator: " .. tostring(kind)
  end
  if self.state.closed then
    return nil, "creation is closed"
  end
  if self.state.busy then
    return nil, "creation is busy"
  end
  if kind == self.state.kind then
    return true
  end
  local shared = {}
  for _, key in ipairs({
    "destination",
    "group_id",
    "artifact_id",
    "package_name",
    "java_version",
  }) do
    shared[key] = vim.deepcopy(self.state.values[key])
  end
  local values = assert(schema.defaults(kind, self.config, self.context))
  for key, value in pairs(shared) do
    values[key] = value
  end
  self.generation = self.generation + 1
  self.active_tokens = {}
  self.state.kind = kind
  self.state.values = values
  self.state.async = {
    runtimes = { state = "idle" },
    metadata = { state = "idle" },
    catalog = { state = "idle" },
  }
  self.state.dirty = true
  self.state.banner = nil
  refresh(self)
  return true
end

function Model:begin_async(key)
  if self.state.closed then
    return nil
  end
  self.generation = self.generation + 1
  local token = { id = self.generation, key = key, kind = self.state.kind }
  self.active_tokens[key] = token.id
  self.state.async[key] = { state = "loading" }
  return token
end

local function accepts(self, token)
  return type(token) == "table"
    and not self.state.closed
    and token.kind == self.state.kind
    and self.active_tokens[token.key] == token.id
end

function Model:resolve_async(token, patch)
  if not accepts(self, token) then
    return false
  end
  for key, value in pairs(patch or {}) do
    self.state.derived[key] = vim.deepcopy(value)
  end
  self.state.async[token.key] = { state = "ready" }
  self.active_tokens[token.key] = nil
  refresh(self)
  return true
end

function Model:reject_async(token, message)
  if not accepts(self, token) then
    return false
  end
  self.state.async[token.key] = { state = "error", message = tostring(message) }
  self.state.banner = tostring(message)
  self.active_tokens[token.key] = nil
  refresh(self)
  return true
end

function Model:set_busy(value)
  if self.state.closed then
    return false
  end
  self.state.busy = value == true
  return true
end

function Model:request()
  if self.state.closed or self.state.busy then
    return nil
  end
  return require("duke.creation.schema").request(self.state.kind, self.config, self.state)
end

function Model:close()
  if self.state.closed then
    return false
  end
  self.generation = self.generation + 1
  self.active_tokens = {}
  self.state.closed = true
  return true
end

function M.new(config, opts)
  opts = opts or {}
  local kind = opts.kind or "maven"
  local schema = require("duke.creation.schema")
  if not schema.valid_kind(kind) then
    error("unknown project generator: " .. tostring(kind))
  end
  local context = { cwd = opts.cwd or vim.fn.getcwd() }
  local self = setmetatable({
    config = config,
    context = context,
    generation = 0,
    active_tokens = {},
    package_explicit = false,
    state = {
      kind = kind,
      values = assert(schema.defaults(kind, config, context)),
      derived = {},
      errors = {},
      async = {
        runtimes = { state = "idle" },
        metadata = { state = "idle" },
        catalog = { state = "idle" },
      },
      busy = false,
      closed = false,
      dirty = false,
      banner = nil,
    },
  }, Model)
  refresh(self)
  return self
end

return M
