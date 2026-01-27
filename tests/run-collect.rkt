#lang racket
(require "../run-collect.rkt"
         "../status.rkt"
         racket/runtime-path
         rackunit)

(define-runtime-path loud-file "loud.rkt")

(define (run-loud n)
  (run/collect/wait #:env (hash)
                    #:timeout (* 10)
                    (path->string (find-system-path 'exec-file))
                    (list "-t" (path->string loud-file)
                          "--" (number->string n))))

(define (test-run-loud n)
  (check-equal? (apply set (status-output-log (run-loud n)))
                (for/set ([i (in-range n)])
                  ((if (even? i)
                       make-stderr
                       make-stdout)
                   (string->bytes/utf-8
                    (number->string i))))
                (format "Test failed for n=~a" n)))

;; Run tests for different values of n
(for ([n (in-range 10)])
  (test-run-loud n))

;; Also run the function once for demonstration
(run-loud 10)
