(library (soda packages buffer-ui action)
  (export make-buffer-item-action-service
          buffer-item-action-service?
          generated-buffer-input-layer
          buffer-item-input-layer
          buffer-item-action-register!
          buffer-item-action-invoke)
  (import (rnrs)
          (only (chezscheme) equal-hash)
          (soda kernel state)
          (soda host command)
          (soda host context)
          (soda host input)
          (soda host input-event)
          (soda host value)
          (soda packages buffer-ui item)
          (soda packages buffer-ui projection))

  (define-record-type
    (buffer-item-action-service %make-buffer-item-action-service buffer-item-action-service?)
    (fields (immutable table buffer-item-action-service-table)
            (immutable item-keymap buffer-item-action-service-item-keymap)))
  (define-record-type buffer-item-action-entry
    (fields owner procedure))

  ;; Generated Buffers share ordinary movement and quit bindings even when
  ;; they do not contain BufferItems.  Item activation is a separate layer.
  (define (make-generated-buffer-keymap)
    (let ([keymap (make-keymap 'generated-buffer)])
      (define (bind key command)
        (keymap-bind! keymap (list (make-key-stroke key #f 0)) command))
      (bind 'up 'buffer.previous-line)
      (bind 'down 'buffer.next-line)
      (bind 'page-up 'buffer.page-up)
      (bind 'page-down 'buffer.page-down)
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\g) 4))
                    'buffer.close)
      keymap))

  (define (make-buffer-item-action-service)
    (let ([item-keymap (make-keymap 'buffer-item)])
      (define (bind-item key command)
        (keymap-bind! item-keymap (list (make-key-stroke key #f 0)) command))
      (bind-item 'home 'buffer.first-item)
      (bind-item 'end 'buffer.last-item)
      (bind-item 'enter 'buffer.activate-item)
      (keymap-bind! item-keymap
                    (list (make-key-stroke 'character (char->integer #\p) 4))
                    'buffer.previous-item)
      (keymap-bind! item-keymap
                    (list (make-key-stroke 'character (char->integer #\n) 4))
                    'buffer.next-item)
      (%make-buffer-item-action-service
        (make-hashtable equal-hash equal?) item-keymap)))

  (define (generated-buffer-input-layer)
    (make-input-layer
      'buffer (make-generated-buffer-keymap) #f 'ignore))

  (define (buffer-item-input-layer service)
    (unless (buffer-item-action-service? service)
      (assertion-violation 'buffer-item-input-layer
                           "expected a BufferItem action service" service))
    (make-input-layer
      'buffer (buffer-item-action-service-item-keymap service) #f 'ignore))

  (define (buffer-item-action-key provider-id name)
    (list (stable-buffer-item-identity provider-id) name))

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
)
