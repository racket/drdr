#lang racket/base
(require racket/list
         racket/match
         racket/local
         racket/contract
         racket/async-channel)

(define current-worker (make-parameter #f))

(define-struct job-queue (jobs-ch jobs-info-ch))
(define-struct job (label paramz thunk))
(define-struct done ())

(define (make-queue how-many)
  (define jobs-ch (make-async-channel))
  (define jobs-info-ch (make-async-channel))
  (define work-ch (make-async-channel))
  (define done-ch (make-async-channel))  
  (define (working-manager spaces accept-new? jobs continues active-jobs)
    (if (and (not accept-new?)
             (empty? jobs)
             (empty? continues))
        (killing-manager how-many active-jobs)
        (apply
         sync
         (if (and accept-new?
                  (not (zero? spaces)))
             (handle-evt
              jobs-ch
              (match-lambda
                [(? job? the-job)
                 (working-manager (sub1 spaces) accept-new?
                                  (list* the-job jobs) continues
                                  active-jobs)]
                [(? done?)
                 (working-manager spaces #f jobs continues active-jobs)]))
             never-evt)
         (handle-evt
          jobs-info-ch
          (λ (reply-ch)
            (async-channel-put reply-ch
                               (vector (map job-label jobs)
                                       (map job-label active-jobs)))
            (working-manager spaces accept-new? jobs continues active-jobs)))
         (handle-evt
          done-ch
          (lambda (j*reply-ch)
            (match-define (cons j reply-ch) j*reply-ch)
            (working-manager spaces accept-new? 
                             jobs
                             (list* reply-ch continues)
                             (remq j active-jobs))))
         (if (empty? jobs)
             never-evt
             (let ([j (first jobs)])
               (handle-evt
                (async-channel-put-evt work-ch j)
                (lambda (_)
                  (working-manager spaces accept-new?
                                   (rest jobs) continues (cons j active-jobs))))))
         (map
          (lambda (reply-ch)
            (handle-evt
             (async-channel-put-evt reply-ch 'continue)
             (lambda (_)
               (working-manager (add1 spaces) accept-new? 
                                jobs (remq reply-ch continues) active-jobs))))
          continues))))
  (define (killing-manager left active-jobs)
    (unless (zero? left)
      (sync
       (handle-evt
        jobs-info-ch
        (λ (reply-ch)
          (async-channel-put reply-ch
                             (vector '()
                                     (map job-label active-jobs)))
          (killing-manager left)))
       (handle-evt
        done-ch
        (lambda (j*reply-ch)
          (match-define (cons j reply-ch) j*reply-ch)
          (async-channel-put reply-ch 'stop)
          (killing-manager (sub1 left) (remq j active-jobs)))))))
  (define (worker i)
    (match (async-channel-get work-ch)
      [(and j (struct job (label paramz thunk)))
       (call-with-parameterization 
        paramz 
        (lambda () 
          (parameterize ([current-worker i])
            (thunk))))
       (local [(define reply-ch (make-async-channel))]
         (async-channel-put done-ch (cons j reply-ch))
         (local [(define reply-v (async-channel-get reply-ch))]
           (case reply-v
             [(continue) (worker i)]
             [(stop) (void)]
             [else
              (error 'worker "Unknown reply command")])))]))
  (define the-workers
    (for/list ([i (in-range 0 how-many)])
      (thread (lambda ()
                (worker i)))))
  (define the-manager
    (thread (lambda () (working-manager how-many #t empty empty empty))))
  (make-job-queue jobs-ch jobs-info-ch))

(define (submit-job! jobq label thunk)
  (async-channel-put
   (job-queue-jobs-ch jobq)
   (make-job label
             (current-parameterization)
             thunk)))

(define (stop-job-queue! jobq)
  (async-channel-put
   (job-queue-jobs-ch jobq)
   (make-done)))

(define (job-queue-jobs jobq)
  (define ch (make-async-channel))
  (async-channel-put
   (job-queue-jobs-info-ch jobq)
   ch)
  (match-define (vector queued active)
    (async-channel-get ch))
  (values queued active))

(provide/contract
 [current-worker (parameter/c (or/c false/c exact-nonnegative-integer?))]
 [job-queue? (any/c . -> . boolean?)]
 [rename make-queue make-job-queue 
         (exact-nonnegative-integer? . -> . job-queue?)]
 [submit-job! (job-queue? any/c (-> any) . -> . void)]
 [job-queue-jobs (job-queue? . -> . (values list? list?))]
 [stop-job-queue! (job-queue? . -> . void)])
