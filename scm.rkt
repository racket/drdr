#lang racket/base
(require racket/contract/base
         racket/port
         racket/file
         racket/string
         racket/match
         racket/list
         racket/function
         "svn.rkt"
         "path-utils.rkt"
         "dirstruct.rkt"
         net/url
         racket/system)
(provide (all-from-out "svn.rkt"))

(define git-path (make-parameter "/opt/local/bin/git"))
(provide/contract
 [git-path (parameter/c string?)])

(define git-url-base "http://git.racket-lang.org/plt.git")

(provide/contract
 [newest-push (-> number?)])
(define (newest-push)
  ;; xxx may be empty
  (push-data-num (first (pushes-intermediates (current-pushes)))))

(define-struct push-data (num who end-commit branches) #:prefab)

(define (push-info push-n)
  (or (for/or ([pd (in-list (pushes-intermediates (current-pushes)))])
        (and (= push-n (push-data-num pd))
             pd))
      (error 'push-info "~a does not exist" push-n)))

(define (pipe/proc cmds)
  (if (null? (cdr cmds))
      ((car cmds))
      (let-values ([(i o) (make-pipe 4096)])
        (parameterize ([current-output-port o])
          (thread (lambda () ((car cmds)) (close-output-port o))))
        (parameterize ([current-input-port i])
          (pipe/proc (cdr cmds))))))
(define-syntax-rule (pipe expr exprs ...)
  (pipe/proc (list (lambda () expr) (lambda () exprs) ...)))

(define (close-input-port* p)
  (when p (close-input-port p)))
(define (close-output-port* p)
  (when p (close-output-port p)))

(define (system/output-port #:k k #:stdout [init-stdout #f] . as)
  (define-values (sp stdout stdin stderr)
    (apply subprocess init-stdout #f #f as))
  (begin0 (k stdout)
    (subprocess-wait sp)
    (subprocess-kill sp #t)
    (close-input-port* stdout)
    (close-output-port* stdin)
    (close-input-port* stderr)))

(define-struct git-push (num author commits) #:prefab)
(define-struct git-commit (hash author date msg) #:prefab)
(define-struct (git-diff git-commit) (mfiles) #:prefab)
(define-struct (git-merge git-commit) (from to) #:prefab)

(define-struct git-commit* (branch hash author date msg) #:prefab)
(define-struct (git-diff* git-commit*) (mfiles) #:prefab)
(define-struct (git-merge* git-commit*) (from to) #:prefab)

(define (read-until-empty-line in-p)
  (let loop ()
    (let ([l (read-line in-p)])
      (cond
        [(eof-object? l)
         (close-input-port in-p)
         empty]
        [(string=? l "")
         empty]
        [else
         (list* (regexp-replace #rx"^ +" l "") (loop))]))))

(define (read-commit branch in-p)
  (match (read-line in-p)
    [(? eof-object?)
     #f]
    [(regexp #rx"^commit +(.+)$" (list _ hash))
     (match (read-line in-p)
       [(regexp #rx"^Merge: +(.+) +(.+)$" (list _ from to))
        (match-define (regexp #rx"^Author: +(.+)$" (list _ author)) (read-line in-p))
        (match-define (regexp #rx"^Date: +(.+)$" (list _ date)) (read-line in-p))
        (define _1 (read-line in-p))
        (define msg (read-until-empty-line in-p))
        (make-git-merge* branch hash author date msg from to)]
       [(regexp #rx"^Author: +(.+)$" (list _ author))
        (match-define (regexp #rx"^Date: +(.+)$" (list _ date)) (read-line in-p))
        (define _1 (read-line in-p))
        (define msg (read-until-empty-line in-p))
        (define mfiles (read-until-empty-line in-p))
        (make-git-diff* branch hash author date msg mfiles)])]))

(define port-empty? port-closed?)

(define (read-commits branch in-p)
  (cond
    [(port-empty? in-p)
     empty]
    [(read-commit branch in-p)
     => (lambda (c)
          (printf "~S\n" c)
          (list* c (read-commits branch in-p)))]
    [else
     empty]))

(define (get-scm-commit-msg rev repo)
  (match-define (struct push-data (_ who _ branches)) (push-info rev))
  (make-git-push
   rev who
   (apply append
          (for/list
              ([(branch cs) branches])
            (match-define (vector start-commit end-commit) cs)
            (parameterize
                ([current-directory repo])
              (system/output-port
               #:k (curry read-commits branch)
               (git-path)
               "--no-pager" "log" "--date=iso" "--name-only" "--no-merges"
               (format "~a..~a" start-commit end-commit)))))))
(provide/contract
 [struct git-push
   ([num exact-nonnegative-integer?]
    [author string?]
    [commits (listof (or/c git-commit? git-commit*?))])]
 [struct git-commit
   ([hash string?]
    [author string?]
    [date string?]
    [msg (listof string?)])]
 [struct git-diff
   ([hash string?]
    [author string?]
    [date string?]
    [msg (listof string?)]
    [mfiles (listof string?)])]
 [struct git-merge
   ([hash string?]
    [author string?]
    [date string?]
    [msg (listof string?)]
    [from string?]
    [to string?])]
 [struct git-commit*
   ([branch string?]
    [hash string?]
    [author string?]
    [date string?]
    [msg (listof string?)])]
 [struct git-diff*
   ([branch string?]
    [hash string?]
    [author string?]
    [date string?]
    [msg (listof string?)]
    [mfiles (listof string?)])]
 [struct git-merge*
   ([branch string?]
    [hash string?]
    [author string?]
    [date string?]
    [msg (listof string?)]
    [from string?]
    [to string?])]
 [get-scm-commit-msg (exact-nonnegative-integer? path-string? . -> . git-push?)])

(define (git-commit-msg* gc)
  (if (git-commit? gc)
      (git-commit-msg gc)
      (git-commit*-msg gc)))
(define (git-commit-hash* gc)
  (if (git-commit? gc)
      (git-commit-hash gc)
      (git-commit*-hash gc)))

(provide/contract
 [git-commit-hash* (-> (or/c git-commit? git-commit*?) string?)]
 [git-commit-msg* (-> (or/c git-commit? git-commit*?) (listof string?))])

(define (git-push-previous-commit gp)
  (define start (git-push-start-commit gp))
  (parameterize ([current-directory (plt-repository)])
    (system/output-port
     #:k (λ (port) (read-line port))
     (git-path)
     "--no-pager" "log" "--format=format:%P" start "-1")))
(define (git-push-start-commit gp)
  (define cs (git-push-commits gp))
  (if (empty? cs)
      "xxxxxxxxxxxxxxxxxxxxxxxxx"
      (git-commit-hash* (last cs))))
(define (git-push-end-commit gp)
  (define cs (git-push-commits gp))
  (if (empty? cs)
      "xxxxxxxxxxxxxxxxxxxxxxxxx"
      (git-commit-hash* (first cs))))
(provide/contract
 [git-push-previous-commit (git-push? . -> . string?)]
 [git-push-start-commit (git-push? . -> . string?)]
 [git-push-end-commit (git-push? . -> . string?)])

(define scm-commit-author
  (match-lambda
    [(? git-push? gp) (git-push-author gp)]
    [(? svn-rev-log? srl) (svn-rev-log-author srl)]))
(provide/contract
 [scm-commit-author ((or/c git-push? svn-rev-log?) . -> . string?)])

(define (scm-export-file rev repo file dest)
  (define commit
    (push-data-end-commit (push-info rev)))
  (call-with-output-file*
    dest
    #:exists 'truncate/replace
    (lambda (file-port)
      (parameterize ([current-directory repo])
        (system/output-port
         #:k void
         #:stdout file-port
         (git-path) "--no-pager" "show" (format "~a:~a" commit file)))))
  (void))

(define (scm-export-repo rev repo dest)
  (define end (push-data-end-commit (push-info rev)))
  (printf "Exporting ~v where end = ~a\n"
          (list rev repo dest)
          end)
  (pipe
   (parameterize ([current-directory repo])
     (system*
      (git-path) "archive"
      (format "--prefix=~a/"
              (regexp-replace #rx"/+$" (path->string* dest) ""))
      "--format=tar"
      end))
   (system* (find-executable-path "tar") "xf" "-" "--absolute-names"))
  (void))

(define (scm-update repo)
  (parameterize ([current-directory repo])
    (system* (git-path) "fetch")
    (system* (git-path) "pull"))
  (void))

(define master-branch "refs/heads/master")
(define release-branch "refs/heads/release")

;; branch->head : hash branch:str checksum:str
;; intermediates : listof push-data
(struct pushes (branch->head intermediates) #:prefab)
(define (current-pushes)
  (define p (plt-new-pushes-file))
  (if (file-exists? p)
      (file->value p)
      (pushes (hash) empty)))
(define (current-pushes! v)
  (define p (plt-new-pushes-file))
  (write-to-file v p #:exists 'replace))

(define (scm-branch-heads)
  (define (read-heads p)
    (for/fold ([h (hash)]) ([l (in-lines p)])
      (match-define (list head branch) (string-split l))
      (hash-set h branch head)))
  (parameterize ([current-directory (plt-repository)])
    (system/output-port
     #:k (λ (port) (read-heads port))
     (git-path) "show-ref" "--heads")))

(define (branches-identical? old-ht new-ht)
  (for/and ([(b n) (in-hash new-ht)])
    (equal? n (hash-ref old-ht b #f))))

(define BLANK-BRANCH-INFO (vector #f #f))
(define (push-data-branch-info->bend v)
  (vector-ref v 1))

(define (contains-branch-end? pds branch bend)
  (for/or ([pd (in-list pds)])
    (equal? bend
            (push-data-branch-info->bend
             (hash-ref (push-data-branches pd) branch BLANK-BRANCH-INFO)))))

(define (extract-git-commit-author bend)
  (parameterize ([current-directory (plt-repository)])
    (system/output-port
     #:k (λ (port)
           (define l (read-line port))
           (if (eof-object? l)
               (error 'extract-git-commit-author "Can't find author of ~v" bend)
               (first (string-split l "@"))))
     (git-path) "--no-pager" "show" "-s" "--format=%ae" bend)))

(define (branch-last ni branch)
  (define l
    (map push-data-branch-info->bend
         (filter-map (λ (pd) (hash-ref (push-data-branches pd) branch #f)) ni)))
  (if (empty? l)
      #f
      (last l)))

(define (snoc l x)
  (append l (list x)))

(define (scm-revisions-after cur-rev repo)
  (match-define (pushes branch->last-head intermediates)
    (current-pushes))
  (scm-update repo)
  (define branch->cur-head (scm-branch-heads))

  (eprintf "sra: ~v\n"
           (vector 'cur-rev cur-rev 'repo repo
                   'branch->last-head branch->last-head
                   'intermediates intermediates
                   'branch->cur-head branch->cur-head))

  (define new-intermediates
    (cond
      [(and (branches-identical? branch->last-head branch->cur-head)
            (= 1 (length intermediates))
            (hash-ref (push-data-branches (first intermediates))
                      master-branch #f)
            (= cur-rev (push-data-num (first intermediates))))
       (list (struct-copy push-data (first intermediates)
                          [num (add1 cur-rev)]))]
      [else
       (for/fold ([ni intermediates]) ([(branch bend) (in-hash branch->cur-head)])
         (cond
           [(contains-branch-end? ni branch bend)
            ni]
           [else
            (define bstart (or (branch-last ni branch) bend))
            (snoc ni
                  (make-push-data
                   (add1 cur-rev)
                   (extract-git-commit-author bend) bend
                   (make-immutable-hash
                    (list (cons branch (vector bstart bend))))))]))]))

  (current-pushes! (pushes branch->cur-head new-intermediates))
  (map push-data-num new-intermediates))

(provide/contract
 [scm-update
  (-> path?
      void?)]
 [scm-revisions-after
  (-> exact-nonnegative-integer? path-string?
      (listof exact-nonnegative-integer?))]
 [scm-export-file
  (-> exact-nonnegative-integer? path-string? string? path-string?
      void?)]
 [scm-export-repo
  (-> exact-nonnegative-integer? path-string? path-string?
      void?)])
