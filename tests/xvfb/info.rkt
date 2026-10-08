#lang info

;; A fixture for plt-build.rkt's tests of test-xvfb-paths; plt-build.rkt
;; runs these files itself.
(define test-xvfb-paths '("gui-test.rkt" "tests" "print-display.rkt" "focus.rkt"))
(define test-omit-paths 'all)
