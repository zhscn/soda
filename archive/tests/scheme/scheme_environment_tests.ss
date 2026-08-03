#!r6rs
(import (rnrs)
        (soda document)
        (soda editor buffer)
        (soda editor core)
        (soda editor scheme-environment)
        (soda editor scheme-query)
        (soda editor scheme-semantics)
        (soda editor scheme-workspace)
        (soda editor state))

(define (check condition message . irritants)
  (unless condition
    (apply error 'scheme-environment-tests message irritants)))

(define (scheme-test-buffer id resource source)
  (make-buffer
    id
    (make-document source id)
    resource
    'scheme-mode))

(define library-a
  (scheme-test-buffer
    8101
    "/environment-a/library.sls"
    "(library (sample shared) (export value-a) (import (rnrs)) (define value-a 1))"))
(define consumer-a
  (scheme-test-buffer
    8102
    "/environment-a/consumer.sls"
    "(import (sample shared)) (define result-a value-a)"))
(define library-b
  (scheme-test-buffer
    8201
    "/environment-b/library.sls"
    "(library (sample shared) (export value-b) (import (rnrs)) (define value-b 2))"))
(define consumer-b
  (scheme-test-buffer
    8202
    "/environment-b/consumer.sls"
    "(import (sample shared)) (define result-b value-b)"))
(define unattached
  (scheme-test-buffer
    8301
    "/standalone/consumer.sls"
    "(import (sample shared)) value-a value-b"))

(define editor (make-editor library-a))
(for-each
  (lambda (buffer) (editor-add-buffer! editor buffer))
  (list consumer-a library-b consumer-b unattached))

(define environments (editor-scheme-environments editor))
(define environment-a
  (scheme-environment-registry-ensure!
    environments "environment-a" 'r6rs))
(define environment-b
  (scheme-environment-registry-ensure!
    environments "environment-b" 'r6rs))

(for-each
  (lambda (buffer)
    (scheme-workspace-attach-buffer!
      (scheme-environment-index environment-a)
      buffer))
  (list library-a consumer-a))
(for-each
  (lambda (buffer)
    (scheme-workspace-attach-buffer!
      (scheme-environment-index environment-b)
      buffer))
  (list library-b consumer-b))

(scheme-workspace-sync-editor!
  (scheme-environment-index environment-a)
  editor)
(scheme-workspace-sync-editor!
  (scheme-environment-index environment-b)
  editor)

(define (resolved-name? snapshot spelling definition-name)
  (let ([use
          (find
            (lambda (candidate)
              (string=? (scheme-use-name candidate) spelling))
            (scheme-semantic-snapshot-uses snapshot))])
    (and
      use
      (exists
        (lambda (definition)
          (string=?
            (scheme-definition-name definition)
            definition-name))
        (scheme-semantic-definitions-at
          snapshot
          (scheme-use-start use))))))

(define snapshot-a
  (scheme-workspace-snapshot-for-buffer
    (scheme-environment-index environment-a)
    consumer-a))
(define snapshot-b
  (scheme-workspace-snapshot-for-buffer
    (scheme-environment-index environment-b)
    consumer-b))

(check
  (resolved-name? snapshot-a "value-a" "value-a")
  "environment A did not resolve its attached library")
(check
  (resolved-name? snapshot-b "value-b" "value-b")
  "environment B did not resolve its attached library")
(check
  (not
    (exists
      (lambda (definition)
        (string=? (scheme-definition-name definition) "value-b"))
      (scheme-semantic-snapshot-visible-index-definitions snapshot-a)))
  "environment A observed a library from environment B")

(define standalone-index
  (scheme-semantic-index-for-buffer
    environments editor unattached))
(define standalone-snapshot
  (scheme-workspace-snapshot-for-buffer
    standalone-index
    unattached))
(check
  (and
    (not (resolved-name? standalone-snapshot "value-a" "value-a"))
    (not (resolved-name? standalone-snapshot "value-b" "value-b")))
  "a standalone Document inherited an open Buffer environment")

(define generation-a
  (scheme-workspace-generation
    (scheme-environment-index environment-a)))
(buffer-replace-range!
  library-b
  0
  0
  (string->utf8 "; unrelated edit\n"))
(scheme-workspace-sync-editor!
  (scheme-environment-index environment-a)
  editor)
(check
  (=
    generation-a
    (scheme-workspace-generation
      (scheme-environment-index environment-a)))
  "an unattached Buffer invalidated another SchemeEnvironment")

(scheme-environment-attach-view!
  environments
  editor
  (view-id (editor-active-view editor))
  environment-a)
(check
  (scheme-environment-for-view
    environments editor (view-id (editor-active-view editor)))
  "the active View did not select its SchemeEnvironment")
(scheme-environment-registry-remove!
  environments editor (scheme-environment-id environment-a))
(check
  (and
    (not
      (scheme-environment-for-view
        environments editor (view-id (editor-active-view editor))))
    (not
      (scheme-workspace-buffer-attached?
        (scheme-environment-index environment-a)
        (buffer-id library-a))))
  "removing a SchemeEnvironment retained its View or index attachments")

(editor-close! editor)
(display "scheme environment tests passed\n")
