[
  (function_declaration)
  (function_definition)
] @text-object.function.around

(parameters) @text-object.parameters.around
(parameters (_) @text-object.parameters.inside)

(arguments) @text-object.arguments.around
(arguments (_) @text-object.arguments.inside)

(function_call) @text-object.call.around

(block) @text-object.block.around
(block (_) @text-object.block.inside)

(table_constructor) @text-object.table.around
(table_constructor (_) @text-object.table.inside)

(if_statement) @text-object.conditional.around

[
  (for_statement)
  (while_statement)
  (repeat_statement)
] @text-object.loop.around

[
  (assignment_statement)
  (return_statement)
] @text-object.statement.around

(string) @text-object.string.around
(comment) @text-object.comment.around
