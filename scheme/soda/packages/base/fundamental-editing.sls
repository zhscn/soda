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
    (fields (immutable keymap fundamental-editing-keymap)))

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

  (define (collapse-selection selection position)
    (make-selection
      (list (make-selection-range position position))
      0))

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
                    (make-selection-range position position)))
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
                          (make-selection-range mapped mapped)))
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
                        (make-selection-range position position)))
                    (selection-ranges selection))
                  (selection-primary selection))]
               [state (command-context-view-state context)])
          (make-view-transaction-spec
            (command-context-view-id context) (view-state-generation state)
            next #f #f '() '() #f)))))

  (define (install-command! runtime owner name procedure documentation class)
    (command-runtime-register-command!
      runtime
      (make-command-definition name procedure owner documentation class #f)))

  (define (make-fundamental-editing! runtime owner)
    (unless (and (command-runtime? runtime) (owner? owner))
      (assertion-violation 'make-fundamental-editing! "expected a runtime and owner" runtime owner))
    (let ([keymap (make-keymap 'fundamental)])
      (install-command!
        runtime owner 'fundamental.insert-text
        (lambda (context inserted) (replace-selection context inserted))
        "Insert committed text at every selection." 'editing)
      (install-command!
        runtime owner 'fundamental.newline
        (lambda (context) (replace-selection context (string->utf8 "\n")))
        "Insert a newline at every selection." 'editing)
      (install-command!
        runtime owner 'fundamental.delete-backward
        (lambda (context) (delete-selection-or-character context 'backward))
        "Delete the active region or preceding grapheme." 'editing)
      (install-command!
        runtime owner 'fundamental.delete-forward
        (lambda (context) (delete-selection-or-character context 'forward))
        "Delete the active region or following grapheme." 'editing)
      (install-command!
        runtime owner 'fundamental.backward-char
        (lambda (context) (move-selection context 'backward))
        "Move every selection backward by one grapheme." 'motion)
      (install-command!
        runtime owner 'fundamental.forward-char
        (lambda (context) (move-selection context 'forward))
        "Move every selection forward by one grapheme." 'motion)
      (install-command!
        runtime owner 'application.quit
        (lambda (context) (make-command-effect 'application.quit #f))
        "Request application shutdown." 'application)
      (keymap-bind! keymap (list (control-stroke #\b)) 'fundamental.backward-char)
      (keymap-bind! keymap (list (control-stroke #\f)) 'fundamental.forward-char)
      (keymap-bind! keymap (list (control-stroke #\d)) 'fundamental.delete-forward)
      (keymap-bind! keymap (list (control-stroke #\g)) 'application.quit)
      (keymap-bind! keymap (list (control-stroke #\x) (control-stroke #\c))
                   'application.quit)
      (keymap-bind! keymap (list (plain-stroke 'left #f)) 'fundamental.backward-char)
      (keymap-bind! keymap (list (plain-stroke 'right #f)) 'fundamental.forward-char)
      (keymap-bind! keymap (list (plain-stroke 'backspace 127)) 'fundamental.delete-backward)
      (keymap-bind! keymap (list (plain-stroke 'delete #f)) 'fundamental.delete-forward)
      (keymap-bind! keymap (list (plain-stroke 'enter 13)) 'fundamental.newline)
      (%make-fundamental-editing keymap)))

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
