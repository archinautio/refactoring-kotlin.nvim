; Kotlin variable references for refactoring.nvim (not bundled upstream).
; Classifies every identifier as a declaration, a write or a read (with its type
; when it's written in the source). Used by extract function to compute the new
; function's parameters and return value, and by inline variable to find the
; usages that kotlin-lsp reports.

; val/var declarations, with the type when it's explicit: `val a: Int = 1`
(property_declaration
  (variable_declaration
    (simple_identifier) @reference.identifier
    (_)? @_type)
  (#set-type! java @_type @reference.identifier)
  (#set! reference_type write)
  (#set! declaration))

; function parameters: `fun f(a: Int)`
(parameter
  (simple_identifier) @reference.identifier
  (_) @_type
  (#set-type! java @_type @reference.identifier)
  (#set! reference_type write)
  (#set! declaration))

; for loop and lambda parameters: `for (a in xs)`, `{ a -> ... }`
(for_statement
  (variable_declaration
    (simple_identifier) @reference.identifier)
  (#set! reference_type write)
  (#set! declaration))

(lambda_parameters
  (variable_declaration
    (simple_identifier) @reference.identifier)
  (#set! reference_type write)
  (#set! declaration))

; `a = 1`, `a += 1`
(assignment
  (directly_assignable_expression
    (simple_identifier) @reference.identifier)
  (#set! reference_type write))

; `a++`, `a--`
(postfix_expression
  (simple_identifier) @reference.identifier
  (#set! reference_type write))

; Any other identifier used as an expression is a read. Excludes declaration
; names, member names (`x.member`), callees (`f()`) and package/import paths.
((simple_identifier) @reference.identifier
  (#not-has-parent? @reference.identifier
    variable_declaration parameter directly_assignable_expression navigation_suffix
    call_expression function_declaration identifier class_parameter)
  (#set! reference_type read))

; `"$a"` string templates
((interpolated_identifier) @reference.identifier
  (#set! reference_type read))
