#lang racket/base
(require "path-utils.rkt"
         "archive.rkt"
         racket/file
         rackunit)

(define archive
  "../test.archive")

;; Create the archive
(create-archive archive (current-directory))

;; Test archive extraction for all files
(for ([fp (in-list (directory-list* (current-directory)))]
      #:when (file-exists? fp))
  (check-equal? (archive-extract-file archive (build-path (current-directory) fp))
                (file->bytes fp)))

;; Test error cases
(check-exn #rx"not in the archive"
           (lambda () (archive-extract-file archive "test")))

(check-exn #rx"not in the archive"
           (lambda () (archive-extract-file archive (build-path (current-directory) "test"))))

(check-exn #rx"not a file"
           (lambda () (archive-extract-file archive (build-path (current-directory) "static"))))

(check-exn #rx"not a valid archive"
           (lambda () (archive-extract-file "archive-test.rkt" (build-path (current-directory) "archive-test.rkt"))))

;; Test directory listing
(check-equal? (directory-list->directory-list* (archive-directory-list archive (current-directory)))
              (directory-list* (current-directory)))

;; Test directory existence checks
(check-true (archive-directory-exists? archive (current-directory)))
(check-true (archive-directory-exists? archive (build-path (current-directory) "static")))
(check-false (archive-directory-exists? archive (build-path (current-directory) "unknown")))
(check-false (archive-directory-exists? archive (build-path (current-directory) "archive-test.rkt")))

;; A path under a different root with the same number of elements must not
;; resolve; stripping elements without comparing them used to read an entry
;; from the wrong level.
(define cwd-parts (explode-path (current-directory)))
(define bogus-root
  (apply build-path (car cwd-parts)
         (for/list ([_ (in-list (cdr cwd-parts))] [n (in-naturals)])
           (string->path-element (format "bogus~a" n)))))
(check-false (archive-directory-exists? archive (build-path bogus-root "static")))
(check-exn #rx"not in the archive"
           (lambda () (archive-extract-file archive (build-path bogus-root "archive-test.rkt"))))

;; With `#:base`, a path under the new root finds the entry the archive
;; recorded under the old one.
(check-equal? (archive-extract-file archive (build-path bogus-root "archive-test.rkt")
                                    #:base bogus-root)
              (file->bytes "archive-test.rkt"))
