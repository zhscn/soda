(comment) @comment

[
  (interpreted_string_literal)
  (raw_string_literal)
  (rune_literal)
] @string

[
  (int_literal)
  (float_literal)
  (imaginary_literal)
] @number

[(true) (false) (nil) (iota)] @constant
(type_identifier) @type
(field_identifier) @property

(function_declaration
  name: (identifier) @function)

(method_declaration
  name: (field_identifier) @function.method)

[
  "package"
  "import"
  "const"
  "var"
  "type"
  "func"
  "struct"
  "interface"
  "map"
  "chan"
  "go"
  "defer"
  "if"
  "else"
  "for"
  "range"
  "switch"
  "select"
  "case"
  "default"
  "return"
  "break"
  "continue"
  "fallthrough"
] @keyword
