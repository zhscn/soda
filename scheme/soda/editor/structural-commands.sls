(library (soda editor structural-commands)
  (export install-structural-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor bytevector)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor command-target)
          (soda editor condition)
          (soda editor edit)
          (soda editor indentation-runtime)
          (soda editor keymap)
          (soda editor kill)
          (soda editor mode-runtime)
          (soda editor state)
          (soda editor structure)
          (soda editor structure-runtime))

  (define (context-view context)
    (command-context-view context))

  (define (context-buffer context)
    (view-buffer (context-view context)))

  (define (structure-index context)
    (buffer-effective-structure-index
      (context-buffer context)))

  (define (require-target who target message)
    (or target (editor-user-error who message)))

  (define (mode-motion-target
            context feature default offset count)
    (let* ([buffer (context-buffer context)]
           [index (structure-index context)]
           [procedure
             (buffer-major-mode-function
               buffer
               feature
               default)])
      (and procedure
           (procedure buffer index offset count))))

  (define (forward-sexp-target context offset count)
    (mode-motion-target
      context
      'forward-sexp-function
      (lambda (buffer index point amount)
        (structure-forward-target
          index
          'sexp
          point
          amount))
      offset
      count))

  (define (move-sexp-command context count)
    (let* ([view (context-view context)]
           [target
             (forward-sexp-target
               context
               (view-caret view)
               count)])
      (view-set-caret!
        view
        (require-target
          (if (negative? count)
              'move.backward-sexp
              'move.forward-sexp)
          target
          (if (negative? count)
              "No previous expression"
              "No next expression")))
      '()))

  (define (forward-sexp-command context)
    (move-sexp-command
      context
      (command-context-count context)))

  (define (backward-sexp-command context)
    (move-sexp-command
      context
      (- (command-context-count context))))

  (define (repeat-list-motion
            who context direction count target-procedure)
    (let ([index (structure-index context)])
      (let loop
        ([remaining (abs count)]
         [point (view-caret (context-view context))]
         [direction
           (if (negative? count)
               (if (eq? direction 'forward)
                   'backward
                   'forward)
               direction)])
        (if (zero? remaining)
            point
            (let ([next
                    (target-procedure
                      index
                      point
                      direction)])
              (if next
                  (loop (- remaining 1) next direction)
                  (editor-user-error
                    who
                    "No enclosing or following list")))))))

  (define (up-list-command context direction who)
    (view-set-caret!
      (context-view context)
      (repeat-list-motion
        who
        context
        direction
        (command-context-count context)
        structure-up-target))
    '())

  (define (backward-up-list-command context)
    (up-list-command
      context
      'backward
      'move.backward-up-list))

  (define (forward-up-list-command context)
    (up-list-command
      context
      'forward
      'move.forward-up-list))

  (define (down-list-command context)
    (view-set-caret!
      (context-view context)
      (repeat-list-motion
        'move.down-list
        context
        'forward
        (command-context-count context)
        structure-down-target))
    '())

  (define (backward-down-list-command context)
    (view-set-caret!
      (context-view context)
      (repeat-list-motion
        'move.backward-down-list
        context
        'backward
        (command-context-count context)
        structure-down-target))
    '())

  (define (mark-sexp-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [point (view-caret view)]
           [extend?
             (and
               (view-mark-active? view)
               (eq? (editor-last-command editor) 'mark.sexp))]
           [origin
             (if extend? (view-mark view) point)]
           [default-direction
             (if
               (and extend? (< origin point))
               -1
               1)]
           [count
             (*
               default-direction
               (command-context-count context))]
           [target
             (forward-sexp-target context origin count)])
      (view-set-mark!
        view
        (require-target
          'mark.sexp
          target
          "No expression to mark"))
      (editor-set-status-message! editor "Mark set")
      '()))

  (define (kill-sexp-target context)
    (let* ([start
             (view-caret
               (context-view context))]
           [end
             (require-target
               'edit.kill-sexp
               (forward-sexp-target
                 context
                 start
                 (command-context-count context))
               "No expression to kill")])
      (command-context-range-target
        context 'sexp start end)))

  (define kill-sexp-target-reader
    (make-command-target-reader
      'kill-sexp-target
      (make-command-target-selector
        'ignore #f kill-sexp-target)))

  (define-command (kill-sexp-command context target)
    "Kill balanced expressions selected by the prefix count."
    (interactive kill-sexp-target-reader)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [buffer (context-buffer context)])
      (unless (command-target-current? target buffer)
        (editor-user-error
          'edit.kill-sexp
          "The expression target is stale"))
      (unless (command-target-empty? target)
        (editor-kill-buffer-target!
          editor
          buffer
          target)
        (view-set-caret!
          view
          (command-target-start target))
        (view-clear-mark! view))
      '()))

  (define (with-buffer-text buffer procedure)
    (let ([snapshot
            (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda () (procedure text))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot)))))

  (define (transpose-pair index point)
    (let* ([at (structure-index-thing-at index 'sexp point)]
           [current
             (and
               at
               (< (structural-thing-start at) point)
               (< point (structural-thing-end at))
               (not
                 (and
                   (structural-thing-has-role? at 'list)
                   (< (structural-thing-start at) point))))]
           [left
             (or current
                 (structure-index-previous
                   index
                   'sexp
                   point))]
           [right
             (and
               left
               (structure-index-next
                 index
                 'sexp
                 (structural-thing-end left)))])
      (if right
          (values left right)
          (let* ([last
                   (structure-index-previous
                     index
                     'sexp
                     point)]
                 [previous
                   (and
                     last
                     (structure-index-previous
                       index
                       'sexp
                       (structural-thing-start last)))])
            (values previous last)))))

  (define (transpose-sexps-once! context)
    (let* ([view (context-view context)]
           [buffer (context-buffer context)]
           [index (structure-index context)])
      (call-with-values
        (lambda ()
          (transpose-pair index (view-caret view)))
        (lambda (left right)
          (unless (and left right)
            (editor-user-error
              'edit.transpose-sexps
              "No pair of expressions to transpose"))
          (let ([start (structural-thing-start left)]
                [middle-left (structural-thing-end left)]
                [middle-right (structural-thing-start right)]
                [end (structural-thing-end right)])
            (with-buffer-text
              buffer
              (lambda (text)
                (buffer-replace-range!
                  buffer
                  start
                  end
                  (bytevector-append
                    (text-subbytevector
                      text
                      middle-right
                      end)
                    (text-subbytevector
                      text
                      middle-left
                      middle-right)
                    (text-subbytevector
                      text
                      start
                      middle-left)))))
            (view-set-caret! view end)
            #t)))))

  (define (transpose-sexps-command context)
    (let ([count (command-context-count context)])
      (when (negative? count)
        (editor-user-error
          'edit.transpose-sexps
          "Transpose count must be non-negative"))
      (do ([remaining count (- remaining 1)])
          [(zero? remaining)]
        (transpose-sexps-once! context))
      '()))

  (define (thing-command-target context source thing)
    (command-context-range-target
      context
      source
      (structural-thing-start thing)
      (structural-thing-end thing)
      (list
        (cons 'roles (structural-thing-roles thing))
        (cons 'depth (structural-thing-depth thing))
        (cons 'node-kind
              (structural-thing-node-kind thing)))))

  (define (indent-sexp-fallback context)
    (let* ([view (context-view context)]
           [point (view-caret view)]
           [index (structure-index context)]
           [defun?
             (and (command-context-prefix context) #t)]
           [thing
             (if defun?
                 (or
                   (structure-index-thing-at
                     index 'defun point)
                   (structure-index-next
                     index 'defun point))
                 (structure-index-next
                   index 'sexp point))])
      (and
        thing
        (thing-command-target
          context
          (if defun? 'defun 'thing)
          thing))))

  (define indent-sexp-selector
    (make-command-target-selector
      'prefer
      #f
      indent-sexp-fallback))

  (define indent-sexp-target-reader
    (make-command-target-reader
      'indent-target
      indent-sexp-selector))

  (define-command (indent-sexp-command context target)
    "Reindent a region, expression, or prefix-selected definition."
    (interactive indent-sexp-target-reader)
    (let* ([view (context-view context)]
           [buffer (context-buffer context)])
      (unless (command-target-current? target buffer)
        (editor-user-error
          'edit.indent-sexp
          "The indentation target is stale"))
      (unless
        (buffer-reindent-range!
          buffer
          (command-target-start target)
          (command-target-end target))
        (editor-user-error
          'edit.indent-sexp
          "Major mode has no indentation provider"))
      (view-deactivate-mark! view)
      '()))

  (define (defun-at-or-near index point direction)
    (or
      (structure-index-thing-at index 'defun point)
      (if (eq? direction 'backward)
          (structure-index-previous index 'defun point)
          (structure-index-next index 'defun point))))

  (define (move-defun-command context direction)
    (let* ([view (context-view context)]
           [index (structure-index context)]
           [count (command-context-count context)])
      (let loop
        ([remaining (abs count)]
         [point (view-caret view)]
         [direction
           (if (negative? count)
               (if (eq? direction 'backward)
                   'forward
                   'backward)
               direction)])
        (if (zero? remaining)
            (view-set-caret! view point)
            (let* ([thing
                     (defun-at-or-near
                       index
                       point
                       direction)]
                   [target
                     (and
                       thing
                       (if (eq? direction 'backward)
                           (structural-thing-start thing)
                           (structural-thing-end thing)))])
              (unless target
                (editor-user-error
                  (if (eq? direction 'backward)
                      'move.beginning-of-defun
                      'move.end-of-defun)
                  "No function definition"))
              (loop (- remaining 1) target direction))))
      '()))

  (define (beginning-of-defun-command context)
    (move-defun-command context 'backward))

  (define (end-of-defun-command context)
    (move-defun-command context 'forward))

  (define (mark-defun-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [thing
             (defun-at-or-near
               (structure-index context)
               (view-caret view)
               'forward)])
      (unless thing
        (editor-user-error 'mark.defun "No function definition"))
      (view-push-mark! view (view-caret view))
      (view-set-caret! view (structural-thing-start thing))
      (view-set-mark! view (structural-thing-end thing))
      (editor-set-status-message! editor "Function marked")
      '()))

  (define (stroke character)
    (make-key-stroke
      'character
      (char->integer character)
      6))

  (define (install-structural-commands! editor)
    (for-each
      (lambda (entry)
        (editor-register-command!
          editor
          (make-interactive-context-command
            (car entry)
            (cadr entry)
            (caddr entry)
            (if (pair? (cdddr entry))
                (cadddr entry)
                #f))))
      (list
        (list
          'move.forward-sexp
          forward-sexp-command
          "Move forward across balanced expressions.")
        (list
          'move.backward-sexp
          backward-sexp-command
          "Move backward across balanced expressions.")
        (list
          'move.backward-up-list
          backward-up-list-command
          "Move backward out of one enclosing list.")
        (list
          'move.forward-up-list
          forward-up-list-command
          "Move forward out of one enclosing list.")
        (list
          'move.down-list
          down-list-command
          "Move into the next list.")
        (list
          'move.backward-down-list
          backward-down-list-command
          "Move backward into the previous list.")
        (list
          'move.beginning-of-defun
          beginning-of-defun-command
          "Move to the beginning of a function definition.")
        (list
          'move.end-of-defun
          end-of-defun-command
          "Move to the end of a function definition.")
        (list
          'mark.sexp
          mark-sexp-command
          "Mark expressions, extending the mark when repeated."
          'mark)
        (list
          'mark.defun
          mark-defun-command
          "Mark the function definition at or following point."
          'mark)
        (list
          'edit.kill-sexp
          kill-sexp-command
          "Kill balanced expressions."
          'kill)
        (list
          'edit.transpose-sexps
          transpose-sexps-command
          "Transpose adjacent balanced expressions.")
        (list
          'edit.indent-sexp
          indent-sexp-command
          "Reindent the region, next expression, or prefix-selected defun.")))
    (for-each
      (lambda (entry)
        (editor-bind-key!
          editor
          (list (stroke (car entry)))
          (cdr entry)))
      (list
        (cons #\f 'move.forward-sexp)
        (cons #\b 'move.backward-sexp)
        (cons #\u 'move.backward-up-list)
        (cons #\d 'move.down-list)
        (cons #\a 'move.beginning-of-defun)
        (cons #\e 'move.end-of-defun)
        (cons #\space 'mark.sexp)
        (cons #\h 'mark.defun)
        (cons #\k 'edit.kill-sexp)
        (cons #\t 'edit.transpose-sexps)
        (cons #\q 'edit.indent-sexp)))
    editor))
