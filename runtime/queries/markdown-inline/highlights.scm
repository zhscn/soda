(strong_emphasis) @markup.bold
(emphasis) @markup.italic
(strikethrough) @markup.strikethrough
(code_span) @markup.raw.inline

[
  (link_text)
  (image_description)
] @markup.link.label

(link_destination) @markup.link.url
(link_title) @string
[(uri_autolink) (email_autolink)] @markup.link.url
