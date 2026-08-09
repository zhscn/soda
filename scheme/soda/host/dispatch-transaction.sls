(library (soda host dispatch-transaction)
  (export dispatcher-dispatch! dispatcher-dispatch-specs!
          dispatcher-dispatch-view! dispatcher-publish-buffer-damage!)
  (import (soda host dispatch internal)))
