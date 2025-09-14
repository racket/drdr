#lang racket/base
(require racket/system
         racket/cmdline
         racket/local
         "config.rkt"
         "archive.rkt"
         "path-utils.rkt"
         "dirstruct.rkt"
         "make-archive-lib.rkt")

(define mode (make-parameter 'single))

(init-revisions!)

(command-line #:program "make-archive"
              #:once-any
              ["--single" "Archive a single revision" (mode 'single)]
              ["--many" "Archive many revisions" (mode 'many)]
              #:args (ns)
              (local [(define n (string->number ns))]
                     (case (mode)
                       [(many)
                        (local [(define all-revisions
                                  (sort (unbox revisions-b) >=))]
                               (for ([rev (in-list (list-tail all-revisions n))])
                                 (make-archive rev)))]
                       [(single)
                        (make-archive n)])))
