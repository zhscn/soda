(comment) @comment

[
  (string)
  (template_string)
  (regex)
] @string

(number) @number
[(true) (false) (null) (undefined)] @constant
(property_identifier) @property
(shorthand_property_identifier) @property
(jsx_attribute
  (property_identifier) @attribute)

[
  (jsx_opening_element
    (identifier) @tag)
  (jsx_closing_element
    (identifier) @tag)
  (jsx_self_closing_element
    (identifier) @tag)
]

(function_declaration
  name: (identifier) @function)

(method_definition
  name: (property_identifier) @function.method)

(class_declaration
  name: (identifier) @type)

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
  "extends"
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
  "break"
  "continue"
] @keyword
