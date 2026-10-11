# CLAUDE.md

Kotlin support for refactoring.nvim, installed as a Neovim plugin. `README.md`
covers installation, configuration and how it hooks into refactoring.nvim.

## Layout

- `lua/refactoring-kotlin/init.lua`: `setup()`. It adds the Kotlin code
  generators by wrapping `refactoring.config.get_config()` (not by calling
  refactoring.nvim's `setup()`, which would replace the user's configuration)
  and installs the inline function patch.
- `lua/refactoring-kotlin/kotlin.lua`: the Kotlin code generators and the
  IDE-style inline function (`plan`).
- `lua/refactoring-kotlin/inline_func.lua`: the patch to refactoring.nvim's
  internal `refactoring.utils.apply_text_edits`, for inline function only.
- `queries/kotlin/refactor_*.scm`: the Tree-sitter queries refactoring.nvim reads.

Keep this repo minimal: it's what users install. The user documentation
(supported and unsupported cases) lives in the tests repo's `docs/`, linked from
`README.md`.

## Tests

The test battery is a separate repo, `../refactoring-kotlin.nvim-tests`, so that
installing the plugin doesn't download it. It loads this directory through
`PLUGIN_DIR` (default `../refactoring-kotlin.nvim`); there are no git
submodules. After any change here, run `./run.sh` there; it must end in
`ALL PASSED`. Its `CLAUDE.md` has the rules for reviewing expected results and
keeping its `docs/` in sync with them.
