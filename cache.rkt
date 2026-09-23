#lang racket/base
(require racket/port
         racket/file
         racket/contract/base
         "path-utils.rkt"
         "not-cached.rkt")

; (symbols 'always 'cache 'no-cache)
(define cache/file-mode (make-parameter 'cache))
(define (cache/file pth thnk)
  (define mode (cache/file-mode))
  (define (recompute!)
    (define v (thnk))
    (write-cache! pth v)
    v)
  (case mode
    [(always) (recompute!)]
    [(cache no-cache)
     (with-handlers 
         ([exn:fail?
           (lambda (x)
             (case mode
               [(no-cache) (raise-not-cached "cache/file: No cache available: ~a" pth)]
               [(cache always)
                #;(printf "cache/file: running ~S for ~a\n" thnk pth)
                (recompute!)]))])
       (read-cache pth))]))

(define (cache/file/timestamp pth thnk)
  (cache/file 
   pth
   (lambda ()
     (thnk)
     (current-seconds)))
  (void))

(require "archive.rkt"
         "dirstruct.rkt"
         "notify.rkt")

;; A lookup whose data is absent is an ordinary miss; anything else, such
;; as a contract violation or a malformed archive, is a bug to report.
(define (miss-on-failure who pth thunk)
  (swallow who pth thunk #:expected? not-cached?))

;; `pth` is relative to where the build lives now, which need not be where
;; it lived when its archive was created.
(define (consult-archive pth)
  (define rev (path->revision pth))
  (define file-bytes
    (archive-extract-file (revision-archive rev) pth #:base (revision-dir rev)))
  (with-input-from-bytes file-bytes read))

(define (consult-archive/directory-list* pth)
  (define rev (path->revision pth))
  (directory-list->directory-list*
   (archive-directory-list (revision-archive rev) pth #:base (revision-dir rev))))

(define (consult-archive/directory-exists? pth)
  (define rev (path->revision pth))
  (archive-directory-exists? (revision-archive rev) pth #:base (revision-dir rev)))

(define (cached-directory-list* dir-pth)
  (if (directory-exists? dir-pth)
      (directory-list* dir-pth)
      (or (miss-on-failure 'cached-directory-list* dir-pth
                           (lambda () (consult-archive/directory-list* dir-pth)))
          (raise-not-cached "cached-directory-list*: Directory list is not cached: ~e" dir-pth))))

(define (cached-directory-exists? dir-pth)
  (if (file-exists? dir-pth)
      #f
      (or (directory-exists? dir-pth)
          (miss-on-failure 'cached-directory-exists? dir-pth
                           (lambda () (consult-archive/directory-exists? dir-pth))))))

(define (read-cache pth)
  (if (file-exists? pth)
      (file->value pth)
      (or (miss-on-failure 'read-cache pth (lambda () (consult-archive pth)))
          (raise-not-cached "read-cache: File is not cached: ~e" pth))))
(define (read-cache* pth)
  ;; also reports a corrupt cache file, which `file->value` rejects
  (miss-on-failure 'read-cache* pth (lambda () (read-cache pth))))
(define (write-cache! pth v)
  (write-to-file* v pth))
(define (delete-cache! pth)
  (swallow 'delete-cache! pth (lambda () (delete-file pth))
           #:expected? exn:fail:filesystem?)
  (void))

(provide/contract
 [cache/file-mode (parameter/c (symbols 'always 'cache 'no-cache))]
 [cache/file (path-string? (-> any/c) . -> . any/c)]
 [cache/file/timestamp (path-string? (-> void) . -> . void)]
 [cached-directory-list* (path-string? . -> . (listof path-string?))]
 [cached-directory-exists? (path-string? . -> . boolean?)]
 [read-cache (path-string? . -> . any/c)]
 [read-cache* (path-string? . -> . any/c)]
 [write-cache! (path-string? any/c . -> . void)]
 [delete-cache! (path-string? . -> . void)])

(module+ test
  (require rackunit
           (submod "notify.rkt" test-support))

  (define (warnings-for thunk)
    (warnings-during (lambda () (check-false (miss-on-failure 'test "/x" thunk)))))

  ;; ordinary misses are quiet
  (check-equal? (warnings-for (lambda () (call-with-input-file "/no/such/file" read))) '())
  (check-equal? (warnings-for (lambda () (raise-not-cached "~e is not in the archive" "/x")))
                '())

  ;; a bug is reported however it is worded, including the contract
  ;; violation `path->revision` used to raise for every archived build
  (check-equal? (length (warnings-for (lambda () (error 'oops "is not in the archive")))) 1)
  (check-equal? (length (warnings-for
                         (lambda ()
                           (raise (exn:fail:contract "path->revision: broke its own contract"
                                                     (current-continuation-marks))))))
                1))
