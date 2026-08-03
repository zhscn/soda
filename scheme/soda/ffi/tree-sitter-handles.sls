(library (soda ffi tree-sitter-handles)
  (export tree-sitter-parser?
          %make-tree-sitter-parser
          tree-sitter-parser-pointer
          tree-sitter-parser-pointer-set!
          tree-sitter-query?
          %make-tree-sitter-query
          tree-sitter-query-pointer
          tree-sitter-query-pointer-set!)
  (import (chezscheme))

  (define-record-type
    (tree-sitter-parser %make-tree-sitter-parser tree-sitter-parser?)
    (fields (mutable pointer)))

  (define-record-type
    (tree-sitter-query %make-tree-sitter-query tree-sitter-query?)
    (fields (mutable pointer))))
