(library (soda ffi unicode)
  (export unicode-grapheme-width unicode-next-grapheme-offset)
  (import (chezscheme))

  (define %grapheme-width
    (foreign-procedure __atomic "soda_unicode_grapheme_width" (u8* size_t) int))

  (define %next-grapheme-offset
    (foreign-procedure __atomic "soda_unicode_next_grapheme_offset"
                       (u8* size_t size_t) size_t))

  (define (unicode-grapheme-width bytes)
    (unless (bytevector? bytes)
      (assertion-violation 'unicode-grapheme-width "expected a bytevector" bytes))
    (%grapheme-width bytes (bytevector-length bytes)))

  (define (unicode-next-grapheme-offset bytes start)
    (unless (and (bytevector? bytes) (integer? start) (exact? start)
                 (>= start 0) (<= start (bytevector-length bytes)))
      (assertion-violation 'unicode-next-grapheme-offset
                           "invalid UTF-8 grapheme boundary request" bytes start))
    (%next-grapheme-offset bytes (bytevector-length bytes) start))
)
