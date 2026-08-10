(library (soda packages file-policy)
  (export file-backup-enabled?
          file-newline-policy
          file-bom-policy
          file-final-newline-policy
          make-file-backup-extension
          file-backup-compartment
          file-lock-read-only-compartment
          register-file-settings!)
  (import (rnrs)
          (soda kernel extension)
          (soda host package)
          (soda host setting))

  ;; Backups are a Buffer policy: visiting the same file through another View
  ;; observes the same save behavior, while an unrelated Buffer retains its
  ;; own choice.  The VFS remains unaware of backup naming or retention.
  (define (first-value values default)
    (if (null? values) default (car values)))

  (define file-backup-facet
    (make-facet 'file-backup 'buffer #f
                (lambda (values) (first-value values #f)) eq? eq?))

  (define file-backup-compartment (make-compartment 'file-backup 'buffer))

  (define file-newline-facet
    (make-facet 'file-newline 'buffer 'preserve
                (lambda (values) (first-value values 'preserve)) eq? eq?))
  (define file-bom-facet
    (make-facet 'file-bom 'buffer 'preserve
                (lambda (values) (first-value values 'preserve)) eq? eq?))
  (define file-final-newline-facet
    (make-facet 'file-final-newline 'buffer 'preserve
                (lambda (values) (first-value values 'preserve)) eq? eq?))

  ;; A lock conflict is Buffer-local.  The compartment prevents this safety
  ;; policy from leaking into the next file visited from a read-only Buffer.
  (define file-lock-read-only-compartment
    (make-compartment 'file-lock-read-only 'buffer))

  (define (file-backup-enabled? configuration)
    (configuration-facet configuration file-backup-facet 'buffer))

  (define (file-newline-policy configuration)
    (configuration-facet configuration file-newline-facet 'buffer))

  (define (file-bom-policy configuration)
    (configuration-facet configuration file-bom-facet 'buffer))

  (define (file-final-newline-policy configuration)
    (configuration-facet configuration file-final-newline-facet 'buffer))

  (define (make-file-backup-extension enabled?)
    (unless (boolean? enabled?)
      (assertion-violation 'make-file-backup-extension
                           "expected a backup policy boolean" enabled?))
    (make-facet-provider file-backup-facet enabled? 'highest))

  (define (parse-backup-policy input)
    (cond
      [(boolean? input) input]
      [(and (string? input)
            (member (string-downcase input) '("true" "yes" "on" "1"))) #t]
      [(and (string? input)
            (member (string-downcase input) '("false" "no" "off" "0"))) #f]
      [else 'invalid]))

  (define (parse-symbol-policy input allowed)
    (let ([value
           (cond [(symbol? input) input]
                 [(string? input) (string->symbol (string-downcase input))]
                 [else 'invalid])])
      (if (memq value allowed) value 'invalid)))

  (define (register-file-settings! host owner)
    (package-host-register-setting-schema!
      host owner
      (make-setting-schema
        'file.backup 'boolean #f '(buffer) parse-backup-policy #f
        (lambda (enabled? scope)
          (make-facet-provider file-backup-facet enabled?))))
    (package-host-register-setting-schema!
      host owner
      (make-setting-schema
        'file.newline 'symbol 'preserve '(buffer)
        (lambda (input) (parse-symbol-policy input '(preserve lf crlf))) #f
        (lambda (value scope) (make-facet-provider file-newline-facet value))))
    (package-host-register-setting-schema!
      host owner
      (make-setting-schema
        'file.bom 'symbol 'preserve '(buffer)
        (lambda (input) (parse-symbol-policy input '(preserve yes no))) #f
        (lambda (value scope) (make-facet-provider file-bom-facet value))))
    (package-host-register-setting-schema!
      host owner
      (make-setting-schema
        'file.final-newline 'symbol 'preserve '(buffer)
        (lambda (input) (parse-symbol-policy input '(preserve yes no))) #f
        (lambda (value scope)
          (make-facet-provider file-final-newline-facet value)))))
)
