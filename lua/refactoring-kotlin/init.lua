-- Kotlin support for refactoring.nvim (https://github.com/ThePrimeagen/refactoring.nvim).
--
--   require("refactoring-kotlin").setup({
--     -- Also fix inline function's layout (indentation, blank lines) for the
--     -- other languages refactoring.nvim supports. Kotlin always gets it.
--     fix_inline_func_layout = true,
--   })
--
-- The Tree-sitter queries in `queries/kotlin/` are found through 'runtimepath';
-- `setup()` adds the Kotlin code generators and patches inline function.
local M = {}

local defaults = {
  fix_inline_func_layout = true,
}

local config_patched = false

-- refactoring.nvim's `setup()` replaces the whole user configuration, so the
-- Kotlin code generators are added when the configuration is read instead:
-- they work whatever the order of the `setup()` calls, and the user's own
-- Kotlin code generators, if any, take precedence.
local function add_code_generation()
  if config_patched then return end
  config_patched = true

  local refactor = {}
  for name, code_generation in pairs(require("refactoring-kotlin.kotlin").code_generation) do
    refactor[name] = { code_generation = code_generation }
  end
  local kotlin = { refactor = refactor }

  local config = require("refactoring.config")
  local get_config = config.get_config
  config.get_config = function(...)
    return vim.tbl_deep_extend("keep", get_config(...), kotlin)
  end
end

---@param opts? { fix_inline_func_layout?: boolean }
function M.setup(opts)
  opts = vim.tbl_extend("force", defaults, opts or {})
  add_code_generation()
  require("refactoring-kotlin.inline_func").setup({ all_languages = opts.fix_inline_func_layout })
end

return M
