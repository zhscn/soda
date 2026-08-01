#!r6rs
(import (rnrs)
        (only (chezscheme) getenv)
        (soda build builtin-api-index))

(define test-root (getenv "SODA_SCHEME_API_CACHE_TEST_ROOT"))
(define analyzer-root (getenv "SODA_SCHEME_SOURCE_ROOT"))
(define sources-root (string-append test-root "/sources"))
(define source-a (string-append sources-root "/alpha.sls"))
(define source-b (string-append sources-root "/beta.sls"))
(define output (string-append test-root "/builtin-api-index.sls"))
(define cache (string-append test-root "/scheme-api-index.cache"))

(define (write-text path value)
  (call-with-port
    (open-file-output-port
      path
      (file-options no-fail)
      (buffer-mode block)
      (native-transcoder))
    (lambda (port) (display value port))))

(define (remove-if-present path)
  (when (file-exists? path) (delete-file path)))

(define (check condition message . irritants)
  (unless condition
    (apply assertion-violation
      'scheme-api-index-cache-tests message irritants)))

(remove-if-present cache)
(remove-if-present output)
(remove-if-present source-a)
(remove-if-present source-b)

(write-text
  source-a
  "(library (fixture alpha) (export alpha) (import (rnrs)) (define alpha 1))\n")
(write-text
  source-b
  "(library (fixture beta) (export beta) (import (rnrs) (fixture alpha)) (define beta alpha))\n")

(define first
  (generate-built-in-api-index!
    sources-root output cache analyzer-root))
(check
  (and
    (= (built-in-api-index-build-source-count first) 2)
    (= (built-in-api-index-build-cache-hits first) 0)
    (= (built-in-api-index-build-cache-misses first) 2))
  "the initial build did not analyze every source"
  first)

(define second
  (generate-built-in-api-index!
    sources-root output cache analyzer-root))
(check
  (and
    (= (built-in-api-index-build-cache-hits second) 2)
    (= (built-in-api-index-build-cache-misses second) 0))
  "an unchanged build did not reuse every file summary"
  second)

(write-text
  source-b
  "(library (fixture beta) (export beta) (import (rnrs) (fixture alpha)) (define (beta x) (+ alpha x)))\n")
(define changed
  (generate-built-in-api-index!
    sources-root output cache analyzer-root))
(check
  (and
    (= (built-in-api-index-build-cache-hits changed) 1)
    (= (built-in-api-index-build-cache-misses changed) 1))
  "a one-file edit invalidated the wrong summary set"
  changed)

(delete-file source-b)
(define removed
  (generate-built-in-api-index!
    sources-root output cache analyzer-root))
(check
  (and
    (= (built-in-api-index-build-source-count removed) 1)
    (= (built-in-api-index-build-cache-hits removed) 1)
    (= (built-in-api-index-build-cache-misses removed) 0))
  "a removed source survived the cache or invalidated an unchanged source"
  removed)

(remove-if-present source-a)
(remove-if-present output)
(remove-if-present cache)

(display "scheme API index cache tests passed\n")
