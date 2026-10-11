# refactoring-kotlin.nvim

Kotlin support for [refactoring.nvim](https://github.com/ThePrimeagen/refactoring.nvim),
which doesn't support Kotlin itself. [kotlin-lsp](https://github.com/Kotlin/kotlin-lsp)
only supports rename, so this fills the gap:

- **Extract function** and **extract variable**.
- **Inline variable**.
- **Inline function**, IDE-style: arguments are substituted into the body where
  that keeps the behaviour. It handles named and default arguments, calls nested
  in expressions, method calls (`obj.f()`, `this`, members), extension functions
  and name clashes.

> [!NOTE]
> **Documentation:** what's supported and what isn't, with examples, is in the
> [refactoring-kotlin.nvim-tests](https://github.com/archinautio/refactoring-kotlin.nvim-tests/blob/main/docs/README.md)
> repo, next to the tests its examples come from.

## Requirements

- Neovim 0.12.5+ and refactoring.nvim (plus [async.nvim](https://github.com/lewis6991/async.nvim)
  on Neovim 0.12).
- The Kotlin Tree-sitter parser (e.g. `:TSInstall kotlin` with nvim-treesitter).
- For inline variable and inline function: kotlin-lsp, configured and attached
  to Kotlin buffers (it provides the definitions and references).

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "ThePrimeagen/refactoring.nvim",
  dependencies = {
    "lewis6991/async.nvim",
    "archinautio/refactoring-kotlin.nvim",
  },
  config = function(_, opts)
    require("refactoring").setup(opts)
    require("refactoring-kotlin").setup()
  end,
  keys = {
    -- Operators: `<leader>re` + a motion, or on a visual selection.
    { "<leader>re", function() return require("refactoring").extract_func() end, mode = { "n", "x" }, expr = true, desc = "Extract function" },
    { "<leader>rv", function() return require("refactoring").extract_var() end, mode = { "n", "x" }, expr = true, desc = "Extract variable" },
    { "<leader>ri", function() return require("refactoring").inline_var() end, mode = { "n", "x" }, expr = true, desc = "Inline variable" },
    { "<leader>rI", function() return require("refactoring").inline_func() end, mode = { "n", "x" }, expr = true, desc = "Inline function" },
  },
}
```

The keymaps are only an example: any of refactoring.nvim's keymaps or its
`:Refactor` command work on Kotlin once this plugin is set up.

## Configuration

```lua
require("refactoring-kotlin").setup({
  -- Also fix inline function's layout (indentation and blank lines) for the other
  -- languages refactoring.nvim supports. Kotlin always gets it.
  fix_inline_func_layout = true,
})
```

`setup()` can be called before or after `require("refactoring").setup()`. Your
own Kotlin code generators in refactoring.nvim's configuration, if any, take
precedence.

## How it works and compatibility

- `queries/kotlin/refactor_*.scm` are the Tree-sitter queries refactoring.nvim
  needs, found through 'runtimepath'. They use `;; extends`, so if
  refactoring.nvim ever ships its own Kotlin queries, both are merged.
- `setup()` adds the Kotlin code generators by wrapping
  `require("refactoring.config").get_config()`.
- Inline function is patched by wrapping refactoring.nvim's internal
  `refactoring.utils.apply_text_edits` for the edits of inline function only.
  This depends on refactoring.nvim's internals. The tests run against a pinned
  commit (see the tests repo), so after updating refactoring.nvim, run them or
  pin it to that commit.

## Tests

The test battery lives in a separate repo, so it isn't downloaded when you
install the plugin:
[refactoring-kotlin.nvim-tests](https://github.com/archinautio/refactoring-kotlin.nvim-tests). It runs every
refactor on a Kotlin project in a headless Neovim with kotlin-lsp, compares the
results and compiles them with Gradle.

## License

[MIT](LICENSE)
