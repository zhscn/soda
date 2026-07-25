(library (soda editor tui)
  (export run-tui-editor render-editor-frame)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor core)
          (soda editor completion-runtime)
          (soda editor effect)
          (soda editor event)
          (soda editor file-runtime)
          (soda editor repl)
          (soda runtime)
          (soda tui commands)
          (soda tui input)
          (soda tui presenter)
          (soda tui renderer))

  (define escape (string (integer->char 27)))

  (define (ansi suffix)
    (string-append escape suffix))

  (define (render! terminal editor previous-frame write!)
    (let ([size (terminal-size terminal)])
      (editor-update!
        editor
        (make-resize-message
          (max 2 (car size))
          (max 1 (cdr size))))
      (let ([frame
              (render-editor-frame
                editor
                (max 2 (car size))
                (max 1 (cdr size)))])
        (write! (frame-diff->ansi previous-frame frame))
        frame)))

  (define (handle-editor-message! editor executor message)
    (let loop ([messages (list message)])
      (if (null? messages)
          #t
          (let* ([effects (editor-update! editor (car messages))]
                 [result (execute-effects! executor effects)])
            (and
              (effect-result-continue? result)
              (loop
                (append
                  (effect-result-messages result)
                  (cdr messages))))))))

  (define (handle-input-events editor executor events)
    (let loop ([events events])
      (if (null? events)
          #t
          (and
            (handle-editor-message!
              editor
              executor
              (make-input-message (car events)))
            (loop (cdr events))))))

  (define (load-bytes runtime path)
    (if (not path)
        (make-bytevector 0)
        (let ([source (runtime-read-file! runtime path)])
          (let loop ()
            (let find ([events (runtime-poll! runtime)])
              (cond
                [(null? events) (loop)]
                [(and (= (event-source (car events)) source)
                      (eq? (event-kind (car events)) 'file-read))
                 (if (negative? (event-status (car events)))
                     (error 'run-tui-editor "cannot read file" path)
                     (event-data (car events)))]
                [else (find (cdr events))]))))))

  (define (detect-file-line-ending bytes)
    (let loop ([index 0])
      (cond
        [(= index (bytevector-length bytes)) 'lf]
        [(= (bytevector-u8-ref bytes index) 13)
         (if (and (< (+ index 1) (bytevector-length bytes))
                  (= (bytevector-u8-ref bytes (+ index 1)) 10))
             'crlf
             'cr)]
        [(= (bytevector-u8-ref bytes index) 10) 'lf]
        [else (loop (+ index 1))])))

  (define (string-suffix? suffix value)
    (and
      (<= (string-length suffix) (string-length value))
      (string=?
        suffix
        (substring
          value
          (- (string-length value) (string-length suffix))
          (string-length value)))))

  (define (initial-major-mode path)
    (let ([normalized (and path (string-foldcase path))])
      (if (and
            normalized
            (exists
              (lambda (suffix)
                (string-suffix? suffix normalized))
              '(".scm" ".ss" ".sls" ".sps")))
          'scheme-mode
          'fundamental-mode)))

  (define (call-with-runtime procedure)
    (let ([runtime #f])
      (dynamic-wind
        (lambda ()
          #f)
        (lambda ()
          (set! runtime (make-runtime))
          (procedure runtime))
        (lambda ()
          (when runtime
            (guard (condition [else #f])
              (runtime-close! runtime)))))))

  (define (call-with-terminal procedure)
    (let ([terminal #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (set! terminal (make-terminal))
          (procedure terminal))
        (lambda ()
          (when terminal
            (guard (condition [else #f])
              (terminal-close! terminal)))))))

  (define (call-with-editor bytes resource file-path procedure)
    (let ([document #f] [buffer #f] [editor #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (set! document (make-document bytes 1))
          (set! buffer
            (make-buffer
              1
              document
              resource
              (initial-major-mode file-path)))
          (buffer-set-local-setting!
            buffer
            'file-line-ending
            (detect-file-line-ending bytes))
          (when file-path
            (buffer-set-file-path! buffer file-path))
          (set! editor (make-editor buffer))
          (install-tui-commands! editor)
          (procedure editor))
        (lambda ()
          (cond
            [editor
             (guard (condition [else #f])
               (editor-close! editor))]
            [buffer
             (guard (condition [else #f])
               (buffer-close! buffer))]
            [document
             (guard (condition [else #f])
               (document-close! document))])))))

  (define (run-editor-session runtime terminal editor)
    (let ([input-source #f]
          [flush-timer #f]
          [raw? #f]
          [screen? #f]
          [previous-frame #f]
          [pending-output #f]
          [pending-output-offset 0]
          [output-source #f]
          [decoder (make-input-decoder)]
          [executor (make-effect-executor)]
          [file-adapter #f])
      (define (cancel-flush-timer!)
        (when flush-timer
          (guard (condition [else #f])
            (runtime-cancel! runtime flush-timer))
          (set! flush-timer #f)))
      (define (cancel-output-source!)
        (when output-source
          (guard (condition [else #f])
            (runtime-cancel! runtime output-source))
          (set! output-source #f)))
      (define (clear-pending-output!)
        (set! pending-output #f)
        (set! pending-output-offset 0)
        (cancel-output-source!))
      (define (arm-output-source!)
        (unless output-source
          (set! output-source
            (runtime-watch-fd! runtime 1 fd-writable))))
      (define (flush-output!)
        (let loop ()
          (when pending-output
            (let ([written
                    (terminal-write-some!
                      terminal
                      pending-output
                      pending-output-offset)])
              (cond
                [(not written) (arm-output-source!)]
                [(zero? written)
                 (if (= pending-output-offset
                        (bytevector-length pending-output))
                     (clear-pending-output!)
                     (arm-output-source!))]
                [else
                 (set! pending-output-offset
                   (+ pending-output-offset written))
                 (if (= pending-output-offset
                        (bytevector-length pending-output))
                     (clear-pending-output!)
                     (loop))])))))
      (define (append-output! data)
        (let* ([bytes
                 (if (bytevector? data)
                     data
                     (string->utf8 data))]
               [remaining
                 (if pending-output
                     (- (bytevector-length pending-output)
                        pending-output-offset)
                     0)]
               [combined
                 (make-bytevector
                   (+ remaining (bytevector-length bytes)))])
          (when (positive? remaining)
            (bytevector-copy!
              pending-output
              pending-output-offset
              combined
              0
              remaining))
          (bytevector-copy!
            bytes
            0
            combined
            remaining
            (bytevector-length bytes))
          (set! pending-output combined)
          (set! pending-output-offset 0)
          (flush-output!)))
      (define (drain-output!)
        (when pending-output
          (let* ([remaining
                   (- (bytevector-length pending-output)
                      pending-output-offset)]
                 [bytes (make-bytevector remaining)])
            (bytevector-copy!
              pending-output
              pending-output-offset
              bytes
              0
              remaining)
            (terminal-write! terminal bytes))
          (clear-pending-output!)))
      (define (arm-flush-timer!)
        (cancel-flush-timer!)
        (when (input-decoder-pending? decoder)
          (set! flush-timer
            (runtime-start-timer! runtime 25 0))))
      (define (handle-input!)
        (let ([input (terminal-read terminal)])
          (if (zero? (bytevector-length input))
              #t
              (let ([events (input-decoder-feed! decoder input)])
                (arm-flush-timer!)
                (handle-input-events editor executor events)))))
      (define (handle-flush!)
        (set! flush-timer #f)
        (handle-input-events
          editor
          executor
          (input-decoder-flush! decoder)))
      (register-effect-handler!
        executor
        'quit
        (lambda (payload) (make-effect-result #f '())))
      (set! file-adapter
        (install-file-runtime! executor runtime))
      (install-interaction-effect-handler! executor editor)
      (install-completion-effect-handlers!
        executor
        (editor-completion-provider-catalog editor))
      (install-prompt-effect-handler! executor)
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (terminal-enter-raw! terminal)
          (set! raw? #t)
          (set! screen? #t)
          (append-output!
            (string-append
              (ansi "[?1049h")
              (ansi "[>1u")
              (ansi "[?2004h")))
          (set! input-source
            (runtime-watch-fd! runtime 0 fd-readable))
          (let loop ([running? #t])
            (when running?
              (set! previous-frame
                (render!
                  terminal
                  editor
                  previous-frame
                  append-output!))
              (let process
                ([events (runtime-poll! runtime)] [continue? #t])
                (cond
                  [(or (not continue?) (null? events))
                   (loop continue?)]
                  [(and (= (event-source (car events)) input-source)
                        (eq? (event-kind (car events)) 'fd-ready))
                   (process (cdr events) (handle-input!))]
                  [(and flush-timer
                        (= (event-source (car events)) flush-timer)
                        (eq? (event-kind (car events)) 'timer))
                   (process (cdr events) (handle-flush!))]
                  [(and output-source
                        (= (event-source (car events)) output-source)
                        (eq? (event-kind (car events)) 'fd-ready))
                   (flush-output!)
                   (process (cdr events) continue?)]
                  [(eq? (event-kind (car events)) 'file-write)
                   (let ([message
                           (file-runtime-handle-event
                             file-adapter
                             (car events))])
                     (process
                       (cdr events)
                       (and
                         continue?
                         (or
                           (not message)
                           (handle-editor-message!
                             editor
                             executor
                             message)))))]
                  [else (process (cdr events) continue?)])))))
        (lambda ()
          (cancel-flush-timer!)
          (when input-source
            (guard (condition [else #f])
              (runtime-cancel! runtime input-source)))
          (guard (condition [else #f])
            (drain-output!))
          (when screen?
            (guard (condition [else #f])
              (terminal-write!
                terminal
                (string-append
                  (ansi "[<u")
                  (ansi "[?2004l")
                  (ansi "[?25h")
                  (ansi "[?1049l")))))
          (when raw?
            (guard (condition [else #f])
              (terminal-leave-raw! terminal)))))))

  (define (run-tui-editor path)
    (call-with-runtime
      (lambda (runtime)
        (let ([bytes (load-bytes runtime path)])
          (call-with-editor
            bytes
            (or path "*scratch*")
            path
            (lambda (editor)
              (call-with-terminal
                (lambda (terminal)
                  (run-editor-session
                    runtime
                    terminal
                    editor))))))))))
