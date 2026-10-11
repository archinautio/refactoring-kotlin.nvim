;; extends

; Kotlin variable declarations for refactoring.nvim (not bundled upstream).
; Used by inline variable: the value replaces every usage and the whole
; declaration is then removed. Separators aren't captured on purpose, so the
; plugin deletes the full `val a = ...` line instead of leaving `val` behind.

(property_declaration
  (variable_declaration
    (simple_identifier) @variable.identifier)
  .
  (_) @variable.value) @variable.declaration
