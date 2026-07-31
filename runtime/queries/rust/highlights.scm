[(line_comment) (block_comment)] @comment

[
  (string_literal)
  (raw_string_literal)
  (char_literal)
] @string

[(integer_literal) (float_literal)] @number
(boolean_literal) @constant
[(type_identifier) (primitive_type)] @type
(field_identifier) @property
(lifetime) @label
(crate) @keyword

(function_item
  name: (identifier) @function)

(macro_invocation
  macro: (identifier) @function.macro)

[
  "use"
  "mod"
  "pub"
  "extern"
  "fn"
  "struct"
  "enum"
  "union"
  "trait"
  "impl"
  "type"
  "where"
  "const"
  "static"
  "let"
  "move"
  "async"
  "await"
  "if"
  "else"
  "match"
  "for"
  "while"
  "loop"
  "in"
  "return"
  "break"
  "continue"
] @keyword
