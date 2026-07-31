[
  (function_declaration
    body: (statement_block) @text-object.function.inside)
  (generator_function_declaration
    body: (statement_block) @text-object.function.inside)
  (method_definition
    body: (statement_block) @text-object.function.inside)
] @text-object.function.around

[
  (function_expression)
  (arrow_function)
] @text-object.function.around

(class_declaration
  body: (class_body) @text-object.class.inside) @text-object.class.around

(formal_parameters) @text-object.parameters.around
(formal_parameters (_) @text-object.parameters.inside)

(arguments) @text-object.arguments.around
(arguments (_) @text-object.arguments.inside)

(call_expression) @text-object.call.around

(statement_block) @text-object.block.around
(statement_block (_) @text-object.block.inside)

(array) @text-object.array.around
(array (_) @text-object.array.inside)

(object) @text-object.object.around
(object (_) @text-object.object.inside)

[
  (if_statement)
  (switch_statement)
  (try_statement)
] @text-object.conditional.around

[
  (for_statement)
  (for_in_statement)
  (while_statement)
  (do_statement)
] @text-object.loop.around

[
  (expression_statement)
  (return_statement)
  (throw_statement)
  (import_statement)
  (export_statement)
] @text-object.statement.around

[
  (string)
  (template_string)
] @text-object.string.around

[
  (comment)
  (html_comment)
] @text-object.comment.around
