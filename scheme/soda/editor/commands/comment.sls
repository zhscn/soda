(library (soda editor commands comment)
  (export install-comment-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor command-target)
          (soda editor condition)
          (soda editor keymap)
          (soda editor setting)
          (soda editor state))

  (define (bytevector-prefix-at? text offset prefix)
    (let ([bytes (string->utf8 prefix)])
      (and
        (<= (+ offset (bytevector-length bytes)) (text-size text))
        (let loop ([index 0])
          (or
            (= index (bytevector-length bytes))
            (and
              (= (text-byte-at text (+ offset index))
                 (bytevector-u8-ref bytes index))
              (loop (+ index 1))))))))

  (define (line-leading-end text line)
    (let ([end (text-line-content-end text line)])
      (let loop ([offset (text-line-start text line)])
        (if
          (and (< offset end)
               (memv (text-byte-at text offset) '(9 32)))
          (loop (+ offset 1))
          offset))))

  (define (target-line-range text target)
    (let* ([start (command-target-start target)]
           [end (command-target-end target)]
           [start-line (car (text-position text start))]
           [end-line
             (car
               (text-position
                 text
                 (if
                   (and (> end start)
                        (= end (text-line-start text (car (text-position text end)))))
                   (- end 1)
                   end)))])
      (cons start-line end-line)))

  (define (commit-replacements! buffer replacements)
    (let ([change #f])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (call-with-values
            (lambda ()
              (call-with-buffer-transaction
                buffer
                (lambda (transaction)
                  (for-each
                    (lambda (replacement)
                      (transaction-replace!
                        transaction
                        (car replacement)
                        (cadr replacement)
                        (caddr replacement)))
                    replacements))))
            (lambda (result committed-change)
              (set! change committed-change)
              result)))
        (lambda ()
          (when change (change-close! change))))))

  (define (line-comment-replacements text first last prefix)
    (let* ([positions
             (let loop ([line first] [result '()])
               (if (> line last)
                   (reverse result)
                   (loop
                     (+ line 1)
                     (cons (line-leading-end text line) result))))]
           [nonempty
             (filter
               (lambda (position)
                 (< position
                    (text-line-content-end
                      text
                      (car (text-position text position)))))
               positions)]
           [uncomment?
             (and
               (pair? nonempty)
               (for-all
                 (lambda (position)
                   (bytevector-prefix-at? text position prefix))
                 nonempty))]
           [bytes (string->utf8 prefix)])
      (map
        (lambda (position)
          (if uncomment?
              (list position (+ position (bytevector-length bytes))
                    (make-bytevector 0))
              (list position position bytes)))
        (reverse positions))))

  (define target-reader
    (make-command-target-reader
      'comment-target
      (make-command-target-selector
        'prefer #f command-context-line-target)))

  (define-command (comment-dwim-command context target)
    "Comment or uncomment the active region or current line."
    (interactive target-reader)
    (let* ([view (command-context-view context)]
           [buffer (view-buffer view)]
           [line-prefix
             (buffer-setting-ref buffer 'comment-line-prefix #f)]
           [block-start
             (buffer-setting-ref buffer 'comment-block-start #f)]
           [block-end
             (buffer-setting-ref buffer 'comment-block-end #f)])
      (unless (command-target-current? target buffer)
        (editor-user-error 'edit.comment-dwim "The comment target is stale"))
      (cond
        [(and line-prefix (not (string=? line-prefix "")))
         (call-with-buffer-text
           buffer
           (lambda (text)
             (let ([lines (target-line-range text target)])
               (commit-replacements!
                 buffer
                 (line-comment-replacements
                   text (car lines) (cdr lines) line-prefix)))))]
        [(and block-start block-end)
         (let* ([start (command-target-start target)]
                [end (command-target-end target)]
                [open (string->utf8 block-start)]
                [close (string->utf8 block-end)])
           (call-with-buffer-text
             buffer
             (lambda (text)
               (let ([commented?
                             (and
                               (bytevector-prefix-at?
                                 text start block-start)
                               (<= (+ start
                                      (bytevector-length open)
                                      (bytevector-length close))
                                   end)
                               (bytevector-prefix-at?
                                 text
                                 (- end (bytevector-length close))
                                 block-end))])
                       (commit-replacements!
                         buffer
                         (if commented?
                             (list
                               (list
                                 (- end (bytevector-length close))
                                 end
                                 (make-bytevector 0))
                               (list
                                 start
                                 (+ start (bytevector-length open))
                                 (make-bytevector 0)))
                     (list
                       (list end end close)
                       (list start start open))))))))]
        [else
         (editor-user-error
           'edit.comment-dwim
           "Major mode has no comment policy")])
      (view-deactivate-mark! view)
      '()))

  (define (install-comment-commands! editor)
    (for-each
      (lambda (entry)
        (editor-register-setting!
          editor
          (make-setting-definition
            (car entry)
            #f
            (lambda (value) (or (not value) (string? value)))
            (cadr entry)
            'document)))
      '((comment-line-prefix "Line comment prefix used by comment commands.")
        (comment-block-start "Opening delimiter used by block comments.")
        (comment-block-end "Closing delimiter used by block comments.")))
    (editor-register-command!
      editor
      (make-interactive-context-command
        'edit.comment-dwim
        comment-dwim-command
        "Comment or uncomment the active region or current line."))
    (editor-bind-key!
      editor
      (list (make-key-stroke 'character (char->integer #\;) 2))
      'edit.comment-dwim)
    editor))
