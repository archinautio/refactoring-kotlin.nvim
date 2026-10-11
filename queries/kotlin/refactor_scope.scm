; Kotlin scopes for refactoring.nvim (not bundled upstream).
; `@scope` is where a variable declared inside is visible, and `@scope.inside`
; the statements of its body. Used by extract function (to decide which variables
; become parameters) and extract variable (to find where to insert the `val`).
; `source_file` is the catch-all scope, so every declaration has one.

(function_declaration
  (function_value_parameters) @scope
  (function_body
    (statements
      (_)* @scope.inside)) @scope)

(control_structure_body
  (statements
    (_)* @scope.inside)) @scope

(lambda_literal
  (statements
    (_)* @scope.inside)) @scope

(class_body
  (_)* @scope.inside) @scope

(source_file
  (_)* @scope.inside) @scope
