#lang racket/base
;; Exits with 0 when a newly shown frame gets the focus within 5 seconds,
;; which happens only when a window manager runs on the display
(require racket/gui/base
         racket/class)

(define f (new frame% [label "focus"]))
(send f show #t)
(define focused?
  (for/or ([i (in-range 50)])
    (sleep/yield 1/10)
    (eq? f (get-top-level-focus-window))))
(send f show #f)
(exit (if focused? 0 1))
