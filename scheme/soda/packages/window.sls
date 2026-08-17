(library (soda packages window)
  (export make-window-service!
          window-service?
          window-keymap)
  (import (rnrs)
          (soda host command)
          (soda host input)
          (soda host input-event)
          (soda host package)
          (soda host package-context)
          (soda host value))

  ;; WindowService owns Emacs-style editor-window commands.  It chooses
  ;; intent only; PackageHost owns View cloning, target validation, placement,
  ;; focus and retirement.
  (define-record-type
    (window-service %make-window-service window-service?)
    (fields host owner keymap))

  (define (control-stroke character)
    (make-key-stroke 'character (char->integer character) 4))

  (define (window-keymap service)
    (unless (window-service? service)
      (assertion-violation 'window-keymap "expected a WindowService" service))
    (window-service-keymap service))

  (define (make-window-service! host package-context)
    (unless (and (package-host? host)
                 (package-context? package-context)
                 (package-context-host? package-context host))
      (assertion-violation 'make-window-service!
                           "expected a PackageHost and its PackageContext"
                           host package-context))
    (let* ([owner (package-context-owner package-context)]
           [keymap (make-keymap 'window)]
           [service (%make-window-service host owner keymap)])
      (keymap-bind! keymap (list (control-stroke #\x)
                                 (make-key-stroke 'character (char->integer #\2) 0))
                    'window.split-below)
      (keymap-bind! keymap (list (control-stroke #\x)
                                 (make-key-stroke 'character (char->integer #\3) 0))
                    'window.split-right)
      (keymap-bind! keymap (list (control-stroke #\x)
                                 (make-key-stroke 'character (char->integer #\o) 0))
                    'window.other)
      (keymap-bind! keymap (list (control-stroke #\x)
                                 (make-key-stroke 'character (char->integer #\0) 0))
                    'window.delete)
      (keymap-bind! keymap (list (control-stroke #\x)
                                 (make-key-stroke 'character (char->integer #\1) 0))
                    'window.delete-others)
      (define-package-command
        package-context 'window.split-below (context)
        (documentation "Split the selected Window below, preserving its View state.")
        (class 'window) (undo 'ignore)
        (package-host-split-window! host owner context 'vertical 'preserve)
        (command-handled))
      (define-package-command
        package-context 'window.split-right (context)
        (documentation "Split the selected Window to the right, preserving its View state.")
        (class 'window) (undo 'ignore)
        (package-host-split-window! host owner context 'horizontal 'preserve)
        (command-handled))
      (define-package-command
        package-context 'window.other (context)
        (documentation "Select the next editor Window.")
        (class 'window) (repeatable #t) (undo 'ignore)
        (package-host-focus-next-window! host context)
        (command-handled))
      (define-package-command
        package-context 'window.delete (context)
        (documentation "Delete the selected Window without killing its Buffer.")
        (class 'window) (undo 'ignore)
        (package-host-delete-window! host context)
        (command-handled))
      (define-package-command
        package-context 'window.delete-others (context)
        (documentation "Delete every other Window without killing their Buffers.")
        (class 'window) (undo 'ignore)
        (package-host-delete-other-windows! host context)
        (command-handled))
      service))
)
