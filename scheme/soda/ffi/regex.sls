(library (soda ffi regex)
  (export regex?
          %make-regex
          regex-pointer
          regex-pointer-set!
          regex-matches?
          %make-regex-matches
          regex-matches-pointer
          regex-matches-pointer-set!
          %regex-compile
          %regex-destroy
          %regex-find
          %regex-collect
          %regex-matches-destroy
          %regex-matches-count
          %regex-matches-range
          %last-error
          native-error
          check-status)
  (import (chezscheme)
          (soda ffi helpers))

  (define-record-type (regex %make-regex regex?)
    (fields (mutable pointer)))
  (define-record-type (regex-matches %make-regex-matches regex-matches?)
    (fields (mutable pointer)))

  (define %abi-version
    (foreign-procedure __atomic "soda_regex_abi_version" () unsigned-32))
  (define %last-error
    (foreign-procedure __atomic "soda_regex_last_error" () string))
  (define abi-version-checked
    (unless (= (%abi-version) 1)
      (error 'soda-regex "unsupported native regex ABI version")))

  (define %regex-compile
    (foreign-procedure __atomic "soda_regex_compile" (u8* size_t int) void*))
  (define %regex-destroy
    (foreign-procedure __atomic "soda_regex_destroy" (void*) void))
  (define %regex-find
    (foreign-procedure __atomic "soda_regex_find"
                       (void* void* unsigned-32 unsigned-32 int void* void*) int))
  (define %regex-collect
    (foreign-procedure __atomic "soda_regex_collect"
                       (void* void* unsigned-32 unsigned-32) void*))
  (define %regex-matches-destroy
    (foreign-procedure __atomic "soda_regex_matches_destroy" (void*) void))
  (define %regex-matches-count
    (foreign-procedure __atomic "soda_regex_matches_count" (void*) unsigned-32))
  (define %regex-matches-range
    (foreign-procedure __atomic "soda_regex_matches_range"
                       (void* unsigned-32 void* void*) int))

  (define native-error (make-native-error %last-error))
  (define check-status (make-native-status-checker native-error)))
