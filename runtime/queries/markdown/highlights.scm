[
  (atx_heading)
  (setext_heading)
] @markup.heading

[
  (fenced_code_block)
  (indented_code_block)
] @markup.raw.block

(info_string) @label
(link_reference_definition) @markup.link
(link_destination) @markup.link.url
(link_label) @markup.link.label
(block_quote_marker) @markup.quote

[
  (list_marker_dot)
  (list_marker_minus)
  (list_marker_parenthesis)
  (list_marker_plus)
  (list_marker_star)
] @markup.list

[(task_list_marker_checked) (task_list_marker_unchecked)] @constant
(thematic_break) @punctuation.delimiter
