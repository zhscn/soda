(library (soda editor commands bookmark)
  (export install-bookmark-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor completion)
          (soda editor edit)
          (soda editor effect)
          (soda editor file)
          (soda editor navigation)
          (soda editor state)
          (soda editor language-state))

  (define (bookmark-choice-source editor)
    (let ([items
            (map
              (lambda (entry)
                (let ([name (bookmark-name entry)])
                  (make-completion-item
                    name
                    'bookmark
                    name
                    name
                    name
                    (or (bookmark-resource entry) "buffer")
                    #f
                    name)))
              (editor-bookmarks editor))])
      (make-choice-source
        'bookmark
        '((category . bookmark) (styles . (fzf)))
        (lambda (input point) (cons 0 (string-length input)))
        (lambda (query) items)
        (lambda (value)
          (exists
            (lambda (item)
              (string=? value (completion-item-insert-text item)))
            items))
        (lambda (generation) #f))))

  (define bookmark-name-reader
    (interactive-completing-read
      "Bookmark: "
      (lambda (context)
        (bookmark-choice-source
          (command-context-editor context)))
      'must-match
      'bookmark
      ""
      #f))

  (define-command (set-bookmark-command context name)
    "Set or replace a named bookmark at point."
    (interactive (interactive-string "Set bookmark: " 'bookmark))
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)])
      (if (zero? (string-length name))
          (editor-set-status-message! editor "Bookmark name is empty")
          (begin
            (editor-set-bookmark!
              editor name (view-buffer view) (view-caret view) #f)
            (editor-set-status-message!
              editor
              (string-append "Bookmark set: " name))))
      '()))

  (define (bookmark-buffer editor entry)
    (or
      (and
        (bookmark-buffer-id entry)
        (find
          (lambda (buffer)
            (= (buffer-id buffer) (bookmark-buffer-id entry)))
          (editor-buffers editor)))
      (and
        (bookmark-resource entry)
        (editor-buffer-for-resource
          editor (bookmark-resource entry)))))

  (define-command (jump-bookmark-command context name)
    "Jump to a named bookmark."
    (interactive bookmark-name-reader)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [entry (editor-find-bookmark editor name)]
           [buffer (and entry (bookmark-buffer editor entry))])
      (cond
        [buffer
         (editor-jump-to-buffer!
           editor
           buffer
           (bookmark-offset-for-buffer entry buffer)
           'bookmark)
         (editor-set-status-message!
           editor (string-append "Bookmark: " name))
         '()]
        [(and entry (bookmark-resource entry))
         (editor-begin-async-jump!
           editor view (bookmark-resource entry) 'bookmark)
         (list
           (make-command-effect
             'file.read
             (make-open-request
               (view-id view)
               (bookmark-resource entry)
               (make-file-source-position
                 (bookmark-line entry)
                 (bookmark-column entry))
               'jump
               (editor-view-resource-context
                 editor
                 (view-id view)))))]
        [else
         (editor-set-status-message! editor "Bookmark target is unavailable")
         '()])))

  (define-command (rename-bookmark-command context old-name new-name)
    "Rename a bookmark."
    (interactive
      bookmark-name-reader
      (interactive-string "Rename bookmark to: " 'bookmark))
    (let ([editor (command-context-editor context)])
      (if (or (zero? (string-length new-name))
              (not
                (editor-rename-bookmark!
                  editor old-name new-name)))
          (editor-set-status-message! editor "Bookmark rename failed")
          (editor-set-status-message!
            editor
            (string-append
              "Bookmark renamed: " old-name " -> " new-name)))
      '()))

  (define-command (delete-bookmark-command context name)
    "Delete a bookmark."
    (interactive bookmark-name-reader)
    (let ([editor (command-context-editor context)])
      (editor-set-status-message!
        editor
        (if (editor-delete-bookmark! editor name)
            (string-append "Bookmark deleted: " name)
            "Bookmark not found"))
      '()))

  (define (bookmark-list-text editor)
    (define (object->string value)
      (let-values ([(port extract) (open-string-output-port)])
        (write value port)
        (extract)))
    (apply
      string-append
      "Bookmark\tResource\tLine:Column\n"
      (map
        (lambda (entry)
          (string-append
            (bookmark-name entry)
            "\t"
            (or (bookmark-resource entry) "<buffer>")
            "\t"
            (number->string (+ (bookmark-line entry) 1))
            ":"
            (number->string (+ (bookmark-column entry) 1))
            (if (bookmark-annotation entry)
                (string-append
                  "\t" (object->string (bookmark-annotation entry)))
                "")
            "\n"))
        (editor-bookmarks editor))))

  (define (list-bookmarks-command context)
    (let* ([editor (command-context-editor context)]
           [resource "*Bookmarks*"]
           [existing (editor-buffer-for-resource editor resource)]
           [contents (string->utf8 (bookmark-list-text editor))]
           [buffer
             (or existing
                 (editor-create-buffer!
                   editor
                   resource
                   'fundamental-mode
                   contents
                   (editor-view-resource-context
                     editor
                     (view-id (command-context-view context)))))])
      (when existing
        (buffer-replace-range-internal!
          buffer 0 (buffer-byte-size buffer) contents))
      (buffer-set-local-setting! buffer 'track-modified? #f)
      (buffer-set-local-setting! buffer 'read-only? #t)
      (editor-set-view-buffer!
        editor
        (view-id (command-context-view context))
        (buffer-id buffer))
      (editor-set-status-message! editor "Bookmarks")
      '()))

  (define (install-bookmark-commands! editor)
    (for-each
      (lambda (definition)
        (editor-register-command! editor definition))
      (list
        (make-interactive-context-command
          'bookmark.set set-bookmark-command "Set a bookmark at point.")
        (make-interactive-context-command
          'bookmark.jump jump-bookmark-command "Jump to a bookmark.")
        (make-interactive-context-command
          'bookmark.rename rename-bookmark-command "Rename a bookmark.")
        (make-interactive-context-command
          'bookmark.delete delete-bookmark-command "Delete a bookmark.")
        (make-interactive-context-command
          'bookmark.list list-bookmarks-command "List bookmarks.")))
    editor))
