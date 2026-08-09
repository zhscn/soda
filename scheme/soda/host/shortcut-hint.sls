(library (soda host shortcut-hint)
  (export command-shortcut-hints)
  (import (rnrs)
          (soda host command)
          (soda host command-runtime-registry)
          (soda host input)
          (soda host input-event))

  (define (key-stroke-label stroke)
    (let* ([modifiers (key-stroke-modifiers stroke)]
           [prefix
            (string-append
              (if (zero? (bitwise-and modifiers 4)) "" "C-")
              (if (zero? (bitwise-and modifiers 2)) "" "M-")
              (if (zero? (bitwise-and modifiers 1)) "" "S-"))]
           [key
            (if (key-stroke-codepoint stroke)
                (string (integer->char (key-stroke-codepoint stroke)))
                (symbol->string (key-stroke-key stroke)))])
      (string-append prefix key)))

  (define (key-sequence-label sequence)
    (let loop ([remaining sequence] [result ""])
      (if (null? remaining)
          result
          (loop (cdr remaining)
                (string-append result (if (zero? (string-length result)) "" " ")
                               (key-stroke-label (car remaining)))))))

  (define (sequence-prefix? prefix sequence)
    (let loop ([left prefix] [right sequence])
      (or (null? left)
          (and (pair? right)
               (key-stroke=? (car left) (car right))
               (loop (cdr left) (cdr right))))))

  (define (sequence-take sequence count)
    (if (zero? count) '()
        (cons (car sequence) (sequence-take (cdr sequence) (- count 1)))))

  (define (remapped-command layers name)
    (let loop ([remaining layers])
      (if (null? remaining)
          name
          (or (keymap-remap (input-layer-keymap (car remaining)) name #f)
              (loop (cdr remaining))))))

  ;; Hints are a projection of the same ranked InputLayers used by dispatch.
  ;; Shadowing, remapping, prefix continuations, and command availability are
  ;; resolved before a frontend receives the immutable label pairs.
  (define (command-shortcut-hints runtime command-context input-context)
    (unless (and (command-runtime? runtime) (command-context? command-context)
                 (input-context? input-context))
      (assertion-violation 'command-shortcut-hints
                           "expected a runtime, command context, and input context"))
    (let* ([layers (input-context-layers input-context)]
           [pending
            (or (input-stack-pending-sequence (input-context-stack input-context)) '())]
           [sequences
            (fold-left append '()
              (map (lambda (layer)
                     (map car (keymap-binding-entries (input-layer-keymap layer))))
                   layers))]
           [candidates
            (fold-left
              (lambda (result sequence)
                (let* ([resolved (resolve-key-sequence layers sequence)]
                       [shown
                        (if (and (pair? pending)
                                 (sequence-prefix? pending sequence)
                                 (> (length sequence) (length pending)))
                            (sequence-take sequence (+ 1 (length pending)))
                            sequence)]
                       [shown-resolution (resolve-key-sequence layers shown)]
                       [label (key-sequence-label shown)])
                  (if (and (eq? (car resolved) 'command)
                           (or (null? pending)
                               (and (> (length sequence) (length pending))
                                    (sequence-prefix? pending sequence)))
                           (not (exists (lambda (hint) (string=? (car hint) label))
                                        result)))
                      (let* ([full-name (remapped-command layers (cadr resolved))]
                             [full-definition
                              (command-runtime-command-definition runtime full-name #f)]
                             [name
                              (and (eq? (car shown-resolution) 'command)
                                   (remapped-command layers (cadr shown-resolution)))]
                             [definition
                              (and (symbol? name)
                                   (command-runtime-command-definition runtime name #f))])
                        (if (and full-definition
                                 (command-runtime-command-available?
                                   runtime full-definition command-context)
                                 (or (eq? (car shown-resolution) 'prefix)
                                     (and definition
                                          (command-runtime-command-available?
                                            runtime definition command-context))))
                            (cons (cons label
                                        (if name (symbol->string name) "prefix"))
                                  result)
                            result))
                      result)))
              '() sequences)])
      (list-sort (lambda (left right) (string<? (car left) (car right)))
                 candidates)))
)
