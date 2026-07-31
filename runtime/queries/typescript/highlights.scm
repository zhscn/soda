(comment) @comment

[
  (string)
  (template_string)
  (regex)
] @string

(number) @number
[(true) (false) (null) (undefined)] @constant
[(type_identifier) (predefined_type)] @type
(property_identifier) @property

(function_declaration
  name: (identifier) @function)

(method_definition
  name: (property_identifier) @function.method)

(class_declaration
  name: (type_identifier) @type)

[
  "import"
  "export"
  "from"
  "as"
  "const"
  "let"
  "var"
  "function"
  "class"
  "interface"
  "type"
  "enum"
  "namespace"
  "extends"
  "implements"
  "declare"
  "abstract"
  "public"
  "private"
  "protected"
  "readonly"
  "new"
  "async"
  "await"
  "if"
  "else"
  "for"
  "while"
  "switch"
  "case"
  "default"
  "try"
  "catch"
  "finally"
  "throw"
  "return"
] @keyword
