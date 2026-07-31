(library (soda editor save-place-store)
  (export default-save-place-path
          save-place-state-encode
          save-place-state-decode
          load-save-place-file
          ensure-save-place-directory!)
  (import (rnrs)
          (only (chezscheme)
                file-directory?
                getenv
                mkdir
                path-parent)
          (soda editor state))

  (define schema-name 'soda-save-place)
  (define schema-version 1)

  (define (non-empty-string? value)
    (and (string? value) (positive? (string-length value))))

  (define (default-save-place-path)
    (let ([override (getenv "SODA_SAVE_PLACE_FILE")])
      (if override
          (and (non-empty-string? override) override)
          (let ([xdg-state-home (getenv "XDG_STATE_HOME")]
                [home (getenv "HOME")])
            (cond
              [(non-empty-string? xdg-state-home)
               (string-append xdg-state-home "/soda/places.ss")]
              [(non-empty-string? home)
               (string-append home "/.local/state/soda/places.ss")]
              [else #f])))))

  (define (entry->datum entry)
    (list
      (save-place-resource entry)
      (save-place-point entry)
      (save-place-first-line entry)
      (save-place-first-visual-row entry)
      (save-place-first-column entry)
      (save-place-mark entry)))

  (define (save-place-state-encode places)
    (unless (and (list? places) (for-all save-place? places))
      (assertion-violation
        'save-place-state-encode
        "expected save-place entries"
        places))
    (let-values ([(port extract) (open-string-output-port)])
      (write
        (list
          schema-name
          schema-version
          (map entry->datum places))
        port)
      (newline port)
      (string->utf8 (extract))))

  (define (valid-offset? value)
    (and (integer? value) (exact? value) (not (negative? value))))

  (define (datum->entry datum)
    (and
      (list? datum)
      (= (length datum) 6)
      (let ([resource (list-ref datum 0)]
            [point (list-ref datum 1)]
            [first-line (list-ref datum 2)]
            [first-visual-row (list-ref datum 3)]
            [first-column (list-ref datum 4)]
            [mark (list-ref datum 5)])
        (and
          (non-empty-string? resource)
          (valid-offset? point)
          (valid-offset? first-line)
          (valid-offset? first-visual-row)
          (valid-offset? first-column)
          (or (not mark) (valid-offset? mark))
          (make-save-place
            resource
            point
            first-line
            first-visual-row
            first-column
            mark)))))

  (define (save-place-state-decode bytes)
    (unless (bytevector? bytes)
      (assertion-violation
        'save-place-state-decode
        "expected a bytevector"
        bytes))
    (guard
      (condition
        [else
         (assertion-violation
           'save-place-state-decode
           "invalid save-place state"
           condition)])
      (let* ([port (open-string-input-port (utf8->string bytes))]
             [datum (read port)]
             [trailing (read port)])
        (unless
          (and
            (eof-object? trailing)
            (list? datum)
            (= (length datum) 3)
            (eq? (car datum) schema-name)
            (eqv? (cadr datum) schema-version)
            (list? (caddr datum)))
          (assertion-violation
            'save-place-state-decode
            "unsupported or malformed save-place state"))
        (let ([entries (map datum->entry (caddr datum))])
          (unless (for-all save-place? entries)
            (assertion-violation
              'save-place-state-decode
              "malformed save-place entry"))
          entries))))

  (define (load-save-place-file path)
    (if (and path (file-exists? path))
        (guard (condition [else '()])
          (call-with-port
            (open-file-input-port path)
            (lambda (port)
              (save-place-state-decode
                (get-bytevector-all port)))))
        '()))

  (define (ensure-directory! directory)
    (unless
      (or (string=? directory "")
          (string=? directory ".")
          (string=? directory "/")
          (file-directory? directory))
      (let ([parent (path-parent directory)])
        (unless (string=? parent directory)
          (ensure-directory! parent)))
      (mkdir directory)))

  (define (ensure-save-place-directory! path)
    (unless (non-empty-string? path)
      (assertion-violation
        'ensure-save-place-directory!
        "path must be non-empty"
        path))
    (ensure-directory! (path-parent path))
    path))
