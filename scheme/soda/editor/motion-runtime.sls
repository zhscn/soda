(library (soda editor motion-runtime)
  (export buffer-word-motion
          buffer-word-motion-target)
  (import (rnrs)
          (soda document)
          (soda editor buffer)
          (soda editor language)
          (soda editor motion))

  (define (buffer-word-motion buffer)
    (unless (buffer? buffer)
      (assertion-violation
        'buffer-word-motion
        "expected a buffer"
        buffer))
    (let ([setting (buffer-setting-ref buffer 'word-motion #f)])
      (cond
        [(word-motion? setting) setting]
        [setting
         (assertion-violation
           'buffer-word-motion
           "word-motion setting must be a word motion"
           setting)]
        [else
         (let ([profile (buffer-language-profile buffer)])
           (or (and profile (language-profile-word-motion profile))
               default-word-motion))])))

  (define (buffer-word-motion-target buffer offset count)
    (let* ([motion (buffer-word-motion buffer)]
           [snapshot
             (document-snapshot (buffer-document buffer))])
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ([text (snapshot-text snapshot)])
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (word-motion-target
                  motion
                  text
                  offset
                  count))
              (lambda () (text-close! text)))))
        (lambda () (snapshot-close! snapshot))))))
