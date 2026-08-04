(library (soda packages base fundamental-editing)
  (export make-fundamental-editing!
          fundamental-editing?
          fundamental-editing-keymap
          fundamental-input-context
          fundamental-input-disposition)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda packages base text-motion)
          (soda host command)
          (soda host command-runtime)
          (soda host context)
          (soda host input)
          (soda host input-event)
          (soda host view)
          (soda host value))

  ;; Fundamental editing is an ordinary package: it owns command
  ;; registrations and a keymap, while all mutation remains a TransactionSpec
  ;; interpreted by CommandRuntime and Dispatcher.
  (define-record-type
    (fundamental-editing %make-fundamental-editing fundamental-editing?)
    (fields (immutable keymap fundamental-editing-keymap)
            (mutable kill-ring fundamental-editing-kill-ring
                     fundamental-editing-kill-ring-set!)))

  (define (control-stroke character)
    (make-key-stroke 'character (char->integer character) 4))

  (define (plain-stroke key codepoint)
    (make-key-stroke key codepoint 0))

  (define (context-selection context)
    (view-state-selection (command-context-view-state context)))

  (define (context-document-length context)
    (snapshot-byte-size
      (buffer-state-document (command-context-buffer-state context))))

  (define (with-context-text context procedure)
    (let ([text (snapshot-text
                  (buffer-state-document (command-context-buffer-state context)))])
      (dynamic-wind
        (lambda () #f)
        (lambda () (procedure text))
        (lambda () (text-close! text)))))

  (define (mark-active? range)
    (let ([metadata (selection-range-metadata range)])
      (and (list? metadata)
           (let ([entry (assq 'mark-active metadata)])
             (and entry (cdr entry))))))

  (define (set-mark-active metadata active?)
    (cons (cons 'mark-active active?)
          (if (list? metadata)
              (filter (lambda (entry)
                        (not (and (pair? entry) (eq? (car entry) 'mark-active))))
                      metadata)
              '())))

  (define (collapse-range range position)
    (make-selection-range
      position position
      (selection-range-affinity range)
      (selection-range-granularity range)
      (set-mark-active (selection-range-metadata range) #f)))

  (define (motion-range range position)
    (if (mark-active? range)
        (make-selection-range
          (selection-range-anchor range) position
          (selection-range-affinity range)
          (selection-range-granularity range)
          (selection-range-metadata range))
        (collapse-range range position)))

  (define (set-mark-selection selection)
    (make-selection
      (map
        (lambda (range)
          (let ([point (selection-range-head range)])
            (make-selection-range
              point point
              (selection-range-affinity range)
              (selection-range-granularity range)
              (set-mark-active (selection-range-metadata range) #t))))
        (selection-ranges selection))
      (selection-primary selection)))

  (define (deactivate-mark-selection selection)
    (make-selection
      (map (lambda (range) (collapse-range range (selection-range-head range)))
           (selection-ranges selection))
      (selection-primary selection)))

  (define (replace-selection context inserted)
    (unless (bytevector? inserted)
      (assertion-violation 'fundamental.insert-text "expected committed UTF-8 bytes" inserted))
    (let* ([selection (context-selection context)]
           [length (context-document-length context)]
           [changes
            (map
              (lambda (range)
                (make-text-change
                  (selection-range-from range) (selection-range-to range) inserted))
              (selection-ranges selection))]
           [change-set (make-change-set length changes)]
           [next-selection
            (make-selection
              (map
                (lambda (range)
                  (let ([position
                         (change-set-map-offset
                           change-set (selection-range-to range) 'after)])
                    (collapse-range range position)))
                (selection-ranges selection))
              (selection-primary selection))])
      (make-transaction-spec
        (command-context-buffer-id context)
        (command-context-view-id context)
        (buffer-state-generation (command-context-buffer-state context))
        change-set next-selection '() '())))

  (define (delete-selection-or-character context direction)
    (let ([selection (context-selection context)]
          [length (context-document-length context)])
      (with-context-text
        context
        (lambda (text)
          (let* ([changes
                  (map
                    (lambda (range)
                      (let ([from (selection-range-from range)]
                            [to (selection-range-to range)])
                        (if (< from to)
                            (make-text-change from to (make-bytevector 0))
                            (let ([other
                                   (if (eq? direction 'backward)
                                       (text-previous-grapheme-offset text from)
                                       (text-next-grapheme-offset text to))])
                              (make-text-change
                                (min from other) (max to other) (make-bytevector 0))))))
                    (selection-ranges selection))]
                 [change-set (make-change-set length changes)]
                 [next-selection
                  (make-selection
                    (map
                      (lambda (range)
                        (let* ([from (selection-range-from range)]
                               [to (selection-range-to range)]
                               [point
                                (if (< from to)
                                    from
                                    (if (eq? direction 'backward)
                                        (text-previous-grapheme-offset text from)
                                        to))]
                               [mapped (change-set-map-offset change-set point 'before)])
                          (collapse-range range mapped)))
                      (selection-ranges selection))
                    (selection-primary selection))])
            (make-transaction-spec
              (command-context-buffer-id context)
              (command-context-view-id context)
              (buffer-state-generation (command-context-buffer-state context))
              change-set next-selection '() '()))))))

  (define (move-selection context direction)
    (with-context-text
      context
      (lambda (text)
        (let* ([selection (context-selection context)]
               [next
                (make-selection
                  (map
                    (lambda (range)
                      (let* ([from (selection-range-from range)]
                             [to (selection-range-to range)]
                             [origin
                              (if (eq? direction 'backward) from to)]
                             [position
                              (if (eq? direction 'backward)
                                  (text-previous-grapheme-offset text origin)
                                  (text-next-grapheme-offset text origin))])
                        (motion-range range position)))
                    (selection-ranges selection))
                  (selection-primary selection))]
               [state (command-context-view-state context)])
          (make-view-transaction-spec
            (command-context-view-id context) (view-state-generation state)
            next #f #f '() '() #f)))))

  (define (move-selection-by context target)
    (with-context-text
      context
      (lambda (text)
        (let* ([selection (context-selection context)]
               [next
                (make-selection
                  (map
                    (lambda (range)
                      (let ([position (target text range)])
                        (motion-range range position)))
                    (selection-ranges selection))
                  (selection-primary selection))]
               [state (command-context-view-state context)])
          (make-view-transaction-spec
            (command-context-view-id context) (view-state-generation state)
            next #f #f '() '() #f)))))

  (define (move-word context direction)
    (move-selection-by
      context
      (lambda (text range)
        ((if (eq? direction 'backward)
             text-backward-word-offset
             text-forward-word-offset)
         text
         (if (eq? direction 'backward)
             (selection-range-from range)
             (selection-range-to range))))))

  (define (move-line-boundary context boundary)
    (move-selection-by
      context
      (lambda (text range)
        ((if (eq? boundary 'start)
             text-line-start-offset
             text-line-end-offset)
         text
         (selection-range-head range)))))

  (define (view-selection-transaction context selection)
    (let ([state (command-context-view-state context)])
      (make-view-transaction-spec
        (command-context-view-id context) (view-state-generation state)
        selection #f #f '() '() #f)))

  (define (set-mark context)
    (view-selection-transaction context (set-mark-selection (context-selection context))))

  (define (deactivate-mark context)
    (view-selection-transaction context
                                (deactivate-mark-selection (context-selection context))))

  (define (primary-region-bytes context)
    (let ([range (selection-primary-range (context-selection context))])
      (and (not (selection-range-empty? range))
           (with-context-text
             context
             (lambda (text)
               (text-subbytevector text
                                   (selection-range-from range)
                                   (selection-range-to range)))))))

  (define (record-kill! editing bytes)
    (unless (bytevector? bytes)
      (assertion-violation 'fundamental.record-kill "expected UTF-8 bytes" bytes))
    (let ([entries (cons (bytevector-copy bytes) (fundamental-editing-kill-ring editing))])
      (fundamental-editing-kill-ring-set!
        editing
        (let loop ([items entries] [remaining 60])
          (if (or (zero? remaining) (null? items))
              '()
              (cons (car items) (loop (cdr items) (- remaining 1)))))))
    bytes)

  (define (copy-region context)
    (let ([bytes (primary-region-bytes context)])
      (if (not bytes)
          (command-handled)
          (make-command-result
            (list
              (deactivate-mark context)
              (make-command-effect 'fundamental.record-kill bytes)
              (make-command-effect 'clipboard.write bytes))))))

  (define (kill-region context)
    (let ([range (selection-primary-range (context-selection context))]
          [bytes (primary-region-bytes context)])
      (if (not bytes)
          (command-handled)
          (let* ([length (context-document-length context)]
                 [start (selection-range-from range)]
                 [changes (make-change-set
                            length
                            (list (make-text-change start (selection-range-to range)
                                                    (make-bytevector 0))))]
                 [selection (make-selection (list (collapse-range range start)) 0)])
            (make-command-result
              (list
                (make-transaction-spec
                  (command-context-buffer-id context)
                  (command-context-view-id context)
                  (buffer-state-generation (command-context-buffer-state context))
                  changes selection '() '())
                (make-command-effect 'fundamental.record-kill bytes)
                (make-command-effect 'clipboard.write bytes)))))))

  (define (yank context editing)
    (let ([ring (fundamental-editing-kill-ring editing)])
      (if (null? ring)
          (command-handled)
          (replace-selection context (bytevector-copy (car ring))))))

  (define-syntax install-command!
    (syntax-rules ()
      [(_ runtime owner name (context . arguments) documentation class body ...)
       (command-runtime-register-command!
         runtime
         (make-command-definition
           name
           (lambda (context . arguments) body ...)
           owner documentation class #f))]))

  (define-syntax bind-keys!
    (syntax-rules ()
      [(_ keymap (sequence command) ...)
       (begin (keymap-bind! keymap sequence command) ...)]))

  (define (make-fundamental-editing! runtime owner)
    (unless (and (command-runtime? runtime) (owner? owner))
      (assertion-violation 'make-fundamental-editing! "expected a runtime and owner" runtime owner))
    (let* ([keymap (make-keymap 'fundamental)]
           [editing (%make-fundamental-editing keymap '())])
      (command-runtime-register-effect-handler!
        runtime 'fundamental.record-kill owner 'fundamental-kill-ring
        (lambda (service invocation effect)
          (record-kill! editing (command-effect-payload effect))))
      (install-command!
        runtime owner 'fundamental.insert-text (context inserted)
        "Insert committed text at every selection." 'editing
        (replace-selection context inserted))
      (install-command!
        runtime owner 'fundamental.newline (context)
        "Insert a newline at every selection." 'editing
        (replace-selection context (string->utf8 "\n")))
      (install-command!
        runtime owner 'fundamental.delete-backward (context)
        "Delete the active region or preceding grapheme." 'editing
        (delete-selection-or-character context 'backward))
      (install-command!
        runtime owner 'fundamental.delete-forward (context)
        "Delete the active region or following grapheme." 'editing
        (delete-selection-or-character context 'forward))
      (install-command!
        runtime owner 'fundamental.backward-char (context)
        "Move every selection backward by one grapheme." 'motion
        (move-selection context 'backward))
      (install-command!
        runtime owner 'fundamental.forward-char (context)
        "Move every selection forward by one grapheme." 'motion
        (move-selection context 'forward))
      (install-command!
        runtime owner 'fundamental.backward-word (context)
        "Move every selection backward by one Unicode word." 'motion
        (move-word context 'backward))
      (install-command!
        runtime owner 'fundamental.forward-word (context)
        "Move every selection forward by one Unicode word." 'motion
        (move-word context 'forward))
      (install-command!
        runtime owner 'fundamental.beginning-of-line (context)
        "Move every selection to the start of its logical line." 'motion
        (move-line-boundary context 'start))
      (install-command!
        runtime owner 'fundamental.end-of-line (context)
        "Move every selection to the end of its logical line." 'motion
        (move-line-boundary context 'end))
      (install-command!
        runtime owner 'fundamental.set-mark (context)
        "Set the mark at every selection and activate the region." 'selection
        (set-mark context))
      (install-command!
        runtime owner 'fundamental.deactivate-mark (context)
        "Deactivate every active region." 'selection
        (deactivate-mark context))
      (install-command!
        runtime owner 'fundamental.copy-region (context)
        "Copy the primary active region to the kill ring and clipboard." 'kill
        (copy-region context))
      (install-command!
        runtime owner 'fundamental.kill-region (context)
        "Kill the primary active region to the kill ring and clipboard." 'kill
        (kill-region context))
      (install-command!
        runtime owner 'fundamental.yank (context)
        "Insert the newest kill-ring entry at every selection." 'yank
        (yank context editing))
      (install-command!
        runtime owner 'application.quit (context)
        "Request application shutdown." 'application
        (make-command-effect 'application.quit #f))
      (bind-keys! keymap
        ((list (control-stroke #\b)) 'fundamental.backward-char)
        ((list (control-stroke #\f)) 'fundamental.forward-char)
        ((list (control-stroke #\a)) 'fundamental.beginning-of-line)
        ((list (control-stroke #\e)) 'fundamental.end-of-line)
        ((list (make-key-stroke 'character (char->integer #\space) 4)) 'fundamental.set-mark)
        ((list (control-stroke #\w)) 'fundamental.kill-region)
        ((list (control-stroke #\y)) 'fundamental.yank)
        ((list (make-key-stroke 'character (char->integer #\b) 2)) 'fundamental.backward-word)
        ((list (make-key-stroke 'character (char->integer #\f) 2)) 'fundamental.forward-word)
        ((list (make-key-stroke 'character (char->integer #\w) 2)) 'fundamental.copy-region)
        ((list (control-stroke #\d)) 'fundamental.delete-forward)
        ((list (control-stroke #\g)) 'application.quit)
        ((list (control-stroke #\x) (control-stroke #\c)) 'application.quit)
        ((list (plain-stroke 'left #f)) 'fundamental.backward-char)
        ((list (plain-stroke 'right #f)) 'fundamental.forward-char)
        ((list (plain-stroke 'home #f)) 'fundamental.beginning-of-line)
        ((list (plain-stroke 'end #f)) 'fundamental.end-of-line)
        ;; Non-character keys are normalized without a codepoint by
        ;; key-event->key-stroke. Terminal decoders retain their physical
        ;; codepoint on KeyEvent for inspection, but it is not part of keymap
        ;; identity.
        ((list (plain-stroke 'backspace #f)) 'fundamental.delete-backward)
        ((list (plain-stroke 'delete #f)) 'fundamental.delete-forward)
        ((list (plain-stroke 'enter #f)) 'fundamental.newline))
      editing))

  (define (fundamental-input-context editing active view)
    (unless (and (fundamental-editing? editing) (active-context? active))
      (assertion-violation 'fundamental-input-context "invalid editing package or active context"
                           editing active))
    (make-input-context
      (active-context-view-id active)
      (active-context-buffer-id active)
      (list (make-input-layer 'fundamental (fundamental-editing-keymap editing) #f 'accept))
      (view-state-input-state (view-state view))))

  (define (fundamental-input-disposition context disposition)
    (unless (and (command-context? context) (input-disposition? disposition))
      (assertion-violation 'fundamental-input-disposition
                           "expected a command context and input disposition"
                           context disposition))
    (case (input-disposition-kind disposition)
      [(text)
       (make-command-invoke-message
         'fundamental.insert-text context (list (input-disposition-value disposition)) #f)]
      [else #f]))
)
