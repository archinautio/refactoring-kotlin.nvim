; Kotlin functions that can contain extracted code, for refactoring.nvim (not bundled upstream).
; Used by extract function to find the function that surrounds the selection.
; Class members are flagged with `method` so the new function is indented as a member.

(source_file
  (function_declaration) @input_function)

(class_body
  (function_declaration) @input_function
  (#set! method))
