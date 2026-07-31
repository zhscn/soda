(library (soda editor fold-runtime)
  (export view-effective-display-map
          install-fold-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor condition)
          (soda editor display-map)
          (soda editor fold)
          (soda editor keymap)
          (soda editor language)
          (soda editor state))

  (define (buffer-fold-captures buffer)
    (let* ([profile (buffer-language-profile buffer)]
           [syntax
             (and profile
                  (language-profile-syntax profile))]
           [session (buffer-language-session buffer)])
      (if
        (and syntax
             session
             (memq 'fold
               (syntax-capabilities syntax)))
        (let ([snapshot
                (document-snapshot
                  (buffer-document buffer))])
          (dynamic-wind
            (lambda () #f)
            (lambda ()
              (let ([text (snapshot-text snapshot)])
                (dynamic-wind
                  (lambda () #f)
                  (lambda ()
                    (syntax-query
                      syntax
                      session
                      'fold
                      0
                      (text-size text)))
                  (lambda () (text-close! text)))))
            (lambda () (snapshot-close! snapshot))))
        '())))

  (define (capture-span capture)
    (- (syntax-capture-end capture)
       (syntax-capture-start capture)))

  (define (better-containing? candidate best)
    (or
      (not best)
      (< (capture-span candidate)
         (capture-span best))))

  (define (better-next? candidate best)
    (or
      (not best)
      (< (syntax-capture-start candidate)
         (syntax-capture-start best))
      (and
        (= (syntax-capture-start candidate)
           (syntax-capture-start best))
        (> (capture-span candidate)
           (capture-span best)))))

  (define (fold-capture-at-or-next captures point)
    (let ([containing
            (fold-left
              (lambda (best capture)
                (if
                  (and
                    (<= (syntax-capture-start capture)
                        point)
                    (< point
                       (syntax-capture-end capture))
                    (better-containing? capture best))
                  capture
                  best))
              #f
              captures)])
      (or
        containing
        (fold-left
          (lambda (best capture)
            (if
              (and
                (>= (syntax-capture-start capture)
                    point)
                (better-next? capture best))
              capture
              best))
          #f
          captures))))

  (define (fold-kind-for-capture capture)
    (let ([kind (syntax-capture-node-kind capture)])
      (if (string? kind)
          (string->symbol kind)
          'syntax)))

  (define (make-capture-fold buffer capture)
    (make-fold
      (buffer-document buffer)
      (syntax-capture-start capture)
      (syntax-capture-end capture)
      (fold-kind-for-capture capture)
      (syntax-capture-name capture)))

  (define (fold-matches-capture? fold capture)
    (and
      (= (fold-start fold)
         (syntax-capture-start capture))
      (= (fold-end fold)
         (syntax-capture-end capture))))

  (define (ranges-overlap? start end fold)
    (and
      (< start (fold-end fold))
      (< (fold-start fold) end)))

  (define (toggle-fold-command context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [buffer (view-buffer view)]
           [captures (buffer-fold-captures buffer)]
           [capture
             (fold-capture-at-or-next
               captures
               (view-caret view))])
      (unless capture
        (editor-user-error
          'display.toggle-fold
          "No fold is available"))
      (let ([existing
              (find
                (lambda (fold)
                  (fold-matches-capture?
                    fold capture))
                (view-folds view))])
        (if existing
            (editor-replace-view-folds!
              editor
              (view-id view)
              (filter
                (lambda (fold)
                  (not (eq? fold existing)))
                (view-folds view)))
            (let* ([start
                     (syntax-capture-start capture)]
                   [end
                     (syntax-capture-end capture)]
                   [retained
                     (filter
                       (lambda (fold)
                         (not
                           (ranges-overlap?
                             start end fold)))
                       (view-folds view))]
                   [fold
                     (make-capture-fold
                       buffer capture)])
              (editor-replace-view-folds!
                editor
                (view-id view)
                (cons fold retained))
              (view-set-caret! view start))))
      '()))

  (define (outer-captures captures)
    (let ([sorted
            (list-sort
              (lambda (left right)
                (or
                  (< (syntax-capture-start left)
                     (syntax-capture-start right))
                  (and
                    (= (syntax-capture-start left)
                       (syntax-capture-start right))
                    (> (syntax-capture-end left)
                       (syntax-capture-end right)))))
              captures)])
      (let loop
        ([remaining sorted]
         [last-end #f]
         [result '()])
        (if (null? remaining)
            (reverse result)
            (let* ([capture (car remaining)]
                   [start
                     (syntax-capture-start capture)]
                   [end
                     (syntax-capture-end capture)])
              (if
                (and last-end (< start last-end))
                (loop
                  (cdr remaining)
                  last-end
                  result)
                (loop
                  (cdr remaining)
                  end
                  (cons capture result))))))))

  (define (fold-all-command context)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [buffer (view-buffer view)]
           [captures
             (outer-captures
               (buffer-fold-captures buffer))])
      (when (null? captures)
        (editor-user-error
          'display.fold-all
          "Major mode provides no folds"))
      (editor-replace-view-folds!
        editor
        (view-id view)
        (map
          (lambda (capture)
            (make-capture-fold buffer capture))
          captures))
      '()))

  (define (unfold-all-command context)
    (editor-clear-view-folds!
      (command-context-editor context)
      (view-id (command-context-view context)))
    '())

  (define (stroke character modifiers)
    (make-key-stroke
      'character
      (char->integer character)
      modifiers))

  (define (install-fold-commands! editor)
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (make-interactive-context-command
            (car entry)
            (cadr entry)
            (caddr entry))))
      (list
        (list
          'display.toggle-fold
          toggle-fold-command
          "Toggle the syntax fold at or after point.")
        (list
          'display.fold-all
          fold-all-command
          "Collapse outer syntax folds in the active view.")
        (list
          'display.unfold-all
          unfold-all-command
          "Expand every fold in the active view.")))
    (for-each
      (lambda (entry)
        (editor-bind-key!
          editor
          (car entry)
          (cdr entry)))
      (list
        (cons
          (list
            (stroke #\c 2)
            (stroke #\@ 0)
            (stroke #\c 2))
          'display.toggle-fold)
        (cons
          (list
            (stroke #\c 2)
            (stroke #\@ 0)
            (stroke #\a 2))
          'display.fold-all)
        (cons
          (list
            (stroke #\c 2)
            (stroke #\@ 0)
            (stroke #\s 2))
          'display.unfold-all)))
    editor))
