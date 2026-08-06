(library (soda kernel regex)
  (export regex?
          compile-regex
          regex-close!
          regex-find
          regex-collect)
  (import (chezscheme)
          (soda ffi document)
          (prefix (soda ffi regex) ffi:)
          (soda ffi helpers)
          (soda kernel document))

  (define (require-open who predicate pointer value)
    (unless (predicate value)
      (assertion-violation who "unexpected native handle" value))
    (when (native-null-pointer? (pointer value))
      (assertion-violation who "native handle is closed" value)))

  (define (regex? value) (ffi:regex? value))

  (define (compile-regex pattern case-sensitive?)
    (unless (and (string? pattern) (boolean? case-sensitive?))
      (assertion-violation 'compile-regex "expected a string and case policy"
                           pattern case-sensitive?))
    (let ([bytes (string->utf8 pattern)])
      (let ([pointer (ffi:%regex-compile bytes (bytevector-length bytes)
                                         (if case-sensitive? 1 0))])
        (if (native-null-pointer? pointer)
            (ffi:native-error 'compile-regex)
            (ffi:%make-regex pointer)))))

  (define (regex-close! regex)
    (when (and (ffi:regex? regex)
               (not (native-null-pointer? (ffi:regex-pointer regex))))
      (ffi:%regex-destroy (ffi:regex-pointer regex))
      (ffi:regex-pointer-set! regex #f)))

  (define (check-text who text)
    (require-open who text? text-pointer text)
    text)

  (define (regex-find regex text start end direction)
    (require-open 'regex-find ffi:regex? ffi:regex-pointer regex)
    (check-text 'regex-find text)
    (unless (and (integer? start) (exact? start) (integer? end) (exact? end)
                 (<= 0 start end (text-size text))
                 (memq direction '(forward backward)))
      (assertion-violation 'regex-find "invalid regular-expression range or direction"
                           start end direction))
    (let ([from (foreign-alloc 4)] [to (foreign-alloc 4)])
      (let ([status (ffi:%regex-find (ffi:regex-pointer regex) (text-pointer text)
                                      start end
                                      (if (eq? direction 'forward) 1 -1)
                                      from to)])
        (dynamic-wind
          (lambda () #f)
          (lambda ()
            (cond [(= status 1)
                   (cons (foreign-ref 'unsigned-32 from 0)
                         (foreign-ref 'unsigned-32 to 0))]
                  [(zero? status) #f]
                  [else (ffi:native-error 'regex-find)]))
          (lambda ()
            (foreign-free from)
            (foreign-free to))))))

  (define (regex-collect regex text start end)
    (require-open 'regex-collect ffi:regex? ffi:regex-pointer regex)
    (check-text 'regex-collect text)
    (unless (and (integer? start) (exact? start) (integer? end) (exact? end)
                 (<= 0 start end (text-size text)))
      (assertion-violation 'regex-collect "invalid regular-expression range" start end))
    (let ([pointer (ffi:%regex-collect (ffi:regex-pointer regex) (text-pointer text) start end)])
      (if (native-null-pointer? pointer)
          (ffi:native-error 'regex-collect)
          (let ([matches (ffi:%make-regex-matches pointer)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (let ([count (ffi:%regex-matches-count pointer)])
                  (when (= count #xffffffff)
                    (ffi:native-error 'regex-collect))
                  (let loop ([index 0] [output '()])
                    (if (= index count)
                        (reverse output)
                        (let ([from (foreign-alloc 4)] [to (foreign-alloc 4)])
                          (dynamic-wind
                            (lambda () #f)
                            (lambda ()
                              (ffi:check-status
                                'regex-collect
                                (ffi:%regex-matches-range pointer index from to))
                              (loop (+ index 1)
                                    (cons (cons (foreign-ref 'unsigned-32 from 0)
                                                (foreign-ref 'unsigned-32 to 0))
                                          output)))
                            (lambda ()
                              (foreign-free from)
                              (foreign-free to))))))))
              (lambda ()
                (unless (native-null-pointer? (ffi:regex-matches-pointer matches))
                  (ffi:%regex-matches-destroy (ffi:regex-matches-pointer matches))
                  (ffi:regex-matches-pointer-set! matches #f)))))))))
