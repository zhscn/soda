(library (soda indentation)
  (export make-cpp-indent-style
          cpp-indent-style?
          cpp-indent-style-close!
          cpp-indent-style-ref
          cpp-indent-style-set!
          cpp-compute-line-indent
          cpp-press-enter!
          cpp-type-char!
          indent-result?
          indent-result-close!
          indent-result-target-column
          indent-result-role
          indent-result-preserve?
          indent-result-anchor
          indent-result-caret
          indent-result-reindented?
          indent-result-handler
          indent-result-indentation
          indent-result-trace
          indent-result-take-change!)
  (import (chezscheme)
          (soda native)
          (soda cpp-analysis handles)
          (soda document handles))

  (define text-npos #xffffffff)

  (define format-roles
    '#(file
       namespace-body
       type-body
       access-specifier-label
       function-body
       compound-body
       lambda-body
       single-statement-body
       control-header-continuation
       case-label
       case-body
       constructor-initializer-intro
       constructor-initializer-item
       paren-continuation
       bracket-continuation
       template-args-continuation
       brace-init
       statement-continuation
       preprocessor-directive
       closing-token
       preserved-raw-string
       preserved-block-comment
       opaque))

  (define style-properties
    '((indent-width . 0)
      (continuation-indent . 1)
      (tab-width . 2)
      (use-tabs? . 3)
      (align-open-bracket? . 4)
      (brace-init-continuation? . 5)
      (indent-wrapped-function-names? . 6)
      (align-operands? . 7)
      (break-before-ternary? . 8)
      (namespace-indentation . 9)
      (indent-type-body? . 10)
      (indent-case-label? . 11)
      (indent-case-body? . 12)
      (access-specifier-offset . 13)
      (pp-directive-indent . 14)
      (pp-indent-width . 15)
      (constructor-initializers . 16)))

  (define boolean-properties
    '(use-tabs?
      align-open-bracket?
      brace-init-continuation?
      indent-wrapped-function-names?
      align-operands?
      break-before-ternary?
      indent-type-body?
      indent-case-label?
      indent-case-body?))

  (define namespace-values '((none . 0) (inner . 1) (all . 2)))
  (define pp-values '((none . 0) (after-hash . 1) (before-hash . 2)))
  (define constructor-values
    '((normal-indent . 0)
      (continuation-indent . 1)
      (align-first-initializer . 2)
      (align-after-colon . 3)
      (align-with-colon . 4)))

  (define %abi-version
    (foreign-procedure __atomic "soda_indentation_abi_version" () unsigned-32))
  (define %last-error
    (foreign-procedure __atomic "soda_indentation_last_error" () string))

  (define abi-version-checked
    (unless (= (%abi-version) 1)
      (error 'soda-indentation "unsupported native indentation ABI version")))

  (define %style-create
    (foreign-procedure __atomic "soda_cpp_indent_style_create" () void*))
  (define %style-destroy
    (foreign-procedure __atomic "soda_cpp_indent_style_destroy" (void*) void))
  (define %style-get
    (foreign-procedure __atomic "soda_cpp_indent_style_get"
                       (void* int void*)
                       int))
  (define %style-set
    (foreign-procedure __atomic "soda_cpp_indent_style_set"
                       (void* int int)
                       int))
  (define %compute-line-indent
    (foreign-procedure __atomic "soda_cpp_compute_line_indent"
                       (void* void* unsigned-32 void*)
                       void*))
  (define %press-enter
    (foreign-procedure __atomic "soda_cpp_press_enter"
                       (void* void* unsigned-32 void*)
                       void*))
  (define %type-char
    (foreign-procedure __atomic "soda_cpp_type_char"
                       (void* void* unsigned-32 unsigned-8 void*)
                       void*))
  (define %result-destroy
    (foreign-procedure __atomic "soda_indent_result_destroy" (void*) void))
  (define %result-target-column
    (foreign-procedure __atomic "soda_indent_result_target_column" (void*) int))
  (define %result-role
    (foreign-procedure __atomic "soda_indent_result_role" (void*) int))
  (define %result-preserve
    (foreign-procedure __atomic "soda_indent_result_preserve" (void*) int))
  (define %result-anchor
    (foreign-procedure __atomic "soda_indent_result_anchor" (void*) unsigned-32))
  (define %result-caret
    (foreign-procedure __atomic "soda_indent_result_caret" (void*) unsigned-32))
  (define %result-reindented
    (foreign-procedure __atomic "soda_indent_result_reindented" (void*) int))
  (define %result-handler
    (foreign-procedure __atomic "soda_indent_result_handler" (void*) string))
  (define %result-indentation-size
    (foreign-procedure __atomic "soda_indent_result_indentation_size"
                       (void*)
                       unsigned-32))
  (define %result-copy-indentation
    (foreign-procedure __atomic "soda_indent_result_copy_indentation"
                       (void* u8* size_t)
                       int))
  (define %result-trace-count
    (foreign-procedure __atomic "soda_indent_result_trace_count"
                       (void*)
                       unsigned-32))
  (define %result-trace
    (foreign-procedure __atomic "soda_indent_result_trace"
                       (void* unsigned-32)
                       string))
  (define %result-take-change
    (foreign-procedure __atomic "soda_indent_result_take_change" (void*) void*))

  (define-record-type (cpp-indent-style %make-cpp-indent-style cpp-indent-style?)
    (fields (mutable pointer)))
  (define-record-type (indent-result %make-indent-result indent-result?)
    (fields (mutable pointer)))

  (define native-error (make-native-error %last-error))

  (define check-status (make-native-status-checker native-error))

  (define (require-style who value)
    (unless (cpp-indent-style? value)
      (assertion-violation who "expected a C++ indent style" value))
    (unless (cpp-indent-style-pointer value)
      (assertion-violation who "C++ indent style is closed" value)))

  (define (require-result who value)
    (unless (indent-result? value)
      (assertion-violation who "expected an indent result" value))
    (unless (indent-result-pointer value)
      (assertion-violation who "indent result is closed" value)))

  (define (require-analyzer who value)
    (unless (cpp-analyzer? value)
      (assertion-violation who "expected a C++ analyzer" value))
    (unless (cpp-analyzer-pointer value)
      (assertion-violation who "C++ analyzer is closed" value)))

  (define (require-document who value)
    (unless (document? value)
      (assertion-violation who "expected a document" value))
    (unless (document-pointer value)
      (assertion-violation who "document is closed" value)))

  (define (require-snapshot who value)
    (unless (snapshot? value)
      (assertion-violation who "expected a document snapshot" value))
    (unless (snapshot-pointer value)
      (assertion-violation who "document snapshot is closed" value)))

  (define (property-id who property)
    (let ([entry (assq property style-properties)])
      (unless entry
        (assertion-violation who "unknown indent style property" property))
      (cdr entry)))

  (define (enum-value who table value)
    (let ([entry (assq value table)])
      (unless entry
        (assertion-violation who "invalid style property value" value))
      (cdr entry)))

  (define (enum-name who table value)
    (let ([entry (find (lambda (entry) (= (cdr entry) value)) table)])
      (unless entry
        (error who "native style property value is invalid" value))
      (car entry)))

  (define (encode-property who property value)
    (cond
      [(memq property boolean-properties) (if value 1 0)]
      [(eq? property 'namespace-indentation)
       (enum-value who namespace-values value)]
      [(eq? property 'pp-directive-indent)
       (enum-value who pp-values value)]
      [(eq? property 'constructor-initializers)
       (enum-value who constructor-values value)]
      [(integer? value) value]
      [else (assertion-violation who "expected an integer style value" value)]))

  (define (decode-property who property value)
    (cond
      [(memq property boolean-properties) (not (zero? value))]
      [(eq? property 'namespace-indentation)
       (enum-name who namespace-values value)]
      [(eq? property 'pp-directive-indent)
       (enum-name who pp-values value)]
      [(eq? property 'constructor-initializers)
       (enum-name who constructor-values value)]
      [else value]))

  (define (make-cpp-indent-style)
    (let ([pointer (%style-create)])
      (unless pointer
        (native-error 'make-cpp-indent-style))
      (%make-cpp-indent-style pointer)))

  (define (cpp-indent-style-close! value)
    (when (and (cpp-indent-style? value) (cpp-indent-style-pointer value))
      (%style-destroy (cpp-indent-style-pointer value))
      (cpp-indent-style-pointer-set! value #f)))

  (define (cpp-indent-style-ref value property)
    (require-style 'cpp-indent-style-ref value)
    (let ([output (foreign-alloc (foreign-sizeof 'int))])
      (dynamic-wind
        (lambda () (void))
        (lambda ()
          (check-status
            'cpp-indent-style-ref
            (%style-get
              (cpp-indent-style-pointer value)
              (property-id 'cpp-indent-style-ref property)
              output))
          (decode-property
            'cpp-indent-style-ref
            property
            (foreign-ref 'int output 0)))
        (lambda () (foreign-free output)))))

  (define (cpp-indent-style-set! style property value)
    (require-style 'cpp-indent-style-set! style)
    (check-status
      'cpp-indent-style-set!
      (%style-set
        (cpp-indent-style-pointer style)
        (property-id 'cpp-indent-style-set! property)
        (encode-property 'cpp-indent-style-set! property value))))

  (define (wrap-result who pointer)
    (unless pointer
      (native-error who))
    (%make-indent-result pointer))

  (define (cpp-compute-line-indent snapshot analyzer line style)
    (require-snapshot 'cpp-compute-line-indent snapshot)
    (require-analyzer 'cpp-compute-line-indent analyzer)
    (require-style 'cpp-compute-line-indent style)
    (wrap-result
      'cpp-compute-line-indent
      (%compute-line-indent
        (snapshot-pointer snapshot)
        (cpp-analyzer-pointer analyzer)
        line
        (cpp-indent-style-pointer style))))

  (define (cpp-press-enter! document analyzer caret style)
    (require-document 'cpp-press-enter! document)
    (require-analyzer 'cpp-press-enter! analyzer)
    (require-style 'cpp-press-enter! style)
    (wrap-result
      'cpp-press-enter!
      (%press-enter
        (document-pointer document)
        (cpp-analyzer-pointer analyzer)
        caret
        (cpp-indent-style-pointer style))))

  (define (cpp-type-char! document analyzer caret character style)
    (require-document 'cpp-type-char! document)
    (require-analyzer 'cpp-type-char! analyzer)
    (require-style 'cpp-type-char! style)
    (unless (char? character)
      (assertion-violation 'cpp-type-char! "expected a character" character))
    (let ([byte (char->integer character)])
      (when (> byte #xff)
        (assertion-violation
          'cpp-type-char!
          "native typed-character command accepts one UTF-8 byte"
          character))
      (wrap-result
        'cpp-type-char!
        (%type-char
          (document-pointer document)
          (cpp-analyzer-pointer analyzer)
          caret
          byte
          (cpp-indent-style-pointer style)))))

  (define (indent-result-close! value)
    (when (and (indent-result? value) (indent-result-pointer value))
      (%result-destroy (indent-result-pointer value))
      (indent-result-pointer-set! value #f)))

  (define (indent-result-target-column value)
    (require-result 'indent-result-target-column value)
    (let ([column (%result-target-column (indent-result-pointer value))])
      (if (negative? column)
          (native-error 'indent-result-target-column)
          column)))

  (define (indent-result-role value)
    (require-result 'indent-result-role value)
    (let ([role (%result-role (indent-result-pointer value))])
      (if (negative? role)
          (native-error 'indent-result-role)
          (vector-ref format-roles role))))

  (define (native-boolean who result)
    (let ([value (result)])
      (if (negative? value) (native-error who) (not (zero? value)))))

  (define (indent-result-preserve? value)
    (require-result 'indent-result-preserve? value)
    (native-boolean
      'indent-result-preserve?
      (lambda () (%result-preserve (indent-result-pointer value)))))

  (define (optional-offset who operation)
    (let ([offset (operation)])
      (if (= offset text-npos)
          (let ([message (%last-error)])
            (if (string=? message "") #f (error who message)))
          offset)))

  (define (indent-result-anchor value)
    (require-result 'indent-result-anchor value)
    (optional-offset
      'indent-result-anchor
      (lambda () (%result-anchor (indent-result-pointer value)))))

  (define (indent-result-caret value)
    (require-result 'indent-result-caret value)
    (optional-offset
      'indent-result-caret
      (lambda () (%result-caret (indent-result-pointer value)))))

  (define (indent-result-reindented? value)
    (require-result 'indent-result-reindented? value)
    (native-boolean
      'indent-result-reindented?
      (lambda () (%result-reindented (indent-result-pointer value)))))

  (define (indent-result-handler value)
    (require-result 'indent-result-handler value)
    (let ([handler (%result-handler (indent-result-pointer value))])
      (unless handler
        (native-error 'indent-result-handler))
      (if (string=? handler "") #f handler)))

  (define (indent-result-indentation value)
    (require-result 'indent-result-indentation value)
    (let ([size (%result-indentation-size (indent-result-pointer value))])
      (when (= size text-npos)
        (native-error 'indent-result-indentation))
      (let ([output (make-bytevector size)])
        (check-status
          'indent-result-indentation
          (%result-copy-indentation
            (indent-result-pointer value)
            output
            size))
        (utf8->string output))))

  (define (indent-result-trace value)
    (require-result 'indent-result-trace value)
    (let ([count (%result-trace-count (indent-result-pointer value))])
      (when (= count text-npos)
        (native-error 'indent-result-trace))
      (do ([index 0 (+ index 1)]
           [trace '()
                  (let ([line (%result-trace
                                (indent-result-pointer value)
                                index)])
                    (unless line
                      (native-error 'indent-result-trace))
                    (cons line trace))])
          ((= index count) (reverse trace)))))

  (define (indent-result-take-change! value)
    (require-result 'indent-result-take-change! value)
    (let ([pointer (%result-take-change (indent-result-pointer value))])
      (unless pointer
        (native-error 'indent-result-take-change!))
      (%make-change pointer))))
