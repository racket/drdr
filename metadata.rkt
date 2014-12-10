#lang racket/base
(require racket/path
         racket/match
         racket/list
         racket/contract/base
         racket/string
         racket/set
         "status.rkt"
         "path-utils.rkt"
         "dirstruct.rkt"
         "scm.rkt")
(module+ test
  (require rackunit))

(define (path-command-line a-path a-timeout)
  `(raco "test" "-m" "--timeout" ,(number->string a-timeout)
    ,(path->string* a-path)))

(define (listify x)
  (if (list? x) x (list x)))

(define (calculate-responsible output-log)
  (set->responsible
   (for/fold ([r (responsible->set "")])
             ([e (in-list output-log)])
     (match e
       [(stdout (regexp #rx#"^raco test: @\\(test-responsible '(.+)\\)$"
                        (list _ who)))
        (set-union
         r
         (list->set
          (map (λ (x) (format "~a" x ))
               (listify (read (open-input-bytes who))))))]
       [_
        r]))))
(module+ test
  (check-equal?
   (calculate-responsible
    (list (stdout #"blah blah blah")
          (stdout #"blah blah blah")
          (stdout #"raco test: @(test-responsible '(robby))")
          (stdout #"blah blah blah")))
   "robby")
  (check-equal?
   (calculate-responsible
    (list (stdout #"blah blah blah")
          (stdout #"blah blah blah")
          (stdout #"raco test: @(test-responsible 'robby)")
          (stdout #"blah blah blah")))
   "robby")
  (check-equal?
   (calculate-responsible
    (list (stdout #"blah blah blah")
          (stdout #"blah blah blah")
          (stdout #"raco test: @(test-responsible '(robby jay))")
          (stdout #"blah blah blah")))
   "robby,jay"))

(define (calculate-random? output-log)
  (ormap
   (λ (l)
     (and (stdout? l)
          (or (regexp-match (regexp-quote "raco test: @(test-random #t)")
                            (stdout-bytes l))
              (regexp-match (regexp-quote "DrDr: This file has random output.")
                            (stdout-bytes l)))
          #t))
   output-log))
(module+ test
  (check-equal?
   (calculate-random?
    (list (stdout #"blah blah blah")
          (stdout #"raco test: @(test-random #t)")
          (stdout #"raco test: @(test-responsible '(robby))")
          (stdout #"blah blah blah")))
   #t))

(define (responsible-append x y)
  (set->responsible
   (set-union (responsible->set x)
              (responsible->set y))))
(define (set->responsible l)
  (string-append* (add-between (set->list l) ",")))
(define (responsible->set s)
  (list->set (string-split s ",")))

(provide/contract
 [responsible-append
  (-> string? string? string?)]
 [calculate-responsible
  (-> (listof event?) string?)]
 [calculate-random?
  (-> (listof event?) boolean?)]
 [path-command-line
  (-> path-string? exact-nonnegative-integer?
      (cons/c symbol? (listof string?)))])
