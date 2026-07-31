#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor display-placement)
        (soda editor language)
        (soda editor language-session)
        (soda editor jump-graph)
        (soda editor location)
        (soda editor navigation)
        (soda editor resource-context)
        (soda editor state)
        (soda editor workbench))

(define (check condition message . irritants)
  (unless condition
    (apply assertion-violation 'language-session-tests message irritants)))

(define document (make-document "source" 9401))
(define buffer-a
  (make-buffer 9402 document "/workspace/a.cpp" 'fundamental-mode))
(define editor (make-editor-state buffer-a))
(define buffer-b
  (editor-create-buffer!
    editor "/dependency/b.hpp" 'fundamental-mode "header"))
(define buffer-c
  (editor-create-buffer!
    editor "/workspace/c.cpp" 'fundamental-mode "other"))

(define key
  (make-language-session-key
    'cpp
    'clangd
    '("/workspace")
    '((compile-commands . "/workspace/build"))
    '("clang" "22")
    '(semantic-tokens xref)))
(define session (editor-ensure-language-session! editor key))
(check
  (eq? session
       (editor-ensure-language-session!
         editor
         (make-language-session-key
           'cpp
           'clangd
           '("/workspace")
           '((compile-commands . "/workspace/build"))
           '("clang" "22")
           '(semantic-tokens xref))))
  "structurally equal keys must share one LanguageSession")

(define home
  (editor-attach-language-session!
    editor
    (buffer-id buffer-a)
    session
    'home
    (view-id (editor-active-view editor))))
(editor-set-view-language-attachment!
  editor
  (view-id (editor-active-view editor))
  home)

(define target
  (editor-display-buffer!
    editor
    (make-display-request
      (buffer-id buffer-b)
      'jump
      (view-id (editor-active-view editor))
      #f
      (editor-view-resource-context
        editor
        (view-id (editor-active-view editor))))))
(define inherited
  (editor-view-language-attachment editor (view-id target)))
(check
  (and
    inherited
    (= (language-attachment-buffer-id inherited) (buffer-id buffer-b))
    (= (language-attachment-session-id inherited) (language-session-id session))
    (eq? (language-attachment-provenance inherited) 'inherited))
  "display must translate the frozen origin attachment to the target Buffer")

(editor-jump-view-to-buffer!
  editor target buffer-a 1 'definition)
(define returned-home
  (editor-view-language-attachment editor (view-id target)))
(define jump
  (car (reverse (navigation-walk-jumps (view-navigation-walk target)))))
(check
  (and
    (eq? returned-home home)
    (view-language-context?
      (location-item-language-context
        (jump-history-entry-source jump)))
    (view-language-context?
      (location-item-language-context
        (jump-history-entry-target jump)))
    (=
      (view-language-context-attachment-id
        (location-item-language-context
          (jump-history-entry-target jump)))
      (language-attachment-id home)))
  "navigation history must preserve source and target attachment provenance")
(check
  (= (length
       (jump-graph-edges
         (workbench-jump-graph (editor-active-workbench editor))))
     1)
  "semantic navigation must record an edge in the Workbench JumpGraph")

(define independent
  (editor-open-view!
    editor
    (buffer-id buffer-b)
    (make-resource-context "/dependency")))
(check
  (not (editor-view-language-attachment editor (view-id independent)))
  "attachment selection must remain per View")

(register-language-profile!
  (editor-language-catalog editor)
  (make-language-profile
    'bootstrap-test
    #f
    #f
    '()
    #f
    #f
    #f
    '()
    #f
    (lambda (owner buffer context) key)))
(register-major-mode!
  (editor-language-catalog editor)
  (make-major-mode
    'bootstrap-test-mode
    'fundamental-mode
    'bootstrap-test
    'editing
    #f
    '()))
(buffer-set-major-mode! buffer-c 'bootstrap-test-mode)
(define bootstrap-view
  (editor-open-view!
    editor
    (buffer-id buffer-c)
    (make-resource-context "/workspace")))
(define bootstrapped
  (editor-bootstrap-view-language-session!
    editor
    (view-id bootstrap-view)))
(check
  (and
    bootstrapped
    (eq? (language-attachment-provenance bootstrapped) 'home)
    (= (language-attachment-session-id bootstrapped)
       (language-session-id session))
    (eq? bootstrapped
         (editor-view-language-attachment
           editor
           (view-id bootstrap-view))))
  "a language profile must bootstrap and select a home attachment")
(editor-close-view! editor (view-id bootstrap-view))
(editor-remove-buffer! editor (buffer-id buffer-c))
(check
  (null?
    (language-session-registry-buffer-attachments
      (editor-language-session-registry editor)
      (buffer-id buffer-c)))
  "removing a Buffer must release its LanguageAttachments")

(editor-close-view! editor (view-id independent))
(editor-close! editor)
(display "language session tests passed\n")
