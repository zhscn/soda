#!r6rs
(import (rnrs)
        (only (chezscheme) getenv)
        (soda build scheme-interface)
        (soda editor scheme-interface-index))

(define source-root
  (getenv "SODA_SCHEME_INTERFACE_BUILD_SOURCE"))
(define object-root
  (getenv "SODA_SCHEME_INTERFACE_BUILD_OBJECT"))
(define program-source
  (string-append source-root "/main.ss"))
(define program-object
  (string-append object-root "/main.so"))
(define interface-output
  (string-append object-root "/interfaces.fasl"))

(define (string-prefix? prefix value)
  (let ([length (string-length prefix)])
    (and
      (<= length (string-length value))
      (string=?
        prefix
        (substring value 0 length)))))

(compile-scheme-program-with-interface!
  "fixture"
  #f
  program-source
  program-object
  interface-output
  (list (cons source-root object-root)))

(define index
  (call-with-port
    (open-file-input-port interface-output)
    (lambda (port)
      (scheme-interface-index-decode
        (get-bytevector-all port)))))

(unless
  (and
    (string=? (scheme-interface-index-owner index) "fixture")
    (string-prefix?
      "fnv1a64:"
      (scheme-interface-index-revision index))
    (member
      '(fixture scheme-interface-build dependency)
      (scheme-interface-index-libraries index))
    (exists
      (lambda (entry)
        (and
          (string=? (list-ref entry 0) "fixture-value")
          (equal?
            (list-ref entry 2)
            '(fixture scheme-interface-build dependency))
          (string=?
            (list-ref entry 3)
            (string-append
              source-root
              "/fixture/scheme-interface-build/dependency.sls"))))
      (scheme-interface-index-entries index))
    (exists
      (lambda (reference)
        (and
          (string=?
            (list-ref reference 0)
            program-source)
          (string=?
            (list-ref reference 2)
            "fixture-value")
          (exists
            (lambda (resolution)
              (and
                (eq? (list-ref resolution 0) 'index)
                (string=?
                  (list-ref resolution 1)
                  (string-append
                    source-root
                    "/fixture/scheme-interface-build/dependency.sls"))
                (string=?
                  (list-ref resolution 4)
                  "fixture-value")))
            (list-ref reference 5))))
      (scheme-interface-index-references index))
    (exists
      (lambda (reference)
        (and
          (string=?
            (list-ref reference 2)
            "public-fixture-value")
          (exists
            (lambda (resolution)
              (string=?
                (list-ref resolution 4)
                "public-fixture-value"))
            (list-ref reference 5))))
      (scheme-interface-index-references index))
    (exists
      (lambda (diagnostic)
        (and
          (string=?
            (list-ref diagnostic 0)
            (string-append
              source-root
              "/fixture/scheme-interface-build/dependency.sls"))
          (eq?
            (list-ref diagnostic 2)
            'unused-parameter)
          (string=?
            (list-ref diagnostic 7)
            "  (define (unused-helper ignored)")))
      (scheme-interface-index-diagnostics index)))
  (assertion-violation
    'scheme-interface-build-tests
    "compiled sources were not represented in the interface artifact"
    index))

(define explicit-output
  (string-append object-root "/explicit-interfaces.fasl"))
(define result
  (call-with-scheme-interface-build
    (make-scheme-interface-build
      "fixture-explicit"
      "build-17"
      (list source-root)
      (list
        (string-append
          source-root
          "/fixture/scheme-interface-build/dependency.sls"))
      explicit-output)
    (lambda () 'compiled)))

(unless (eq? result 'compiled)
  (assertion-violation
    'scheme-interface-build-tests
    "build wrapper did not preserve the build result"
    result))

(define explicit-index
  (call-with-port
    (open-file-input-port explicit-output)
    (lambda (port)
      (scheme-interface-index-decode
        (get-bytevector-all port)))))

(unless
  (and
    (string=?
      (scheme-interface-index-owner explicit-index)
      "fixture-explicit")
    (string=?
      (scheme-interface-index-revision explicit-index)
      "build-17")
    (exists
      (lambda (entry)
        (string=? (list-ref entry 0) "fixture-value"))
      (scheme-interface-index-entries explicit-index)))
  (assertion-violation
    'scheme-interface-build-tests
    "explicit build metadata was not preserved"
    explicit-index))

(define failed-output
  (string-append object-root "/failed-interfaces.fasl"))
(when (file-exists? failed-output)
  (delete-file failed-output))

(define failed?
  (guard
    (condition [else #t])
    (call-with-scheme-interface-build
      (make-scheme-interface-build
        "fixture-failed"
        #f
        (list source-root)
        (list program-source)
        failed-output)
      (lambda ()
        (assertion-violation
          'scheme-interface-build-tests
          "expected build failure")))
    #f))

(unless
  (and failed? (not (file-exists? failed-output)))
  (assertion-violation
    'scheme-interface-build-tests
    "a failed build published an interface artifact"))
