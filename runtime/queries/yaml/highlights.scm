(comment) @comment

[
  (string_scalar)
  (double_quote_scalar)
  (single_quote_scalar)
] @string

[(integer_scalar) (float_scalar)] @number
[(boolean_scalar) (null_scalar)] @constant
(anchor_name) @label
(alias_name) @label
(tag) @attribute
(directive_name) @keyword

["[" "]" "{" "}"] @punctuation.bracket
[":" "," "-"] @punctuation.delimiter
