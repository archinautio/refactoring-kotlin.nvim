; Kotlin statements for refactoring.nvim (not bundled upstream).
; Used by extract variable: the new `val` is inserted above the statement that
; contains the extracted expression. Also used by the debug prints, which go
; above or below the statement that contains the cursor.
; - `@output_statement.inside` is the body of a statement that has one. When
;   the cursor is in the statement's header (a loop variable, a parameter, an
;   `if` condition), the debug prints go into the body instead of around the
;   whole statement, where the variable may be out of scope.
; - Statements with a body are only matched by their own pattern below: if the
;   generic pattern also matched them (without `inside`), the debug prints could
;   pick that match and ignore the body.
; - `inside_only` marks nodes that aren't statements (top-level and member
;   functions, lambdas): only their body is used, extract variable never inserts
;   above them.

((statements
  (_) @output_statement)
  (#not-kind-eq? @output_statement
    "for_statement" "while_statement" "do_while_statement" "if_expression" "function_declaration"))

; Only in statement position: `val m = if (a) { 1 } else { 2 }` isn't a statement.
(statements
  (for_statement
    (control_structure_body
      (statements)? @output_statement.inside)?) @output_statement)

(statements
  (while_statement
    (control_structure_body
      (statements)? @output_statement.inside)?) @output_statement)

(statements
  (do_while_statement
    (control_structure_body
      (statements)? @output_statement.inside)?) @output_statement)

(statements
  (if_expression
    consequence: (control_structure_body
      (statements)? @output_statement.inside)?) @output_statement)

; Local functions
(statements
  (function_declaration
    (function_body
      (statements)? @output_statement.inside)?) @output_statement)

; Top-level and member functions
((function_declaration
  (function_body
    (statements) @output_statement.inside)) @output_statement
  (#not-has-parent? @output_statement statements)
  (#set! inside_only))

(lambda_literal
  (statements) @output_statement.inside
  (#set! inside_only)) @output_statement
