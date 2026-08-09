(library (soda host navigation)
  (export navigation-entry?
          navigation-entry-from
          navigation-entry-to
          navigation-jump?
          navigation-jump-kind
          navigation-jump-from
          navigation-jump-target)
  (import (soda host internal navigation)))
