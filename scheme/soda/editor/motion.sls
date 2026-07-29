(library (soda editor motion)
  (export make-word-motion
          word-motion?
          word-motion-target
          default-word-motion)
  (import (rnrs)
          (soda document)
          (soda editor motion-protocol))

  (define (word-motion-target motion text offset count)
    (unless (word-motion? motion)
      (assertion-violation
        'word-motion-target
        "expected a word motion"
        motion))
    (unless (text? text)
      (assertion-violation
        'word-motion-target
        "expected text"
        text))
    (unless (and (integer? offset)
                 (exact? offset)
                 (<= 0 offset (text-size text)))
      (assertion-violation
        'word-motion-target
        "offset is outside the text"
        offset))
    (unless (and (integer? count) (exact? count))
      (assertion-violation
        'word-motion-target
        "count must be an exact integer"
        count))
    (let ([target
            (word-motion-apply motion text offset count)])
      (unless (and (integer? target)
                   (exact? target)
                   (<= 0 target (text-size text)))
        (assertion-violation
          'word-motion-target
          "word motion returned an invalid offset"
          target))
      target))

  (define (previous-character-offset text offset)
    (if (zero? offset)
        0
        (let loop ([candidate (- offset 1)])
          (if (or (zero? candidate)
                  (not
                    (= (bitwise-and
                         (text-byte-at text candidate)
                         #xc0)
                       #x80)))
              candidate
              (loop (- candidate 1))))))

  (define (next-character-offset text offset)
    (let ([size (text-size text)])
      (if (>= offset size)
          size
          (let loop ([candidate (+ offset 1)])
            (if (or (>= candidate size)
                    (not
                      (= (bitwise-and
                           (text-byte-at text candidate)
                           #xc0)
                         #x80)))
                candidate
                (loop (+ candidate 1)))))))

  (define (character-at text start end)
    (string-ref
      (utf8->string (text-subbytevector text start end))
      0))

  (define (word-character? character)
    (or (char=? character #\_)
        (memq
          (char-general-category character)
          '(Lu Ll Lt Lm Lo Mn Mc Me Nd Nl No Pc))))

  (define (word-character-at? text offset)
    (and (< offset (text-size text))
         (let ([end (next-character-offset text offset)])
           (word-character? (character-at text offset end)))))

  (define (word-character-before? text offset)
    (and (positive? offset)
         (let ([start (previous-character-offset text offset)])
           (word-character? (character-at text start offset)))))

  (define (forward-one-word text offset)
    (let skip-separators ([offset offset])
      (if (and (< offset (text-size text))
               (not (word-character-at? text offset)))
          (skip-separators (next-character-offset text offset))
          (let skip-word ([offset offset])
            (if (word-character-at? text offset)
                (skip-word (next-character-offset text offset))
                offset)))))

  (define (backward-one-word text offset)
    (let skip-separators ([offset offset])
      (if (and (positive? offset)
               (not (word-character-before? text offset)))
          (skip-separators (previous-character-offset text offset))
          (let skip-word ([offset offset])
            (if (word-character-before? text offset)
                (skip-word (previous-character-offset text offset))
                offset)))))

  (define default-word-motion
    (make-word-motion
      (lambda (text offset count)
        (let loop ([offset offset] [remaining count])
          (cond
            [(positive? remaining)
             (loop
               (forward-one-word text offset)
               (- remaining 1))]
            [(negative? remaining)
             (loop
               (backward-one-word text offset)
               (+ remaining 1))]
            [else offset]))))))
