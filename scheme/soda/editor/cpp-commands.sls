(library (soda editor cpp-commands)
  (export install-cpp-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor command-target)
          (soda editor condition)
          (soda editor cpp-language)
          (soda editor edit)
          (soda editor editor-storage)
          (soda editor keymap)
          (soda editor view)
          (soda indentation))

  (define style-properties
    '(indent-width
      continuation-indent
      tab-width
      use-tabs?
      align-open-bracket?
      brace-init-continuation?
      indent-wrapped-function-names?
      align-operands?
      break-before-ternary?
      namespace-indentation
      indent-type-body?
      indent-case-label?
      indent-case-body?
      access-specifier-offset
      pp-directive-indent
      pp-indent-width
      constructor-initializers))

  (define (make-buffer-indent-style buffer)
    (let ([style (make-cpp-indent-style)]
          [missing (list 'missing)]
          [complete? #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (for-each
            (lambda (property)
              (let ([value
                      (buffer-setting-ref
                        buffer property missing)])
                (unless (eq? value missing)
                  (cpp-indent-style-set!
                    style property value))))
            style-properties)
          (set! complete? #t)
          style)
        (lambda ()
          (unless complete?
            (cpp-indent-style-close! style))))))

  (define (require-cpp-session buffer)
    (let ([session (buffer-language-session buffer)])
      (unless (cpp-language-session? session)
        (assertion-violation
          'cpp-command
          "active buffer has no C++ language session"
          (buffer-major-mode-name buffer)))
      session))

  (define (require-non-negative-count who context)
    (let ([count (command-context-count context)])
      (when (negative? count)
        (assertion-violation
          who
          "command requires a non-negative prefix argument"
          count))
      count))

  (define line-target-reader
    (make-command-target-reader
      'cpp-line-target
      (make-command-target-selector
        'ignore
        #f
        command-context-line-target)))

  (define replace-target-reader
    (make-command-target-reader
      'cpp-newline-target
      (make-command-target-selector
        'prefer
        #t
        command-context-point-target)))

  (define (native-enter-once! buffer view session style)
    (let ([result #f] [change #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (set! result
            (cpp-press-enter!
              (buffer-document buffer)
              (cpp-language-session-analyzer session)
              (view-caret view)
              style))
          (set! change
            (indent-result-take-change! result))
          (buffer-adopt-change! buffer change)
          (view-set-caret!
            view
            (indent-result-caret result)))
        (lambda ()
          (when change (change-close! change))
          (when result (indent-result-close! result))))))

  (define-command (cpp-newline-command context target)
    "Insert newlines with the native C++ indentation engine."
    (interactive replace-target-reader)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)]
           [session (require-cpp-session buffer)]
           [count
             (require-non-negative-count
               'cpp.newline-and-indent
               context)]
           [style #f])
      (require-command-target-current
        'cpp.newline-and-indent buffer target)
      (when (positive? count)
        (view-set-caret!
          view
          (command-target-start target))
        (unless (command-target-empty? target)
          (buffer-delete-range!
            buffer
            (command-target-start target)
            (command-target-end target)))
        (when (eq? (command-target-source target) 'region)
          (view-clear-mark! view))
        (dynamic-wind
          (lambda () #f)
          (lambda ()
            (set! style (make-buffer-indent-style buffer))
            (do ([index 0 (+ index 1)])
                ((= index count))
              (native-enter-once!
                buffer view session style)))
          (lambda ()
            (when style
              (cpp-indent-style-close! style)))))
      '()))

  (define (line-whitespace-end text line)
    (let ([start (text-line-start text line)]
          [end (text-line-content-end text line)])
      (let loop ([offset start])
        (if
          (and
            (< offset end)
            (memv (text-byte-at text offset) '(9 32)))
          (loop (+ offset 1))
          offset))))

  (define (indent-one-line! buffer session style line caret)
    (let ([snapshot #f]
          [text #f]
          [result #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (set! snapshot
            (document-snapshot
              (buffer-document buffer)))
          (set! text (snapshot-text snapshot))
          (if (>= line (text-line-count text))
              caret
              (let* ([line-start (text-line-start text line)]
                     [whitespace-end
                       (line-whitespace-end text line)])
                (set! result
                  (cpp-language-compute-indent
                    session snapshot line style))
                (if (indent-result-preserve? result)
                    caret
                    (let* ([indentation
                             (string->utf8
                               (indent-result-indentation result))]
                           [old-length
                             (- whitespace-end line-start)]
                           [new-length
                             (bytevector-length indentation)]
                           [delta (- new-length old-length)])
                      (buffer-replace-range!
                        buffer
                        line-start
                        whitespace-end
                        indentation)
                      (cond
                        [(< caret line-start) caret]
                        [(<= caret whitespace-end)
                         (+ line-start new-length)]
                        [else (+ caret delta)]))))))
        (lambda ()
          (when result (indent-result-close! result))
          (when text (text-close! text))
          (when snapshot (snapshot-close! snapshot))))))

  (define-command (cpp-indent-line-command context target)
    "Indent C++ source lines beginning with the frozen target line."
    (interactive line-target-reader)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)]
           [session (require-cpp-session buffer)]
           [count
             (require-non-negative-count
               'cpp.indent-line
               context)]
           [start-line
             (command-target-property-ref
               target 'line)]
           [style #f]
           [caret (command-target-point target)])
      (require-command-target-current
        'cpp.indent-line buffer target)
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (set! style (make-buffer-indent-style buffer))
          (do ([index 0 (+ index 1)])
              ((= index count))
            (set! caret
              (indent-one-line!
                buffer
                session
                style
                (+ start-line index)
                caret)))
          (view-set-caret! view caret))
        (lambda ()
          (when style
            (cpp-indent-style-close! style))))
      '()))

  (define (install-cpp-commands! editor)
    (editor-register-command!
      editor
      (make-interactive-context-command
        'cpp.newline-and-indent
        cpp-newline-command
        "Insert a newline using the native C++ indentation engine."))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'cpp.indent-line
        cpp-indent-line-command
        "Indent C++ source lines using the native analyzer."))
    (let ([keymap (make-keymap)])
      (keymap-bind!
        keymap
        (list (make-key-stroke 'enter 13 0))
        'cpp.newline-and-indent)
      (keymap-bind!
        keymap
        (list (make-key-stroke 'tab 9 0))
        'cpp.indent-line)
      (keymap-catalog-register!
        (editor-keymap-catalog editor)
        'cpp-mode-map
        keymap))
    editor))
