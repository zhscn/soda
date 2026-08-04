(library (soda test terminal-clipboard)
  (export run-terminal-clipboard-tests!)
  (import (rnrs)
          (soda host command)
          (soda tui clipboard))

  (define (run-terminal-clipboard-tests!)
    (unless (string=? (osc52-copy-control (string->utf8 "copy") 16)
                      "\x1b;]52;c;Y29weQ==\x7;")
      (error 'terminal-clipboard-tests "OSC 52 encoding differs"))
    (unless (not (osc52-copy-control (string->utf8 "copy") 3))
      (error 'terminal-clipboard-tests "OSC 52 maximum was ignored"))
    (let* ([controls '()]
           [handler
           (make-terminal-clipboard-effect-handler
             (lambda (control) (set! controls (cons control controls))) #t 16)])
      (handler #f #f (make-command-effect 'clipboard.write (string->utf8 "copy")))
      (unless (equal? controls (list "\x1b;]52;c;Y29weQ==\x7;"))
        (error 'terminal-clipboard-tests "clipboard effect did not write OSC 52")))))
