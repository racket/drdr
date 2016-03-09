#lang racket/base
(require racket/list
         xml
         net/url
         xml/path
         "scm.rkt")

(define drdr-url 
  (string->url "http://drdr.racket-lang.org"))

(define drdr-xml
  (call/input-url drdr-url get-pure-port read-xml/element))
(define drdr-xexpr
  (xml->xexpr drdr-xml))

(define-values
  (building done)
  (for/fold ([building empty]
             [done empty])
    ([tr (in-list (reverse (se-path*/list '(tbody) drdr-xexpr)))])
    (define rev (string->number (se-path* '(a) tr)))
    (define building? (se-path* '(td #:class) tr))
    (if building?
        (values (list* rev building) done)
        (values building (list* rev done)))))

(if (empty? building)
    (if (= (first done) (newest-push))
        (void)
        (error 'monitor-drdr "DrDr is not building, but is not at the most recent push"))
    (void))
