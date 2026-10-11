-- Patch for refactoring.nvim's inline function: it plugs in the Kotlin inliner
-- (`refactoring-kotlin.kotlin`) and fixes the layout upstream leaves, for
-- Kotlin and, with `fix_inline_func_layout`, for every other language too.
-- Installed by `require("refactoring-kotlin").setup()`.
local M = {}

-- Re-indents rows [first_row, end_row) (0-based) with the buffer's indenter (`=`),
-- or, without 'indentexpr', with the indent of `indent_row`.
local function reindent(buf, first_row, end_row, indent_row)
  vim.api.nvim_buf_call(buf, function()
    if vim.bo.indentexpr ~= "" then
      local view = vim.fn.winsaveview()
      vim.cmd(("silent keepjumps normal! %dGV%dG="):format(first_row + 1, end_row))
      vim.fn.winrestview(view)
    else
      local indent = vim.api.nvim_buf_get_lines(buf, indent_row, indent_row + 1, true)[1]:match("^%s*")
      local lines = vim.api.nvim_buf_get_lines(buf, first_row, end_row, true)
      vim.api.nvim_buf_set_lines(buf, first_row, end_row, true,
        vim.tbl_map(function(line) return indent .. vim.trim(line) end, lines))
    end
  end)
end

-- After deleting the function at `row`: the blank lines that surrounded it are
-- now adjacent, or trail at the end of the file.
local function collapse_blank_lines(buf, row)
  if row == 0 then return end
  local around = vim.api.nvim_buf_get_lines(buf, row - 1, row + 1, false)
  if #around == 2 and not around[1]:match("%S") and not around[2]:match("%S") then
    vim.api.nvim_buf_set_lines(buf, row, row + 1, true, {})
  end
  local count = vim.api.nvim_buf_line_count(buf)
  if row >= count - 1 then
    local last = count
    while last > 1 and not vim.api.nvim_buf_get_lines(buf, last - 1, last, true)[1]:match("%S") do
      last = last - 1
    end
    vim.api.nvim_buf_set_lines(buf, last, count, true, {})
  end
end

local function without_blank_lines(lines)
  return vim.tbl_filter(function(line) return line:match("%S") ~= nil end, lines)
end

-- Wraps `apply_text_edits` for inline_func's edits only:
-- - For Kotlin, the inlined lines come from `refactoring-kotlin.kotlin` (IDE-style
--   argument substitution, calls nested in expressions). If a call can't be
--   inlined, it's left as is and the function is kept.
-- - Upstream inserts the inlined code badly indented (it reads the call's indent
--   from an empty line range, never indents the generated `val` lines and
--   flattens nested blocks) and leaves blank lines for an empty body or argument
--   list: drop those blank lines (blank lines inside the inlined body go too)
--   and re-indent the inserted lines.
-- - Deleting the function leaves two blank lines where it was (or trailing ones
--   at the end of the file): collapse them.
local function has_kotlin(text_edits_by_buf)
  for buf in pairs(text_edits_by_buf) do
    if vim.treesitter.language.get_lang(vim.bo[buf].filetype) == "kotlin" then return true end
  end
  return false
end

local options = { all_languages = true }
local installed = false

-- `opts.all_languages`: also fix the layout for languages other than Kotlin.
-- Can be called again to change the options; the patch is installed once.
function M.setup(opts)
  options = vim.tbl_extend("force", options, opts or {})
  if installed then return end
  installed = true

  local utils = require("refactoring.utils")
  local apply_text_edits = utils.apply_text_edits
  local ns = vim.api.nvim_create_namespace("refactoring-inline-func")

  utils.apply_text_edits = function(text_edits_by_buf)
    local caller = debug.getinfo(2, "S").source
    if not caller:find("refactor/inline_func.lua", 1, true) then
      return apply_text_edits(text_edits_by_buf)
    end
    if not options.all_languages and not has_kotlin(text_edits_by_buf) then
      return apply_text_edits(text_edits_by_buf)
    end

    -- Kotlin: how to inline each call, worked out before any edit (one of them
    -- deletes the function). `false` for the calls that can't be inlined.
    local plans, reasons = require("refactoring-kotlin.kotlin").plan(text_edits_by_buf)
    local skipped = plans and #vim.tbl_filter(function(plan) return plan == false end, vim.tbl_values(plans)) or 0

    for buf, text_edits in pairs(text_edits_by_buf) do
      -- Edits are anchored to extmarks so they can be applied top-down (the
      -- evaluation order, for code inserted before a statement) while earlier
      -- ones add or remove lines.
      local function mark(row, col, end_row, end_col)
        -- Not strict: the deleted function's range may end past the last line.
        return vim.api.nvim_buf_set_extmark(buf, ns, row, col, { end_row = end_row, end_col = end_col, strict = false })
      end
      local function position(id)
        local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })
        return pos[1], pos[2], pos[3].end_row, pos[3].end_col
      end
      table.sort(text_edits, function(a, b) return a.range < b.range end)
      local marks, statement_marks = {}, {}
      for i, text_edit in ipairs(text_edits) do
        marks[i] = mark(text_edit.range:to_extmark())
        local plan = plans and plans[text_edit]
        if plan and plan.pre then statement_marks[i] = mark(plan.statement[1], plan.statement[2]) end
      end

      for i, text_edit in ipairs(text_edits) do
        local srow, scol, erow, ecol = position(marks[i])
        local plan = plans and plans[text_edit]
        if #text_edit.lines == 0 then
          -- The function itself: keep it if some call is still using it.
          if skipped == 0 then
            -- Upstream starts at the function, after its indent: delete whole lines
            -- (otherwise the indent joins the next line, e.g. a class's `}`).
            if not vim.api.nvim_buf_get_lines(buf, srow, srow + 1, true)[1]:sub(1, scol):match("%S") then scol = 0 end
            vim.api.nvim_buf_set_text(buf, srow, scol, erow, ecol, {})
            collapse_blank_lines(buf, srow)
          end
        elseif plan ~= false then
          local lines = plan and plan.lines or text_edit.lines
          if #lines > 1 then lines = without_blank_lines(lines) end
          vim.api.nvim_buf_set_text(buf, srow, scol, erow, ecol, lines)
          if #lines == 0 and not vim.api.nvim_buf_get_lines(buf, srow, srow + 1, true)[1]:match("%S") then
            -- Nothing left of the call (a pure function called as a statement).
            vim.api.nvim_buf_set_lines(buf, srow, srow + 1, true, {})
          elseif #lines > 1 then
            reindent(buf, srow, srow + #lines, srow)
          end

          -- Nested call: its body goes before the enclosing statement.
          local pre = plan and plan.pre and without_blank_lines(plan.pre) or {}
          if #pre > 0 then
            local row = position(statement_marks[i])
            vim.api.nvim_buf_set_lines(buf, row, row, true, pre)
            reindent(buf, row, row + #pre, row + #pre)
          end
        end
      end
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end

    if skipped > 0 then
      vim.notify(
        -- One line: a multi-line message would wait for <Enter>.
        ("%d call(s) not inlined, so the function was kept: %s"):format(
          skipped,
          table.concat(vim.fn.uniq(vim.fn.sort(reasons)), "; ")
        ),
        vim.log.levels.WARN,
        { title = "refactoring.nvim" }
      )
    end
  end
end

return M
