#lang info

(define collection "drdr")
(define name "DrDr")
(define compile-omit-paths 'all)

(define test-responsibles '((all jay)))
(define deps '("base"
               "eli-tester"
               "net-lib"
               "web-server-lib"
               "web-server-test"))
(define build-deps '("at-exp-lib"
                     "scheme-lib"
                     "scribble-lib"))
