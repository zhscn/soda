(library (soda cpp-analysis handles)
  (export cpp-analyzer?
          %make-cpp-analyzer
          cpp-analyzer-pointer
          cpp-analyzer-pointer-set!)
  (import (chezscheme))

  (define-record-type (cpp-analyzer %make-cpp-analyzer cpp-analyzer?)
    (fields (mutable pointer))))
