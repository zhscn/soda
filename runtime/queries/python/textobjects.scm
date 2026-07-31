(function_definition
  body: (block) @text-object.function.inside) @text-object.function.around

(class_definition
  body: (block) @text-object.class.inside) @text-object.class.around

(parameters) @text-object.parameters.around
(parameters (_) @text-object.parameters.inside)

(argument_list) @text-object.arguments.around
(argument_list (_) @text-object.arguments.inside)

(call) @text-object.call.around

[
  (list)
  (tuple)
] @text-object.list.around

[
  (list (_) @text-object.list.inside)
  (tuple (_) @text-object.list.inside)
]

(dictionary) @text-object.object.around
(dictionary (_) @text-object.object.inside)

(set) @text-object.set.around
(set (_) @text-object.set.inside)

[
  (if_statement)
  (match_statement)
] @text-object.conditional.around

[
  (for_statement)
  (while_statement)
] @text-object.loop.around

[
  (expression_statement)
  (return_statement)
  (raise_statement)
  (assert_statement)
  (import_statement)
  (import_from_statement)
] @text-object.statement.around

(string) @text-object.string.around
(comment) @text-object.comment.around
