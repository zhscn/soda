(library (soda packages file-operation)
  (export make-file-load file-load? file-load-buffer-id file-load-resource
          file-load-version file-load-format file-load-discard-history?
          make-file-write file-write? file-write-buffer-id file-write-resource
          file-write-contents file-write-format file-write-expected-version
          file-write-rebind?
          make-file-visit file-visit? file-visit-context file-visit-resource
          make-file-location-open file-location-open? file-location-open-location
          make-file-close file-close? file-close-buffer-id
          make-file-insert file-insert? file-insert-context file-insert-resource
          make-file-external-resolution file-external-resolution?
          file-external-resolution-buffer-id file-external-resolution-version
          file-external-resolution-action file-external-resolution-destination
          file-external-resolution-destination-version)
  (import (rnrs))

  ;; These immutable values cross the command-loop effect boundary.  They
  ;; describe requested work without carrying mutable service state.
  (define-record-type file-load
    (fields buffer-id resource version format discard-history?))

  (define-record-type file-write
    (fields buffer-id resource contents format expected-version rebind?))

  (define-record-type file-visit
    (fields context resource))

  (define-record-type file-location-open
    (fields location))

  (define-record-type file-close
    (fields buffer-id))

  (define-record-type file-insert
    (fields context resource))

  (define-record-type file-external-resolution
    (fields buffer-id version action destination destination-version))
)
