(library (soda editor completion-runtime)
  (export install-completion-effect-handlers!)
  (import (rnrs)
          (soda editor completion)
          (soda editor completion-provider)
          (soda editor effect))

  (define (install-completion-effect-handlers! executor catalog)
    (unless (effect-executor? executor)
      (assertion-violation
        'install-completion-effect-handlers!
        "expected an effect executor"
        executor))
    (unless (completion-provider-catalog? catalog)
      (assertion-violation
        'install-completion-effect-handlers!
        "expected a completion provider catalog"
        catalog))
    (register-effect-handler!
      executor
      'completion.request
      (lambda (request)
        (unless (completion-request? request)
          (assertion-violation
            'completion.request
            "expected a completion request"
            request))
        (guard (condition
                 [else
                  (make-effect-result
                    #t
                    (list
                      (make-completion-response-for-request
                        request
                        '()
                        #t)))])
          (make-effect-result
            #t
            (completion-provider-start
              (completion-provider-for-request catalog request)
              request)))))
    (register-effect-handler!
      executor
      'completion.cancel
      (lambda (request)
        (unless (completion-request? request)
          (assertion-violation
            'completion.cancel
            "expected a completion request"
            request))
        (guard (condition [else #f])
          (completion-provider-cancel
            (completion-provider-for-request catalog request)
            request))
        (make-effect-result #t '())))
    executor))
