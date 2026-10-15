; Kotlin debug path for refactoring.nvim (not bundled upstream).
; Used by the debug prints: the path of the printed location, e.g.
; `total#for#if` (the enclosing functions, loops and `if`s, outermost first).

(if_expression
  (#set! text if)) @debug_path_segment

(for_statement
  (#set! text for)) @debug_path_segment

(while_statement
  (#set! text while)) @debug_path_segment

(do_while_statement
  (#set! text do)) @debug_path_segment

(function_declaration
  (simple_identifier) @_name
  (#set! text @_name)) @debug_path_segment

(lambda_literal
  (#set! text "(anon)")) @debug_path_segment
