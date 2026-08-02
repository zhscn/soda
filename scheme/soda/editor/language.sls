(library (soda editor language)
  (export make-syntax-provider
          syntax-provider?
          syntax-capabilities
          syntax-open
          syntax-sync!
          syntax-view
          syntax-highlights
          syntax-query
          syntax-close-view!
          syntax-close!
          make-syntax-capture
          syntax-capture?
          syntax-capture-name
          syntax-capture-start
          syntax-capture-end
          syntax-capture-node-kind
          syntax-capture-properties
          syntax-capture-depth
          make-language-profile
          language-profile?
          language-profile-name
          language-profile-syntax
          language-profile-indent
          language-profile-pairs
          language-profile-lexical
          language-profile-word-motion
          language-profile-structure
          language-profile-electric
          language-profile-enter
          language-profile-bootstrap
          make-language-catalog
          language-catalog?
          language-catalog-snapshot
          language-catalog-restore!
          default-language-catalog
          register-language-profile!
          find-language-profile
          language-profile-ref
          make-major-mode
          major-mode?
          major-mode-name
          major-mode-parent
          major-mode-language
          major-mode-interaction-class
          major-mode-keymap
          major-mode-default-settings
          major-mode-features
          register-major-mode!
          find-major-mode
          major-mode-ref
          resolve-major-mode-language
          resolve-major-mode-interaction-class
          major-mode-keymaps
          major-mode-setting-ref
          major-mode-feature-ref
          major-mode-syntax-capabilities)
  (import (rnrs)
          (soda editor contract)
          (soda editor hashtable-state)
          (soda document)
          (soda editor decoration)
          (soda editor indentation-protocol)
          (soda editor motion-protocol)
          (soda editor scheme-highlighting)
          (soda editor scheme-indentation-provider)
          (soda editor scheme-structure)
          (soda editor structure))

  (define-record-type (syntax-provider %make-syntax-provider syntax-provider?)
    (fields
      (immutable capabilities syntax-provider-capabilities)
      (immutable open syntax-provider-open)
      (immutable sync syntax-provider-sync)
      (immutable view syntax-provider-view)
      (immutable close-view syntax-provider-close-view)
      (immutable highlights syntax-provider-highlights)
      (immutable query syntax-provider-query)
      (immutable close syntax-provider-close)))

  (define-record-type
    (syntax-capture %make-syntax-capture syntax-capture?)
    (fields name start end node-kind properties depth))

  (define (make-syntax-capture
            name start end node-kind properties depth)
    (unless
      (and
        (symbol? name)
        (exact-non-negative-integer? start)
        (exact-non-negative-integer? end)
        (<= start end)
        (or (not node-kind) (symbol? node-kind) (string? node-kind))
        (list? properties)
        (exact-non-negative-integer? depth))
      (assertion-violation
        'make-syntax-capture
        "invalid syntax capture"
        name start end node-kind properties depth))
    (%make-syntax-capture name start end node-kind properties depth))

  (define make-syntax-provider
    (case-lambda
      [(capabilities open sync close)
       (make-syntax-provider
         capabilities open sync #f #f #f #f close)]
      [(capabilities open sync view close)
       (make-syntax-provider
         capabilities open sync view #f #f #f close)]
      [(capabilities open sync view close-view close)
       (make-syntax-provider
         capabilities open sync view close-view #f #f close)]
      [(capabilities open sync view close-view highlights close)
       (make-syntax-provider
         capabilities
         open
         sync
         view
         close-view
         highlights
         #f
         close)]
      [(capabilities
         open
         sync
         view
         close-view
         highlights
         query
         close)
       (unless (and (list? capabilities) (for-all symbol? capabilities))
         (assertion-violation
           'make-syntax-provider
           "capabilities must be a list of symbols"
           capabilities))
       (unless (procedure? open)
         (assertion-violation 'make-syntax-provider "open must be a procedure" open))
       (unless (procedure? sync)
         (assertion-violation 'make-syntax-provider "sync must be a procedure" sync))
       (unless (or (not view) (procedure? view))
         (assertion-violation
           'make-syntax-provider
           "view must be a procedure or #f"
           view))
       (unless (or (not close-view) (procedure? close-view))
         (assertion-violation
           'make-syntax-provider
           "close-view must be a procedure or #f"
           close-view))
       (unless (or (not highlights) (procedure? highlights))
         (assertion-violation
           'make-syntax-provider
           "highlights must be a procedure or #f"
           highlights))
       (unless (or (not query) (procedure? query))
         (assertion-violation
           'make-syntax-provider
           "query must be a procedure or #f"
           query))
       (unless (procedure? close)
         (assertion-violation 'make-syntax-provider "close must be a procedure" close))
       (%make-syntax-provider
         capabilities
         open
         sync
         view
         close-view
         highlights
         query
         close)]))

  (define (require-syntax-provider who provider)
    (unless (syntax-provider? provider)
      (assertion-violation who "expected a syntax provider" provider)))

  (define (syntax-capabilities provider)
    (require-syntax-provider 'syntax-capabilities provider)
    (syntax-provider-capabilities provider))

  (define (syntax-open provider snapshot)
    (require-syntax-provider 'syntax-open provider)
    ((syntax-provider-open provider) snapshot))

  (define (syntax-sync! provider session change snapshot)
    (require-syntax-provider 'syntax-sync! provider)
    ((syntax-provider-sync provider) session change snapshot))

  (define (syntax-view provider session snapshot pending-edits)
    (require-syntax-provider 'syntax-view provider)
    (let ([view (syntax-provider-view provider)])
      (and view (view session snapshot pending-edits))))

  (define (syntax-highlights provider session start end)
    (require-syntax-provider 'syntax-highlights provider)
    (unless
      (and
        (integer? start)
        (exact? start)
        (integer? end)
        (exact? end)
        (<= 0 start end))
      (assertion-violation
        'syntax-highlights
        "invalid syntax highlight range"
        start
        end))
    (let ([highlights (syntax-provider-highlights provider)])
      (if (not highlights)
          #f
          (let ([runs (highlights session start end)])
            (unless
              (and (list? runs) (for-all decoration-run? runs))
              (assertion-violation
                'syntax-highlights
                "syntax provider returned invalid highlight runs"
                runs))
            runs))))

  (define (syntax-query provider session query-name start end)
    (require-syntax-provider 'syntax-query provider)
    (unless (symbol? query-name)
      (assertion-violation
        'syntax-query
        "query name must be a symbol"
        query-name))
    (unless
      (and
        (exact-non-negative-integer? start)
        (exact-non-negative-integer? end)
        (<= start end))
      (assertion-violation
        'syntax-query
        "invalid syntax query range"
        start
        end))
    (let ([query (syntax-provider-query provider)])
      (if (not query)
          #f
          (let ([captures (query session query-name start end)])
            (unless
              (and (list? captures) (for-all syntax-capture? captures))
              (assertion-violation
                'syntax-query
                "syntax provider returned invalid captures"
                captures))
            captures))))

  (define (syntax-close-view! provider view)
    (require-syntax-provider 'syntax-close-view! provider)
    (let ([close-view (syntax-provider-close-view provider)])
      (when (and view close-view)
        (close-view view))))

  (define (syntax-close! provider session)
    (require-syntax-provider 'syntax-close! provider)
    ((syntax-provider-close provider) session))

  (define-record-type
    (language-profile %make-language-profile language-profile?)
    (fields
      (immutable name language-profile-name)
      (immutable syntax language-profile-syntax)
      (immutable indent language-profile-indent)
      (immutable pairs language-profile-pairs)
      (immutable lexical language-profile-lexical)
      (immutable word-motion language-profile-word-motion)
      (immutable structure language-profile-structure)
      (immutable electric language-profile-electric)
      (immutable enter language-profile-enter)
      (immutable bootstrap language-profile-bootstrap)))

  (define make-language-profile
    (case-lambda
      [(name syntax)
       (make-language-profile
         name syntax #f '() #f #f #f '() #f #f)]
      [(name syntax indent pairs lexical structure electric enter)
       (make-language-profile
         name syntax indent pairs lexical #f structure electric enter #f)]
      [(name syntax indent pairs lexical word-motion structure electric enter)
       (make-language-profile
         name syntax indent pairs lexical word-motion structure electric enter #f)]
      [(name
         syntax
         indent
         pairs
         lexical
         word-motion
         structure
         electric
         enter
         bootstrap)
       (unless (symbol? name)
         (assertion-violation
           'make-language-profile
           "name must be a symbol"
           name))
       (unless (or (not syntax) (syntax-provider? syntax))
         (assertion-violation
           'make-language-profile
           "syntax must be a syntax provider or #f"
           syntax))
       (unless
         (or (not indent) (indentation-provider? indent))
         (assertion-violation
           'make-language-profile
           "indent must be an indentation provider or #f"
           indent))
      (unless (list? pairs)
        (assertion-violation 'make-language-profile "pairs must be a list" pairs))
      (unless (or (not lexical) (procedure? lexical))
        (assertion-violation
          'make-language-profile
          "lexical policy must be a procedure or #f"
          lexical))
       (unless (or (not word-motion) (word-motion? word-motion))
         (assertion-violation
           'make-language-profile
           "word motion must be a word-motion or #f"
           word-motion))
       (unless
         (or (not structure) (structure-provider? structure))
         (assertion-violation
           'make-language-profile
           "structure must be a structure provider or #f"
           structure))
       (unless (and (list? electric) (for-all char? electric))
         (assertion-violation
           'make-language-profile
           "electric must be a list of characters"
           electric))
       (unless (or (not enter) (procedure? enter))
         (assertion-violation
           'make-language-profile
           "enter must be a procedure or #f"
           enter))
       (unless (or (not bootstrap) (procedure? bootstrap))
         (assertion-violation
           'make-language-profile
           "bootstrap must be a procedure or #f"
           bootstrap))
       (%make-language-profile
         name
         syntax
         indent
         pairs
         lexical
         word-motion
         structure
         electric
         enter
         bootstrap)]))

  (define-record-type (major-mode %make-major-mode major-mode?)
    (fields
      (immutable name major-mode-name)
      (immutable parent major-mode-parent)
      (immutable language major-mode-language)
      (immutable interaction-class major-mode-interaction-class)
      (immutable keymap major-mode-keymap)
      (immutable default-settings major-mode-default-settings)
      (immutable features major-mode-features)))

  (define-record-type
    (language-catalog %make-language-catalog language-catalog?)
    (fields profiles modes))

  (define-record-type
    (language-catalog-state
      %make-language-catalog-state
      language-catalog-state?)
    (fields profiles modes))

  (define (language-catalog-snapshot catalog)
    (unless (language-catalog? catalog)
      (assertion-violation
        'language-catalog-snapshot
        "expected a language catalog"
        catalog))
    (%make-language-catalog-state
      (hashtable-copy (language-catalog-profiles catalog) #t)
      (hashtable-copy (language-catalog-modes catalog) #t)))

  (define (language-catalog-restore! catalog snapshot)
    (unless (language-catalog? catalog)
      (assertion-violation
        'language-catalog-restore!
        "expected a language catalog"
        catalog))
    (unless (language-catalog-state? snapshot)
      (assertion-violation
        'language-catalog-restore!
        "expected a language catalog snapshot"
        snapshot))
    (replace-hashtable!
      (language-catalog-profiles catalog)
      (language-catalog-state-profiles snapshot))
    (replace-hashtable!
      (language-catalog-modes catalog)
      (language-catalog-state-modes snapshot))
    catalog)

  (define (make-language-catalog)
    (let ([catalog
            (%make-language-catalog
              (make-eq-hashtable)
              (make-eq-hashtable))])
      (hashtable-set!
        (language-catalog-modes catalog)
        'fundamental-mode
        (%make-major-mode
          'fundamental-mode
          #f
          #f
          'editing
          #f
          '()
          '()))
      catalog))

  (define make-major-mode
    (case-lambda
      [(name parent language)
       (make-major-mode name parent language 'editing #f '() '())]
      [(name parent language interaction-class keymap default-settings)
       (make-major-mode
         name
         parent
         language
         interaction-class
         keymap
         default-settings
         '())]
      [(name
         parent
         language
         interaction-class
         keymap
         default-settings
         features)
       (unless (symbol? name)
         (assertion-violation 'make-major-mode "name must be a symbol" name))
       (unless (or (not parent) (symbol? parent))
         (assertion-violation
           'make-major-mode
           "parent must be a symbol or #f"
           parent))
       (unless (or (not language) (symbol? language))
         (assertion-violation
           'make-major-mode
           "language must be a symbol or #f"
           language))
       (unless (memq interaction-class '(editing interface inherit))
         (assertion-violation
           'make-major-mode
           "interaction class must be editing, interface, or inherit"
           interaction-class))
       (unless (or (not keymap) (symbol? keymap))
         (assertion-violation
           'make-major-mode
           "keymap must be a symbol or #f"
           keymap))
       (unless (and (list? default-settings)
                    (for-all (lambda (entry)
                               (and (pair? entry) (symbol? (car entry))))
                             default-settings))
         (assertion-violation
           'make-major-mode
           "default settings must be an alist with symbol keys"
           default-settings))
       (unless (and (list? features)
                    (for-all
                      (lambda (entry)
                        (and (pair? entry) (symbol? (car entry))))
                      features))
         (assertion-violation
           'make-major-mode
           "features must be an alist with symbol keys"
           features))
       (%make-major-mode
         name
         parent
         language
         interaction-class
         keymap
         default-settings
         features)]))

  (define default-language-catalog (make-language-catalog))

  (define register-language-profile!
    (case-lambda
      [(profile)
       (register-language-profile!
         default-language-catalog
         profile)]
      [(catalog profile)
       (unless (language-catalog? catalog)
         (assertion-violation
           'register-language-profile!
           "expected a language catalog"
           catalog))
       (unless (language-profile? profile)
         (assertion-violation
           'register-language-profile!
           "expected a language profile"
           profile))
       (hashtable-set!
         (language-catalog-profiles catalog)
         (language-profile-name profile)
         profile)
       profile]))

  (define find-language-profile
    (case-lambda
      [(name)
       (find-language-profile default-language-catalog name)]
      [(catalog name)
       (unless (language-catalog? catalog)
         (assertion-violation
           'find-language-profile
           "expected a language catalog"
           catalog))
       (unless (symbol? name)
         (assertion-violation
           'find-language-profile
           "name must be a symbol"
           name))
       (hashtable-ref (language-catalog-profiles catalog) name #f)]))

  (define language-profile-ref
    (case-lambda
      [(name)
       (language-profile-ref default-language-catalog name)]
      [(catalog name)
       (or (find-language-profile catalog name)
           (assertion-violation
             'language-profile-ref
             "unknown language profile"
             name))]))

  (define register-major-mode!
    (case-lambda
      [(mode)
       (register-major-mode! default-language-catalog mode)]
      [(catalog mode)
       (unless (language-catalog? catalog)
         (assertion-violation
           'register-major-mode!
           "expected a language catalog"
           catalog))
       (unless (major-mode? mode)
         (assertion-violation
           'register-major-mode!
           "expected a major mode"
           mode))
       (hashtable-set!
         (language-catalog-modes catalog)
         (major-mode-name mode)
         mode)
       mode]))

  (define find-major-mode
    (case-lambda
      [(name) (find-major-mode default-language-catalog name)]
      [(catalog name)
       (unless (language-catalog? catalog)
         (assertion-violation
           'find-major-mode
           "expected a language catalog"
           catalog))
       (unless (symbol? name)
         (assertion-violation
           'find-major-mode
           "name must be a symbol"
           name))
       (hashtable-ref (language-catalog-modes catalog) name #f)]))

  (define major-mode-ref
    (case-lambda
      [(name) (major-mode-ref default-language-catalog name)]
      [(catalog name)
       (or (find-major-mode catalog name)
           (assertion-violation
             'major-mode-ref
             "unknown major mode"
             name))]))

  (define (mode-chain-fold who catalog name visit seed)
    (let loop ([name name] [seen '()] [state seed])
      (when (memq name seen)
        (assertion-violation who "major mode parent cycle" name))
      (let* ([mode (major-mode-ref catalog name)]
             [next-state (visit mode state)]
             [parent (major-mode-parent mode)])
        (if parent
            (loop parent (cons name seen) next-state)
            next-state))))

  (define resolve-major-mode-language
    (case-lambda
      [(name)
       (resolve-major-mode-language default-language-catalog name)]
      [(catalog name)
       (call/cc
         (lambda (return)
           (mode-chain-fold
             'resolve-major-mode-language
             catalog
             name
             (lambda (mode state)
               (let ([language (major-mode-language mode)])
                 (if (eq? language 'inherit)
                     state
                     (return language))))
             #f)))]))

  (define major-mode-keymaps
    (case-lambda
      [(name) (major-mode-keymaps default-language-catalog name)]
      [(catalog name)
       (reverse
         (mode-chain-fold
           'major-mode-keymaps
           catalog
           name
           (lambda (mode keymaps)
             (let ([keymap (major-mode-keymap mode)])
               (if keymap (cons keymap keymaps) keymaps)))
           '()))]))

  (define resolve-major-mode-interaction-class
    (case-lambda
      [(name)
       (resolve-major-mode-interaction-class
         default-language-catalog
         name)]
      [(catalog name)
       (call/cc
         (lambda (return)
           (mode-chain-fold
             'resolve-major-mode-interaction-class
             catalog
             name
             (lambda (mode state)
               (let ([interaction
                       (major-mode-interaction-class mode)])
                 (if (eq? interaction 'inherit)
                     state
                     (return interaction))))
             'editing)))]))

  (define major-mode-setting-ref
    (case-lambda
      [(name key default)
       (major-mode-setting-ref
         default-language-catalog
         name
         key
         default)]
      [(catalog name key default)
       (unless (symbol? key)
         (assertion-violation
           'major-mode-setting-ref
           "key must be a symbol"
           key))
       (call/cc
         (lambda (return)
           (mode-chain-fold
             'major-mode-setting-ref
             catalog
             name
             (lambda (mode state)
               (let ([entry
                       (assq key
                         (major-mode-default-settings mode))])
                 (if entry (return (cdr entry)) state)))
             default)))]))

  (define major-mode-feature-ref
    (case-lambda
      [(name key default)
       (major-mode-feature-ref
         default-language-catalog
         name
         key
         default)]
      [(catalog name key default)
       (unless (symbol? key)
         (assertion-violation
           'major-mode-feature-ref
           "key must be a symbol"
           key))
       (call/cc
         (lambda (return)
           (mode-chain-fold
             'major-mode-feature-ref
             catalog
             name
             (lambda (mode state)
               (let ([entry (assq key (major-mode-features mode))])
                 (if entry (return (cdr entry)) state)))
             default)))]))

  (define major-mode-syntax-capabilities
    (case-lambda
      [(name)
       (major-mode-syntax-capabilities
         default-language-catalog
         name)]
      [(catalog name)
       (let* ([language
                (resolve-major-mode-language catalog name)]
              [profile
                (and language
                     (find-language-profile catalog language))]
              [provider
                (and profile (language-profile-syntax profile))])
         (if provider (syntax-capabilities provider) '()))]))

  (define (scheme-identifier-character? character)
    (and
      (not (char-whitespace? character))
      (not
        (memv
          character
          '(#\( #\) #\[ #\] #\{ #\}
            #\" #\; #\' #\` #\, #\|)))))

  (define (scheme-quoted-identifier-start input point)
    (let loop ([index 0]
               [quoted? #f]
               [start #f]
               [escaped? #f])
      (if (= index point)
          (and quoted? start)
          (let ([character (string-ref input index)])
            (cond
              [escaped?
               (loop (+ index 1) quoted? start #f)]
              [(and quoted? (char=? character #\\))
               (loop (+ index 1) quoted? start #t)]
              [(char=? character #\|)
               (if quoted?
                   (loop (+ index 1) #f #f #f)
                   (loop (+ index 1) #t index #f))]
              [else
               (loop (+ index 1) quoted? start #f)])))))

  (define (scheme-completion-boundaries input point)
    (let ([quoted-start
            (scheme-quoted-identifier-start input point)])
      (if quoted-start
          (cons quoted-start point)
          (let loop ([index point])
            (if
              (and
                (positive? index)
                (scheme-identifier-character?
                  (string-ref input (- index 1))))
              (loop (- index 1))
              (cons index point))))))

  (define-record-type
    (scheme-syntax-session
      %make-scheme-syntax-session
      scheme-syntax-session?)
    (fields
      document-id
      (mutable revision
               scheme-syntax-session-revision
               scheme-syntax-session-revision-set!)
      (mutable highlights
               scheme-syntax-session-highlights
               scheme-syntax-session-highlights-set!)))

  (define (scheme-highlight-index snapshot)
    (let ([text (snapshot-text snapshot)])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (make-decoration-index
            (scheme-highlight-runs
              (snapshot-document-id snapshot)
              (snapshot-revision snapshot)
              (text->bytevector text)
              0
              (text-size text))))
        (lambda () (text-close! text)))))

  (define (open-scheme-syntax-session snapshot)
    (%make-scheme-syntax-session
      (snapshot-document-id snapshot)
      (snapshot-revision snapshot)
      (scheme-highlight-index snapshot)))

  (define (sync-scheme-syntax-session! session change snapshot)
    (unless (scheme-syntax-session? session)
      (assertion-violation
        'sync-scheme-syntax-session!
        "expected a Scheme syntax session"
        session))
    (unless
      (and
        (= (scheme-syntax-session-document-id session)
           (snapshot-document-id snapshot))
        (= (scheme-syntax-session-revision session)
           (change-old-revision change))
        (= (change-new-revision change)
           (snapshot-revision snapshot)))
      (assertion-violation
        'sync-scheme-syntax-session!
        "Scheme syntax session revision differs from change"
        (scheme-syntax-session-revision session)
        (change-old-revision change)
        (change-new-revision change)
        (snapshot-revision snapshot)))
    (scheme-syntax-session-highlights-set!
      session
      (scheme-highlight-index snapshot))
    (scheme-syntax-session-revision-set!
      session
      (snapshot-revision snapshot)))

  (define (scheme-syntax-highlights session start end)
    (unless (scheme-syntax-session? session)
      (assertion-violation
        'scheme-syntax-highlights
        "expected a Scheme syntax session"
        session))
    (decoration-index-runs-in-range
      (scheme-syntax-session-highlights session)
      start
      end))

  (define scheme-syntax-provider
    (make-syntax-provider
      '(highlight)
      open-scheme-syntax-session
      sync-scheme-syntax-session!
      #f
      #f
      scheme-syntax-highlights
      (lambda (session) #f)))

  (define scheme-structure-provider
    (make-structure-provider
      (lambda (syntax-session snapshot)
        (make-scheme-structure-index snapshot))))

  (register-major-mode!
    default-language-catalog
    (make-major-mode
      'fundamental-mode #f #f 'editing #f '() '()))

  (register-language-profile!
    default-language-catalog
    (make-language-profile
      'scheme
      scheme-syntax-provider
      scheme-indentation-provider
      '((#\( . #\))
        (#\[ . #\])
        (#\{ . #\}))
      scheme-identifier-character?
      scheme-structure-provider
      '()
      #f))

  (register-major-mode!
    default-language-catalog
    (make-major-mode
      'scheme-mode
      'fundamental-mode
      'scheme
      'editing
      'scheme-mode-map
      (list
        (cons 'comment-line-prefix ";;")
        (cons
          'completion-providers
          '(scheme-static scheme-runtime))
        (cons
          'completion-boundaries
          scheme-completion-boundaries)))))
