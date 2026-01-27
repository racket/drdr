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

