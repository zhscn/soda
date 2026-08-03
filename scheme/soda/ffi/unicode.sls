(library (soda ffi unicode)
  (export unicode-grapheme-width)
  (import (chezscheme))

  (define %grapheme-width
    (foreign-procedure __atomic "soda_unicode_grapheme_width" (u8* size_t) int))

  (define (unicode-grapheme-width bytes)
    (unless (bytevector? bytes)
      (assertion-violation 'unicode-grapheme-width "expected a bytevector" bytes))
    (%grapheme-width bytes (bytevector-length bytes))))
