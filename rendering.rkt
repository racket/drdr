#lang racket/base
(require racket/contract/base
         "list-count.rkt")

(define-struct rendering
  (start end duration timeout? unclean-exit? stderr? responsible changed?)
  #:prefab)
(define-struct (rendering.v2 rendering)
  (random?)
  #:prefab)
(define-struct (rendering.v3 rendering.v2)
  (known-error?)
  #:prefab)

(define (rendering-responsibles r)
  (regexp-split #rx"," (rendering-responsible r)))

(define (rendering-random? r)
  (cond
    [(rendering.v2? r)
     (rendering.v2-random? r)]
    [else
     #f]))

(define (rendering-known-error? r)
  (cond
    [(rendering.v3? r)
     (rendering.v3-known-error? r)]
    [else
     #f]))

(define (rendering-ignorable? r)
  (or (rendering-random? r)
      (rendering-known-error? r)))

(provide/contract
 [struct rendering
   ([start number?]
    [end number?]
    [duration number?]
    [timeout? list/count]
    [unclean-exit? list/count]
    [stderr? list/count]
    [responsible string?]
    [changed? list/count])]
 [struct rendering.v2
   ([start number?]
    [end number?]
    [duration number?]
    [timeout? list/count]
    [unclean-exit? list/count]
    [stderr? list/count]
    [responsible string?]
    [changed? list/count]
    [random? boolean?])]
 [struct rendering.v3
   ([start number?]
    [end number?]
    [duration number?]
    [timeout? list/count]
    [unclean-exit? list/count]
    [stderr? list/count]
    [responsible string?]
    [changed? list/count]
    [random? boolean?]
    [known-error? boolean?])]
 [rendering-random? (rendering? . -> . boolean?)]
 [rendering-known-error? (rendering? . -> . boolean?)]
 [rendering-ignorable? (rendering? . -> . boolean?)]
 [rendering-responsibles (rendering? . -> . (listof string?))])
