(library (soda packages help)
  (export make-help-service!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel extension)
          (soda host command)
          (soda host command-runtime)
          (soda host dispatch)
          (soda host input)
          (soda host input-event)
          (soda host internal buffer)
          (soda host internal operation)
          (soda host internal state)
          (soda host internal view)
          (soda host value)
          (soda packages buffer-ui))

  (define help-text
    "Soda Nano Help\n\nC-x C-f  Visit file\nC-x C-s  Save file\nC-x C-w  Save file as\nC-r      Insert file\nC-w      Search\nC-\\      Replace all\nC-_      Go to line\nM-u      Undo\nM-e      Redo\nC-x C-k  Close buffer\nC-x C-c  Exit\nM-q      Fill paragraph\nM-]      Matching delimiter\nC-g      Close help\n")

  (define-record-type help-service
    (fields state owner keymap))

  (define (help-configuration keymap)
    (make-configuration
      (list
        (make-buffer-input-layer-extension
          (list (make-input-layer 'help keymap #f 'accept)))
        (make-buffer-edit-policy-extension (make-buffer-edit-policy 'reject)))))

  (define (open-help! service context)
    (let* ([state (help-service-state service)]
           [buffers (host-state-buffers state)]
           [views (host-state-views state)]
           [configuration (help-configuration (help-service-keymap service))]
           [buffer
            (buffer-service-open-or-create!
              buffers (help-service-owner service) (make-buffer-key 'help 'nano)
              (lambda ()
                (buffer-service-create! buffers (help-service-owner service) "*help*"
                                        (make-document help-text) configuration)))])
      (unless (= (buffer-id buffer) (command-context-buffer-id context))
        (let ([view (view-service-create! views (help-service-owner service) buffer configuration)])
          (unless (dispatcher-dispatch-host!
                    (host-state-dispatch state)
                    (make-replace-window-view-operation
                      (command-context-surface-id context)
                      (command-context-window-id context) (view-id view)))
            (view-service-close-view! views (view-id view))
            (assertion-violation 'help.show "origin Window is no longer available" context))))))

  (define (make-help-service! state owner)
    (let* ([keymap (make-keymap 'help)]
           [service #f])
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\g) 4))
                    'file.close)
      (set! service (make-help-service state owner keymap))
      (command-runtime-register-command!
        (host-state-command-runtime state)
        (make-command-definition
          'help.show (lambda (context) (open-help! service context))
          owner "Show the Nano-oriented Soda help Buffer." 'help #f))
      service))
)
