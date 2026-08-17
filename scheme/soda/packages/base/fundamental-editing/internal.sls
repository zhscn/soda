(library (soda packages base fundamental-editing internal)
  (export make-fundamental-editing!
          fundamental-editing?
          fundamental-editing-keymap
          fundamental-mode
          fundamental-fallback-input-layer
          fundamental-input-disposition)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel syntax-profile)
          (soda kernel view-state)
          (soda kernel viewport)
          (soda packages base text-motion)
          (soda packages base text-format)
          (soda packages base fundamental-keymap)
          (soda packages base fundamental-motion)
          (soda packages base fundamental-edit)
          (soda packages base fundamental-kill)
          (soda packages base fundamental-interface)
          (soda packages base fundamental-selection)
          (soda packages base editing-options)
          (soda packages base editing-context)
          (soda packages buffer-mode)
          (soda host command)
          (soda host command-message)
          (soda host context)
          (soda host input)
          (soda host input-event)
          (soda host package)
          (soda host package-context)
          (soda host render)
          (soda host view)
          (soda host value)
          (soda packages interaction)
          (soda ffi unicode)
          (soda view frame)
          (soda view text-layout-options)
          (soda view visual-geometry))

  ;; Fundamental editing is an ordinary package: it owns command
  ;; registrations and a keymap, while all mutation remains a TransactionSpec
  ;; interpreted by CommandRuntime and Dispatcher.
  (define-record-type
    (fundamental-editing %make-fundamental-editing fundamental-editing?)
    (fields (immutable keymap fundamental-editing-keymap)
            (immutable mode fundamental-mode)
            (immutable kill-ring fundamental-editing-kill-ring)))

  (define-syntax install-command!
    (syntax-rules (visible)
      [(_ package-context name (context . arguments) documentation class (visible user-visible?) body ...)
       (package-context-register-command!
         package-context
         (make-command-definition
           name (lambda (context . arguments) body ...)
           (package-context-owner package-context)
           documentation class #f 'mode
           (make-command-policy
             name
             (and (memq class '(editing motion selection kill yank viewport)) #t)
             (if (memq class '(editing kill yank)) 'amalgamate 'ignore)
             #f #f)
           user-visible?))]
      [(_ package-context name (context . arguments) documentation class body ...)
       (install-command! package-context name (context . arguments) documentation class
                         (visible #t) body ...)]))

  (define (make-fundamental-editing! host package-context)
    (unless (and (package-host? host)
                 (package-context? package-context)
                 (package-context-host? package-context host))
      (assertion-violation 'make-fundamental-editing!
                           "expected a PackageHost and its PackageContext"
                           host package-context))
    (let* ([keymap (make-keymap 'fundamental)]
           [mode
            (make-mode-spec
              'fundamental-mode 'major "Fundamental" #f
              (list
                (make-buffer-syntax-profile-extension
                  (make-plain-text-syntax-profile))
                (make-buffer-input-layer-extension
                  (list (make-input-layer 'major keymap #f 'accept))))
              '(editing motion selection kill yank viewport interface completion)
              "Fund")]
           [editing (%make-fundamental-editing keymap mode (make-kill-ring))])
      (package-context-register-effect-handler!
        package-context 'fundamental.record-kill 'fundamental-kill-ring
        (lambda (service invocation effect)
          (record-kill! (fundamental-editing-kill-ring editing)
                        (command-effect-payload effect))))
      (package-context-register-effect-handler!
        package-context 'fundamental.redraw 'fundamental-surface-invalidation
        (lambda (ignored invocation effect)
          (package-host-invalidate-surface!
            host (command-effect-payload effect))))
      (install-command!
        package-context 'fundamental.insert-text (context inserted)
        "Insert committed text at every selection." 'editing (visible #f)
        (auto-fill-insert context inserted))
      (install-command!
        package-context 'fundamental.newline (context)
        "Insert a newline and preserve leading indentation at every selection." 'editing
        (insert-newline context))
      (install-command!
        package-context 'fundamental.insert-tab (context)
        "Insert the configured indentation unit at every selection." 'editing
        (replace-selection context (indentation-bytes (context-indent-options context))))
      (install-command!
        package-context 'fundamental.open-line (context)
        "Insert a newline before every caret without moving it." 'editing
        (open-line context))
      (install-command!
        package-context 'fundamental.delete-backward (context)
        "Delete the active region or preceding grapheme." 'editing
        (delete-selection-or-character context 'backward))
      (install-command!
        package-context 'fundamental.delete-forward (context)
        "Delete the active region or following grapheme." 'editing
        (delete-selection-or-character context 'forward))
      (install-command!
        package-context 'fundamental.backward-char (context)
        "Move every selection backward by one grapheme." 'motion
        (move-selection context 'backward))
      (install-command!
        package-context 'fundamental.forward-char (context)
        "Move every selection forward by one grapheme." 'motion
        (move-selection context 'forward))
      (install-command!
        package-context 'fundamental.backward-word (context)
        "Move every selection backward by one Unicode word." 'motion
        (move-word context 'backward))
      (install-command!
        package-context 'fundamental.forward-word (context)
        "Move every selection forward by one Unicode word." 'motion
        (move-word context 'forward))
      (install-command!
        package-context 'fundamental.beginning-of-line (context)
        "Move every selection to the start of its logical line." 'motion
        (move-line-boundary context 'start))
      (install-command!
        package-context 'fundamental.end-of-line (context)
        "Move every selection to the end of its logical line." 'motion
        (move-line-boundary context 'end))
      (install-command!
        package-context 'fundamental.previous-line (context)
        "Move every selection to the preceding logical line." 'motion
        (move-logical-line context -1))
      (install-command!
        package-context 'fundamental.next-line (context)
        "Move every selection to the following logical line." 'motion
        (move-logical-line context 1))
      (install-command!
        package-context 'fundamental.beginning-of-buffer (context)
        "Move every selection to the beginning of the Buffer." 'motion
        (move-buffer-boundary context #f))
      (install-command!
        package-context 'fundamental.end-of-buffer (context)
        "Move every selection to the end of the Buffer." 'motion
        (move-buffer-boundary context #t))
      (define-package-command
        package-context 'fundamental.goto-line (context line column)
        (documentation "Move every selection to one-based LINE and optional COLUMN.")
        (class 'motion)
        (scope 'mode)
        (interactive (make-interactive-plan (list (make-goto-reader))))
        (semantic 'fundamental.goto-line)
        (repeatable #t)
        (undo 'ignore)
        (goto-line-column context line column))
      (install-command!
        package-context 'fundamental.indent-lines (context)
        "Indent each logical line selected by the active regions." 'editing
        (shift-selected-lines context 'indent))
      (install-command!
        package-context 'fundamental.unindent-lines (context)
        "Remove one tab or one configured space indentation from selected lines." 'editing
        (shift-selected-lines context 'unindent))
      (install-command!
        package-context 'fundamental.matching-delimiter (context)
        "Move point to the matching ASCII parenthesis, bracket, or brace." 'motion
        (move-matching-delimiter context))
      (install-command!
        package-context 'fundamental.fill-paragraph (context)
        "Reflow the active region or paragraph at point to eighty columns." 'editing
        (fill-paragraph context))
      (install-command!
        package-context 'fundamental.transpose-characters (context)
        "Transpose the graphemes around point." 'editing
        (transpose-characters context))
      (install-command!
        package-context 'fundamental.scroll-up (context)
        "Scroll the Viewport toward the beginning of the Buffer." 'viewport
        (fundamental-scroll-visual context -1 #t))
      (install-command!
        package-context 'fundamental.scroll-down (context)
        "Scroll the Viewport toward the end of the Buffer." 'viewport
        (fundamental-scroll-visual context 1 #t))
      (install-command!
        package-context 'fundamental.scroll-backward-line (context)
        "Scroll the Viewport backward by one visual row." 'viewport
        (fundamental-scroll-visual context -1 #f))
      (install-command!
        package-context 'fundamental.scroll-forward-line (context)
        "Scroll the Viewport forward by one visual row." 'viewport
        (fundamental-scroll-visual context 1 #f))
      (install-command!
        package-context 'fundamental.pointer-select (context)
        "Select document content targeted by a pointer event." 'selection (visible #f)
        (fundamental-pointer-selection context))
      (install-command!
        package-context 'fundamental.pointer-scroll (context amount page?)
        "Scroll the targeted View from a pointer wheel event." 'viewport (visible #f)
        (fundamental-scroll-visual context amount page?))
      (install-command!
        package-context 'fundamental.recenter (context)
        "Center point vertically in the active Window." 'viewport
        (fundamental-recenter-viewport context 'center))
      (install-command!
        package-context 'fundamental.recenter-top (context)
        "Place point at the top of the active Window." 'viewport
        (fundamental-recenter-viewport context 'top))
      (install-command!
        package-context 'fundamental.recenter-bottom (context)
        "Place point at the bottom of the active Window." 'viewport
        (fundamental-recenter-viewport context 'bottom))
      (install-command!
        package-context 'fundamental.move-to-window-top (context)
        "Move point to the top visual row of the active Window." 'motion
        (fundamental-move-to-viewport-row context 'top))
      (install-command!
        package-context 'fundamental.move-to-window-center (context)
        "Move point to the center visual row of the active Window." 'motion
        (fundamental-move-to-viewport-row context 'center))
      (install-command!
        package-context 'fundamental.move-to-window-bottom (context)
        "Move point to the bottom visual row of the active Window." 'motion
        (fundamental-move-to-viewport-row context 'bottom))
      (install-command!
        package-context 'fundamental.redraw (context)
        "Request a fresh presentation of the active Surface." 'interface
        (let ([surface-id (command-context-surface-id context)])
          (if (and (integer? surface-id) (exact? surface-id) (>= surface-id 0))
              (make-command-effect 'fundamental.redraw surface-id)
              (command-handled))))
      (install-command!
        package-context 'fundamental.set-mark (context)
        "Set the mark at every selection and activate the region." 'selection
        (fundamental-set-mark context))
      (install-command!
        package-context 'fundamental.deactivate-mark (context)
        "Deactivate every active region." 'selection
        (fundamental-deactivate-mark context))
      (install-command!
        package-context 'fundamental.mark-whole-buffer (context)
        "Select the whole Buffer." 'selection
        (fundamental-mark-whole-buffer context))
      (install-command!
        package-context 'fundamental.exchange-point-and-mark (context)
        "Exchange point and mark in the primary region." 'selection
        (fundamental-exchange-point-and-mark context))
      (install-command!
        package-context 'fundamental.copy-region (context)
        "Copy the primary active region to the kill ring and clipboard." 'kill
        (copy-region context))
      (install-command!
        package-context 'fundamental.kill-region (context)
        "Kill the primary active region to the kill ring and clipboard." 'kill
        (kill-region context))
      (install-command!
        package-context 'fundamental.kill-word (context)
        "Kill the active region or the following word." 'kill
        (kill-word context 'forward))
      (install-command!
        package-context 'fundamental.backward-kill-word (context)
        "Kill the active region or the preceding word." 'kill
        (kill-word context 'backward))
      (install-command!
        package-context 'fundamental.kill-line (context)
        "Kill the active region or text through the next logical line boundary." 'kill
        (kill-line context))
      (install-command!
        package-context 'fundamental.kill-whole-line (context)
        "Kill the active region, or the complete current logical line." 'kill
        (kill-whole-line context))
      (install-command!
        package-context 'fundamental.yank (context)
        "Insert the newest kill-ring entry at every selection." 'yank
        (yank context (fundamental-editing-kill-ring editing)))
      (install-fundamental-keymap! keymap)
      editing))

  ;; Temporary editable interfaces reuse the package-owned bindings without
  ;; adopting fundamental-mode as their major mode.  The default rank leaves
  ;; transient and interface-local maps in control of their own keys.
  (define (fundamental-fallback-input-layer editing)
    (unless (fundamental-editing? editing)
      (assertion-violation
        'fundamental-fallback-input-layer "expected a fundamental editing service" editing))
    (make-input-layer
      'default (fundamental-editing-keymap editing) #f 'accept))

  (define (fundamental-input-disposition context disposition)
    (unless (and (command-context? context) (input-disposition? disposition))
      (assertion-violation 'fundamental-input-disposition
                           "expected a command context and input disposition"
                           context disposition))
    (case (input-disposition-kind disposition)
      [(text)
       (make-command-invoke-message
         'fundamental.insert-text context (list (input-disposition-value disposition)) #f)]
      [(pass)
       (let ([event (command-context-event context)])
         (and (pointer-event? event)
              (case (pointer-event-phase event)
                [(wheel)
                 (let* ([direction
                         (case (pointer-event-button event)
                           [(wheel-up) -1] [(wheel-down) 1]
                           [else 0])]
                        [page? (pointer-event-modifier? event 'alt)]
                        [step
                         (if (pointer-event-modifier? event 'ctrl) 5 1)])
                   (and (not (zero? direction))
                        (make-command-invoke-message
                          'fundamental.pointer-scroll context
                          (list (* direction step) page?) #f)))]
                [(press move)
                 (and (memq (pointer-event-button event) '(left none))
                      (make-command-invoke-message
                        'fundamental.pointer-select context '() #f))]
                [else #f])))]
      [else #f]))
)
