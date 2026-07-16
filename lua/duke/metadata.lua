---Public API facade. Delegates to initializr_cache (transport) and initializr_model (data).
---@see duke.initializr_cache
---@see duke.initializr_model

local cache = require("duke.initializr_cache")
local model = require("duke.initializr_model")

return {
  -- Transport
  http_get = cache.http_get,
  fetch_cached = cache.fetch_cached,
  cache_dir = cache.cache_dir,
  cache_path = cache.cache_path,
  clear_cache = cache.clear_cache,

  -- Model
  is_client = model.is_client,
  is_catalog = model.is_catalog,
  flatten_dependencies = model.flatten_dependencies,
  default = model.default,
  values = model.values,
  project_types = model.project_types,
  resolve = model.resolve,
  is_direct = model.is_direct,
}
