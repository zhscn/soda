(library (soda editor tui)
  (export run-tui-editor render-editor-frame)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor core)
          (soda editor effect)
          (soda editor event)
          (soda runtime)
          (soda tui commands)
          (soda tui input)
          (soda tui presenter)
          (soda tui renderer))

  (define escape (string (integer->char 27)))

  (define (ansi suffix)
    (string-append escape suffix))

  (define (render! terminal editor)
    (let ([size (terminal-size terminal)])
      (editor-update!
        editor
        (make-resize-message
          (max 2 (car size))
          (max 1 (cdr size))))
      (terminal-write!
        terminal
        (frame->ansi
          (render-editor-frame
            editor
            (max 2 (car size))
            (max 1 (cdr size)))))))

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

  (define (call-with-editor bytes resource procedure)
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
              'fundamental-mode))
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
          [decoder (make-input-decoder)]
          [executor (make-effect-executor)])
      (define (cancel-flush-timer!)
        (when flush-timer
          (guard (condition [else #f])
            (runtime-cancel! runtime flush-timer))
          (set! flush-timer #f)))
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
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (terminal-enter-raw! terminal)
          (set! raw? #t)
          (set! screen? #t)
          (terminal-write!
            terminal
            (string-append
              (ansi "[?1049h")
              (ansi "[>1u")
              (ansi "[?2004h")))
          (set! input-source
            (runtime-watch-fd! runtime 0 fd-readable))
          (let loop ([running? #t])
            (when running?
              (render! terminal editor)
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
                  [else (process (cdr events) continue?)])))))
        (lambda ()
          (cancel-flush-timer!)
          (when input-source
            (guard (condition [else #f])
              (runtime-cancel! runtime input-source)))
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
            (lambda (editor)
              (call-with-terminal
                (lambda (terminal)
                  (run-editor-session
                    runtime
                    terminal
                    editor))))))))))
