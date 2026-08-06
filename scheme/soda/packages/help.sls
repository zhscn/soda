(library (soda packages help)
  (export make-help-service!)
  (import (rnrs)
          (soda kernel document)
          (soda kernel extension)
          (soda host command)
          (soda host command-runtime)
          (soda host buffer)
          (soda host input)
          (soda host input-event)
          (soda host package)
          (soda host value)
          (soda host view)
          (soda packages buffer-ui))

  (define help-text
    "Soda Nano Help\n\nC-x C-f  Visit file\nC-x C-d  Browse directory\nC-x C-b  List buffers (RET visit, d close)\nC-o      Write out\nC-x C-s  Save file\nC-x C-w  Save file as\nC-r      Insert file\nM-B      Toggle file backups\nTAB      Insert indentation (complete prompt input)\nC-c      Current position\nC-l      Refresh screen\nC-t      Check spelling\nM-D      Count words, lines, characters\nM-!      Execute command\nM-r      Revert file\nC-w      Search\nM-w/M-W  Repeat search forward/backward\nM-C      Toggle search case\nM-`      Toggle whole-word search\nC-\\      Query replace\nC-k      Cut text or line\nC-u      Uncut text\nM-6      Copy region\nM-a/C-6  Set mark\nC-j      Justify paragraph\nM-g/C-_  Go to line\nC-y/C-v  Previous/next page\nM-\\/M-/ First/last line\nM-u      Undo\nM-e      Redo\nM-i      Toggle auto-indent\nM-R      Toggle read-only\nM-E      Toggle tab-to-spaces\nM-T      Set indent width\nM-F      Toggle auto-fill\nM-$      Toggle soft wrap\nC-x C-k  Close buffer\nC-x C-c  Exit\nM-]      Matching delimiter\nC-g      Close help\n")

  (define-record-type help-service
    (fields host owner keymap))

  (define (help-configuration keymap)
    (make-configuration
      (list
        (make-buffer-input-layer-extension
          ;; A help Buffer owns this local binding.  `buffer` has a defined
          ;; precedence above the fundamental fallback, unlike a package name
          ;; that would otherwise share the default rank.
          (list (make-input-layer 'buffer keymap #f 'accept)))
        (make-buffer-edit-policy-extension (make-buffer-edit-policy 'reject)))))

  (define (open-help! service context)
    (let* ([host (help-service-host service)]
           [configuration (help-configuration (help-service-keymap service))]
           [buffer
            (package-host-open-or-create-buffer!
              host (help-service-owner service) (make-buffer-key 'help 'nano)
              (lambda ()
                (package-host-create-buffer! host (help-service-owner service) "*help*"
                                             (make-document help-text) configuration)))])
      (unless (= (buffer-id buffer) (command-context-buffer-id context))
        (let ([view (package-host-create-view! host (help-service-owner service) buffer configuration)])
          (unless (package-host-replace-window-view!
                    host (command-context-surface-id context)
                    (command-context-window-id context) (view-id view))
            (assertion-violation 'help.show "origin Window is no longer available" context))))))

  (define (make-help-service! host owner)
    (let* ([keymap (make-keymap 'help)]
           [service #f])
      (keymap-bind! keymap
                    (list (make-key-stroke 'character (char->integer #\g) 4))
                    'file.close)
      (set! service (make-help-service host owner keymap))
      (command-runtime-register-command!
        (package-host-command-runtime host)
        (make-command-definition
          'help.show (lambda (context) (open-help! service context))
          owner "Show the Nano-oriented Soda help Buffer." 'help #f))
      service))
)
