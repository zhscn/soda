(library (soda tree-sitter)
  (export make-tree-sitter-parser
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
          tree-sitter-query-source
          make-tree-sitter-query
          tree-sitter-query?
          tree-sitter-query-close!
          tree-sitter-query-execute
          tree-sitter-parser-query
          tree-sitter-capture?
          tree-sitter-capture-name
          tree-sitter-capture-start
          tree-sitter-capture-end
          tree-sitter-capture-node-kind
          tree-sitter-capture-depth
          tree-sitter-capture-match-id
          tree-sitter-capture-pattern-index
          tree-sitter-capture-properties)
  (import (chezscheme)
          (soda document)
          (soda document handles)
          (soda native)
          (soda tree-sitter handles))

  (define native-library-loaded
    (load-soda-native-library! "SODA_TREE_SITTER_LIBRARY"))

  (define-record-type tree-sitter-capture
    (fields name
            start
            end
            node-kind
            depth
            match-id
            pattern-index
            properties))

  (define %abi-version
    (foreign-procedure
      __atomic "soda_tree_sitter_abi_version" () unsigned-32))
  (define %last-error
    (foreign-procedure
      __atomic "soda_tree_sitter_last_error" () string))
  (define %language-available
    (foreign-procedure
      __atomic "soda_ts_language_available"
      (string)
      int))
  (define %parser-create
    (foreign-procedure
      __atomic "soda_ts_parser_create"
      (string)
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
  (define %query-source
    (foreign-procedure
      __atomic "soda_ts_query_source" (string string) string))
  (define %query-compile
    (foreign-procedure
      __atomic "soda_ts_query_compile" (void* string) void*))
  (define %query-destroy
    (foreign-procedure
      __atomic "soda_ts_query_destroy" (void*) void))
  (define %query-execute
    (foreign-procedure
      __atomic "soda_ts_query_execute"
      (void* void* unsigned-32 unsigned-32)
      void*))
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
  (define %query-result-match-id
    (foreign-procedure
      __atomic "soda_ts_query_result_match_id"
      (void* unsigned-32)
      unsigned-32))
  (define %query-result-pattern-index
    (foreign-procedure
      __atomic "soda_ts_query_result_pattern_index"
      (void* unsigned-32)
      unsigned-32))
  (define %query-result-property-count
    (foreign-procedure
      __atomic "soda_ts_query_result_property_count"
      (void* unsigned-32)
      unsigned-32))
  (define %query-result-property-key
    (foreign-procedure
      __atomic "soda_ts_query_result_property_key"
      (void* unsigned-32 unsigned-32)
      string))
  (define %query-result-property-value
    (foreign-procedure
      __atomic "soda_ts_query_result_property_value"
      (void* unsigned-32 unsigned-32)
      string))

  (define abi-version-checked
    (unless (= (%abi-version) 1)
      (error
        'soda-tree-sitter
        "unsupported native Tree-sitter ABI version")))

  (define native-error (make-native-error %last-error))

  (define (null-pointer? pointer)
    (or
      (not pointer)
      (and (integer? pointer) (zero? pointer))))

  (define check-status (make-native-status-checker native-error))

  (define (require-open who value)
    (unless (tree-sitter-parser? value)
      (assertion-violation who "expected a Tree-sitter parser" value))
    (unless (tree-sitter-parser-pointer value)
      (assertion-violation who "Tree-sitter parser is closed" value)))

  (define (require-open-query who value)
    (unless (tree-sitter-query? value)
      (assertion-violation who "expected a Tree-sitter query" value))
    (unless (tree-sitter-query-pointer value)
      (assertion-violation who "Tree-sitter query is closed" value)))

  (define (require-snapshot who value)
    (unless (and (snapshot? value) (snapshot-pointer value))
      (assertion-violation who "expected an open snapshot" value)))

  (define (require-change who value)
    (unless (and (change? value) (change-pointer value))
      (assertion-violation who "expected an open change" value)))

  (define (tree-sitter-language-available? language)
    (unless (symbol? language)
      (assertion-violation
        'tree-sitter-language-available?
        "language must be a symbol"
        language))
    (positive?
      (%language-available
        (symbol->string language))))

  (define (make-tree-sitter-parser language)
    (unless (symbol? language)
      (assertion-violation
        'make-tree-sitter-parser
        "language must be a symbol"
        language))
    (let ([pointer
            (%parser-create
              (symbol->string language))])
      (when (null-pointer? pointer)
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

  (define (tree-sitter-query-source language query-name)
    (unless (symbol? language)
      (assertion-violation
        'tree-sitter-query-source
        "language must be a symbol"
        language))
    (unless (symbol? query-name)
      (assertion-violation
        'tree-sitter-query-source
        "query name must be a symbol"
        query-name))
    (let ([source
            (%query-source
              (symbol->string language)
              (symbol->string query-name))])
      (unless source
        (native-error 'tree-sitter-query-source))
      source))

  (define (make-tree-sitter-query parser source)
    (require-open 'make-tree-sitter-query parser)
    (unless (string? source)
      (assertion-violation
        'make-tree-sitter-query
        "query source must be a string"
        source))
    (let ([pointer
            (%query-compile
              (tree-sitter-parser-pointer parser)
              source)])
      (when (null-pointer? pointer)
        (native-error 'make-tree-sitter-query))
      (%make-tree-sitter-query pointer)))

  (define (tree-sitter-query-close! query)
    (unless (tree-sitter-query? query)
      (assertion-violation
        'tree-sitter-query-close!
        "expected a Tree-sitter query"
        query))
    (let ([pointer (tree-sitter-query-pointer query)])
      (when pointer
        (%query-destroy pointer)
        (tree-sitter-query-pointer-set! query #f))))

  (define (query-result->captures who result)
    (when (null-pointer? result)
      (native-error who))
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
                        who
                        (lambda (range-start range-end)
                          (%query-result-range
                            result
                            index
                            range-start
                            range-end)))]
                    [properties
                      (let ([property-count
                              (%query-result-property-count
                                result index)])
                        (when (= property-count #xffffffff)
                          (native-error who))
                        (let property-loop
                          ([property-index 0]
                           [values '()])
                          (if (= property-index property-count)
                              (reverse values)
                              (let ([key
                                      (%query-result-property-key
                                        result
                                        index
                                        property-index)]
                                    [value
                                      (%query-result-property-value
                                        result
                                        index
                                        property-index)])
                                (unless (and key value)
                                  (native-error who))
                                (property-loop
                                  (+ property-index 1)
                                  (cons
                                    (cons
                                      (string->symbol key)
                                      value)
                                    values))))))])
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
                      (%query-result-depth result index)
                      (%query-result-match-id result index)
                      (%query-result-pattern-index result index)
                      properties)
                    captures))))))
      (lambda () (%query-result-destroy result))))

  (define (tree-sitter-query-execute query parser start end)
    (require-open-query 'tree-sitter-query-execute query)
    (require-open 'tree-sitter-query-execute parser)
    (query-result->captures
      'tree-sitter-query-execute
      (%query-execute
        (tree-sitter-parser-pointer parser)
        (tree-sitter-query-pointer query)
        start
        end)))

  (define (tree-sitter-parser-query value source start end)
    (require-open 'tree-sitter-parser-query value)
    (unless (string? source)
      (assertion-violation
        'tree-sitter-parser-query
        "query source must be a string"
        source))
    (query-result->captures
      'tree-sitter-parser-query
      (%parser-query
        (tree-sitter-parser-pointer value)
        source
        start
        end)))
)
