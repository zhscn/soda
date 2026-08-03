(library (soda editor builtin-api-index)
  (export soda-built-in-api-index
          soda-built-in-library-index
          scheme-built-in-api-index
          scheme-built-in-library-index)
  (import (rnrs))

  ;; The application build replaces this library in its staging tree with the
  ;; catalog generated from Soda's Scheme sources.  Source-tree evaluation
  ;; keeps an empty catalog so individual libraries remain directly loadable.
  (define soda-built-in-api-index '())
  (define soda-built-in-library-index '())
  (define scheme-built-in-api-index '())
  (define scheme-built-in-library-index '()))
