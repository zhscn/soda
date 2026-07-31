((block) @indent.scope
  (#set! indent.include-start "true"))

[
  (table_constructor)
  (parameters)
  (arguments)
] @indent.scope

[
  "}"
  ")"
] @indent.end
