(library (soda editor hashtable-state)
  (export replace-hashtable!
          hashtable->alist
          restore-hashtable!)
  (import (rnrs))

  (define (replace-hashtable! target source)
    (hashtable-clear! target)
    (let-values ([(keys values) (hashtable-entries source)])
      (do ([index 0 (+ index 1)])
          ((= index (vector-length keys)) target)
        (hashtable-set!
          target
          (vector-ref keys index)
          (vector-ref values index)))))

  (define (hashtable->alist table)
    (let-values ([(keys values) (hashtable-entries table)])
      (do ([index 0 (+ index 1)]
           [entries '()
                    (cons
                      (cons (vector-ref keys index)
                            (vector-ref values index))
                      entries)])
          ((= index (vector-length keys)) entries))))

  (define (restore-hashtable! table entries)
    (hashtable-clear! table)
    (for-each
      (lambda (entry) (hashtable-set! table (car entry) (cdr entry)))
      entries)
    table))
