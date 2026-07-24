(library (soda cpp-analysis)
  (export make-cpp-analyzer
          cpp-analyzer?
          cpp-analyzer-close!
          cpp-analyzer-analyze!
          cpp-analyzer-apply!
          cpp-analyzer-document-id
          cpp-analyzer-revision
          cpp-analyzer-node-count
          cpp-analyzer-root
          cpp-analyzer-node-at
          cpp-analyzer-node-kind
          cpp-analyzer-node-range
          cpp-analyzer-node-parent
          cpp-analyzer-node-child-count
          cpp-analyzer-node-child
          cpp-analyzer-node-incomplete?
          cpp-analyzer-sexp-forward
          cpp-analyzer-sexp-backward
          cpp-analyzer-enclosing-list
          cpp-analyzer-matching-bracket-range
          cpp-analyzer-expand-selection
          cpp-analyzer-soft-kill-end)
  (import (chezscheme)
          (soda cpp-analysis handles)
          (soda document handles))

  (define shared-library
    (let ([path (or (getenv "SODA_CPP_ANALYSIS_LIBRARY")
                    "libsoda_cpp_analysis.so")])
      (load-shared-object path)
      path))

  (define syntax-node-none #xffffffff)
  (define revision-none #xffffffffffffffff)

  (define syntax-kinds
    '#(translation-unit
       preprocessor-directive
       namespace-decl
       namespace-body
       class-decl
       class-body
       access-specifier-label
       opaque-declaration
       function-definition
       ctor-initializer-list
       ctor-initializer
       paren-group
       bracket-group
       brace-group
       template-argument-list
       compound-statement
       if-statement
       else-clause
       for-statement
       while-statement
       do-statement
       switch-statement
       case-section
       case-label
       pp-reopened-scope
       missing-token
       error))

  (define %abi-version
    (foreign-procedure __atomic "soda_cpp_analysis_abi_version" () unsigned-32))
  (define %last-error
    (foreign-procedure __atomic "soda_cpp_analysis_last_error" () string))

  (define abi-version-checked
    (unless (= (%abi-version) 1)
      (error 'soda-cpp-analysis "unsupported native C++ analysis ABI version")))

  (define %analyzer-create
    (foreign-procedure __atomic "soda_cpp_analyzer_create" () void*))
  (define %analyzer-destroy
    (foreign-procedure __atomic "soda_cpp_analyzer_destroy" (void*) void))
  (define %analyzer-analyze
    (foreign-procedure __atomic "soda_cpp_analyzer_analyze" (void* void*) int))
  (define %analyzer-apply
    (foreign-procedure __atomic "soda_cpp_analyzer_apply"
                       (void* void* void*)
                       int))
  (define %analyzer-document-id
    (foreign-procedure __atomic "soda_cpp_analyzer_document_id"
                       (void*)
                       unsigned-32))
  (define %analyzer-revision
    (foreign-procedure __atomic "soda_cpp_analyzer_revision"
                       (void*)
                       unsigned-64))
  (define %analyzer-node-count
    (foreign-procedure __atomic "soda_cpp_analyzer_node_count"
                       (void*)
                       unsigned-32))
  (define %analyzer-root
    (foreign-procedure __atomic "soda_cpp_analyzer_root" (void*) unsigned-32))
  (define %analyzer-node-at
    (foreign-procedure __atomic "soda_cpp_analyzer_node_at"
                       (void* unsigned-32)
                       unsigned-32))
  (define %analyzer-node-kind
    (foreign-procedure __atomic "soda_cpp_analyzer_node_kind"
                       (void* unsigned-32)
                       int))
  (define %analyzer-node-range
    (foreign-procedure __atomic "soda_cpp_analyzer_node_range"
                       (void* unsigned-32 void* void*)
                       int))
  (define %analyzer-node-parent
    (foreign-procedure __atomic "soda_cpp_analyzer_node_parent"
                       (void* unsigned-32)
                       unsigned-32))
  (define %analyzer-node-child-count
    (foreign-procedure __atomic "soda_cpp_analyzer_node_child_count"
                       (void* unsigned-32)
                       unsigned-32))
  (define %analyzer-node-child
    (foreign-procedure __atomic "soda_cpp_analyzer_node_child"
                       (void* unsigned-32 unsigned-32)
                       unsigned-32))
  (define %analyzer-node-incomplete
    (foreign-procedure __atomic "soda_cpp_analyzer_node_incomplete"
                       (void* unsigned-32)
                       int))
  (define %analyzer-sexp-forward
    (foreign-procedure __atomic "soda_cpp_analyzer_sexp_forward"
                       (void* unsigned-32 void* void*)
                       int))
  (define %analyzer-sexp-backward
    (foreign-procedure __atomic "soda_cpp_analyzer_sexp_backward"
                       (void* unsigned-32 void* void*)
                       int))
  (define %analyzer-enclosing-list
    (foreign-procedure __atomic "soda_cpp_analyzer_enclosing_list"
                       (void* unsigned-32 void* void*)
                       int))
  (define %analyzer-matching-bracket-range
    (foreign-procedure __atomic "soda_cpp_analyzer_matching_bracket_range"
                       (void* unsigned-32 void* void*)
                       int))
  (define %analyzer-expand-selection
    (foreign-procedure __atomic "soda_cpp_analyzer_expand_selection"
                       (void* unsigned-32 unsigned-32 void* void*)
                       int))
  (define %analyzer-soft-kill-end
    (foreign-procedure __atomic "soda_cpp_analyzer_soft_kill_end"
                       (void* unsigned-32 void* void*)
                       int))

  (define (native-error who)
    (error who (%last-error)))

  (define (check-status who status)
    (when (negative? status)
      (native-error who)))

  (define (require-open who value)
    (unless (cpp-analyzer? value)
      (assertion-violation who "expected a C++ analyzer" value))
    (unless (cpp-analyzer-pointer value)
      (assertion-violation who "C++ analyzer is closed" value)))

  (define (require-snapshot who value)
    (unless (snapshot? value)
      (assertion-violation who "expected a document snapshot" value))
    (unless (snapshot-pointer value)
      (assertion-violation who "document snapshot is closed" value)))

  (define (require-change who value)
    (unless (change? value)
      (assertion-violation who "expected a document change" value))
    (unless (change-pointer value)
      (assertion-violation who "document change is closed" value)))

  (define (checked-node who node)
    (if (= node syntax-node-none) (native-error who) node))

  (define (call-range who optional? operation)
    (let ([start (foreign-alloc 4)]
          [end (foreign-alloc 4)])
      (dynamic-wind
        (lambda () (void))
        (lambda ()
          (let ([status (operation start end)])
            (cond
              [(negative? status) (native-error who)]
              [(and optional? (zero? status)) #f]
              [else
               (cons (foreign-ref 'unsigned-32 start 0)
                     (foreign-ref 'unsigned-32 end 0))])))
        (lambda ()
          (foreign-free start)
          (foreign-free end)))))

  (define (make-cpp-analyzer)
    (let ([pointer (%analyzer-create)])
      (unless pointer
        (native-error 'make-cpp-analyzer))
      (%make-cpp-analyzer pointer)))

  (define (cpp-analyzer-close! value)
    (when (and (cpp-analyzer? value) (cpp-analyzer-pointer value))
      (%analyzer-destroy (cpp-analyzer-pointer value))
      (cpp-analyzer-pointer-set! value #f)))

  (define (cpp-analyzer-analyze! value snapshot)
    (require-open 'cpp-analyzer-analyze! value)
    (require-snapshot 'cpp-analyzer-analyze! snapshot)
    (check-status
      'cpp-analyzer-analyze!
      (%analyzer-analyze
        (cpp-analyzer-pointer value)
        (snapshot-pointer snapshot))))

  (define (cpp-analyzer-apply! value change after)
    (require-open 'cpp-analyzer-apply! value)
    (require-change 'cpp-analyzer-apply! change)
    (require-snapshot 'cpp-analyzer-apply! after)
    (check-status
      'cpp-analyzer-apply!
      (%analyzer-apply
        (cpp-analyzer-pointer value)
        (change-pointer change)
        (snapshot-pointer after))))

  (define (cpp-analyzer-document-id value)
    (require-open 'cpp-analyzer-document-id value)
    (let ([id (%analyzer-document-id (cpp-analyzer-pointer value))])
      (let ([message (%last-error)])
        (if (string=? message "") id (error 'cpp-analyzer-document-id message)))))

  (define (cpp-analyzer-revision value)
    (require-open 'cpp-analyzer-revision value)
    (let ([revision (%analyzer-revision (cpp-analyzer-pointer value))])
      (if (= revision revision-none)
          (native-error 'cpp-analyzer-revision)
          revision)))

  (define (cpp-analyzer-node-count value)
    (require-open 'cpp-analyzer-node-count value)
    (checked-node
      'cpp-analyzer-node-count
      (%analyzer-node-count (cpp-analyzer-pointer value))))

  (define (cpp-analyzer-root value)
    (require-open 'cpp-analyzer-root value)
    (checked-node
      'cpp-analyzer-root
      (%analyzer-root (cpp-analyzer-pointer value))))

  (define (cpp-analyzer-node-at value offset)
    (require-open 'cpp-analyzer-node-at value)
    (checked-node
      'cpp-analyzer-node-at
      (%analyzer-node-at (cpp-analyzer-pointer value) offset)))

  (define (cpp-analyzer-node-kind value node)
    (require-open 'cpp-analyzer-node-kind value)
    (let ([kind (%analyzer-node-kind (cpp-analyzer-pointer value) node)])
      (if (negative? kind)
          (native-error 'cpp-analyzer-node-kind)
          (vector-ref syntax-kinds kind))))

  (define (cpp-analyzer-node-range value node)
    (require-open 'cpp-analyzer-node-range value)
    (call-range
      'cpp-analyzer-node-range
      #f
      (lambda (start end)
        (%analyzer-node-range
          (cpp-analyzer-pointer value)
          node
          start
          end))))

  (define (cpp-analyzer-node-parent value node)
    (require-open 'cpp-analyzer-node-parent value)
    (let ([parent (%analyzer-node-parent (cpp-analyzer-pointer value) node)])
      (if (= parent syntax-node-none)
          (let ([message (%last-error)])
            (if (string=? message "") #f (error 'cpp-analyzer-node-parent message)))
          parent)))

  (define (cpp-analyzer-node-child-count value node)
    (require-open 'cpp-analyzer-node-child-count value)
    (checked-node
      'cpp-analyzer-node-child-count
      (%analyzer-node-child-count (cpp-analyzer-pointer value) node)))

  (define (cpp-analyzer-node-child value node index)
    (require-open 'cpp-analyzer-node-child value)
    (checked-node
      'cpp-analyzer-node-child
      (%analyzer-node-child (cpp-analyzer-pointer value) node index)))

  (define (cpp-analyzer-node-incomplete? value node)
    (require-open 'cpp-analyzer-node-incomplete? value)
    (let ([incomplete (%analyzer-node-incomplete
                        (cpp-analyzer-pointer value)
                        node)])
      (if (negative? incomplete)
          (native-error 'cpp-analyzer-node-incomplete?)
          (not (zero? incomplete)))))

  (define (optional-query who value operation)
    (require-open who value)
    (call-range who #t operation))

  (define (cpp-analyzer-sexp-forward value from)
    (optional-query
      'cpp-analyzer-sexp-forward
      value
      (lambda (start end)
        (%analyzer-sexp-forward
          (cpp-analyzer-pointer value)
          from
          start
          end))))

  (define (cpp-analyzer-sexp-backward value from)
    (optional-query
      'cpp-analyzer-sexp-backward
      value
      (lambda (start end)
        (%analyzer-sexp-backward
          (cpp-analyzer-pointer value)
          from
          start
          end))))

  (define (cpp-analyzer-enclosing-list value offset)
    (optional-query
      'cpp-analyzer-enclosing-list
      value
      (lambda (start end)
        (%analyzer-enclosing-list
          (cpp-analyzer-pointer value)
          offset
          start
          end))))

  (define (cpp-analyzer-matching-bracket-range value offset)
    (optional-query
      'cpp-analyzer-matching-bracket-range
      value
      (lambda (start end)
        (%analyzer-matching-bracket-range
          (cpp-analyzer-pointer value)
          offset
          start
          end))))

  (define (cpp-analyzer-expand-selection value selection)
    (unless (and (pair? selection)
                 (integer? (car selection))
                 (integer? (cdr selection)))
      (assertion-violation
        'cpp-analyzer-expand-selection
        "expected a pair of byte offsets"
        selection))
    (optional-query
      'cpp-analyzer-expand-selection
      value
      (lambda (start end)
        (%analyzer-expand-selection
          (cpp-analyzer-pointer value)
          (car selection)
          (cdr selection)
          start
          end))))

  (define (cpp-analyzer-soft-kill-end value from)
    (require-open 'cpp-analyzer-soft-kill-end value)
    (call-range
      'cpp-analyzer-soft-kill-end
      #f
      (lambda (start end)
        (%analyzer-soft-kill-end
          (cpp-analyzer-pointer value)
          from
          start
          end)))))
