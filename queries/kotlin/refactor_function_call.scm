;; extends

; Kotlin function calls for refactoring.nvim (not bundled upstream).
; Used by inline function: every call to the inlined function is replaced by its
; body. Captures the callee name, its arguments and, for `val x = f()`, the
; variable that receives the result.
; - `@function_call` is only the callee name (`f` in `f()` or `obj.f()`): the
;   plugin picks the call whose `@function_call` contains the reference, so a
;   call nested in another one (`println(f(x))`) must not match the outer call.
; - `@function_call.outside` is the text that gets replaced. For nested calls
;   it's the call itself; `lua/refactoring-kotlin/kotlin.lua` also inserts the
;   body before the enclosing statement.
; - Whole `value_argument`s are captured, so named arguments arrive as
;   `name = value`, and the Kotlin code generator (`assignment`, the fallback
;   used when the inliner can't handle a function) matches them by name.

; `f(a, b)` or `obj.f(a, b)` used as a statement
(statements
  (call_expression
    [
      (simple_identifier) @function_call.name @function_call
      (navigation_expression
        (navigation_suffix
          (simple_identifier) @function_call.name @function_call))
    ]
    (call_suffix
      (value_arguments
        ((value_argument) @function_call.arg
          (","
            (value_argument) @function_call.arg)*)?))) @function_call.outside)

; `val x = f(a, b)` or `val x = obj.f(a, b)`
(property_declaration
  (variable_declaration
    (simple_identifier) @function_call.return_value)
  (call_expression
    [
      (simple_identifier) @function_call.name @function_call
      (navigation_expression
        (navigation_suffix
          (simple_identifier) @function_call.name @function_call))
    ]
    (call_suffix
      (value_arguments
        ((value_argument) @function_call.arg
          (","
            (value_argument) @function_call.arg)*)?)))) @function_call.outside

; Any other call: `println(f(a))`, `obj.f(a) + 1`, `x = f(a)`, `fun g() = f(a)`...
; (only the callee is needed: the arguments are read by the Kotlin inliner).
((call_expression
  [
    (simple_identifier) @function_call.name @function_call
    (navigation_expression
      (navigation_suffix
        (simple_identifier) @function_call.name @function_call))
  ]
  (call_suffix)) @function_call.outside
  (#not-has-parent? @function_call.outside statements property_declaration))
