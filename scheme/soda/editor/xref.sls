(library (soda editor xref)
  (export make-xref-backend
          xref-backend?
          xref-backend-name
          editor-register-xref-backend!
          dispatch-xref
          install-xref-results!
          editor-begin-xref-results!
          editor-show-xref-results!)
  (import (rnrs)
          (only (chezscheme) make-weak-eq-hashtable)
          (soda editor command)
          (soda editor condition)
          (soda editor event)
          (soda editor keymap)
          (soda editor language)
          (soda editor location)
          (soda editor location-results)
          (soda editor result-buffer)
          (soda editor result-edit)
          (soda editor state))

  (define editor-xref-backends
    (make-weak-eq-hashtable))

  (define-record-type (xref-backend %make-xref-backend xref-backend?)
    (fields name priority applicable? definitions references))

  (define (make-xref-backend
            name priority applicable? definitions references)
    (unless (symbol? name)
      (assertion-violation 'make-xref-backend "name must be a symbol" name))
    (unless (and (integer? priority) (exact? priority))
      (assertion-violation
        'make-xref-backend "priority must be an exact integer" priority))
    (unless (and (procedure? applicable?)
                 (procedure? definitions)
                 (procedure? references))
      (assertion-violation
        'make-xref-backend
        "backend operations must be procedures"
        applicable? definitions references))
    (%make-xref-backend name priority applicable? definitions references))

  (define (editor-register-xref-backend! editor backend)
    (unless (xref-backend? backend)
      (assertion-violation
        'editor-register-xref-backend! "expected an xref backend" backend))
    (let* ([current (hashtable-ref editor-xref-backends editor '())]
           [without
             (filter
               (lambda (item)
                 (not (eq? (xref-backend-name item) (xref-backend-name backend))))
               current)])
      (hashtable-set!
        editor-xref-backends
        editor
        (list-sort
          (lambda (left right)
            (> (xref-backend-priority left) (xref-backend-priority right)))
          (cons backend without))))
    backend)

  (define (xref-backend-for-context context)
    (find
      (lambda (backend) ((xref-backend-applicable? backend) context))
      (hashtable-ref
        editor-xref-backends
        (command-context-editor context)
        '())))

  (define (dispatch-xref context operation)
    (let ([backend (xref-backend-for-context context)])
      (unless backend
        (editor-user-error operation "No xref backend is available for this Buffer"))
      ((case operation
         [(xref.find-definition) (xref-backend-definitions backend)]
         [(xref.find-references) (xref-backend-references backend)]
         [else
          (assertion-violation 'dispatch-xref "unknown xref operation" operation)])
       context)))

  (define (install-xref-results! editor)
    (install-location-results! editor)
    (register-major-mode!
      (editor-language-catalog editor)
      (make-major-mode
        'xref-results-mode 'location-results-mode #f 'interface
        'xref-results-mode-map
        '((track-modified? . #f) (read-only? . #t))))
    (let ([keymap (make-keymap)])
      (keymap-bind!
        keymap
        (list
          (make-key-stroke
            'character (char->integer #\e) 0))
        'result-edit.begin)
      (keymap-catalog-register!
        (editor-keymap-catalog editor) 'xref-results-mode-map keymap))
    editor)

  (define (%editor-show-xref-results!
            editor locations origin-view-id refresh)
    (unless (and (location-list? locations)
                 (or (not refresh) (procedure? refresh)))
      (assertion-violation
        'editor-show-xref-results!
        "expected a LocationList and optional refresh procedure"
        locations refresh))
    (let* ([presentation
             (make-location-list (location-list-source locations) '())]
           [buffer
             (editor-open-result-buffer!
               editor "*Xref*" 'xref-results-mode
               "References" presentation origin-view-id
               'xref #f #f)])
      (editor-set-current-location-list! editor presentation)
      (editor-append-location-results!
        editor buffer (location-list-items locations))
      (when (null? (location-list-items locations))
        (editor-append-result-message!
          editor buffer "No references." 'info))
      (when refresh
        (buffer-set-result-refresh! buffer refresh))
      (when refresh
        (buffer-enable-result-edit-action!
          buffer "Edit reference targets"))
      buffer))

  (define (editor-begin-xref-results! editor origin-view-id refresh)
    (unless (and (editor? editor)
                 (integer? origin-view-id) (exact? origin-view-id)
                 (positive? origin-view-id)
                 (procedure? refresh))
      (assertion-violation
        'editor-begin-xref-results!
        "expected an Editor, origin View id, and refresh procedure"
        editor origin-view-id refresh))
    (let* ([locations (make-location-list 'lsp-references '())]
           [buffer
             (editor-open-result-buffer!
               editor "*Xref*" 'xref-results-mode
               "References" locations origin-view-id
               'xref #f #f)])
      (editor-set-current-location-list! editor locations)
      (buffer-set-result-refresh! buffer refresh)
      (buffer-enable-result-edit-action!
        buffer "Edit reference targets")
      (buffer-set-result-producer-state! buffer 'running)
      (editor-append-result-message!
        editor buffer "Searching references..." 'info)
      buffer))

  (define editor-show-xref-results!
    (case-lambda
      [(editor locations origin-view-id)
       (%editor-show-xref-results!
         editor locations origin-view-id #f)]
      [(editor locations origin-view-id refresh)
       (%editor-show-xref-results!
         editor locations origin-view-id refresh)]))
)
