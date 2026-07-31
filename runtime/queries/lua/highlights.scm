(comment) @comment
(hash_bang_line) @comment
(string) @string
(number) @number
[(true) (false) (nil)] @constant

(function_declaration
  name: (identifier) @function)

(function_declaration
  name: (method_index_expression) @function.method)

[
  "local"
  "function"
  "end"
  "if"
  "then"
  "elseif"
  "else"
  "for"
  "in"
  "while"
  "repeat"
  "until"
  "do"
  "return"
  "goto"
  "and"
  "or"
  "not"
] @keyword
