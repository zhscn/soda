(function_item
  body: (block) @text-object.function.inside) @text-object.function.around

[
  (struct_item)
  (enum_item)
  (trait_item)
  (impl_item)
  (mod_item)
] @text-object.class.around

(parameters) @text-object.parameters.around
(parameters (_) @text-object.parameters.inside)

(arguments) @text-object.arguments.around
(arguments (_) @text-object.arguments.inside)

(call_expression) @text-object.call.around

(block) @text-object.block.around
(block (_) @text-object.block.inside)

(array_expression) @text-object.array.around
(array_expression (_) @text-object.array.inside)

(tuple_expression) @text-object.tuple.around
(tuple_expression (_) @text-object.tuple.inside)

(if_expression) @text-object.conditional.around

[
  (for_expression)
  (while_expression)
  (loop_expression)
] @text-object.loop.around

(expression_statement) @text-object.statement.around

(string_literal) @text-object.string.around

[
  (line_comment)
  (block_comment)
] @text-object.comment.around
