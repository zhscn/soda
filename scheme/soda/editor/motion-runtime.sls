(library (soda editor motion-runtime)
  (export buffer-word-motion
          buffer-word-motion-target)
  (import (rnrs)
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
    (call-with-buffer-text
      buffer
      (lambda (text)
        (word-motion-target
          (buffer-word-motion buffer)
          text
          offset
          count)))))
