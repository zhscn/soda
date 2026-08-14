(library (soda packages search internal)
  (export make-search-service!
          search-service?
          search-keymap)
  (import (rnrs)
          (soda kernel change)
          (soda kernel document)
          (soda kernel extension)
          (soda kernel selection)
          (soda kernel state)
          (soda kernel view-state)
          (soda packages base text-motion)
          (soda packages search-keymap)
          (soda packages search-options)
          (soda packages search-matcher)
          (soda packages search-workflow)
          (soda host command)
          (soda host command-runtime)
          (soda host buffer)
          (soda host feedback)
          (soda host operation)
          (soda host package)
          (soda host value)
          (soda host view)
          (soda packages interaction))

  (define install-command!
    (case-lambda
      [(runtime owner name documentation readers procedure)
       (install-command! runtime owner name documentation readers procedure #t)]
      [(runtime owner name documentation readers procedure user-visible?)
       (command-runtime-register-command!
         runtime
         (make-command-definition
           name procedure owner documentation 'search
           (and readers (make-interactive-plan readers))
           'global (make-command-policy) user-visible?))]))

  (define (toggle-case-sensitive context)
    (let* ([state (command-context-view-state context)]
           [enabled? (search-case-sensitive? context)]
           [effect
            (make-compartment-reconfigure-effect
              search-case-sensitive-compartment
              (make-search-case-sensitive-extension (not enabled?)))]
           [update
            (make-view-transaction-spec
              (command-context-view-id context) (view-state-generation state)
              #f #f #f (list effect) '() #f)]
           [surface-id (command-context-surface-id context)])
      (if (and (integer? surface-id) (exact? surface-id) (>= surface-id 0))
          (list update
                (make-set-surface-feedback-operation
                  surface-id
                  (make-user-feedback
                    (string-append "Search is "
                                   (if enabled? "case-insensitive" "case-sensitive")) 'info)))
          update)))

  (define (toggle-whole-word context)
    (let* ([state (command-context-view-state context)]
           [enabled? (search-whole-word? context)]
           [effect
            (make-compartment-reconfigure-effect
              search-whole-word-compartment
              (make-search-whole-word-extension (not enabled?)))]
           [update
            (make-view-transaction-spec
              (command-context-view-id context) (view-state-generation state)
              #f #f #f (list effect) '() #f)]
           [surface-id (command-context-surface-id context)])
      (if (and (integer? surface-id) (exact? surface-id) (>= surface-id 0))
          (list update
                (make-set-surface-feedback-operation
                  surface-id
                  (make-user-feedback
                    (string-append "Search whole-word matching "
                                   (if enabled? "disabled" "enabled")) 'info)))
          update)))

  (define (toggle-regular-expression context)
    (let* ([state (command-context-view-state context)]
           [enabled? (search-regular-expression? context)]
           [effect
            (make-compartment-reconfigure-effect
              search-regular-expression-compartment
              (make-search-regular-expression-extension (not enabled?)))]
           [update
            (make-view-transaction-spec
              (command-context-view-id context) (view-state-generation state)
              #f #f #f (list effect) '() #f)]
           [surface-id (command-context-surface-id context)])
      (if (and (integer? surface-id) (exact? surface-id) (>= surface-id 0))
          (list update
                (make-set-surface-feedback-operation
                  surface-id
                  (make-user-feedback
                    (string-append "Search regular-expression matching "
                                   (if enabled? "disabled" "enabled")) 'info)))
          update)))

  (define (make-search-service! host owner)
    (unless (and (package-host? host) (owner? owner))
      (assertion-violation 'make-search-service! "expected a PackageHost and owner"
                           host owner))
    (let* ([runtime (package-host-command-runtime host)]
           [keymap (make-search-keymap)]
           [service
            (make-search-service-value
              host keymap (make-eqv-hashtable) (make-eqv-hashtable))]
           [forward-reader (make-interaction-string-reader 'search "Search: ")]
           [backward-reader (make-interaction-string-reader 'search "Search backward: ")]
           [replace-reader (make-interaction-string-reader 'search "Replace: ")]
           [decision-reader (make-query-replace-decision-reader)])
      (install-command! runtime owner 'search.forward "Search forward for text."
                        (list forward-reader)
        (lambda (context value)
          (let ([query (remember-query! service context (make-query context value 'forward))])
            (select-match context query #f))))
      (install-command! runtime owner 'search.backward "Search backward for text."
                        (list backward-reader)
        (lambda (context value)
          (let ([query (remember-query! service context (make-query context value 'backward))])
            (select-match context query #f))))
      (install-command! runtime owner 'search.next "Repeat the latest search forward." #f
        (lambda (context)
          (let ([query (remembered-query service context 'forward)])
            (if query (select-match context query #t) (command-handled)))))
      (install-command! runtime owner 'search.previous "Repeat the latest search backward." #f
        (lambda (context)
          (let ([query (remembered-query service context 'backward)])
            (if query (select-match context query #t) (command-handled)))))
      (install-command! runtime owner 'search.toggle-case-sensitive
                        "Toggle case-sensitive matching for new searches in the active View." #f
        (lambda (context) (toggle-case-sensitive context)))
      (install-command! runtime owner 'search.toggle-whole-word
                        "Toggle whole-word matching for new searches in the active View." #f
        (lambda (context) (toggle-whole-word context)))
      (install-command! runtime owner 'search.toggle-regular-expression
                        "Toggle POSIX ERE matching for new searches in the active View." #f
        (lambda (context) (toggle-regular-expression context)))
      (install-command! runtime owner 'search.replace-all "Replace every search match in the active Buffer."
                        (list forward-reader replace-reader)
        (lambda (context value replacement)
          (let ([query (remember-query! service context (make-query context value 'forward))])
            (replace-all context query replacement))))
      (install-command! runtime owner 'search.query-replace
                        "Replace search matches one at a time in the active Buffer."
                        (list forward-reader replace-reader)
        (lambda (context value replacement)
          (let ([session (start-query-replace! service context value replacement)])
            (if session
                (make-command-effect 'search.query-replace.advance session)
                (command-handled)))))
      (install-command! runtime owner 'search.query-replace.decision
                        "Apply the current query replace decision."
                        (list decision-reader)
        (lambda (context value)
          (query-replace-decision! service context value))
        #f)
      (command-runtime-register-effect-handler!
        runtime 'search.query-replace.advance owner 'query-replace-advance
        (lambda (ignored invocation effect)
          (let ([session (command-effect-payload effect)])
            (when (query-replace-session? session)
              (queue-query-replace-decision! service session)))))
      (command-runtime-add-hook!
        runtime 'command-cancel owner 'query-replace-cancel
        (lambda (invocation)
          (when (eq? (command-definition-name (command-invocation-definition invocation))
                     'search.query-replace.decision)
            (let ([session
                   (query-replace-session-for-context
                     service (command-invocation-context invocation))])
              (when session (finish-query-replace! service session))))))
      service))
)
