#lang racket/base
(require racket/match
         "config.rkt"
         "cache.rkt"
         "replay.rkt"
         "status.rkt")

(define targets
  '((24744 26988 "collects/tests/typed-racket/tr-random-testing.rkt")
    (26989 27017 "pkgs/racket-pkgs/racket-test/tests/typed-racket/tr-random-testing.rkt")
    (27018 27215 "pkgs/typed-racket-pkgs/typed-racket-tests/tests/typed-racket/tr-random-testing.rkt")
    (27216 29597 "pkgs/typed-racket-pkgs/typed-racket-test/tests/typed-racket/tr-random-testing.rkt")
    (29598 29639 "racket/share/pkgs/typed-racket-test/tests/typed-racket/tr-random-testing.rkt")
    (29640 32242 "racket/share/pkgs/typed-racket-test/tr-random-testing.rkt")))

(module+ main
  (require racket/cmdline)
  (define the-dir
    (command-line
     #:program "gather-logs"
     #:args (dir) dir))

  (make-directory the-dir)
  (for ([t (in-list targets)])
    (match-define (list start end pth) t)
    (printf "~v: " t)
    (for ([rev (in-range start (add1 end))])
      (printf " ~a" rev) (flush-output)
      (define v
        (with-handlers ([exn:fail? (λ (x) #f)])
          (define p (format "/opt/plt/builds/~a/logs/~a" rev pth))
          (read-cache p)))
      (with-output-to-file (build-path the-dir (format "~a.log" rev))
        (λ ()
          (match v
            [#f (printf "~a not present in archive" pth)]
            [(? status?)
             (parameterize ([exit-handler (λ (v) (printf "EXIT: ~v\n" v))]
                            [current-error-port (current-output-port)])
               (replay-status v))]))))
    (printf "\n") (flush-output)))
