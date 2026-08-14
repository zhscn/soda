(library (soda packages command-presentation)
  (export command-context-keymaps
          command-access?
          command-access-definition
          command-access-key-sequences
          command-context-command-accesses
          command-context-command-access
          key-sequence-name
          join-strings)
  (import (rnrs)
          (soda kernel extension)
          (soda kernel state)
          (soda host command)
          (soda host command-runtime)
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

  ;; Presentation queries use the same semantic layer ordering as input
  ;; dispatch.  Fallbacks therefore retain their InputLayer ranks instead of
  ;; being flattened into unranked Keymaps.
  (define (command-context-keymaps context fallback-layers)
    (unless (and (command-context? context)
                 (list? fallback-layers)
                 (for-all input-layer? fallback-layers))
      (assertion-violation
        'command-context-keymaps
        "expected a CommandContext and fallback InputLayers"
        context fallback-layers))
    (let ([state (command-context-buffer-state context)])
      (map input-layer-keymap
           (input-layer-compose
             (append
               (if state
                   (configuration-facet
                     (buffer-state-configuration state)
                     buffer-input-layers-facet 'buffer)
                   '())
               fallback-layers)))))

  ;; A CommandAccess is the canonical user-facing projection for one command
  ;; in one context.  An empty key sequence list means it is available only
  ;; through M-x.  Command UI surfaces share this projection instead of
  ;; independently filtering the registry or reinterpreting Keymaps.
  (define-record-type
    (command-access %make-command-access command-access?)
    (fields (immutable definition command-access-definition)
            (immutable key-sequences command-access-key-sequences)))

  (define (access<? left right)
    (string<?
      (symbol->string
        (command-definition-name (command-access-definition left)))
      (symbol->string
        (command-definition-name (command-access-definition right)))))

  (define (command-context-command-accesses runtime context fallback-layers)
    (unless (command-runtime? runtime)
      (assertion-violation 'command-context-command-accesses
                           "expected a CommandRuntime" runtime))
    (let ([keymaps (command-context-keymaps context fallback-layers)])
      (list-sort
        access<?
        (map
          (lambda (definition)
            (%make-command-access
              definition
              (keymap-where-is keymaps (command-definition-name definition))))
          (command-runtime-available-user-command-definitions runtime context)))))

  (define (command-context-command-access runtime context fallback-layers name)
    (unless (symbol? name)
      (assertion-violation 'command-context-command-access
                           "expected a command name" name))
    (find
      (lambda (access)
        (eq? (command-definition-name (command-access-definition access)) name))
      (command-context-command-accesses runtime context fallback-layers)))
)
