-- Kotlin support for refactoring.nvim, which doesn't support Kotlin upstream.
-- Used by `lua/refactoring-kotlin/init.lua` and `lua/refactoring-kotlin/inline_func.lua`;
-- the Tree-sitter queries are in `queries/kotlin/refactor_*.scm`.
--
-- `M.code_generation`: the code generators refactoring.nvim needs for each refactor.
--
-- `M.plan`: IDE-style "inline function". refactoring.nvim's inline_func declares
-- every parameter as a variable (`val price = base`) and copies the body as is.
-- That clashes in Kotlin (no redeclarations) and reads worse than what IntelliJ
-- produces. This module regenerates the lines for each inlined call instead:
--   - Arguments are substituted into the body when that keeps the behaviour:
--     simple arguments (identifiers, literals, `this`) always; any other
--     argument only when it's the only non-simple one, it's used once, the
--     function has no statements besides its return value, and the use isn't
--     conditional (`&&`, `?:`, `if`, lambdas...).
--   - Otherwise the parameter is declared with `val`; an unused argument with
--     possible side effects is kept as a statement.
--   - Omitted arguments take the parameter's default value; named arguments are
--     matched by name; a trailing lambda is the last argument. A lambda argument
--     is always declared, with its parameter's type (needed to infer `it`).
--   - Variables the inlined code introduces are renamed (`price1`) when the
--     name is already used in the calling function.
--   - A call nested in an expression (`println(f(x))`, `f(x) + 1`, a lambda's
--     result...) is replaced by the return value, and the rest of the body is
--     inserted before the enclosing statement. When that would change when the
--     body runs (the call is under `&&`, `?:`, `if`...), or isn't possible (an
--     expression body, a one-line lambda), the call isn't inlined and the
--     function is kept.
--   - Method calls (`obj.f(x)`): the receiver is bound like an argument, `this`
--     becomes it and the class members the body uses become `obj.member`
--     (extension functions: only `this`). Calls inside the class (`f(x)`,
--     `this.f(x)`) keep the body as is. Safe calls (`obj?.f()`) and bodies
--     using private/protected members (from outside) aren't inlined.
--   - Parentheses are added only where operator precedence needs them.
-- Unsupported functions (a single `return` that isn't the last statement, a
-- default value that uses another parameter) fall back to upstream's lines;
-- upstream itself refuses functions with several `return`s.
-- What's supported and what isn't, with examples: `docs/` in the tests repo (see README.md).
local ts = vim.treesitter

local M = {}

-- Code generators -------------------------------------------------------------

local UNKNOWN_TYPE = "P" -- placeholder when the type can't be read from the source (Java uses the same)

local function identifiers(vars)
  return vim
    .iter(vars)
    :map(function(v)
      return v.identifier
    end)
    :join ", "
end

local function function_declaration(opts)
  local args = vim
    .iter(opts.args)
    :map(function(v)
      return ("%s: %s"):format(v.identifier, v.type or UNKNOWN_TYPE)
    end)
    :join ", "
  local return_type = #opts.return_values == 0 and "" or (": %s"):format(opts.return_values[1].type or UNKNOWN_TYPE)
  return ("private fun %s(%s)%s {\n%s\n}"):format(opts.name, args, return_type, opts.body)
end

local function function_call(opts)
  local call = ("%s(%s)"):format(opts.name, identifiers(opts.args))
  if #opts.return_values == 0 then return call end
  if #opts.return_values > 1 then
    vim.notify(
      "The extracted function requires multiple return values; only the first one is returned",
      vim.log.levels.WARN,
      { title = "refactoring.nvim" }
    )
  end
  return ("val %s = %s"):format(opts.return_values[1].identifier, call)
end

local function return_statement(opts)
  return ("\n\nreturn %s"):format(opts.return_values[1].identifier)
end

