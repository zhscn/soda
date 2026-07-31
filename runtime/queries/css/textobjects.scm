(rule_set
  (block) @text-object.class.inside) @text-object.class.around

(block) @text-object.block.around
(block (_) @text-object.block.inside)

(arguments) @text-object.arguments.around
(arguments (_) @text-object.arguments.inside)

(call_expression) @text-object.call.around

(declaration) @text-object.statement.around

(string_value) @text-object.string.around

[
  (comment)
  (js_comment)
] @text-object.comment.around
