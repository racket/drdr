#lang info

;; A fixture for plt-build.rkt's tests of test-xvfb-paths and
;; test-command-prefixes; plt-build.rkt runs these files itself.
(define test-xvfb-paths '("gui-test.rkt" "tests" "print-display.rkt" "focus.rkt" "nested/listed.rkt"))
(define test-command-prefixes
  '(("gui-test.rkt" ("gdb" "--args")) ("tests" ("rr" "record"))
                                      ("tests/deeper" ("strace" "-f"))
                                      ("print-display.rkt" ("/usr/bin/env" "DRDR_PREFIX=yes"))))
(define test-omit-paths 'all)