-- Inline function, upstream style: each parameter becomes `val param = arg`.
-- Only a fallback: `M.plan` regenerates the lines, unless the function isn't
-- supported there. `left` are names (params or the call's result variable),
-- `right` the values (call args or the function's return expression). Named
-- args (`name = value`) are matched by name; a missing argument is left as a
-- compile error.
local function assignment(opts)
  local named, positional = {}, {}
  for _, value in ipairs(opts.right) do
    local name, named_value = value:match "^([%a_][%w_]*)%s*=%s*([^=].*)$"
    if name then
      named[name] = named_value
    else
      table.insert(positional, value)
    end
  end

  return vim
    .iter(ipairs(opts.left))
    :map(function(i, name)
      local value = named[name] or positional[i] or "/* missing argument */"
      -- `f(a = a)`: the variable already exists (same skip upstream does for `f(a)`).
      if value == name then return nil end
      return ("val %s = %s"):format(name, value)
    end)
    :join "\n"
end

local function group_expression(opts)
  return ("(%s)"):format(opts.expression)
end

local function variable_declaration(opts)
  return ("val %s = %s"):format(opts.name, opts.value)
end

-- By refactor, in the shape of refactoring.nvim's `refactor.<name>.code_generation`.
M.code_generation = {
  extract_func = {
    function_declaration = { kotlin = function_declaration },
    function_call = { kotlin = function_call },
    return_statement = { kotlin = return_statement },
  },
  extract_var = {
    variable_declaration = { kotlin = variable_declaration },
  },
  inline_var = {
    group_expression = { kotlin = group_expression },
  },
  inline_func = {
    assignment = { kotlin = assignment },
  },
}

-- Inline function -------------------------------------------------------------

-- Arguments that can be substituted wherever they're used (no side effects, cheap).
local SIMPLE = {
  simple_identifier = true,
  null_literal = true,
  boolean_literal = true,
  character_literal = true,
  integer_literal = true,
  long_literal = true,
  hex_literal = true,
  bin_literal = true,
  unsigned_literal = true,
  real_literal = true,
  this_expression = true,
}

-- Expressions that never need parentheses when substituted.
local ATOMIC = vim.tbl_extend("force", SIMPLE, {
  string_literal = true,
  call_expression = true,
  navigation_expression = true,
  indexing_expression = true,
  parenthesized_expression = true,
  collection_literal = true,
})

-- Positions where any expression can go without parentheses.
local NO_PARENS_PARENT = {
  value_argument = true,
  parenthesized_expression = true,
  property_declaration = true,
  jump_expression = true,
  statements = true,
  interpolated_expression = true,
  function_body = true,
  assignment = true,
}

-- Code that may not run, or may run several times, compared to the call.
local CONDITIONAL = {
  conjunction_expression = true,
  disjunction_expression = true,
  elvis_expression = true,
  if_expression = true,
  when_expression = true,
  try_expression = true,
  lambda_literal = true,
}

-- Kotlin operator precedence (higher binds tighter).
local PRECEDENCE = {
  postfix_expression = 13,
  prefix_expression = 12,
  as_expression = 11,
  multiplicative_expression = 10,
  additive_expression = 9,
  range_expression = 8,
  infix_expression = 7,
  elvis_expression = 6,
  check_expression = 5,
  comparison_expression = 4,
  equality_expression = 3,
  conjunction_expression = 2,
  disjunction_expression = 1,
}

-- Whether an expression of type `inner` needs parentheses where a node with
-- parent `outer` was (`is_left`: it was the left operand; operators are
-- left-associative).
local function needs_parens(inner, outer, is_left)
  if ATOMIC[inner] or NO_PARENS_PARENT[outer] then return false end
  local inner_precedence, outer_precedence = PRECEDENCE[inner], PRECEDENCE[outer]
  if not inner_precedence or not outer_precedence then return true end
  return inner_precedence < outer_precedence or (inner_precedence == outer_precedence and not is_left)
end

local function is_left_operand(node)
  local first = node:parent():named_child(0)
  return first ~= nil and first:id() == node:id()
end

local function text(node, buf)
  return ts.get_node_text(node, buf)
end

local function is_simple(node)
  if SIMPLE[node:type()] then return true end
  -- A string without templates.
  if node:type() == "string_literal" then
    for child in node:iter_children() do
      if child:named() and child:type() ~= "string_content" and child:type() ~= "escape_sequence" then return false end
    end
    return true
  end
  return false
end

-- Text to splice into a string template for a literal argument (`"$x"` with
-- `x = "a"` or `x = 1` becomes `"a"` or `"1"`), or nil.
local function template_text(node, buf)
  local value = text(node, buf)
  if node:type() == "string_literal" and is_simple(node) and not value:match '^"""' then return value:sub(2, -2) end
  if node:type() == "integer_literal" or node:type() == "boolean_literal" then return value end
end

local function contains_call(node)
  if node:type() == "call_expression" then return true end
  for child in node:iter_children() do
    if contains_call(child) then return true end
  end
  return false
end

local function walk(node, fn)
  fn(node)
  for child in node:iter_children() do
    walk(child, fn)
  end
end

-- Identifier that refers to a variable (not a member, a named argument label...).
local function is_reference(node)
  if node:type() == "interpolated_identifier" then return true end
  if node:type() ~= "simple_identifier" then return false end
  local parent = node:parent()
  local parent_type = parent and parent:type()
  if
    parent_type == "navigation_suffix"
    or parent_type == "parameter"
    or parent_type == "class_parameter"
    or parent_type == "function_declaration"
    or parent_type == "identifier"
  then
    return false
  end
  -- `f(name = value)`
  local next = node:next_sibling()
  if parent_type == "value_argument" and next and next:type() == "=" then return false end
  return true
end

-- Text between two nodes plus the places (`spots`) where names in `names`
-- (name -> "param" | "local" | "member") and `this` occur, as byte offsets
-- relative to that text.
local function template(buf, first, last, names, root)
  local srow, scol, sbyte = first:start()
  local erow, ecol = last:end_()
  local tpl = {
    text = table.concat(vim.api.nvim_buf_get_text(buf, srow, scol, erow, ecol, {}), "\n"),
    spots = {},
    has_call = false,
  }
  local _, _, ebyte = last:end_()

  local function add(node)
    local _, _, nstart = node:start()
    local _, _, nend = node:end_()
    if nstart < sbyte or nend > ebyte then return end
    if node:type() == "call_expression" then tpl.has_call = true end
    local name = text(node, buf)
    local kind
    if node:type() == "this_expression" and name == "this" then
      kind = "this"
    elseif node:type() == "simple_identifier" or node:type() == "interpolated_identifier" then
      kind = names[name]
    end
    if not kind then return end
    local parent = node:parent()
    local declaration = parent:type() == "variable_declaration"
    if kind ~= "this" and not declaration and not is_reference(node) then return end

    local conditional = false
    local ancestor = parent
    while ancestor and ancestor:id() ~= root:id() do
      if CONDITIONAL[ancestor:type()] then conditional = true end
      ancestor = ancestor:parent()
    end
    local interpolated = node:type() == "interpolated_identifier"
    table.insert(tpl.spots, {
      -- `$name`: the spot includes the `$`.
      s = nstart - sbyte - (interpolated and 1 or 0),
      e = nend - sbyte,
      name = name,
      kind = kind,
      declaration = declaration,
      interpolated = interpolated,
      parent_type = parent:type(),
      is_left = is_left_operand(node),
      conditional = conditional,
    })
  end

  -- `first` and `last` may be siblings: walk from their common parent.
  walk(first == last and first or first:parent(), add)
  return tpl
end

local function render(tpl, replace)
  local spots = vim.deepcopy(tpl.spots)
  table.sort(spots, function(a, b)
    return a.s > b.s
  end)
  local out = tpl.text
  for _, spot in ipairs(spots) do
    local replacement = replace(spot)
    if replacement then out = out:sub(1, spot.s) .. replacement .. out:sub(spot.e + 1) end
  end
  return out
end

-- The function about to be deleted by inline_func (the only edit without lines),
-- read before any edit is applied. Returns nil when it isn't Kotlin or isn't supported.
function M.deleted_function(text_edits_by_buf)
  local query = ts.query.parse("kotlin", "(function_declaration) @function")
  for buf, text_edits in pairs(text_edits_by_buf) do
    if ts.language.get_lang(vim.bo[buf].filetype) == "kotlin" then
      for _, text_edit in ipairs(text_edits) do
        if #text_edit.lines == 0 then
          local srow, _, erow = text_edit.range:to_extmark()
          local root = ts.get_parser(buf, "kotlin"):parse()[1]:root()
          -- The first one in the range is the deleted function (nested ones come later).
          for _, node in query:iter_captures(root, buf, srow, erow + 1) do
            return M.analyze(buf, node)
          end
        end
      end
    end
  end
end

function M.analyze(buf, fn)
  local params, names = {}, {}
  local body
  for child in fn:iter_children() do
    if child:type() == "function_value_parameters" then
      for param in child:iter_children() do
        if param:type() == "parameter" then
          local name = text(param:named_child(0), buf)
          local declared_type = param:named_child(1)
          table.insert(params, { name = name, declared_type = declared_type and text(declared_type, buf) })
          names[name] = "param"
        elseif param:named() and #params > 0 and param:prev_sibling():type() == "=" then
          params[#params].default = param
        end
      end
    elseif child:type() == "function_body" then
      body = child
    end
  end
  if not body then return end

  -- Statements before the return value, and the return value.
  local statements, ret = {}, nil
  local block = vim.iter(body:iter_children()):find(function(c)
    return c:type() == "statements"
  end)
  if block then
    for statement in block:iter_children() do
      if statement:named() then table.insert(statements, statement) end
    end
    local last = statements[#statements]
    if last and last:type() == "jump_expression" and text(last, buf):match "^return%f[^%w_@]" then
      table.remove(statements)
      ret = last:named_child(0)
    end
  elseif body:named_child_count() == 1 then
    ret = body:named_child(0) -- `= expr`
  end

  -- Any other `return` (not inside a lambda) would leave the caller early.
  for _, statement in ipairs(statements) do
    local early_return = false
    walk(statement, function(node)
      if node:type() == "jump_expression" and text(node, buf):match "^return%f[^@]" then early_return = true end
    end)
    if early_return then return end
  end

  -- Locals declared directly in the body end up in the caller's block.
  local locals = {}
  for _, statement in ipairs(statements) do
    if statement:type() == "property_declaration" then
      local declaration = vim.iter(statement:iter_children()):find(function(c)
        return c:type() == "variable_declaration"
      end)
      if declaration then
        local name = text(declaration:named_child(0), buf)
        locals[name] = true
        names[name] = "local"
      end
    end
  end

  -- Methods: the class members the body can use without `this.` (params and
  -- locals shadow them); `private`/`protected` ones can't be used from outside.
  -- Extension functions only have `this` (the receiver type's members are unknown).
  local receiver_type, private_members = nil, {}
  local function add_member(name_node, declaration)
    local name = text(name_node, buf)
    names[name] = names[name] or "member"
    local modifiers = vim.iter(declaration:iter_children()):find(function(c)
      return c:type() == "modifiers"
    end)
    local visibility = modifiers and text(modifiers, buf) or ""
    if visibility:match "%f[%w]private%f[%W]" or visibility:match "%f[%w]protected%f[%W]" then
      private_members[name] = true
    end
  end
  local class_body = fn:parent()
  if class_body and class_body:type() == "class_body" then
    local class = class_body:parent()
    for member in class_body:iter_children() do
      if member:type() == "property_declaration" then
        local declaration = vim.iter(member:iter_children()):find(function(c)
          return c:type() == "variable_declaration"
        end)
        if declaration then add_member(declaration:named_child(0), member) end
      elseif member:type() == "function_declaration" then
        local name = vim.iter(member:iter_children()):find(function(c)
          return c:type() == "simple_identifier"
        end)
        if name then add_member(name, member) end
      end
    end
    -- `class Shop(val total: Int)`: constructor parameters with `val`/`var` are properties.
    local constructor = vim.iter(class:iter_children()):find(function(c)
      return c:type() == "primary_constructor"
    end)
    if constructor then
      for parameter in constructor:iter_children() do
        local is_property = parameter:type() == "class_parameter"
          and vim.iter(parameter:iter_children()):any(function(c)
            return c:type() == "binding_pattern_kind"
          end)
        if is_property then
          add_member(
            vim.iter(parameter:iter_children()):find(function(c)
              return c:type() == "simple_identifier"
            end),
            parameter
          )
        end
      end
    end
    local class_name = vim.iter(class:iter_children()):find(function(c)
      return c:type() == "type_identifier"
    end)
    receiver_type = class_name and text(class_name, buf) or "receiver"
  else
    local receiver = vim.iter(fn:iter_children()):find(function(c)
      return c:type() == "receiver_type"
    end)
    if receiver then receiver_type = text(receiver, buf):match "([%w_]+)%??$" or "receiver" end
  end

  local function_info = {
    params = params,
    locals = locals,
    receiver_type = receiver_type,
    body = #statements > 0 and template(buf, statements[1], statements[#statements], names, body) or nil,
    ret = ret and template(buf, ret, ret, names, body) or nil,
    -- Whether the return value can replace a nested call without parentheses.
    ret_type = ret and ret:type(),
    ret_param = ret and ret:type() == "simple_identifier" and names[text(ret, buf)] == "param" and text(ret, buf)
      or nil,
  }

  -- Private members used by the body.
  for _, tpl in pairs { body = function_info.body, ret = function_info.ret } do
    for _, spot in ipairs(tpl.spots) do
      if spot.kind == "member" and private_members[spot.name] then function_info.uses_private = true end
    end
  end

  for _, param in ipairs(params) do
    if param.default then
      -- A default that uses another parameter would need substituting too.
      local default_tpl = template(buf, param.default, param.default, names, param.default)
      if #default_tpl.spots > 0 then return end
      param.default = {
        text = default_tpl.text,
        simple = is_simple(param.default),
        has_call = default_tpl.has_call,
        template_text = template_text(param.default, buf),
        type = param.default:type(),
      }
    end
  end
  return function_info
end

-- How to inline the call at `range` (the `@function_call.outside` capture):
--   `{ lines }`: lines that replace the range (possibly none);
--   `{ lines, pre, statement }` for a call nested in an expression: `lines` is
--   the return value that replaces the call and `pre` the lines to insert
--   before `statement` (`{ row, col }`, the enclosing statement);
--   nil and the reason when the call can't be inlined.
-- `taken_by_scope` shares the names already used in each calling function
-- between the calls of the same refactor.
function M.inline_call(fn, buf, range, taken_by_scope)
  local srow, scol, erow, ecol = range:to_extmark()
  local root = ts.get_parser(buf, "kotlin"):parse()[1]:root()
  local node = root:named_descendant_for_range(srow, scol, erow, ecol)

  local call, result, nested
  if node:type() == "property_declaration" then
    local declaration = vim.iter(node:iter_children()):find(function(c)
      return c:type() == "variable_declaration"
    end)
    call = vim.iter(node:iter_children()):find(function(c)
      return c:type() == "call_expression"
    end)
    if not declaration or not call then return nil, "unsupported call" end
    result = text(declaration, buf)
  elseif node:type() == "call_expression" then
    call = node
    nested = node:parent():type() ~= "statements"
    -- The last statement of a lambda or an `if`/`when` branch is its value.
    local block = node:parent()
    if not nested and block:named_child(block:named_child_count() - 1):id() == node:id() then
      local container = block:parent():type()
      nested = container == "lambda_literal" or container == "control_structure_body"
    end
  else
    return nil, "unsupported call"
  end

  -- Nested call: the statement it belongs to, and whether it may not run (or run
  -- several times) when that statement runs.
  local statement, conditional = nil, false
  if nested then
    local child = call
    while child:parent() do
      local parent = child:parent()
      if parent:type() == "statements" then
        statement = child
        break
      end
      if parent:type() == "function_body" then break end -- `fun g() = f(x)`
      if CONDITIONAL[parent:type()] or parent:type() == "control_structure_body" then conditional = true end
      child = parent
    end
  end

  -- `obj.f()`: the receiver. `this.f()` is the same as `f()`.
  local receiver
  local callee = call:named_child(0)
  if callee:type() == "navigation_expression" then
    local receiver_node, member = callee:named_child(0), callee:named_child(1)
    if text(member, buf):match "^%?%." then return nil, "safe calls (`?.`) run conditionally" end
    if not (receiver_node:type() == "this_expression" and text(receiver_node, buf) == "this") then
      if fn.uses_private then return nil, "the body uses private members" end
      receiver = {
        text = text(receiver_node, buf),
        simple = is_simple(receiver_node),
        type = receiver_node:type(),
        has_call = contains_call(receiver_node),
      }
    end
  end

  -- Arguments: positional, named and the trailing lambda.
  local positional, named = {}, {}
  local suffix = vim.iter(call:iter_children()):find(function(c)
    return c:type() == "call_suffix"
  end)
  for part in suffix:iter_children() do
    if part:type() == "value_arguments" then
      for argument in part:iter_children() do
        if argument:type() == "value_argument" then
          local value = argument:named_child(argument:named_child_count() - 1)
          local label = argument:named_child(0)
          local next = label:next_sibling()
          if argument:named_child_count() == 2 and next and next:type() == "=" then
            named[text(label, buf)] = value
          else
            table.insert(positional, value)
          end
        end
      end
    elseif part:type() == "annotated_lambda" then
      table.insert(positional, part)
    end
  end

  -- Names already used in the calling function: the inlined code can't reuse them.
  local scope = node
  while scope:parent() and scope:type() ~= "function_declaration" do
    scope = scope:parent()
  end
  local scope_key = ("%d:%s"):format(buf, scope:id())
  local taken = taken_by_scope[scope_key]
  if not taken then
    taken = {}
    walk(scope, function(n)
      local parent_type = n:parent() and n:parent():type()
      local declaration = n:type() == "simple_identifier"
        and (parent_type == "variable_declaration" or parent_type == "parameter" or parent_type == "class_parameter")
      if declaration or is_reference(n) then taken[text(n, buf)] = true end
    end)
    taken_by_scope[scope_key] = taken
  end
  local function fresh(name)
    local candidate, i = name, 0
    while taken[candidate] do
      i = i + 1
      candidate = name .. i
    end
    taken[candidate] = true
    return candidate
  end

  local function uses(name)
    local spots = {}
    for _, tpl in pairs { body = fn.body, ret = fn.ret } do
      for _, spot in ipairs(tpl.spots) do
        if spot.name == name and not spot.declaration then table.insert(spots, spot) end
      end
    end
    return spots
  end

  -- What each parameter is replaced with.
  local args = {}
  local complex = 0
  for i, param in ipairs(fn.params) do
    local value = named[param.name] or positional[i]
    local arg
    if value then
      arg = {
        text = text(value, buf),
        simple = is_simple(value),
        type = value:type(),
        has_call = contains_call(value),
        template_text = template_text(value, buf),
      }
    elseif param.default then
      arg = vim.deepcopy(param.default)
    else
      return nil, "an argument is missing (vararg?)"
    end
    arg.uses = uses(param.name)
    if not arg.simple and #arg.uses > 0 then complex = complex + 1 end
    args[param.name] = arg
  end

  -- The receiver is used by `this` and the members the body uses.
  if receiver then
    receiver.uses = {}
    for _, tpl in pairs { body = fn.body, ret = fn.ret } do
      for _, spot in ipairs(tpl.spots) do
        if spot.kind == "this" or spot.kind == "member" then table.insert(receiver.uses, spot) end
      end
    end
    if not receiver.simple and #receiver.uses > 0 then complex = complex + 1 end
  end

  -- Locals of the body that clash with the caller get a new name.
  local renamed = {}
  for name in pairs(fn.locals) do
    renamed[name] = fresh(name)
  end

  -- Substitute `arg` or declare it as `val <name>`, in evaluation order (the
  -- receiver first).
  local lines = {}
  -- A lambda needs its parameter's type to compile (`{ it + 1 }` alone can't
  -- infer `it`), so it's always declared, with that type.
  local function bind(arg, name, declared_type)
    local only_use = #arg.uses == 1 and arg.uses[1]
    local lambda = arg.type == "annotated_lambda" or arg.type == "lambda_literal"
    if lambda and #arg.uses > 0 then
      local fresh_name = fresh(name)
      local declaration = declared_type and ("%s: %s"):format(fresh_name, declared_type) or fresh_name
      vim.list_extend(lines, vim.split(("val %s = %s"):format(declaration, arg.text), "\n"))
      arg.replacement = fresh_name
      arg.type = "simple_identifier"
    elseif arg.simple then
      arg.replacement = arg.text
    elseif only_use and complex == 1 and not fn.body and not only_use.conditional then
      arg.replacement = arg.text
    elseif #arg.uses == 0 then
      -- Unused: keep the argument only for its side effects.
      if arg.has_call then vim.list_extend(lines, vim.split(arg.text, "\n")) end
    else
      local fresh_name = fresh(name)
      vim.list_extend(lines, vim.split(("val %s = %s"):format(fresh_name, arg.text), "\n"))
      arg.replacement = fresh_name
      arg.type = "simple_identifier"
      arg.template_text = nil
    end
  end
  if receiver then bind(receiver, (fn.receiver_type or "receiver"):gsub("^%u", string.lower)) end
  for _, param in ipairs(fn.params) do
    bind(args[param.name], param.name, param.declared_type)
  end

  local function replace(spot)
    if spot.kind == "this" or spot.kind == "member" then
      -- Implicit receiver (`f()`, `this.f()`): the body works as is.
      if not receiver then return nil end
      local object = receiver.replacement
      if needs_parens(receiver.type, "navigation_expression", true) then object = ("(%s)"):format(object) end
      if spot.kind == "this" then
        return needs_parens(receiver.type, spot.parent_type, spot.is_left) and ("(%s)"):format(receiver.replacement)
          or receiver.replacement
      end
      local member = ("%s.%s"):format(object, spot.name)
      return spot.interpolated and ("${%s}"):format(member) or member
    end

    local replacement, arg
    if fn.locals[spot.name] then
      replacement = renamed[spot.name]
    else
      arg = args[spot.name]
      replacement = arg.replacement
    end
    if replacement == spot.name then return nil end
    if spot.interpolated then
      if arg and arg.template_text then return arg.template_text end
      return replacement:match "^[%a_][%w_]*$" and ("$" .. replacement) or ("${%s}"):format(replacement)
    end
    if not arg then return replacement end
    if needs_parens(arg.type, spot.parent_type, spot.is_left) then return ("(%s)"):format(replacement) end
    return replacement
  end

  if fn.body then vim.list_extend(lines, vim.split(render(fn.body, replace), "\n")) end

  if nested then
    -- Moving code before the statement is only right if the call always runs,
    -- and possible if the statement starts its line (not `xs.map { f(it) }`).
    if #lines > 0 then
      local reason =
        "its body can't be moved before the statement (conditional code, an expression body or a one-line lambda)"
      if conditional or not statement then return nil, reason end
      local row, col = statement:start()
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, true)[1]
      if line:sub(1, col):match "%S" then return nil, reason end
    end
    local value = fn.ret and render(fn.ret, replace) or "Unit"
    local value_type = fn.ret_param and args[fn.ret_param].type or fn.ret_type or "simple_identifier"
    if needs_parens(value_type, call:parent():type(), is_left_operand(call)) then value = ("(%s)"):format(value) end
    local row, col = (statement or call):start()
    return { lines = vim.split(value, "\n"), pre = lines, statement = { row, col } }
  end

  if fn.ret then
    local value = render(fn.ret, replace)
    if result then
      vim.list_extend(lines, vim.split(("val %s = %s"):format(result, value), "\n"))
    elseif fn.ret.has_call then
      vim.list_extend(lines, vim.split(value, "\n"))
    end
  elseif result then
    table.insert(lines, ("val %s = Unit"):format(result))
  end

  return { lines = lines }
end

-- Plans for every call of the function inline_func is about to delete, keyed by
-- text edit (`false` when that call can't be inlined), computed before any edit
-- is applied, plus the reasons of the calls that can't. nil when the function
-- isn't Kotlin or isn't supported.
function M.plan(text_edits_by_buf)
  local fn = M.deleted_function(text_edits_by_buf)
  if not fn then return end
  local plans, reasons, taken_by_scope = {}, {}, {}
  for buf, text_edits in pairs(text_edits_by_buf) do
    for _, text_edit in ipairs(text_edits) do
      if #text_edit.lines > 0 then
        local plan, reason = M.inline_call(fn, buf, text_edit.range, taken_by_scope)
        plans[text_edit] = plan or false
        if not plan then table.insert(reasons, reason) end
      end
    end
  end
  return plans, reasons
end

return M
