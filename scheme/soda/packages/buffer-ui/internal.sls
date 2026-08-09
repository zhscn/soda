(library (soda packages buffer-ui internal)
  (export make-mode-spec
          mode-spec?
          mode-spec-id
          mode-spec-kind
          mode-spec-display-name
          mode-spec-parent
          mode-spec-extensions
          mode-spec-command-categories
          mode-spec-modeline-contribution
          buffer-mode-facet
          buffer-minor-modes-facet
          buffer-major-mode-compartment
          buffer-minor-modes-compartment
          buffer-input-layers-facet
          buffer-edit-policies-facet
          buffer-read-only-option
          buffer-read-only-facet
          buffer-read-only-compartment
          buffer-read-only?
          buffer-display-profile-facet
          buffer-item-ranges-facet
          buffer-update-listeners-facet
          make-buffer-mode-extension
          make-buffer-modes-extension
          set-buffer-major-mode-effect
          set-buffer-minor-modes-effect
          make-buffer-input-layer-extension
          buffer-input-context
          make-buffer-display-profile-extension
          make-buffer-read-only-extension
          make-buffer-read-only-setting-extension
          make-edit-authority
          edit-authority?
          make-edit-authority-annotation
          make-buffer-edit-policy
          buffer-edit-policy?
          buffer-edit-policy-content-changes
          buffer-edit-policy-validator
          buffer-edit-policy-authority
          make-buffer-edit-policy-extension
          make-buffer-item
          buffer-item?
          buffer-item-provider-id
          buffer-item-id
          buffer-item-kind
          buffer-item-payload
          buffer-item-actions
          buffer-item-primary-action
          buffer-item-field
          buffer-item-field-extension
          make-buffer-items-effect
          make-projection-update
          projection-update?
          projection-update-model-generation
          projection-update-text
          projection-update-item-ranges
          projection-update-decorations
          projection-update-semantic-position-map
          generated-projection-field
          generated-projection-extension
          make-projection-transaction-spec
          buffer-item-ranges
          buffer-items-at-point
          buffer-item-at-point
          make-semantic-position
          semantic-position?
          semantic-position-provider-id
          semantic-position-item-id
          semantic-position-offset-within-item
          semantic-position-fallback-offset
          semantic-position-desired-column
          semantic-position-at-point
          make-semantic-position-restore-effect
          make-buffer-item-action-service
          buffer-item-action-service?
          buffer-item-input-layer
          buffer-item-action-register!
          buffer-item-action-invoke
          install-buffer-item-commands!)
  (import (rnrs)
          (only (chezscheme) equal-hash string->immutable-string
                bytevector->immutable-bytevector)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel mode)
          (soda kernel option)
          (soda kernel range-set)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda kernel viewport)
          (soda host command)
          (soda host command-runtime)
          (soda host context)
          (soda host buffer)
          (soda host input)
          (soda host input-event)
          (soda host package)
          (soda host view)
          (soda host value))

  ;; These facets are declarative Buffer-local contracts.  The host never
  ;; branches on mode or package names; the frontend and commands consume the
  ;; combined values through the normal Buffer configuration.
  (define (append-values values) (fold-left append '() values))
  (define (append-values-in-precedence-order values)
    (fold-left (lambda (result value) (append value result)) '() values))
  (define (first-value values) (if (null? values) #f (car values)))

  (define buffer-input-layers-facet
    (make-facet 'buffer-input-layers 'buffer '()
                append-values-in-precedence-order equal? equal?))
  (define buffer-edit-policies-facet
    (make-facet 'buffer-edit-policies 'buffer '() append-values eq? eq?))
  ;; Read-only is an ordinary Buffer configuration contribution.  The facet
  ;; is descriptive so chrome and commands can report the state; a transaction
  ;; filter consults the final composed value before accepting content changes.
  ;; Generated packages can install their own policy independently, so turning
  ;; this user-facing option off never grants write access to a Dired/result
  ;; Buffer.
  (define buffer-read-only-option
    (make-option-spec
      'buffer-read-only #f boolean? eq?
      "Whether ordinary editing commands may change the Buffer."))
  (define buffer-read-only-facet (option-spec-facet buffer-read-only-option))
  (define buffer-read-only-compartment
    (option-spec-compartment buffer-read-only-option))
  (define buffer-display-profile-facet
    (make-facet 'buffer-display-profile 'buffer '() append-values equal? equal?))
  (define buffer-item-ranges-facet
    (make-facet 'buffer-item-ranges 'buffer '() list-copy eq? eq?))
  (define buffer-update-listeners-facet update-listeners-facet)

  (define (make-buffer-input-layer-extension layers)
    (unless (and (list? layers) (for-all input-layer? layers))
      (assertion-violation 'make-buffer-input-layer-extension
                           "expected a list of InputLayer values" layers))
    (make-facet-provider buffer-input-layers-facet (list-copy layers)))

  ;; Buffer-local input contributions precede caller-supplied fallback layers,
  ;; while InputState remains owned by the View.  Temporary interfaces add
  ;; their local and transient maps through the same composition boundary.
  (define (buffer-input-context active view fallback-layers)
    (unless (and (active-context? active) (view? view)
                 (list? fallback-layers) (for-all input-layer? fallback-layers))
      (assertion-violation 'buffer-input-context
                           "invalid active context, View, or InputLayer values"
                           active view fallback-layers))
    ;; The context identifies the sole View whose InputState is consulted.
    ;; Rejecting a mismatched pair keeps a caller from accidentally applying
    ;; one window's pending key sequence to another window's Buffer layers.
    (unless (and (= (active-context-view-id active) (view-id view))
                 (= (active-context-buffer-id active)
                    (buffer-id (view-buffer view))))
      (assertion-violation 'buffer-input-context
                           "active context does not identify the supplied View"
                           active view))
    (let* ([state (buffer-state (view-buffer view))]
           [layers
            (configuration-facet (buffer-state-configuration state)
                                 buffer-input-layers-facet 'buffer)])
      (make-input-context
        (active-context-view-id active)
        (active-context-buffer-id active)
        (input-layer-compose (append layers fallback-layers))
        (view-state-input-state (view-state view)))))

  (define (make-buffer-display-profile-extension contributions)
    (unless (list? contributions)
      (assertion-violation 'make-buffer-display-profile-extension
                           "display profile contributions must be a list" contributions))
    (make-facet-provider buffer-display-profile-facet (list-copy contributions)))

  (define (buffer-read-only? configuration)
    (option-ref configuration buffer-read-only-option))

  ;; Edit authority is an owner-scoped capability carried in an annotation.
  ;; It lets a producer refresh a protected/generated Buffer without granting
  ;; unrestricted write access to unrelated commands.
  (define-record-type
    (edit-authority %make-edit-authority edit-authority?)
    (fields (immutable owner edit-authority-owner)
            (immutable name edit-authority-name)))

  (define (make-edit-authority owner name)
    (unless (and (owner? owner) (symbol? name))
      (assertion-violation 'make-edit-authority "expected an owner and symbolic name" owner name))
    (owner-assert-active 'make-edit-authority owner)
    (%make-edit-authority owner name))

  (define (make-edit-authority-annotation authority)
    (unless (edit-authority? authority)
      (assertion-violation 'make-edit-authority-annotation "expected an EditAuthority" authority))
    (make-annotation 'buffer-edit-authority authority))

  (define-record-type
    (buffer-edit-policy %make-buffer-edit-policy buffer-edit-policy?)
    (fields (immutable content-changes buffer-edit-policy-content-changes)
            (immutable validator buffer-edit-policy-validator)
            (immutable authority buffer-edit-policy-authority)))

  (define make-buffer-edit-policy
    (case-lambda
      [(content-changes) (make-buffer-edit-policy content-changes #f #f)]
      [(content-changes validator authority)
       (unless (and (memq content-changes '(allow reject validate))
                    (or (not validator) (procedure? validator))
                    (or (not authority) (edit-authority? authority)))
         (assertion-violation 'make-buffer-edit-policy "invalid EditPolicy"
                              content-changes validator authority))
       (when (and (eq? content-changes 'validate) (not validator))
         (assertion-violation 'make-buffer-edit-policy
                              "validate policy requires a validator" content-changes))
       (%make-buffer-edit-policy content-changes validator authority)]))

  (define (transaction-authorized? transaction authority)
    (and authority
         (owner-active? (edit-authority-owner authority))
         (exists (lambda (annotation)
                   (and (eq? (annotation-key annotation) 'buffer-edit-authority)
                        (eq? (annotation-value annotation) authority)))
                 (resolved-transaction-annotations transaction))))

  (define (apply-edit-policy policy transaction)
    (if (or (change-set-empty? (resolved-transaction-changes transaction))
            (transaction-authorized? transaction (buffer-edit-policy-authority policy)))
        transaction
        (case (buffer-edit-policy-content-changes policy)
          [(allow) transaction]
          [(reject) #f]
          [(validate)
           (and ((buffer-edit-policy-validator policy) transaction) transaction)])))

  (define (make-buffer-edit-policy-extension policy)
    (unless (buffer-edit-policy? policy)
      (assertion-violation 'make-buffer-edit-policy-extension "expected an EditPolicy" policy))
    (let ([filter (lambda (state transaction) (apply-edit-policy policy transaction))])
      (list (make-facet-provider buffer-edit-policies-facet (list policy))
            (make-facet-provider transaction-filters-facet (list filter)))))

  (define (make-read-only-filter-extension)
    (make-facet-provider
      transaction-filters-facet
      (list
        (lambda (state transaction)
          (if (or (change-set-empty?
                    (resolved-transaction-changes transaction))
                  (not (buffer-read-only?
                         (buffer-state-configuration state))))
              transaction
              #f)))))

  (define (make-buffer-read-only-extension enabled?)
    (unless (boolean? enabled?)
      (assertion-violation 'make-buffer-read-only-extension
                           "expected a read-only boolean" enabled?))
    (list
      (make-buffer-local-option-extension buffer-read-only-option enabled?)
      (make-read-only-filter-extension)))

  (define (make-buffer-read-only-setting-extension enabled?)
    (unless (boolean? enabled?)
      (assertion-violation 'make-buffer-read-only-setting-extension
                           "expected a read-only boolean" enabled?))
    (list
      (make-facet-provider buffer-read-only-facet enabled?)
      (make-read-only-filter-extension)))

  (define-record-type
    (buffer-item %make-buffer-item buffer-item?)
    (fields (immutable provider-id buffer-item-provider-id)
            (immutable id buffer-item-id)
            (immutable kind buffer-item-kind)
            (immutable payload buffer-item-payload)
            (immutable actions buffer-item-actions)
            (immutable primary-action buffer-item-primary-action)))

  (define (stable-identity value)
    (cond [(string? value) (string->immutable-string value)]
          [(bytevector? value) (bytevector->immutable-bytevector value)]
          [else value]))

  (define (make-buffer-item provider-id id kind payload actions primary-action)
    (unless (and (or (symbol? provider-id) (string? provider-id))
                 (or (symbol? id) (string? id) (integer? id))
                 (symbol? kind) (list? actions) (for-all symbol? actions)
                 (or (not primary-action)
                     (and (symbol? primary-action) (memq primary-action actions))))
      (assertion-violation 'make-buffer-item "invalid BufferItem" provider-id id kind))
    (%make-buffer-item (stable-identity provider-id) (stable-identity id)
                       kind payload (list-copy actions) primary-action))

  (define (assert-buffer-item-ranges who ranges)
    (unless (range-set? ranges)
      (assertion-violation who "expected an item RangeSet" ranges))
    (for-each
      (lambda (range)
        (unless (buffer-item? (range-value-value range))
          (assertion-violation who "item ranges must contain BufferItem values" range)))
      (range-set-ranges ranges))
    ranges)

  (define (replacement-item-effect transaction)
    (let loop ([effects (transaction-effects transaction)] [replacement #f])
      (if (null? effects)
          replacement
          (let ([effect (car effects)])
            (if (eq? (state-effect-type effect) 'buffer-items-replace)
                (let ([ranges
                       (assert-buffer-item-ranges
                         'buffer-item-field (state-effect-value effect))])
                  (when replacement
                    (assertion-violation 'buffer-item-field
                                         "transaction contains multiple item replacements"))
                  (loop (cdr effects) ranges))
                (loop (cdr effects) replacement))))))

  (define buffer-item-field
    (make-state-field
      'buffer-items 'buffer
      (lambda (ignored) (make-range-set '()))
      (lambda (old transaction)
        (let ([replacement (replacement-item-effect transaction)])
          (if replacement
              replacement
              (range-set-map-change old (transaction-changes transaction)))))))

  (define (make-buffer-items-effect ranges)
    (assert-buffer-item-ranges 'make-buffer-items-effect ranges)
    ;; Projection ranges are authored in the resulting document coordinates.
    (make-state-effect 'buffer-items-replace ranges (lambda (value ignored) value)))

  ;; A generated projection is the immutable hand-off from a producer to the
  ;; editor.  Its decorations and semantic map stay package data until a
  ;; display/position provider consumes them; the text and item ranges publish
  ;; through the same Buffer transaction.
  (define-record-type
    (projection-update %make-projection-update projection-update?)
    (fields (immutable model-generation projection-update-model-generation)
            (immutable text projection-update-text)
            (immutable item-ranges projection-update-item-ranges)
            (immutable decorations projection-update-decorations)
            (immutable semantic-position-map projection-update-semantic-position-map)))

  (define (projection-text-length text)
    (cond [(string? text) (bytevector-length (string->utf8 text))]
          [(bytevector? text) (bytevector-length text)]
          [else #f]))

  (define (immutable-projection-text text)
    (cond [(string? text) (string->immutable-string text)]
          [(bytevector? text) (bytevector->immutable-bytevector text)]
          [else (assertion-violation 'immutable-projection-text
                                     "expected text" text)]))

  (define (make-projection-update generation text item-ranges decorations semantic-position-map)
    (unless (and (integer? generation) (exact? generation) (>= generation 0)
                 (projection-text-length text) (range-set? item-ranges))
      (assertion-violation 'make-projection-update
                           "invalid generated projection" generation text item-ranges))
    ;; Reuse the standard validator so semantic item data cannot drift from
    ;; the text projection contract.
    (make-buffer-items-effect item-ranges)
    (let ([length (projection-text-length text)])
      (for-each
        (lambda (range)
          (when (> (range-value-to range) length)
            (assertion-violation 'make-projection-update
                                 "item range exceeds projected text" range length)))
        (range-set-ranges item-ranges)))
    (%make-projection-update generation
                             (immutable-projection-text text)
                             item-ranges decorations semantic-position-map))

  (define (projection-transaction-effects value)
    (cond [(transaction? value) (transaction-effects value)]
          [(resolved-transaction? value) (resolved-transaction-effects value)]
          [else
           (assertion-violation 'projection-effect
                                "expected a Transaction or ResolvedTransaction" value)]))

  (define (projection-effect transaction)
    (let loop ([effects (projection-transaction-effects transaction)] [replacement #f])
      (if (null? effects)
          replacement
          (let ([effect (car effects)])
            (if (eq? (state-effect-type effect) 'generated-projection-replace)
                (let ([update (state-effect-value effect)])
                  (unless (projection-update? update)
                    (assertion-violation 'generated-projection-field
                                         "projection effect must contain a ProjectionUpdate"
                                         update))
                  (when replacement
                    (assertion-violation 'generated-projection-field
                                         "transaction contains multiple projection updates"))
                  (loop (cdr effects) update))
                (loop (cdr effects) replacement))))))

  (define (projection-newer? old update)
    (or (not old)
        (> (projection-update-model-generation update)
           (projection-update-model-generation old))))

  (define (generated-projection-filter state resolved)
    (let ([update (projection-effect resolved)])
      (if (not update)
          resolved
          (let ([old (buffer-state-field state generated-projection-field)])
            (if (projection-newer? old update) resolved #f)))))

  (define generated-projection-field
    (make-state-field
      'generated-projection 'buffer
      (lambda (ignored) #f)
      (lambda (old transaction)
        (let ([update (projection-effect transaction)])
          (cond [(not update) old]
                [(projection-newer? old update) update]
                [else
                 (assertion-violation 'generated-projection-field
                                      "stale projection escaped its transaction filter"
                                      update old)])))))

  (define (semantic-position-restore-entries? positions)
    (and (list? positions)
         (for-all
           (lambda (entry)
             (and (pair? entry) (integer? (car entry)) (exact? (car entry))
                  (>= (car entry) 0) (semantic-position? (cdr entry))))
           positions)))

  (define (restore-position-for-view transaction view-id)
    (let loop ([effects (transaction-effects transaction)])
      (and (pair? effects)
           (let ([effect (car effects)])
             (if (eq? (state-effect-type effect) 'semantic-position-restore)
                 (let ([entries (state-effect-value effect)])
                   (unless (semantic-position-restore-entries? entries)
                     (assertion-violation 'generated-projection-selection-mapper
                                          "semantic restore effect has invalid entries" entries))
                   (let find ([entries entries])
                   (and (pair? entries)
                        (if (= (caar entries) view-id)
                            (cdar entries)
                            (find (cdr entries))))))
                 (loop (cdr effects)))))))

  (define (generated-projection-selection-mapper view-id old-view-state transaction selection)
    (let ([position (restore-position-for-view transaction view-id)])
      (if position
          (or (semantic-position-selection (transaction-new-buffer-state transaction) position)
              selection)
          selection)))

  (define (generated-projection-extension)
    (list generated-projection-field
          (buffer-item-field-extension)
          (make-facet-provider transaction-filters-facet
                               (list generated-projection-filter))
          (make-facet-provider view-selection-mappers-facet
                               (list generated-projection-selection-mapper))))

  (define make-projection-transaction-spec
    (case-lambda
      [(buffer-id origin-view-id state update)
       (make-projection-transaction-spec buffer-id origin-view-id state update '() '())]
      [(buffer-id origin-view-id state update annotations)
       (make-projection-transaction-spec buffer-id origin-view-id state update annotations '())]
      [(buffer-id origin-view-id state update annotations restore-positions)
       (unless (and (integer? buffer-id) (exact? buffer-id) (>= buffer-id 0)
                    (buffer-state? state) (projection-update? update)
                    (list? annotations) (list? restore-positions))
         (assertion-violation 'make-projection-transaction-spec
                              "invalid generated projection transaction"))
       (let ([old-length (snapshot-byte-size (buffer-state-document state))]
             [effects
              (append
                (list (make-state-effect 'generated-projection-replace update
                                         (lambda (value ignored) value))
                      (make-buffer-items-effect (projection-update-item-ranges update)))
                (if (null? restore-positions)
                    '()
                    (list (make-semantic-position-restore-effect restore-positions))))])
         (make-transaction-spec
           buffer-id origin-view-id (buffer-state-generation state)
           (make-change-set old-length
                            (list (make-text-change 0 old-length
                                                    (projection-update-text update))))
           #f effects annotations))]))

  (define (buffer-item-field-extension)
    (list buffer-item-field
          (make-facet-provider
            buffer-item-ranges-facet
            (lambda (state) (buffer-state-field state buffer-item-field)))))

  (define (buffer-item-ranges state)
    (unless (buffer-state? state)
      (assertion-violation 'buffer-item-ranges "expected a BufferState" state))
    (let ([providers
           (configuration-facet (buffer-state-configuration state)
                                buffer-item-ranges-facet 'buffer)])
      (map
        (lambda (provider)
          (unless (procedure? provider)
            (assertion-violation 'buffer-item-ranges
                                 "item range facet values must be procedures" provider))
          (let ([ranges (provider state)])
            (unless (range-set? ranges)
              (assertion-violation 'buffer-item-ranges
                                   "item range provider must return a RangeSet" ranges))
            ranges))
        providers)))

  (define (buffer-items-at-point state point)
    (apply append
           (map
             (lambda (ranges)
               (map range-value-value (range-set-query-point ranges point)))
             (buffer-item-ranges state))))

  (define (buffer-item-at-point state point)
    (let ([items (buffer-items-at-point state point)])
      (and (pair? items) (car items))))

  (define-record-type
    (semantic-position %make-semantic-position semantic-position?)
    (fields (immutable provider-id semantic-position-provider-id)
            (immutable item-id semantic-position-item-id)
            (immutable offset-within-item semantic-position-offset-within-item)
            (immutable fallback-offset semantic-position-fallback-offset)
            (immutable desired-column semantic-position-desired-column)))

  (define (make-semantic-position provider-id item-id offset fallback desired-column)
    (unless (and (or (symbol? provider-id) (string? provider-id))
                 (or (symbol? item-id) (string? item-id) (integer? item-id))
                 (integer? offset) (exact? offset) (>= offset 0)
                 (integer? fallback) (exact? fallback) (>= fallback 0)
                 (or (not desired-column)
                     (and (integer? desired-column) (exact? desired-column)
                          (>= desired-column 0))))
      (assertion-violation 'make-semantic-position "invalid semantic position"))
    (%make-semantic-position (stable-identity provider-id) (stable-identity item-id)
                             offset fallback desired-column))

  (define (item-range-at-point state point)
    (let outer ([sets (buffer-item-ranges state)])
      (and (pair? sets)
           (let inner ([ranges (range-set-query-point (car sets) point)])
             (cond [(null? ranges) (outer (cdr sets))]
                   [(buffer-item? (range-value-value (car ranges))) (car ranges)]
                   [else (inner (cdr ranges))])))))

  (define (semantic-position-at-point state point . desired-column)
    (unless (and (integer? point) (exact? point) (>= point 0)
                 (or (null? desired-column)
                     (and (pair? desired-column) (null? (cdr desired-column))
                          (or (not (car desired-column))
                              (and (integer? (car desired-column)) (exact? (car desired-column))
                                   (>= (car desired-column) 0))))))
      (assertion-violation 'semantic-position-at-point "invalid point or desired column" point))
    (let ([range (item-range-at-point state point)])
      (and range
           (let ([item (range-value-value range)])
             (make-semantic-position
               (buffer-item-provider-id item) (buffer-item-id item)
               (- point (range-value-from range)) point
               (if (null? desired-column) #f (car desired-column)))))))

  (define (find-semantic-item-range state position)
    (let outer ([sets (buffer-item-ranges state)])
      (and (pair? sets)
           (let inner ([ranges (range-set-ranges (car sets))])
             (cond
               [(null? ranges) (outer (cdr sets))]
               [else
                (let ([item (range-value-value (car ranges))])
                  (if (and (buffer-item? item)
                           (equal? (buffer-item-provider-id item)
                                   (semantic-position-provider-id position))
                           (equal? (buffer-item-id item)
                                   (semantic-position-item-id position)))
                      (car ranges)
                      (inner (cdr ranges))))])))))

  (define (semantic-position-selection state position)
    (let ([range (find-semantic-item-range state position)])
      (and range
           (let ([point (min (range-value-to range)
                             (+ (range-value-from range)
                                (semantic-position-offset-within-item position)))])
             (make-selection (list (make-selection-range point point)))))))

  (define (make-semantic-position-restore-effect positions)
    (unless (semantic-position-restore-entries? positions)
      (assertion-violation 'make-semantic-position-restore-effect
                           "expected View id to SemanticPosition pairs" positions))
    (make-state-effect 'semantic-position-restore (list-copy positions)
                       (lambda (value ignored) value)))

  (define-record-type
    (buffer-item-action-service %make-buffer-item-action-service buffer-item-action-service?)
    (fields (immutable table buffer-item-action-service-table)
            (immutable keymap buffer-item-action-service-keymap)))
  (define-record-type buffer-item-action-entry
    (fields owner procedure))

  (define (make-buffer-item-action-service)
    (let ([keymap (make-keymap 'buffer-item)])
      (define (bind key command)
        (keymap-bind! keymap (list (make-key-stroke key #f 0)) command))
      (bind 'up 'buffer.previous-line)
      (bind 'down 'buffer.next-line)
      (bind 'page-up 'buffer.page-up)
      (bind 'page-down 'buffer.page-down)
      (bind 'home 'buffer.first-item)
      (bind 'end 'buffer.last-item)
      (bind 'enter 'buffer.activate-item)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\p) 4))
                    'buffer.previous-item)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\n) 4))
                    'buffer.next-item)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\g) 4))
                    'buffer.close)
      (%make-buffer-item-action-service (make-hashtable equal-hash equal?) keymap)))

  (define (buffer-item-input-layer service)
    (unless (buffer-item-action-service? service)
      (assertion-violation 'buffer-item-input-layer
                           "expected a BufferItem action service" service))
    (make-input-layer 'buffer (buffer-item-action-service-keymap service) #f 'ignore))

  (define (buffer-item-action-key provider-id name)
    (list (stable-identity provider-id) name))

  (define (buffer-item-action-register! service owner provider-id name procedure)
    (unless (and (buffer-item-action-service? service) (owner? owner)
                 (or (symbol? provider-id) (string? provider-id))
                 (symbol? name) (procedure? procedure))
      (assertion-violation 'buffer-item-action-register!
                           "expected an action service, owner, provider, name, and procedure"))
    (owner-assert-active 'buffer-item-action-register! owner)
    (let* ([key (buffer-item-action-key provider-id name)]
           [entry (make-buffer-item-action-entry owner procedure)])
      (when (hashtable-contains? (buffer-item-action-service-table service) key)
        (assertion-violation 'buffer-item-action-register!
                             "action is already registered for provider" provider-id name))
      (hashtable-set! (buffer-item-action-service-table service) key entry)
      (make-registration
        owner
        (lambda ()
          (when (eq? (hashtable-ref (buffer-item-action-service-table service) key #f) entry)
            (hashtable-delete! (buffer-item-action-service-table service) key))))))

  (define (buffer-item-action-invoke service name item context)
    (unless (and (buffer-item-action-service? service) (symbol? name)
                 (buffer-item? item) (command-context? context))
      (assertion-violation 'buffer-item-action-invoke "invalid item action invocation" name item))
    (let ([entry (hashtable-ref (buffer-item-action-service-table service)
                                (buffer-item-action-key
                                  (buffer-item-provider-id item) name) #f)])
      (and entry (owner-active? (buffer-item-action-entry-owner entry))
           ((buffer-item-action-entry-procedure entry)
            item context
            (let ([state (command-context-buffer-state context)])
              (and state
                   (let ([projection
                          (buffer-state-field state generated-projection-field #f)])
                     (and projection
                          (projection-update-model-generation projection)))))))))

  (define (all-item-ranges state)
    (list-sort
      (lambda (left right)
        (or (< (range-value-from left) (range-value-from right))
            (and (= (range-value-from left) (range-value-from right))
                 (< (range-value-to left) (range-value-to right)))))
      (apply append (map range-set-ranges (buffer-item-ranges state)))))

  (define (context-point context)
    (selection-range-head
      (selection-primary-range
        (view-state-selection (command-context-view-state context)))))

  (define (move-to-item context range)
    (make-view-transaction-spec
      (command-context-view-id context)
      (view-state-generation (command-context-view-state context))
      (make-selection
        (list (make-selection-range (range-value-from range) (range-value-from range))))
      #f #f '() '() #f))

  (define (move-line context amount)
    (let* ([state (command-context-buffer-state context)]
           [snapshot (buffer-state-document state)]
           [text (snapshot-text snapshot)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let* ([position (text-position text (context-point context))]
                 [line (max 0 (min (- (text-line-count text) 1)
                                   (+ (car position) amount)))]
                 [point (text-offset text line (cdr position))])
            (move-to-item context (make-range-value point point #f))))
        (lambda () (text-close! text)))))

  (define (scroll-page context amount)
    (let ([state (command-context-view-state context)])
      (make-view-transaction-spec
        (command-context-view-id context) (view-state-generation state)
        #f #f #f '() '()
        (make-scroll-request
          'scroll-pages
          (command-context-surface-id context)
          (command-context-window-id context)
          (command-context-view-id context)
          amount))))

  (define (next-item-range state point)
    (let loop ([ranges (all-item-ranges state)])
      (and (pair? ranges)
           (if (> (range-value-from (car ranges)) point)
               (car ranges)
               (loop (cdr ranges))))))

  (define (previous-item-range state point)
    (let loop ([ranges (all-item-ranges state)] [previous #f])
      (if (null? ranges)
          previous
          (if (>= (range-value-from (car ranges)) point)
              previous
              (loop (cdr ranges) (car ranges))))))

  (define (edge-item-range state first?)
    (let ([ranges (all-item-ranges state)])
      (and (pair? ranges)
           (if first?
               (car ranges)
               (let loop ([items (cdr ranges)] [last (car ranges)])
                 (if (null? items) last (loop (cdr items) (car items))))))))

  (define (install-buffer-item-commands! runtime owner actions host)
    (unless (and (command-runtime? runtime) (owner? owner)
                 (buffer-item-action-service? actions) (package-host? host))
      (assertion-violation 'install-buffer-item-commands!
                           "invalid BufferItem command dependencies" runtime owner actions))
    (for-each
      (lambda (definition) (command-runtime-register-command! runtime definition))
      (list
        (make-command-definition
          'buffer.next-line
          (lambda (context) (move-line context 1))
          owner "Move to the next logical line in a special Buffer." 'buffer-item #f)
        (make-command-definition
          'buffer.previous-line
          (lambda (context) (move-line context -1))
          owner "Move to the previous logical line in a special Buffer." 'buffer-item #f)
        (make-command-definition
          'buffer.page-up
          (lambda (context) (scroll-page context -1))
          owner "Scroll a special Buffer toward its beginning." 'buffer-item #f)
        (make-command-definition
          'buffer.page-down
          (lambda (context) (scroll-page context 1))
          owner "Scroll a special Buffer toward its end." 'buffer-item #f)
        (make-command-definition
          'buffer.next-item
          (lambda (context)
            (let ([range (next-item-range (command-context-buffer-state context)
                                          (context-point context))])
              (if range (move-to-item context range) (command-handled))))
          owner "Move to the next semantic Buffer item." 'buffer-item #f)
        (make-command-definition
          'buffer.previous-item
          (lambda (context)
            (let ([range (previous-item-range (command-context-buffer-state context)
                                              (context-point context))])
              (if range (move-to-item context range) (command-handled))))
          owner "Move to the previous semantic Buffer item." 'buffer-item #f)
        (make-command-definition
          'buffer.first-item
          (lambda (context)
            (let ([range (edge-item-range (command-context-buffer-state context) #t)])
              (if range (move-to-item context range) (command-handled))))
          owner "Move to the first semantic Buffer item." 'buffer-item #f)
        (make-command-definition
          'buffer.last-item
          (lambda (context)
            (let ([range (edge-item-range (command-context-buffer-state context) #f)])
              (if range (move-to-item context range) (command-handled))))
          owner "Move to the last semantic Buffer item." 'buffer-item #f)
        (make-command-definition
          'buffer.activate-item
          (lambda (context)
            (let ([item (buffer-item-at-point (command-context-buffer-state context)
                                              (context-point context))])
              (if (and item (buffer-item-primary-action item))
                  (or (buffer-item-action-invoke actions (buffer-item-primary-action item) item context)
                      (command-handled))
                  (command-handled))))
          owner "Run the primary action for the semantic item at point." 'buffer-item #f)
        (make-command-definition
          'buffer.close
          (lambda (context)
            (package-host-close-buffer-with-fallback!
              host owner (command-context-buffer-id context))
            (command-handled))
          owner "Close the active special Buffer." 'buffer-item #f))))
)
