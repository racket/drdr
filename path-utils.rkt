#lang racket/base
(require racket/list
         racket/path
         racket/contract/base
         racket/file
         "notify.rkt")

(define current-temporary-directory
  (make-parameter #f))

(define (directory-list->directory-list* l)
  (sort (filter-not (compose 
                     (lambda (s)
                       (or (regexp-match #rx"^\\." s)
                           (string=? "compiled" s)
                           (link-exists? s)))
                     path->string)
                    l)
        string<=? #:key path->string #:cache-keys? #t))

(define (directory-list* pth)
  (directory-list->directory-list* (directory-list pth)))

(define (safely-delete-directory pth)
  (swallow 'safely-delete-directory pth (lambda () (delete-directory/files pth))
           #:expected? exn:fail:filesystem?)
  (void))

(define (make-parent-directory pth)  
  (define pth-dir (path-only pth))
  (make-directory* pth-dir))

(define (write-to-file* v pth)
  (define tpth (make-temporary-file))
  (write-to-file v tpth #:exists 'truncate)
  (make-parent-directory pth)
  (rename-file-or-directory tpth pth #t))

(define (rebase-path from to)
  (define froms (explode-path from))
  (define froms-len (length froms))
  (lambda (pth)
    (define pths (explode-path pth))
    (apply build-path to (list-tail pths froms-len))))

(define (path->string* pth-string)
  (if (string? pth-string)
      pth-string
      (path->string pth-string)))

;; If `pth` is `root` or lies under it, the path elements below `root`;
;; otherwise #f.
(define (path-prefix-split pth root)
  (define root-parts (explode-path root))
  (define pth-parts (explode-path pth))
  (define root-len (length root-parts))
  (and ((length pth-parts) . >= . root-len)
       (equal? (for/list ([p (in-list pth-parts)] [_ (in-range root-len)]) p)
               root-parts)
       (list-tail pth-parts root-len)))

(provide/contract
 [path-prefix-split (path-string? path-string? . -> . (or/c false/c (listof path?)))]
 [current-temporary-directory (parameter/c (or/c false/c path-string?))]
 [safely-delete-directory (path-string? . -> . void)]
 [directory-list->directory-list* ((listof path?) . -> . (listof path?))]
 [directory-list* (path-string? . -> . (listof path?))]
 [write-to-file* (any/c path-string? . -> . void)]
 [make-parent-directory (path-string? . -> . void)]
 [rebase-path (path-string? path-string? . -> . (path-string? . -> . path?))]
 [path->string* (path-string? . -> . string?)])

(module+ test
  (require rackunit)

  (check-equal? (path-prefix-split "/opt/plt/builds/73400/logs" "/opt/plt/builds")
                (map string->path '("73400" "logs")))
  (check-equal? (path-prefix-split "/extra/builds/55389/logs" "/extra/builds")
                (map string->path '("55389" "logs")))
  (check-equal? (path-prefix-split "/opt/plt/builds" "/opt/plt/builds") '())
  ;; a different prefix of the same length does not match
  (check-false (path-prefix-split "/opt/plt/other/73400" "/opt/plt/builds"))
  (check-false (path-prefix-split "/opt/plt" "/opt/plt/builds")))
