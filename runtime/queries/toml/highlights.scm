(comment) @comment
[(string) (quoted_key)] @string
[(integer) (float)] @number
(boolean) @constant
(bare_key) @property

[(table) (table_array_element)] @type
["[" "]" "[[" "]]" "{" "}"] @punctuation.bracket
["=" "." ","] @punctuation.delimiter
