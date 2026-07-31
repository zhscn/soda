(library (soda editor structural-commands)
  (export install-structural-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor condition)
          (soda editor edit)
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

  (define (kill-sexp-command context)
    (let* ([editor (command-context-editor context)]
           [view (context-view context)]
           [start (view-caret view)]
           [end
             (require-target
               'edit.kill-sexp
               (forward-sexp-target
                 context
                 start
                 (command-context-count context))
               "No expression to kill")])
      (unless (= start end)
        (editor-kill-buffer-range!
          editor
          (context-buffer context)
          start
          end)
        (view-set-caret! view (min start end))
        (view-clear-mark! view))
      '()))

  (define (append-bytevectors . values)
    (let* ([size
             (fold-left
               (lambda (total bytes)
                 (+ total (bytevector-length bytes)))
               0
               values)]
           [result (make-bytevector size)])
      (let loop ([remaining values] [offset 0])
        (unless (null? remaining)
          (let* ([bytes (car remaining)]
                 [length (bytevector-length bytes)])
            (bytevector-copy!
              bytes
              0
              result
              offset
              length)
            (loop (cdr remaining) (+ offset length)))))
      result))

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
                  (append-bytevectors
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
          'edit.kill-sexp
          kill-sexp-command
          "Kill balanced expressions."
          'kill)
        (list
          'edit.transpose-sexps
          transpose-sexps-command
          "Transpose adjacent balanced expressions.")))
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
        (cons #\k 'edit.kill-sexp)
        (cons #\t 'edit.transpose-sexps)))
    editor))
