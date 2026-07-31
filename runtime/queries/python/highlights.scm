(comment) @comment
(string) @string
[(integer) (float)] @number
[(true) (false) (none)] @constant

(function_definition
  name: (identifier) @function)

(class_definition
  name: (identifier) @type)

(decorator) @attribute

[
  "import"
  "from"
  "as"
  "def"
  "class"
  "async"
  "await"
  "if"
  "elif"
  "else"
  "for"
  "while"
  "try"
  "except"
  "finally"
  "with"
  "match"
  "case"
  "lambda"
  "yield"
  "return"
  "raise"
  "assert"
  "break"
  "continue"
  "pass"
  "global"
  "nonlocal"
] @keyword
