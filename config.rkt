#lang racket/base
(require racket/list
         racket/contract/base
         "cache.rkt"
         "dirstruct.rkt"
         "scm.rkt"
         "monitor-scm.rkt")

(plt-directory "/opt/plt")
(drdr-directory "/opt/svn/drdr")
(git-path "/usr/bin/git")
(Xvfb-path "/usr/bin/Xnest")
(fluxbox-path "/usr/bin/metacity")
(vncviewer-path "/usr/bin/vncviewer")
(current-make-install-timeout-seconds (* 5 60 60))
(current-make-timeout-seconds (* 5 60 60))                                       
(current-subprocess-timeout-seconds 90)
(current-monitoring-interval-seconds 60)
(number-of-cpus 18)

(define (string->number* s)
  (with-handlers ([exn:fail? (lambda (x) #f)])
    (let ([v (string->number s)])
      (and (number? v)
           v))))

(define revisions-b (box #f))

(define (init-revisions!)
  (define builds (directory-list (plt-build-directory)))
  (define nums
    (filter-map
     (compose string->number* path->string)
     builds))
  (define sorted (sort nums <))
  (set-box! revisions-b sorted))

(define (newest-revision)
  (last (unbox revisions-b)))

(define (second-to-last l)
  (list-ref l (- (length l) 2)))

(define (second-newest-revision)
  (with-handlers ([exn:fail? (lambda (x) #f)])
    (second-to-last (unbox revisions-b))))

(define (newest-completed-revision)
  (define n (newest-revision))
  (if (read-cache* (build-path (revision-dir n) "analyzed"))
      n
      (second-newest-revision)))

(provide/contract
 [revisions-b (box/c (or/c false/c (listof exact-nonnegative-integer?)))]
 [init-revisions! (-> void)]
 [newest-revision (-> exact-nonnegative-integer?)]
 [second-newest-revision (-> (or/c false/c exact-nonnegative-integer?))]
 [newest-completed-revision (-> (or/c false/c exact-nonnegative-integer?))])
