(import (chezscheme)
        (soda editor core))

(editor-set-global-setting! *editor* 'indent-width 11)
(define soda-test-init-marker 'failed)
(error 'editor-init "intentional init failure")
