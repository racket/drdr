#lang at-exp racket/base
(require racket/list
         racket/local
         racket/function
         racket/match
         racket/file
         racket/port
         racket/string
         racket/system
         racket/date
         racket/runtime-path
         xml
         "config.rkt"
         "diff.rkt"
         "list-count.rkt"
         "cache.rkt"
         (except-in "dirstruct.rkt"
                    revision-trunk-dir)
         "status.rkt"
         "monitor-scm.rkt"
         "formats.rkt"
         "path-utils.rkt"
         "analyze.rkt"
         "status-analyze.rkt")

(define (base-path pth)
  (define rev (current-rev))
  (define log-dir (revision-log-dir rev))
  ((rebase-path log-dir "/") pth))

(define-runtime-path static "static")

(define (snoc l x) (append l (list x)))
(define (list-head l n)
  (if (zero? n)
      empty
      (list* (first l)
             (list-head (rest l) (sub1 n)))))
(define (all-but-last l) (list-head l (sub1 (length l))))

(define (to-index i)
  (cond
    [(<= i 0) "."]
    [else
     (apply string-append (snoc (add-between (make-list i "..") "/") "/"))]))

(define (current-depth log-pth directory?)
  (define new-pth ((rebase-path (revision-log-dir (current-rev)) "/") log-pth))
  (define depth (sub1 (length (explode-path new-pth))))
  (if directory? 
      depth
      (sub1 depth)))

