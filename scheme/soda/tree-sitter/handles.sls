(library (soda tree-sitter handles)
  (export tree-sitter-parser?
          %make-tree-sitter-parser
          tree-sitter-parser-pointer
          tree-sitter-parser-pointer-set!)
  (import (chezscheme))

  (define-record-type
    (tree-sitter-parser %make-tree-sitter-parser tree-sitter-parser?)
    (fields (mutable pointer))))
