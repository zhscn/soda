#!r6rs
(import (rnrs)
        (rnrs eval)
        (only (chezscheme)
              delete-directory
              get-mode
              get-process-id
              mkdir)
        (soda kernel change)
        (soda kernel extension)
        (soda kernel option)
        (soda kernel location)
        (soda kernel range-set)
        (soda kernel resource)
        (soda kernel selection)
        (soda kernel state)
        (soda kernel syntax-profile)
        (soda kernel value)
        (soda kernel viewport)
        (soda kernel view-state)
        (soda host command)
        (soda host command-runtime)
        (soda host analysis)
        (soda host condition)
        (soda host internal context)
        (soda host dispatch)
        (soda host frontend)
        (soda host feedback)
        (soda host location)
        (soda host navigation)
        (soda host package)
        (soda host internal buffer)
        (soda host input)
        (soda host input-event)
        (soda host key-configuration)
        (soda host operation)
        (soda host runtime)
        (soda host render)
        (soda host render-service)
        (soda host setting)
        (soda host internal state)
        (soda host internal surface)
        (soda host value)
        (soda host internal view)
        (soda host internal window)
        (soda kernel document)
        (soda kernel range-set)
        (soda ffi cpp-analysis)
        (soda ffi indentation)
        (soda ffi tree-sitter)
        (soda bootstrap)
        (soda packages base fundamental-editing)
        (soda packages base editing-options)
        (soda packages base history)
        (soda packages analysis-ui)
        (soda packages buffer-ui)
        (soda packages interaction)
        (soda packages file)
        (soda packages file-format)
        (soda packages file-watch)
        (soda packages recovery)
        (soda packages process)
        (soda packages spell)
        (prefix (soda ffi runtime) native:)
        (soda support vfs)
        (soda tui terminal-input)
        (soda tui frontend)
        (soda tui terminal-frontend)
        (soda tui terminal-session)
        (soda tui presenter)
        (soda tui presenter-session)
        (soda test fundamental-editing)
        (soda test file-state)
        (soda test buffer-ui)
        (soda test host-integration)
        (soda test terminal-clipboard)
        (soda test command-loop)
        (soda test view-presentation)
        (soda view display)
        (soda view projection)
        (soda view frame)
        (soda view compositor)
        (soda view decoration)
        (soda view text-layout)
        (soda view theme)
        (soda view plugin)
        (soda view occurrence)
        (soda view internal plugin))

