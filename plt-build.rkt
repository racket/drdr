#lang racket/base
(require racket/list
         racket/local
         racket/match
         racket/contract/base
         racket/file
         racket/runtime-path
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
  (unless (file-exists? (build-path d "core"))
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
(define-syntax-rule (with-temporary-directory n e)
  (call-with-temporary-directory n (lambda () e)))

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
    (define-syntax-rule (with-temporary-planet-directory e)
      (call-with-temporary-planet-directory (lambda () e)))))
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
          (copy-directory/files
           (hash-ref (current-env) "HOME")
           new-dir)))
      (lambda ()
        (with-env (["HOME" (path->string new-dir)])
                  (thunk)))
      (lambda ()
        (delete-directory/files new-dir))))
(define-syntax-rule (with-temporary-home-directory e)
  (call-with-temporary-home-directory (lambda () e)))

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
            (subprocess-kill the-process #t))))
    (thunk)))

(define-runtime-path pkgs-file "pkgs.rktd")
(define (tested-packages)
  (define val (file->value pkgs-file))
  val)

(define (log-pth->dir-name lp)
  (regexp-replace* #rx"/" (path->string lp) "_"))

(define (test-revision rev)
  (define rev-dir (revision-dir rev))
  (define trunk-dir
    (revision-trunk-dir rev))
  (define log-dir
    (revision-log-dir rev))
  (define trunk->log
    (rebase-path trunk-dir log-dir))
  (define racket-path
    (path->string (build-path trunk-dir "racket" "bin" "racket")))
  (define (raco-path cs?)
    (path->string (build-path trunk-dir "racket" "bin" (if cs? "racocs" "raco"))))
  (define test-workers (make-job-queue (number-of-cpus)))

  (define pkgs-pths
    (list (build-path trunk-dir "racket" "collects")
          (build-path trunk-dir "pkgs")
          (build-path trunk-dir "racket" "share" "pkgs")))
  (define (test-directory dir-pth upper-sema)
    (define dir-log (build-path (trunk->log dir-pth) ".index.test"))
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
       (for ([sub-pth (in-list files)])
         (define pth (build-path dir-pth sub-pth))
         (define directory? (directory-exists? pth))
         (cond
           [directory?
            (test-directory pth dir-sema)]
           [else
            (define log-pth (trunk->log pth))
            (cond
              [(file-exists? log-pth)
               (semaphore-post dir-sema)]
              [else
               (define pth-timeout
                 (current-subprocess-timeout-seconds))
               (define pth-cmd/general
                 (path-command-line pth pth-timeout))
               (define-values
                 (pth-cmd the-queue)
                 (match pth-cmd/general
                   [(list-rest 'raco rst)
                    (values
                     (lambda (cs? k)
                       (k (list* (raco-path cs?) rst)))
                     test-workers)]))
               (cond
                 [pth-cmd
                  (define cs? #f) ;; XXX
                  (submit-job!
                   the-queue
                   (pth-cmd cs? (λ (x) x))
                   (lambda ()
                     (dynamic-wind
                         void
                         (λ ()
                           (pth-cmd
                            cs?
                            (λ (l)
                              (with-env
                                (["DISPLAY"
                                  (format ":~a"
                                          (cpu->child
                                           (current-worker)))])
                                (with-temporary-tmp-directory
                                  (with-temporary-planet-directory
                                    (with-temporary-home-directory
                                      (with-temporary-directory
                                        (log-pth->dir-name log-pth)
                                        (run/collect/wait/log
                                         log-pth
                                         #:timeout (current-make-install-timeout-seconds)
                                         #:env (current-env)
                                         (first l)
                                         (rest l))))))))))
                         (λ ()
                           (semaphore-post dir-sema)))))]
                 [else
                  (semaphore-post dir-sema)])])]))
       (thread
        (lambda ()
          (define how-many (length files))
          (semaphore-wait* dir-sema how-many)
          (notify! "Done with dir: ~a" dir-pth)
          (write-cache! dir-log (current-seconds))
          (semaphore-post upper-sema)))]))
  ;; Some setup
  (for ([pp (in-list (tested-packages))])
    (define (run name source)
      (run/collect/wait/log
       #:timeout (current-make-install-timeout-seconds)
       #:env (current-env)
       (build-path log-dir "pkg" name)
       (raco-path #f)
       (list "pkg" "install" "--skip-installed" "-i" "--deps" "fail" "--name" name source)))
    (match pp
      [`(,name ,source) (run name source)]
      [(? string? name) (run name name)]))
  (run/collect/wait/log
   #:timeout (current-subprocess-timeout-seconds)
   #:env (current-env)
   (build-path log-dir "pkg-show")
   (raco-path #f)
   (list "pkg" "show" "-al" "--full-checksum"))
  (run/collect/wait/log
   #:timeout (current-subprocess-timeout-seconds)
   #:env (current-env)
   (build-path log-dir "pkg-src" "build" "set-browser.rkt")
   racket-path
   (list "-t"
         (path->string*
          (build-path (drdr-directory) "set-browser.rkt"))))
  ;; And go
  (define (test-directories ps upper-sema)
    (define list-sema (make-semaphore 0))
    (define how-many 
      (for/sum ([p (in-list ps)] #:when (directory-exists? p))
        (test-directory p list-sema)
        1))
    (and (not (zero? how-many))
         (thread
          (lambda ()
            (semaphore-wait* list-sema how-many)
            (semaphore-post upper-sema)))))

  (define top-sema (make-semaphore 0))
  (notify! "Starting testing")
  (when (test-directories pkgs-pths top-sema)
    (notify! "All testing scheduled... waiting for completion")
    (define the-deadline
      (+ (current-inexact-milliseconds)
         (* 1000 (* 2 (current-make-install-timeout-seconds)))))
    (define the-deadline-evt
      (handle-evt
       (alarm-evt the-deadline)
       (λ _
         (kill-thread (current-thread)))))
    (let loop ()
      (sync top-sema
            the-deadline-evt
            (handle-evt
             (alarm-evt (+ (current-inexact-milliseconds)
                           (* 1000 60)))
             (λ _
               (define-values (queued-js active-js) (job-queue-jobs test-workers))
               (notify! "Testing still in progress. [~a queued jobs ~e] [~a active jobs ~e]"
                        (length queued-js) queued-js
                        (length active-js) active-js)
               (notify! "Testing has until ~a (~a) to finish"
                        the-deadline
                        (seconds->string (/ the-deadline 1000)))
               (loop))))))
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
                  ["GIT_DIR" (path->string (plt-repository))]
                  ["TMPDIR" (path->string tmp-dir)]
                  ["PLTDRDR" "yes"]
                  ["PATH"
                   (format "~a:~a"
                           (path->string
                            (build-path trunk-dir "bin"))
                           (getenv "PATH"))]
                  ["PLTLOCKDIR" (path->string lock-dir)]
                  ["PLTPLANETDIR" (path->string planet-dir)]
                  ["HOME" (path->string home-dir)])
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
                              "--no-composite")
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
