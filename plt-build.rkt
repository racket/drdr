#lang racket/base
(require racket/list
         racket/local
         racket/match
         racket/contract/base
         racket/file
         racket/path
         racket/runtime-path
         setup/getinfo
         "job-queue.rkt"
         "metadata.rkt"
         "run-collect.rkt"
         "cache.rkt"
         "dirstruct.rkt"
         "replay.rkt"
         "notify.rkt"
         "path-utils.rkt"
         "sema.rkt"
         "scm.rkt")

;; test-xvfb-paths: hash of normalized-path -> #t
(define xvfb-paths (make-hash))
(define xvfb-info-done (make-hash))

(define (normalize-info-path p)
  (simplify-path (path->complete-path p) #f))

(define (check-xvfb-info dir)
  (define ndir (normalize-info-path dir))
  (unless (hash-ref xvfb-info-done ndir #f)
    (hash-set! xvfb-info-done ndir #t)
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (define info (get-info/full dir))
      (when info
        (define v (info 'test-xvfb-paths (lambda () '())))
        (when (list? v)
          (for ([i (in-list v)])
            (when (path-string? i)
              (define p (normalize-info-path (path->complete-path i dir)))
              (define dp (if (directory-exists? p)
                             (path->directory-path p)
                             p))
              (hash-set! xvfb-paths dp #t))))))))

(define (path-needs-xvfb? pth trunk-dir)
  (define-values (base name dir?) (split-path pth))
  (define dir (if (path? base) (path->complete-path base) (current-directory)))
  (check-xvfb-info dir)
  (let ([p (normalize-info-path pth)])
    (or (hash-ref xvfb-paths p #f)
        (let-values ([(base name dir?) (split-path p)])
          (and (path? base)
               (hash-ref xvfb-paths base #f))))))

(define current-env (make-parameter (make-immutable-hash empty)))
(define-syntax-rule (with-env ([env-expr val-expr] ...) expr ...)
  (parameterize ([current-env
                  (for/fold ([env (current-env)])
                      ([k (in-list (list env-expr ...))]
                       [v (in-list (list val-expr ...))])
                    (hash-set env k v))])
    expr ...))

(define (build-revision rev)
  (define rev-dir (revision-dir rev))
  (define co-dir (revision-trunk-dir rev))
  (define log-dir (revision-log-dir rev))
  (define trunk-dir (revision-trunk-dir rev))  
  ;; Checkout the repository revision
  (cache/file/timestamp
   (build-path rev-dir "checkout-done")
   (lambda ()
     (notify! "Removing checkout directory: ~a" co-dir)
     (safely-delete-directory co-dir)
     (local [(define repo (plt-repository))
             (define to-dir
               (path->string co-dir))]
            (notify! "Checking out ~a@~a into ~a"
                     repo rev to-dir)
            (scm-export-repo rev repo to-dir))))
  (parameterize ([current-directory co-dir])
    (with-env
     (["PLT_SETUP_OPTIONS" (format "-j ~a" (number-of-cpus))])
     (run/collect/wait/log
      #:timeout (current-make-install-timeout-seconds)
      #:env (current-env)
      (build-path log-dir "pkg-src" "build" "make")
      (make-path)
      (list "-j" (number->string (number-of-cpus)) "both"))))
  (run/collect/wait/log
   #:timeout (current-make-install-timeout-seconds)
   #:env (current-env)
   (build-path log-dir "pkg-src" "build" "archive")
   (tar-path)
   (list "-czvf"
         (path->string (revision-trunk.tgz rev))
         "-C" (path->string rev-dir)
         "trunk")))

(define (delete-directory/files-unless-core d)
  (unless
      #f ;; XXX Disabled for a while
      #;(file-exists? (build-path d "core"))
    (delete-directory/files d)))
(define (call-with-temporary-directory n thunk)
  (define nd (build-path (current-directory) n))
  (dynamic-wind
      (lambda ()
        (make-directory* nd))
      (lambda ()
        (parameterize ([current-directory nd])
          (thunk)))
      (lambda ()
        (delete-directory/files-unless-core nd))))
(define-syntax-rule (with-temporary-directory n . e)
  (call-with-temporary-directory n (lambda () . e)))

(define-syntax-rule
  (define-with-temporary-planet-directory with-temporary-planet-directory env-str)
  (begin
    (define (call-with-temporary-planet-directory thunk)
      (define tempdir
        (build-path (current-directory)
                    (symbol->string (gensym 'planetdir))))
      (dynamic-wind
          (lambda ()
            (make-directory* tempdir))
          (lambda ()
            (with-env ([env-str (path->string tempdir)])
                      (thunk)))
          (lambda ()
            (delete-directory/files tempdir))))
    (define-syntax-rule (with-temporary-planet-directory . e)
      (call-with-temporary-planet-directory (lambda () . e)))))
(define-with-temporary-planet-directory with-temporary-planet-directory "PLTPLANETDIR")
(define-with-temporary-planet-directory with-temporary-tmp-directory "TMPDIR")

(define (call-with-temporary-home-directory thunk)
  (define new-dir
    (make-temporary-file
     "home~a"
     'directory
     (current-temporary-directory)))
  (dynamic-wind
      (lambda ()
        (with-handlers ([exn:fail?
                         (λ (x)
                           (notify! "Failed while copying HOME: ~a"
                                    (exn-message x)))])
          (delete-directory/files new-dir)
          (define from (hash-ref (current-env) "HOME"))
          (delete-directory/files (build-path from ".cache") #:must-exist? #f)
          (copy-directory/files from new-dir)))
      (lambda ()
        (with-env (["HOME" (path->string new-dir)])
                  (thunk)))
      (lambda ()
        (delete-directory/files new-dir))))
(define-syntax-rule (with-temporary-home-directory . e)
  (call-with-temporary-home-directory (lambda () . e)))

(define (with-running-program command args thunk)
  (if command
    (let ()
      (define-values (new-command new-args)
        (command+args+env->command+args
         #:env (current-env)
         command args))
      (define-values
        (the-process _stdout stdin _stderr)
        (parameterize ([subprocess-group-enabled #t])
          (apply subprocess
                 (current-error-port)
                 #f
                 (current-error-port)
                 new-command new-args)))
      ;; Die if this program does
      (define parent
        (current-thread))
      (define waiter
        (thread
         (lambda ()
           (subprocess-wait the-process)
           (eprintf "Killing parent because wrapper (~a) is dead...\n" (list* command args))
           (kill-thread parent))))

      ;; Run without stdin
      (close-output-port stdin)

      (dynamic-wind
          void
          ;; Run the thunk
          thunk
          (λ ()
            ;; Close the output ports
            ;;(close-input-port stdout)
            ;;(close-input-port stderr)

            ;; Kill the guard
            (kill-thread waiter)

            ;; Kill the process
            (subprocess-kill the-process #f)
            (sleep)
            (subprocess-kill the-process #t)
            (with-handlers ([exn:fail? (lambda (e) (void))])
              (subprocess-wait the-process)))))
    (thunk)))

(define-runtime-path pkgs-file "pkgs.rktd")
(define (tested-packages)
  (define val (file->value pkgs-file))
  val)

(define (log-pth->dir-name lp)
  (regexp-replace* #rx"/" (path->string lp) "_"))

(define (test-revision rev)
  (define rev-dir (revision-dir rev))
  (define trunk-dir (revision-trunk-dir rev))
  (define log-dir (revision-log-dir rev))
  (define trunk->log (rebase-path trunk-dir log-dir))
  (define trunk->log+cs
    (rebase-path trunk-dir (build-path log-dir "cs")))
  (define (trunk->log/cs p cs?)
    ((if cs? trunk->log+cs trunk->log) p))
  (define racket-path
    (path->string (build-path trunk-dir "racket" "bin" "racket")))
  (define (raco-path cs?)
    (define (make-path suffix)
      (path->string (build-path trunk-dir "racket" "bin" (string-append "raco" suffix))))
    (define suffixed-p (make-path (if cs? "cs" "bc")))
    (if (file-exists? suffixed-p)
        suffixed-p
        ;; Assume that the requested variant is the default one
        (make-path "")))
  (define test-workers (make-job-queue (number-of-cpus)))

  (define pkgs-pths
    (list (build-path trunk-dir "racket" "collects")
          (build-path trunk-dir "pkgs")
          (build-path trunk-dir "racket" "share" "pkgs")))
  (define (test-directory cs? dir-pth upper-sema)
    (define dir-log (build-path (trunk->log/cs dir-pth cs?) ".index.test"))
    (cond
      [(read-cache* dir-log)
       (semaphore-post upper-sema)]
      [else
       (notify! "Testing in ~S" dir-pth)
       (define files/unsorted (directory-list* dir-pth))
       (define dir-sema (make-semaphore 0))
       (define files
         (sort files/unsorted <
               #:key (λ (p)
                       (if (bytes=? #"tests" (path->bytes p))
                         0
                         1))
               #:cache-keys? #t))
       (thread
        (lambda ()
          (define how-many (length files))
          (notify! "Dir ~a waiting for ~a jobs" dir-pth how-many)
          (semaphore-wait* dir-sema how-many)
          (notify! "Done with dir: ~a" dir-pth)
          (write-cache! dir-log (current-seconds))
          (semaphore-post upper-sema)))
       (for ([sub-pth (in-list files)])
         (define pth (build-path dir-pth sub-pth))
         (cond
           [(directory-exists? pth)
            (test-directory cs? pth dir-sema)]
           [else
            (define log-pth (trunk->log/cs pth cs?))
            (cond
              [(file-exists? log-pth)
               (semaphore-post dir-sema)]
              [else
               (define pth-cmd
                 (match (path-command-line pth (current-subprocess-timeout-seconds))
                   [(list-rest 'raco rst)
                    (lambda (cs? k)
                      (k (list* (raco-path cs?) rst)))]))
               (cond
                 [pth-cmd
                  (define cmd (pth-cmd cs? (λ (x) x)))
                  (define lab (vector cmd (current-seconds) #f 'submit))
                  (submit-job!
                   test-workers lab
                   (lambda ()
                     (define (status! v) (vector-set! lab 3 v))
                     (status! 'start)
                     (vector-set! lab 2 (current-seconds))
                     (notify! "job start: ~v" lab)
                     (define needs-xvfb (path-needs-xvfb? pth trunk-dir))
                     (dynamic-wind
                         void
                         (λ ()
                            (with-env
                              (["DISPLAY"
                                (if needs-xvfb
                                  ""
                                  (format ":~a"
                                          (cpu->child
                                            (current-worker))))])
                              (status! 'env)
                              (with-temporary-tmp-directory
                                (status! 'tmp)
                                (with-temporary-planet-directory
                                  (status! 'planet)
                                  (with-temporary-home-directory
                                    (status! 'home)
                                    (with-temporary-directory
                                      (log-pth->dir-name log-pth)
                                      (status! 'tmp2)
                                      (define final-cmd
                                        (if needs-xvfb
                                          (list* "/usr/bin/xvfb-run"
                                                 "--auto-servernum"
                                                 "--server-args=-screen 0 1024x768x24"
                                                 cmd)
                                          cmd))
                                      (run/collect/wait/log
                                        log-pth
                                        #:timeout (current-make-install-timeout-seconds)
                                        #:env (current-env)
                                        (first final-cmd)
                                        (rest final-cmd))))))))
                         (λ ()
                           (semaphore-post dir-sema)))))]
                 [else
                  (semaphore-post dir-sema)])])]))]))
  ;; Some setup
  (for ([cs? (in-list '(#f #t))])
    (define this-base
      (if cs?
        (build-path log-dir "cs")
        log-dir))
    (for ([pp (in-list (tested-packages))])
      (define (run name source)
        (run/collect/wait/log
         #:timeout (current-make-install-timeout-seconds)
         #:env (current-env)
         (build-path this-base "pkg" name)
         (raco-path cs?)
         (list "pkg" "install" "--no-cache" "--skip-installed" "-i" "--deps" "fail" "--name" name source)))
      (match pp
        [`(,name ,source) (run name source)]
        [(? string? name) (run name name)]))
    (run/collect/wait/log
     #:timeout (current-subprocess-timeout-seconds)
     #:env (current-env)
     (build-path this-base "pkg-show")
     (raco-path cs?)
     (list "pkg" "show" "-al" "--full-checksum")))
  (run/collect/wait/log
   #:timeout (current-subprocess-timeout-seconds)
   #:env (current-env)
   (build-path log-dir "pkg-src" "build" "set-browser.rkt")
   racket-path
   (list "-y" 
	 "-t"
         (path->string*
          (build-path (drdr-directory) "set-browser.rkt"))))
  ;; And go
  (define (test-directories ps upper-sema)
    (define list-sema (make-semaphore 0))
    (define how-many
      (for/sum ([p (in-list ps)] #:when (directory-exists? p))
        (for ([cs? (in-list '(#f #t))])
          (test-directory cs? p list-sema))
        1))
    (thread
      (lambda ()
        (semaphore-wait* list-sema (* 2 how-many))
        (semaphore-post upper-sema))))

  (define top-sema (make-semaphore 0))
  (notify! "Starting testing with")
  (thread (lambda ()
    (test-directories pkgs-pths top-sema)
    (notify! "All testing scheduled... waiting for completion")))

  (define the-start (current-inexact-milliseconds))
  (let loop ()
    (define-values (queued-js active-js) (job-queue-jobs test-workers))
    (notify! "Testing still in progress. [~a queued jobs] [~a active jobs]"
             (length queued-js) (length active-js))
    (define (show-jobs l js)
      (for ([j (in-list js)])
        (match-define (vector jl s e st) j)
        (notify! "\t~a: ~a/~a ~v" l st (and e (- e s)) jl)))
    (show-jobs "Q" queued-js)
    (show-jobs "A" active-js)
    (define how-many (+ (length queued-js) (length active-js)))
    (define the-deadline
      (+ the-start (* 1000 (current-make-install-timeout-seconds))))
    (define the-deadline-evt
      (handle-evt
        (alarm-evt the-deadline)
        (λ _
           (notify! "Deadline reached"))))
    (notify! "Testing has until ~a (~a) to finish"
             the-deadline
             (seconds->string (/ the-deadline 1000)))
    (sync top-sema
          the-deadline-evt
          (handle-evt
            (alarm-evt (+ (current-inexact-milliseconds)
                          (* 1000 60)))
            (λ _ (loop)))))

  (notify! "Stopping testing")
  (stop-job-queue! test-workers))

(define (recur-many i r f)
  (if (zero? i)
    (f)
    (r (sub1 i) (lambda ()
                  (recur-many (sub1 i) r f)))))

(define XSERVER-OFFSET 20)
(define ROOTX XSERVER-OFFSET)
(define (cpu->child cpu-i)
  ROOTX
  #;
  (+ XSERVER-OFFSET cpu-i 1))

(define (remove-X-locks tmp-dir i)
  (for ([dir (in-list (list "/tmp" tmp-dir))])
    (safely-delete-directory
     (build-path dir (format ".X~a-lock" i)))
    (safely-delete-directory
     (build-path dir ".X11-unix" (format ".X~a-lock" i)))
    (safely-delete-directory
     (build-path dir (format ".tX~a-lock" i)))))

(define (integrate-revision rev)
  (define test-dir
    (build-path (revision-dir rev) "test"))
  (define planet-dir
    (build-path test-dir "planet"))
  (define home-dir
    (build-path test-dir "home"))
  (define tmp-dir
    (build-path test-dir "tmp"))
  (define lock-dir
    (build-path test-dir "locks"))
  (define trunk-dir
    (revision-trunk-dir rev))
  (cache/file/timestamp
   (build-path (revision-dir rev) "integrated")
   (lambda ()
     (make-directory* test-dir)
     (make-directory* planet-dir)
     (make-directory* home-dir)
     (make-directory* tmp-dir)
     (make-directory* lock-dir)
     ;; We are running inside of a test directory so that random files are stored there
     (parameterize ([current-directory test-dir]
                    [current-temporary-directory tmp-dir]
                    [current-rev rev])
       (with-env (["PLTSTDERR" "error"]
                  ["TMPDIR" (path->string tmp-dir)]
                  ["PLTDRDR" "yes"]
                  ["PATH"
                   (format "~a:~a"
                           (path->string
                            (build-path trunk-dir "bin"))
                           (getenv "PATH"))]
                  ["PLTLOCKDIR" (path->string lock-dir)]
                  ["PLTPLANETDIR" (path->string planet-dir)]
                  ["HOME" (path->string home-dir)]
                  ["MESA_LOADER_IGNORE_DRIVERS" "mgag200"]
                  ["LIBGL_ALWAYS_SOFTWARE" "1"])
                 (unless (read-cache* (revision-commit-msg rev))
                   (write-cache! (revision-commit-msg rev)
                                 (get-scm-commit-msg rev (plt-repository))))
                 (when (build?)
                   (build-revision rev))

                 (define (start-x-server i inner)
                   (notify! "Starting X server #~a" i)
                   (remove-X-locks tmp-dir i)
                   (with-running-program
                    "/usr/bin/Xorg" (list (format ":~a" i))
                    (lambda ()
                      (with-env
                       (["DISPLAY" (format ":~a" i)])
                       (sleep 2)
                       (notify! "Starting WM #~a" i)
                       (with-running-program
                        (fluxbox-path)
                        (list "-d" (format ":~a" i)
                              "--sm-disable"
                              "--compositor=none")
                        inner)))))

                 (start-x-server
                  ROOTX
                  (lambda ()
                    (sleep 2)
                    (notify! "Starting test of rev ~a" rev)
                    (test-revision rev)))))
     ;; Remove the test directory
     (safely-delete-directory home-dir)
     (safely-delete-directory tmp-dir)
     (safely-delete-directory lock-dir)
     (safely-delete-directory planet-dir))))

(provide/contract
 [integrate-revision (exact-nonnegative-integer? . -> . void)])