(define (next-rev)
  (init-revisions!)
  (local [(define end (newest-completed-revision))]
    (let loop ([rev (add1 (current-rev))])
      (cond
        [(not end)
         #f]
        [(<= end rev)
         end]
        [(read-cache* (build-path (revision-dir rev) "analyzed"))
         rev]
        [else
         (loop (add1 rev))]))))

(define (path->breadcrumb pth directory?)
  (define the-rev (current-rev))
  (define new-pth ((rebase-path (revision-log-dir the-rev) "/") pth))
  (define parts (rest (explode-path new-pth)))
  (define string-parts (list* (format "R~a" the-rev) (map path->string parts)))
  (define (parent-a href sp)
    `(a ([class "parent"] [href ,href]) ,sp))
  (define the-base-path*
    (format "~a~a"
            (base-path pth)
            (if directory? "/" "")))
  (define the-base-path
    (if (string=? the-base-path* "//")
        "/"
        the-base-path*))
  (define prev-rev-url (format "/~a~a" (previous-rev) the-base-path))
  (define next-rev-url (format "/~a~a" (next-rev) the-base-path))
  (define prev-change-url (format "/previous-change/~a~a" the-rev the-base-path))
  (define next-change-url (format "/next-change/~a~a" the-rev the-base-path))
  (define cur-rev-url (format "/~a~a" "current" the-base-path))
  ;; XXX Don't special case top level
  (values (apply string-append 
                 (add-between (list* "DrDr" string-parts) " / "))
          `(span
            (span ([class "breadcrumb"])
                  ,(parent-a "/" "DrDr") " / "
                  ,@(add-between
                     (snoc
                      (for/list 
                          ([sp (in-list (all-but-last string-parts))]
                           [from-root (in-naturals)])
                        (define the-depth 
                          (current-depth pth directory?))
                        (parent-a 
                         (to-index (- the-depth from-root)) sp))
                      `(span ([class "this"]) 
                             ,(last string-parts)))
                     " / "))
            (span ([class "revnav"])
                  ,@(if directory?
                      empty
                      `((a ([href ,prev-change-url])
                           (img ([src "/images/rewind-change.png"])))))
                  (a ([href ,prev-rev-url])
                     (img ([src "/images/rewind.png"])))
                  (a ([href ,next-rev-url])
                     (img ([src "/images/fast-forward.png"])))
                  ,@(if directory?
                      empty
                      `((a ([href ,next-change-url])
                           (img ([src "/images/fast-forward-change.png"])))))
                  (a ([href ,cur-rev-url])
                     (img ([src "/images/skip-forward1.png"])))))))

(define (looks-like-directory? pth)
  (and (regexp-match #rx"/$" pth) #t))

(define (make-timestamp-span utc-display-text timestamp-seconds)
  `(span ([class "timestamp"]
          [data-timestamp ,(number->string timestamp-seconds)]
          [title ,(format "UTC: ~a" utc-display-text)])
         ,utc-display-text))

(define (svn-date->nice-date date)
  (define nice-date (regexp-replace "^(....-..-..)T(..:..:..).*Z$" date "\\1 \\2"))
  (with-handlers ([exn:fail? (lambda (x) nice-date)])
    (match (regexp-match #rx"^(....)-(..)-(..T)(..):(..):(..).*Z$" date)
      [(list _ year month dayT hour minute second)
       (define day (substring dayT 0 2))
       (define timestamp (find-seconds (string->number second)
                                     (string->number minute)
                                     (string->number hour)
                                     (string->number day)
                                     (string->number month)
                                     (string->number year)))
       (make-timestamp-span nice-date timestamp)]
      [else nice-date])))
(define (git-date->nice-date date)
  (define nice-date (regexp-replace "^(....-..-..) (..:..:..).*$" date "\\1 \\2"))
  (with-handlers ([exn:fail? (lambda (x) nice-date)])
    ; Parse "2023-12-25 10:30:45 +0000" format
    (match (regexp-match #rx"^([0-9][0-9][0-9][0-9])-([0-9][0-9])-([0-9][0-9]) ([0-9][0-9]):([0-9][0-9]):([0-9][0-9]).*$" date)
      [(list _ year month day hour minute second)
       (define timestamp (find-seconds (string->number second)
                                     (string->number minute)
                                     (string->number hour)
                                     (string->number day)
                                     (string->number month)
                                     (string->number year)))
       (make-timestamp-span nice-date timestamp)]
      [else nice-date])))
(define (log->url log)
  (define start-commit (git-push-start-commit log))
  (define end-commit (git-push-end-commit log))
  (if (string=? start-commit end-commit)
      (format "http://github.com/racket/racket/commit/~a" end-commit)
      (format "http://github.com/racket/racket/compare/~a...~a"
              (git-push-previous-commit log) end-commit)))

(define (format-commit-msg)
  (define pth (revision-commit-msg (current-rev)))
  (define (timestamp pth)
    (with-handlers ([exn:fail? (lambda (x) "")])
      (define secs (read-cache
                    (build-path (revision-dir (current-rev)) pth)))
      (define utc-time-str (date->string (seconds->date secs) #t))
      (make-timestamp-span utc-time-str secs)))
  (define bdate/s (timestamp "checkout-done"))
  (define bdate/e (timestamp "integrated"))
  (match (read-cache* pth)
    [(and gp (struct git-push (num author commits)))
     (define start-commit (git-push-start-commit gp))
     (define end-commit (git-push-end-commit gp))
     `(table 
       ([class "data"])
       (tr ([class "author"]) (td "Author:") (td ,author))
       (tr ([class "date"]) (td "Build Start:") (td ,bdate/s))
       (tr ([class "date"]) (td "Build End:") (td ,bdate/e))
       ,@(if (file-exists? (revision-trunk.tgz (current-rev)))
             `((tr ([class "date"])
                   (td "Archive") 
                   (td (a 
                        ([href
                          ,(format "/builds/~a/trunk.tgz" 
                                   (current-rev))])
                        "trunk.tgz"))))
             `())
       ,@(if (file-exists? (revision-trunk.tar.7z (current-rev)))
             `((tr ([class "date"])
                   (td "Archive") 
                   (td (a 
                        ([href
                          ,(format "/builds/~a/trunk.tar.7z" 
                                   (current-rev))])
                        "trunk.tar.7z"))))
             `())
       (tr ([class "hash"]) 
           (td "Diff:") 
           (td (a ([href ,(log->url gp)]) 
                  ,(substring start-commit 0 8)
                  ".." ,(substring end-commit 0 8))))
       ,@(append-map
          (match-lambda
            [(or (and (struct git-merge (hash author date msg from to))
                      (app (λ (x) #f) branch))
                 (struct git-merge* (branch hash author date msg from to)))
             ; Don't display these "meaningless" commits
             empty]
            [(or (and (struct git-diff (hash author date msg mfiles))
                      (app (λ (x) #f) branch))
                 (struct git-diff* (branch hash author date msg mfiles)))
             (define cg-id (symbol->string (gensym 'changes)))
             (define ccss-id
               (symbol->string (gensym 'changes)))
             `(,@(if branch
                     (list `(tr ([class "branch"]) (td "Branch:") (td ,branch)))
                     empty)
               (tr 
                ([class "hash"])
                (td "Commit:")
                (td 
                 (a 
                  ([href
                    ,(format "http://github.com/racket/racket/commit/~a"
                             hash)])
                  ,hash)))
               (tr ([class "date"])
                   (td "Date:")
                   (td ,(git-date->nice-date date)))
               (tr ([class "author"]) (td "Author:") (td ,author))
               (tr ([class "msg"]) (td "Log:") (td (pre ,@(add-between msg "\n"))))
               (tr ([class "changes"]) 
                   (td 
                    (a ([href ,(format "javascript:TocviewToggle(\"~a\",\"~a\");" cg-id ccss-id)])
                       (span ([id ,cg-id]) 9658) "Changes:"))
                   (td
                    (div 
                     ([id ,ccss-id]
                      [style "display: none;"])
                     ,@(for/list ([path (in-list mfiles)])
                         `(p 
                           ([class "output"])
                           ,(if 
                             (regexp-match #rx"^collects" path)
                             (let ()
                               (define path-w/o-trunk
                                 (apply build-path 
                                        (explode-path path)))
                               (define html-path
                                 (if (looks-like-directory? path)
                                     (format "~a/" path-w/o-trunk)
                                     path-w/o-trunk))
                               (define path-url
                                 (path->string* html-path))
                               (define path-tested?
                                 #t)
                               (if path-tested?
                                   `(a ([href ,path-url]) ,path)
                                   path))
                             path)))))))])
          commits))]
    
    [(struct svn-rev-log (num author date msg changes))
     (define url (format "http://svn.racket-lang.org/view?view=rev&revision=~a" num))
     (define cg-id (symbol->string (gensym 'changes)))
     (define ccss-id (symbol->string (gensym 'changes)))
     `(table
       ([class "data"])
       (tr ([class "author"]) (td "Author:") (td ,author))
       (tr ([class "date"]) 
           (td "Build Start:")
           (td ,bdate/s))
       (tr ([class "date"]) (td "Build End:") (td ,bdate/e))
       (tr ([class "rev"])
           (td "Commit:")
           (td (a ([href ,url]) ,(number->string num))))
       (tr ([class "date"])
           (td "Date:")
           (td ,(svn-date->nice-date date)))
       (tr ([class "msg"]) (td "Log:") (td (pre ,msg)))
       (tr ([class "changes"]) 
           (td 
            (a ([href 
                 ,(format
                   "javascript:TocviewToggle(\"~a\",\"~a\");"
                   cg-id ccss-id)])
               (span ([id ,cg-id]) 9658) "Changes:"))
           (td
            (div 
             ([id ,ccss-id]
              [style "display: none;"])
             ,@(map 
                (match-lambda
                  [(struct svn-change (action path))
                   `(p ([class "output"])
                       ,(symbol->string action) " " 
                       ,(if (regexp-match
                             #rx"^/trunk/collects"
                             path)
                            (local 
                              [(define path-w/o-trunk
                                 (apply build-path
                                        (list-tail
                                         (explode-path path) 2)))
                               (define html-path
                                 (if (looks-like-directory? path)
                                     (format "~a/" path-w/o-trunk)
                                     path-w/o-trunk))
                               (define path-url
                                 (path->string* html-path))
                               (define path-tested?
                                 #t)]
                              (if path-tested?
                                  `(a ([href ,path-url]) ,path)
                                  path))
                            path))])
                changes)))))]
    [else
     '" "]))

(define (format-responsible r)
  (string-append* (add-between (string-split r ",") ", ")))

(define drdr-start-request (make-parameter #f))
(define (footer)
  `(div ([id "footer"])
        "Powered by " (a ([href "http://racket-lang.org/"]) "Racket") ". "
        "Written by " (a ([href "http://jeapostrophe.github.io"]) "Jay McCarthy") ". "
        (a ([href "/help"])
           "Need help?")
        (br)
        "Current time: "
        ,(let ([curr-secs (current-seconds)])
           (define utc-time-str (date->string (seconds->date curr-secs) #t))
           (make-timestamp-span utc-time-str curr-secs))
        "Render time: "
        ,(real->decimal-string
          (- (current-inexact-milliseconds) (drdr-start-request)))
        "ms"))

(define (render-event e)
  (with-handlers ([exn:fail?
                   (lambda (x)
                     `(pre ([class "unprintable"]) "UNPRINTABLE"))])
    (match e
      [(struct stdout (bs))
       `(pre ([class "stdout"]) ,(bytes->string/utf-8 bs))]
      [(struct stderr (bs))
       `(pre ([class "stderr"]) ,(bytes->string/utf-8 bs))])))

(define (json-out out x)
  (cond
   [(list? x)
    (fprintf out "[")
    (let loop ([l x])
      (match l
        [(list)
         (void)]
        [(list e)
         (json-out out e)]
        [(list-rest e es)
         (json-out out e)
         (fprintf out ",")
         (loop es)]))
    (fprintf out "]")]
   [else
    (display x out)]))
          
(define (json-timing req path-to-file)
  (define timing-pth (path-timing-log (apply build-path path-to-file)))
  (define ts (file->list timing-pth))
  (response
   200 #"Okay"
   (file-or-directory-modify-seconds timing-pth)
   #"application/json"
   (list (make-header #"Access-Control-Allow-Origin"
                      #"*"))
   (lambda (out)
     (fprintf out "[")
     (for ([l (in-list (add-between ts ","))])
          (json-out out l))         
     (fprintf out "]"))))

(define (render-log log-pth)
  (match (log-rendering log-pth)
    [#f
     (file-not-found log-pth)]
    [(and the-log-rendering 
          (struct rendering 
            (start end dur _ _ _ responsible changed)))
     (match (read-cache log-pth)
       [(and log (struct status (_ _ command-line output-log)))
        (define-values (title breadcrumb) (path->breadcrumb log-pth #f))
        (define the-base-path
          (base-path log-pth))
        (define scm-url
          (if ((current-rev) . < . 20000)
              (format "http://svn.racket-lang.org/view/trunk/~a?view=markup&pathrev=~a"
                      the-base-path
                      (current-rev))
              (local [(define msg (read-cache* (revision-commit-msg (current-rev))))]
                (if msg
                    (format "http://github.com/racket/racket/blob/~a~a"
                            (git-push-end-commit msg) the-base-path)
                    "#"))))
        (define prev-rev-url (format "/~a~a" (previous-rev) the-base-path))
        (define cur-rev-url (format "/~a~a" "current" the-base-path))
        (define s-output-log (log-divide output-log))
        (define (timestamp msecs)
          (define secs (/ msecs 1000))
          (with-handlers ([exn:fail? (lambda (x) "")])
            (define utc-time-str (format "~a.~a"
                                       (date->string (seconds->date secs) #t)
                                       (substring
                                        (number->string
                                         (/ (- msecs (* 1000 (floor secs))) 1000))
                                        2)))
            (make-timestamp-span utc-time-str (inexact->exact (floor secs)))))
        (response/xexpr
         `(html 
           (head (title ,title)
                 (script ([language "javascript"] [type "text/javascript"] 
                          [src "/jquery-1.6.2.min.js"]) "")
                 (script ([language "javascript"] [type "text/javascript"]
                          [src "/jquery.flot.js"]) "")
                 (script ([language "javascript"] [type "text/javascript"]
                          [src "/jquery.flot.selection.js"]) "")
                 (script ([language "javascript"] [type "text/javascript"])
                         "
                         $(document).ready(function() {
                           $('.timestamp').each(function() {
                             var $span = $(this);
                             var timestamp = parseInt($span.attr('data-timestamp'));
                             if (!isNaN(timestamp)) {
                               var utcTime = $span.text();
                               var localDate = new Date(timestamp * 1000);
                               var localTime = localDate.toLocaleString();
                               $span.text(localTime);
                               $span.attr('title', 'UTC: ' + utcTime);
                             }
                           });
                         });
                         ")
                 (link ([rel "stylesheet"] [type "text/css"] [href "/render.css"])))
                (body 
                 (div ([class "log, content"])
                      ,breadcrumb
                      (table ([class "data"])
                             (tr (td "Responsible:")
                                 (td ,(format-responsible responsible)))
                             (tr (td "Command-line:") 
                                 (td ,@(add-between
                                        (map (lambda (s)
                                               `(span ([class "commandline"]) ,s))
                                             command-line)
                                        " ")))
                             (tr ([class "date"]) 
                                 (td "Start:")
                                 (td ,(timestamp start)))
                             (tr ([class "date"]) 
                                 (td "End:")
                                 (td ,(timestamp end)))
                             (tr (td "Duration:")
                                 (td ,(format-duration-ms dur)
                                     nbsp (a ([href ,(format "/json/timing~a" the-base-path)])
                                             "(timing data)")))
                             (tr (td "Timeout:") (td ,(if (timeout? log) checkmark-entity "")))
                             (tr (td "Exit Code:") (td ,(if (exit? log) (number->string (exit-code log)) "")))
                             (tr (td "Random?") (td ,(if (rendering-random? the-log-rendering) "Yes" "No")))
                             (tr (td "History:")
                                 (td (a ([href ,(format "/file-history~a" the-base-path)])
                                        "All results for this file"))))
                      ,(if (lc-zero? changed)
                           ""
                           `(div ([class "error"])
                                 "The result of executing this file has changed since the previous push."
                                 " "
                                 (a ([href ,(format "/diff/~a/~a~a" (previous-rev) (current-rev) the-base-path)])
                                    "See the difference")))
                      ,@(if (empty? output-log)
                            '()
                            (append*
                             (for/list ([o-block (in-list s-output-log)]
                                        [i (in-naturals)])
                               `((span ([id ,(format "output~a" i)]) " ")
                                 ,(if (> (length s-output-log) (add1 i))
                                    `(div ([class "error"])
                                          (a ([href ,(format "#output~a" (add1 i))])
                                             "Skip to the next STDERR block."))
                                    "")
                                 (div 
                                  ([class "output"])
                                  " "
                                  ,@(map render-event o-block))))))

                      (p)
                      
                      (div ([id "_chart"] [style "width:800px;height:300px;"]) "")
                      (script ([language "javascript"] [type "text/javascript"] [src "/chart.js"]) "")
                      (script ([language "javascript"] [type "text/javascript"])
                              ,(format "get_data('~a');" the-base-path))
                      (button ([onclick "reset_chart()"]) "Reset")
                      (button ([id "setlegend"] [onclick "set_legend(!cur_options.legend.show)"])
                              "Hide Legend")
                      
                      ,(footer)))))])]))

(define (number->string/zero v)
  (cond 
    [(zero? v)
     '" "]
    [else
     (number->string v)]))

(define checkmark-entity
  10004)

(define (path->url pth)
  (format "http://drdr.racket-lang.org/~a~a" (current-rev) pth))

(define (render-logs/dir dir-pth #:show-commit-msg? [show-commit-msg? #f])
  (match (dir-rendering dir-pth)
    [#f
     (dir-not-found dir-pth)]
    [(and pth-rendering (struct rendering (tot-start tot-end tot-dur tot-timeout tot-unclean tot-stderr tot-responsible tot-changes)))
     (define files
       (foldl (lambda (sub-pth files)
                (define pth (build-path dir-pth sub-pth))
                (define directory? (cached-directory-exists? pth))
                (define pth-rendering
                  (if directory?
                      (dir-rendering pth)
                      (log-rendering pth)))
                (list* (list directory? sub-pth pth-rendering) files))
              empty
              (cached-directory-list* dir-pth)))
     (define-values (title breadcrumb) (path->breadcrumb dir-pth #t))
     (response/xexpr
      `(html (head (title ,title)
                   (script ([src "/sorttable.js"]) " ")
                   (link ([rel "stylesheet"] [type "text/css"] [href "/render.css"])))
             (body
              (div ([class "dirlog, content"])
                   ,breadcrumb
                   ,(if show-commit-msg?
                        (format-commit-msg)
                        "")
                   
                   ; All files with a status
                   ,(let ()
                      (define log-dir (revision-log-dir (current-rev)))
                      (define base-path 
                        (rebase-path log-dir "/"))
                      `(div ([class "status"])
                            (div ([class "tag"]) "by status")
                            ,@(for/list ([status (in-list (cons "problems" responsible-ht-severity))]
                                         [rendering->list-count (in-list
                                                                 (cons (λ (r) (lc-sort (lc+ (rendering-stderr? r) (rendering-timeout? r) (rendering-unclean-exit? r))))
                                                                       (list rendering-timeout? rendering-unclean-exit?
                                                                             rendering-stderr? rendering-changed?)))])
                                (define lc (rendering->list-count pth-rendering))
                                (define rcss-id (symbol->string (gensym)))
                                (define rg-id (symbol->string (gensym 'glyph)))
                                
                                `(div (a ([href ,(format "javascript:TocviewToggle(\"~a\",\"~a\");" rg-id rcss-id)])
                                         (span ([id ,rg-id]) 9658) " "
                                         ,(format "~a [~a]"
                                                  status
                                                  (lc->number lc)))
                                      (ul ([id ,rcss-id] 
                                           [style ,(format "display: ~a"
                                                           "none")])
                                          ,@(for/list ([pp (lc->list lc)])
                                              (define p (bytes->string/utf-8 pp))
                                              (define bp (base-path p))
                                              `(li (a ([href ,(path->url bp)]) ,(path->string bp)))))))))
                   
                   ,(local [(define responsible->problems
                              (rendering->responsible-ht (current-rev) pth-rendering))
                            (define last-responsible->problems
                              (with-handlers ([exn:fail? (lambda (x) (make-hash))])
                                (define prev-dir-pth ((rebase-path (revision-log-dir (current-rev))
                                                                   (revision-log-dir (previous-rev)))
                                                      dir-pth))
                                (define previous-pth-rendering
                                  (parameterize ([current-rev (previous-rev)])
                                    (dir-rendering prev-dir-pth)))
                                (rendering->responsible-ht (previous-rev) previous-pth-rendering)))
                            (define new-responsible->problems
                              (responsible-ht-difference last-responsible->problems responsible->problems))
                            
                            (define (render-responsible->problems tag responsible->problems)
                              (if (zero? (hash-count responsible->problems))
                                  ""
                                  `(div ([class "status"])
                                        (div ([class "tag"]) ,tag)
                                        ,@(for/list ([(responsible ht) (in-hash responsible->problems)])
                                            (define rcss-id (symbol->string (gensym)))
                                            (define rg-id (symbol->string (gensym 'glyph)))
                                            (define summary
                                              (for/fold ([s ""])
                                                ([id (in-list responsible-ht-severity)])
                                                (define llc (hash-ref ht id empty))
                                                (if (empty? llc)
                                                    s
                                                    (format "~a [~a: ~a]" s id (length llc)))))                                  
                                            `(div (a ([href ,(format "javascript:TocviewToggle(\"~a\",\"~a\");" rg-id rcss-id)])
                                                     (span ([id ,rg-id]) 9658) " "
                                                     ,(format-responsible responsible)
                                                     " " ,summary)
                                                  (blockquote 
                                                   ([id ,rcss-id]
                                                    [style "display: none;"])
                                                   ,@(local [(define i 0)]
                                                       (for/list ([id (in-list responsible-ht-severity)])
                                                         (define llc (hash-ref ht id empty))
                                                         (if (empty? llc)
                                                             ""
                                                             (local [(define display? (< i 2))
                                                                     (define css-id (symbol->string (gensym 'ul)))
                                                                     (define glyph-id (symbol->string (gensym 'glyph)))]
                                                               (set! i (add1 i))
                                                               `(div (a ([href ,(format "javascript:TocviewToggle(\"~a\",\"~a\");" glyph-id css-id)])
                                                                        (span ([id ,glyph-id]) ,(if display? 9660 9658)) " "
                                                                        ,(hash-ref responsible-ht-id->str id))
                                                                     (ul ([id ,css-id] 
                                                                          [style ,(format "display: ~a"
                                                                                          (if display? "block" "none"))])
                                                                         ,@(for/list ([p llc])
                                                                             `(li (a ([href ,(path->url p)]) ,(path->string p))))))))))))))))]
                      `(div ,(render-responsible->problems "all" responsible->problems)
                            ,(render-responsible->problems "new" new-responsible->problems)))
                   (table ([class "sortable, dirlist"])
                          (thead
                           (tr (td "Path")
                               (td "Duration (Abs)")
                               (td "Duration (Sum)")
                               (td "Timeout?")
                               (td "Unclean Exit?")
                               (td "STDERR Output")
                               (td "Changes")
                               (td "Responsible")))
                          (tbody
                           ,@(map (match-lambda
                                    [(list directory? sub-pth (struct rendering (start end dur timeout unclean stderr responsible-party changes)))
                                     (define name (path->string sub-pth))
                                     (define abs-dur (- end start))
                                     (define url 
                                       (if directory?
                                           (format "~a/" name)
                                           name))
                                     `(tr ([class ,(if directory? "dir" "file")]
                                           [onclick ,(format "document.location = ~S" url)])
                                          (td ([sorttable_customkey 
                                                ,(format "~a:~a"
                                                         (if directory? "dir" "file")
                                                         name)])
                                              (a ([href ,url]) ,name ,(if directory? "/" "")))
                                          (td ([sorttable_customkey ,(number->string abs-dur)])
                                              ,(format-duration-ms abs-dur))
                                          (td ([sorttable_customkey ,(number->string dur)])
                                              ,(format-duration-ms dur))
                                          ,@(map (lambda (vv)
                                                   (define v (lc->number vv))
                                                   `(td ([sorttable_customkey ,(number->string v)])
                                                        ,(if directory?
                                                             (number->string/zero v)
                                                             (if (zero? v)
                                                                 '" "
                                                                 checkmark-entity))))
                                                 (list timeout unclean stderr changes))
                                          (td ,(format-responsible responsible-party)))])
                                  (sort files
                                        (match-lambda*
                                          [(list (list dir?1 name1 _)
                                                 (list dir?2 name2 _))
                                           (cond
                                             [(and dir?1 dir?2)
                                              (string<=? (path->string name1)
                                                         (path->string name2))]
                                             [dir?1 #t]
                                             [dir?2 #f])]))))
                          (tfoot
                           (tr ([class "total"])
                               (td "Total")
                               (td ,(format-duration-ms (- tot-end tot-start)))
                               (td ,(format-duration-ms tot-dur))
                               (td ,(number->string/zero (lc->number tot-timeout)))
                               (td ,(number->string/zero (lc->number tot-unclean)))
                               (td ,(number->string/zero (lc->number tot-stderr)))
                               (td ,(number->string/zero (lc->number tot-changes)))
                               (td " "))))
                   ,(footer)))))]))

(define (show-help req)
  (response/xexpr
   `(html
     (head (title "DrDr > Help")
           (link ([rel "stylesheet"] [type "text/css"] [href "/render.css"])))
     (body
      (div ([class "dirlog, content"])
           (span ([class "breadcrumb"])
                 (a ([class "parent"] [href "/"]) "DrDr") " / "
                 (span ([class "this"]) 
                       "Help"))
           @div[[(class "help")]]{
                                  @h1{What is DrDr?}
                                   @p{DrDr is a server at @a[[(href "http://www.indiana.edu/")]]{Indiana University} that builds
                                                          and "tests" every push to the Racket code base.}
                                   
                                   @h1{What kind of server?}
                                   @p{Here is the result of calling @code{uname -a}:}
                                   @pre{@,(with-output-to-string (λ () (system "uname -a")))}
                                   @p{Here is the result of calling @code{cat /etc/issue}:}
                                   @pre{@,(with-output-to-string (λ () (system "cat /etc/issue")))}
                                   @p{The machine has @,(number->string (number-of-cpus)) cores and runs Racket @,(version).}
                                   
                                   @h1{How is the build run?}
                                   @p{Every push is built from a clean checkout with the standard separate build directory command sequence, except that @code{make}
                                                                                                                                                         is passed @code{-j} with the number of cores. Each push also has a fresh home directory and PLaneT cache.}

                                   @h1{What is a push?}  @p{When we
used SVN (Push 23032, although there was a hard drive crash and we
lost a number of pushes from before then), before we switched to Git,
a push was an SVN revision. After we started with Git (Push 18817, I
think), we made a post-push script to keep track of when a push of a
set commits happened (because that is not stored in any way in the Git
repository.) Once we switched to a more distributed architecture with
one repository per set of packages (Around push 29612), this became
not very useful. After a while living with that (Push 29810), we
decided to just run DrDr constantly, getting new commits as they come
in.}

                                   @h1{How long does it take for a build to start after a check-in?}
                                   @p{Only one build runs at a time and when none is running the git repository is polled every @,(number->string (current-monitoring-interval-seconds)) seconds.}
                                   
                                   @h1{How is the push "tested"?}
                                   @p{Each file is run with @code{raco test ~s} is used if the file's suffix is @code{.rkt}, @code{.ss}, @code{.scm}, @code{.sls}, or @code{.scrbl}.}
                                   
                                   @p{The command-line is always executed with a fresh empty current directory which is removed after the run. But all the files share the same home directory and X server, which are both removed after each push's testing is complete.}
                                   
                                   @p{When DrDr runs any command, it sets the @code{PLTDRDR} environment variable. You can use this to change the command's behavior. However, it is preferred that you change the command-line directly.}
                                   
                                   @h1{How many files are "tested" concurrently?}
                                   @p{One per core, or @,(number->string (number-of-cpus)).}
                                   
                                   @h1{How long may a file run?}
                                   @p{The execution timeout is @,(number->string (current-make-install-timeout-seconds)) seconds by default, but the code may set its own timeout internally and well-behaved tests will.}
                                   
                                   @h1{May these settings be set on a per-directory basis?}
                                   @p{Yes, if the property is set on any ancestor directory, then its value is used for its descendents when theirs is not set.}

                                   @h1{What properties does DrDr recognize?}
                                   @p{DrDr reads properties that @code{raco test} prints to standard output. These fall into two categories: properties DrDr uses for reporting, and properties @code{raco test} uses to control execution.}

                                   @h2{Reporting properties}
                                   @p{These are read by DrDr from @code{raco test} output and affect how results are analyzed and reported:}
                                   @ul{
                                     @li{@code{test-responsible} — who to notify on failure.}
                                     @li{@code{test-random} — marks non-deterministic output. When set to @code{#t}, changes in output are not reported.}
                                     @li{@code{test-known-error} — marks known failures. When set to @code{#t}, changes are not reported.}
                                   }

                                   @h2{Execution properties}
                                   @p{These are handled by @code{raco test} itself and affect how tests are run:}
                                   @ul{
                                     @li{@code{lock-name} — serializes tests sharing the same lock name using file-based locking. Useful for tests that need exclusive access to a shared resource (see below).}
                                     @li{@code{timeout} — per-test timeout override in seconds.}
                                     @li{@code{ignore-stderr} — a regular expression pattern; matching stderr lines are ignored.}
                                   }

                                   @h2{How to set properties}
                                   @p{Properties can be set in two ways:}
                                   @p{@b{Via @code{info.rkt}:} Use the plural/keyed form in the package's @code{info.rkt}. Each entry maps a path to a value.}
                                   @pre{
(define test-responsibles '((#f "someone@")))
(define test-lock-names '(("gui-test.rkt" "x-server")))
(define test-timeouts '(("slow-test.rkt" 600)))
(define test-ignore-stderrs '(("noisy.rkt" "GLib-WARNING")))
}
                                   @p{@b{Via @code{config} submodule:} Add a @code{config} submodule inside the test file's @code{test} submodule.}
                                   @pre{
(module test racket/base
  (module config info
    (define responsible "someone@")
    (define lock-name "x-server")
    (define timeout 600)
    (define random? #t)))
}

                                   @h2{X server serialization}
                                   @p{All DrDr workers share a single X server (display @code{:20}). Tests that need exclusive X server access can use the @code{lock-name} property with a conventional name like @code{"x-server"}. This causes @code{raco test} to serialize those tests via file locking, preventing concurrent X server access conflicts. No DrDr-side changes are needed.}

                                   @h2{Per-test Xvfb isolation}
                                   @p{Tests that need their own isolated X server can be listed in the package's @code{info.rkt} using @code{test-xvfb-paths}. This property takes a list of relative path strings (files or directories), following the same convention as @code{test-omit-paths}. Matching tests are run under @code{xvfb-run} with a temporary Xvfb server instead of the shared display.}
                                   @pre{
;; in info.rkt:
(define test-xvfb-paths '("gui-test.rkt" "tests/visual"))
}

                                   @h1{What data is gathered during these runs?}
                                   @p{When each file is run the following is recorded: the start time, the command-line, the STDERR and STDOUT output, the exit code (unless there is a timeout), and the end time. All this information is presented in the per-file DrDr report page.}
                                   
                                   @h1{How is the data analyzed?}
                                   @p{From the data collected from the run, DrDr computes the total test time and whether output has "changed" since the last time the file was tested.}
                                   
                                   @h1{What output patterns constitute a "change"?}
                                   @p{At the most basic level, if the bytes are different. However, there are a few subtleties. First, DrDr knows to ignore the result of @code{time}. Second, the standard output and standard error streams are compared independently. Finally, if the output stream contains @code{DrDr: This file has random output.} or @code{raco test: @"@"(test-random #t)} then changes do not affect any reporting DrDr would otherwise perform. The difference display pages present changed lines with a @span[([class "difference"])]{unique background}.}

                                   @h1{What should I do if I know there is a problem but can't fix it now?}
                                   @p{Have the program output @code{raco test: @"@"(test-random #t)} to standard output.}

                                   @h1{What do the green buttons do?}
                                   @p{They switch between revisions where there was a change from the previous revision.}

                                   @p{For example, if there where seven revisions with three different outputs---1A 2A 3A 4B 5B 6C 7C---then the green buttons will go from 1 to 4 to 6 to 7. (1 and 7 are included because they are the last possible revisions and the search stops.)}

                                   @p{In other words, the green buttons go forwards and backwards to the nearest pushes that have the red 'This result of executing this file has changed' box on them.}
                                   
                                   @h1{How is this site organized?}
                                   @p{Each file's test results are displayed on a separate page, with a link to the previous push on changes. All the files in a directory are collated and indexed recursively. On these pages each column is sortable and each row is clickable. The root of a push also includes the git commit messages with links to the test results of the modified files. The top DrDr page displays the summary information for all the tested pushes.}
                                   
                                   @h1{What is the difference between @code{Duration (Abs)} and @code{Duration (Sum)}?}
                                   @p{@code{Duration (Abs)} is the difference between the earliest start time and the latest end time in the collection.}
                                   @p{@code{Duration (Sum)} is the sum of each file's difference between the start time and end time.}
                                   @p{The two are often different because of parallelism in the testing process. (Long absolute durations indicate DrDr bugs waiting to get fixed.)}
                                   
                                   @h1{What do the graphs mean?}
                                   @p{There is a single graph for each file, i.e., graphs are not kept for old pushs.}
                                   @p{The X-axis is the tested push. The Y-axis is the percentage of the time of the slowest push.}
                                   @p{The gray, horizontal lines show where 0%, 25%, 50%, 75%, and 100% are in the graph.}
                                   @p{The black line shows the times for overall running of the file. The colored lines show the results from @code{time}. For each color, the "real" time is the darkest version of it and the "cpu" and "gc" time are 50% and 25% of the darkness, respectively.}
                                   @p{If the number of calls to @code{time} change from one push to the next, then there is a gray, vertical bar at that point. Also, the scaling to the slowest time is specific to each horizontal chunk.}
                                   @p{The graph is split up into panes that each contain approximately 300 pushes. The green arrowheads to the left
                                      and right of the image move between panes.}
                                   @p{The legend at the bottom of the graph shows the current pane, as well as the push number and any timing information from that push.}
                                   @p{Click on the graph to jump to the DrDr page for a specific push.}
                                   
                                   @h1{What is the timing data format?}
                                   @p{The timing files are a list of S-expressions. Their grammar is: @code{(push duration ((cpu real gc) ...))} where @code{push} is an integer, @code{duration} is an inexact millisecond, and @code{cpu}, @code{real}, and @code{gc} are parsed from the @code{time-apply} function.}
                                   
                                   @h1{Why are some pushes missing?}
                                   @p{Some pushes are missing because they only modify branches. Only pushes that change the @code{master} or @code{release} branch are tested.}
                                   
                                   @h1{How do I make the most use of DrDr?}
                                   @p{So DrDr can be effective with all testing packages and untested code, it only pays attention to error output and non-zero exit codes. You can make the most of this strategy by ensuring that when your tests are run successfully they have no STDERR output and exit cleanly, but have both when they fail.}
                                                                      
                                   @h1{How can I do the most for DrDr?}
                                   @p{The most important thing you can do is eliminate false positives by configuring DrDr for your code and removing spurious error output.}
                                   @p{The next thing is to structure your code so DrDr does not do the same work many times. For example, because DrDr will load every file if your test suite is broken up into different parts that execute when loaded @em{and} they are all loaded by some other file, then DrDr will load and run them twice. The recommended solution is to have DrDr ignore the combining file or change it so a command-line argument is needed to run everything but is not provided by DrDr, that way the combining code is compiled but the tests are run once.}
                                   
                                   }                                           
           ,(footer))))))

(define (take* l i)
  (take l (min (length l) i)))

(define (list-limit len offset l)
  (take* (drop l offset) len))

(define (string-first-line s)
  (define v
    (with-input-from-string s read-line))
  (if (eof-object? v)
      "" v))

(define log->committer+title 
  (match-lambda
    [(struct git-push (num author commits))
     (define lines (append-map (λ (c) (if (git-merge? c) empty (git-commit-msg* c))) commits))
     (define title
       (if (empty? lines)
           ""
           (first lines)))
     (values author title)]
    [(struct svn-rev-log (num author date msg changes))
     (define commit-msg (string-first-line msg))
     (define title 
       (format "~a - ~a"
               (svn-date->nice-date date)
               commit-msg))
     (values author title)]))

(define (log->branches log)
  (match-define (struct git-push (num author commits)) log)
  (apply string-append
         (add-between
          (remove-duplicates 
           (for/list ([c (in-list commits)])
                     (format "branch-~a"
                             (regexp-replace*
                              "/"
                              (if (git-commit*? c)
                                  (git-commit*-branch c)
                                  "refs/heads/master")
                              "-"))))
          " ")))

(require web-server/servlet-env
         web-server/http
         web-server/dispatch
         "scm.rkt")
(define how-many-revs 45)
(define (show-revisions req)
  (define builds-pth (plt-build-directory))
  (define offset
    (match (bindings-assq #"offset" (request-bindings/raw req))
      [(struct binding:form (_ val))
       (string->number (bytes->string/utf-8 val))]
      [_
       0]))
  (define future-revs
    (map (curry cons 'future)
         (sort (directory-list* (plt-future-build-directory))
               >
               #:key (compose string->number path->string))))
  (define how-many-future-revs
    (length future-revs))
  (define built-or-building-revs
    (map (curry cons 'past)
         (sort (directory-list* builds-pth)
               >
               #:key (compose string->number path->string))))
  (define all-revs
    (append future-revs built-or-building-revs))
  (define how-many-total-revs
    (length all-revs))
  (response/xexpr
   `(html
     (head (title "DrDr")
           (link ([rel "stylesheet"] [type "text/css"] [href "/render.css"])))
     (body
      (div ([class "dirlog, content"])
           (span ([class "breadcrumb"])
                 (span ([class "this"]) 
                       "DrDr"))
           (table ([class "dirlist frontpage"])
                  (thead
                   (tr (td "Push#")
                       (td "Duration (Abs)")
                       (td "Duration (Sum)")
                       (td "Problems")
                       (td "Pusher")))
                  (tbody
                   ,@(map (match-lambda
                            [(cons 'future rev-pth)
                             (define name (path->string rev-pth))
                             (define rev (string->number name))
                             (define log (read-cache (future-record-path rev)))
                             (define-values (committer title)
                               (log->committer+title log))
                             (define url (log->url log))
                             `(tr ([class ,(format "dir ~a"
                                                   (log->branches log))]
                                   [title ,title])
                                  (td (a ([href ,url]) ,name))
                                  (td ([class "building"] [colspan "3"])
                                      "")
                                  (td ([class "author"]) ,committer))]
                            [(cons 'past rev-pth)
                             (define name (path->string rev-pth))
                             (define url (format "~a/" name))
                             (define rev (string->number name))
                             (define log-pth (revision-commit-msg rev))
                             (define log (read-cache log-pth))
                             (define-values (committer title)
                               (log->committer+title log))
                             (define (no-rendering-row)
                               (define mtime 
                                 (file-or-directory-modify-seconds log-pth))
                               
                               `(tr ([class ,(format "dir ~a"
                                                     (log->branches log))]
                                     [title ,title])
                                    (td (a ([href "#"]) ,name))
                                    (td ([class "building"] [colspan "3"])
                                        "Build in progress. Started "
                                        ,(format-duration-m
                                          (/ (- (current-seconds) mtime) 60))
                                        " ago.")
                                    (td ([class "author"]) ,committer)))
                             (parameterize ([current-rev rev])
                               (with-handlers 
                                   ([(lambda (x)
                                       (regexp-match #rx"No cache available" (exn-message x)))
                                     (lambda (x)
                                       (no-rendering-row))])
                                 ;; XXX One function to generate
                                 (match (dir-rendering (revision-log-dir rev))
                                   [#f
                                    (no-rendering-row)]
                                   [(and ring
                                         (struct rendering 
                                           (start end dur timeout unclean
                                                  stderr responsible-party changes)))
                                    (define abs-dur (- end start))
                                    
                                    `(tr ([class ,(format "dir ~a"
                                                          (log->branches log))]
                                          [title ,title]
                                          [onclick ,(format "document.location = ~S" url)])
                                         (td (a ([href ,url]) ,name))
                                         (td ([sorttable_customkey ,(number->string abs-dur)])
                                             ,(format-duration-ms abs-dur))
                                         (td ([sorttable_customkey ,(number->string dur)])
                                             ,(format-duration-ms dur))
                                         ,(let ()
                                            (define tn (lc->number timeout))
                                            (define un (lc->number unclean))
                                            (define sn (lc->number stderr))
                                            ;; XXX subtract ignorable
                                            (define v (lc->number (lc-sort (lc+ stderr timeout unclean))))
                                            `(td ([sorttable_customkey ,(number->string v)])
                                             ,(number->string/zero v)))
                                         (td ,committer))])))])
                          (list-limit
                           how-many-revs offset
                           all-revs))))
           (table ([id "revnav"] [width "100%"])
                  (tr (td ([align "left"])
                          (span ([class "revnav"])
                                (a ([href ,(top-url show-revisions)])
                                   (img ([src "/images/skip-backward1.png"])))
                                (a ([href ,(format "~a?offset=~a"
                                                   (top-url show-revisions)
                                                   (max 0 (- offset how-many-revs)))])
                                   (img ([src "/images/rewind.png"])))))
                      (td ([align "right"])
                          (span ([class "revnav"])
                                (a ([href ,(format "~a?offset=~a"
                                                   (top-url show-revisions)
                                                   (min (- how-many-total-revs how-many-revs)
                                                        (+ offset how-many-revs)))])
                                   (img ([src "/images/fast-forward.png"])))
                                (a ([href ,(format "~a?offset=~a"
                                                   (top-url show-revisions)
                                                   (- how-many-total-revs how-many-revs))])
                                   (img ([src "/images/skip-forward1.png"])))))))
           ,(footer))))))

(define (show-revision req rev)
  (define log-dir (revision-log-dir rev))
  (parameterize ([current-rev rev]
                 [previous-rev (find-previous-rev rev)])
    (with-handlers ([(lambda (x)
                       (regexp-match #rx"No cache available" (exn-message x)))
                     (lambda (x)
                       (rev-not-found log-dir rev))])
      (render-logs/dir log-dir #:show-commit-msg? #t))))

(define (file-not-found file-pth)
  (define-values (title breadcrumb) (path->breadcrumb file-pth #f))
  (response/xexpr
   `(html
     (head (title ,title " > Not Found")
           (link ([rel "stylesheet"] [type "text/css"] [href "/render.css"])))
     (body
      (div ([class "content"])
           ,breadcrumb
           (div ([class "error"])
                "This file does not exist in push #" ,(number->string (current-rev)) " or has not been tested.")
           ,(footer))))))
(define (dir-not-found dir-pth)
  (define-values (title breadcrumb) (path->breadcrumb dir-pth #t))
  (response/xexpr
   `(html
     (head (title ,title " > Not Found")
           (link ([rel "stylesheet"] [type "text/css"] [href "/render.css"])))
     (body
      (div ([class "content"])
           ,breadcrumb
           (div ([class "error"])
                "This directory does not exist in push #" ,(number->string (current-rev)) " or has not been tested.")
           ,(footer))))))
(define (rev-not-found dir-pth path-to-file)
  (define-values (title breadcrumb) (path->breadcrumb dir-pth #t))
  (response/xexpr
   `(html
     (head (title ,title " > Not Found")
           (link ([rel "stylesheet"] [type "text/css"] [href "/render.css"])))
     (body
      (div ([class "content"])
           ,breadcrumb
           (div ([class "error"])
                "Push #" ,(number->string (current-rev)) " does not exist or has not been tested.")
           ,(footer))))))

(define (find-previous-rev this-rev)
  (if (zero? this-rev)
      #f
      (local [(define maybe (sub1 this-rev))]
        (if (cached-directory-exists? (revision-log-dir maybe))
            maybe
            (find-previous-rev maybe)))))

(define (show-file/prev-change req rev path-to-file)
  (show-file/change -1 rev path-to-file))
(define (show-file/next-change req rev path-to-file)
  (show-file/change +1 rev path-to-file))
(define (show-file/change direction top-rev path-to-file)
  (define the-rev
    (let loop ([last-rev top-rev]
               [this-rev (+ direction top-rev)])
      (parameterize ([current-rev this-rev]
                     [previous-rev (find-previous-rev this-rev)])
        (define log-dir (revision-log-dir this-rev))
        (define log-pth
          (apply build-path log-dir path-to-file))
        (match 
            (with-handlers ([(lambda (x)
                               (regexp-match #rx"No cache available" (exn-message x)))
                             (lambda (x)
                               #f)])
              (log-rendering log-pth))
          [#f
           last-rev]
          [(and the-log-rendering (struct rendering (_ _ _ _ _ _ _ changed)))
           (if (empty? changed)
             (loop this-rev (+ direction this-rev))
             this-rev)]))))
  (redirect-to
   (top-url show-file the-rev path-to-file)))

(define (show-file req rev path-to-file)
  (define log-dir (revision-log-dir rev))
  (parameterize ([current-rev rev]
                 [previous-rev (find-previous-rev rev)])
    (if (member "" path-to-file)
        (local [(define dir-pth
                  (apply build-path log-dir (all-but-last path-to-file)))]
          (with-handlers ([(lambda (x)
                             (regexp-match #rx"No cache available" (exn-message x)))
                           (lambda (x)
                             (dir-not-found dir-pth))])
            (render-logs/dir dir-pth)))
        (local [(define file-pth
                  (apply build-path log-dir path-to-file))]
          (with-handlers ([(lambda (x)
                             (regexp-match #rx"No cache available" (exn-message x)))
                           (lambda (x)
                             (file-not-found file-pth))])
            (render-log file-pth))))))

(define (show-revision/current req)
  (init-revisions!)
  (redirect-to
   (top-url show-revision (newest-completed-revision))))
(define (show-file/current req . args)
  (init-revisions!)
  (redirect-to
   (apply top-url show-file (newest-completed-revision) args)))

(define how-many-file-results 45)
(define (show-file-history req path-to-file)
  (define file-rel-path (apply build-path path-to-file))
  (define file-path-str (string-join path-to-file "/"))
  (define offset
    (match (bindings-assq #"offset" (request-bindings/raw req))
      [(struct binding:form (_ val))
       (string->number (bytes->string/utf-8 val))]
      [_
       0]))
  ;; Get all revision numbers sorted descending (newest first)
  (define builds-pth (plt-build-directory))
  (define all-rev-nums
    (sort (filter-map (compose string->number path->string)
                      (directory-list* builds-pth))
          >))
  ;; Compute analyze and log paths for a revision
  (define (rev-analyze-path rev)
    (define log-dir (revision-log-dir rev))
    (define analyze-dir (revision-analyze-dir rev))
    (path-add-suffix
     ((rebase-path log-dir analyze-dir)
      (build-path log-dir file-rel-path))
     ".analyze"))
  (define (rev-log-path rev)
    (build-path (revision-log-dir rev) file-rel-path))
  (define how-many-total (length all-rev-nums))
  ;; Only read cache for the page we need to display
  (define page-revs (list-limit how-many-file-results offset all-rev-nums))
  (define page-results
    (map (lambda (rev)
           (define pth (rev-analyze-path rev))
           (define r (and (file-exists? pth) (read-cache* pth)))
           (define log-pth (rev-log-path rev))
           (define log (and r (file-exists? log-pth) (read-cache* log-pth)))
           (define analyzed? (file-exists? (build-path (revision-dir rev) "analyzed")))
           (list rev (and r (rendering? r) r) log analyzed?))
         page-revs))
  (define history-url (format "/file-history/~a" file-path-str))
  (define title (format "DrDr / File History / ~a" file-path-str))

  (response/xexpr
   `(html
     (head (title ,title)
           (link ([rel "stylesheet"] [type "text/css"] [href "/render.css"])))
     (body
      (div ([class "dirlog, content"])
           (span ([class "breadcrumb"])
                 (a ([class "parent"] [href "/"])
                    "DrDr")
                 " / "
                 (span ([class "this"])
                       "File History: /" ,file-path-str))
           (table ([class "dirlist frontpage"])
                  (thead
                   (tr (td "Push#")
                       (td "Status")
                       (td "Exit Code")
                       (td "Duration")
                       (td "Changed?")))
                  (tbody
                   ,@(map
                      (match-lambda
                        [(list rev #f _ analyzed?)
                         (define name (number->string rev))
                         (define url (format "/~a/" rev))
                         `(tr ([class "dir"]
                               [onclick ,(format "document.location = ~S" url)])
                              (td (a ([href ,url]) ,name))
                              (td ,(if analyzed? "Missing" "Pending"))
                              (td "")
                              (td "")
                              (td ""))]
                        [(list rev (struct rendering (_ _ dur timeout unclean stderr _ changed)) log _)
                         (define name (number->string rev))
                         (define url (format "/~a/~a" rev file-path-str))
                         (define status-text
                           (cond
                             [(not (lc-zero? timeout)) "Timeout"]
                             [(not (lc-zero? unclean)) "Failure"]
                             [else "Success"]))
                         (define exit-code-text
                           (cond
                             [(and log (exit? log)) (number->string (exit-code log))]
                             [(and log (timeout? log)) ""]
                             [else ""]))
                         `(tr ([class "dir"]
                               [onclick ,(format "document.location = ~S" url)])
                              (td (a ([href ,url]) ,name))
                              (td ,status-text)
                              (td ,exit-code-text)
                              (td ,(format-duration-ms dur))
                              (td ,(if (lc-zero? changed) '" " checkmark-entity)))])
                      page-results)))
           (table ([id "revnav"] [width "100%"])
                  (tr (td ([align "left"])
                          (span ([class "revnav"])
                                (a ([href ,history-url])
                                   (img ([src "/images/skip-backward1.png"])))
                                (a ([href ,(format "~a?offset=~a" history-url
                                                   (max 0 (- offset how-many-file-results)))])
                                   (img ([src "/images/rewind.png"])))))
                      (td ([align "right"])
                          (span ([class "revnav"])
                                (a ([href ,(format "~a?offset=~a" history-url
                                                   (min (max 0 (- how-many-total how-many-file-results))
                                                        (+ offset how-many-file-results)))])
                                   (img ([src "/images/fast-forward.png"])))
                                (a ([href ,(format "~a?offset=~a" history-url
                                                   (max 0 (- how-many-total how-many-file-results)))])
                                   (img ([src "/images/skip-forward1.png"])))))))
           ,(footer))))))

(define (show-diff req r1 r2 f)
  (define f1 (apply build-path (revision-log-dir r1) f))
  (with-handlers ([(lambda (x)
                     (regexp-match #rx"File is not cached" (exn-message x)))
                   (lambda (x)
                     ;; XXX Make a little nicer
                     (parameterize ([current-rev r1])
                       (file-not-found f1)))])
    (define l1 (status-output-log (read-cache f1)))
    (define f2 (apply build-path (revision-log-dir r2) f))
    (with-handlers ([(lambda (x)
                       (regexp-match #rx"File is not cached" (exn-message x)))
                     (lambda (x)
                       ;; XXX Make a little nicer
                       (parameterize ([current-rev r2])
                         (file-not-found f2)))])
      (define l2 (status-output-log (read-cache f2)))
      (define f-str (path->string (apply build-path f)))
      (define title 
        (format "DrDr / File Difference / ~a (~a:~a)"
                f-str r1 r2))
      
      (response/xexpr
       `(html (head (title ,title)
                    (link ([rel "stylesheet"] [type "text/css"] [href "/render.css"])))
              (body 
               (div ([class "log, content"])
                    (span ([class "breadcrumb"])
                          (a ([class "parent"] [href "/"])
                             "DrDr")
                          " / "
                          (span ([class "this"]) 
                                "File Difference"))
                    (table ([class "data"])
                           (tr (td "First Push:") (td (a ([href ,(format "/~a/~a" r1 f-str)]) ,(number->string r1))))
                           (tr (td "Second Push:") (td (a ([href ,(format "/~a/~a" r2 f-str)]) ,(number->string r2))))
                           (tr (td "File:") (td "/" ,f-str)))
                    (div ([class "output"])
                         (table ([class "diff"])
                                ,@(for/list ([d (in-list (render-log-difference l1 l2))])
                                    (match d
                                      [(struct difference (old new))
                                       `(tr ([class "difference"])
                                            (td ,(render-event old))
                                            (td ,(render-event new)))]
                                      [(struct same-itude (e))
                                       `(tr (td ([colspan "2"]) ,(render-event e)))]))))
                    ,(footer))))))))

(define-values (top-dispatch top-url)
  (dispatch-rules
   [("help") show-help]
   [("") show-revisions]
   [("diff" (integer-arg) (integer-arg) (string-arg) ...) show-diff]
   [("file-history" (string-arg) ...) show-file-history]
   [("json" "timing" (string-arg) ...) json-timing]
   [("previous-change" (integer-arg) (string-arg) ...) show-file/prev-change]
   [("next-change" (integer-arg) (string-arg) ...) show-file/next-change]
   [("current" "") show-revision/current]
   [("current" (string-arg) ...) show-file/current]
   [((integer-arg) "") show-revision]
   [((integer-arg) (string-arg) ...) show-file]))

(require (only-in net/url url->string))
(define (log-dispatch req)
  (define user-agent
    (cond
      [(headers-assq* #"User-Agent"
                      (request-headers/raw req))
       => header-value]
      [else
       #"Unknown"]))
  (cond
    [(regexp-match #"Googlebot" user-agent)
     (response/xexpr "Please, do not index.")]
    [else
     (printf "~a - ~a ~a\n"
             (url->string (request-uri req))
             user-agent
	     (request-client-ip req))
     (parameterize ([drdr-start-request (current-inexact-milliseconds)])
     (top-dispatch req))]))

(provide top-dispatch log-dispatch static drdr-start-request)

(module+ main
  (date-display-format 'iso-8601)
  (cache/file-mode 'no-cache)
  (serve/servlet log-dispatch
                 #:port 9000
                 #:listen-ip #f
                 #:quit? #f
                 #:launch-browser? #f
                 #:servlet-regexp #rx""
                 #:servlet-path "/"
                 #:extra-files-paths (list static)))

(module+ test
  (require rackunit)

  ;; Test the make-timestamp-span helper function
  (check-equal? (make-timestamp-span "2023-12-25 10:30:45" 1703505045)
                '(span ([class "timestamp"]
                        [data-timestamp "1703505045"]
                        [title "UTC: 2023-12-25 10:30:45"])
                       "2023-12-25 10:30:45"))

  ;; Test SVN regex pattern works correctly
  (check-equal? (regexp-match #rx"^(....)-(..)-(..T)(..):(..):(..).*Z$" "2023-12-25T10:30:45.123456Z")
                '("2023-12-25T10:30:45.123456Z" "2023" "12" "25T" "10" "30" "45"))

  ;; Test svn-date->nice-date function generates proper spans
  (let ([result (svn-date->nice-date "2023-12-25T10:30:45.123456Z")])
    (check-true (list? result))
    (check-eq? (car result) 'span)
    (check-true (and (member '(class "timestamp") (cadr result)) #t))
    (check-true (and (member '(title "UTC: 2023-12-25 10:30:45") (cadr result)) #t))
    (check-equal? (caddr result) "2023-12-25 10:30:45"))

  ;; Test svn-date->nice-date with malformed date (should fallback)
  (check-equal? (svn-date->nice-date "invalid-date") "invalid-date")

  ;; Test git regex pattern with correct space separator
  (check-equal? (regexp-match #rx"^([0-9][0-9][0-9][0-9])-([0-9][0-9])-([0-9][0-9]) ([0-9][0-9]):([0-9][0-9]):([0-9][0-9]).*$" "2023-12-25 10:30:45 +0000")
                '("2023-12-25 10:30:45 +0000" "2023" "12" "25" "10" "30" "45"))

  ;; Test git-date->nice-date function generates proper spans
  (let ([result (git-date->nice-date "2023-12-25 10:30:45 +0000")])
    (check-true (list? result))
    (check-eq? (car result) 'span)
    (check-true (and (member '(class "timestamp") (cadr result)) #t))
    (check-true (and (member '(title "UTC: 2023-12-25 10:30:45") (cadr result)) #t))
    (check-equal? (caddr result) "2023-12-25 10:30:45"))

  ;; Test git-date->nice-date with malformed date (should fallback)
  (check-equal? (git-date->nice-date "invalid-date") "invalid-date")

  ;; Test that timestamp spans have correct structure
  (check-true (match (make-timestamp-span "test-time" 123456)
                [`(span ([class "timestamp"]
                         [data-timestamp "123456"]
                         [title "UTC: test-time"])
                        "test-time")
                 #t]
                [_ #f]))

  ;; Test that generated spans contain all required attributes
  (let ([span (make-timestamp-span "2023-01-01 00:00:00" 1672531200)])
    (check-equal? (car span) 'span)
    (check-true (and (member '(class "timestamp") (cadr span)) #t))
    (check-true (and (member '(data-timestamp "1672531200") (cadr span)) #t))
    (check-true (and (member '(title "UTC: 2023-01-01 00:00:00") (cadr span)) #t))
    (check-equal? (caddr span) "2023-01-01 00:00:00")))
