#lang racket/base
(require racket/contract/base
         racket/match
         racket/list)

(define list/count
  (or/c exact-nonnegative-integer? (listof bytes?)))
(define lc->number
  (match-lambda
    [(? number? x)
     x]
    [(? list? x)
     (length x)]))
(define lc->list
  (match-lambda
    [(? number? x)
     empty]
    [(? list? x)
     x]))
(define lc-zero?
  (match-lambda
    [(? number? x)
     (zero? x)]
    [(? list? x)
     (eq? empty x)]))

(define (-lc+ x y)
  (cond
    [(number? x)
     (+ x (lc->number y))]
    [(number? y)
     (+ (lc->number x) y)]
    [else
     (append x y)]))

(define (lc+ x . args)
 (cond [(null? args) x]
       [else (foldr -lc+ x args)]))

(define (lc-sort l)
  (cond
    [(number? l)
     l]
    [else
     (sort (remove-duplicates l) bytes<?)]))

(provide/contract
 [list/count contract?]
 [lc+ ((list/count) #:rest (listof list/count) . ->* . list/count)]
 [lc->number (list/count . -> . exact-nonnegative-integer?)]
 [lc-sort (list/count . -> . list/count)]
 [lc->list (list/count . -> . (listof bytes?))]
 [lc-zero? (list/count . -> . boolean?)])
