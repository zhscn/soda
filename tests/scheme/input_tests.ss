#!r6rs
(import (rnrs)
        (soda editor event)
        (soda tui input))

(define (ascii value)
  (string->utf8 value))

(define (bytes . values)
  (let ([result (make-bytevector (length values))])
    (do ([index 0 (+ index 1)]
         [rest values (cdr rest)])
        ((null? rest) result)
      (bytevector-u8-set! result index (car rest)))))

(define decoder (make-input-decoder))

(unless (null? (input-decoder-feed! decoder (bytes #x1b #x5b #x31)))
  (error 'input-tests "incomplete CSI sequence produced an event"))

(define ctrl-q
  (input-decoder-feed! decoder (ascii "13;5u")))
(unless (and (= (length ctrl-q) 1)
             (eq? (key-event-key (car ctrl-q)) 'character)
             (= (key-event-codepoint (car ctrl-q)) 113)
             (key-event-modifier? (car ctrl-q) 'ctrl)
             (eq? (key-event-type (car ctrl-q)) 'press))
  (error 'input-tests "Kitty ctrl-q differs" ctrl-q))

(define enhanced
  (input-decoder-feed! decoder (ascii "\x1b;[97:65:97;6:2;65u")))
(let ([event (car enhanced)])
  (unless (and (= (key-event-codepoint event) 97)
               (= (key-event-shifted-codepoint event) 65)
               (= (key-event-base-layout-codepoint event) 97)
               (key-event-modifier? event 'shift)
               (key-event-modifier? event 'ctrl)
               (eq? (key-event-type event) 'repeat)
               (bytevector=? (key-event-text event) (ascii "A")))
    (error 'input-tests "enhanced Kitty event differs" event)))

(define left
  (input-decoder-feed! decoder (ascii "\x1b;[1;5D")))
(unless (and (eq? (key-event-key (car left)) 'left)
             (key-event-modifier? (car left) 'ctrl))
  (error 'input-tests "modified legacy arrow differs" left))

(define legacy-backtab
  (input-decoder-feed! decoder (bytes #x1b #x5b #x5a)))
(unless
  (and
    (= (length legacy-backtab) 1)
    (eq? (key-event-key (car legacy-backtab)) 'tab)
    (= (key-event-codepoint (car legacy-backtab)) 9)
    (key-event-modifier? (car legacy-backtab) 'shift))
  (error 'input-tests "legacy backtab differs" legacy-backtab))

(define ss3-f3
  (input-decoder-feed! decoder (bytes #x1b #x4f #x52)))
(unless (eq? (key-event-key (car ss3-f3)) 'f3)
  (error 'input-tests "SS3 function key differs" ss3-f3))

(define alt-x
  (input-decoder-feed! decoder (bytes #x1b #x78)))
(unless (and (eq? (key-event-key (car alt-x)) 'character)
             (= (key-event-codepoint (car alt-x)) 120)
             (key-event-modifier? (car alt-x) 'alt)
             (bytevector=?
               (key-event-text (car alt-x))
               (ascii "x")))
  (error 'input-tests "legacy Alt prefix differs" alt-x))

(define utf8-bytes (string->utf8 "λ"))
(unless (null?
          (input-decoder-feed!
            decoder
            (bytes (bytevector-u8-ref utf8-bytes 0))))
  (error 'input-tests "partial UTF-8 produced an event"))
(define utf8-event
  (input-decoder-feed!
    decoder
    (bytes (bytevector-u8-ref utf8-bytes 1))))
(unless (and (eq? (key-event-key (car utf8-event)) 'character)
             (= (key-event-codepoint (car utf8-event))
                (char->integer #\λ))
             (bytevector=?
               (key-event-text (car utf8-event))
               utf8-bytes))
  (error 'input-tests "split UTF-8 differs" utf8-event))

(define legacy-ctrl-q
  (input-decoder-feed! decoder (bytes 17)))
(unless (and (= (key-event-codepoint (car legacy-ctrl-q)) 113)
             (key-event-modifier? (car legacy-ctrl-q) 'ctrl))
  (error 'input-tests "legacy ctrl-q differs" legacy-ctrl-q))

(define legacy-alt-backspace
  (input-decoder-feed! decoder (bytes 27 127)))
(unless
  (and
    (= (length legacy-alt-backspace) 1)
    (eq? (key-event-key (car legacy-alt-backspace)) 'backspace)
    (= (key-event-codepoint (car legacy-alt-backspace)) 127)
    (key-event-modifier? (car legacy-alt-backspace) 'alt))
  (error
    'input-tests
    "legacy alt-backspace differs"
    legacy-alt-backspace))

(unless (null? (input-decoder-feed! decoder (bytes 27)))
  (error 'input-tests "pending escape produced an event"))
(unless (input-decoder-pending? decoder)
  (error 'input-tests "pending escape was not observable"))
(define flushed-escape (input-decoder-flush! decoder))
(unless (and (= (length flushed-escape) 1)
             (eq? (key-event-key (car flushed-escape)) 'escape)
             (not (input-decoder-pending? decoder)))
  (error 'input-tests "standalone escape did not flush" flushed-escape))

(define invalid-utf8
  (input-decoder-feed! decoder (bytes #xff)))
(unless (and (= (length invalid-utf8) 1)
             (eq? (key-event-key (car invalid-utf8)) 'character)
             (= (key-event-codepoint (car invalid-utf8)) #xfffd)
             (bytevector=?
               (key-event-text (car invalid-utf8))
               (string->utf8 (string (integer->char #xfffd)))))
  (error 'input-tests "invalid UTF-8 was not replaced" invalid-utf8))

(unless
  (null?
    (input-decoder-feed!
      decoder
      (bytes #x1b #x5b #x32 #x30 #x30 #x7e
             #x61 #x11 #x1b #x5b #x32)))
  (error 'input-tests "incomplete bracketed paste produced an event"))
(define paste-events
  (input-decoder-feed!
    decoder
    (bytes #x30 #x31 #x7e #x71)))
(unless (and (= (length paste-events) 2)
             (text-input-event? (car paste-events))
             (eq? (text-input-event-kind (car paste-events)) 'paste)
             (bytevector=?
               (text-input-event-text (car paste-events))
               (bytes #x61 #x11))
             (key-event? (cadr paste-events))
             (= (key-event-codepoint (cadr paste-events)) 113))
  (error 'input-tests "bracketed paste was not atomic" paste-events))
