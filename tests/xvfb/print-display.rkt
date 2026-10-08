#lang racket/base
;; Prints the display that xvfb-run chose
(displayln (getenv "DISPLAY"))
