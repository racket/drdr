#lang racket/base
;; Prints the display that xvfb-run chose, and whether the test ran under
;; its command prefix
(displayln (getenv "DISPLAY"))
(printf "prefix: ~a\n" (getenv "DRDR_PREFIX"))
