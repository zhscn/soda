(library (soda editor keymap)
  (export make-key-stroke
          make-character-key-stroke
          key-stroke?
          key-stroke-key
          key-stroke-codepoint
          key-stroke-modifiers
          key-stroke=?
          key-stroke-description
          key-sequence-description
          key-event->key-stroke
          make-keymap
          keymap?
          keymap-parent
          keymap-set-parent!
          keymap-ref
          keymap-set!
          keymap-remove!
          keymap-bind!
          keymap-undefine!
          keymap-unbind!
          keymap-resolve
          keymaps-resolve
          keymap-bindings
          key-binding?
          key-binding-sequence
          key-binding-status
          key-binding-command
          make-keymap-catalog
          keymap-catalog?
          keymap-catalog-snapshot
          keymap-catalog-restore!
          keymap-catalog-register!
          keymap-catalog-find
          keymap-catalog-ref
          keymap-catalog-names)
  (import (rnrs)
          (soda editor event)
          (soda editor ordered-registry))

  (define-record-type key-stroke
    (fields key codepoint modifiers))

  (define (make-character-key-stroke character modifiers)
    (unless (and (char? character)
                 (integer? modifiers)
                 (exact? modifiers)
                 (not (negative? modifiers)))
      (assertion-violation
        'make-character-key-stroke
        "expected a character and modifier mask"
        character modifiers))
    (make-key-stroke
      'character (char->integer character) modifiers))

  (define-record-type (keymap %make-keymap keymap?)
    (fields
      (mutable entries keymap-entries keymap-entries-set!)
      (mutable parent keymap-parent keymap-parent-set!)))

  (define-record-type
    (keymap-catalog %make-keymap-catalog keymap-catalog?)
    (fields registry))

  (define-record-type
    (keymap-state %make-keymap-state keymap-state?)
    (fields keymap entries parent))

  (define-record-type
    (keymap-catalog-state %make-keymap-catalog-state keymap-catalog-state?)
    (fields registry keymaps))

  (define-record-type key-binding
    (fields sequence status command))

  (define (key-stroke=? left right)
    (and (key-stroke? left)
         (key-stroke? right)
         (eq? (key-stroke-key left) (key-stroke-key right))
         (equal? (key-stroke-codepoint left) (key-stroke-codepoint right))
         (= (key-stroke-modifiers left) (key-stroke-modifiers right))))

  (define (modifier-set? modifiers bit)
    (not (zero? (bitwise-and modifiers bit))))

  (define (key-stroke-base-description stroke)
    (let ([key (key-stroke-key stroke)]
          [codepoint (key-stroke-codepoint stroke)])
      (cond
        [(and (eq? key 'character) (integer? codepoint))
         (cond
           [(= codepoint (char->integer #\space)) "SPC"]
           [else (string (integer->char codepoint))])]
        [(symbol? key)
         (string-append "<" (symbol->string key) ">")]
        [else "<unknown>"])))

  (define (key-stroke-description stroke)
    (unless (key-stroke? stroke)
      (assertion-violation
        'key-stroke-description
        "expected a key stroke"
        stroke))
    (let ([modifiers (key-stroke-modifiers stroke)])
      (string-append
        (if (modifier-set? modifiers 4) "C-" "")
        (if (or (modifier-set? modifiers 2)
                (modifier-set? modifiers 32))
            "M-"
            "")
        (if (modifier-set? modifiers 1) "S-" "")
        (if (modifier-set? modifiers 8) "s-" "")
        (if (modifier-set? modifiers 16) "H-" "")
        (key-stroke-base-description stroke))))

  (define (key-sequence-description sequence)
    (unless (and (list? sequence) (for-all key-stroke? sequence))
      (assertion-violation
        'key-sequence-description
        "expected a list of key strokes"
        sequence))
    (let loop ([remaining sequence] [result ""])
      (if (null? remaining)
          result
          (loop
            (cdr remaining)
            (string-append
              result
              (if (zero? (string-length result)) "" " ")
              (key-stroke-description (car remaining)))))))

  (define (key-event->key-stroke event)
    (unless (key-event? event)
      (assertion-violation
        'key-event->key-stroke
        "expected a key event"
        event))
    (let* ([key (key-event-key event)]
           [codepoint (key-event-codepoint event)]
           [shifted (key-event-shifted-codepoint event)]
           [modifiers (key-event-modifiers event)]
           [logical-codepoint
             (if (and (eq? key 'character)
                      (not (zero? (bitwise-and modifiers 1)))
                      (or shifted codepoint)
                      (let ([character
                              (integer->char (or shifted codepoint))])
                        (and (not (char-alphabetic? character))
                             (not (char-whitespace? character)))))
                 (or shifted codepoint)
                 codepoint)]
           [logical-modifiers
             (if (and (eq? key 'character)
                      logical-codepoint
                      (not (equal? logical-codepoint codepoint)))
                 (bitwise-and modifiers (bitwise-not 1))
                 (if (and (eq? key 'character)
                          codepoint
                          (not (zero? (bitwise-and modifiers 1)))
                          (let ([character (integer->char codepoint)])
                            (and (not (char-alphabetic? character))
                                 (not (char-numeric? character))
                                 (not (char-whitespace? character)))))
                     (bitwise-and modifiers (bitwise-not 1))
                     modifiers))])
      (make-key-stroke key logical-codepoint logical-modifiers)))

  (define make-keymap
    (case-lambda
      [() (%make-keymap '() #f)]
      [(parent)
       (unless (or (not parent) (keymap? parent))
         (assertion-violation
           'make-keymap
           "parent must be a keymap or #f"
           parent))
       (%make-keymap '() parent)]))

  (define (make-keymap-catalog)
    (%make-keymap-catalog (make-ordered-registry)))

  (define (copy-keymap-entries entries)
    (map
      (lambda (entry) (cons (car entry) (cdr entry)))
      entries))

  (define (collect-keymap-states roots)
    (let ([seen (make-eq-hashtable)])
      (let visit-list ([remaining roots] [states '()])
        (if (null? remaining)
            states
            (let visit ([keymap (car remaining)] [states states])
              (cond
                [(or (not keymap)
                     (hashtable-contains? seen keymap))
                 (visit-list (cdr remaining) states)]
                [else
                 (hashtable-set! seen keymap #t)
                 (let* ([entries (keymap-entries keymap)]
                        [next
                          (cons
                            (keymap-parent keymap)
                            (filter
                              keymap?
                              (map cdr entries)))]
                        [captured
                          (cons
                            (%make-keymap-state
                              keymap
                              (copy-keymap-entries entries)
                              (keymap-parent keymap))
                            states)])
                   (visit-list
                     (append next (cdr remaining))
                     captured))]))))))

  (define (keymap-catalog-snapshot catalog)
    (unless (keymap-catalog? catalog)
      (assertion-violation
        'keymap-catalog-snapshot
        "expected a keymap catalog"
        catalog))
    (%make-keymap-catalog-state
      (ordered-registry-snapshot (keymap-catalog-registry catalog))
      (collect-keymap-states
        (ordered-registry-values (keymap-catalog-registry catalog)))))

  (define (keymap-catalog-restore! catalog snapshot)
    (unless (keymap-catalog? catalog)
      (assertion-violation
        'keymap-catalog-restore!
        "expected a keymap catalog"
        catalog))
    (unless (keymap-catalog-state? snapshot)
      (assertion-violation
        'keymap-catalog-restore!
        "expected a keymap catalog snapshot"
        snapshot))
    (for-each
      (lambda (state)
        (keymap-entries-set!
          (keymap-state-keymap state)
          (copy-keymap-entries (keymap-state-entries state)))
        (keymap-parent-set!
          (keymap-state-keymap state)
          (keymap-state-parent state)))
      (keymap-catalog-state-keymaps snapshot))
    (ordered-registry-restore!
      (keymap-catalog-registry catalog)
      (keymap-catalog-state-registry snapshot))
    catalog)

  (define (keymap-catalog-register! catalog name keymap)
    (unless (keymap-catalog? catalog)
      (assertion-violation
        'keymap-catalog-register!
        "expected a keymap catalog"
        catalog))
    (unless (symbol? name)
      (assertion-violation
        'keymap-catalog-register!
        "keymap name must be a symbol"
        name))
    (unless (keymap? keymap)
      (assertion-violation
        'keymap-catalog-register!
        "expected a keymap"
        keymap))
    (ordered-registry-set!
      (keymap-catalog-registry catalog) name keymap))

  (define (keymap-catalog-find catalog name)
    (unless (keymap-catalog? catalog)
      (assertion-violation
        'keymap-catalog-find
        "expected a keymap catalog"
        catalog))
    (unless (symbol? name)
      (assertion-violation
        'keymap-catalog-find
        "keymap name must be a symbol"
        name))
    (ordered-registry-ref (keymap-catalog-registry catalog) name))

  (define (keymap-catalog-ref catalog name)
    (or (keymap-catalog-find catalog name)
        (assertion-violation
          'keymap-catalog-ref
          "unknown keymap"
          name)))

  (define (keymap-catalog-names catalog)
    (unless (keymap-catalog? catalog)
      (assertion-violation
        'keymap-catalog-names
        "expected a keymap catalog"
        catalog))
    (ordered-registry-names (keymap-catalog-registry catalog)))

  (define (find-entry keymap stroke)
    (let loop ([entries (keymap-entries keymap)])
      (cond
        [(null? entries) #f]
        [(key-stroke=? stroke (caar entries)) (car entries)]
        [else (loop (cdr entries))])))

  (define (keymap-parent-chain-contains? keymap candidate)
    (let loop ([current candidate])
      (and current
           (or (eq? current keymap)
               (loop (keymap-parent current))))))

  (define (keymap-set-parent! keymap parent)
    (unless (keymap? keymap)
      (assertion-violation
        'keymap-set-parent!
        "expected a keymap"
        keymap))
    (unless (or (not parent) (keymap? parent))
      (assertion-violation
        'keymap-set-parent!
        "parent must be a keymap or #f"
        parent))
    (when (keymap-parent-chain-contains? keymap parent)
      (assertion-violation
        'keymap-set-parent!
        "keymap parent would create a cycle"
        parent))
    (keymap-parent-set! keymap parent)
    parent)

  (define (remove-entry! keymap stroke)
    (let ([entry (find-entry keymap stroke)])
      (when entry
        (keymap-entries-set!
          keymap
          (filter
            (lambda (candidate)
              (not (eq? candidate entry)))
            (keymap-entries keymap))))
      (and entry #t)))

  (define (binding-status definition)
    (cond
      [(not definition) 'undefined]
      [(keymap? definition) 'prefix]
      [else 'command]))

  (define (keymap-ref keymap stroke)
    (unless (keymap? keymap)
      (assertion-violation 'keymap-ref "expected a keymap" keymap))
    (unless (key-stroke? stroke)
      (assertion-violation
        'keymap-ref
        "expected a key stroke"
        stroke))
    (let loop ([current keymap])
      (if (not current)
          (values 'none #f)
          (let ([entry (find-entry current stroke)])
            (if entry
                (values
                  (binding-status (cdr entry))
                  (cdr entry))
                (loop (keymap-parent current)))))))

  (define (keymap-set! keymap stroke definition)
    (unless (keymap? keymap)
      (assertion-violation 'keymap-set! "expected a keymap" keymap))
    (unless (key-stroke? stroke)
      (assertion-violation
        'keymap-set!
        "expected a key stroke"
        stroke))
    (unless (or (not definition)
                (symbol? definition)
                (keymap? definition))
      (assertion-violation
        'keymap-set!
        "definition must be a command symbol, keymap, or #f"
        definition))
    (let ([entry (find-entry keymap stroke)])
      (if entry
          (keymap-entries-set!
            keymap
            (map
              (lambda (candidate)
                (if (eq? candidate entry)
                    (cons (car candidate) definition)
                    candidate))
              (keymap-entries keymap)))
          (keymap-entries-set!
            keymap
            (cons
              (cons stroke definition)
              (keymap-entries keymap)))))
    definition)

  (define (keymap-remove! keymap stroke)
    (unless (keymap? keymap)
      (assertion-violation 'keymap-remove! "expected a keymap" keymap))
    (unless (key-stroke? stroke)
      (assertion-violation
        'keymap-remove!
        "expected a key stroke"
        stroke))
    (remove-entry! keymap stroke))

  (define (local-prefix keymap stroke)
    (let ([entry (find-entry keymap stroke)])
      (and entry (keymap? (cdr entry)) (cdr entry))))

  (define (ensure-prefix! who keymap stroke sequence)
    (let ([entry (find-entry keymap stroke)])
      (cond
        [(and entry (keymap? (cdr entry))) (cdr entry)]
        [entry
         (assertion-violation
           who
           "key sequence starts with a non-prefix binding"
           sequence)]
        [else
         (call-with-values
           (lambda () (keymap-ref keymap stroke))
           (lambda (status definition)
             (cond
               [(eq? status 'prefix)
                (let ([prefix (make-keymap definition)])
                  (keymap-set! keymap stroke prefix)
                  prefix)]
               [(eq? status 'none)
                (let ([prefix (make-keymap)])
                  (keymap-set! keymap stroke prefix)
                  prefix)]
               [else
                (assertion-violation
                  who
                  "key sequence starts with a non-prefix binding"
                  sequence)])))])))

  (define (require-sequence who keymap sequence)
    (unless (keymap? keymap)
      (assertion-violation who "expected a keymap" keymap))
    (unless (and (list? sequence)
                 (pair? sequence)
                 (for-all key-stroke? sequence))
      (assertion-violation
        who
        "key sequence must be a non-empty list of key strokes"
        sequence)))

  (define (set-binding! who keymap sequence binding)
    (require-sequence who keymap sequence)
    (let loop ([current keymap] [remaining sequence])
      (if (null? (cdr remaining))
          (keymap-set! current (car remaining) binding)
          (loop
            (ensure-prefix!
              who
              current
              (car remaining)
              sequence)
            (cdr remaining)))))

  (define (keymap-bind! keymap sequence command)
    (unless (symbol? command)
      (assertion-violation
        'keymap-bind!
        "command name must be a symbol"
        command))
    (set-binding! 'keymap-bind! keymap sequence command)
    command)

  (define (keymap-undefine! keymap sequence)
    (set-binding! 'keymap-undefine! keymap sequence #f)
    #t)

  (define (remove-binding! keymap remaining)
    (let ([stroke (car remaining)])
      (if (null? (cdr remaining))
          (remove-entry! keymap stroke)
          (let ([prefix (local-prefix keymap stroke)])
            (and prefix
                 (remove-binding! prefix (cdr remaining)))))))

  (define (keymap-unbind! keymap sequence)
    (require-sequence 'keymap-unbind! keymap sequence)
    (remove-binding! keymap sequence))

  (define (keymap-resolve keymap sequence)
    (unless (keymap? keymap)
      (assertion-violation 'keymap-resolve "expected a keymap" keymap))
    (unless (and (list? sequence) (for-all key-stroke? sequence))
      (assertion-violation
        'keymap-resolve
        "key sequence must be a list of key strokes"
        sequence))
    (if (null? sequence)
        (values 'prefix #f)
        (let loop ([current keymap] [remaining sequence])
          (call-with-values
            (lambda () (keymap-ref current (car remaining)))
            (lambda (status definition)
              (if (null? (cdr remaining))
                  (values
                    status
                    (if (eq? status 'command) definition #f))
                  (if (eq? status 'prefix)
                      (loop definition (cdr remaining))
                      (values 'none #f))))))))

  (define (keymaps-resolve keymaps sequence)
    (unless (and (list? keymaps) (for-all keymap? keymaps))
      (assertion-violation
        'keymaps-resolve
        "expected a list of keymaps"
        keymaps))
    (let loop ([remaining keymaps])
      (if (null? remaining)
          (values 'none #f)
          (call-with-values
            (lambda () (keymap-resolve (car remaining) sequence))
            (lambda (status command)
              (if (eq? status 'none)
                  (loop (cdr remaining))
                  (values status command)))))))

  (define (prefix-keymap keymap prefix)
    (let loop ([current keymap] [remaining prefix])
      (if (null? remaining)
          current
          (call-with-values
            (lambda () (keymap-ref current (car remaining)))
            (lambda (status definition)
              (and (eq? status 'prefix)
                   (loop definition (cdr remaining))))))))

  (define (collect-bindings keymap sequence bindings)
    (fold-left
      (lambda (state entry)
        (let* ([stroke (car entry)]
               [definition (cdr entry)]
               [binding-sequence
                 (append sequence (list stroke))])
          (cond
            [(keymap? definition)
             (collect-bindings
               definition
               binding-sequence
               state)]
            [definition
             (cons
               (make-key-binding
                 binding-sequence
                 'command
                 definition)
               state)]
            [else
             (cons
               (make-key-binding
                 binding-sequence
                 'undefined
                 #f)
               state)])))
      bindings
      (keymap-entries keymap)))

  (define keymap-bindings
    (case-lambda
      [(keymap) (keymap-bindings keymap '())]
      [(keymap prefix)
       (unless (keymap? keymap)
         (assertion-violation
           'keymap-bindings
           "expected a keymap"
           keymap))
       (unless (and (list? prefix) (for-all key-stroke? prefix))
         (assertion-violation
           'keymap-bindings
           "prefix must be a list of key strokes"
           prefix))
       (let ([prefix-map (prefix-keymap keymap prefix)])
         (if prefix-map
             (reverse
               (collect-bindings prefix-map prefix '()))
             '()))])))
