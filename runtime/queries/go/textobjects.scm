[
  (function_declaration
    body: (block) @text-object.function.inside)
  (method_declaration
    body: (block) @text-object.function.inside)
  (func_literal
    body: (block) @text-object.function.inside)
] @text-object.function.around

[
  (struct_type)
  (interface_type)
] @text-object.class.around

(parameter_list) @text-object.parameters.around
(parameter_list (_) @text-object.parameters.inside)

(argument_list) @text-object.arguments.around
(argument_list (_) @text-object.arguments.inside)

(call_expression) @text-object.call.around

(block) @text-object.block.around
(block (_) @text-object.block.inside)

(literal_value) @text-object.list.around
(literal_value (_) @text-object.list.inside)

(if_statement) @text-object.conditional.around

(for_statement) @text-object.loop.around

[
  (expression_statement)
  (return_statement)
  (assignment_statement)
  (short_var_declaration)
  (go_statement)
  (defer_statement)
] @text-object.statement.around

[
  (interpreted_string_literal)
  (raw_string_literal)
] @text-object.string.around

(comment) @text-object.comment.around
