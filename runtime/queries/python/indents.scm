((block) @indent.scope
  (#set! indent.include-start "true"))

[
  (argument_list)
  (parameters)
  (list)
  (tuple)
  (dictionary)
  (set)
  (parenthesized_expression)
] @indent.scope

[
  ")"
  "]"
  "}"
] @indent.end
