(library (soda host input)
  (export make-keymap
          keymap?
          keymap-name
          keymap-bind!
          keymap-unbind!
          keymap-lookup
          keymap-binding-entries
          keymap-where-is
          keymap-prefix?
          keymap-remap!
          keymap-remap
          make-input-state
          input-state?
          input-state-name
          input-state-keymaps
          input-state-text-policy
          make-input-session
          input-session?
          input-session-state
          input-session-transient?
          make-input-stack
          input-stack?
          input-stack-sessions
          input-stack-pending-sequence
          input-stack-pending-argument
          input-stack-feedback
          make-prefix-argument-state
          prefix-argument-state?
          prefix-argument-state-universal-count
          prefix-argument-state-sign
          prefix-argument-state-digits
          prefix-argument-state-append-universal
          prefix-argument-state-append-digit
          prefix-argument-state-toggle-negative
          prefix-argument-state-value
          prefix-argument->state
          input-stack-prefix-argument
          input-stack-with-pending-sequence
          input-stack-with-pending-argument
          input-stack-with-feedback
          input-stack-push
          input-stack-pop
          input-stack-reset
          make-input-layer
          input-layer?
          input-layer-keymap
          input-layer-kind
          input-layer-handler
          input-layer-text-policy
          make-input-translation
          input-translation?
          input-translation-translate
          input-translation-aliases
          make-input-context
          input-context?
          input-context-view-id
          input-context-buffer-id
          input-context-layers
          input-context-stack
          input-context-translation
          input-context-with-translation
          input-layer-compose
          resolve-key-sequence
          input-disposition?
          input-disposition-kind
          input-disposition-value
          input-disposition-requested-command
          input-disposition-input-state
          input-pass
          input-consume
          input-dispatch)
  (import (rnrs)
          (soda host command)
          (soda host input-event)
          (soda host input-translation)
          (soda host value))

  (define-record-type
    (keymap %make-keymap keymap?)
    (fields
      (immutable name keymap-name)
      (immutable bindings keymap-binding-table)
      (immutable remaps keymap-remaps)
      (immutable prefixes keymap-prefixes)))

  (define (make-keymap name)
    (unless (symbol? name)
      (assertion-violation 'make-keymap "name must be a symbol" name))
    (%make-keymap name (make-hashtable equal-hash equal?)
                  (make-eq-hashtable) (make-hashtable equal-hash equal?)))

  (define (binding-key value)
    (if (key-stroke? value) (key-stroke-binding-key value) value))

  (define (valid-binding-key? value)
    (or (symbol? value)
        (string? value)
        (and (vector? value)
             (= (vector-length value) 4)
             (eq? (vector-ref value 0) 'key-stroke))))

  (define (valid-sequence? value)
    (and (pair? value)
         (for-all
           (lambda (key) (valid-binding-key? (binding-key key)))
           value)))

  (define (normalize-sequence sequence)
    (map binding-key sequence))

  (define (keymap-bind! map sequence binding)
    (unless (and (keymap? map) (valid-sequence? sequence))
      (assertion-violation 'keymap-bind! "expected a keymap and non-empty sequence" map sequence))
    (let ([normalized (normalize-sequence sequence)])
      (hashtable-set! (keymap-binding-table map) normalized binding)
      (let loop ([items normalized] [prefix '()])
      (unless (null? items)
        (let ([next (append prefix (list (car items)))])
          (hashtable-set! (keymap-prefixes map) next #t)
            (loop (cdr items) next)))))
    binding)

  (define (keymap-unbind! map sequence)
    (hashtable-delete! (keymap-binding-table map) (normalize-sequence sequence))
    (let ([prefixes (keymap-prefixes map)])
      (call-with-values
        (lambda () (hashtable-entries prefixes))
        (lambda (keys values)
          (do ([index 0 (+ index 1)])
              ((= index (vector-length keys)))
            (hashtable-delete! prefixes (vector-ref keys index)))))
      (call-with-values
        (lambda () (hashtable-entries (keymap-binding-table map)))
        (lambda (keys values)
          (do ([index 0 (+ index 1)])
              ((= index (vector-length keys)))
            (let loop ([items (vector-ref keys index)] [prefix '()])
              (unless (null? items)
                (let ([next (append prefix (list (car items)))])
                  (hashtable-set! prefixes next #t)
                  (loop (cdr items) next))))))))
    #t)

  (define (keymap-lookup map sequence . default)
    (let ([value
            (hashtable-ref
              (keymap-binding-table map) (normalize-sequence sequence) #f)])
      (if value value (if (null? default) #f (car default)))))

  (define (binding-key->public value)
    (if (and (vector? value) (= (vector-length value) 4)
             (eq? (vector-ref value 0) 'key-stroke))
        (make-key-stroke
          (vector-ref value 1) (vector-ref value 2) (vector-ref value 3))
        value))

  ;; Enumeration is a read-only snapshot.  Keymap storage remains private so
  ;; introspection consumers cannot bypass bind/unbind prefix maintenance.
  (define (keymap-binding-entries keymap)
    (unless (keymap? keymap)
      (assertion-violation 'keymap-binding-entries "expected a keymap" keymap))
    (call-with-values
      (lambda () (hashtable-entries (keymap-binding-table keymap)))
      (lambda (keys values)
        (let loop ([index 0] [result '()])
          (if (= index (vector-length keys))
              (reverse result)
              (loop (+ index 1)
                    (cons
                      (cons (map binding-key->public (vector-ref keys index))
                            (vector-ref values index))
                      result)))))))

  (define (keymap-where-is maps command)
    (unless (and (list? maps) (for-all keymap? maps) (symbol? command))
      (assertion-violation 'keymap-where-is
                           "expected keymaps and a command name" maps command))
    (let* ([sequence=?
            (lambda (left right)
              (and (= (length left) (length right))
                   (for-all
                     (lambda (pair)
                       (let ([left-key (car pair)] [right-key (cdr pair)])
                         (if (and (key-stroke? left-key) (key-stroke? right-key))
                             (key-stroke=? left-key right-key)
                             (equal? left-key right-key))))
                     (map cons left right))))]
           [sequences
            (fold-left
              (lambda (result sequence)
                (if (exists (lambda (seen) (sequence=? seen sequence)) result)
                    result
                    (append result (list sequence))))
              '()
              (fold-left
                append '()
                (map (lambda (keymap)
                       (map car (keymap-binding-entries keymap)))
                     maps)))]
           [effective-command
            (lambda (sequence)
              (let ([binding
                     (let loop ([remaining maps])
                       (and (pair? remaining)
                            (or (keymap-lookup (car remaining) sequence #f)
                                (loop (cdr remaining)))))])
                (and binding
                     (let loop ([remaining maps])
                       (if (null? remaining)
                           binding
                           (or (keymap-remap (car remaining) binding #f)
                               (loop (cdr remaining))))))))])
      (filter (lambda (sequence) (eq? (effective-command sequence) command))
              sequences)))

  (define (keymap-prefix? map sequence)
    (hashtable-contains?
      (keymap-prefixes map) (normalize-sequence sequence)))

  (define (keymap-remap! map command replacement)
    (unless (and (keymap? map) (symbol? command) (symbol? replacement))
      (assertion-violation 'keymap-remap! "invalid command remap" command replacement))
    (hashtable-set! (keymap-remaps map) command replacement)
    replacement)

  (define (keymap-remap map command . default)
    (if (hashtable-contains? (keymap-remaps map) command)
        (hashtable-ref (keymap-remaps map) command #f)
        (if (null? default) #f (car default))))

  (define-record-type
    (input-state %make-input-state input-state?)
    (fields
      (immutable name input-state-name)
      (immutable keymaps input-state-keymaps)
      (immutable text-policy input-state-text-policy)))

  (define (make-input-state name keymaps text-policy)
    (unless (and (symbol? name) (list? keymaps) (memq text-policy '(accept ignore)))
      (assertion-violation 'make-input-state "invalid input state" name keymaps text-policy))
    (%make-input-state name (list-copy keymaps) text-policy))

  (define-record-type
    (input-session %make-input-session input-session?)
    (fields
      (immutable state input-session-state)
      (immutable transient? input-session-transient?)))

  (define (make-input-session state transient?)
    (unless (input-state? state)
      (assertion-violation 'make-input-session "expected an input state" state))
    (%make-input-session state (and transient? #t)))

  (define-record-type
    (input-stack %make-input-stack input-stack?)
    (fields
      (immutable sessions input-stack-sessions)
      (immutable pending-sequence input-stack-pending-sequence)
      (immutable pending-argument input-stack-pending-argument)
      (immutable feedback input-stack-feedback)))

  ;; PrefixArgumentState is unfinished input syntax owned by a View.  Commands
  ;; receive only the resolved PrefixArgument value, so command behavior does
  ;; not depend on how a frontend collected universal or numeric input.
  (define-record-type
    (prefix-argument-state %make-prefix-argument-state prefix-argument-state?)
    (fields
      (immutable universal-count prefix-argument-state-universal-count)
      (immutable sign prefix-argument-state-sign)
      (immutable digits prefix-argument-state-digits)))

  (define (make-prefix-argument-state)
    (%make-prefix-argument-state 0 1 '()))

  (define (require-prefix-state who value)
    (unless (prefix-argument-state? value)
      (assertion-violation who "expected PrefixArgumentState" value)))

  (define (prefix-argument-state-append-universal value)
    (require-prefix-state 'prefix-argument-state-append-universal value)
    (%make-prefix-argument-state
      (+ 1 (prefix-argument-state-universal-count value))
      (prefix-argument-state-sign value)
      (prefix-argument-state-digits value)))

  (define (prefix-argument-state-append-digit value digit)
    (require-prefix-state 'prefix-argument-state-append-digit value)
    (unless (and (integer? digit) (exact? digit) (<= 0 digit 9))
      (assertion-violation 'prefix-argument-state-append-digit
                           "digit must be an exact integer from zero through nine" digit))
    (%make-prefix-argument-state
      (prefix-argument-state-universal-count value)
      (prefix-argument-state-sign value)
      (append (prefix-argument-state-digits value) (list digit))))

  (define (prefix-argument-state-toggle-negative value)
    (require-prefix-state 'prefix-argument-state-toggle-negative value)
    (%make-prefix-argument-state
      (prefix-argument-state-universal-count value)
      (- (prefix-argument-state-sign value))
      (prefix-argument-state-digits value)))

  (define (digits-value digits)
    (fold-left (lambda (value digit) (+ (* value 10) digit)) 0 digits))

  (define (prefix-argument-state-value value)
    (require-prefix-state 'prefix-argument-state-value value)
    (let* ([digits (prefix-argument-state-digits value)]
           [universal-count (prefix-argument-state-universal-count value)]
           [numeric
            (* (prefix-argument-state-sign value)
               (if (null? digits)
                   (expt 4 universal-count)
                   (digits-value digits)))]
           [raw
            (list 'prefix
                  universal-count
                  (prefix-argument-state-sign value)
                  (list-copy digits))])
      (make-prefix-argument raw numeric)))

  (define (prefix-argument->state value)
    (unless (prefix-argument? value)
      (assertion-violation 'prefix-argument->state "expected PrefixArgument" value))
    (let ([raw (prefix-argument-raw-value value)])
      (if (and (list? raw) (= (length raw) 4) (eq? (car raw) 'prefix)
               (integer? (cadr raw)) (>= (cadr raw) 0)
               (memv (caddr raw) '(-1 1))
               (list? (cadddr raw))
               (for-all (lambda (digit)
                          (and (integer? digit) (<= 0 digit 9)))
                        (cadddr raw)))
          (%make-prefix-argument-state
            (cadr raw) (caddr raw) (list-copy (cadddr raw)))
          (make-prefix-argument-state))))

  (define (input-stack-prefix-argument stack)
    (unless (input-stack? stack)
      (assertion-violation 'input-stack-prefix-argument "expected InputStack" stack))
    (let ([pending (input-stack-pending-argument stack)])
      (cond [(prefix-argument-state? pending) (prefix-argument-state-value pending)]
            [(prefix-argument? pending) pending]
            [(not pending) (make-prefix-argument)]
            [else
             (assertion-violation 'input-stack-prefix-argument
                                  "invalid pending prefix argument" pending)])))

  (define (make-input-stack durable)
    (unless (input-state? durable)
      (assertion-violation 'make-input-stack "durable state is required" durable))
    (%make-input-stack (list (%make-input-session durable #f)) #f #f #f))

  (define (input-stack-copy stack sessions pending-sequence pending-argument feedback)
    (unless (input-stack? stack)
      (assertion-violation 'input-stack "expected an input stack" stack))
    (%make-input-stack sessions pending-sequence pending-argument feedback))

  (define (input-stack-with-pending-sequence stack value)
    (input-stack-copy
      stack (input-stack-sessions stack) value
      (input-stack-pending-argument stack) (input-stack-feedback stack)))

  (define (input-stack-with-pending-argument stack value)
    (input-stack-copy
      stack (input-stack-sessions stack) (input-stack-pending-sequence stack)
      value (input-stack-feedback stack)))

  (define (input-stack-with-feedback stack value)
    (input-stack-copy
      stack (input-stack-sessions stack) (input-stack-pending-sequence stack)
      (input-stack-pending-argument stack) value))

  (define (input-stack-push stack state)
    (unless (input-stack? stack)
      (assertion-violation 'input-stack-push "expected an input stack" stack))
    (unless (input-state? state)
      (assertion-violation 'input-stack-push "expected an input state" state))
    (%make-input-stack
      (cons (%make-input-session state #t) (input-stack-sessions stack))
      (input-stack-pending-sequence stack)
      (input-stack-pending-argument stack)
      (input-stack-feedback stack)))

  (define (input-stack-pop stack)
    (unless (input-stack? stack)
      (assertion-violation 'input-stack-pop "expected an input stack" stack))
    (let ([sessions (input-stack-sessions stack)])
      (if (= (length sessions) 1)
          stack
          (%make-input-stack
            (cdr sessions)
            (input-stack-pending-sequence stack)
            (input-stack-pending-argument stack)
            (input-stack-feedback stack)))))

  (define (input-stack-reset stack)
    (unless (input-stack? stack)
      (assertion-violation 'input-stack-reset "expected an input stack" stack))
    (let ([sessions (input-stack-sessions stack)])
      (%make-input-stack
        (list (let loop ([items sessions])
                (if (null? (cdr items)) (car items) (loop (cdr items)))))
        #f #f #f)))

  (define-record-type
    (input-layer %make-input-layer input-layer?)
    (fields
      (immutable kind input-layer-kind)
      (immutable keymap input-layer-keymap)
      (immutable handler input-layer-handler)
      (immutable text-policy input-layer-text-policy)))

  (define input-layer-order
    '((override . 0) (transient . 1) (durable . 2) (window . 3)
      (view . 4) (buffer . 5) (minor . 6) (major . 7)
      (default . 8) (global . 9)))

  (define (make-input-layer kind keymap . options)
    (unless (and (<= (length options) 2)
                 (assq kind input-layer-order)
                 (keymap? keymap)
                 (or (null? options) (not (car options)) (procedure? (car options)))
                 (or (null? options) (null? (cdr options))
                     (memq (cadr options) '(pass accept ignore))))
      (assertion-violation 'make-input-layer
                           "expected a declared layer kind, Keymap, optional handler, and text policy"
                           kind keymap options))
    (%make-input-layer
      kind keymap
      (if (null? options) #f (car options))
      (if (or (null? options) (null? (cdr options)))
          'pass
          (cadr options))))

  (define-record-type
    (input-context %make-input-context input-context?)
    (fields
      (immutable view-id input-context-view-id)
      (immutable buffer-id input-context-buffer-id)
      (immutable layers input-context-layers)
      (immutable stack input-context-stack)
      (immutable translation input-context-translation)))

  (define (make-input-context view-id buffer-id layers . stack)
    (%make-input-context
      view-id buffer-id (list-copy layers)
      (if (null? stack)
          (make-input-stack (make-input-state 'default '() 'accept))
          (let ([value (car stack)])
            (unless (input-stack? value)
              (assertion-violation 'make-input-context "expected an input stack" value))
            value))
      identity-input-translation))

  (define (input-context-with-translation context translation)
    (unless (and (input-context? context) (input-translation? translation))
      (assertion-violation
        'input-context-with-translation
        "expected an InputContext and InputTranslation"
        context translation))
    (%make-input-context
      (input-context-view-id context)
      (input-context-buffer-id context)
      (input-context-layers context)
      (input-context-stack context)
      translation))

  (define (input-layer-rank kind)
    (cdr (assq kind input-layer-order)))

  ;; Build the canonical layer order once at the host boundary.  The resolver
  ;; itself remains pure and receives the resulting immutable list.  Layers
  ;; at the same semantic rank retain their declaration order, which lets a
  ;; host compose independent package maps without inventing package-specific
  ;; precedence kinds.
  (define (input-layer-compose layers)
    (unless (list? layers)
      (assertion-violation 'input-layer-compose "layers must be a list" layers))
    (let index ([remaining layers] [next 0] [indexed '()])
      (if (null? remaining)
          (map cdr
               (list-sort
                 (lambda (left right)
                   (let ([left-rank (input-layer-rank (input-layer-kind (cdr left)))]
                         [right-rank (input-layer-rank (input-layer-kind (cdr right)))])
                     (or (< left-rank right-rank)
                         (and (= left-rank right-rank) (< (car left) (car right))))))
                 (reverse indexed)))
          (index (cdr remaining) (+ next 1)
                 (cons (cons next (car remaining)) indexed)))))

  (define (lookup-layer map sequence)
    (cond
      [(keymap-lookup map sequence #f) => (lambda (value) (cons 'command value))]
      [(keymap-prefix? map sequence) (cons 'prefix #t)]
      [else (cons 'unbound #f)]))

  (define (resolve-key-sequence layers sequence)
    (let loop ([items layers] [trace '()])
      (if (null? items)
          (list 'unbound (reverse trace))
          (let* ([layer (car items)]
                 [result (lookup-layer (input-layer-keymap layer) sequence)])
            (case (car result)
              [(command)
               (list 'command (cdr result) layer
                     (reverse (cons (list layer result) trace)))]
              [(prefix)
               (list 'prefix (reverse (cons (list layer result) trace)))]
              [else
               (loop (cdr items) (cons (list layer result) trace))])))))

  (define-record-type
    (input-disposition %make-input-disposition input-disposition?)
    (fields (immutable kind input-disposition-kind)
            (immutable value input-disposition-value)
            (immutable requested-command input-disposition-requested-command)
            (immutable input-state input-disposition-input-state)))

  (define input-pass
    (case-lambda
      [() (%make-input-disposition 'pass #f #f #f)]
      [(input-state) (%make-input-disposition 'pass #f #f input-state)]))
  (define input-consume
    (case-lambda
      [() (%make-input-disposition 'consume #f #f #f)]
      [(input-state) (%make-input-disposition 'consume #f #f input-state)]))

  (define (input-reset context)
    (unless (input-context? context)
      (assertion-violation 'input-reset "expected an input context" context))
    (input-stack-reset (input-context-stack context)))

  (define (input-cancel context)
    (unless (input-context? context)
      (assertion-violation 'input-cancel "expected an input context" context))
    (input-stack-reset (input-context-stack context)))

  (define (resolve-command layers sequence result)
    (if (not (eq? (car result) 'command))
        result
        (let ([binding (cadr result)]
              [source (caddr result)])
          (let loop ([items layers])
            (if (null? items)
                (list 'command binding source (cadddr result) binding)
                (let ([replacement (keymap-remap
                                     (input-layer-keymap (car items))
                                     binding
                                     #f)])
                  (if replacement
                      (list 'command replacement source (cadddr result) binding)
                      (loop (cdr items)))))))))

  (define (input-dispatch context event)
    (unless (and (input-context? context)
                 (input-event? event))
      (assertion-violation
        'input-dispatch "expected an input context and event" context event))
    (let* ([stack (input-context-stack context)]
           [pending (input-stack-pending-sequence stack)])
      (cond
        [(not (key-event? event))
         (let* ([reset (input-reset context)]
                [result (input-dispatch-once context event)])
           (%make-input-disposition
             (input-disposition-kind result)
             (input-disposition-value result)
             (input-disposition-requested-command result)
             reset))]
        [(eq? (key-event-type event) 'release)
         (input-pass stack)]
        [else
         (let* ([stroke (key-event->key-stroke event)]
                [single-sequence (list stroke)]
                [translated-single
                 (input-translation-translate
                   (input-context-translation context) single-sequence)]
                [single-result
                 (and pending
                      (resolve-command
                        (input-context-layers context)
                        translated-single
                        (resolve-key-sequence
                          (input-context-layers context) translated-single)))]
                ;; An override command is an application-declared interrupt:
                ;; it remains reachable while an ordinary prefix is pending.
                ;; Input owns this composition rule; it does not know which
                ;; physical key or command name an application chooses.
                [interrupt?
                 (and single-result
                      (eq? (car single-result) 'command)
                      (eq? (input-layer-kind (caddr single-result)) 'override))]
                [sequence (if interrupt?
                              single-sequence
                              (if pending
                                  (append pending single-sequence)
                                  single-sequence))]
                [translated-sequence
                 (input-translation-translate
                   (input-context-translation context) sequence)]
                [result
                 (if interrupt?
                     single-result
                     (resolve-command
                       (input-context-layers context)
                       translated-sequence
                       (resolve-key-sequence
                         (input-context-layers context) translated-sequence)))])
           (case (car result)
             [(prefix)
              (input-consume
                (input-stack-with-pending-sequence stack sequence))]
             [(command)
              (%make-input-disposition 'command (cadr result) (list-ref result 4)
                                       (input-reset context))]
             [else
              (if (and (positive? (bytevector-length (key-event-text event)))
                       (accepting-text-layer? (input-context-layers context)))
                  (%make-input-disposition 'text (key-event-text event) #f (input-reset context))
                  (%make-input-disposition 'undefined sequence #f (input-reset context)))]))])))

  (define (accepting-text-layer? layers)
    (and (pair? layers)
         (case (input-layer-text-policy (car layers))
           [(accept) #t]
           [(ignore) #f]
           [else (accepting-text-layer? (cdr layers))])))

  (define (input-dispatch-once context event)
    (unless (and (input-context? context) (input-event? event))
      (assertion-violation 'input-dispatch-once "expected an input context and event" context event))
      (if (text-input-event? event)
        (let ([layers (input-context-layers context)])
          (if (accepting-text-layer? layers)
              (%make-input-disposition
                (text-input-event-kind event)
                (text-input-event-text event)
                #f
                (input-context-stack context))
              (input-pass (input-context-stack context))))
        (if (key-event? event)
            (let* ([sequence (list (key-event->key-stroke event))]
                   [translated
                    (input-translation-translate
                      (input-context-translation context) sequence)]
                   [result (resolve-key-sequence
                             (input-context-layers context) translated)])
              (case (car result)
                [(command)
                 (%make-input-disposition
                   'command (cadr result) (cadr result)
                   (input-context-stack context))]
                [(prefix) (input-consume (input-context-stack context))]
                [else (input-pass (input-context-stack context))]))
            (input-pass (input-context-stack context)))))
)