(define (application-command-context application)
  (let* ([state (soda-application-state application)]
         [surface (soda-application-surface application)]
         [active (surface-active-context surface (host-state-views state))]
         [view
          (view-service-ref (host-state-views state) (active-context-view-id active))]
         [buffer (view-buffer view)])
    (make-command-context
      #f
      (active-context-surface-id active)
      (active-context-window-id active)
      (view-id view)
      (buffer-id buffer)
      (buffer-state buffer)
      (view-state view)
      #f '() #f active 'fundamental-test)))

(define (buffer-string buffer)
  (snapshot-string (buffer-state-document (buffer-state buffer))))

(define (string-contains? value needle)
  (let ([limit (- (string-length value) (string-length needle))])
    (let loop ([index 0])
      (and (<= index limit)
           (or (string=? (substring value index (+ index (string-length needle))) needle)
               (loop (+ index 1)))))))

(define (library-binding-hidden? library-name identifier)
  (guard (condition [else #t])
    (eval identifier (apply environment (list library-name)))
    #f))

(unless (and (nonnegative-exact-integer? 0)
             (nonnegative-exact-integer? 7)
             (not (nonnegative-exact-integer? -1))
             (not (nonnegative-exact-integer? 1.5)))
  (error 'kernel-tests "nonnegative exact integer predicate differs"))

(let* ([profile
        (make-syntax-profile
          'scheme-test
          (lambda (character)
            (cond [(char-whitespace? character) 'whitespace]
                  [(or (char-alphabetic? character) (char-numeric? character)) 'word]
                  [(memv character '(#\- #\?)) 'symbol]
                  [else 'punctuation]))
          (list (cons #\( #\)) (cons #\[ #\]))
          (list ";") (list (cons "#|" "|#")) (list #\") #\\)]
       [configuration
        (make-configuration (list (make-buffer-syntax-profile-extension profile)))])
  (unless (and (eq? (configuration-facet
                      configuration buffer-syntax-profile-facet 'buffer)
                    profile)
               (syntax-profile-word-constituent? profile #\?)
               (equal? (syntax-profile-delimiter-pair profile #\])
                       (cons #\[ #\]))
               (syntax-profile-open-delimiter? profile #\()
               (syntax-profile-close-delimiter? profile #\)))
    (error 'kernel-tests "SyntaxProfile classification or configuration differs")))

(unless (and
          (library-binding-hidden? '(soda host buffer) 'buffer-document)
          (library-binding-hidden? '(soda host buffer) 'buffer-publish-state!)
          (library-binding-hidden? '(soda host view) 'view-publish-state!)
          (library-binding-hidden? '(soda host view) 'view-plugin-instances)
          (library-binding-hidden? '(soda view plugin) 'make-view-plugin-instance)
          (library-binding-hidden? '(soda host surface) 'surface-resize!)
          (library-binding-hidden? '(soda host surface) 'surface-set-selected-window!)
          (library-binding-hidden? '(soda host buffer) 'make-buffer-service)
          (library-binding-hidden? '(soda host view) 'make-view-service)
          (library-binding-hidden? '(soda host surface) 'make-surface-service)
          (library-binding-hidden? '(soda host state) 'host-state-buffers)
          (library-binding-hidden? '(soda host state) 'host-state-dispatch)
          (library-binding-hidden? '(soda host state) 'host-state-commands)
          (library-binding-hidden? '(soda host context) 'surface-select-view!)
          (library-binding-hidden? '(soda host context) 'surface-route-display-request!)
          (library-binding-hidden? '(soda host window) 'make-split-window)
          (library-binding-hidden? '(soda host window) 'window-layout!))
  (error 'kernel-tests "public host facade exposes dispatcher mutation"))

(define selection
  (make-selection
    (list (make-selection-range 1 4 'after 'character '(primary . #t))
          (make-selection-range 8 8))
    1))
(unless (= (selection-primary selection) 1)
  (error 'kernel-tests "selection primary differs"))
(unless (equal? (selection-range-from (selection-primary-range selection)) 8)
  (error 'kernel-tests "selection range differs"))

(unless (and (guard (condition [else #t]) (make-viewport -1 0) #f)
             (guard (condition [else #t]) (make-viewport 0 -1) #f))
  (error 'kernel-tests "Viewport rejects invalid coordinates"))

(let ([normalized
       (make-selection
         (list (make-selection-range 7 3)
               (make-selection-range 1 4))
         0
         'merge)])
  (unless (and (= (length (selection-ranges normalized)) 1)
               (= (selection-range-anchor (selection-primary-range normalized)) 7)
               (= (selection-range-head (selection-primary-range normalized)) 1))
    (error 'kernel-tests "overlapping selection ranges were not normalized")))
(unless
    (guard (condition [else #t])
      (make-selection
        (list (make-selection-range 1 4)
              (make-selection-range 3 5))
        0
        'reject)
      #f)
  (error 'kernel-tests "selection overlap rejection policy differs"))
(let* ([count 1024]
       [overlapping
        (let loop ([index 1] [result '()])
          (if (> index count)
              (reverse result)
              (loop
                (+ index 1)
                (cons (make-selection-range 0 index) result))))]
       [normalized (make-selection overlapping 0 'merge)]
       [range (selection-primary-range normalized)])
  (unless (and (= (length (selection-ranges normalized)) 1)
               (= (selection-range-anchor range) 0)
               (= (selection-range-head range) count))
    (error 'kernel-tests "large selection normalization differs")))

(call-with-values
  (lambda ()
    (change-by-range
      (make-selection
        (list (make-selection-range 1 1)
              (make-selection-range 3 3)))
      4
      (lambda (range)
        (let ([position (selection-range-head range)])
          (values
            (make-change-set 4 (list (make-text-change position position "X")))
            (make-selection-range (+ position 1) (+ position 1)))))))
  (lambda (range-changes range-selection)
    (unless (and (string=?
                   (change-set-apply range-changes (string->utf8 "abcd") #t)
                   "aXbcXd")
                 (equal? (map selection-range-head
                              (selection-ranges range-selection))
                         '(2 5)))
      (error 'kernel-tests "change-by-range composition differs"))))

(define changes
  (make-change-set
    12
    (list (make-text-change 2 4 "abc")
          (make-text-change 8 8 "x"))))
(unless (= (change-set-new-length changes) 14)
  (error 'kernel-tests "change set length differs"))
(let ([empty-change-set
       (make-change-set 5 (list (make-text-change 2 2 "")))])
  (unless (and (change-set-empty? empty-change-set)
               (= (change-set-new-length empty-change-set) 5))
    (error 'kernel-tests "empty text change was not normalized")))
(unless (= (change-set-map-offset changes 10 'after) 12)
  (error 'kernel-tests "change mapping differs"))
(unless (equal? (change-set-map-range changes 2 8 'after) (cons 5 10))
  (error 'kernel-tests "range mapping differs"))
(let* ([selection-before
        (make-selection (list (make-selection-range 2 2 'after 'character '())))]
       [selection-after
        (selection-map-change selection-before (change-set-change-desc changes))])
  (unless (= (selection-range-head (selection-primary-range selection-after)) 5)
    (error 'kernel-tests "Selection ChangeDesc mapping differs")))
(let ([replacement
        (make-change-set
          5
          (list (make-text-change 1 4 "xx")))])
  (unless (and (= (change-set-map-offset replacement 1 'before) 1)
               (= (change-set-map-offset replacement 4 'before) 1)
               (= (change-set-map-offset replacement 1 'after) 3)
               (= (change-set-map-offset replacement 4 'after) 3))
    (error 'kernel-tests "replacement boundary affinity differs")))
(let ([adjacent-insertions
        (make-change-set
          4
          (list (make-text-change 1 1 "a")
                (make-text-change 1 1 "b")))])
  (unless (and (= (change-set-map-offset adjacent-insertions 1 'before) 1)
               (= (change-set-map-offset adjacent-insertions 1 'after) 3))
    (error 'kernel-tests "adjacent insertion mapping differs")))
(let ([applied
        (change-set-apply
          (make-change-set
            5
            (list (make-text-change 1 2 "XYZ")
                  (make-text-change 4 5 "!")))
          (string->utf8 "abcde")
          #t)])
  (unless (string=? applied "aXYZcd!")
    (error 'kernel-tests "change set application differs")))
(let* ([base (string->utf8 "abcde")]
       [forward (make-change-set 5 (list (make-text-change 1 3 "XYZ")))]
       [inverse (change-set-invert forward base)])
  (unless (string=? (change-set-apply inverse (change-set-apply forward base) #t) "abcde")
    (error 'kernel-tests "change set inversion differs")))
(let* ([base (string->utf8 "abcde")]
       [first (make-change-set 5 (list (make-text-change 1 2 "XYZ")))]
       [second (make-change-set 7 (list (make-text-change 6 7 "!")))]
       [composed (change-set-compose first second)])
  (unless (string=? (change-set-apply composed base #t) "aXYZcd!")
    (error 'kernel-tests "change set composition differs")))
(let* ([base (string->utf8 "abcde")]
       [first (make-change-set 5 (list (make-text-change 1 1 "X")))]
       [second (make-change-set 6 (list (make-text-change 5 5 "Y")))]
       [composed (change-set-compose first second)])
  (unless (and (= (length (change-set-changes composed)) 2)
               (string=? (change-set-apply composed base #t) "aXbcdYe")
               (= (change-set-map-offset composed 2 'after) 3))
    (error 'kernel-tests "distant change composition differs")))
(let* ([size 2048]
       [base (string->utf8 (make-string size #\a))]
       [insertions
        (let loop ([position 0] [result '()])
          (if (= position size)
              (reverse result)
              (loop
                (+ position 1)
                (cons (make-text-change position position "x") result))))]
       [first (make-change-set size '())]
       [second (make-change-set size insertions)]
       [composed (change-set-compose first second)])
  (unless (bytevector=?
            (change-set-apply composed base)
            (change-set-apply second base))
    (error 'kernel-tests "large ChangeSet composition differs")))
(let* ([base (string->utf8 "abcde")]
       [first (make-change-set 5 (list (make-text-change 1 1 "X")))]
       [second (make-change-set 5 (list (make-text-change 4 4 "Y")))]
       [merged (change-set-merge first second)]
       [mapped-second (change-set-map second first)]
       [sequential (change-set-compose first mapped-second)])
  (unless (and (string=? (change-set-apply merged base #t) "aXbcdYe")
               (string=? (change-set-apply sequential base #t) "aXbcdYe"))
    (error 'kernel-tests "simultaneous change merge differs")))

;; Mapping concurrent replacements must satisfy the convergence law used by
;; transaction batching, including edits that overlap at the end boundary.
(let* ([base (string->utf8 "abcd")]
       [a (make-change-set 4 (list (make-text-change 4 4 "YZ")))]
       [b (make-change-set 4 (list (make-text-change 3 4 "YZ")))]
       [left
        (change-set-compose a (change-set-map b a))]
       [right
        (change-set-compose b (change-set-map a b #t))])
  (unless (bytevector=?
            (change-set-apply left base)
            (change-set-apply right base))
    (error 'kernel-tests "concurrent ChangeSet mapping did not converge")))

(let* ([base (string->utf8 "abcd")]
       [sets
        (map
          (lambda (spec)
            (make-change-set
              4
              (list (make-text-change (car spec) (cadr spec) (caddr spec)))))
          '((0 0 "X") (2 2 "YZ") (4 4 "X")
            (0 1 "") (1 3 "Q") (3 4 "YZ")
            (0 4 "") (0 4 "replacement")))])
  (for-each
    (lambda (a)
      (for-each
        (lambda (b)
          (let ([left
                 (change-set-compose a (change-set-map b a))]
                [right
                 (change-set-compose b (change-set-map a b #t))])
            (unless (bytevector=?
                      (change-set-apply left base)
                      (change-set-apply right base))
              (error 'kernel-tests "ChangeSet convergence matrix differs"))))
        sets))
    sets))

(let* ([description (change-set-change-desc changes)]
       [span (car (change-desc-changes description))])
  (unless (and (change-span? span)
               (= (change-span-from span) 2)
               (= (change-span-to span) 4)
               (= (change-span-insert-length span) 3)
               (not (text-change? span)))
    (error 'kernel-tests "ChangeDesc retained ChangeSet payload data")))
(let* ([base (string->utf8 "abcde")]
       [first-scroll (make-scroll-request 'reveal-point 0 0 0)]
       [second-scroll (make-scroll-request 'reveal-point 0 0 1)]
       [first-spec
        (make-transaction-spec
          0 #f 0
          (make-change-set 5 (list (make-text-change 1 1 "X")))
          #f '() '() first-scroll #f)]
       [second-spec
        (make-transaction-spec
          0 #f 0
          (make-change-set 5 (list (make-text-change 4 4 "Y")))
          #f '() '() second-scroll #f)]
       [resolved
        (resolve-transaction-specs (list first-spec second-spec) 5)]
       [sequential-spec
        (make-transaction-spec
          0 #f 0
          (make-change-set 6 (list (make-text-change 2 2 "Y")))
          #f '() '() #f #t)]
       [sequential-resolved
        (resolve-transaction-specs
          (list first-spec sequential-spec)
          5)])
(unless (and (string=?
                 (change-set-apply
                   (resolved-transaction-changes resolved) base #t)
                 "aXbcdYe")
               (string=?
                 (change-set-apply
                   (resolved-transaction-changes sequential-resolved) base #t)
                 "aXYbcde")
               (eq? (resolved-transaction-scroll-request resolved) second-scroll))
    (error 'kernel-tests "transaction spec resolution differs")))
(unless
    (guard (condition [else #t])
      (resolve-transaction-specs
        (list
          (make-transaction-spec
            0 #f 0
            (make-change-set 5 '())
            (make-selection (list (make-selection-range 6 6)))
            '() '()))
        5)
      #f)
  (error 'kernel-tests "out-of-range transaction selection was accepted"))
(unless
    (guard (condition [else #t])
      (make-transaction-spec
        0 #f 0 (make-change-set 0 '()) #f '() '() 'untyped-scroll-request)
      #f)
  (error 'kernel-tests "untyped transaction scroll request was accepted"))
(unless
    (guard (condition [else #t])
      (resolve-transaction-specs
        (list
          (make-transaction-spec 0 1 0 (make-change-set 5 '()) #f '() '())
          (make-transaction-spec 0 2 0 (make-change-set 5 '()) #f '() '()))
        5)
      #f)
  (error 'kernel-tests "multiple origin Views were accepted in one batch"))
(let* ([base (string->utf8 "abcde")]
       [first-spec
        (make-transaction-spec
          0 #f 0
          (make-change-set 5 (list (make-text-change 1 1 "X")))
          #f '() '() #f #f)]
       [second-spec
        (make-transaction-spec
          0 #f 0
          (make-change-set 5 (list (make-text-change 4 4 "Y")))
          (make-selection (list (make-selection-range 5 5 'after 'character '())))
          (list
            (make-state-effect
              'position 5
              (lambda (offset description)
                (change-desc-map-offset description offset 'after))))
          '() #f #f)]
       [resolved (resolve-transaction-specs (list first-spec second-spec) 5)])
  (unless (and (= (selection-range-head
                    (selection-primary-range
                      (resolved-transaction-selection resolved)))
                  6)
               (= (state-effect-value
                    (car (resolved-transaction-effects resolved)))
                  6))
    (error 'kernel-tests "non-sequential selection/effect mapping differs")))

(define first-range
  (make-range-value 1 3 'first 'before 'after))
(define second-range
  (make-range-value 6 8 'second 'after 'before))
(define ranges (make-range-set (list first-range second-range)))
(unless (and (eq? (range-value-value first-range) 'first)
             (eq? (range-value-start-affinity first-range) 'before)
             (eq? (range-value-end-affinity first-range) 'after)
             (eq? (car (range-set-query ranges 2 7)) first-range)
             (eq? (car (range-set-cursor ranges 6 9)) second-range)
             (eq? (range-cursor-current
                    (range-set-sweep-cursor ranges 6 9))
                  second-range))
  (error 'kernel-tests "range set query differs"))
(let ([cursor (range-set-sweep-cursor ranges 0 9)])
  (unless (and (eq? (range-cursor-current cursor) first-range)
               (eq? (range-cursor-next! cursor) second-range)
               (not (range-cursor-next! cursor))
               (range-cursor-done? cursor))
    (error 'kernel-tests "range cursor traversal differs")))
(let* ([outer (make-range-value 1 6 'outer)]
       [inner (make-range-value 3 4 'inner)]
       [overlapping (make-range-set (list outer inner))]
       [matches (range-set-query overlapping 3 4)])
  (unless (and (= (length matches) 2)
               (eq? (car matches) outer)
               (eq? (cadr matches) inner))
    (error 'kernel-tests "overlapping range query differs")))
(let* ([outer (make-range-value 1 6 'outer)]
       [point (make-range-value 3 3 'point)]
       [point-set (make-range-set (list outer point))]
       [matches (range-set-query-point point-set 3)])
  (unless (and (= (length matches) 2)
               (eq? (car matches) outer)
               (eq? (cadr matches) point))
    (error 'kernel-tests "point range query differs")))
(let* ([count 1024]
       [large-ranges
        (let loop ([index 0] [result '()])
          (if (= index count)
              (reverse result)
              (loop
                (+ index 1)
                (cons
                  (make-range-value (* 2 index) (+ (* 2 index) 1) index)
                  result))))]
       [large-set (make-range-set large-ranges)]
       [spans (range-set-spans large-set 0 (* 2 count))])
  (unless (and (= (length spans) (* 2 count))
               (= (range-span-from (car spans)) 0)
               (= (range-span-to (car spans)) 1)
               (= (range-value-value
                    (car (range-span-values (car spans))))
                  0))
    (error 'kernel-tests "large RangeSet sweep differs")))
(let* ([count 1024]
       [coincident-ranges
        (let loop ([index 0] [result '()])
          (if (= index count)
              (reverse result)
              (loop
                (+ index 1)
                (cons (make-range-value 0 1 index) result))))]
       [spans (range-set-spans (make-range-set coincident-ranges) 0 1)])
  (unless (and (= (length spans) 1)
               (= (length (range-span-values (car spans))) count)
               (= (range-value-value
                    (car (range-span-values (car spans))))
                  0))
    (error 'kernel-tests "coincident RangeSet sweep differs")))
(let* ([builder (make-range-set-builder)]
       [_ (range-set-builder-add! builder first-range)]
       [_ (range-set-builder-add! builder second-range)]
       [built (range-set-builder-finish! builder)])
  (unless (and (eq? (range-set-builder-finish! builder) built)
               (equal? (range-set-ranges built) (range-set-ranges ranges)))
    (error 'kernel-tests "range set builder differs")))
(let* ([point (make-range-value 3 3 'point 'after 'after 'retain #t)]
       [updated (range-set-update ranges (list point))]
       [spans (range-set-spans updated 0 9)]
       [point-span
        (let loop ([items spans])
          (cond
            [(null? items) #f]
            [(pair? (range-span-points (car items))) (car items)]
            [else (loop (cdr items))]))])
  (unless (and (range-value-point? point)
               point-span
               (= (range-span-from point-span) 3)
               (eq? (range-value-value
                      (car (range-span-points point-span)))
                    'point))
    (error 'kernel-tests "range set spans differs")))
(let ([filtered (range-set-update ranges '()
                                  (lambda (range)
                                    (not (eq? (range-value-value range) 'first))))])
  (unless (and (= (length (range-set-ranges filtered)) 1)
               (eq? (range-value-value
                      (car (range-set-ranges filtered)))
                    'second))
    (error 'kernel-tests "range set filter update differs")))
(let ([mapped
        (range-set-map-change
          ranges
          (make-change-set
            10
            (list (make-text-change 1 1 "xx"))))])
  (let ([mapped-ranges (range-set-ranges mapped)])
    (unless (and (= (range-value-from (car mapped-ranges)) 1)
                 (= (range-value-to (car mapped-ranges)) 5)
                 (= (range-value-from (cadr mapped-ranges)) 8)
                 (= (range-value-to (cadr mapped-ranges)) 10))
      (error 'kernel-tests "range set mapping differs"))))
(let ([mapped
        (range-set-map-change
          ranges
          (change-set-change-desc
            (make-change-set
              10
              (list (make-text-change 1 1 "xx")))))])
  (unless (= (range-value-to (car (range-set-ranges mapped))) 5)
    (error 'kernel-tests "range ChangeDesc mapping differs")))
(let ([collapsed
        (range-set-map-change
          (make-range-set
            (list (make-range-value 1 9 'deleted 'after 'before)))
          (make-change-set
            10
            (list (make-text-change 1 9 "x"))))])
  (let ([range (car (range-set-ranges collapsed))])
    (unless (and (= (range-value-from range) 1)
                 (= (range-value-to range) 1))
      (error 'kernel-tests "range deletion affinity differs"))))
(let ([mapped
        (range-set-map-change
          (make-range-set
            (list (make-range-value 1 4 'drop 'before 'after 'drop)
                  (make-range-value 7 9 'retain 'before 'after 'retain)))
          (make-change-set
            10
            (list (make-text-change 2 6 "x"))))])
  (let ([mapped-ranges (range-set-ranges mapped)])
    (unless (and (= (length mapped-ranges) 1)
                 (eq? (range-value-value (car mapped-ranges)) 'retain)
                 (eq? (range-value-map-mode (car mapped-ranges)) 'retain))
      (error 'kernel-tests "range deletion policy differs"))))
(let ([empty-changes (make-change-set 10 '())])
  (unless (and (eq? (range-set-map-change ranges empty-changes) ranges)
               (eq? (range-set-map ranges (lambda (range) range)) ranges))
    (error 'kernel-tests "range set no-op mapping did not preserve identity")))

(define history-field
  (make-state-field
    'history 'buffer
    (lambda (state) 'empty)
    (lambda (value transaction) value)))
(unless
    (guard (condition [else #t])
      (make-state-field 'unsupported-host-field 'host
                        (lambda (state) #f)
                        (lambda (value update) value))
      #f)
  (error 'kernel-tests "host-scoped StateField was accepted"))
(define read-only
  (make-facet 'read-only #f (lambda (values) (and (pair? values) (car values)))))
(define configuration
  (make-configuration
    (list history-field
          (make-facet-provider read-only #t 'high))))
(unless (eq? (car (configuration-fields configuration 'buffer)) history-field)
  (error 'kernel-tests "state field configuration differs"))
(unless (= (length (configuration-fields
                    (make-configuration (list history-field history-field))
                    'buffer))
           1)
  (error 'kernel-tests "duplicate state field was not normalized"))
(unless (configuration-facet configuration read-only)
  (error 'kernel-tests "facet configuration differs"))
(let* ([combine-count 0]
       [cached-facet
        (make-facet
          'cached 'buffer '()
          (lambda (values)
            (set! combine-count (+ combine-count 1))
            (list->vector values))
          equal?
          equal?)]
       [compartment (make-compartment 'cached)]
       [configuration
        (make-configuration
          (list (compartment-of
                  compartment
                  (make-facet-provider cached-facet 'same))))]
       [first (configuration-facet configuration cached-facet)]
       [again (configuration-facet configuration cached-facet)]
       [reconfigured
        (configuration-reconfigure
          configuration compartment
          (make-facet-provider cached-facet 'same))]
       [after (configuration-facet reconfigured cached-facet)])
  (unless (and (= combine-count 1)
               (eq? first again)
               (eq? first after))
    (error 'kernel-tests "Facet comparison/cache identity differs")))
(define view-only-facet
  (make-facet
    'view-only 'view #f
    (lambda (values) (car values))
    eq?))
(define view-only-configuration
  (make-configuration
    (list (make-facet-provider view-only-facet #t))))
(unless (and (not (configuration-facet view-only-configuration view-only-facet 'buffer))
             (configuration-facet view-only-configuration view-only-facet 'view))
  (error 'kernel-tests "facet scope differs"))

(define buffer-snapshot
  (make-buffer-state 'document configuration))
(define view-snapshot
  (make-view-state 0 0 selection (make-viewport 0 20) 'insert configuration))
(define spec (make-transaction-spec 0 0 changes))
(unless
    (guard (condition [else #t])
      (make-transaction-spec 0 #f changes)
      #f)
  (error 'kernel-tests "transaction spec accepted a missing generation"))
(unless (and (= (transaction-spec-buffer-id spec) 0)
             (eq? (buffer-state-field buffer-snapshot history-field) 'empty)
             (= (view-state-buffer-id view-snapshot) 0))
  (error 'kernel-tests "state protocol differs"))

(define initial-view-field
  (make-state-field
    'initial-view 'view
    (lambda (state)
      (if (selection? (view-state-selection state)) 'created 'invalid))
    (lambda (value transaction) value)))
(define initial-view-state
  (make-view-state
    0 0 selection (make-viewport 0 20) 'insert
    (make-configuration (list initial-view-field))))
(unless (eq? (view-state-field initial-view-state initial-view-field) 'created)
  (error 'kernel-tests "view StateField was not initialized with its state"))

(let* ([count 256]
       [fields
        (let loop ([index 0] [result '()])
          (if (= index count)
              (reverse result)
              (loop
                (+ index 1)
                (cons
                  (make-state-field
                    (string->symbol (string-append "field-" (number->string index)))
                    'buffer
                    (lambda (state) index)
                    (lambda (value transaction) value))
                  result))))]
       [state (make-buffer-state 'document (make-configuration fields))])
  (unless (and (= (length (buffer-state-fields state)) count)
               (= (buffer-state-field state (car fields)) 0)
               (= (buffer-state-field state (car (reverse fields))) (- count 1)))
    (error 'kernel-tests "large FieldTable differs")))

(let* ([provisional #f]
       [first-field
        (make-state-field
          'first-provisional 'buffer
          (lambda (state)
            (set! provisional state)
            'first)
          (lambda (value transaction) value))]
       [second-field
        (make-state-field
          'second-provisional 'buffer
          (lambda (state) 'second)
          (lambda (value transaction) value))]
       [state
        (make-buffer-state
          'document (make-configuration (list first-field second-field)))])
  (unless (and (eq? (buffer-state-field state second-field) 'second)
               (eq? (buffer-state-field provisional second-field 'missing)
                    'missing))
    (error 'kernel-tests "retained provisional StateField state was mutated")))

;; State effects are authored against the transaction's starting document and
;; are mapped before they reach the realized transaction.
(define position-effect
  (make-state-effect
    'position
    8
    (lambda (offset description)
      (change-desc-map-offset description offset 'after))))
(define mapped-transaction
  (make-transaction buffer-snapshot changes #f (list position-effect) '()))
(unless (= (state-effect-value (car (transaction-effects mapped-transaction))) 10)
  (error 'kernel-tests "state effect mapping differs"))
(let* ([false-effect
        (make-state-effect 'false-value #t (lambda (value description) #f))]
       [mapped
        (state-effect-map-value
          false-effect (change-set-change-desc (make-change-set 0 '())))]
       [dropped
        (state-effect-map-value
          (make-state-effect
            'drop #t (lambda (value description) state-effect-drop))
          (change-set-change-desc (make-change-set 0 '())))])
  (unless (and (state-effect? mapped)
               (not (state-effect-value mapped))
               (not dropped))
    (error 'kernel-tests "StateEffect false/drop mapping differs")))

(let* ([field
        (make-state-field
          'stable 'buffer
          (lambda (state) (vector 1))
          (lambda (value transaction) (vector (vector-ref value 0)))
          equal?)]
       [old-value (vector 1)]
       [state
        (make-buffer-state
          'document
          (make-configuration (list field))
          (list (cons field old-value)))]
       [transaction
        (make-transaction
          state (make-change-set 0 '()) #f '() '() 'document)])
  (unless (eq? (buffer-state-field (transaction-new-buffer-state transaction) field)
               old-value)
    (error 'kernel-tests "StateField.compare did not preserve equal state")))

(define mode-field
  (make-state-field
    'mode 'buffer
    (lambda (state) 'mode)
    (lambda (value transaction) value)))
(define mode-compartment (make-compartment 'mode))
(unless (and (compartment-entry? (compartment-of mode-compartment mode-field))
             (state-effect? (compartment-reconfigure mode-compartment mode-field)))
  (error 'kernel-tests "compartment convenience protocol differs"))
(define configurable-state
  (make-buffer-state
    'document
    (make-configuration
      (list (make-compartment-entry mode-compartment history-field)))))
(define reconfigured-transaction
  (make-transaction
    configurable-state changes #f
    (list (make-compartment-reconfigure-effect mode-compartment mode-field))
    '()))
(define reconfigured-state
  (transaction-new-buffer-state reconfigured-transaction))
(unless (eq? (buffer-state-field reconfigured-state mode-field) 'mode)
  (error 'kernel-tests "compartment reconfiguration differs"))

(let* ([mode-facet
        (make-facet 'mode-name #f (lambda (values) (car values)))]
       [observing-field
        (make-state-field
          'observing 'buffer
          (lambda (state)
            (configuration-facet
              (buffer-state-configuration state) mode-facet 'buffer))
          (lambda (value transaction) value))]
       [entry
        (list (make-facet-provider mode-facet 'scheme-mode)
              observing-field)]
       [compartment (make-compartment 'observed-mode)]
       [state (make-buffer-state 'document (make-configuration '()))]
       [transaction
        (make-transaction
          state (make-change-set 0 '()) #f
          (list (compartment-reconfigure compartment entry)) '()
          'document)]
       [new-state (transaction-new-buffer-state transaction)])
  (unless (eq? (buffer-state-field new-state observing-field) 'scheme-mode)
    (error 'kernel-tests "StateField.create did not observe new configuration")))
(let* ([new-compartment (make-compartment 'new-mode)]
       [new-configuration
        (configuration-apply-effects
          (make-configuration '())
          (list (make-compartment-reconfigure-effect
                  new-compartment mode-field)))])
  (unless (and (= (length (configuration-fields new-configuration 'buffer)) 1)
               (eq? (state-field-name
                      (car (configuration-fields new-configuration 'buffer)))
                    'mode))
    (error 'kernel-tests "absent compartment reconfiguration differs")))
(define reconfigured-with-view
  (make-transaction
    configurable-state changes #f
    (list (make-compartment-reconfigure-effect mode-compartment mode-field))
    '()))
(unless (not (pair?
              (filter
                compartment-entry?
                (configuration-extensions
                  (view-state-configuration
                    (view-state-advance
                      view-snapshot
                      (make-view-update-context
                        0 #t reconfigured-with-view view-snapshot
                        (selection-map-change
                          (view-state-selection view-snapshot) changes)
                        (view-state-viewport view-snapshot)
                        (view-state-input-state view-snapshot)
                        '()
                        (transaction-annotations reconfigured-with-view))))))))
  (error 'kernel-tests "compartment leaked into view configuration"))
(let* ([view-field
        (make-state-field
          'view-mode 'view
          (lambda (state) 'view-mode)
          (lambda (value transaction) value))]
       [view-compartment (make-compartment 'view-mode 'view)]
       [view-configuration
        (make-configuration
          (list (make-compartment-entry view-compartment '())))]
       [view-start
        (make-view-state
          0 0 selection (make-viewport 0 20) 'insert view-configuration)]
       [view-transaction
        (make-transaction
          buffer-snapshot (make-change-set 12 '()) #f
          (list
            (make-compartment-reconfigure-effect
              view-compartment view-field))
          '()
          'document)]
       [origin-state
        (view-state-advance
          view-start
          (make-view-update-context
            0 #t view-transaction view-start selection
            (view-state-viewport view-start)
            (view-state-input-state view-start)
            (list (make-compartment-reconfigure-effect
                    view-compartment view-field))
            (transaction-annotations view-transaction)))]
       [shared-state
        (view-state-advance
          view-start
          (make-view-update-context
            1 #f view-transaction view-start selection
            (view-state-viewport view-start)
            (view-state-input-state view-start)
            '()
            (transaction-annotations view-transaction)))])
  (unless (and (= (length (configuration-fields
                            (view-state-configuration origin-state)
                            'view))
                  1)
               (null? (configuration-fields
                        (view-state-configuration shared-state)
                        'view)))
    (error 'kernel-tests "view-scoped effect leaked to shared view")))

(define provided-facet (make-facet 'provided #f (lambda (values) (car values))))
(define provider-field
  (make-state-field
    'provider 'buffer
    (lambda (state) 'provider)
    (lambda (value transaction) value)
    eq?
    (lambda (field)
      (make-facet-provider provided-facet 'from-state-field))))
(unless (eq?
          (configuration-facet
            (make-configuration (list provider-field))
            provided-facet)
          'from-state-field)
  (error 'kernel-tests "state field provider differs"))
(let* ([ordered
        (make-facet 'ordered '() (lambda (values) (apply append values)))]
       [ordered-configuration
        (make-configuration
          (list
            (make-facet-provider ordered (list 'first))
            (make-facet-provider ordered (list 'second))))])
  (unless (equal? (configuration-facet ordered-configuration ordered)
                  '(first second))
    (error 'kernel-tests "facet provider order differs")))
(let* ([count 1024]
       [ordered (make-facet 'large-ordered '() (lambda (values) values))]
       [providers
        (let loop ([index 0] [result '()])
          (if (= index count)
              (reverse result)
              (loop
                (+ index 1)
                (cons (make-facet-provider ordered index) result))))]
       [values
        (configuration-facet (make-configuration providers) ordered)])
  (unless (and (= (length values) count)
               (= (car values) 0)
               (= (car (reverse values)) (- count 1)))
    (error 'kernel-tests "large facet provider order differs")))

(let ([drop-effect
        (make-state-effect
          'drop
          'value
          (lambda (value description) state-effect-drop))])
  (unless (not (state-effect-map-value
                drop-effect
                (change-set-change-desc changes)))
    (error 'kernel-tests "deleted state effect was not retired")))

(define host (make-host-state))
(define owner (make-owner 'kernel-test))
(let* ([document (make-document "abc")]
       [configuration (make-configuration '())]
       [buffer (buffer-service-create! (host-state-buffers host) owner "*deferred*"
                                       document configuration)]
       [view (view-service-create! (host-state-views host) owner buffer configuration)]
       [dispatcher (host-state-dispatch host)]
       [listener-count 0]
       [queued-result #t]
       [queued? #f]
       [first-selection (make-selection (list (make-selection-range 1 1)))]
       [second-selection (make-selection (list (make-selection-range 2 2)))])
  (dispatcher-set-listener!
    dispatcher
    (lambda (update)
      (set! listener-count (+ listener-count 1))
      (unless queued?
        (set! queued? #t)
        (let ([state (view-state view)])
          (set! queued-result
            (dispatcher-dispatch-view!
              dispatcher
              (make-view-transaction-spec
                (view-id view) (view-state-generation state)
                second-selection #f #f '() '() #f)))))))
  (dispatcher-dispatch-view!
    dispatcher
    (make-view-transaction-spec
      (view-id view) (view-state-generation (view-state view))
      first-selection #f #f '() '() #f))
  (dispatcher-set-listener! dispatcher #f)
  (unless (and (not queued-result)
               (= listener-count 2)
               (= (selection-range-head
                    (selection-primary-range (view-state-selection (view-state view))))
                  2))
    (error 'kernel-tests "Dispatcher did not defer a reentrant view update")))

;; Point motion is a semantic selection change.  Dispatcher owns the default
;; reveal contract so every package gets one viewport policy without coupling
;; its command implementation to a Surface or terminal geometry.
(let* ([document (make-document "abc")]
       [configuration (make-configuration '())]
       [buffer
        (buffer-service-create!
          (host-state-buffers host) owner "*point-reveal*" document configuration)]
       [view (view-service-create! (host-state-views host) owner buffer configuration)]
       [dispatcher (host-state-dispatch host)]
       [view-request #f]
       [viewport-request #t]
       [buffer-request #f]
       [selection (make-selection (list (make-selection-range 1 1)))])
  (dispatcher-set-listener!
    dispatcher
    (lambda (update)
      (cond
        [(not view-request) (set! view-request (editor-update-scroll-request update))]
        [(eq? viewport-request #t)
         (set! viewport-request (editor-update-scroll-request update))]
        [else (set! buffer-request (editor-update-scroll-request update))])))
  (dispatcher-dispatch-view!
    dispatcher
    (make-view-transaction-spec
      (view-id view) (view-state-generation (view-state view))
      selection #f #f '() '() #f))
  (dispatcher-dispatch-view!
    dispatcher
    (make-view-transaction-spec
      (view-id view) (view-state-generation (view-state view))
      selection (make-viewport 0 1) #f '() '() #f))
  (dispatcher-dispatch!
    dispatcher
    (make-transaction-spec
      (buffer-id buffer) (view-id view) (buffer-state-generation (buffer-state buffer))
      (make-change-set 3 '()) selection '() '()))
  (dispatcher-set-listener! dispatcher #f)
  (unless (and (scroll-request? view-request)
               (eq? (scroll-request-kind view-request) 'reveal-point)
               (= (scroll-request-view-id view-request) (view-id view))
               (not viewport-request)
               (scroll-request? buffer-request)
               (eq? (scroll-request-kind buffer-request) 'reveal-point)
               (= (scroll-request-view-id buffer-request) (view-id view)))
    (error 'kernel-tests "Dispatcher point reveal contract differs")))
(let ([text (string->text "e\x301;\x1f469;\x200d;\x1f4bb;")])
  (let ([first (text-next-grapheme-offset text 0)]
        [second (text-next-grapheme-offset text 3)]
        [previous (text-previous-grapheme-offset text 14)]
        [boundary (text-grapheme-boundary? text 3)]
        [inside (text-grapheme-boundary? text 1)])
    (unless (and (= first 3) (= second 14) (= previous 3)
                 boundary (not inside))
      (error
        'kernel-tests "grapheme boundary navigation differs"
        first second previous boundary inside)))
  (text-close! text))
(let ([text (string->text "\n\x301;")])
  (unless (and (= (text-next-grapheme-offset text 0) 1)
               (= (text-next-grapheme-offset text 1) 3))
    (error 'kernel-tests "control grapheme boundaries differ"))
  (text-close! text))

(let* ([resource (make-resource 'file "/tmp/location.ss")]
       [same-resource (make-resource 'file "/tmp/location.ss")]
       [location
        (make-location resource
                       (make-byte-position 2) (make-byte-position 4)
                       7 'after '((label . "definition")))]
       [changes
        (change-set-change-desc
          (make-change-set 6 (list (make-text-change 1 1 "xx"))))]
       [mapped (location-map-change-desc location changes 8)])
  (unless (and (resource=? resource same-resource)
               (location=? location
                           (make-location same-resource
                                          (make-byte-position 2)
                                          (make-byte-position 4)
                                          7 'after '()))
               (= (source-position-first (location-start mapped)) 4)
               (= (source-position-first (location-end mapped)) 6)
               (= (location-revision mapped) 8)
               (equal? (location-metadata mapped)
                       '((label . "definition")))
               (guard (condition [else #t])
                 (make-location resource
                                (make-utf16-position 0 1)
                                (make-byte-position 1)
                                #f 'after '())
                 #f))
    (error 'kernel-tests "Location coordinate or revision mapping differs")))

(define document (make-document "hello"))

(let* ([snapshot (document-snapshot document)]
       [changed
        (make-range-set
          (list (make-range-value 1 2 'changed)))]
       [request (make-analysis-request 7 snapshot changed)]
       [published '()]
       [deferred-publish! #f]
       [cancelled? #f]
       [provider
        (make-analysis-provider
          'test.syntax
          (lambda (received publish!)
            (unless (eq? received request)
              (error 'kernel-tests "AnalysisProvider request identity changed"))
            (set! deferred-publish! publish!)
            (lambda () (set! cancelled? #t))))]
       [cancel
        (analysis-provider-start!
          provider request (lambda (result) (set! published (cons result published))))]
       [result
        (make-analysis-result
          'test.syntax 7 (snapshot-revision snapshot)
          (make-range-set
            (list (make-range-value 1 4 'identifier)))
          '((language . scheme)))])
  (deferred-publish! result)
  (cancel)
  (unless (and cancelled?
               (= (analysis-request-revision request) (snapshot-revision snapshot))
               (eq? (car published) result)
               (equal? (map range-value-value
                            (analysis-result-query result 2 3))
                       '(identifier))
               (guard (condition [else #t])
                 (deferred-publish!
                   (make-analysis-result
                     'test.syntax 7 (+ 1 (snapshot-revision snapshot))
                     (make-range-set '()) '()))
                 #f))
    (error 'kernel-tests "AnalysisProvider publication contract differs"))
  (snapshot-close! snapshot))

(let* ([result
        (make-analysis-result
          'test.highlight 3 0
          (make-range-set
            (list (make-range-value 0 5 'comment)
                  (make-range-value 8 10 'number)))
          '((language . scheme)))]
       [decorations
        (analysis-result->decorations
          result (list (cons 0 3) (cons 2 5))
          (lambda (range metadata)
            (and (eq? (range-value-value range) 'comment)
                 (eq? (cdr (assq 'language metadata)) 'scheme)
                 (make-face-decoration 'syntax.comment 10))))]
       [ranges (range-set-ranges decorations)])
  (unless (and (= (length ranges) 1)
               (= (range-value-from (car ranges)) 0)
               (= (range-value-to (car ranges)) 5)
               (eq? (face-decoration-face (range-value-value (car ranges)))
                    'syntax.comment))
    (error 'kernel-tests
           "visible AnalysisResult projection duplicated or missed a range")))

(define buffer
  (buffer-service-create!
    (host-state-buffers host) owner "*kernel*" document configuration))
(define view
  (view-service-create!
    (host-state-views host) owner buffer configuration))

;; Buffer names are stable user-facing identities within a live catalog.  A
;; collision receives the same deterministic suffix convention as Emacs.
(let* ([duplicate
        (buffer-service-create!
          (host-state-buffers host) owner "*kernel*"
          (make-document "") configuration)]
       [third
        (buffer-service-create!
          (host-state-buffers host) owner "*kernel*"
          (make-document "") configuration)])
  (unless (and (string=? (buffer-name buffer) "*kernel*")
               (string=? (buffer-name duplicate) "*kernel*<2>")
               (string=? (buffer-name third) "*kernel*<3>"))
    (error 'kernel-tests "BufferService did not uniquify display names")))

(let* ([package-host (make-package-host host)]
       [provider-owner (make-owner 'analysis-service-test)]
       [decoration-publications 0]
       [analysis-buffer
        (buffer-service-create!
          (host-state-buffers host) provider-owner "*analysis*"
          (make-document "hello") configuration)]
       [analysis-view
        (view-service-create!
          (host-state-views host) provider-owner analysis-buffer configuration)]
       [_observer
        (dispatcher-add-listener!
          (host-state-dispatch host) provider-owner
          (lambda (update)
            (when (and (= (editor-update-buffer-id update)
                          (buffer-id analysis-buffer))
                       (memq 'decoration (editor-update-damage update)))
              (set! decoration-publications (+ decoration-publications 1)))))]
       [starts '()]
       [cancel-count 0]
       [provider
        (make-analysis-provider
          'test.service
          (lambda (request publish!)
            (set! starts (cons (cons request publish!) starts))
            (lambda () (set! cancel-count (+ cancel-count 1)))))]
       [registration
        (package-host-register-analysis-provider!
          package-host provider-owner provider)])
  (package-host-request-analysis!
    package-host (buffer-id analysis-buffer) 'test.service)
  (let ([first (car starts)]
        [state (buffer-state analysis-buffer)])
    (package-host-dispatch!
      package-host
      (make-transaction-spec
        (buffer-id analysis-buffer) (view-id analysis-view)
        (buffer-state-generation state)
        (make-change-set
          (snapshot-byte-size (buffer-state-document state))
          (list (make-text-change 5 5 "!")))
        #f '() '()))
    (unless (and (= (length starts) 2) (= cancel-count 1))
      (error 'kernel-tests
             "AnalysisService did not cancel and replace an older revision"))
    (let* ([second (car starts)]
           [first-request (car first)]
           [second-request (car second)])
      (let ([changed
             (range-set-ranges
               (analysis-request-changed-ranges second-request))])
        (unless (and (= (length changed) 1)
                     (= (range-value-from (car changed)) 5)
                     (= (range-value-to (car changed)) 6))
          (error 'kernel-tests
                 "AnalysisService did not publish new-revision changed ranges")))
      ((cdr first)
       (make-analysis-result
         'test.service (buffer-id analysis-buffer)
         (analysis-request-revision first-request)
         (make-range-set (list (make-range-value 0 1 'old))) '()))
      ((cdr second)
       (make-analysis-result
         'test.service (buffer-id analysis-buffer)
         (analysis-request-revision second-request)
         (make-range-set (list (make-range-value 0 2 'current))) '()))
      (host-state-run! host)
      (let ([result
             (package-host-analysis-result
               package-host (buffer-id analysis-buffer) 'test.service #f)])
        (unless (and result
                     (= (analysis-result-revision result)
                        (snapshot-revision
                          (buffer-state-document (buffer-state analysis-buffer))))
                     (equal?
                       (map range-value-value (analysis-result-query result 0 2))
                       '(current))
                     (= decoration-publications 1))
          (error 'kernel-tests
                 "stale AnalysisResult replaced the current revision"))))
    (unless (= cancel-count 1)
      (error 'kernel-tests "completed analysis task was cancelled")))
  (let* ([plugin
          (make-analysis-decoration-plugin
            package-host 'test.service
            (lambda (range metadata)
              (and (eq? (range-value-value range) 'current)
                   (make-face-decoration 'syntax.current 10))))]
         [configuration
          (make-configuration
            (list (make-facet-provider view-plugins-facet (list plugin))))]
         [visible-view
          (view-service-create!
            (host-state-views host) provider-owner analysis-buffer configuration)]
         [outside-view
          (view-service-create!
            (host-state-views host) provider-owner analysis-buffer configuration)])
    (view-service-publish-occurrences!
      (host-state-views host) (view-id visible-view)
      (list
        (make-view-occurrence
          1 1 (view-id visible-view) '(0 0 2 1) default-viewport
          (list (cons 0 1)) 0)))
    (view-service-publish-occurrences!
      (host-state-views host) (view-id outside-view)
      (list
        (make-view-occurrence
          1 2 (view-id outside-view) '(0 0 2 1) default-viewport
          (list (cons 3 6)) 0)))
    (unless (and (= (length
                      (range-set-ranges
                        (view-projection-decorations
                          (view-projection visible-view))))
                    1)
                 (range-set-empty?
                   (view-projection-decorations
                     (view-projection outside-view))))
      (error 'kernel-tests
             "shared analysis did not retain View-local visible projection")))
  (package-host-request-analysis!
    package-host (buffer-id analysis-buffer) 'test.service)
  (let* ([pending (car starts)]
         [request (car pending)]
         [buffer-id (buffer-id analysis-buffer)])
    (unless (package-host-close-buffer! package-host buffer-id)
      (error 'kernel-tests "analysis Buffer did not close"))
    ((cdr pending)
     (make-analysis-result
       'test.service buffer-id (analysis-request-revision request)
       (make-range-set '()) '()))
    (host-state-run! host)
    (unless (and (= cancel-count 2)
                 (not (package-host-analysis-result
                        package-host buffer-id 'test.service #f)))
      (error 'kernel-tests
             "closed Buffer accepted a late AnalysisResult")))
  (registration-close! registration)
  (owner-close! provider-owner))

(define leaf (make-leaf-window (view-id view) '(0 0 80 24)))
(define surface (make-surface 'terminal '(kitty color-256) leaf '(80 . 24)))

(let* ([package-host (make-package-host host)]
       [resource (make-resource 'buffer "kernel")]
       [provider-owner (make-owner 'location-provider-test)]
       [provider
        (make-location-provider
          'buffer
          (lambda (candidate)
            (and (resource=? candidate resource) (buffer-id buffer)))
          (lambda (location) (list 'open (location-resource location))))]
       [registration
        (package-host-register-location-provider!
          package-host provider-owner provider)]
       [revision (snapshot-revision (buffer-state-document (buffer-state buffer)))]
       [byte-resolution
        (package-host-resolve-location
          package-host
          (make-location resource
                         (make-byte-position 1) (make-byte-position 3)
                         revision 'after '()))]
       [line-resolution
        (package-host-resolve-location
          package-host
          (make-location resource
                         (make-line-column-position 0 2)
                         (make-line-column-position 0 4)
                         revision 'after '()))]
       [utf16-resolution
        (package-host-resolve-location
          package-host
          (make-location resource
                         (make-utf16-position 0 1)
                         (make-utf16-position 0 5)
                         revision 'after '()))]
       [stale-resolution
        (package-host-resolve-location
          package-host
          (make-location resource
                         (make-byte-position 0) (make-byte-position 0)
                         (+ revision 1) 'after '()))]
       [open-resolution
        (package-host-resolve-location
          package-host
          (make-location (make-resource 'buffer "missing")
                         (make-byte-position 0) (make-byte-position 0)
                         #f 'after '()))])
  (unless (and (eq? (location-resolution-status byte-resolution) 'resolved)
               (= (location-resolution-buffer-id byte-resolution) (buffer-id buffer))
               (= (location-resolution-from byte-resolution) 1)
               (= (location-resolution-to byte-resolution) 3)
               (eq? (location-resolution-status line-resolution) 'resolved)
               (= (location-resolution-from line-resolution) 2)
               (= (location-resolution-to line-resolution) 4)
               (eq? (location-resolution-status utf16-resolution) 'resolved)
               (= (location-resolution-from utf16-resolution) 1)
               (= (location-resolution-to utf16-resolution) 5)
               (eq? (location-resolution-status stale-resolution) 'stale)
               (eq? (location-resolution-status open-resolution) 'needs-open)
               (pair? (location-resolution-request open-resolution)))
    (error 'kernel-tests "LocationResolver coordinate or revision policy differs"))
  (registration-close! registration)
  (unless (eq? (location-resolution-status
                 (package-host-resolve-location
                   package-host
                   (make-location resource
                                  (make-byte-position 0) (make-byte-position 0)
                                  revision 'after '())))
               'unavailable)
    (error 'kernel-tests "LocationProvider owner cleanup differs"))
  (owner-close! provider-owner))

(let* ([package-host (make-package-host host)]
       [schema-owner (make-owner 'setting-schema-test)]
       [facet
        (make-facet
          'test-width 'buffer 1
          (lambda (values) (if (null? values) 1 (car values)))
          equal? equal?)]
       [compartment (make-compartment 'test-width 'buffer)]
       [schema
        (make-setting-schema
          'test.width 'positive-integer 4 '(workspace buffer)
          (lambda (input) (and (string? input) (string->number input)))
          (lambda (value) (<= value 16))
          (lambda (value scope)
            (compartment-of
              compartment (make-facet-provider facet value))))]
       [source
        (make-location
          (make-resource 'file "/tmp/soda.conf")
          (make-line-column-position 2 4)
          (make-line-column-position 2 6)
          #f 'after '())]
       [registration
        (package-host-register-setting-schema!
          package-host schema-owner schema)]
       [parsed
        (package-host-parse-setting
          package-host 'test.width "8" 'workspace source)]
       [configuration
        (make-configuration (list (setting-value-extension parsed)))])
  (unless (and (= (setting-value-value parsed) 8)
               (eq? (setting-value-source parsed) source)
               (= (configuration-facet configuration facet 'buffer) 8)
               (guard
                 (condition
                   [(setting-error? condition)
                    (and (eq? (setting-error-name condition) 'test.width)
                         (eq? (setting-error-source condition) source)
                         (equal? (setting-error-input condition) "20"))]
                   [else #f])
                 (package-host-parse-setting
                   package-host 'test.width "20" 'workspace source)
                 #f))
    (error 'kernel-tests "SettingSchema parsing or source diagnostics differ"))
  (let* ([file-resource (make-resource 'file "/tmp/project/main.scm")]
         [other-resource (make-resource 'file "/tmp/project/other.scm")]
         [context (make-configuration-context 'project-a file-resource)]
         [other-context (make-configuration-context 'project-b other-resource)]
         [declaration
          (lambda (input)
            (make-setting-declaration 'test.width input 'buffer source))]
         [application-source
          (make-configuration-source
            'test.application 'application #f (list (declaration "2")) 0)]
         [user-source
          (make-configuration-source
            'test.user 'user #f (list (declaration "4")) 0)]
         [workspace-source
          (make-configuration-source
            'test.workspace 'workspace 'project-a
            (list (declaration "8")) 0)]
         [file-source
          (make-configuration-source
            'test.file 'file-local file-resource
            (list (declaration "12")) 0)]
         [later-user-source
          (make-configuration-source
            'test.later-user 'user #f (list (declaration "6")) 0)]
         [updates '()]
         [observer
          (dispatcher-add-host-listener!
            (host-state-dispatch host) schema-owner
            (lambda (update) (set! updates (cons update updates))))])
    (for-each
      (lambda (configuration-source)
        (package-host-reload-configuration-source!
          package-host schema-owner configuration-source))
      (list application-source user-source workspace-source
            file-source later-user-source))
    (let* ([resolved
            (package-host-resolve-setting
              package-host 'test.width 'buffer context)]
           [other
            (package-host-resolve-setting
              package-host 'test.width 'buffer other-context)]
           [materialized
            (make-configuration
              (package-host-configuration-extensions
                package-host 'buffer context))]
           [update (car updates)])
      (unless (and (= (setting-value-value
                        (resolved-setting-value resolved)) 12)
                   (eq? (resolved-setting-source-id resolved) 'test.file)
                   (eq? (resolved-setting-layer resolved) 'file-local)
                   (= (setting-value-value
                        (resolved-setting-value other)) 6)
                   (= (configuration-facet materialized facet 'buffer) 12)
                   (not (host-update-surface-id update))
                   (memq 'configuration (host-update-damage update))
                   (eq? (host-update-resolution update) later-user-source))
        (error 'kernel-tests
               "ConfigurationSource precedence or publication differs")))
    (package-host-reload-configuration-source!
      package-host schema-owner
      (make-configuration-source
        'test.user 'user #f (list (declaration "5")) 1))
    (unless (= (setting-value-value
                 (resolved-setting-value
                   (package-host-resolve-setting
                     package-host 'test.width 'buffer other-context)))
               6)
      (error 'kernel-tests
             "ConfigurationSource reload changed stable source ordering"))
    (unless
      (guard
        (condition
          [(setting-error? condition)
           (and (eq? (setting-error-name condition) 'test.width)
                (eq? (setting-error-source condition) source))]
          [else #f])
        (package-host-reload-configuration-source!
          package-host schema-owner
          (make-configuration-source
            'test.user 'user #f (list (declaration "20")) 2))
        #f)
      (error 'kernel-tests
             "ConfigurationSource invalid reload did not report its source"))
    (unless (= (configuration-source-generation
                 (package-host-configuration-source package-host 'test.user))
               1)
      (error 'kernel-tests
             "ConfigurationSource invalid reload replaced active generation"))
    (registration-close! observer))
  (registration-close! registration)
  (unless (not (package-host-setting-schema package-host 'test.width #f))
    (error 'kernel-tests "SettingSchema Owner cleanup differs"))
  (owner-close! schema-owner))

(let* ([package-host (make-package-host host)]
       [resource (make-resource 'buffer "navigation")]
       [at
        (lambda (offset)
          (make-location resource
                         (make-byte-position offset) (make-byte-position offset)
                         #f 'after '()))]
       [first (package-host-begin-navigation! package-host (at 0) (at 1))]
       [replacement (package-host-begin-navigation! package-host (at 0) (at 2))])
  (unless (and (not (package-host-commit-navigation! package-host first (at 1)))
               (package-host-commit-navigation! package-host replacement (at 2)))
    (error 'kernel-tests "superseded navigation committed history"))
  (let ([cancelled (package-host-navigation-back! package-host)])
    (unless (and cancelled
                 (location=? (navigation-jump-target cancelled) (at 0))
                 (package-host-cancel-navigation! package-host cancelled)
                 (not (package-host-navigation-forward! package-host)))
      (error 'kernel-tests "cancelled navigation changed history cursor")))
  (let ([back (package-host-navigation-back! package-host)])
    (unless (and back
                 (package-host-commit-navigation! package-host back (at 0)))
      (error 'kernel-tests "navigation back did not commit")))
  (let ([forward (package-host-navigation-forward! package-host)])
    (unless (and forward
                 (location=? (navigation-jump-target forward) (at 2))
                 (package-host-commit-navigation! package-host forward (at 2)))
      (error 'kernel-tests "navigation forward did not commit")))
  (let ([back (package-host-navigation-back! package-host)])
    (package-host-commit-navigation! package-host back (at 0)))
  (let ([branch (package-host-begin-navigation! package-host (at 0) (at 3))])
    (unless (and (package-host-commit-navigation! package-host branch (at 3))
                 (not (package-host-navigation-forward! package-host)))
      (error 'kernel-tests "new navigation did not truncate forward history"))))
(surface-service-register! (host-state-surfaces host) surface)
(surface-set-selected-window! surface leaf)
  (unless (and (eq? (surface-selected-window surface) leaf)
             (eq? (surface-frontend surface) 'terminal)
             (equal? (surface-capabilities surface) '(kitty color-256))
             (= (buffer-id buffer) (view-state-buffer-id (view-state view))))
  (error 'kernel-tests "host state protocol differs"))

(let ([context (surface-active-context surface (host-state-views host))]
      [request (make-display-request (buffer-id buffer) (view-id view)
                                     'result 'focus 'same-window 'test)])
  (unless (and (active-context? context)
               (= (active-context-surface-id context) (surface-id surface))
               (= (active-context-window-id context) (window-id leaf))
               (= (active-context-view-id context) (view-id view))
               (= (active-context-buffer-id context) (buffer-id buffer))
               (display-request? request)
               (eq? (display-request-focus-policy request) 'focus))
    (error 'kernel-tests "active context or DisplayRequest differs")))

(let* ([other-document (make-document "other")]
       [other-buffer
        (buffer-service-create! (host-state-buffers host) owner "*other*"
                                other-document configuration)]
       [other-view
        (view-service-create! (host-state-views host) owner other-buffer configuration)]
       [host-updates '()]
       [left (make-leaf-window (view-id view) #f)]
       [right (make-leaf-window (view-id other-view) #f)]
       [split (make-split-window 'horizontal (list left right) #f)]
       [split-surface (make-surface split '(8 . 1))]
       [single-leaf (make-leaf-window (view-id view) #f)]
       [single-surface (make-surface single-leaf '(8 . 1))]
       [_registered
        (surface-service-register! (host-state-surfaces host) split-surface)]
       [_single-registered
        (surface-service-register! (host-state-surfaces host) single-surface)]
       [_listener
        (dispatcher-set-host-listener!
          (host-state-dispatch host)
          (lambda (update) (set! host-updates (cons update host-updates))))]
       [split-update
        (dispatcher-dispatch-host!
          (host-state-dispatch host)
          (make-split-view-operation
            (surface-id single-surface) 'horizontal (view-id other-view) 'focus))]
       [split-leaf-count (length (window-leaves (surface-root-window single-surface)))]
       [split-rectangle (window-rectangle (surface-selected-window single-surface))]
       [focus-update
        (dispatcher-dispatch-host!
          (host-state-dispatch host)
          (make-focus-view-operation (surface-id split-surface) (view-id other-view)))]
       [preserved
        (dispatcher-dispatch-host!
          (host-state-dispatch host)
          (make-display-request-operation
            (surface-id split-surface)
            (make-display-request (buffer-id buffer) #f 'result 'preserve #f 'test)))]
       [focused
        (dispatcher-dispatch-host!
          (host-state-dispatch host)
          (make-display-request-operation
            (surface-id split-surface)
            (make-display-request (buffer-id buffer) #f 'result 'focus #f 'test)))]
       [interaction-update
        (dispatcher-dispatch-host!
          (host-state-dispatch host)
          (make-push-interaction-operation
            (surface-id split-surface) (view-id other-view) 1))]
       [interaction-render (render-surface split-surface (host-state-views host))]
       [pop-update
        (dispatcher-dispatch-host!
          (host-state-dispatch host)
          (make-pop-interaction-operation (surface-id split-surface)))]
       [resize-update
        (dispatcher-dispatch-host!
          (host-state-dispatch host)
          (make-resize-surface-operation (surface-id split-surface) '(16 . 2)))]
       [remove-update
        (dispatcher-dispatch-host!
          (host-state-dispatch host)
          (make-remove-window-operation
            (surface-id single-surface)
            (active-context-window-id (host-update-resolution split-update))))]
       [redraw-update
        (dispatcher-dispatch-host!
          (host-state-dispatch host)
          (make-invalidate-surface-operation (surface-id split-surface)))]
       [window-focus-update
        (dispatcher-dispatch-host!
          (host-state-dispatch host)
          (make-focus-window-operation
            (surface-id split-surface) (window-id right)))]
       [generation (surface-generation split-surface)])
  (unless (and (host-update? split-update)
               (= (active-context-view-id (host-update-resolution split-update))
                  (view-id other-view))
               (= split-leaf-count 2)
               (equal? split-rectangle '(0 4 4 1))
               (= (length (window-leaves (surface-root-window single-surface))) 1)
               (eq? (surface-selected-window single-surface) single-leaf)
               (host-update? remove-update)
               (host-update? focus-update)
               (= (active-context-view-id (host-update-new-context focus-update))
                  (view-id other-view))
               (= (active-context-buffer-id (host-update-resolution focus-update))
                  (buffer-id other-buffer))
               (host-update? preserved)
               (= (active-context-view-id (host-update-resolution preserved)) (view-id view))
               (= (active-context-view-id (host-update-new-context preserved))
                  (view-id other-view))
               (null? (host-update-damage preserved))
               (host-update? focused)
               (= (active-context-view-id (host-update-resolution focused)) (view-id view))
               (= (active-context-view-id (host-update-new-context focused)) (view-id view))
               (equal? (host-update-damage focused) '(chrome))
               (host-update? interaction-update)
               (= (active-context-view-id (host-update-new-context interaction-update))
                  (view-id other-view))
               (= (length (active-context-interaction-stack
                            (host-update-new-context interaction-update)))
                  1)
               (string=? (frame-cell-grapheme
                           (frame-cell-at (surface-render-frame interaction-render) 0 0))
                         "o")
               (= (surface-render-cursor-column interaction-render) 0)
               (host-update? pop-update)
               (= (active-context-view-id (host-update-new-context pop-update)) (view-id view))
               (host-update? resize-update)
               (equal? (host-update-damage resize-update) '(resize layout))
               (equal? (surface-size split-surface) '(16 . 2))
               (host-update? redraw-update)
               (equal? (host-update-damage redraw-update) '(redraw))
               (host-update? window-focus-update)
               (= (active-context-window-id
                    (host-update-resolution window-focus-update))
                  (window-id right))
               (= (length host-updates) 10)
               (eq? (surface-selected-window split-surface) right)
               (eq? (surface-set-selected-window! split-surface right) right)
               (= (surface-generation split-surface) generation)
               (not (dispatcher-dispatch-host!
                      (host-state-dispatch host)
                      (make-focus-view-operation (surface-id split-surface) 999999))))
    (error 'kernel-tests "Surface View focus routing differs"))
  (dispatcher-set-host-listener! (host-state-dispatch host) #f)
  (surface-service-remove! (host-state-surfaces host) (surface-id split-surface))
  (surface-service-remove! (host-state-surfaces host) (surface-id single-surface))
  (let* ([prune-left (make-leaf-window (view-id view) #f)]
         [prune-right (make-leaf-window (view-id other-view) #f)]
         [prune-root (make-split-window 'horizontal (list prune-left prune-right) #f)]
         [prune-surface (make-surface prune-root '(8 . 1))]
         [lone-surface (make-surface (make-leaf-window (view-id other-view) #f) '(4 . 1))]
         [stale-render (render-surface prune-surface (host-state-views host))]
         [stale-hit (surface-render-hit-test stale-render 0 6)])
    (surface-service-register! (host-state-surfaces host) prune-surface)
    (surface-service-register! (host-state-surfaces host) lone-surface)
    (surface-push-interaction! prune-surface (view-id other-view) 1)
    (view-service-close-view! (host-state-views host) (view-id other-view))
    (unless (and (surface-service-ref (host-state-surfaces host)
                                     (surface-id prune-surface) #f)
                 (= (length (window-leaves (surface-root-window prune-surface))) 1)
                 (eq? (surface-selected-window prune-surface) prune-left)
                 (null? (surface-interaction-windows prune-surface))
                 (not (surface-service-ref (host-state-surfaces host)
                                           (surface-id lone-surface) #f))
                 (not (host-frontend-surface-hit-current?
                        host prune-surface stale-hit))
                 (= (active-context-view-id
                     (surface-active-context prune-surface (host-state-views host)))
                    (view-id view)))
      (error 'kernel-tests "View close did not prune Surface placement"))
    (surface-service-remove! (host-state-surfaces host) (surface-id prune-surface))))

(let* ([closing-document (make-document "closing")]
       [closing-buffer
        (buffer-service-create! (host-state-buffers host) owner "*closing*"
                                closing-document configuration)]
       [closing-view
        (view-service-create! (host-state-views host) owner closing-buffer configuration)]
       [closing-surface
        (make-surface (make-leaf-window (view-id closing-view) #f) '(8 . 1))])
  (surface-service-register! (host-state-surfaces host) closing-surface)
  (buffer-service-close-buffer! (host-state-buffers host) (buffer-id closing-buffer))
  (unless (and (not (buffer-service-ref (host-state-buffers host) (buffer-id closing-buffer) #f))
               (not (view-service-ref (host-state-views host) (view-id closing-view) #f))
               (not (member closing-buffer
                            (buffer-service-buffers (host-state-buffers host))))
               (not (member closing-view
                            (view-service-views (host-state-views host))))
               (not (surface-service-ref (host-state-surfaces host)
                                         (surface-id closing-surface) #f)))
    (error 'kernel-tests "Buffer close did not retire View and Surface")))

(let* ([left (make-leaf-window 1 #f)]
       [right (make-leaf-window 2 #f)]
       [root (make-split-window 'horizontal (list left right) #f)])
  (window-layout! root 0 0 7 3)
  (unless (and (equal? (window-rectangle left) '(0 0 4 3))
               (equal? (window-rectangle right) '(0 4 3 3)))
    (error 'kernel-tests "Window grid layout differs")))

(let* ([left (make-leaf-window 1 #f)]
       [right (make-leaf-window 2 #f)]
       [root (make-split-window 'horizontal (list left right) '(1/3 2/3) #f)]
       [surface (make-surface root '(7 . 3))])
  (unless (and (equal? (window-rectangle left) '(0 0 2 3))
               (equal? (window-rectangle right) '(0 2 5 3))
               (eq? (surface-selected-window surface) left)
               (window-selected? left))
    (error 'kernel-tests "weighted Window layout or initial selection differs")))

(let* ([left (make-leaf-window 1 #f)]
       [middle (make-leaf-window 2 #f)]
       [right (make-leaf-window 3 #f)]
       [root (make-split-window 'horizontal (list left middle right) #f)]
       [surface (make-surface root '(9 . 1))])
  (surface-set-selected-window! surface right)
  (surface-remove-window! surface (window-id left))
  (unless (and (eq? (surface-selected-window surface) right)
               (= (length (window-leaves (surface-root-window surface))) 2))
    (error 'kernel-tests "Surface retained focus after non-active leaf removal differs")))

(surface-resize! surface '(40 . 12))
(unless (and (= (surface-generation surface) 1)
             (equal? (window-rectangle leaf) '(0 0 40 12)))
  (error 'kernel-tests "Surface resize layout differs"))
(surface-resize! surface '(80 . 24))

(let ([rendered (render-surface surface (host-state-views host))])
  (let ([hit (surface-render-hit-test rendered 0 1)])
    (unless (and (= (frame-width (surface-render-frame rendered)) 80)
                 (= (frame-height (surface-render-frame rendered)) 24)
                 (= (surface-render-cursor-row rendered) 0)
                 (= (surface-render-cursor-column rendered) 0)
                 (= (length (surface-render-rendered-views rendered)) 1)
                 (surface-hit? hit)
                 (= (surface-render-surface-id rendered) (surface-id surface))
                 (= (surface-render-surface-generation rendered)
                    (surface-generation surface))
                 (= (surface-hit-window-id hit) (window-id leaf))
                 (eqv? (surface-hit-view-id hit) (view-id view))
                 (= (surface-hit-document-offset hit) 1)
                 (string=? (frame-cell-grapheme (frame-cell-at (surface-render-frame rendered) 0 0)) "h"))
    (error 'kernel-tests "Surface render composition differs"))))

;; Projection, Frame diffing, and ANSI encoding consume immutable published
;; values.  None of them may advance host generations or replace live state.
(let* ([buffer-state-before (buffer-state buffer)]
       [view-state-before (view-state view)]
       [projection-before (view-projection view)]
       [view-render-generation-before (view-render-generation view)]
       [surface-generation-before (surface-generation surface)]
       [rendered (render-surface surface (host-state-views host))]
       [frame (surface-render-frame rendered)]
       [_spans (frame-diff frame frame)]
       [_ansi (frame-diff->ansi frame frame default-theme 0 0)])
  (unless (and (eq? buffer-state-before (buffer-state buffer))
               (eq? view-state-before (view-state view))
               (eq? projection-before (view-projection view))
               (= view-render-generation-before (view-render-generation view))
               (= surface-generation-before (surface-generation surface)))
    (error 'kernel-tests "render or presentation projection mutated host state")))

(let ([service (make-render-service)])
  (let ([first (render-service-render! service surface (host-state-views host))]
        [second (render-service-render! service surface (host-state-views host))])
    (unless (eq? first second)
      (error 'kernel-tests "RenderService did not reuse an unchanged render"))
    (surface-resize! surface '(79 . 24))
    (let ([resized (render-service-render! service surface (host-state-views host))])
      (unless (and (not (eq? second resized))
                   (= (frame-width (surface-render-frame resized)) 79))
        (error 'kernel-tests "RenderService did not invalidate resized Surface")))
    (surface-resize! surface '(80 . 24))
    (render-service-invalidate! service)
    (unless (not (eq? first (render-service-render! service surface (host-state-views host))))
      (error 'kernel-tests "RenderService invalidation differs"))))

(let* ([document (make-document "cache")]
       [buffer (buffer-service-create! (host-state-buffers host) owner "*cache*"
                                       document configuration)]
       [view (view-service-create! (host-state-views host) owner buffer configuration)]
       [leaf (make-leaf-window (view-id view) '(0 0 3 1))]
       [surface (make-surface leaf '(3 . 1))]
       [service (make-render-service)]
       [initial (render-service-render! service surface (host-state-views host))]
       [state (view-state view)]
       [_input-update
        (dispatcher-dispatch-view!
          (host-state-dispatch host)
          (make-view-transaction-spec
            (view-id view) (view-state-generation state)
            #f #f
            (make-input-stack (make-input-state 'transient '() 'accept))
            '() '() #f))]
       [after-input (render-service-render! service surface (host-state-views host))]
       [state (view-state view)]
       [_selection-update
        (dispatcher-dispatch-view!
          (host-state-dispatch host)
          (make-view-transaction-spec
            (view-id view) (view-state-generation state)
            (make-selection (list (make-selection-range 1 1))) #f #f
            '() '() #f))]
       [after-selection (render-service-render! service surface (host-state-views host))]
       [state (view-state view)]
       [_range-update
        (dispatcher-dispatch-view!
          (host-state-dispatch host)
          (make-view-transaction-spec
            (view-id view) (view-state-generation state)
            (make-selection (list (make-selection-range 0 2))) #f #f
            '() '() #f))]
       [after-range (render-service-render! service surface (host-state-views host))]
       [state (view-state view)]
       [_viewport-update
        (dispatcher-dispatch-view!
          (host-state-dispatch host)
          (make-view-transaction-spec
            (view-id view) (view-state-generation state)
            #f (make-viewport 0 1) #f '() '() #f))]
       [after-viewport (render-service-render! service surface (host-state-views host))]
       [view-field
        (make-state-field
          'render-cache-view-configuration 'view
          (lambda (state) 'enabled)
          (lambda (value transaction) value))]
       [view-compartment (make-compartment 'render-cache-view-configuration 'view)]
       [state (view-state view)]
       [_configuration-update
        (dispatcher-dispatch-view!
          (host-state-dispatch host)
          (make-view-transaction-spec
            (view-id view) (view-state-generation state)
            #f #f #f
            (list (make-compartment-reconfigure-effect
                    view-compartment view-field))
            '() #f))]
       [after-configuration
        (render-service-render! service surface (host-state-views host))]
       [_document-update
        (dispatcher-dispatch!
          (host-state-dispatch host)
          (make-transaction-spec
            (buffer-id buffer) (view-id view)
            (buffer-state-generation (buffer-state buffer))
            (make-change-set 5 (list (make-text-change 5 5 "!")))
            #f '() '()))]
       [after-document (render-service-render! service surface (host-state-views host))]
       [_chrome-update
        (surface-set-feedback! surface (make-user-feedback "cache status"))]
       [after-chrome (render-service-render! service surface (host-state-views host))]
       [_layout-update (surface-push-interaction! surface (view-id view) 1)]
       [after-layout (render-service-render! service surface (host-state-views host))])
  (unless (and (eq? initial after-input)
               (not (eq? after-input after-selection))
               (eq? (surface-render-frame after-input)
                    (surface-render-frame after-selection))
               (eq? (rendered-view-layout
                      (car (surface-render-rendered-views after-input)))
                    (rendered-view-layout
                      (car (surface-render-rendered-views after-selection))))
               (= (surface-render-cursor-column after-selection) 1)
               (not (eq? (surface-render-frame after-selection)
                         (surface-render-frame after-range)))
               (not (eq? after-range after-viewport))
               (not (eq? after-viewport after-configuration))
               (not (eq? after-configuration after-document))
               (not (eq? after-document after-chrome))
               (not (eq? after-chrome after-layout)))
    (error 'kernel-tests "RenderService invalidation matrix differs")))

;; Temporary interaction Windows consume dedicated rows between root Window
;; mode lines and the echo area. They do not cover either stable chrome layer.
(let* ([root-document (make-document "root")]
       [root-buffer
        (buffer-service-create!
          (host-state-buffers host) owner "*chrome-root*"
          root-document configuration)]
       [root-view
        (view-service-create!
          (host-state-views host) owner root-buffer configuration)]
       [prompt-document (make-document "prompt")]
       [prompt-buffer
        (buffer-service-create!
          (host-state-buffers host) owner " *chrome-prompt*"
          prompt-document configuration)]
       [prompt-view
        (view-service-create!
          (host-state-views host) owner prompt-buffer configuration)]
       [surface
        (make-surface
          'terminal '(mode-line echo-area)
          (make-leaf-window (view-id root-view) #f) '(10 . 6))]
       [interaction
        (surface-push-interaction!
          surface (view-id prompt-view) 1)]
       [render (render-surface surface (host-state-views host))]
       [root-rendered
        (find
          (lambda (item) (= (rendered-view-view-id item) (view-id root-view)))
          (surface-render-rendered-views render))]
       [prompt-rendered
        (find
          (lambda (item) (= (rendered-view-view-id item) (view-id prompt-view)))
          (surface-render-rendered-views render))]
       [frame (surface-render-frame render)])
  (unless (and root-rendered prompt-rendered
               (= (cadddr (rendered-view-rectangle root-rendered)) 3)
               (= (car (rendered-view-rectangle prompt-rendered)) 4)
               (= (cadddr (rendered-view-rectangle prompt-rendered)) 1)
               (eq? (frame-cell-face (frame-cell-at frame 3 0)) 'mode-line)
               (not (eq? (frame-cell-face (frame-cell-at frame 4 0))
                         'mode-line)))
    (error 'kernel-tests
           "interaction Window did not reserve root, mode-line, and echo rows"))
  (surface-resize! surface '(14 . 6))
  (let* ([resized-render (render-surface surface (host-state-views host))]
         [resized-prompt
          (find
            (lambda (item) (= (rendered-view-view-id item) (view-id prompt-view)))
            (surface-render-rendered-views resized-render))])
    (unless (and resized-prompt
                 (equal? (rendered-view-rectangle resized-prompt) '(4 0 14 1)))
      (error 'kernel-tests
             "interaction Window did not follow the resized Surface width")))
  (surface-resize! surface '(10 . 6))
  (surface-set-feedback!
    surface (make-user-feedback "older feedback" 'warning))
  (surface-push-interaction!
    surface (view-id root-view) 1)
  (unless (surface-remove-interaction! surface (view-id prompt-view))
    (error 'kernel-tests "specific interaction View was not removed"))
  (let* ([interactions (surface-interaction-windows surface)]
         [hidden (surface-render-frame
                   (render-surface surface (host-state-views host)))])
    (unless (and (= (length interactions) 1)
                 (= (window-view-id (car interactions)) (view-id root-view))
                 (string=? (frame-cell-grapheme (frame-cell-at hidden 5 0)) " "))
      (error 'kernel-tests
             "non-top interaction removal or feedback suppression differs")))
  (surface-remove-interaction! surface (view-id root-view))
  (let ([restored
         (surface-render-frame (render-surface surface (host-state-views host)))])
    (unless (string=? (frame-cell-grapheme (frame-cell-at restored 5 0)) " ")
      (error 'kernel-tests
             "retired feedback resurfaced after the interaction closed")))
  (surface-resize! surface '(10 . 1))
  (let ([minimal (render-surface surface (host-state-views host))])
    (unless (and
              (string=?
                (frame-cell-grapheme (frame-cell-at (surface-render-frame minimal) 0 0))
                "r")
              (= (surface-render-cursor-row minimal) 0))
      (error 'kernel-tests
             "one-row Surface let echo feedback replace editable content"))))

;; A ViewPlugin may project InputState even though core rendering does not.
;; Its published projection generation must invalidate only that View's render
;; token, leaving sibling Views of the same Buffer untouched.
(let* ([plugin
        (make-view-plugin
          'independent-projection
          (lambda (view) (vector 0))
          (lambda (value update)
            (when (view-update-damaged? update 'input)
              (vector-set! value 0 (+ 1 (vector-ref value 0)))))
          #f #f
          (lambda (value)
            (make-display-stream
              (list (make-display-text
                      (if (= (vector-ref value 0) 0) "a" "b")
                      0 1 'text 'plugin)))))]
       [plugin-configuration
        (make-configuration
          (list (make-facet-provider view-plugins-facet (list plugin))))]
       [document (make-document "x")]
       [buffer (buffer-service-create! (host-state-buffers host) owner
                                       "*independent-views*" document
                                       plugin-configuration)]
       [left (view-service-create! (host-state-views host) owner buffer
                                   plugin-configuration)]
       [right (view-service-create! (host-state-views host) owner buffer
                                    plugin-configuration)]
       [left-surface (make-surface (make-leaf-window (view-id left) '(0 0 1 1))
                                   '(1 . 1))]
       [service (make-render-service)]
       [before (render-service-render! service left-surface (host-state-views host))]
       [right-state (view-state right)]
       [right-projection (view-projection right)]
       [left-state (view-state left)]
       [_update
        (dispatcher-dispatch-view!
          (host-state-dispatch host)
          (make-view-transaction-spec
            (view-id left) (view-state-generation left-state)
            (make-selection (list (make-selection-range 1 1)))
            #f
            (make-input-stack (make-input-state 'transient '() 'accept))
            '() '() #f))]
       [after (render-service-render! service left-surface (host-state-views host))])
  (unless (and (not (eq? before after))
               (string=? (frame-cell-grapheme
                            (frame-cell-at (surface-render-frame after) 0 0)) "b")
               (eq? right-state (view-state right))
               (eq? right-projection (view-projection right))
               (= (selection-range-head
                    (selection-primary-range
                      (view-state-selection (view-state left))))
                  1)
               (= (viewport-visual-row
                    (view-state-viewport (view-state left)))
                  0)
               (= (selection-range-head
                    (selection-primary-range
                      (view-state-selection (view-state right))))
                  0)
               (= (viewport-visual-row
                    (view-state-viewport (view-state right)))
                  0))
    (error 'kernel-tests "sibling View state or projection was not independent")))

(let* ([layout-configuration
        (make-configuration
          (list (make-facet-provider text-layout-options-facet
                                     (make-text-layout-options 2 #f))))]
       [configured-document (make-document "abc")]
       [configured-buffer
        (buffer-service-create! (host-state-buffers host) owner "*layout*"
                                configured-document layout-configuration)]
       [configured-view
        (view-service-create! (host-state-views host) owner configured-buffer
                              layout-configuration)]
       [configured-leaf (make-leaf-window (view-id configured-view) '(0 0 2 2))]
       [configured-surface (make-surface configured-leaf '(2 . 2))]
       [configured-render (render-surface configured-surface (host-state-views host))])
  (unless (and (string=? (frame-cell-grapheme
                           (frame-cell-at (surface-render-frame configured-render) 0 0)) "a")
               (string=? (frame-cell-grapheme
                           (frame-cell-at (surface-render-frame configured-render) 1 0)) " "))
    (error 'kernel-tests "View text layout configuration differs")))

(let* ([document (make-document "a\nb")]
       [buffer (buffer-service-create! (host-state-buffers host) owner "*viewport*"
                                       document configuration)]
       [view (view-service-create! (host-state-views host) owner buffer configuration)]
       [leaf (make-leaf-window (view-id view) '(0 0 2 1))]
       [surface (make-surface leaf '(2 . 1))]
       [state (view-state view)]
       [_update
        (dispatcher-dispatch-view!
          (host-state-dispatch host)
          (make-view-transaction-spec
            (view-id view) (view-state-generation state)
            #f (make-viewport 0 1) #f '() '() #f))]
       [render (render-surface surface (host-state-views host))])
  (unless (and (string=? (frame-cell-grapheme
                           (frame-cell-at (surface-render-frame render) 0 0)) "b")
               (= (surface-hit-document-offset
                    (surface-render-hit-test render 0 0))
                  2))
    (error 'kernel-tests "View visual viewport rendering differs")))

(let* ([plugin
        (make-view-plugin
          'display-stream
          (lambda (view) 'ready)
          #f #f #f
          (lambda (value)
            (make-display-stream
              (list (make-display-text "virtual" 0 7 'virtual 'plugin)))))]
       [configuration
        (make-configuration
          (list (make-facet-provider view-plugins-facet (list plugin))))]
       [document (make-document "hidden")]
       [buffer
        (buffer-service-create! (host-state-buffers host) owner "*display*"
                                document configuration)]
       [view (view-service-create! (host-state-views host) owner buffer configuration)]
       [leaf (make-leaf-window (view-id view) '(0 0 3 1))]
       [surface (make-surface leaf '(3 . 1))]
       [render (render-surface surface (host-state-views host))])
  (unless (and (display-stream? (view-projection-display-stream (view-projection view)))
               (string=? (frame-cell-grapheme
                           (frame-cell-at (surface-render-frame render) 0 0)) "v")
               (eq? (frame-cell-face
                     (frame-cell-at (surface-render-frame render) 0 0)) 'virtual))
    (error 'kernel-tests "cached View display stream differs"))
  (unless (= (text-layout-content-height
               (layout-display-stream
                 (view-projection-display-stream (view-projection view))
                 (view-state-selection (view-state view)) 3 7))
             3)
    (error 'kernel-tests "transformed DisplayStream geometry height differs"))
  (let* ([rendered (car (surface-render-rendered-views render))]
         [active (make-active-context
                   (surface-id surface) (window-id leaf) (view-id view) (buffer-id buffer) '())])
    (host-frontend-resolve-scroll-request!
      host active (rendered-view-layout rendered)
      (make-scroll-request
        'scroll-rows (surface-id surface) (window-id leaf) (view-id view) 1))
    (let ([next (render-surface surface (host-state-views host))])
      (unless (string=?
                (frame-cell-grapheme (frame-cell-at (surface-render-frame next) 0 0))
                "t")
        (error 'kernel-tests
               "viewport intent did not use transformed DisplayStream geometry")))))

(let* ([first
        (make-view-plugin
          'first-display (lambda (view) 'ready) #f #f #f
          (lambda (value) (make-display-stream '())))]
       [second
        (make-view-plugin
          'second-display (lambda (view) 'ready) #f #f #f
          (lambda (value) (make-display-stream '())))]
       [configuration
        (make-configuration
          (list (make-facet-provider view-plugins-facet (list first second))))]
       [document (make-document "hidden")]
       [buffer (buffer-service-create! (host-state-buffers host) owner "*ambiguous-display*"
                                       document configuration)])
  (unless
      (guard (condition [else #t])
        (view-service-create! (host-state-views host) owner buffer configuration)
        #f)
    (error 'kernel-tests "View accepted multiple full DisplayStream providers")))

(let* ([plugin
        (make-view-plugin
          'display-transform
          (lambda (view) 'ready)
          #f #f #f #f
          (lambda (value)
            (lambda (stream)
              (display-stream-insert
                stream 1 (list (make-display-text ":" 1 1 'hint 'inlay))))))]
       [configuration
        (make-configuration
          (list (make-facet-provider view-plugins-facet (list plugin))))]
       [document (make-document "ab")]
       [buffer
        (buffer-service-create! (host-state-buffers host) owner "*transform*"
                                document configuration)]
       [view (view-service-create! (host-state-views host) owner buffer configuration)]
       [leaf (make-leaf-window (view-id view) '(0 0 3 1))]
       [surface (make-surface leaf '(3 . 1))]
       [render (render-surface surface (host-state-views host))])
  (unless (and (= (length (view-projection-transforms (view-projection view))) 1)
               (string=? (frame-cell-grapheme
                           (frame-cell-at (surface-render-frame render) 0 1)) ":")
               (eq? (frame-cell-face
                     (frame-cell-at (surface-render-frame render) 0 1)) 'hint)
               (eq? (surface-hit-kind (surface-render-hit-test render 0 1)) 'virtual)
               (eq? (surface-hit-source (surface-render-hit-test render 0 1)) 'inlay))
    (error 'kernel-tests "cached View display transform differs")))

;; Occurrence updates expose the viewport-local projection to a ViewPlugin
;; without making the pure renderer mutate the live View.
(let* ([seen '()]
       [plugin (make-view-plugin
                 'occurrences (lambda (view) 'ready)
                 (lambda (value update) (set! seen (view-update-occurrences update)))
                 #f #f)]
       [configuration (make-configuration
                        (list (make-facet-provider view-plugins-facet (list plugin))))]
       [buffer (buffer-service-create! (host-state-buffers host) owner "*occurrences*"
                                       (make-document "abc") configuration)]
       [view (view-service-create! (host-state-views host) owner buffer configuration)]
       [surface (make-surface (make-leaf-window (view-id view) '(0 0 3 1)) '(3 . 1))]
       [render (render-surface surface (host-state-views host))]
       [occurrence (rendered-view-occurrence
                     (car (surface-render-rendered-views render)))])
  (view-service-publish-occurrences! (host-state-views host) (view-id view)
                                     (list occurrence))
  (let* ([next-render (render-surface surface (host-state-views host))]
         [next-occurrence (rendered-view-occurrence
                            (car (surface-render-rendered-views next-render)))])
  (unless (and (= (length seen) 1)
               (= (view-occurrence-view-id (car seen)) (view-id view))
               (pair? (view-occurrence-visible-ranges (car seen)))
               (not (view-service-publish-occurrences!
                      (host-state-views host) (view-id view) (list next-occurrence))))
    (error 'kernel-tests "View occurrence publication differs"))))

;; Structural transforms run before viewport clipping.  The initial source
;; window contains only two logical lines, but the fold placeholder leaves
;; visual room for the trailing `z`, so the projection must extend its source
;; prefix until that text becomes visible.
(let* ([plugin
        (make-view-plugin
          'large-fold
          (lambda (view) 'ready)
          #f #f #f #f
          (lambda (value)
            (lambda (stream)
              (display-stream-replace
                stream 0 16 (list (make-display-text "FF" 0 16 'fold 'fold))))))]
       [configuration
        (make-configuration
          (list (make-facet-provider view-plugins-facet (list plugin))))]
       [document (make-document "a\na\na\na\na\na\na\na\nz")]
       [buffer
        (buffer-service-create! (host-state-buffers host) owner "*large-fold*"
                                document configuration)]
       [view (view-service-create! (host-state-views host) owner buffer configuration)]
       [leaf (make-leaf-window (view-id view) '(0 0 2 2))]
       [surface (make-surface leaf '(2 . 2))]
       [render (render-surface surface (host-state-views host))]
       [frame (surface-render-frame render)])
  (unless (and (string=? (frame-cell-grapheme (frame-cell-at frame 0 0)) "F")
               (string=? (frame-cell-grapheme (frame-cell-at frame 1 0)) "z"))
    (error 'kernel-tests "document projection did not extend beyond a large fold")))

(define control-x
  (make-key-stroke 'character (char->integer #\x) 4))
(define control-s
  (make-key-stroke 'character (char->integer #\s) 4))
(define test-keymap (make-keymap 'test))
(keymap-bind! test-keymap (list control-x control-s) 'save-buffer)
(unless (equal?
          (keymap-lookup test-keymap (list control-x control-s))
          'save-buffer)
  (error 'kernel-tests "keymap lookup differs"))
(unless (eq? (car (resolve-key-sequence
                    (list (make-input-layer 'global test-keymap))
                    (list control-x control-s)))
             'command)
  (error 'kernel-tests "keymap resolver differs"))
(let* ([binding-owner (make-owner 'configured-key-binding-test)]
       [runtime (host-state-command-runtime host)]
       [register
        (lambda (name)
          (command-runtime-register-command!
            runtime
            (make-command-definition
              name (lambda (context) (command-handled)) binding-owner)))]
       [first-registration (register 'configured.default)]
       [second-registration (register 'configured.scheme)]
       [binding-source
        (make-location
          (make-resource 'file "/tmp/soda-keys.conf")
          (make-line-column-position 3 0)
          (make-line-column-position 3 12)
          #f 'after '())]
       [default-binding
        (make-key-binding-declaration
          'editing #f (list control-s) 'configured.default
          'global binding-source)]
       [scheme-binding
        (make-key-binding-declaration
          'editing 'scheme (list control-s) 'configured.scheme
          'global binding-source)]
       [layers
        (package-host-materialize-key-bindings
          (make-package-host host)
          (list default-binding scheme-binding) 'editing 'scheme)])
  (unless (and (= (length layers) 2)
               (eq? (cadr (resolve-key-sequence layers (list control-s)))
                    'configured.scheme))
    (error 'kernel-tests
           "mode-specific configured key did not precede its context default"))
  (let ([unknown
         (make-key-binding-declaration
           'editing #f (list control-x) 'configured.missing
           'global binding-source)])
    (unless
      (guard
        (condition
          [(key-binding-configuration-error? condition)
           (and (eq? (key-binding-configuration-error-reason condition)
                     'unknown-command)
                (eq? (key-binding-configuration-error-source condition)
                     binding-source))]
          [else #f])
        (package-host-materialize-key-bindings
          (make-package-host host) (list default-binding unknown)
          'unrelated #f)
        #f)
      (error 'kernel-tests
             "configured key did not diagnose an unknown command")))
  (let ([invalid
         (make-key-binding-declaration
           'editing #f (list 'not-a-key-stroke) 'configured.default
           'global binding-source)])
    (unless
      (guard
        (condition
          [(key-binding-configuration-error? condition)
           (eq? (key-binding-configuration-error-reason condition) 'invalid-key)]
          [else #f])
        (package-host-materialize-key-bindings
          (make-package-host host) (list invalid) 'editing #f)
        #f)
      (error 'kernel-tests "configured key accepted an invalid sequence")))
  (let ([conflict
         (make-key-binding-declaration
           'editing #f (list control-s) 'configured.scheme
           'global binding-source)])
    (unless
      (guard
        (condition
          [(key-binding-configuration-error? condition)
           (and (eq? (key-binding-configuration-error-reason condition) 'conflict)
                (eq? (key-binding-configuration-error-conflict condition)
                     default-binding))]
          [else #f])
        (package-host-materialize-key-bindings
          (make-package-host host) (list default-binding conflict)
          'editing #f)
        #f)
      (error 'kernel-tests
             "configured keys accepted a same-layer conflict")))
  (registration-close! second-registration)
  (registration-close! first-registration)
  (owner-close! binding-owner)
  (unless
    (guard
      (condition
        [(key-binding-configuration-error? condition)
         (eq? (key-binding-configuration-error-reason condition)
              'unknown-command)]
        [else #f])
      (package-host-materialize-key-bindings
        (make-package-host host) (list default-binding) 'editing #f)
      #f)
    (error 'kernel-tests
           "configured key retained a command after Owner cleanup")))
(let* ([first (make-keymap 'first-package)]
       [second (make-keymap 'second-package)]
       [_first-binding (keymap-bind! first (list control-s) 'first-command)]
       [_second-binding (keymap-bind! second (list control-s) 'second-command)]
       [layers
        (input-layer-compose
          (list (make-input-layer 'global first #f 'pass)
                (make-input-layer 'global second #f 'pass)))])
  (unless (and (eq? (input-layer-kind (car layers)) 'global)
               (eq? (cadr (resolve-key-sequence layers (list control-s)))
                    'first-command))
    (error 'kernel-tests "equal-priority input layers did not retain declaration order"))
  (let ([sequences (keymap-where-is (list first second) 'first-command)])
    (unless (and (= (length sequences) 1)
                 (= (length (car sequences)) 1)
                 (key-stroke=? (caar sequences) control-s)
                 (null? (keymap-where-is (list first second) 'second-command)))
      (error 'kernel-tests "where-is did not honor keymap precedence"
             sequences (keymap-where-is (list first second) 'second-command))))
  (keymap-remap! first 'first-command 'remapped-command)
  (let ([sequences (keymap-where-is (list first second) 'remapped-command)])
    (unless (and (= (length sequences) 1)
                 (key-stroke=? (caar sequences) control-s))
      (error 'kernel-tests "where-is did not honor active command remapping"))))
(let ([rejected? #f])
  (guard (condition [else (set! rejected? #t)])
    (make-input-layer 'package-name test-keymap #f 'pass))
  (unless rejected?
    (error 'kernel-tests "undeclared input layer kind was accepted")))
(let* ([transient (make-keymap 'transient-prefix)]
       [global (make-keymap 'global-command)]
       [_prefix (keymap-bind! transient (list control-x control-s) 'transient-save)]
       [_command (keymap-bind! global (list control-x) 'global-prefix-command)]
       [result
        (resolve-key-sequence
          (input-layer-compose
            (list (make-input-layer 'transient transient #f 'ignore)
                  (make-input-layer 'global global #f 'pass)))
          (list control-x))])
  (unless (eq? (car result) 'prefix)
    (error 'kernel-tests "higher-priority prefix did not shadow lower command" result)))
(let* ([accept-map (make-keymap 'accept-text)]
       [ignore-map (make-keymap 'ignore-text)]
       [event (make-text-input-event 'text (string->utf8 "x"))]
       [ignored
        (input-dispatch
          (make-input-context
            0 0
            (input-layer-compose
              (list (make-input-layer 'transient ignore-map #f 'ignore)
                    (make-input-layer 'default accept-map #f 'accept))))
          event)]
       [accepted
        (input-dispatch
          (make-input-context
            0 0
            (input-layer-compose
              (list (make-input-layer 'transient ignore-map #f 'pass)
                    (make-input-layer 'default accept-map #f 'accept))))
          event)])
  (unless (and (eq? (input-disposition-kind ignored) 'pass)
               (eq? (input-disposition-kind accepted) 'text))
    (error 'kernel-tests "text policy did not stop at the first decisive layer")))
(define input-context
  (make-input-context
    0 0 (list (make-input-layer 'global test-keymap #f 'ignore))
    (view-state-input-state (view-state view))))
(define prefix-result
  (input-dispatch
    input-context
    (make-key-event
      'character (char->integer #\x) #f #f 4 'press (make-bytevector 0))))
(unless (eq? (input-disposition-kind prefix-result) 'consume)
  (error 'kernel-tests "pending prefix was not retained"))
(unless (and (not (input-stack-pending-sequence
                    (input-context-stack input-context)))
             (= (length
                  (input-stack-pending-sequence
                    (input-disposition-input-state prefix-result)))
                1)
             (key-stroke=?
               (car
                 (input-stack-pending-sequence
                   (input-disposition-input-state prefix-result)))
               control-x))
  (error 'kernel-tests "input dispatch mutated its starting InputState"))
(define pending-result
  (input-dispatch
    (make-input-context
      0 0 (input-context-layers input-context)
      (input-disposition-input-state prefix-result))
    (make-key-event
      'character (char->integer #\s) #f #f 4 'press (make-bytevector 0))))
(unless (and (eq? (input-disposition-kind pending-result) 'command)
             (eq? (input-disposition-value pending-result) 'save-buffer))
  (error 'kernel-tests "pending command was not resolved"))

(define (input-bytes . values)
  (let ([result (make-bytevector (length values))])
    (let loop ([index 0] [remaining values])
      (if (null? remaining)
          result
          (begin
            (bytevector-u8-set! result index (car remaining))
            (loop (+ index 1) (cdr remaining)))))))

(define terminal-decoder (make-terminal-input-decoder))
(unless (null?
          (terminal-input-decoder-feed!
            terminal-decoder (string->utf8 "\x1b;[1")))
  (error 'kernel-tests "partial Kitty sequence produced an event"))
(let ([events
        (terminal-input-decoder-feed!
          terminal-decoder (string->utf8 "13;5u"))])
  (unless (and (= (length events) 1)
               (eq? (key-event-key (car events)) 'character)
               (= (key-event-codepoint (car events)) (char->integer #\q))
               (key-event-modifier? (car events) 'ctrl))
    (error 'kernel-tests "Kitty control key decoding differs" events)))
(let* ([events
         (terminal-input-decoder-feed!
           terminal-decoder
           (string->utf8 "\x1b;[97:65:97;6:2;65u"))]
       [event (car events)])
  (unless (and (= (key-event-codepoint event) 97)
               (= (key-event-shifted-codepoint event) 65)
               (= (key-event-base-layout-codepoint event) 97)
               (key-event-modifier? event 'shift)
               (key-event-modifier? event 'ctrl)
               (eq? (key-event-type event) 'repeat)
               (bytevector=? (key-event-text event) (string->utf8 "A")))
    (error 'kernel-tests "enhanced Kitty key decoding differs" event)))
(let* ([events
         (terminal-input-decoder-feed!
           terminal-decoder (string->utf8 "\x1b;[44:60:44;4u"))]
       [stroke (key-event->key-stroke (car events))])
  (unless (and (= (key-stroke-codepoint stroke) (char->integer #\<))
               (= (key-stroke-modifiers stroke) 2))
    (error 'kernel-tests "Kitty shifted punctuation normalization differs" stroke)))
(let* ([events
         (terminal-input-decoder-feed!
           terminal-decoder (string->utf8 "\x1b;[122:90:122;6u"))]
       [stroke (key-event->key-stroke (car events))])
  (unless (and (= (key-stroke-codepoint stroke) (char->integer #\z))
               (= (key-stroke-modifiers stroke) 5))
    (error 'kernel-tests "Kitty alphabetic Shift normalization differs" stroke)))
(let ([events
        (terminal-input-decoder-feed!
          terminal-decoder (string->utf8 "\x1b;[57350;5u"))])
  (unless (and (eq? (key-event-key (car events)) 'left)
               (key-event-modifier? (car events) 'ctrl)
               (not
                 (key-stroke-codepoint
                   (key-event->key-stroke (car events)))))
    (error 'kernel-tests "Kitty functional key decoding differs" events)))
(let ([events
        (terminal-input-decoder-feed!
          terminal-decoder
          (string->utf8 "\x1b;[1;1:1B\x1b;[1;1:3B"))])
  (unless (and (= (length events) 2)
               (eq? (key-event-key (car events)) 'down)
               (eq? (key-event-type (car events)) 'press)
               (eq? (key-event-key (cadr events)) 'down)
               (eq? (key-event-type (cadr events)) 'release))
    (error 'kernel-tests
           "Kitty legacy functional event types differ" events)))
(let ([events
        (terminal-input-decoder-feed!
          terminal-decoder (input-bytes 8 27 127))])
  (unless (and (= (length events) 2)
               (= (key-event-codepoint (car events)) (char->integer #\h))
               (key-event-modifier? (car events) 'ctrl)
               (eq? (key-event-key (cadr events)) 'backspace)
               (key-event-modifier? (cadr events) 'alt))
    (error 'kernel-tests "legacy control input decoding differs" events)))
(let ([lambda-bytes (string->utf8 "λ")])
  (unless (null?
            (terminal-input-decoder-feed!
              terminal-decoder
              (input-bytes (bytevector-u8-ref lambda-bytes 0))))
    (error 'kernel-tests "partial UTF-8 produced an event"))
  (let ([events
          (terminal-input-decoder-feed!
            terminal-decoder
            (input-bytes (bytevector-u8-ref lambda-bytes 1)))])
    (unless (and (= (key-event-codepoint (car events)) (char->integer #\λ))
                 (bytevector=? (key-event-text (car events)) lambda-bytes))
      (error 'kernel-tests "split UTF-8 decoding differs" events))))
(unless (null?
          (terminal-input-decoder-feed!
            terminal-decoder (string->utf8 "\x1b;[?5u")))
  (error 'kernel-tests "Kitty capability response leaked into input"))
(unless (null?
          (terminal-input-decoder-feed!
            terminal-decoder (string->utf8 "\x1b;[200~hello\x1b;[20")))
  (error 'kernel-tests "partial bracketed paste produced an event"))
(let ([events
        (terminal-input-decoder-feed!
          terminal-decoder (string->utf8 "1~"))])
  (unless (and (= (length events) 1)
               (text-input-event? (car events))
               (eq? (text-input-event-kind (car events)) 'paste)
               (bytevector=?
                 (text-input-event-text (car events))
                 (string->utf8 "hello")))
    (error 'kernel-tests "bracketed paste decoding differs" events)))
(unless (null?
          (terminal-input-decoder-feed!
            terminal-decoder (input-bytes #x1b)))
  (error 'kernel-tests "pending Escape produced an event"))
(let ([events (terminal-input-decoder-flush! terminal-decoder)])
  (unless (and (= (length events) 1)
               (eq? (key-event-key (car events)) 'escape))
    (error 'kernel-tests "Escape flush differs" events)))
(unless (null?
          (terminal-input-decoder-feed!
            terminal-decoder (string->utf8 "\x1b;[<52;10")))
  (error 'kernel-tests "partial SGR mouse report produced an event"))
(let* ([events
         (terminal-input-decoder-feed!
           terminal-decoder (string->utf8 ";20M"))]
       [event (car events)])
  (unless (and (= (length events) 1)
               (pointer-event? event)
               (= (pointer-event-row event) 19)
               (= (pointer-event-column event) 9)
               (eq? (pointer-event-button event) 'left)
               (pointer-event-modifier? event 'ctrl)
               (= (pointer-event-click-count event) 0)
               (eq? (pointer-event-phase event) 'move))
    (error 'kernel-tests "SGR mouse motion decoding differs" events)))
(let* ([press
         (car (terminal-input-decoder-feed!
                terminal-decoder (string->utf8 "\x1b;[<4;2;3M")))]
       [release
         (car (terminal-input-decoder-feed!
                terminal-decoder (string->utf8 "\x1b;[<0;2;3m")))]
       [wheel
         (car (terminal-input-decoder-feed!
                terminal-decoder (string->utf8 "\x1b;[<65;5;6M")))]
       [double-click
         (make-pointer-event 2 1 'left 0 2 'press)])
  (unless (and (eq? (pointer-event-phase press) 'press)
               (pointer-event-modifier? press 'shift)
               (= (pointer-event-click-count press) 1)
               (eq? (pointer-event-phase release) 'release)
               (= (pointer-event-click-count release) 1)
               (eq? (pointer-event-phase wheel) 'wheel)
               (eq? (pointer-event-button wheel) 'wheel-down)
               (= (pointer-event-click-count wheel) 0)
               (= (pointer-event-click-count double-click) 2)
               (input-event? double-click))
    (error 'kernel-tests "PointerEvent phase or click contract differs")))
(let ([events
       (terminal-input-decoder-feed!
         terminal-decoder (string->utf8 "\x1b;[<0;0;1M"))])
  (unless (and (= (length events) 1)
               (key-event? (car events))
               (eq? (key-event-key (car events)) 'unknown))
    (error 'kernel-tests "invalid SGR mouse report was accepted" events)))
(let* ([now 0]
       [click-decoder (make-terminal-input-decoder (lambda () now))]
       [first
        (car (terminal-input-decoder-feed!
               click-decoder (string->utf8 "\x1b;[<0;4;5M")))]
       [_release
        (terminal-input-decoder-feed!
          click-decoder (string->utf8 "\x1b;[<0;4;5m"))]
       [_second-time (set! now 200)]
       [second
        (car (terminal-input-decoder-feed!
               click-decoder (string->utf8 "\x1b;[<0;4;5M")))]
       [_expired-time (set! now 800)]
       [expired
        (car (terminal-input-decoder-feed!
               click-decoder (string->utf8 "\x1b;[<0;4;5M")))])
  (unless (and (= (pointer-event-click-count first) 1)
               (= (pointer-event-click-count second) 2)
               (= (pointer-event-click-count expired) 1))
    (error 'kernel-tests "terminal pointer click aggregation differs")))
(unless (and (string=? terminal-input-enable-sequence
                       "\x1b;[>7u\x1b;[?2004h\x1b;[?1003h\x1b;[?1006h")
             (string=? terminal-input-disable-sequence
                       "\x1b;[?1006l\x1b;[?1003l\x1b;[?2004l\x1b;[<u"))
  (error 'kernel-tests "terminal input protocol sequences differ"))

(unless (and (string=? terminal-alternate-screen-enable-sequence
                       "\x1b;[?1049h\x1b;[H")
             (string=? terminal-alternate-screen-disable-sequence
                       "\x1b;[0m\x1b;[?25h\x1b;[?1049l"))
  (error 'kernel-tests "terminal alternate screen sequences differ"))

(let* ([event
         (make-key-event
           'character (char->integer #\a) #f #f 0 'press
           (string->utf8 "a"))]
       [message (make-surface-input-message (surface-id surface) event)])
  (unless (and (= (surface-input-message-surface-id message)
                  (surface-id surface))
               (eq? (surface-input-message-event message) event))
    (error 'kernel-tests "Surface input message differs" message)))

(let ([native-runtime (native:make-runtime)]
      [native-terminal (native:make-terminal)]
      [messages '()]
      [controls '()])
  (dynamic-wind
    (lambda () #f)
    (lambda ()
      (let ([session
              (make-terminal-input-session
                native-runtime native-terminal (surface-id surface)
                (lambda (message) (set! messages (cons message messages)))
                (lambda (control) (set! controls (cons control controls))))])
        (unless (and (not (terminal-input-session-active? session))
                     (terminal-input-session-close! session)
                     (not (terminal-input-session-close! session))
                     (null? messages)
                     (null? controls))
          (error 'kernel-tests "inactive terminal session lifecycle differs"))))
    (lambda ()
      (native:terminal-close! native-terminal)
      (native:runtime-close! native-runtime))))

(let* ([text-keymap (make-keymap 'text-test)]
       [text-context
         (make-input-context
           0 0 (list (make-input-layer 'global text-keymap #f 'accept)))]
       [event (make-key-event
                'character (char->integer #\a) #f #f 0 'press
                (string->utf8 "a"))]
       [result (input-dispatch text-context event)])
  (unless (and (eq? (input-disposition-kind result) 'text)
               (bytevector=?
                 (input-disposition-value result) (string->utf8 "a")))
  (error 'kernel-tests "unbound committed text was not dispatched" result)))

(let* ([directory
         (string-append
           "/tmp/soda-vfs-kernel-" (number->string (get-process-id)))]
       [path (vfs-path-join directory "content.bin")]
       [destination (vfs-path-join directory "destination.bin")]
       [lock (vfs-path-join directory "content.bin.soda-lock")]
       [token (string->utf8 "soda-lock-token")])
  (dynamic-wind
    (lambda () (mkdir directory))
    (lambda ()
      (unless (= (vfs-write-file path (string->utf8 "first value")) 11)
        (error 'kernel-tests "synchronous VFS write size differs"))
      (unless (and (vfs-create-exclusive-file! lock token)
                   (not (vfs-create-exclusive-file! lock token))
                   (bytevector=? (vfs-read-file lock) token)
                   (not (vfs-delete-file-if-matches! lock (string->utf8 "other")))
                   (vfs-file-exists? lock)
                   (vfs-delete-file-if-matches! lock token)
                   (not (vfs-file-exists? lock)))
        (error 'kernel-tests "exclusive VFS file lifecycle differs"))
      (vfs-write-file path (string->utf8 "next"))
      (unless (bytevector=? (vfs-read-file path) (string->utf8 "next"))
        (error 'kernel-tests "synchronous VFS read/write differs"))
      (let ([entries (vfs-list-directory directory)]
            [stat (vfs-stat-path path)])
        (unless (and (= (length entries) 1)
                     (string=? (vfs-entry-name (car entries)) "content.bin")
                     (eq? (vfs-entry-kind (car entries)) 'file)
                     (eq? (vfs-stat-kind stat) 'file)
                     (= (vfs-stat-size stat) 4)
                     (vfs-stat-same-version? stat (vfs-stat-path path)))
          (error 'kernel-tests "synchronous VFS metadata differs" entries stat)))
      (let ([selected (vfs-stat-path path #f)])
        (vfs-write-file destination (string->utf8 "occupied"))
        (guard (condition [else #t])
          (vfs-rename-path-if-matches! path destination selected)
          (error 'kernel-tests "conditional rename replaced a destination"))
        (unless (and (vfs-file-exists? path)
                     (bytevector=? (vfs-read-file destination)
                                   (string->utf8 "occupied")))
          (error 'kernel-tests "failed conditional rename did not restore source"))
        (delete-file destination)
        (vfs-rename-path-if-matches! path destination selected)
        (unless (and (not (vfs-file-exists? path))
                     (vfs-file-exists? destination))
          (error 'kernel-tests "conditional rename did not commit"))
        (let ([stale (vfs-stat-path destination #f)])
          (delete-file destination)
          (vfs-write-file destination (string->utf8 "replacement"))
          (guard (condition [else #t])
            (vfs-delete-path-if-matches! destination stale)
            (error 'kernel-tests "conditional delete removed a replacement"))
          (unless (bytevector=? (vfs-read-file destination)
                                (string->utf8 "replacement"))
            (error 'kernel-tests "conditional delete failed to restore replacement")))))
    (lambda ()
      (when (file-exists? path) (delete-file path))
      (when (file-exists? destination) (delete-file destination))
      (when (file-exists? lock) (delete-file lock))
      (delete-directory directory #t))))

;; FileFormat keeps the document representation UTF-8/LF while preserving
;; external newline spelling, BOM, and final-newline state at the file edge.
(let ([source
       (u8-list->bytevector
         '(#xef #xbb #xbf #x61 #x0d #x0a #x62 #x0a #x63 #x0d #x0a))])
  (call-with-values
    (lambda () (decode-file-contents source))
    (lambda (contents format)
      (unless (and (bytevector=? contents (string->utf8 "a\nb\nc\n"))
                   (eq? (file-format-encoding format) 'utf-8)
                   (eq? (file-format-newline format) 'mixed)
                   (file-format-final-newline? format)
                   (file-format-bom? format))
        (error 'kernel-tests "file format decoding differs"))
      (call-with-values
        (lambda ()
          (encode-file-contents contents format 'preserve 'preserve 'preserve))
        (lambda (encoded preserved)
          (unless (and (bytevector=? encoded source)
                       (eq? (file-format-newline preserved) 'mixed)
                       (file-format-bom? preserved))
            (error 'kernel-tests "mixed newline or BOM round trip differs"))))
      (call-with-values
        (lambda () (encode-file-contents contents format 'lf 'no 'no))
        (lambda (encoded normalized)
          (unless (and (bytevector=? encoded (string->utf8 "a\nb\nc"))
                       (eq? (file-format-newline normalized) 'lf)
                       (not (file-format-final-newline? normalized))
                       (not (file-format-bom? normalized)))
            (error 'kernel-tests "file format policy override differs"))))))
  (unless
    (guard (condition [else #t])
      (decode-file-contents (u8-list->bytevector '(#xc0 #xaf)))
      #f)
    (error 'kernel-tests "invalid UTF-8 was silently decoded")))

;; Recovery snapshots are written from a queued command effect, coalesce to
;; the latest published Buffer generation, survive service shutdown, and are
;; restored into an unbound Buffer without changing the original resource.
(let* ([directory
         (string-append
           "/tmp/soda-recovery-test-" (number->string (get-process-id)))]
       [resource
         (make-resource
           'file
           (string-append directory "/original.txt"))]
       [state (make-host-state)]
       [host-capability (make-package-host state)]
       [owner (make-owner 'recovery-writer-test)]
       [history
        (make-history!
          (host-state-command-runtime state) (host-state-dispatch state) owner)]
       [buffer
        (buffer-service-create!
          (host-state-buffers state) owner "recovery-source"
          (make-document "base") (make-configuration '()))]
       [service
        (make-recovery-service!
          host-capability owner history
          (lambda (id)
            (and (= id (buffer-id buffer)) resource))
          directory)])
  (define (replace-recovery-buffer! text)
    (let* ([state-before (buffer-state buffer)]
           [length
            (snapshot-byte-size (buffer-state-document state-before))])
      (dispatcher-dispatch!
        (host-state-dispatch state)
        (make-transaction-spec
          (buffer-id buffer) (buffer-state-generation state-before)
          (make-change-set
            length (list (make-text-change 0 length (string->utf8 text))))))))
  (dynamic-wind
    (lambda ()
      (when (file-exists? directory) (delete-directory directory #t)))
    (lambda ()
      (history-mark-saved! history (buffer-id buffer))
      (replace-recovery-buffer! "first")
      (replace-recovery-buffer! "latest")
      (host-state-run! state)
      (unless (and (= (length (vfs-list-directory directory)) 1)
                   (zero?
                     (bitwise-and
                       (get-mode
                         (vfs-path-join
                           directory
                           (vfs-entry-name (car (vfs-list-directory directory)))))
                       #o077)))
        (error 'kernel-tests "recovery snapshot was not coalesced"))
      (recovery-service-clear-buffer! service (buffer-id buffer))
      (host-state-run! state)
      (unless (null? (vfs-list-directory directory))
        (error 'kernel-tests "successful recovery cleanup retained an artifact"))
      (replace-recovery-buffer! "crash contents")
      (host-state-run! state)
      (unless (= (length (vfs-list-directory directory)) 1)
        (error 'kernel-tests "modified Buffer did not produce a recovery artifact"))
      (owner-close! owner)
      (host-state-close! state)
      (unless (= (length (vfs-list-directory directory)) 1)
        (error 'kernel-tests "service shutdown removed crash recovery state"))
      ;; Two process artifacts may describe the same original resource.  The
      ;; selector identifies the artifact file, not that shared resource.
      (let* ([first-entry (car (vfs-list-directory directory))]
             [first-path
              (vfs-path-join directory (vfs-entry-name first-entry))]
             [second-path (vfs-path-join directory "duplicate.soda-recovery")])
        (vfs-write-file second-path (vfs-read-file first-path)))

      (let* ([next-state (make-host-state)]
             [next-host (make-package-host next-state)]
             [next-owner (make-owner 'recovery-reader-test)]
             [next-history
              (make-history!
                (host-state-command-runtime next-state)
                (host-state-dispatch next-state) next-owner)]
             [base
              (buffer-service-create!
                (host-state-buffers next-state) next-owner "recovery-target"
                (make-document "") (make-configuration '()))]
             [base-view
              (view-service-create!
                (host-state-views next-state) next-owner base
                (make-configuration '()))]
             [surface
              (make-surface
                'recovery-test '()
                (make-leaf-window (view-id base-view) '(0 0 40 8)) '(40 . 8))]
             [_surface
              (surface-service-register! (host-state-surfaces next-state) surface)]
             [reader
              (make-recovery-service!
                next-host next-owner next-history (lambda (buffer-id) #f) directory)]
             [interactions
              (make-interaction-service!
                (host-state-command-runtime next-state) next-owner)]
             [context
              (make-command-context
                #f (surface-id surface) (window-id (surface-active-window surface))
                (view-id base-view) (buffer-id base)
                (buffer-state base) (view-state base-view)
                #f '() #f #f 'recovery-test)])
        (unless (and (= (length (recovery-service-pending-artifacts reader)) 2)
                     (not (string=?
                            (recovery-artifact-path
                              (car (recovery-service-pending-artifacts reader)))
                            (recovery-artifact-path
                              (cadr (recovery-service-pending-artifacts reader)))))
                     (string=?
                       (utf8->string
                         (recovery-artifact-contents
                           (car (recovery-service-pending-artifacts reader))))
                       "crash contents"))
          (error 'kernel-tests "recovery discovery differs"))
        (unless (not (surface-feedback surface))
          (error 'kernel-tests
                 "recovery discovery occupied the echo area before user action"))
        (command-runtime-start-interactive!
          (host-state-command-runtime next-state) 'recovery.restore context)
        (unless (eq? (interaction-request-kind
                       (interaction-session-request
                         (interaction-service-current interactions)))
                     'file-selection)
          (error 'kernel-tests "multiple recovery artifacts did not request a target"))
        (interaction-service-submit!
          interactions
          (recovery-artifact-path
            (cadr (recovery-service-pending-artifacts reader))))
        (host-state-run! next-state)
        (unless (eq? (interaction-request-kind
                       (interaction-session-request
                         (interaction-service-current interactions)))
                     'recovery-decision)
          (error 'kernel-tests "recovery command did not request a decision"))
        (interaction-service-submit! interactions 'recover)
        (host-state-run! next-state)
        (let* ([active
                (surface-active-context surface (host-state-views next-state))]
               [restored-view
                (view-service-ref
                  (host-state-views next-state) (active-context-view-id active))]
               [restored (view-buffer restored-view)])
          (unless (and (string=? (buffer-string restored) "crash contents")
                       (not (= (buffer-id restored) (buffer-id base)))
                       (= (length (vfs-list-directory directory)) 1))
            (error 'kernel-tests
                   "recovery restore changed the resource or wrong artifact")))
        (unless (and (not (interaction-service-current interactions))
                     (= (length (recovery-service-pending-artifacts reader)) 1))
          (error 'kernel-tests
                 "one recovery command consumed more than its selected artifact"))
        (command-runtime-start-interactive!
          (host-state-command-runtime next-state) 'recovery.restore context)
        (unless (eq? (interaction-request-kind
                       (interaction-session-request
                         (interaction-service-current interactions)))
                     'recovery-decision)
          (error 'kernel-tests
                 "explicit recovery of the remaining artifact did not ask"))
        (interaction-service-submit! interactions 'discard)
        (host-state-run! next-state)
        (unless (null? (vfs-list-directory directory))
          (error 'kernel-tests "recovery discard retained the remaining artifact"))
        (owner-close! next-owner)
        (host-state-close! next-state)))
    (lambda ()
      (when (owner-active? owner) (owner-close! owner))
      (unless (host-state-closed? state) (host-state-close! state))
      (when (file-exists? directory) (delete-directory directory #t)))))

;; FileWatchService shares a parent-directory source while preserving Buffer
;; identity, distinguishes acknowledged local writes, and retires bindings as
;; their Buffer or Owner lifecycle ends.
(let* ([directory
         (string-append
           "/tmp/soda-file-watch-" (number->string (get-process-id)))]
       [first (vfs-path-join directory "first.txt")]
       [second (vfs-path-join directory "second.txt")]
       [owner (make-owner 'file-watch-test)]
       [runtime (native:make-runtime)]
       [service (make-file-watch-service owner)]
       [observed '()])
  (define (next-state-event predicate)
    (let loop ()
      (let scan ([events (native:runtime-poll! runtime)])
        (cond
          [(null? events) (loop)]
          [else
           (let ([handled
                  (file-watch-service-handle-runtime-event!
                    service (car events))])
             (let ([match (and handled (find predicate handled))])
               (or match (scan (cdr events)))))]))))
  (dynamic-wind
    (lambda ()
      (mkdir directory)
      (vfs-write-file first (string->utf8 "one"))
      (vfs-write-file second (string->utf8 "two")))
    (lambda ()
      (file-watch-service-add-listener!
        service owner (lambda (event) (set! observed (cons event observed))))
      (file-watch-service-register! service 101 first (vfs-stat-path first))
      (file-watch-service-register! service 102 second (vfs-stat-path second))
      (file-watch-service-attach-runtime! service runtime)
      (unless (and (= (file-watch-service-binding-count service) 2)
                   (= (file-watch-service-directory-count service) 1))
        (error 'kernel-tests "FileWatchService did not share its directory watch"))
      (vfs-write-file first (string->utf8 "external-change"))
      (let ([event
             (next-state-event
               (lambda (candidate)
                 (and (= (file-state-event-buffer-id candidate) 101)
                      (memq (file-state-event-kind candidate)
                            '(modified replaced)))))])
        (unless (and (eq? (file-state-event-origin event) 'external)
                     (exists
                       (lambda (cause) (memq cause '(rename change)))
                       (file-state-event-causes event)))
          (error 'kernel-tests "external file modification was not normalized" event)))
      (vfs-write-file second (string->utf8 "local-write"))
      (file-watch-service-update!
        service 102 second (vfs-stat-path second) #t)
      (let ([event
             (next-state-event
               (lambda (candidate)
                 (and (= (file-state-event-buffer-id candidate) 102)
                      (eq? (file-state-event-origin candidate) 'local))))])
        (unless (memq (file-state-event-kind event) '(metadata replaced))
          (error 'kernel-tests "local file notification was not acknowledged" event)))
      (delete-file first)
      (let ([event
             (next-state-event
               (lambda (candidate)
                 (and (= (file-state-event-buffer-id candidate) 101)
                      (eq? (file-state-event-kind candidate) 'deleted))))])
        (unless (eq? (file-state-event-origin event) 'external)
          (error 'kernel-tests "file deletion origin differs" event)))
      (file-watch-service-unregister! service 101)
      (file-watch-service-unregister! service 102)
      (unless (and (zero? (file-watch-service-binding-count service))
                   (zero? (file-watch-service-directory-count service)))
        (error 'kernel-tests "FileWatchService retained an empty directory watch")))
    (lambda ()
      (when (owner-active? owner) (owner-close! owner))
      (native:runtime-close! runtime)
      (when (file-exists? first) (delete-file first))
      (when (file-exists? second) (delete-file second))
      (delete-directory directory #t))))

(let* ([secondary
        (view-service-create!
          (host-state-views host) owner buffer configuration)]
       [old-buffer-generation (buffer-state-generation (buffer-state buffer))]
       [old-primary-generation (view-state-generation (view-state view))]
       [old-state (view-state secondary)]
       [new-input-state (input-disposition-input-state prefix-result)]
       [update
        (dispatcher-dispatch-view!
          (host-state-dispatch host)
          (make-view-transaction-spec
            (view-id secondary) (view-state-generation old-state)
            #f (make-viewport 3 9) new-input-state '()
            (list (make-annotation 'origin 'input))
            (make-scroll-request 'reveal-point #f #f (view-id secondary))))]
       [new-state (view-state secondary)])
  (unless (and (editor-update? update)
               (eq? (editor-update-old-buffer-state update)
                    (editor-update-new-buffer-state update))
               (= (buffer-state-generation (buffer-state buffer))
                  old-buffer-generation)
               (= (view-state-generation (view-state view))
                  old-primary-generation)
               (= (view-state-generation new-state)
                  (+ 1 (view-state-generation old-state)))
               (= (viewport-first-line (view-state-viewport new-state)) 3)
               (= (viewport-visual-row (view-state-viewport new-state)) 9)
               (eq? (view-state-input-state new-state) new-input-state)
               (not (input-stack-pending-sequence
                      (view-state-input-state old-state)))
               (equal? (editor-update-damage update) '(viewport input)))
    (error 'kernel-tests "ViewTransaction did not publish isolated state"))
  (unless
      (guard (condition [else #t])
        (dispatcher-dispatch-view!
          (host-state-dispatch host)
          (make-view-transaction-spec
            (view-id secondary) (view-state-generation old-state)))
        #f)
    (error 'kernel-tests "stale ViewTransaction was accepted")))

(define runtime (make-runtime))
(define request (runtime-enqueue-request! runtime owner 'buffer 0 'payload))
(unless (and (runtime-request? request) (= (runtime-request-id request) 1)
             (runtime-pending? runtime))
  (error 'kernel-tests "runtime request identity differs"))
(define drained '())
(runtime-drain! runtime (lambda (message) (set! drained (cons message drained))))
(unless (and (= (length drained) 1)
             (eq? (runtime-request-payload (car drained)) 'payload)
             (not (runtime-pending? runtime)))
  (error 'kernel-tests "runtime queue order differs"))

;; Dispatch is the only host publication path.  It applies the kernel change
;; set to the native document, maps the view selection, and advances both
;; immutable state generations atomically.
(define dispatch-spec
  (make-transaction-spec
    (buffer-id buffer) (view-id view) (buffer-state-generation (buffer-state buffer))
    (make-change-set
      (snapshot-byte-size (buffer-state-document (buffer-state buffer)))
      (list (make-text-change 5 5 " world")))
    #f '() '()))
(define publication-consistent? #f)
(dispatcher-set-listener!
  (host-state-dispatch host)
  (lambda (update)
    (set!
      publication-consistent?
      (= (buffer-state-generation (editor-update-new-buffer-state update))
         (view-state-buffer-generation
           (view-state-update-new-state
             (car (editor-update-views update))))))))
(define update
  (dispatcher-dispatch!
    (host-state-dispatch host)
    dispatch-spec))
(unless (and (editor-update? update)
             (= (buffer-state-generation (buffer-state buffer)) 1)
             (= (view-state-generation (view-state view)) 1)
             (= (view-state-buffer-generation (view-state view)) 1)
             publication-consistent?
             (string=?
               (snapshot-string (buffer-state-document (buffer-state buffer)))
               "hello world"))
  (error 'kernel-tests "dispatcher did not publish an atomic update"))
(let ([view-update
       (find (lambda (candidate)
               (= (view-state-update-view-id candidate) (view-id view)))
             (editor-update-views update))])
  (unless (and view-update
               (= (view-state-generation
                    (view-state-update-old-state view-update))
                  0)
               (= (view-state-generation
                    (view-state-update-new-state view-update))
                  1))
    (error 'kernel-tests "EditorUpdate omitted old/new ViewState")))

;; A batch dispatch resolves simultaneous specs against one starting snapshot
;; and publishes one buffer generation/update.
(define batch-generation (buffer-state-generation (buffer-state buffer)))
(define batch-length (snapshot-byte-size (buffer-state-document (buffer-state buffer))))
(define batch-update
  (dispatcher-dispatch-specs!
    (host-state-dispatch host)
    (list
      (make-transaction-spec
        (buffer-id buffer) (view-id view) batch-generation
        (make-change-set
          batch-length
          (list (make-text-change 0 0 "A")))
        #f '() '())
      (make-transaction-spec
        (buffer-id buffer) #f batch-generation
        (make-change-set
          batch-length
          (list (make-text-change batch-length batch-length "B")))
        #f '() '()))))
(unless (and (editor-update? batch-update)
             (= (buffer-state-generation (buffer-state buffer)) 2)
             (= (change-set-old-length (editor-update-changes batch-update))
                batch-length)
             (= (change-set-new-length (editor-update-changes batch-update))
                (+ batch-length 2))
             (string=?
               (snapshot-string (buffer-state-document (buffer-state buffer)))
               "Ahello worldB"))
  (error 'kernel-tests "dispatcher did not resolve a batch update"))

(let* ([reject-filter
        (lambda (state value)
          (unless (and (buffer-state? state) (resolved-transaction? value))
            (error 'kernel-tests "transaction filter did not receive BufferState and resolved state"))
          #f)]
       [reject-configuration
        (make-configuration
          (list
            (make-facet-provider
              transaction-filters-facet
              (list reject-filter))))]
       [reject-document (make-document "hello")]
       [reject-buffer
        (buffer-service-create!
          (host-state-buffers host) owner "*reject*" reject-document
          reject-configuration)]
       [reject-view
        (view-service-create!
          (host-state-views host) owner reject-buffer reject-configuration)]
       [rejected
        (dispatcher-dispatch!
          (host-state-dispatch host)
          (make-transaction-spec
            (buffer-id reject-buffer) (view-id reject-view) 0
            (make-change-set 5 (list (make-text-change 5 5 "!")))
            #f '() '()))]
       [bypass-rejected
        (dispatcher-dispatch!
          (host-state-dispatch host)
          (make-transaction-spec
            (buffer-id reject-buffer) (view-id reject-view) 0
            (make-change-set 5 (list (make-text-change 5 5 "!")))
            #f '() '() #f #t))])
  (unless (and (not rejected)
               (not bypass-rejected)
               (= (buffer-state-generation (buffer-state reject-buffer)) 0)
               (string=? (snapshot-string
                           (buffer-state-document (buffer-state reject-buffer)))
                         "hello"))
    (error 'kernel-tests "transaction filter policy can be bypassed")))

(let* ([target-document (make-document "other")]
       [target-buffer
        (buffer-service-create!
          (host-state-buffers host) owner "*target*" target-document
          (make-configuration '()))]
       [retarget-filter
        (lambda (state resolved)
          (make-resolved-transaction
            (buffer-id target-buffer)
            (resolved-transaction-origin-view-id resolved)
            (resolved-transaction-start-generation resolved)
            (resolved-transaction-changes resolved)
            (resolved-transaction-selection resolved)
            (resolved-transaction-effects resolved)
            (resolved-transaction-annotations resolved)
            (resolved-transaction-scroll-request resolved)))]
       [source-configuration
        (make-configuration
          (list
            (make-facet-provider
              transaction-filters-facet (list retarget-filter))))]
       [source-document (make-document "hello")]
       [source-buffer
        (buffer-service-create!
          (host-state-buffers host) owner "*source*" source-document
          source-configuration)]
       [source-view
        (view-service-create!
          (host-state-views host) owner source-buffer source-configuration)]
       [rejected?
        (guard (condition [else #t])
          (dispatcher-dispatch!
            (host-state-dispatch host)
            (make-transaction-spec
              (buffer-id source-buffer) (view-id source-view) 0
              (make-change-set 5 (list (make-text-change 5 5 "!")))
              #f '() '()))
          #f)])
  (unless (and rejected?
               (string=?
                 (snapshot-string
                   (buffer-state-document (buffer-state source-buffer)))
                 "hello")
               (string=?
                 (snapshot-string
                   (buffer-state-document (buffer-state target-buffer)))
                 "other"))
    (error 'kernel-tests "transaction filter retargeted its baseline")))

(define stale-transaction-rejected?
  (guard (condition [else #t])
    (dispatcher-dispatch!
      (host-state-dispatch host)
      (make-transaction-spec
        (buffer-id buffer) (view-id view)
        (- (buffer-state-generation (buffer-state buffer)) 1)
        (make-change-set
          (snapshot-byte-size (buffer-state-document (buffer-state buffer)))
          (list (make-text-change
                  (snapshot-byte-size (buffer-state-document (buffer-state buffer)))
                  (snapshot-byte-size (buffer-state-document (buffer-state buffer)))
                  "!")))
        #f '() '()))
    #f))
(unless stale-transaction-rejected?
  (error 'kernel-tests "stale transaction was not rejected"))

;; A View StateField failure occurs after the native transaction and snapshot
;; have been prepared. The dispatcher must abort that native transaction so a
;; later edit can still commit.
(let* ([fail-next? #t]
       [failing-field
        (make-state-field
          'failing-view 'view
          (lambda (state) 'ready)
          (lambda (value transaction)
            (if fail-next?
                (begin
                  (set! fail-next? #f)
                  (error 'kernel-tests "intentional view update failure"))
                value)))]
       [plain-configuration (make-configuration '())]
       [failing-configuration (make-configuration (list failing-field))]
       [failure-document (make-document "hello")]
       [failure-buffer
        (buffer-service-create!
          (host-state-buffers host) owner "*failure*" failure-document
          plain-configuration)]
       [origin-view
        (view-service-create!
          (host-state-views host) owner failure-buffer plain-configuration)]
       [failing-view
        (view-service-create!
          (host-state-views host) owner failure-buffer failing-configuration)]
       [failure-spec
        (make-transaction-spec
          (buffer-id failure-buffer) (view-id origin-view) 0
          (make-change-set 5 (list (make-text-change 5 5 "!")))
          #f '() '())]
       [failed?
        (guard (condition [else #t])
          (dispatcher-dispatch! (host-state-dispatch host) failure-spec)
          #f)]
       [recovered
        (dispatcher-dispatch! (host-state-dispatch host) failure-spec)])
  (unless (and failed?
               recovered
               (= (buffer-state-generation (buffer-state failure-buffer)) 1)
               (string=?
                 (snapshot-string
                   (buffer-state-document (buffer-state failure-buffer)))
                 "hello!"))
    (error 'kernel-tests "dispatcher did not recover from ViewState failure")))

(let* ([routing-field
        (make-state-field
          'view-routing 'view
          (lambda (state) 'initial)
          (lambda (value update)
            (unless (view-update-context? update)
              (error 'kernel-tests "View StateField did not receive its context"))
            (list
              (view-update-context-view-id update)
              (view-update-context-origin? update)
              (map state-effect-type (view-update-context-effects update)))))]
       [routing-configuration (make-configuration (list routing-field))]
       [routing-document (make-document "x")]
       [routing-buffer
        (buffer-service-create!
          (host-state-buffers host) owner "*routing*" routing-document
          routing-configuration)]
       [origin-view
        (view-service-create!
          (host-state-views host) owner routing-buffer routing-configuration)]
       [shared-view
        (view-service-create!
          (host-state-views host) owner routing-buffer routing-configuration)]
       [origin-effect
        (make-targeted-state-effect 'origin-view 'origin-effect #t)]
       [shared-effect
        (make-targeted-state-effect 'all-views 'shared-effect #t)])
  (dispatcher-dispatch!
    (host-state-dispatch host)
    (make-transaction-spec
      (buffer-id routing-buffer) (view-id origin-view) 0
      (make-change-set 1 '()) #f
      (list origin-effect shared-effect) '()))
  (let ([origin-value
         (view-state-field (view-state origin-view) routing-field)]
        [shared-value
         (view-state-field (view-state shared-view) routing-field)])
    (unless (and (equal? origin-value
                         (list (view-id origin-view) #t
                               '(origin-effect shared-effect)))
                 (equal? shared-value
                         (list (view-id shared-view) #f '(shared-effect))))
      (error 'kernel-tests "View StateEffect routing differs"))))

(let* ([stream
         (make-display-stream
           (list (make-display-text "a" 0 1 'default 'text)
                 (make-display-break 'line-end)))]
       [extended
         (display-stream-append
           stream
           (list (make-display-widget 3 1 1 'hint 'inlay)))]
       [entries
         (list
           (make-display-map-entry 0 1 0 1 'text 'a)
           (make-display-map-entry 1 3 1 2 'text 'wide)
           (make-display-map-entry 3 3 2 5 'virtual 'hint))]
       [map (make-display-map entries)])
  (unless (and (= (length (display-stream-fragments stream)) 2)
               (= (length (display-stream-fragments extended)) 3)
               (= (display-map-document->cell map 0) 0)
               (= (display-map-document->cell map 1) 1)
               (= (display-map-document->cell map 3) 5)
               (= (display-map-document->cell map 3 'before) 2)
               (= (display-map-cell->document map 0) 0)
               (= (display-map-cell->document map 1) 1)
               (= (display-map-cell->document map 3) 3)
               (= (length (display-map-document-range map 1 3)) 1)
               (= (length (display-map-cell-range map 2 5)) 1))
    (error 'kernel-tests "DisplayStream or DisplayMap differs")))

(let* ([map
         (make-display-map
           (list (make-display-map-entry 0 1 0 1 'text 'left)
                 (make-display-map-entry 1 1 1 4 'virtual 'hint)
                 (make-display-map-entry 1 2 4 5 'text 'right)))])
  (unless (and (= (display-map-document->cell map 1 'before) 1)
               (= (display-map-document->cell map 1 'after) 4)
               (= (display-map-cell->document map 2) 1)
               (= (length (display-map-document-range map 1 2)) 2))
    (error 'kernel-tests "DisplayMap affinity differs")))

(let* ([map
         (make-display-map
           (list (make-display-map-entry 0 1 0 2 'text 'outside)
                 (make-display-map-entry 1 2 2 4 'text 'left)
                 (make-display-map-entry 2 3 4 4 'line-break 'break)
                 (make-display-map-entry 3 4 4 6 'text 'right)
                 (make-display-map-entry 4 5 6 8 'text 'outside)))]
       [slice (display-map-cell-slice map 2 6)]
       [entries (display-map-entries slice)])
  (unless (and (= (length entries) 3)
               (= (display-map-entry-cell-from (car entries)) 0)
               (= (display-map-entry-cell-to (car entries)) 2)
               (eq? (display-map-cell-boundary-entry slice 2) (cadr entries))
               (= (display-map-entry-cell-from (caddr entries)) 2)
               (= (display-map-entry-cell-to (caddr entries)) 4))
    (error 'kernel-tests "DisplayMap cell slicing differs")))

(let* ([base (make-frame 5 2)]
       [emphasis (make-frame-cell "x" 1 #f 'emphasis 'source)]
       [changed
         (frame-with-cells
           base
           (list (list 0 1 emphasis) (list 0 2 emphasis) (list 1 4 emphasis)))]
       [spans (frame-diff base changed)]
       [initial (frame-diff #f base)])
  (unless (and (= (length spans) 2)
               (= (frame-row-span-row (car spans)) 0)
               (= (frame-row-span-from (car spans)) 1)
               (= (frame-row-span-to (car spans)) 3)
               (= (frame-row-span-row (cadr spans)) 1)
               (= (frame-row-span-from (cadr spans)) 4)
               (= (frame-row-span-to (cadr spans)) 5)
               (= (length initial) 2)
               (frame-cell=? emphasis
                             (make-frame-cell "x" 1 #f 'emphasis 'source))
               (eq? (frame-cell-at base 0 0) default-frame-cell))
    (error 'kernel-tests "Frame diff differs" spans)))

(let* ([old (frame-with-cell (make-frame 1 1) 0 0
                             (make-frame-cell "x" 1 #f 'text 'first))]
       [new (frame-with-cell (make-frame 1 1) 0 0
                             (make-frame-cell "x" 1 #f 'text 'second))])
  (unless (and (not (frame-cell=? (frame-cell-at old 0 0)
                                  (frame-cell-at new 0 0)))
               (frame-cell-paint=? (frame-cell-at old 0 0)
                                    (frame-cell-at new 0 0))
               (null? (frame-diff old new)))
    (error 'kernel-tests "Frame diff repainted source-only change")))

(define (contains-string? text needle)
  (let ([size (string-length needle)])
    (let loop ([position 0])
      (and (<= (+ position size) (string-length text))
           (or (string=? (substring text position (+ position size)) needle)
               (loop (+ position 1)))))))

(unless (string=? (face-style->sgr (theme-face-style default-theme 'selection)) "0;7")
  (error 'kernel-tests "Default terminal theme differs"))

(let* ([base (make-frame 2 1)]
       [next (frame-with-cell base 0 0
                              (make-frame-cell "x" 1 #f 'selection #f))]
       [ansi (frame-diff->ansi base next default-theme 2 3)])
  (unless (and (contains-string? ansi "[1;1H")
               (contains-string? ansi "[0;7m")
               (contains-string? ansi "[3;4H")
               (contains-string? ansi "[?25h")
               (contains-string? ansi "x"))
    (error 'kernel-tests "ANSI presenter encoding differs" ansi)))

(let* ([frame (make-frame 1 1)]
       [ansi (frame-diff->ansi #f frame default-theme #f #f)])
  (unless (and (contains-string? ansi "[?25l")
               (not (contains-string? ansi "[?25h")))
    (error 'kernel-tests "ANSI presenter did not hide an absent cursor" ansi)))

(let* ([presenter (make-frame-presenter)]
       [frame (frame-with-cell (make-frame 2 1) 0 0
                               (make-frame-cell "x" 1 #f 'text #f))]
       [writes '()]
       [writer
         (lambda (bytes offset)
           (set! writes (cons (cons (bytevector-length bytes) offset) writes))
           (if (zero? offset) 1 (- (bytevector-length bytes) offset)))])
  (frame-presenter-present! presenter frame)
  (unless (and (eq? (frame-presenter-drain! presenter writer) 'partial)
               (frame-presenter-pending? presenter)
               (eq? (frame-presenter-drain! presenter writer) 'committed)
               (eq? (frame-presenter-committed-frame presenter) frame)
               (= (length writes) 2))
    (error 'kernel-tests "Frame presenter transaction differs" writes)))

;; A newer desired Frame may arrive after some bytes of an older transaction
;; have reached the terminal.  The old transaction must finish first, then a
;; subsequent drain emits the newest state from the committed Frame.
(let* ([presenter (make-frame-presenter)]
       [first (frame-with-cell (make-frame 1 1) 0 0
                               (make-frame-cell "a" 1 #f 'text #f))]
       [second (frame-with-cell (make-frame 1 1) 0 0
                                (make-frame-cell "b" 1 #f 'text #f))]
       [writes 0]
       [writer
        (lambda (bytes offset)
          (set! writes (+ writes 1))
          (if (= writes 1) 1 (- (bytevector-length bytes) offset)))])
  (frame-presenter-present! presenter first)
  (unless (eq? (frame-presenter-drain! presenter writer) 'partial)
    (error 'kernel-tests "Frame presenter did not begin partial transaction"))
  (frame-presenter-present! presenter second)
  (unless (and (eq? (frame-presenter-drain! presenter writer) 'committed)
               (frame-presenter-dirty? presenter)
               (eq? (frame-presenter-drain! presenter writer) 'committed)
               (eq? (frame-presenter-committed-frame presenter) second)
               (not (frame-presenter-dirty? presenter)))
    (error 'kernel-tests "Frame presenter did not retire superseded frame")))

;; Themes resolve semantic faces only at the terminal boundary.  Reusing an
;; unchanged Frame with a different Theme still needs a full presentation.
(let* ([presenter (make-frame-presenter)]
       [frame (frame-with-cell (make-frame 1 1) 0 0
                               (make-frame-cell "x" 1 #f 'text #f))]
       [theme (make-theme (list (cons 'text (make-face-style 6 #f '())))
                          (make-face-style #f #f '()))]
       [writes '()]
       [writer (lambda (bytes offset)
                 (set! writes (cons (utf8->string bytes) writes))
                 (- (bytevector-length bytes) offset))])
  (frame-presenter-present! presenter frame)
  (frame-presenter-drain! presenter writer)
  (set! writes '())
  (frame-presenter-present! presenter frame theme #f #f)
  (unless (and (eq? (frame-presenter-drain! presenter writer) 'committed)
               (= (length writes) 1)
               (contains-string? (car writes) "[0;38;5;6m"))
    (error 'kernel-tests "Frame presenter theme invalidation differs" writes)))

;; Cursor-only state changes encode terminal cursor state without repainting
;; immutable Frame cells.
(let* ([presenter (make-frame-presenter)]
       [frame (frame-with-cell (make-frame 1 1) 0 0
                               (make-frame-cell "x" 1 #f 'text #f))]
       [writes '()]
       [writer (lambda (bytes offset)
                 (set! writes (cons (utf8->string bytes) writes))
                 (- (bytevector-length bytes) offset))])
  (frame-presenter-present! presenter frame)
  (frame-presenter-drain! presenter writer)
  (set! writes '())
  (frame-presenter-present! presenter frame default-theme 0 0)
  (unless (and (eq? (frame-presenter-drain! presenter writer) 'committed)
               (= (length writes) 1)
               (contains-string? (car writes) "[1;1H")
               (contains-string? (car writes) "[?25h")
               (not (contains-string? (car writes) "x")))
    (error 'kernel-tests "cursor-only presentation repainted Frame cells" writes)))

(let ([wide (make-frame-cell "界" 2 #f 'default 'wide)]
      [continuation (make-frame-cell "" 0 #t 'default 'wide)])
  (unless (and (frame? (make-frame 2 1 (vector wide continuation)))
               (guard (condition [else #t]) (make-frame 1 1 (vector wide)) #f)
               (guard (condition [else #t])
                 (make-frame 2 1 (vector continuation default-frame-cell)) #f))
    (error 'kernel-tests "Frame grid validation differs")))

(let* ([document (make-document "ab\ncd")]
       [snapshot (document-snapshot document)]
       [selection (make-selection (list (make-selection-range 1 3)))]
       [layout (layout-text-snapshot snapshot selection 0 4 2)])
  (unless (and (string=? (frame-cell-grapheme (frame-cell-at (text-layout-frame layout) 0 0)) "a")
               (equal? (frame-cell-face (frame-cell-at (text-layout-frame layout) 0 1))
                       '(text selection))
               (eq? (frame-cell-face (frame-cell-at (text-layout-frame layout) 1 0)) 'text)
               (= (display-map-cell->document (text-layout-display-map layout) 4) 3)
               (equal? (text-layout-document->point layout 3) '(1 . 0))
               (= (text-layout-point->document layout 1 0) 3)
               (eq? (display-map-entry-kind
                      (text-layout-point->display-entry layout 0 0))
                     'text)
               (not (text-layout-point->document layout 2 0)))
    (error 'kernel-tests "text layout projection differs"))
  (snapshot-close! snapshot)
  (document-close! document))

(let* ([document (make-document "abcdef\nx")]
       [snapshot (document-snapshot document)]
       [selection (make-selection (list (make-selection-range 5 5)))]
       [layout (layout-text-snapshot snapshot selection 0 6 2)])
  (unless (and (= (text-layout-vertical-target layout 5 1) 7)
               (= (text-layout-vertical-target layout 5 1 5) 7)
               (= (text-layout-vertical-target layout 7 -1 5) 5)
               (not (text-layout-vertical-target layout 5 2)))
    (error 'kernel-tests "text layout vertical motion differs"))
  (snapshot-close! snapshot)
  (document-close! document))

(let* ([document (make-document "abc")]
       [snapshot (document-snapshot document)]
       [selection (make-selection (list (make-selection-range 0 0)))]
       [decorations
         (make-decoration-set
           (list (make-range-value 1 2 (make-face-decoration 'keyword 10))))]
       [layout (layout-text-snapshot snapshot selection 0 3 1 decorations)])
  (unless (eq? (frame-cell-face (frame-cell-at (text-layout-frame layout) 0 1)) 'keyword)
    (error 'kernel-tests "RangeSet decoration layout differs"))
  (snapshot-close! snapshot)
  (document-close! document))

(let* ([document (make-document "abc")]
       [snapshot (document-snapshot document)]
       [selection (make-selection (list (make-selection-range 1 2)))]
       [decorations
        (make-decoration-set
          (list (make-range-value 1 2 (make-face-decoration 'keyword 1))
                (make-range-value 1 2 (make-face-decoration 'warning 10))))]
       [layout (layout-text-snapshot snapshot selection 0 3 1 decorations)]
       [face (frame-cell-face (frame-cell-at (text-layout-frame layout) 0 1))]
       [theme
        (make-theme
          (list (cons 'keyword (make-face-style 6 #f '(bold)))
                (cons 'warning (make-face-style #f 1 '(underline)))
                (cons 'selection (make-face-style #f #f '(reverse))))
          (make-face-style #f #f '()))]
       [style (theme-face-style theme face)])
  (unless (and (equal? face '(text keyword warning selection))
               (= (face-style-foreground style) 6)
               (= (face-style-background style) 1)
               (equal? (face-style-attributes style) '(bold underline reverse)))
    (error 'kernel-tests "overlapping decoration style composition differs" face style))
  (snapshot-close! snapshot)
  (document-close! document))

(let* ([document (make-document "a\nb")]
       [snapshot (document-snapshot document)]
       [decorations
        (make-decoration-set
          (list (make-range-value 2 3 (make-face-decoration 'keyword 1))))]
       [stream (snapshot-display-stream snapshot 0 2 decorations)]
       [fragments (display-stream-fragments stream)]
       [layout (layout-display-stream stream
                                      (make-selection (list (make-selection-range 0 0)))
                                      2 2)])
  (unless (and (= (length fragments) 3)
               (display-text-atomic? (car fragments))
               (= (display-text-width (car fragments)) 1)
               (display-break? (cadr fragments))
               (eq? (frame-cell-face
                     (frame-cell-at (text-layout-frame layout) 1 0)) 'keyword)
               (eq? (display-map-entry-kind
                     (text-layout-point->display-entry layout 0 1)) 'line-break)
               (= (text-layout-point->document layout 0 1) 1)
               (equal? (text-layout-visible-ranges layout) (list (cons 0 3))))
    (error 'kernel-tests "document DisplayStream projection differs"))
  (snapshot-close! snapshot)
  (document-close! document))

(let* ([document (make-document #vu8(255 97))]
       [snapshot (document-snapshot document)]
       [stream (snapshot-display-stream snapshot 0 1)]
       [fragments (display-stream-fragments stream)]
       [layout (layout-display-stream
                 stream (make-selection (list (make-selection-range 0 0))) 2 1)])
  (unless (and (= (length fragments) 2)
               (display-text-atomic? (car fragments))
               (= (display-text-from (car fragments)) 0)
               (= (display-text-to (car fragments)) 1)
               (= (display-text-width (car fragments)) 1)
               (string=? (frame-cell-grapheme
                            (frame-cell-at (text-layout-frame layout) 0 0))
                          "\xfffd;")
               (= (text-layout-point->document layout 0 1) 1))
    (error 'kernel-tests "invalid UTF-8 display projection differs"))
  (snapshot-close! snapshot)
  (document-close! document))

(let* ([document (make-document "ab\tcd")]
       [snapshot (document-snapshot document)]
       [selection (make-selection (list (make-selection-range 3 3)))]
       [options (make-text-layout-options 4 #t)]
       [layout (layout-text-snapshot snapshot selection 0 4 2
                                     (make-decoration-set '()) options)]
       [frame (text-layout-frame layout)])
  (unless (and (string=? (frame-cell-grapheme (frame-cell-at frame 0 0)) "a")
               (string=? (frame-cell-grapheme (frame-cell-at frame 0 3)) " ")
               (string=? (frame-cell-grapheme (frame-cell-at frame 1 0)) "c")
               (equal? (text-layout-document->point layout 3) '(1 . 0))
               (= (text-layout-point->document layout 0 3) 2)
               (= (text-layout-cursor-row layout) 1)
               (= (text-layout-cursor-column layout) 0))
    (error 'kernel-tests "soft-wrap or tab layout differs"))
  (snapshot-close! snapshot)
  (document-close! document))

(let* ([stream
        (make-display-stream
          (list (make-display-text "ab" 0 2 'text 'document)
                (make-display-widget 1 1 2 'hint 'inlay)
                (make-display-text "c" 2 3 'text 'document)))]
       [selection (make-selection (list (make-selection-range 0 0)))]
       [layout (layout-display-stream stream selection 4 1)]
       [frame (text-layout-frame layout)]
       [map (text-layout-display-map layout)])
  (unless (and (string=? (frame-cell-grapheme (frame-cell-at frame 0 0)) "a")
               (string=? (frame-cell-grapheme (frame-cell-at frame 0 1)) "b")
               (eq? (frame-cell-face (frame-cell-at frame 0 2)) 'hint)
               (string=? (frame-cell-grapheme (frame-cell-at frame 0 3)) "c")
               (= (display-map-cell->document map 2) 2)
               (= (display-map-document->cell map 2 'before) 2)
               (= (display-map-document->cell map 2 'after) 3))
    (error 'kernel-tests "DisplayStream layout differs")))

;; Visible ranges come from the finished display mapping.  They exclude
;; virtual content and retain source gaps created by structural projection.
(let* ([stream
        (make-display-stream
          (list (make-display-text "a" 0 1 'text 'document)
                (make-display-text ":" 1 1 'hint 'inlay)
                (make-display-text "F" 2 4 'fold 'fold)
                (make-display-text "z" 5 6 'text 'document)))]
       [layout (layout-display-stream
                 stream (make-selection (list (make-selection-range 0 0))) 8 1)])
  (unless (equal? (text-layout-visible-ranges layout)
                  (list (cons 0 1) (cons 2 4) (cons 5 6)))
    (error 'kernel-tests "TextLayout visible ranges differ")))

(let* ([stream
        (make-display-stream
          (list (make-display-text "e\x301;" 0 3 'text 'document)))]
       [selection (make-selection (list (make-selection-range 0 0)))]
       [layout (layout-display-stream stream selection 2 1)])
  (unless (and (string=? (frame-cell-grapheme
                           (frame-cell-at (text-layout-frame layout) 0 0)) "e\x301;")
               (equal? (text-layout-document->point layout 3) '(0 . 1)))
    (error 'kernel-tests "DisplayStream grapheme layout differs")))

;; Viewport offsets are visual rows, not document lines.  Cropping a wrapped
;; projection must retain both its display text and its DisplayMap mapping.
(let* ([stream
        (make-display-stream
          (list (make-display-text "abcd" 0 4 'text 'document)))]
       [layout (layout-display-stream
                 stream (make-selection (list (make-selection-range 2 2)))
                 2 1 default-text-layout-options 1)]
       [frame (text-layout-frame layout)])
  (unless (and (string=? (frame-cell-grapheme (frame-cell-at frame 0 0)) "c")
               (string=? (frame-cell-grapheme (frame-cell-at frame 0 1)) "d")
               (= (text-layout-point->document layout 0 0) 2)
               (= (text-layout-cursor-row layout) 0)
               (= (text-layout-cursor-column layout) 0))
    (error 'kernel-tests "DisplayStream visual viewport differs")))

(let* ([base
        (make-display-stream
          (list (make-display-text "a" 0 1 'text 'document)
                (make-display-text "b" 1 2 'text 'document)
                (make-display-text "c" 2 3 'text 'document)))]
       [inlay (make-display-text ":" 1 1 'hint 'inlay)]
       [replacement (make-display-text "X" 1 2 'fold 'fold)]
       [stream (display-stream-replace
                 (display-stream-insert base 1 (list inlay)) 1 2 (list replacement))]
       [layout (layout-display-stream stream
                                      (make-selection (list (make-selection-range 0 0)))
                                      4 1)])
  (unless (and (string=? (frame-cell-grapheme (frame-cell-at (text-layout-frame layout) 0 0)) "a")
               (string=? (frame-cell-grapheme (frame-cell-at (text-layout-frame layout) 0 1)) ":")
               (string=? (frame-cell-grapheme (frame-cell-at (text-layout-frame layout) 0 2)) "X")
               (string=? (frame-cell-grapheme (frame-cell-at (text-layout-frame layout) 0 3)) "c"))
    (error 'kernel-tests "DisplayStream transform differs")))

;; A virtual insertion at a newline offset remains on the preceding visual
;; line.  DisplayBreak participates in stream ordering even though it has no
;; text interval.
(let* ([base
        (make-display-stream
          (list (make-display-text "a" 0 1 'text 'document)
                (make-display-break 1)
                (make-display-text "b" 2 3 'text 'document)))]
       [stream (display-stream-insert
                 base 1 (list (make-display-text ":" 1 1 'hint 'inlay)))]
       [layout (layout-display-stream
                 stream (make-selection (list (make-selection-range 0 0))) 3 2)]
       [frame (text-layout-frame layout)])
  (unless (and (string=? (frame-cell-grapheme (frame-cell-at frame 0 0)) "a")
               (string=? (frame-cell-grapheme (frame-cell-at frame 0 1)) ":")
               (string=? (frame-cell-grapheme (frame-cell-at frame 1 0)) "b"))
    (error 'kernel-tests "DisplayStream newline insertion differs")))

;; A replacement that owns a physical newline must collapse the corresponding
;; DisplayBreak as well.  Otherwise a folded multi-line range leaves an empty
;; visual line after its placeholder.
(let* ([base
        (make-display-stream
          (list (make-display-text "a" 0 1 'text 'document)
                (make-display-break 1)
                (make-display-text "b" 2 3 'text 'document)))]
       [stream (display-stream-replace
                 base 0 3 (list (make-display-text "X" 0 3 'fold 'fold)))]
       [layout (layout-display-stream stream
                                      (make-selection (list (make-selection-range 0 0)))
                                      2 2)]
       [frame (text-layout-frame layout)])
  (unless (and (string=? (frame-cell-grapheme (frame-cell-at frame 0 0)) "X")
               (string=? (frame-cell-grapheme (frame-cell-at frame 1 0)) " "))
    (error 'kernel-tests "DisplayStream multi-line replacement differs")))

(let ([layout
       (layout-display-stream (make-display-stream '())
                              (make-selection (list (make-selection-range 0 0)))
                              2 1)])
  (unless (and (= (text-layout-cursor-row layout) 0)
               (= (text-layout-cursor-column layout) 0))
    (error 'kernel-tests "empty DisplayStream caret differs")))

(let* ([base (make-frame 4 2)]
       [top (frame-with-cell (make-frame 2 1) 0 0
                             (make-frame-cell "x" 1 #f 'overlay #f))]
       [composed
         (compose-frame
           4 2
           (list (make-frame-placement 0 0 base)
                 (make-frame-placement 1 2 top)))])
  (unless (and (string=? (frame-cell-grapheme (frame-cell-at composed 1 2)) "x")
               (eq? (frame-cell-face (frame-cell-at composed 1 2)) 'overlay)
               (string=? (frame-cell-grapheme (frame-cell-at composed 0 0)) " "))
    (error 'kernel-tests "Frame composition differs")))

(let* ([destroyed #f]
       [decoration-reads 0]
       [plugin
         (make-view-plugin
           'counter
           (lambda (view) (vector 1))
           (lambda (value update)
             (when (view-update-damaged? update 'selection)
               (vector-set! value 0 (+ (vector-ref value 0) 1))))
           (lambda (value) (set! destroyed (vector-ref value 0)))
           (lambda (value)
             (set! decoration-reads (+ decoration-reads 1))
             (make-decoration-set
               (list (make-range-value 0 1
                                       (make-face-decoration 'counter
                                                             (vector-ref value 0)))))))]
       [instance (make-view-plugin-instance plugin 'view)]
       [update (make-view-update 9 'old 'new #f '(selection))])
  (view-plugin-instance-update! instance update)
  (unless (and (= (vector-ref (view-plugin-instance-value instance) 0) 2)
               (= (length (range-set-ranges (view-plugin-instance-decorations instance))) 1)
               (= decoration-reads 2)
               (view-plugin-instance-destroy! instance)
               (= destroyed 2)
               (null? (view-plugin-instance-decorations instance))
               (not (view-plugin-instance-destroy! instance)))
    (error 'kernel-tests "ViewPlugin lifecycle differs")))

(let* ([created 0]
       [updated 0]
       [destroyed 0]
       [plugin
         (make-view-plugin
           'host-counter
           (lambda (view) (set! created (+ created 1)) 0)
           (lambda (value update) (set! updated (+ updated 1)))
           (lambda (value) (set! destroyed (+ destroyed 1)))
           #f)]
       [view-configuration
         (make-configuration
           (list (make-facet-provider view-plugins-facet (list plugin))))]
       [plugin-document (make-document "x")]
       [plugin-buffer
         (buffer-service-create!
           (host-state-buffers host) owner "*plugin*" plugin-document
           (make-configuration '()))]
       [plugin-view
         (view-service-create!
           (host-state-views host) owner plugin-buffer view-configuration)])
  (dispatcher-dispatch-view!
    (host-state-dispatch host)
    (make-view-transaction-spec
      (view-id plugin-view) 0
      (make-selection (list (make-selection-range 1 1)))
      #f #f '() '() #f))
  (view-service-close-view! (host-state-views host) (view-id plugin-view))
  (unless (and (= created 1) (= updated 1) (= destroyed 1))
    (error 'kernel-tests "host ViewPlugin integration differs"
           created updated destroyed)))

;; Reconfiguring a view-scoped plugin compartment retires removed instances
;; before publishing the replacement projection.  Closing the View then owns
;; the replacement instance's final cleanup.
(let* ([events '()]
       [first
        (make-view-plugin
          'reconfigure-first
          (lambda (view) (set! events (cons 'first-create events)) 'first)
          #f
          (lambda (value) (set! events (cons 'first-destroy events)))
          #f)]
       [second
        (make-view-plugin
          'reconfigure-second
          (lambda (view) (set! events (cons 'second-create events)) 'second)
          #f
          (lambda (value) (set! events (cons 'second-destroy events)))
          #f)]
       [compartment (make-compartment 'view-plugin-reconfigure 'view)]
       [configuration
        (make-configuration
          (list
            (make-compartment-entry
              compartment
              (make-facet-provider view-plugins-facet (list first)))))]
       [document (make-document "x")]
       [buffer (buffer-service-create! (host-state-buffers host) owner
                                       "*plugin-reconfigure*" document
                                       (make-configuration '()))]
       [view (view-service-create! (host-state-views host) owner buffer configuration)]
       [before-generation (view-render-generation view)]
       [state (view-state view)]
       [_update
        (dispatcher-dispatch-view!
          (host-state-dispatch host)
          (make-view-transaction-spec
            (view-id view) (view-state-generation state)
            #f #f #f
            (list
              (make-compartment-reconfigure-effect
                compartment
                (make-facet-provider view-plugins-facet (list second))))
            '() #f))]
       [after-generation (view-render-generation view)])
  (view-service-close-view! (host-state-views host) (view-id view))
  (unless (and (> after-generation before-generation)
               (equal? (reverse events)
                       '(first-create first-destroy second-create second-destroy)))
    (error 'kernel-tests "ViewPlugin reconfiguration lifecycle differs"
           (reverse events))))

(let* ([updates 0]
       [destroyed 0]
       [plugin
         (make-view-plugin
           'failing-plugin
           (lambda (view) 'value)
           (lambda (value update)
             (set! updates (+ updates 1))
             (error 'kernel-tests "intentional ViewPlugin failure"))
           (lambda (value) (set! destroyed (+ destroyed 1)))
           #f)]
       [view-configuration
         (make-configuration
           (list (make-facet-provider view-plugins-facet (list plugin))))]
       [plugin-document (make-document "x")]
       [plugin-buffer
         (buffer-service-create!
           (host-state-buffers host) owner "*failing-plugin*" plugin-document
           (make-configuration '()))]
       [plugin-view
         (view-service-create!
           (host-state-views host) owner plugin-buffer view-configuration)]
       [selection (make-selection (list (make-selection-range 1 1)))])
  (dispatcher-dispatch-view!
    (host-state-dispatch host)
    (make-view-transaction-spec
      (view-id plugin-view) 0 selection #f #f '() '() #f))
  (dispatcher-dispatch-view!
    (host-state-dispatch host)
    (make-view-transaction-spec
      (view-id plugin-view) 1 selection #f #f '() '() #f))
  (unless (and (= updates 1) (= destroyed 1))
    (error 'kernel-tests "failing ViewPlugin was not retired" updates destroyed)))

(let* ([plugin
        (make-view-plugin
          'failing-display
          (lambda (view) 'ready)
          (lambda (value update) (error 'kernel-tests "intentional display failure"))
          #f
          #f
          (lambda (value)
            (make-display-stream
              (list (make-display-text "v" 0 1 'virtual 'plugin)))))]
       [configuration
        (make-configuration
          (list (make-facet-provider view-plugins-facet (list plugin))))]
       [document (make-document "x")]
       [buffer (buffer-service-create! (host-state-buffers host) owner "*failing-display*"
                                       document configuration)]
       [view (view-service-create! (host-state-views host) owner buffer configuration)]
       [leaf (make-leaf-window (view-id view) '(0 0 2 1))]
       [surface (make-surface leaf '(2 . 1))]
       [service (make-render-service)]
       [before (render-service-render! service surface (host-state-views host))]
       [state (view-state view)]
       [_update
        (dispatcher-dispatch-view!
          (host-state-dispatch host)
          (make-view-transaction-spec
            (view-id view) (view-state-generation state)
            #f #f (make-input-stack (make-input-state 'transient '() 'accept))
            '() '() #f))]
       [after (render-service-render! service surface (host-state-views host))])
  (unless (and (not (eq? before after))
               (string=? (frame-cell-grapheme
                           (frame-cell-at (surface-render-frame after) 0 0)) "x"))
    (error 'kernel-tests "failed display plugin left a stale render")))

;; A transform runs while rendering rather than while publishing a ViewUpdate.
;; Its failure leaves the frame pure, then the host loop retires the matching
;; plugin only when that frame still names the current projection generation.
(let* ([plugin
        (make-view-plugin
          'failing-transform
          (lambda (view) 'ready)
          #f #f #f
          (lambda (value)
            (make-display-stream
              (list (make-display-text "v" 0 1 'virtual 'plugin))))
          (lambda (value)
            (lambda (stream)
              (error 'kernel-tests "intentional display transform failure"))))]
       [configuration
        (make-configuration
          (list (make-facet-provider view-plugins-facet (list plugin))))]
       [document (make-document "x")]
       [buffer
        (buffer-service-create! (host-state-buffers host) owner "*failing-transform*"
                                document configuration)]
       [view (view-service-create! (host-state-views host) owner buffer configuration)]
       [leaf (make-leaf-window (view-id view) '(0 0 2 1))]
       [surface (make-surface leaf '(2 . 1))]
       [service (make-render-service)]
       [render (render-service-render! service surface (host-state-views host))]
       [cached (render-service-render! service surface (host-state-views host))]
       [rendered (car (surface-render-rendered-views render))]
       [failure (car (rendered-view-transform-failures rendered))]
       [retired
        (view-service-retire-projection-failure!
          (host-state-views host) (view-id view)
          (rendered-view-projection-generation rendered)
          (car failure) (cadr failure))])
  (unless (and (string=? (frame-cell-grapheme
                           (frame-cell-at (surface-render-frame render) 0 0)) "v")
               retired
               (view-plugin-instance-destroyed?
                 (car (view-plugin-instances view)))
               (= (length (rendered-view-transform-failures
                            rendered)) 1)
               (eq? render cached))
    (error 'kernel-tests "failed display transform was not isolated from rendering")))

;; Command packages exchange declarations and result values with the runtime;
;; they never receive a Dispatcher or a terminal-specific interaction object.
(let* ([package-owner (make-owner 'command-test)]
       [runtime (host-state-command-runtime host)]
       [effects '()]
       [hooks '()]
       [definition
        (make-command-definition
          'command.test
          (lambda (context number)
            (make-command-result
              (list (make-command-effect 'command-test-effect number))))
          package-owner
          "Command runtime test" 'editing #f)]
       [_command (command-runtime-register-command! runtime definition)]
       [_effect-handler
        (command-runtime-register-effect-handler!
          runtime 'command-test-effect package-owner 'record-effect
          (lambda (service invocation effect)
            (set! effects (cons (command-effect-payload effect) effects))))]
       [_pre-hook
        (command-runtime-add-hook!
          runtime 'pre-command package-owner 'record-pre
          (lambda (invocation) (set! hooks (cons 'pre hooks))))]
       [_post-hook
        (command-runtime-add-hook!
          runtime 'post-command package-owner 'record-post
          (lambda (invocation result) (set! hooks (cons 'post hooks))))]
       [_advice
        (command-runtime-add-advice!
          runtime 'command.test package-owner 'increment-argument 'filter-args
          (lambda (context arguments) (map (lambda (value) (+ value 1)) arguments)))]
       [invocation
        (command-runtime-start!
          runtime 'command.test (make-command-context #f #f 'test) (list 4))])
  (unless (and (eq? (command-invocation-phase invocation) 'completed)
               (equal? effects '(5))
               (equal? hooks '(post pre))
               (not (command-runtime-invocation runtime
                                                 (command-invocation-id invocation) #f)))
    (error 'kernel-tests "command lifecycle did not dispatch outcomes"))
  (owner-close! package-owner))

;; Interactive suspension is data-driven.  Resume continues the original
;; invocation after the UI package has produced a decoder input.
(let* ([package-owner (make-owner 'interactive-command-test)]
       [runtime (host-state-command-runtime host)]
       [effect-values '()]
       [suspended #f]
       [first-reader
        (make-interactive-reader
          'first
          (lambda (context arguments) (make-interactive-ready (list 'first))))]
       [second-reader
        (make-interactive-reader
          'second
          (lambda (context arguments)
            (make-interactive-suspend
              '(read-second)
              (lambda (value) (make-interactive-ready (list value))))))]
       [definition
        (make-command-definition
          'command.interactive-test
          (lambda (context first second)
            (make-command-result
              (list (make-command-effect 'interactive-command-effect
                                         (list first second)))))
          package-owner
          (make-interactive-plan (list first-reader second-reader)))]
       [_command (command-runtime-register-command! runtime definition)]
       [_handler
        (command-runtime-register-effect-handler!
          runtime 'interactive-command-effect package-owner 'record-interactive
          (lambda (service invocation effect)
            (set! effect-values (cons (command-effect-payload effect) effect-values))))]
       [_interaction
        (command-runtime-set-interaction-handler!
          runtime package-owner
          (lambda (service invocation request)
            (set! suspended (cons (command-invocation-id invocation) request))))]
       [invocation
        (command-runtime-start-interactive!
          runtime 'command.interactive-test (make-command-context #f #f 'test))]
       [_resumed
        (command-runtime-resume! runtime (command-invocation-id invocation) 'second)])
  (unless (and (equal? suspended (cons (command-invocation-id invocation) '(read-second)))
               (eq? (command-invocation-phase invocation) 'completed)
               (equal? effect-values '((first second)))
               (not (command-runtime-invocation runtime
                                                 (command-invocation-id invocation) #f)))
    (error 'kernel-tests "interactive command resume did not preserve its invocation"))
  (owner-close! package-owner))

;; Command messages run at HostState's runtime-queue boundary rather than
;; recursively from the input or interaction implementation.
(let* ([package-owner (make-owner 'command-queue-test)]
       [runtime (host-state-command-runtime host)]
       [observed #f]
       [definition
        (make-command-definition
          'command.queue-test
          (lambda (context value)
            (set! observed value)
            (command-handled))
          package-owner)]
       [_command (command-runtime-register-command! runtime definition)])
  (command-runtime-enqueue!
    runtime
    (make-command-invoke-message
      'command.queue-test (make-command-context #f #f 'queue) (list 'queued)))
  (host-state-run! host)
  (unless (eq? observed 'queued)
    (error 'kernel-tests "host command loop did not consume queued command message"))
  (owner-close! package-owner))

;; A command exception stops only that invocation.  It becomes an editor
;; condition at the host boundary instead of escaping the frontend loop.
(let* ([package-owner (make-owner 'command-condition-test)]
       [runtime (host-state-command-runtime host)]
       [before (length (condition-service-entries (host-state-conditions host)))]
       [definition
        (make-command-definition
          'command.condition-test
          (lambda (context) (error 'command-condition-test "expected failure"))
          package-owner)]
       [_command (command-runtime-register-command! runtime definition)]
       [invocation
        (command-runtime-start!
          runtime 'command.condition-test (make-command-context #f #f 'test))])
  (unless (and (eq? (command-invocation-phase invocation) 'cancelled)
               (editor-condition? (command-invocation-condition invocation))
               (= (length (condition-service-entries (host-state-conditions host)))
                  (+ before 1)))
    (error 'kernel-tests "command exception was not captured as an editor condition"))
  (owner-close! package-owner))

;; define-command publishes complete metadata through runtime-owned
;; introspection without exposing the mutable CommandRegistry.
(let* ([command-owner (make-owner 'command-introspection-test)]
       [runtime (host-state-command-runtime host)]
       [registration
        (define-command
          runtime command-owner 'command.introspection-test (context value)
          (documentation "Inspect this command.")
          (class 'inspection)
          (interactive
            (make-interactive-plan
              (list
                (make-interactive-reader
                  'value
                  (lambda (context arguments)
                    (make-interactive-ready (list 'ready)))))))
          (undo 'ignore)
          (if (eq? value 'ready) (command-handled) (command-handled)))]
       [definition
        (command-runtime-command-definition runtime 'command.introspection-test)]
       [names (command-runtime-command-names runtime)]
       [definitions (command-runtime-command-definitions runtime)])
  (define (sorted-symbols? values)
    (or (null? values) (null? (cdr values))
        (and (string<? (symbol->string (car values))
                       (symbol->string (cadr values)))
             (sorted-symbols? (cdr values)))))
  (unless (and (registration? registration)
               (command-definition? definition)
               (string=? (command-definition-documentation definition)
                         "Inspect this command.")
               (eq? (command-definition-class definition) 'inspection)
               (eq? (command-definition-owner definition) command-owner)
               (command-definition-interactive? definition)
               (memq 'command.introspection-test names)
               (memq definition definitions)
               (sorted-symbols? names))
    (error 'kernel-tests "define-command metadata is not introspectable"))
  (owner-close! command-owner)
  (unless (not (command-runtime-command-definition
                 runtime 'command.introspection-test #f))
    (error 'kernel-tests "owner cleanup did not retire the declared command")))

;; OptionSpec resolves defaults, mode contributions, and explicit Buffer-local
;; overrides by precedence. Clearing the local compartment reveals the mode
;; default without rebuilding the rest of the Configuration.
(let* ([positive-option
        (make-option-spec
          'test-width 4
          (lambda (value) (and (integer? value) (exact? value) (> value 0)))
          = "Positive test width.")]
       [configuration
        (make-configuration
          (list
            (make-option-default-extension positive-option 8)
            (compartment-of
              (option-spec-compartment positive-option)
              (make-buffer-local-option-extension positive-option 2))))]
       [cleared
        (configuration-apply-effects
          configuration (list (clear-buffer-local-option-effect positive-option)) 'buffer)]
       [overridden
        (configuration-apply-effects
          cleared (list (set-buffer-local-option-effect positive-option 6)) 'buffer)]
       [invalid-rejected?
        (guard (condition [else #t])
          (make-buffer-local-option-extension positive-option 0)
          #f)])
  (unless (and (= (option-ref (make-configuration '()) positive-option) 4)
               (= (option-ref configuration positive-option) 2)
               (= (option-ref cleared positive-option) 8)
               (= (option-ref overridden positive-option) 6)
               invalid-rejected?)
    (error 'kernel-tests "Buffer-local OptionSpec precedence or validation failed")))

;; ModeSpec composes inherited major-mode extensions before ordered minor
;; modes, and both mode sets can be replaced through Buffer transactions.
(let* ([contributions
        (make-facet 'mode-test-contributions 'buffer '()
                    (lambda (values) (fold-left append '() values)) equal? equal?)]
       [base
        (make-mode-spec
          'base-mode 'major "Base" #f
          (list (make-facet-provider contributions '(base))) '(base) "Base")]
       [derived
        (make-mode-spec
          'derived-mode 'major "Derived" base
          (list (make-facet-provider contributions '(derived))) '(derived) "Derived")]
       [alternate
        (make-mode-spec
          'alternate-mode 'major "Alternate" #f
          (list (make-facet-provider contributions '(alternate))) '() "Alternate")]
       [first-minor
        (make-mode-spec
          'first-minor 'minor "First minor" #f
          (list (make-facet-provider contributions '(first-minor))) '() #f)]
       [second-minor
        (make-mode-spec
          'second-minor 'minor "Second minor" #f
          (list (make-facet-provider contributions '(second-minor))) '() #f)]
       [configuration
        (make-configuration
          (make-buffer-modes-extension derived (list first-minor second-minor)))]
       [changed
        (configuration-apply-effects
          configuration
          (list (set-buffer-major-mode-effect alternate)
                (set-buffer-minor-modes-effect (list second-minor)))
          'buffer)])
  (unless (and (eq? (configuration-facet configuration buffer-mode-facet 'buffer) derived)
               (equal? (configuration-facet configuration buffer-minor-modes-facet 'buffer)
                       (list first-minor second-minor))
               (equal? (configuration-facet configuration contributions 'buffer)
                       '(base derived first-minor second-minor))
               (eq? (configuration-facet changed buffer-mode-facet 'buffer) alternate)
               (equal? (configuration-facet changed buffer-minor-modes-facet 'buffer)
                       (list second-minor))
               (equal? (configuration-facet changed contributions 'buffer)
                       '(alternate second-minor)))
    (error 'kernel-tests "ModeSpec configuration composition is not deterministic")))

(let* ([application (make-soda-application)]
       [state (soda-application-state application)]
       [buffer (soda-application-buffer application)]
       [view (soda-application-view application)]
       [secondary-owner (make-owner 'mode-secondary-view)]
       [secondary-view
        (view-service-create!
          (host-state-views state) secondary-owner buffer
          (view-state-configuration (view-state view)))]
       [configuration (buffer-state-configuration (buffer-state buffer))]
       [mode (configuration-facet configuration buffer-mode-facet 'buffer)]
       [layers (configuration-facet configuration buffer-input-layers-facet 'buffer)]
       [minor
        (make-mode-spec 'transaction-minor 'minor "Transaction minor" #f '() '() #f)]
       [document-length
        (snapshot-byte-size (buffer-state-document (buffer-state buffer)))]
       [_update
        (dispatcher-dispatch!
          (host-state-dispatch state)
          (make-transaction-spec
            (buffer-id buffer) (view-id view)
            (buffer-state-generation (buffer-state buffer))
            (make-change-set document-length '()) #f
            (list (set-buffer-minor-modes-effect (list minor))) '()))]
       [published-configuration (buffer-state-configuration (buffer-state buffer))])
  (unless (and (mode-spec? mode)
               (eq? (mode-spec-id mode) 'fundamental-mode)
               (= (length layers) 1)
               (eq? (input-layer-kind (car layers)) 'major)
               (eq? (input-layer-keymap (car layers))
                    (fundamental-editing-keymap (soda-application-editing application)))
               (equal? (configuration-facet
                         published-configuration buffer-minor-modes-facet 'buffer)
                       (list minor))
               (= (view-state-buffer-generation (view-state view))
                  (buffer-state-generation (buffer-state buffer)))
               (= (view-state-buffer-generation (view-state secondary-view))
                  (buffer-state-generation (buffer-state buffer))))
    (error 'kernel-tests "fundamental-mode is not the Buffer major mode"))
  (let* ([settings-owner (make-owner 'editor-setting-source-test)]
         [package-host (make-package-host state)]
         [resource (make-resource 'file "/tmp/project/main.scm")]
         [context (make-configuration-context 'project-a resource)]
         [source-location
          (make-location resource
                         (make-line-column-position 0 0)
                         (make-line-column-position 0 1)
                         #f 'after '())]
         [declaration
          (lambda (name value scope)
            (make-setting-declaration
              name value scope source-location))]
         [source
          (make-configuration-source
            'test.editor-settings 'workspace 'project-a
            (list
              (declaration 'editor.tab-width "4" 'view)
              (declaration 'editor.indent-width "2" 'buffer)
              (declaration 'editor.fill-column "100" 'buffer)
              (declaration 'editor.soft-wrap "off" 'view)
              (declaration 'editor.line-numbers "on" 'view)
              (declaration 'editor.auto-indent "false" 'buffer)
              (declaration 'editor.auto-fill "true" 'buffer)
              (declaration 'editor.tab-to-spaces "yes" 'buffer)
              (declaration 'editor.read-only "true" 'buffer)
              (declaration 'file.backup "on" 'buffer))
            0)])
    (package-host-reload-configuration-source!
      package-host settings-owner source)
    (let* ([buffer-settings
            (package-host-configuration-extensions
              package-host 'buffer context)]
           [view-settings
            (package-host-configuration-extensions
              package-host 'view context)]
           [configured-buffer
            (make-configuration
              (append (configuration-extensions configuration)
                      buffer-settings))]
           [configured-view (make-configuration view-settings)]
           [indent (configuration-indent-options configured-buffer)]
           [fill (configuration-fill-options configured-buffer)]
           [layout
            (configuration-facet
              configured-view text-layout-options-facet 'view)]
           [temporary-buffer
            (make-configuration
              (append (configuration-extensions configured-buffer)
                      (list
                        (compartment-of
                          indent-options-compartment
                          (make-indent-options-extension 6 #t)))))]
           [temporary-view
            (make-configuration
              (append (configuration-extensions configured-view)
                      (list
                        (compartment-of
                          layout-options-compartment
                          (make-layout-options-extension 7 #t))
                        (compartment-of
                          line-number-compartment
                          (make-line-number-extension #f)))))]
           [temporary-indent
            (configuration-indent-options temporary-buffer)]
           [temporary-layout
            (configuration-facet
              temporary-view text-layout-options-facet 'view)])
      (unless
        (and (= (indent-options-width indent) 2)
             (not (indent-options-insert-tabs? indent))
             (= (fill-options-column fill) 100)
             (fill-options-auto-fill? fill)
             (not (auto-indent-enabled? configured-buffer))
             (buffer-read-only? configured-buffer)
             (file-backup-enabled? configured-buffer)
             (= (text-layout-options-tab-width layout) 4)
             (not (text-layout-options-wrap? layout))
             (line-numbers-enabled? configured-view)
             (= (indent-options-width temporary-indent) 6)
             (indent-options-insert-tabs? temporary-indent)
             (= (text-layout-options-tab-width temporary-layout) 7)
             (text-layout-options-wrap? temporary-layout)
             (not (line-numbers-enabled? temporary-view)))
        (error 'kernel-tests
               "persistent editor settings did not compose with local overrides"
               (list
                 (indent-options-width temporary-indent)
                 (indent-options-insert-tabs? temporary-indent)
                 (text-layout-options-tab-width temporary-layout)
                 (text-layout-options-wrap? temporary-layout)
                 (line-numbers-enabled? temporary-view)
                 (text-layout-options-tab-width layout)
                 (text-layout-options-wrap? layout)
                 (line-numbers-enabled? configured-view)
                 (file-backup-enabled? configured-buffer)))))
    (owner-close! settings-owner))
  (owner-close! secondary-owner)
  (soda-application-close! application))

(let* ([application (make-soda-application)]
       [state (soda-application-state application)]
       [surface (soda-application-surface application)]
       [buffer (soda-application-buffer application)]
       [view (soda-application-view application)]
       [contents (string->utf8 "hello world\nnext")]
       [_contents
        (dispatcher-dispatch!
          (host-state-dispatch state)
          (make-transaction-spec
            (buffer-id buffer) (view-id view)
            (buffer-state-generation (buffer-state buffer))
            (make-change-set 0 (list (make-text-change 0 0 contents)))
            #f '() '()))]
       [render (render-surface surface (host-state-views state))])
  (define (pointer-context event)
    (let* ([hit
            (surface-render-hit-test
              render (pointer-event-row event) (pointer-event-column event))]
           [active (surface-active-context surface (host-state-views state))])
      (make-command-context
        #f (surface-id surface) (surface-hit-window-id hit)
        (view-id view) (buffer-id buffer)
        (buffer-state buffer) (view-state view)
        event '() #f hit 'pointer-test)))
  (define (pointer-message event)
    (fundamental-input-disposition
      (pointer-context event) (input-pass)))
  (define (dispatch-pointer! event)
    (let ([message (pointer-message event)])
      (when message
        (command-runtime-enqueue!
          (host-state-command-runtime state) message)
        (host-state-run! state))))
  (define (primary-range)
    (selection-primary-range
      (view-state-selection (view-state view))))
  (dispatch-pointer! (make-pointer-event 0 1 'left 0 1 'press))
  (unless (= (selection-range-head (primary-range)) 1)
    (error 'kernel-tests "single click did not move point"))
  (dispatch-pointer! (make-pointer-event 0 7 'left 0 2 'press))
  (unless (and (= (selection-range-from (primary-range)) 6)
               (= (selection-range-to (primary-range)) 11))
    (error 'kernel-tests "double click did not select a semantic word"))
  (dispatch-pointer! (make-pointer-event 0 3 'left 0 3 'press))
  (unless (and (= (selection-range-from (primary-range)) 0)
               (= (selection-range-to (primary-range)) 11)
               (eq? (selection-range-granularity (primary-range)) 'line))
    (error 'kernel-tests "triple click did not select a logical line"))
  (dispatch-pointer! (make-pointer-event 0 1 'left 0 1 'press))
  (dispatch-pointer! (make-pointer-event 0 5 'left 0 0 'move))
  (dispatch-pointer! (make-pointer-event 0 5 'left 0 1 'release))
  (unless (and (= (selection-range-anchor (primary-range)) 1)
               (= (selection-range-head (primary-range)) 5))
    (error 'kernel-tests "pointer drag did not extend selection"))
  (dispatch-pointer! (make-pointer-event 0 8 'left 1 1 'press))
  (unless (= (selection-range-head (primary-range)) 8)
    (error 'kernel-tests "Shift-click did not extend the primary selection"))
  (dispatch-pointer! (make-pointer-event 0 10 'left 4 1 'press))
  (unless (= (length
               (selection-ranges
                 (view-state-selection (view-state view))))
             2)
    (error 'kernel-tests "Control-click did not add a selection range"))
  (let ([rows
         (pointer-message
           (make-pointer-event 0 0 'wheel-up 4 0 'wheel))]
        [page
         (pointer-message
           (make-pointer-event 0 0 'wheel-down 2 0 'wheel))])
    (unless (and (eq? (command-invoke-message-name rows)
                      'fundamental.pointer-scroll)
                 (equal? (command-invoke-message-arguments rows) '(-5 #f))
                 (equal? (command-invoke-message-arguments page) '(1 #t)))
      (error 'kernel-tests "pointer wheel modifier policy differs")))
  (soda-application-close! application))

;; Frontend orchestration converts queued Surface input into a published
;; InputState and a command-runtime message, then redraws only after the
;; dispatcher reports a changed View or Surface.
(let* ([package-owner (make-owner 'frontend-command-test)]
       [runtime (host-state-command-runtime host)]
       [keymap (make-keymap 'frontend-test)]
       [key (make-key-stroke 'character (char->integer #\f) 4)]
       [unavailable-key (make-key-stroke 'character (char->integer #\u) 4)]
       [observed #f]
       [unavailable-ran? #f]
       [pointer-observed #f]
       [renders 0]
       [presented-theme #f]
       [alternate-theme
        (make-theme '() (make-face-style 2 #f '()))]
       [definition
        (make-command-definition
          'command.frontend-test
          (lambda (context value)
            (set! observed (cons context value))
            (command-handled))
          package-owner
          (make-interactive-plan
            (list
              (make-interactive-reader
                'frontend-value
                (lambda (context arguments)
                  (make-interactive-ready (list 'frontend)))))))]
       [_command (command-runtime-register-command! runtime definition)]
       [_binding (keymap-bind! keymap (list key) 'command.frontend-test)]
       [unavailable-definition
        (make-command-definition
          'command.frontend-unavailable
          (lambda (context)
            (set! unavailable-ran? #t)
            (command-handled))
          package-owner "Only valid in a capability this Buffer does not provide."
          'frontend-unavailable #f 'mode)]
       [_unavailable-command
        (command-runtime-register-command! runtime unavailable-definition)]
       [_unavailable-binding
        (keymap-bind! keymap (list unavailable-key) 'command.frontend-unavailable)]
       [frontend
        (make-frontend
          host surface
          (lambda (active active-view)
            (make-input-context
              (active-context-view-id active)
              (active-context-buffer-id active)
              (list (make-input-layer 'global keymap #f 'ignore))
              (view-state-input-state (view-state active-view))))
          (lambda (context disposition)
            (when (pointer-event? (command-context-event context))
              (set! pointer-observed context))
            #f)
          (lambda (render theme)
            (set! renders (+ renders 1))
            (set! presented-theme theme))
          (make-render-service)
          default-theme)]
       [event
        (make-key-event
          'character (char->integer #\f) #f #f 4 'press (make-bytevector 0))])
  (define (dispatch-input! event)
    (frontend-enqueue!
      frontend (make-surface-input-message (surface-id surface) event))
    (frontend-step! frontend 100000))
  (unless (hashtable-contains?
            (host-state-frontend-handlers host) (surface-id surface))
    (error 'kernel-tests "frontend did not register its Surface input route"))
  (let ([rejected?
         (guard (condition [else #t])
           (command-runtime-start!
             runtime 'command.frontend-unavailable
             (make-command-context
               #f (surface-id surface) (window-id leaf) (view-id view)
               (buffer-id buffer) (buffer-state buffer) (view-state view)
               #f '() #f #f 'frontend-test))
           #f)])
    (unless rejected?
      (error 'kernel-tests
             "runtime accepted a mode-scoped command without its capability")))
  (frontend-step! frontend)
  (dispatch-input!
    (make-key-event
      'character (char->integer #\u) #f #f 4 'press (make-bytevector 0)))
  (unless (and (not unavailable-ran?)
               (let ([feedback (surface-feedback surface)])
                 (and feedback
                      (string=? (user-feedback-text feedback)
                                "C-u is not available in this context"))))
    (error 'kernel-tests
           "frontend queued a command unavailable in the active mode"
           unavailable-ran?
           (surface-feedback surface)))
  (dispatch-input! (make-pointer-event 0 1 'left 0 1 'press))
  (unless (and pointer-observed
               (surface-hit? (command-context-target pointer-observed))
               (= (surface-hit-window-id
                    (command-context-target pointer-observed))
                  (window-id leaf))
               (= (surface-hit-document-offset
                    (command-context-target pointer-observed))
                  1)
               (frontend-cancel-pointer-capture! frontend))
    (error 'kernel-tests
           "frontend pointer hit did not target its rendered Window"
           pointer-observed
           renders
           (map editor-condition-value
                (condition-service-entries (host-state-conditions host)))))
  (dispatch-input! (make-pointer-event 0 1 'left 0 1 'press))
  (let ([state-before-frame (view-state view)])
    (dispatcher-dispatch-view!
      (host-state-dispatch host)
      (make-view-transaction-spec
        (view-id view) (view-state-generation state-before-frame)
        (make-selection (list (make-selection-range 3 3)))
        #f #f '() '() #f)))
  (frontend-step! frontend)
  (dispatch-input! (make-pointer-event 0 2 'left 0 0 'move))
  (unless (and (= (surface-hit-document-offset
                    (command-context-target pointer-observed))
                  2)
               (= (surface-hit-window-id
                    (command-context-target pointer-observed))
                  (window-id leaf)))
    (error 'kernel-tests
           "pointer capture did not route motion through the captured Window"
           (and pointer-observed
                (surface-hit-document-offset
                  (command-context-target pointer-observed)))
           (and pointer-observed
                (surface-hit-window-id
                  (command-context-target pointer-observed)))))
  (dispatch-input! (make-pointer-event 0 200 'left 0 1 'release))
  (unless (not (frontend-cancel-pointer-capture! frontend))
    (error 'kernel-tests "pointer release retained capture"))
  (dispatch-input! (make-pointer-event 0 1 'left 0 1 'press))
  (frontend-enqueue!
    frontend
    (make-surface-input-message (surface-id surface) event))
  (frontend-step! frontend)
  (frontend-resize! frontend '(60 . 20))
  (unless (not (frontend-cancel-pointer-capture! frontend))
    (error 'kernel-tests "Surface resize retained stale pointer capture"))
  (frontend-step! frontend)
  (frontend-set-theme! frontend alternate-theme)
  (frontend-step! frontend)
  (unless (and observed
               (let ([context (car observed)])
                 (and (= (command-context-surface-id context) (surface-id surface))
                      (= (command-context-window-id context) (window-id leaf))
                      (= (command-context-view-id context) (view-id view))
                      (= (command-context-buffer-id context) (buffer-id buffer))
                      (key-event? (command-context-event context))))
               (eq? (cdr observed) 'frontend)
               (equal? (surface-size surface) '(60 . 20))
               (eq? presented-theme alternate-theme)
               (>= renders 3))
    (error 'kernel-tests "frontend orchestration did not route input and rendering"))
  ;; HostState owns routing for its shared runtime.  Advancing one frontend
  ;; may execute another Surface's action, but must deliver it to that
  ;; Surface's input handler and completion cycle.
  (let* ([second-leaf (make-leaf-window (view-id view) #f)]
         [second-surface (make-surface 'terminal '() second-leaf '(40 . 10))]
         [_registered
          (surface-service-register! (host-state-surfaces host) second-surface)]
         [second-renders 0]
         [second-frontend
          (make-frontend
            host second-surface
            (lambda (active active-view)
              (make-input-context
                (active-context-view-id active)
                (active-context-buffer-id active)
                (list (make-input-layer 'global keymap #f 'ignore))
                (view-state-input-state (view-state active-view))))
            (lambda (context disposition) #f)
            (lambda (render theme)
              (set! second-renders (+ second-renders 1)))
            (make-render-service) default-theme)])
    (frontend-step! second-frontend)
    (set! observed #f)
    (frontend-enqueue!
      second-frontend
      (make-surface-input-message (surface-id second-surface) event))
    (frontend-step! frontend)
    (frontend-step! second-frontend)
    (unless (and observed
                 (= (command-context-surface-id (car observed))
                    (surface-id second-surface))
                 (> second-renders 0))
      (error 'kernel-tests
             "shared runtime did not route input to its owning Surface"))
    (frontend-close! second-frontend)
    (surface-service-remove!
      (host-state-surfaces host) (surface-id second-surface)))
  (frontend-close! frontend)
  (owner-close! package-owner))

(let* ([application (make-soda-application)]
       [state (soda-application-state application)]
       [runtime (host-state-command-runtime state)]
       [processes (soda-application-processes application)]
       [native-runtime (native:make-runtime)])
  (dynamic-wind
    (lambda () #f)
    (lambda ()
      (process-service-attach-runtime! processes native-runtime)
      (let ([invocation
             (command-runtime-start!
               runtime 'process.execute (application-command-context application)
               (list "printf soda-process-output"))])
        (unless (eq? (command-invocation-phase invocation) 'completed)
          (error 'kernel-tests "process command did not complete its effect")))
      (let poll ([remaining 4])
        (let* ([events (native:runtime-poll! native-runtime)]
               [_handled
                (for-each
                  (lambda (event)
                    (process-service-handle-runtime-event! processes event))
                  events)]
               [active
                (surface-active-context (soda-application-surface application)
                                        (host-state-views state))]
               [buffer
                (buffer-service-ref (host-state-buffers state)
                                    (active-context-buffer-id active) #f)]
               [output (and buffer (buffer-string buffer))])
          (cond
            [(and buffer
                  (string=? (buffer-name buffer) "*command: printf soda-process-output*")
                  (string=? output
                            "soda-process-output\n[Process exited with status 0]\n"))
             #t]
            [(zero? remaining)
             (error 'kernel-tests "process output Buffer did not receive complete process output"
                    output)]
            [else (poll (- remaining 1))])))
      ;; Generic ProcessJob supplies finite stdin and callbacks without making
      ;; an output Buffer the process package's only consumer.  Tool packages
      ;; such as spelling and formatting can parse their own protocol here.
      (let ([output ""]
            [exit-status #f])
        (process-service-run!
          processes
          (make-process-job
            (list "/bin/cat") "" (string->utf8 "soda-process-input")
            (lambda (event)
              (set! output
                    (string-append output (utf8->string (native:event-data event)))))
            (lambda (status flags)
              (set! exit-status status))))
        (let poll ([remaining 4])
          (for-each
            (lambda (event) (process-service-handle-runtime-event! processes event))
            (native:runtime-poll! native-runtime))
          (cond
            [(and exit-status (zero? exit-status))
             (unless (string=? output "soda-process-input")
               (error 'kernel-tests "generic process job did not receive stdout" output))]
            [(zero? remaining)
             (error 'kernel-tests "generic process job did not exit" exit-status)]
            [else (poll (- remaining 1))]))))
    (lambda ()
      (native:runtime-close! native-runtime)
      (soda-application-close! application))))

(let* ([application (make-soda-application)]
       [state (soda-application-state application)]
       [runtime (host-state-command-runtime state)]
       [processes (soda-application-processes application)]
       [spelling (soda-application-spelling application)]
       [source-view-id (view-id (soda-application-view application))]
       [navigation-scroll #f]
       [_navigation-listener
        (host-frontend-add-update-listener!
          state
          (lambda (update)
            (when (editor-update-scroll-request update)
              (set! navigation-scroll
                    (editor-update-scroll-request update)))))]
       [native-runtime (native:make-runtime)])
  (dynamic-wind
    (lambda () #f)
    (lambda ()
      (process-service-attach-runtime! processes native-runtime)
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "helo\n")))
      (let ([invocation
             (command-runtime-start!
               runtime 'spell.check (application-command-context application))])
        (unless (eq? (command-invocation-phase invocation) 'completed)
          (error 'kernel-tests "spell command did not complete its effect")))
      (let poll ([remaining 4])
        (for-each
          (lambda (event) (process-service-handle-runtime-event! processes event))
          (native:runtime-poll! native-runtime))
        (let* ([active
                (surface-active-context (soda-application-surface application)
                                        (host-state-views state))]
               [buffer
                (buffer-service-ref (host-state-buffers state)
                                    (active-context-buffer-id active) #f)]
               [output (and buffer (buffer-string buffer))])
          (cond
            [(and buffer
                  (string=? (buffer-name buffer) "*Spelling: *scratch**")
                  (or (string-contains? output "Line 1: & helo")
                      (string-contains? output "Hunspell exited with status")))
             (unless
               (eq? (keymap-lookup
                      (spell-keymap spelling)
                      (list (make-key-stroke 'character (char->integer #\t) 4)))
                     'spell.check)
               (error 'kernel-tests "spell keymap did not bind C-t"))
             (let ([rejected?
                    (guard (condition [else #t])
                      (command-runtime-start!
                        runtime 'fundamental.insert-text
                        (application-command-context application)
                        (list (string->utf8 "must-not-edit")))
                      #f)])
               (unless (and rejected? (string=? output (buffer-string buffer)))
                 (error 'kernel-tests
                        "spell result mode exposed an editing command")))
             (when (string-contains? output "Line 1: & helo")
               (let* ([item-ranges (buffer-item-ranges (buffer-state buffer))]
                      [item-range (and (pair? item-ranges)
                                       (pair? (range-set-ranges (car item-ranges)))
                                       (car (range-set-ranges (car item-ranges))))])
                 (unless item-range
                   (error 'kernel-tests "spell report did not expose a navigable finding"))
                 (let* ([report-active
                         (surface-active-context (soda-application-surface application)
                                                 (host-state-views state))]
                        [report-view
                         (view-service-ref (host-state-views state)
                                           (active-context-view-id report-active))])
                   (dispatcher-dispatch-view!
                     (host-state-dispatch state)
                     (make-view-transaction-spec
                       (view-id report-view) (view-state-generation (view-state report-view))
                       (make-selection
                         (list (make-selection-range (range-value-from item-range)
                                                     (range-value-from item-range))))
                       #f #f '() '() #f)))
                 (command-runtime-start!
                   runtime 'buffer.activate-item (application-command-context application))
                 (let* ([source-active
                         (surface-active-context (soda-application-surface application)
                                                 (host-state-views state))]
                        [source-view
                         (view-service-ref (host-state-views state)
                                           (active-context-view-id source-active))]
                        [source-selection
                         (selection-primary-range
                           (view-state-selection (view-state source-view)))])
                   (unless (and (= (buffer-id (view-buffer source-view))
                                   (buffer-id (soda-application-buffer application)))
                                (= (view-id source-view) source-view-id)
                                (= (selection-range-head source-selection) 0)
                                (scroll-request? navigation-scroll)
                                (eq? (scroll-request-kind navigation-scroll)
                                     'reveal-point)
                                (= (scroll-request-view-id navigation-scroll)
                                   source-view-id))
                     (error 'kernel-tests
                            "spell finding activation did not restore the source View and location")))))]
            [(zero? remaining)
             (error 'kernel-tests "spell check did not display a parsed report" output)]
            [else (poll (- remaining 1))]))))
    (lambda ()
      (native:runtime-close! native-runtime)
      (soda-application-close! application))))

;; Buffer-local help input must outrank the fundamental global binding: C-g
;; closes help instead of reopening it.
(let* ([application (make-soda-application)]
       [state (soda-application-state application)]
       [runtime (host-state-command-runtime state)])
  (dynamic-wind
    (lambda () #f)
    (lambda ()
      (command-runtime-start! runtime 'help.show (application-command-context application))
      (let* ([surface (soda-application-surface application)]
             [active (surface-active-context surface (host-state-views state))]
             [view (view-service-ref (host-state-views state) (active-context-view-id active))]
             [context
              (buffer-input-context
                active view
                (list (fundamental-fallback-input-layer
                        (soda-application-editing application))))]
             [disposition
              (input-dispatch
                context
                (make-key-event
                  'character (char->integer #\g) #f #f 4 'press (make-bytevector 0)))]
             [text-disposition
              (input-dispatch context
                              (make-text-input-event 'text (string->utf8 "x")))])
        (unless (and (eq? (input-disposition-kind disposition) 'command)
                     (eq? (input-disposition-value disposition) 'buffer.close)
                     (eq? (input-disposition-kind text-disposition) 'pass))
          (error 'kernel-tests "help Buffer did not override C-g with close"))))
    (lambda () (soda-application-close! application))))

;; A semantic spelling item can carry immutable target data through an
;; interactive prompt.  The prompt answer is applied only to the exact source
;; revision that Hunspell inspected.
(let* ([application (make-soda-application)]
       [state (soda-application-state application)]
       [runtime (host-state-command-runtime state)]
       [processes (soda-application-processes application)]
       [interactions (soda-application-interaction application)]
       [native-runtime (native:make-runtime)])
  (dynamic-wind
    (lambda () #f)
    (lambda ()
      (process-service-attach-runtime! processes native-runtime)
      (command-runtime-start!
        runtime 'fundamental.insert-text (application-command-context application)
        (list (string->utf8 "helo\n")))
      (command-runtime-start!
        runtime 'spell.check (application-command-context application))
      (let poll ([remaining 4])
        (for-each
          (lambda (event) (process-service-handle-runtime-event! processes event))
          (native:runtime-poll! native-runtime))
        (let* ([active
                (surface-active-context (soda-application-surface application)
                                        (host-state-views state))]
               [report-view
                (view-service-ref (host-state-views state) (active-context-view-id active))]
               [report-buffer (view-buffer report-view)]
               [output (buffer-string report-buffer)])
          (cond
            [(and (string=? (buffer-name report-buffer) "*Spelling: *scratch**")
                  (or (string-contains? output "Line 1: & helo")
                      (string-contains? output "Hunspell exited with status")))
             (when (string-contains? output "Line 1: & helo")
               (let* ([ranges (buffer-item-ranges (buffer-state report-buffer))]
                      [item-range (and (pair? ranges)
                                       (pair? (range-set-ranges (car ranges)))
                                       (car (range-set-ranges (car ranges))))])
                 (unless item-range
                   (error 'kernel-tests "spell correction report has no item"))
                 (dispatcher-dispatch-view!
                   (host-state-dispatch state)
                   (make-view-transaction-spec
                     (view-id report-view) (view-state-generation (view-state report-view))
                     (make-selection
                       (list (make-selection-range (range-value-from item-range)
                                                   (range-value-from item-range))))
                     #f #f '() '() #f))
                 (command-runtime-start!
                   runtime 'spell.correct-item (application-command-context application))
                 (host-state-run! state)
                 (unless (interaction-service-current interactions)
                   (error 'kernel-tests "spell correction did not request a replacement"))
                 (interaction-service-submit! interactions "hello")
                 (host-state-run! state)
                 (unless (string=? (buffer-string (soda-application-buffer application)) "hello\n")
                   (error 'kernel-tests "spell correction did not replace the source word"))))]
            [(zero? remaining)
             (error 'kernel-tests "spell correction did not display a report" output)]
            [else (poll (- remaining 1))]))))
    (lambda ()
      (native:runtime-close! native-runtime)
      (soda-application-close! application))))

(run-fundamental-editing-tests!)
(run-file-state-tests!)
(run-buffer-ui-tests!)
(run-host-integration-tests!)
(run-terminal-clipboard-tests!)
(run-command-loop-tests!)
(run-view-presentation-tests!)
(host-state-close! host)
