; Kotlin insertion points for extracted functions, for refactoring.nvim (not bundled upstream).
; Used by extract function: the new function is inserted above the function it
; comes from (and above that function's leading comments), at top level or inside
; the class body.

(source_file
  ([
    (line_comment)
    (multiline_comment)
  ]* @output_function.comment
    .
    (function_declaration) @output_function))

(class_body
  ([
    (line_comment)
    (multiline_comment)
  ]* @output_function.comment
    .
    (function_declaration) @output_function))
