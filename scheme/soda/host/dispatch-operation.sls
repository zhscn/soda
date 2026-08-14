(library (soda host dispatch-operation)
  (export dispatcher-dispatch-host!
          dispatcher-dispatch-view-with-host!
          dispatcher-register-global-operation-handler!)
  (import (soda host dispatch internal)))
