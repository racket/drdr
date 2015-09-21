#lang racket/base
(require racket/system
         racket/file
         "config.rkt"
         "archive.rkt"
         "path-utils.rkt"
         "dirstruct.rkt")

(define (make-archive rev)
  (define archive-path (revision-archive rev))
  (cond [(file-exists? archive-path)
         (printf "r~a is already archived\n" rev)
         #t]
        [(zero? (modulo rev 100))
         (printf "r~a is saved for posterity\n" rev)
         #t]
        [else
         (define tmp-path (make-temporary-file))
         (printf "Archiving r~a\n" rev)
         (safely-delete-directory (revision-trunk.tgz rev))
         (safely-delete-directory (revision-trunk.tar.7z rev))
         (create-archive tmp-path (revision-dir rev))
         (rename-file-or-directory tmp-path archive-path)
         (safely-delete-directory (revision-log-dir rev))
         (safely-delete-directory (revision-analyze-dir rev))
         (for ([x (in-list '("analyzed" "archiving-done" "checkout-done"
                             "commit-msg" "integrated" "timing-done"
                             "recompressing"))])
           (safely-delete-directory (build-path (revision-dir rev) x)))
         #f]))

(provide make-archive)
