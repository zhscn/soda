(library (soda packages base text-motion)
  (export text-forward-word-offset
          text-backward-word-offset
          text-word-count
          text-word-character-at?
          text-word-character-before?
          text-line-start-offset
          text-line-end-offset)
  (import (rnrs)
          (soda kernel document))

  ;; Word boundaries are a policy-level Unicode operation.  They work on a
  ;; Text handle so commands can share the definition without allocating a
  ;; whole-document string.
  (define (character-at text start end)
    (string-ref (utf8->string (text-subbytevector text start end)) 0))

  (define (word-character? character)
    (or (char=? character #\_)
        (memq (char-general-category character)
              '(Lu Ll Lt Lm Lo Mn Mc Me Nd Nl No Pc))))

  (define (text-word-character-at? text offset)
    (and (< offset (text-size text))
         (let ([end (text-next-character-offset text offset)])
           (word-character? (character-at text offset end)))))

  (define (text-word-character-before? text offset)
    (and (positive? offset)
         (let ([start (text-previous-character-offset text offset)])
           (word-character? (character-at text start offset)))))

  (define (text-forward-word-offset text offset)
    (let skip-separators ([current offset])
      (if (and (< current (text-size text))
               (not (text-word-character-at? text current)))
          (skip-separators (text-next-character-offset text current))
          (let skip-word ([current current])
            (if (text-word-character-at? text current)
                (skip-word (text-next-character-offset text current))
                current)))))

  (define (text-backward-word-offset text offset)
    (let skip-separators ([current offset])
      (if (and (positive? current)
               (not (text-word-character-before? text current)))
          (skip-separators (text-previous-character-offset text current))
          (let skip-word ([current current])
            (if (text-word-character-before? text current)
                (skip-word (text-previous-character-offset text current))
                current)))))

  ;; Count word runs intersecting [from,to).  This shares the same Unicode
  ;; character policy as word motion, including identifiers with underscores.
  (define (text-word-count text from to)
    (unless (and (integer? from) (exact? from) (>= from 0)
                 (integer? to) (exact? to) (<= from to) (<= to (text-size text)))
      (assertion-violation 'text-word-count "invalid text range" text from to))
    (let loop ([offset from] [inside? #f] [count 0])
      (if (>= offset to)
          count
          (let* ([next (text-next-character-offset text offset)]
                 [word? (text-word-character-at? text offset)])
            (loop next word? (if (and word? (not inside?)) (+ count 1) count))))))

  (define (text-line-start-offset text offset)
    (text-line-start text (car (text-position text offset))))

  (define (text-line-end-offset text offset)
    (text-line-content-end text (car (text-position text offset)))))
