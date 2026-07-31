(library (soda tree-sitter)
  (export make-tree-sitter-parser
          register-tree-sitter-language!
          tree-sitter-language-available?
          tree-sitter-parser?
          tree-sitter-parser-close!
          tree-sitter-parser-parse!
          tree-sitter-parser-apply!
          tree-sitter-parser-document-id
          tree-sitter-parser-revision
          tree-sitter-parser-root-kind
          tree-sitter-parser-root-range
          tree-sitter-parser-root-has-error?
          tree-sitter-parser-query
          tree-sitter-capture?
          tree-sitter-capture-name
          tree-sitter-capture-start
          tree-sitter-capture-end
          tree-sitter-capture-node-kind
          tree-sitter-capture-depth)
  (import (chezscheme)
          (soda document)
          (soda document handles)
          (soda native)
          (soda tree-sitter handles))

  (define native-library-loaded
    (load-soda-native-library! "SODA_TREE_SITTER_LIBRARY"))

  (define language-overrides (make-eq-hashtable))

  (define-record-type tree-sitter-capture
    (fields name start end node-kind depth))

  (define %abi-version
    (foreign-procedure
      __atomic "soda_tree_sitter_abi_version" () unsigned-32))
  (define %last-error
    (foreign-procedure
      __atomic "soda_tree_sitter_last_error" () string))
  (define %language-available
    (foreign-procedure
      __atomic "soda_ts_language_available"
      (string string string)
      int))
  (define %parser-create
    (foreign-procedure
      __atomic "soda_ts_parser_create"
      (string string string)
      void*))
  (define %parser-destroy
    (foreign-procedure
      __atomic "soda_ts_parser_destroy" (void*) void))
  (define %parser-parse
    (foreign-procedure
      __atomic "soda_ts_parser_parse" (void* void*) int))
  (define %parser-apply
    (foreign-procedure
      __atomic "soda_ts_parser_apply" (void* void* void*) int))
  (define %parser-document-id
    (foreign-procedure
      __atomic "soda_ts_parser_document_id" (void*) unsigned-32))
  (define %parser-revision
    (foreign-procedure
      __atomic "soda_ts_parser_revision" (void*) unsigned-64))
  (define %parser-root-kind
    (foreign-procedure
      __atomic "soda_ts_parser_root_kind" (void*) string))
  (define %parser-root-range
    (foreign-procedure
      __atomic "soda_ts_parser_root_range" (void* void* void*) int))
  (define %parser-root-has-error
    (foreign-procedure
      __atomic "soda_ts_parser_root_has_error" (void*) int))
  (define %parser-query
    (foreign-procedure
      __atomic "soda_ts_parser_query"
      (void* string unsigned-32 unsigned-32)
      void*))
  (define %query-result-destroy
    (foreign-procedure
      __atomic "soda_ts_query_result_destroy" (void*) void))
  (define %query-result-count
    (foreign-procedure
      __atomic "soda_ts_query_result_count" (void*) unsigned-32))
  (define %query-result-name
    (foreign-procedure
      __atomic "soda_ts_query_result_name"
      (void* unsigned-32)
      string))
  (define %query-result-node-kind
    (foreign-procedure
      __atomic "soda_ts_query_result_node_kind"
      (void* unsigned-32)
      string))
  (define %query-result-range
    (foreign-procedure
      __atomic "soda_ts_query_result_range"
      (void* unsigned-32 void* void*)
      int))
  (define %query-result-depth
    (foreign-procedure
      __atomic "soda_ts_query_result_depth"
      (void* unsigned-32)
      unsigned-32))

  (define abi-version-checked
    (unless (= (%abi-version) 1)
      (error
        'soda-tree-sitter
        "unsupported native Tree-sitter ABI version")))

  (define (native-error who)
    (error who (%last-error)))

  (define (check-status who status)
    (when (negative? status)
      (native-error who)))

  (define (require-open who value)
    (unless (tree-sitter-parser? value)
      (assertion-violation who "expected a Tree-sitter parser" value))
    (unless (tree-sitter-parser-pointer value)
      (assertion-violation who "Tree-sitter parser is closed" value)))

  (define (require-snapshot who value)
    (unless (and (snapshot? value) (snapshot-pointer value))
      (assertion-violation who "expected an open snapshot" value)))

  (define (require-change who value)
    (unless (and (change? value) (change-pointer value))
      (assertion-violation who "expected an open change" value)))

  (define register-tree-sitter-language!
    (case-lambda
      [(language)
       (register-tree-sitter-language! language #f #f)]
      [(language library)
       (register-tree-sitter-language! language library #f)]
      [(language library symbol)
       (unless (symbol? language)
         (assertion-violation
           'register-tree-sitter-language!
           "language must be a symbol"
           language))
       (unless (or (not library) (string? library))
         (assertion-violation
           'register-tree-sitter-language!
           "library must be a string or #f"
           library))
       (unless (or (not symbol) (string? symbol))
         (assertion-violation
           'register-tree-sitter-language!
           "entry symbol must be a string or #f"
           symbol))
       (hashtable-set!
         language-overrides
         language
         (cons (or library "") (or symbol "")))
       language]))

  (define (language-load-specification language)
    (hashtable-ref
      language-overrides
      language
      (cons "" "")))

  (define (tree-sitter-language-available? language)
    (unless (symbol? language)
      (assertion-violation
        'tree-sitter-language-available?
        "language must be a symbol"
        language))
    (let ([specification (language-load-specification language)])
      (positive?
        (%language-available
          (symbol->string language)
          (car specification)
          (cdr specification)))))

  (define (make-tree-sitter-parser language)
    (unless (symbol? language)
      (assertion-violation
        'make-tree-sitter-parser
        "language must be a symbol"
        language))
    (let* ([specification
             (language-load-specification language)]
           [pointer
             (%parser-create
               (symbol->string language)
               (car specification)
               (cdr specification))])
      (unless pointer
        (native-error 'make-tree-sitter-parser))
      (%make-tree-sitter-parser pointer)))

  (define (tree-sitter-parser-close! value)
    (when (and
            (tree-sitter-parser? value)
            (tree-sitter-parser-pointer value))
      (%parser-destroy (tree-sitter-parser-pointer value))
      (tree-sitter-parser-pointer-set! value #f)))

  (define (tree-sitter-parser-parse! value snapshot)
    (require-open 'tree-sitter-parser-parse! value)
    (require-snapshot 'tree-sitter-parser-parse! snapshot)
    (check-status
      'tree-sitter-parser-parse!
      (%parser-parse
        (tree-sitter-parser-pointer value)
        (snapshot-pointer snapshot))))

  (define (tree-sitter-parser-apply! value change snapshot)
    (require-open 'tree-sitter-parser-apply! value)
    (require-change 'tree-sitter-parser-apply! change)
    (require-snapshot 'tree-sitter-parser-apply! snapshot)
    (check-status
      'tree-sitter-parser-apply!
      (%parser-apply
        (tree-sitter-parser-pointer value)
        (change-pointer change)
        (snapshot-pointer snapshot))))

  (define (tree-sitter-parser-document-id value)
    (require-open 'tree-sitter-parser-document-id value)
    (%parser-document-id (tree-sitter-parser-pointer value)))

  (define (tree-sitter-parser-revision value)
    (require-open 'tree-sitter-parser-revision value)
    (%parser-revision (tree-sitter-parser-pointer value)))

  (define (tree-sitter-parser-root-kind value)
    (require-open 'tree-sitter-parser-root-kind value)
    (or (%parser-root-kind (tree-sitter-parser-pointer value))
        (native-error 'tree-sitter-parser-root-kind)))

  (define (call-range who operation)
    (let ([start (foreign-alloc 4)]
          [end (foreign-alloc 4)])
      (dynamic-wind
        (lambda () (void))
        (lambda ()
          (check-status who (operation start end))
          (cons
            (foreign-ref 'unsigned-32 start 0)
            (foreign-ref 'unsigned-32 end 0)))
        (lambda ()
          (foreign-free start)
          (foreign-free end)))))

  (define (tree-sitter-parser-root-range value)
    (require-open 'tree-sitter-parser-root-range value)
    (call-range
      'tree-sitter-parser-root-range
      (lambda (start end)
        (%parser-root-range
          (tree-sitter-parser-pointer value)
          start
          end))))

  (define (tree-sitter-parser-root-has-error? value)
    (require-open 'tree-sitter-parser-root-has-error? value)
    (let ([status
            (%parser-root-has-error
              (tree-sitter-parser-pointer value))])
      (check-status 'tree-sitter-parser-root-has-error? status)
      (not (zero? status))))

  (define (tree-sitter-parser-query value source start end)
    (require-open 'tree-sitter-parser-query value)
    (unless (string? source)
      (assertion-violation
        'tree-sitter-parser-query
        "query source must be a string"
        source))
    (let ([result
            (%parser-query
              (tree-sitter-parser-pointer value)
              source
              start
              end)])
      (unless result
        (native-error 'tree-sitter-parser-query))
      (dynamic-wind
        (lambda () (void))
        (lambda ()
          (let loop ([index 0]
                     [count (%query-result-count result)]
                     [captures '()])
            (if (= index count)
                (reverse captures)
                (let ([range
                        (call-range
                          'tree-sitter-parser-query
                          (lambda (range-start range-end)
                            (%query-result-range
                              result
                              index
                              range-start
                              range-end)))])
                  (loop
                    (+ index 1)
                    count
                    (cons
                      (make-tree-sitter-capture
                        (string->symbol
                          (%query-result-name result index))
                        (car range)
                        (cdr range)
                        (%query-result-node-kind result index)
                        (%query-result-depth result index))
                      captures))))))
        (lambda () (%query-result-destroy result)))))
)
