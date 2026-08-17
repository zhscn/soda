(library (soda packages word-completion)
  (export make-word-completion-service!
          word-completion-service?
          word-completion-keymap
          word-completion-related-buffers?)
  (import (rnrs)
          (rnrs sorting)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda host buffer)
          (soda host command)
          (soda host input)
          (soda host input-event)
          (soda host package)
          (soda host package-context)
          (soda host setting)
          (soda host value)
          (soda packages completion)
          (soda packages interaction))

  (define-record-type word-completion-service
    (fields host owner (immutable keymap word-completion-keymap)))

  (define (first-value values default)
    (if (null? values) default (car values)))

  (define related-buffers-facet
    (make-facet 'word-completion-related-buffers 'buffer #t
                (lambda (values) (first-value values #t)) eq? eq?))

  (define (word-completion-related-buffers? configuration)
    (configuration-facet configuration related-buffers-facet 'buffer))

  (define (parse-boolean input)
    (cond
      [(boolean? input) input]
      [(and (string? input)
            (member (string-downcase input) '("true" "yes" "on" "1"))) #t]
      [(and (string? input)
            (member (string-downcase input) '("false" "no" "off" "0"))) #f]
      [else 'invalid]))

  (define (word-character? character)
    (or (char-alphabetic? character)
        (char-numeric? character)
        (char=? character #\_)))

  (define (word-prefix context)
    (let* ([point
            (selection-range-head
              (selection-primary-range
                (view-state-selection (command-context-view-state context))))]
           [document (buffer-state-document (command-context-buffer-state context))]
           [before
            (utf8->string
              (let ([result (make-bytevector point)])
                (bytevector-copy! (snapshot-bytevector document) 0 result 0 point)
                result))]
           [start
            (let loop ([index (string-length before)])
              (if (and (positive? index)
                       (word-character? (string-ref before (- index 1))))
                  (loop (- index 1))
                  index))])
      (values (substring before start (string-length before)) point)))

  (define (string-words text)
    (let loop ([index 0] [start #f] [words '()])
      (cond
        [(= index (string-length text))
         (reverse
           (if start
               (cons (substring text start index) words)
               words))]
        [(word-character? (string-ref text index))
         (loop (+ index 1) (or start index) words)]
        [else
         (loop (+ index 1) #f
               (if start (cons (substring text start index) words) words))])))

  (define (string-prefix? prefix value)
    (and (<= (string-length prefix) (string-length value))
         (string=? prefix (substring value 0 (string-length prefix)))))

  (define (candidate-words service context prefix)
    (let* ([origin-id (command-context-buffer-id context)]
           [configuration (buffer-state-configuration
                            (command-context-buffer-state context))]
           [buffers
            (if (word-completion-related-buffers? configuration)
                (package-host-buffers (word-completion-service-host service))
                (let ([buffer
                       (package-host-buffer-ref
                         (word-completion-service-host service) origin-id #f)])
                  (if buffer (list buffer) '())))]
           [seen (make-hashtable string-hash string=?)])
      (for-each
        (lambda (buffer)
          (for-each
            (lambda (word)
              (when (and (positive? (string-length prefix))
                         (string-prefix? prefix word)
                         (not (string=? prefix word)))
                (hashtable-set! seen word #t)))
            (string-words
              (utf8->string
                (snapshot-bytevector
                  (buffer-state-document (buffer-state buffer)))))))
        buffers)
      (list-sort string<? (vector->list (hashtable-keys seen)))))

  (define (make-word-source service context)
    (make-completion-source
      (lambda (snapshot)
        (let ([words
               (candidate-words service context (prompt-snapshot-input snapshot))])
          (let loop ([remaining words] [index 0])
            (if (null? remaining)
                '()
                (cons
                  (make-completion-candidate
                    (car remaining) (car remaining) (car remaining)
                    #f "Buffer words" (car remaining))
                  (loop (cdr remaining) (+ index 1)))))))
      #f #f #f
      (lambda (input snapshot)
        (member input (candidate-words service context
                                      (prompt-snapshot-input snapshot))))))

  (define (make-word-reader service)
    (make-interactive-reader
      'buffer-word
      (lambda (context arguments)
        (if (pair? arguments)
            (make-interactive-ready '())
            (call-with-values
              (lambda () (word-prefix context))
              (lambda (prefix point)
                (if (zero? (string-length prefix))
                    (assertion-violation 'word.complete
                                         "point is not after a word prefix")
                    (make-interactive-suspend
                      (make-interaction-request
                        'word-completion "Complete word: " prefix
                        (make-word-source service context) 'must-match)
                      (lambda (value)
                        (make-interactive-ready (list value)))))))))))

  (define (complete-word context replacement)
    (unless (string? replacement)
      (assertion-violation 'word.complete
                           "expected a completed word" replacement))
    (call-with-values
      (lambda () (word-prefix context))
      (lambda (prefix point)
        (let* ([inserted (string->utf8 replacement)]
               [from (- point (bytevector-length (string->utf8 prefix)))]
               [state (command-context-buffer-state context)]
               [selection
                (make-selection
                  (list
                    (make-selection-range
                      (+ from (bytevector-length inserted))
                      (+ from (bytevector-length inserted)))))])
          (make-transaction-spec
            (command-context-buffer-id context)
            (command-context-view-id context)
            (buffer-state-generation state)
            (make-change-set
              (snapshot-byte-size (buffer-state-document state))
              (list (make-text-change from point inserted)))
            selection '() '())))))

  (define (make-word-completion-service! host package-context)
    (unless (and (package-host? host)
                 (package-context? package-context)
                 (package-context-host? package-context host))
      (assertion-violation 'make-word-completion-service!
                           "expected a PackageHost and its PackageContext"
                           host package-context))
    (let* ([owner (package-context-owner package-context)]
           [keymap (make-keymap 'word-completion)]
           [service (make-word-completion-service host owner keymap)])
      (package-host-register-setting-schema!
        host owner
        (make-setting-schema
          'completion.related-buffers 'boolean #t '(buffer) parse-boolean #f
          (lambda (value scope)
            (make-facet-provider related-buffers-facet value))))
      (define-package-command
        package-context 'word.complete (context prefix)
        (documentation "Complete the word before point from words in editor Buffers.")
        (class 'completion)
        (scope 'mode)
        (interactive (make-interactive-plan (list (make-word-reader service))))
        (repeatable #t)
        (undo 'amalgamate)
        (complete-word context prefix))
      (keymap-bind! keymap (list (make-key-stroke 'tab #f 2)) 'word.complete)
      service))
)
