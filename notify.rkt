#lang racket/base
(require racket/contract/base
         racket/date)

(define (notify! fmt . args)
  (define now (current-seconds))
  (log-info (format "[~a: ~a] ~a" now (seconds->string now) (apply format fmt args))))

(define (seconds->string secs)
  (parameterize ([date-display-format 'iso-8601])
    (date->string (seconds->date secs) #t)))

(define-logger drdr)

;; Run `thunk`, and return `(on-fail)` if it raises. A handler that
;; discards every exception makes a bug look like the ordinary case its
;; fallback stands for, so log each exception that `expected?` rejects.
(define (swallow who context thunk
                 #:expected? [expected? (lambda (x) #f)]
                 #:on-fail [on-fail (lambda () #f)])
  (with-handlers ([exn:fail?
                   (lambda (x)
                     (unless (expected? x)
                       (log-drdr-warning "~a: swallowed exception for ~e: ~a"
                                         who context (exn-message x)))
                     (on-fail))])
    (thunk)))

(provide/contract
 [seconds->string (-> number? string?)]
 [notify! ((string?) () #:rest (listof any/c) . ->* . void)]
 [swallow (->* (any/c any/c (-> any))
               (#:expected? (-> exn:fail? boolean?) #:on-fail (-> any))
               any)])

(module test-support racket/base
  (require racket/logging)
  (provide warnings-during)
  ;; the `drdr` warnings logged while `thunk` runs
  (define (warnings-during thunk)
    (define msgs '())
    (with-intercepted-logging
      (lambda (l) (set! msgs (cons (vector-ref l 1) msgs)))
      thunk
      'warning 'drdr)
    (reverse msgs)))

(module+ test
  (require rackunit
           (submod ".." test-support))

  (seconds->string (current-seconds))

  (check-equal? (swallow 'test "ctx" (lambda () 'ok)) 'ok)

  ;; an unexpected failure is logged, and the fallback returned
  (let ([msgs (warnings-during
               (lambda ()
                 (check-equal? (swallow 'test "ctx"
                                        (lambda () (error 'boom "went wrong"))
                                        #:on-fail (lambda () 'fallback))
                               'fallback)))])
    (check-equal? (length msgs) 1)
    (check-regexp-match #rx"test: swallowed exception for \"ctx\": boom: went wrong"
                        (car msgs)))

  ;; an expected failure is not
  (check-equal? (warnings-during
                 (lambda ()
                   (swallow 'test "ctx"
                            (lambda () (raise (exn:fail:filesystem
                                               "gone" (current-continuation-marks))))
                            #:expected? exn:fail:filesystem?)))
                '())

  ;; only `exn:fail?` is caught
  (check-exn (lambda (x) (eq? x 'not-a-failure))
             (lambda () (swallow 'test "ctx" (lambda () (raise 'not-a-failure))))))
