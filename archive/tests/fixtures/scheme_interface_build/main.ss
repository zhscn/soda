#!r6rs
(import (rnrs)
        (fixture scheme-interface-build dependency))

(unless (= (fixture-value 20) 42)
  (assertion-violation
    'scheme-interface-build-fixture
    "fixture library returned an unexpected value"))

(unless (= (public-fixture-value 20) 42)
  (assertion-violation
    'scheme-interface-build-fixture
    "renamed fixture export returned an unexpected value"))
