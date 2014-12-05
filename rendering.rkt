#lang racket/base
(require racket/contract/base
         "list-count.rkt")

(define-struct rendering
  (start end duration timeout? unclean-exit? stderr? responsible changed?)
  #:prefab)
(define-struct (rendering.v2 rendering)
  (random?)
  #:prefab)

(define (rendering-responsibles r)
  (regexp-split #rx"," (rendering-responsible r)))

(define (rendering-random? r)
  (if (rendering.v2? r)
      (rendering.v2-random? r)
      #f))

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
 [rendering-random? (rendering? . -> . boolean?)]
 [rendering-responsibles (rendering? . -> . (listof string?))])
