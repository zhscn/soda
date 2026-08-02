(library (soda editor search)
  (export install-search-commands!)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor command)
          (soda editor command-runtime)
          (soda editor edit)
          (soda editor input-state)
          (soda editor keymap)
          (soda editor location)
          (soda editor navigation)
          (soda editor prompt)
          (soda editor regexp)
          (soda editor setting)
          (soda editor state)
          (soda editor tui-projection))

  (define-record-type search-session
    (fields
      origin-view-id
      origin
      (mutable direction)
      regexp?
      case-policy
      (mutable query)
      (mutable compiled-query)
      (mutable program)
      (mutable source-buffer-id)
      (mutable source-revision)
      (mutable source)
      (mutable match-start)
      (mutable match-end)
      (mutable wrapped?)))

  (define-record-type query-replace-session
    (fields
      origin-view-id
      origin
      regexp?
      case-policy
      (mutable query)
      (mutable replacement)
      (mutable program)
      (mutable source-buffer-id)
      (mutable source-revision)
      (mutable source)
      (mutable phase)
      (mutable scan-position)
      (mutable match-start)
      (mutable match-end)
      (mutable match-result)
      (mutable expanded-replacement)
      (mutable count)))

  (define (regexp-quote value)
    (let-values ([(port extract) (open-string-output-port)])
      (for-each
        (lambda (character)
          (when (memv character
                      '(#\\ #\. #\^ #\$ #\[ #\]
                        #\( #\) #\| #\* #\+ #\?))
            (put-char port #\\))
          (put-char port character))
        (string->list value))
      (extract)))

  (define (regexp-query-has-uppercase? query)
    (let ([size (string-length query)])
      (let loop ([index 0])
        (and
          (< index size)
          (let ([character (string-ref query index)])
            (if (and (char=? character #\\) (< (+ index 1) size))
                (let ([escaped (string-ref query (+ index 1))])
                  (or
                    (and
                      (not (memv escaped
                                 '(#\d #\D #\w #\W #\s #\S
                                   #\b #\B #\n #\t #\r)))
                      (char-upper-case? escaped))
                    (loop (+ index 2))))
                (or
                  (char-upper-case? character)
                  (loop (+ index 1)))))))))

  (define (smart-case-fold? query regexp?)
    (not
      (if regexp?
          (regexp-query-has-uppercase? query)
          (exists char-upper-case? (string->list query)))))

  (define (case-fold-for-query policy query regexp?)
    (case policy
      [(sensitive) #f]
      [(insensitive) #t]
      [(smart) (smart-case-fold? query regexp?)]
      [else
       (assertion-violation
         'case-fold-for-query "invalid search case policy" policy)]))

  (define (search-case-policy editor buffer regexp?)
    (editor-setting-ref
      editor
      buffer
      (if regexp?
          'search-regexp-case-policy
          'search-literal-case-policy)))

  (define (case-mode-label case-fold?)
    (if case-fold? "case-fold" "case-sensitive"))

  (define (program-match program source start end backward? case-fold?)
    (if backward?
        (regexp-program-find-backward
          program source start end case-fold?)
        (regexp-program-find-forward
          program source start end case-fold?)))

  (define (next-character-offset text offset)
    (let ([size (text-size text)])
      (if (>= offset size)
          (+ size 1)
          (let* ([lead (text-byte-at text offset)]
                 [width
                   (cond
                     [(< lead #x80) 1]
                     [(< lead #xe0) 2]
                     [(< lead #xf0) 3]
                     [else 4])])
            (min size (+ offset width))))))

  (define (buffer-regexp-source buffer)
    (call-with-buffer-text
      buffer
      (lambda (text)
        (make-regexp-source
          (utf8->string (text->bytevector text))))))

  (define (search-session-program! session query)
    (if (and
          (search-session-program session)
          (string? (search-session-compiled-query session))
          (string=? query (search-session-compiled-query session)))
        (search-session-program session)
        (let ([program
                (compile-regexp
                  (if (search-session-regexp? session)
                      query
                      (regexp-quote query)))])
          (search-session-compiled-query-set! session query)
          (search-session-program-set! session program)
          program)))

  (define (search-session-source! editor session buffer)
    (tui-ensure-buffer-text-projection! editor buffer)
    (let ([revision (buffer-revision buffer)])
      (if (and
            (search-session-source session)
            (= (buffer-id buffer)
               (search-session-source-buffer-id session))
            (= revision (search-session-source-revision session)))
          (search-session-source session)
          (let ([source (buffer-regexp-source buffer)])
            (search-session-source-buffer-id-set!
              session (buffer-id buffer))
            (search-session-source-revision-set! session revision)
            (search-session-source-set! session source)
            source))))

  (define (query-replace-program! session)
    (or
      (query-replace-session-program session)
      (let ([program
              (compile-regexp
                (if (query-replace-session-regexp? session)
                    (query-replace-session-query session)
                    (regexp-quote
                      (query-replace-session-query session))))])
        (query-replace-session-program-set! session program)
        program)))

  (define (query-replace-source! editor session buffer)
    (tui-ensure-buffer-text-projection! editor buffer)
    (let ([revision (buffer-revision buffer)])
      (if (and
            (query-replace-session-source session)
            (= (buffer-id buffer)
               (query-replace-session-source-buffer-id session))
            (= revision (query-replace-session-source-revision session)))
          (query-replace-session-source session)
          (let ([source (buffer-regexp-source buffer)])
            (query-replace-session-source-buffer-id-set!
              session (buffer-id buffer))
            (query-replace-session-source-revision-set! session revision)
            (query-replace-session-source-set! session source)
            source))))

  (define (written-string value)
    (let-values ([(port extract) (open-string-output-port)])
      (write value port)
      (extract)))

  (define (search-data editor)
    (let ([prompt (editor-active-prompt editor)])
      (and prompt
           (let ([data
                   (prompt-request-data
                     (prompt-session-request prompt))])
             (and (search-session? data) data)))))

  (define (query-replace-data editor)
    (let ([prompt (editor-active-prompt editor)])
      (and prompt
           (let ([data
                   (prompt-request-data
                     (prompt-session-request prompt))])
             (and (query-replace-session? data) data)))))

  (define (origin-view editor session)
    (editor-view-ref editor (search-session-origin-view-id session)))

  (define (restore-origin! editor session)
    (let* ([view (origin-view editor session)]
           [location (search-session-origin session)]
           [buffer
             (editor-buffer-ref
               editor
               (editor-location-buffer-id location))])
      (unless (= (buffer-id (view-buffer view)) (buffer-id buffer))
        (editor-set-view-buffer!
          editor
          (view-id view)
          (buffer-id buffer)))
      (view-clear-mark! view)
      (view-set-caret! view (editor-location-offset location))
      (ensure-view-visible! view)))

  (define (show-match! editor session start end wrapped?)
    (let ([view (origin-view editor session)]
          [case-fold?
            (case-fold-for-query
              (search-session-case-policy session)
              (search-session-query session)
              (search-session-regexp? session))])
      (view-set-mark!
        view
        (if (eq? (search-session-direction session) 'forward)
            start
            end))
      (view-set-caret!
        view
        (if (eq? (search-session-direction session) 'forward)
            end
            start))
      (search-session-match-start-set! session start)
      (search-session-match-end-set! session end)
      (search-session-wrapped?-set! session wrapped?)
      (ensure-view-visible! view)
      (editor-set-status-message!
        editor
        (string-append
          "Search ["
          (case-mode-label case-fold?)
          "]"
          (if wrapped? " wrapped" "")))))

  (define (search-from! editor session query repeat?)
    (let* ([view (origin-view editor session)]
           [buffer (view-buffer view)]
           [bytes (string->utf8 query)]
           [length (bytevector-length bytes)]
           [case-fold?
             (case-fold-for-query
               (search-session-case-policy session)
               query
               (search-session-regexp? session))]
           [origin-offset
             (editor-location-offset
               (search-session-origin session))])
      (search-session-query-set! session query)
      (cond
        [(zero? length)
         (restore-origin! editor session)
         (search-session-match-start-set! session #f)
         (search-session-match-end-set! session #f)
         (search-session-wrapped?-set! session #f)
         (editor-set-status-message! editor #f)]
        [else
         (let* ([program (search-session-program! session query)]
                [source (search-session-source! editor session buffer)]
                [size (regexp-source-byte-length source)]
                [direction (search-session-direction session)]
                [start
                  (if repeat?
                      (if (eq? direction 'forward)
                          (min
                            size
                            (+
                              (or
                                (search-session-match-start session)
                                origin-offset)
                              1))
                          (-
                            (or
                              (search-session-match-start session)
                              origin-offset)
                            1))
                      origin-offset)]
                [first
                  (program-match
                    program
                    source
                    (if (eq? direction 'forward) start 0)
                    (if (eq? direction 'forward) size start)
                    (eq? direction 'backward)
                    case-fold?)]
                [wrapped
                  (and
                    (not first)
                    (program-match
                      program
                      source
                      (if (eq? direction 'forward)
                          0
                          (max 0 (+ start 1)))
                      (if (eq? direction 'forward)
                          (min start size)
                          size)
                      (eq? direction 'backward)
                      case-fold?))]
                [match (or first wrapped)])
           (if match
               (show-match!
                 editor session (car match) (cdr match) (and wrapped #t))
               (editor-set-status-message!
                 editor
                 (string-append
                   "Failing search ["
                   (case-mode-label case-fold?)
                   "]: "
                   query))))])))

  (define (start-search! context direction regexp?)
    (let* ([editor (command-context-editor context)]
           [active (search-data editor)])
      (if active
          (begin
            (search-session-direction-set! active direction)
            (search-from!
              editor
              active
              (editor-active-prompt-input editor)
              #t))
          (let* ([view (command-context-view context)]
                 [session
                   (make-search-session
                     (view-id view)
                     (make-buffer-location
                       (view-buffer view)
                       (view-caret view))
                     direction
                     regexp?
                     (search-case-policy
                       editor (view-buffer view) regexp?)
                     ""
                     #f
                     #f
                     #f
                     #f
                     #f
                     #f
                     #f
                     #f)])
            (editor-open-prompt!
              editor
              (make-prompt-request
                (string-append
                  (if regexp? "Regexp " "")
                  (if (eq? direction 'forward)
                      "I-search: "
                      "I-search backward: "))
                ""
                'search
                #f
                'free
                #f
                'search.accept
                'search.abort
                session
                'search.changed))))
      '()))

  (define (forward-search-command context)
    (start-search! context 'forward #f))

  (define (backward-search-command context)
    (start-search! context 'backward #f))

  (define (forward-regexp-search-command context)
    (start-search! context 'forward #t))

  (define (backward-regexp-search-command context)
    (start-search! context 'backward #t))

  (define (search-changed-command context)
    (let* ([editor (command-context-editor context)]
           [session (search-data editor)])
      (when session
        (guard
          (condition
            [else
             (if (search-session-regexp? session)
                 (editor-set-status-message!
                   editor "Incomplete or invalid regexp")
                 (raise condition))])
          (search-from!
            editor
            session
            (editor-active-prompt-input editor)
            #f)))
      '()))

  (define (finish-search! context accepted?)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [session
             (and
               (prompt-result? result)
               (prompt-result-data result))])
      (when (search-session? session)
        (let ([view
                (editor-view-ref
                  editor
                  (search-session-origin-view-id session))])
          (view-clear-mark! view)
          (if (and accepted? (search-session-match-start session))
              (let* ([buffer (view-buffer view)]
                     [target
                       (if (eq? (search-session-direction session) 'forward)
                           (search-session-match-end session)
                           (search-session-match-start session))])
                (restore-origin! editor session)
                (editor-jump-to-buffer!
                  editor buffer target 'search))
              (restore-origin! editor session)))
        (editor-location-close! (search-session-origin session))
        (editor-set-status-message! editor #f))
      '()))

  (define (search-accept-command context)
    (finish-search! context #t))

  (define (search-abort-command context)
    (finish-search! context #f))

  (define (query-replace-origin-view editor session)
    (editor-view-ref
      editor
      (query-replace-session-origin-view-id session)))

  (define (query-replace-buffer editor session)
    (view-buffer (query-replace-origin-view editor session)))

  (define (query-replace-ranges buffer size)
    (let* ([provider (buffer-local-ref buffer 'search-ranges #f)]
           [ranges
             (if (procedure? provider)
                 (provider)
                 (list (cons 0 size)))])
      (unless
        (and
          (list? ranges)
          (for-all
            (lambda (range)
              (and
                (pair? range)
                (integer? (car range)) (exact? (car range))
                (integer? (cdr range)) (exact? (cdr range))
                (<= 0 (car range) (cdr range) size)))
            ranges))
        (assertion-violation
          'query-replace
          "Buffer search ranges are invalid"
          ranges))
      (list-sort
        (lambda (left right)
          (or (< (car left) (car right))
              (and (= (car left) (car right))
                   (< (cdr left) (cdr right)))))
        ranges)))

  (define (query-replace-next-match
            program source scan size case-fold? ranges)
    (let loop ([remaining ranges])
      (if (null? remaining)
          #f
          (let* ([range (car remaining)]
                 [start (car range)]
                 [end (cdr range)])
            (if (> scan end)
                (loop (cdr remaining))
                (or
                  (regexp-program-search-forward
                    program source (max scan start) end case-fold?)
                  (loop (cdr remaining))))))))

  (define (query-replace-show-next! editor session)
    (let* ([buffer (query-replace-buffer editor session)]
           [query (query-replace-session-query session)]
           [case-fold?
             (case-fold-for-query
               (query-replace-session-case-policy session)
               query
               (query-replace-session-regexp? session))]
           [source (query-replace-source! editor session buffer)]
           [program (query-replace-program! session)]
           [scan (query-replace-session-scan-position session)]
           [size (regexp-source-byte-length source)]
           [result
             (and
               (<= scan size)
               (query-replace-next-match
                 program source scan size case-fold?
                 (query-replace-ranges buffer size)))]
           [match-range
             (and result (regexp-match-group result 0))])
      (query-replace-session-match-result-set!
        session
        (and (query-replace-session-regexp? session) result))
      (if (not match-range)
          (begin
            (query-replace-session-match-result-set! session #f)
            (query-replace-session-expanded-replacement-set! session #f)
            #f)
          (let ([view (query-replace-origin-view editor session)]
                [match (car match-range)]
                [end (cdr match-range)])
            (query-replace-session-expanded-replacement-set!
              session
              (if (query-replace-session-regexp? session)
                  (regexp-expand-replacement
                    (query-replace-session-replacement session)
                    (regexp-source-value source)
                    (query-replace-session-match-result session))
                  (query-replace-session-replacement session)))
            (editor-set-status-message!
              editor
              (string-append
                "Replacement: "
                (written-string
                  (query-replace-session-expanded-replacement session))
                " ["
                (case-mode-label case-fold?)
                "]"))
            (view-set-mark! view match)
            (view-set-caret! view end)
            (query-replace-session-match-start-set! session match)
            (query-replace-session-match-end-set! session end)
            (ensure-view-visible! view)
            #t))))

  (define (query-replace-close-prompt! editor)
    (let ([reply (editor-accept-prompt! editor)])
      (if reply
          (list (make-command-effect 'prompt.reply reply))
          '())))

  (define (query-replace-next-or-finish! editor session)
    (if (query-replace-show-next! editor session)
        '()
        (begin
          (query-replace-session-phase-set! session 'finished)
          (query-replace-close-prompt! editor))))

  (define (start-query-replace! context regexp?)
    (let* ([editor (command-context-editor context)]
           [view (command-context-view context)]
           [session
             (make-query-replace-session
               (view-id view)
               (make-buffer-location
                 (view-buffer view)
                 (view-caret view))
               regexp?
               (search-case-policy
                 editor (view-buffer view) regexp?)
               #f
               #f
               #f
               #f
               #f
               #f
               'query
               (view-caret view)
               #f
               #f
               #f
               #f
               0)])
      (editor-open-prompt!
        editor
        (make-prompt-request
          (if regexp? "Query replace regexp: " "Query replace: ")
          ""
          'query-replace
          #f
          'free
          #f
          'query-replace.read-replacement
          'query-replace.abort
          session))
      '()))

  (define (query-replace-start-command context)
    (start-query-replace! context #f))

  (define (query-replace-regexp-start-command context)
    (start-query-replace! context #t))

  (define (query-replace-read-replacement-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [session
             (and (prompt-result? result)
                  (prompt-result-data result))]
           [query
             (and (prompt-result? result)
                  (prompt-result-value result))]
           [valid-regexp?
             (or
               (not (and
                      (query-replace-session? session)
                      (query-replace-session-regexp? session)))
               (guard
                 (condition [else #f])
                 (compile-regexp (or query ""))
                 #t))])
      (when (query-replace-session? session)
        (if (or (not query)
                (zero? (string-length query))
                (not valid-regexp?))
            (begin
              (editor-location-close!
                (query-replace-session-origin session))
              (editor-set-status-message!
                editor
                (if valid-regexp?
                    "Query is empty"
                    "Invalid regexp")))
            (begin
              (query-replace-session-query-set! session query)
              (query-replace-session-program-set! session #f)
              (query-replace-session-phase-set! session 'replacement)
              (editor-open-prompt!
                editor
                (make-prompt-request
                  (string-append
                    "Replace " query " with: ")
                  ""
                  'query-replace-replacement
                  #f
                  'free
                  #f
                  'query-replace.begin
                  'query-replace.abort
                  session)))))
      '()))

  (define (query-replace-begin-command context)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [session
             (and (prompt-result? result)
                  (prompt-result-data result))]
           [replacement
             (and (prompt-result? result)
                  (prompt-result-value result))])
      (if (not (query-replace-session? session))
          '()
          (begin
            (query-replace-session-replacement-set!
              session
              (or replacement ""))
            (query-replace-session-phase-set! session 'deciding)
            (editor-open-prompt!
              editor
              (make-prompt-request
                "Replace? (y/n/!/q) "
                ""
                #f
                #f
                'free
                #f
                'query-replace.finish
                'query-replace.abort
                session))
            (view-push-input-state!
              (editor-active-view editor)
              (make-input-state
                'query-replace
                '(query-replace)
                'ignore))
            (query-replace-next-or-finish! editor session)))))

  (define (query-replace-current! editor session)
    (let* ([buffer (query-replace-buffer editor session)]
           [start (query-replace-session-match-start session)]
           [end (query-replace-session-match-end session)]
           [replacement-value
             (query-replace-session-expanded-replacement session)]
           [replacement
             (string->utf8 replacement-value)]
           [new-end (+ start (bytevector-length replacement))])
      (buffer-replace-range! buffer start end replacement)
      (query-replace-session-count-set!
        session
        (+ (query-replace-session-count session) 1))
      (query-replace-session-scan-position-set! session new-end)
      (when (= start end)
        (query-replace-session-scan-position-set!
          session
          (call-with-buffer-text
            buffer
            (lambda (text)
              (next-character-offset text new-end)))))
      (query-replace-session-match-result-set! session #f)
      (query-replace-session-expanded-replacement-set! session #f)
      (view-set-caret!
        (query-replace-origin-view editor session)
        new-end)))

  (define (query-replace-yes-command context)
    (let* ([editor (command-context-editor context)]
           [session (query-replace-data editor)])
      (unless session
        (assertion-violation
          'query-replace.yes
          "no active query replace"))
      (query-replace-current! editor session)
      (query-replace-next-or-finish! editor session)))

  (define (query-replace-no-command context)
    (let* ([editor (command-context-editor context)]
           [session (query-replace-data editor)])
      (unless session
        (assertion-violation
          'query-replace.no
          "no active query replace"))
      (let ([start (query-replace-session-match-start session)]
            [end (query-replace-session-match-end session)])
        (query-replace-session-scan-position-set!
          session
          (if (= start end)
              (call-with-buffer-text
                (query-replace-buffer editor session)
                (lambda (text) (next-character-offset text end)))
              end)))
      (query-replace-session-match-result-set! session #f)
      (query-replace-session-expanded-replacement-set! session #f)
      (query-replace-next-or-finish! editor session)))

  (define (query-replace-all-command context)
    (let* ([editor (command-context-editor context)]
           [session (query-replace-data editor)])
      (unless session
        (assertion-violation
          'query-replace.all
          "no active query replace"))
      (let loop ()
        (query-replace-current! editor session)
        (when (query-replace-show-next! editor session)
          (loop)))
      (query-replace-session-phase-set! session 'finished)
      (query-replace-close-prompt! editor)))

  (define (query-replace-quit-command context)
    (let* ([editor (command-context-editor context)]
           [session (query-replace-data editor)])
      (when session
        (query-replace-session-phase-set! session 'finished))
      (query-replace-close-prompt! editor)))

  (define (query-replace-finish! context aborted?)
    (let* ([editor (command-context-editor context)]
           [result (command-context-argument context)]
           [session
             (and (prompt-result? result)
                  (prompt-result-data result))])
      (when (query-replace-session? session)
        (let ([view (query-replace-origin-view editor session)])
          (view-clear-mark! view)
          (when (memq
                  (query-replace-session-phase session)
                  '(query replacement))
            (let ([location (query-replace-session-origin session)]
                  [buffer
                    (editor-buffer-ref
                      editor
                      (editor-location-buffer-id
                        (query-replace-session-origin session)))])
              (unless (= (buffer-id (view-buffer view))
                         (buffer-id buffer))
                (editor-set-view-buffer!
                  editor
                  (view-id view)
                  (buffer-id buffer)))
              (view-set-caret!
                view
                (editor-location-offset location))))
          (editor-location-close!
            (query-replace-session-origin session))
          (editor-set-status-message!
            editor
            (cond
              [(memq
                 (query-replace-session-phase session)
                 '(query replacement))
               "Query replace aborted"]
              [(and aborted?
                    (eq?
                      (query-replace-session-phase session)
                      'deciding))
               "Query replace stopped"]
              [else
               (string-append
                 "Replaced "
                 (number->string
                   (query-replace-session-count session))
                 " occurrence(s)")]))))
      '()))

  (define (query-replace-finish-command context)
    (query-replace-finish! context #f))

  (define (query-replace-abort-command context)
    (query-replace-finish! context #t))

  (define (stroke character modifiers)
    (make-key-stroke
      'character
      (char->integer character)
      modifiers))

  (define (install-search-commands! editor)
    (for-each
      (lambda (entry)
        (editor-register-setting!
          editor
          (make-setting-definition
            (car entry)
            'smart
            (lambda (value)
              (memq value '(sensitive insensitive smart)))
            (cadr entry)
            'chrome)))
      '((search-literal-case-policy
          "Case policy for literal search and replacement.")
        (search-regexp-case-policy
          "Case policy for regexp search and replacement.")))
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
          'search.forward
          forward-search-command
          "Start or repeat incremental forward search.")
        (list
          'search.backward
          backward-search-command
          "Start or repeat incremental backward search.")
        (list
          'search.forward-regexp
          forward-regexp-search-command
          "Start or repeat incremental forward regexp search.")
        (list
          'search.backward-regexp
          backward-regexp-search-command
          "Start or repeat incremental backward regexp search.")
        (list
          'search.accept
          search-accept-command
          "Commit the active incremental search.")
        (list
          'search.abort
          search-abort-command
          "Abort the active incremental search.")
        (list
          'query-replace
          query-replace-start-command
          "Interactively replace occurrences following point.")
        (list
          'query-replace-regexp
          query-replace-regexp-start-command
          "Interactively replace regexp matches following point.")
        (list
          'query-replace.yes
          query-replace-yes-command
          "Replace the current occurrence.")
        (list
          'query-replace.no
          query-replace-no-command
          "Skip the current occurrence.")
        (list
          'query-replace.all
          query-replace-all-command
          "Replace every remaining occurrence.")
        (list
          'query-replace.quit
          query-replace-quit-command
          "Stop query replace and retain completed replacements.")))
    (for-each
      (lambda (entry)
        (editor-register-internal-command!
          editor
          (make-internal-context-command
            (car entry)
            (cadr entry)
            (caddr entry))))
      (list
        (list
          'search.changed
          search-changed-command
          "Update the active incremental search.")
        (list
          'query-replace.read-replacement
          query-replace-read-replacement-command
          "Read the replacement for query replace.")
        (list
          'query-replace.begin
          query-replace-begin-command
          "Begin query replace decisions.")
        (list
          'query-replace.finish
          query-replace-finish-command
          "Finish query replace.")
        (list
          'query-replace.abort
          query-replace-abort-command
          "Abort the current query replace stage.")))
    (editor-bind-key!
      editor
      (list (stroke #\s 4))
      'search.forward)
    (editor-bind-key!
      editor
      (list (stroke #\r 4))
      'search.backward)
    (editor-bind-key!
      editor
      (list (stroke #\s 6))
      'search.forward-regexp)
    (editor-bind-key!
      editor
      (list (stroke #\r 6))
      'search.backward-regexp)
    (editor-bind-key!
      editor
      (list (stroke #\% 2))
      'query-replace)
    (editor-bind-key!
      editor
      (list (stroke #\% 6))
      'query-replace-regexp)
    (let ([keymap (make-keymap)])
      (for-each
        (lambda (entry)
          (keymap-bind! keymap (list (car entry)) (cdr entry)))
        (list
          (cons (stroke #\y 0) 'query-replace.yes)
          (cons (stroke #\space 0) 'query-replace.yes)
          (cons (stroke #\n 0) 'query-replace.no)
          (cons
            (make-key-stroke 'delete #f 0)
            'query-replace.no)
          (cons (stroke #\! 0) 'query-replace.all)
          (cons (stroke #\q 0) 'query-replace.quit)))
      (keymap-catalog-register!
        (editor-keymap-catalog editor)
        'query-replace
        keymap))
    editor))
