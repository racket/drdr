#lang racket/base
;; The exception for "this is not cached", as opposed to a bug. Callers
;; test for it by type, so they do not depend on how another module words
;; its errors.
(require racket/contract/base)

(struct exn:fail:not-cached exn:fail ())

(define (raise-not-cached fmt . args)
  (raise (exn:fail:not-cached (apply format fmt args) (current-continuation-marks))))

;; A lookup legitimately fails when the data is absent: the file is
;; missing, or the archive does not hold the path.
(define (not-cached? x)
  (or (exn:fail:not-cached? x) (exn:fail:filesystem? x)))

(provide (struct-out exn:fail:not-cached))
(provide/contract [raise-not-cached (->* (string?) () #:rest (listof any/c) none/c)]
                  [not-cached? (-> any/c boolean?)])

(module+ test
  (require rackunit)

  (check-exn exn:fail:not-cached? (lambda () (raise-not-cached "~a is gone" "x")))
  (check-exn #rx"x is gone" (lambda () (raise-not-cached "~a is gone" "x")))
  (check-true (not-cached? (exn:fail:not-cached "m" (current-continuation-marks))))
  (check-true (not-cached? (exn:fail:filesystem "m" (current-continuation-marks))))
  ;; a bug is not a miss, however it is worded
  (check-false (not-cached? (exn:fail:contract "is not cached" (current-continuation-marks)))))
