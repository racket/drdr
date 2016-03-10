#lang racket/base
(require racket/contract/base
         racket/date)

(define (notify! fmt . args)
  (define now (current-seconds))
  (log-info (format "[~a: ~a] ~a" now (seconds->string now) (apply format fmt args))))

(define (seconds->string secs)
  (parameterize ([date-display-format 'iso-8601])
    (date->string (seconds->date secs) #t)))

(provide/contract
 [seconds->string (-> number? string?)]
 [notify! ((string?) () #:rest (listof any/c) . ->* . void)])

(module+ test
  (seconds->string (current-seconds)))
