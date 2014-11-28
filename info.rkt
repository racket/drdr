#lang info

(define collection "drdr")
(define name "DrDr")
(define compile-omit-paths 'all)

(define test-omit-paths '("archive-repair.rkt" "cc.rkt" "diffcmd.rkt"
                          "housecall.rkt" "main.rkt" "make-archive.rkt"
                          "monitor-drdr.rkt" "render.rkt" "replay-log.rkt"
                          "time-file.rkt" "time.rkt" "vdbm.rkt"))

(define test-responsibles '((all jay)))
(define deps '("base"
               "eli-tester"
               "net-lib"
               "web-server-lib"
               "web-server-test"))
(define build-deps '("at-exp-lib"
                     "scheme-lib"
                     "scribble-lib"))
