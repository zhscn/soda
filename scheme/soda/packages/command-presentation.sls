(library (soda packages command-presentation)
  (export command-context-keymaps key-sequence-name join-strings)
  (import (rnrs)
          (soda kernel extension)
          (soda kernel state)
          (soda host command)
          (soda host input)
          (soda host input-event)
          (soda packages buffer-mode))

  (define (join-strings strings separator)
    (if (null? strings)
        ""
        (let loop ([remaining (cdr strings)] [result (car strings)])
          (if (null? remaining)
              result
              (loop (cdr remaining)
                    (string-append result separator (car remaining)))))))

  (define (modifier-prefix modifiers)
    (string-append
      (if (zero? (bitwise-and modifiers 4)) "" "C-")
      (if (zero? (bitwise-and modifiers 2)) "" "M-")
      (if (zero? (bitwise-and modifiers 1)) "" "S-")
      (if (zero? (bitwise-and modifiers 8)) "" "s-")))

  (define (stroke-name stroke)
    (let ([codepoint (key-stroke-codepoint stroke)])
      (string-append
        (modifier-prefix (key-stroke-modifiers stroke))
        (if codepoint
            (string (integer->char codepoint))
            (string-append "<" (symbol->string (key-stroke-key stroke)) ">")))))

  (define (key-sequence-name sequence)
    (join-strings
      (map (lambda (key)
             (if (key-stroke? key) (stroke-name key)
                 (if (symbol? key) (symbol->string key) key)))
           sequence)
      " "))

  (define (command-context-keymaps context fallback-keymaps)
    (let ([state (command-context-buffer-state context)])
      (append
        (if state
            (map input-layer-keymap
                 (configuration-facet
                   (buffer-state-configuration state)
                   buffer-input-layers-facet 'buffer))
            '())
        fallback-keymaps)))
)
