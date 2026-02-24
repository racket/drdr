#lang racket/base
;; Tests for the DrDr web interface.
;; Uses synthetic data and web-server/test to exercise page rendering.
(require rackunit
         racket/file
         racket/list
         racket/match
         racket/path
         racket/promise
         net/url
         xml/path
         web-server/test
         web-server/http
         web-server/servlet-dispatch
         "dirstruct.rkt"
         "rendering.rkt"
         "status.rkt"
         "scm.rkt"
         "path-utils.rkt"
         "cache.rkt"
         "analyze.rkt"
         "render.rkt")

;; --- Synthetic data setup ---

(define test-file-path "cs/pkgs/racket-test/tests/example.rkt")

(define (make-test-revision rev
                            #:status [status-type 'success]
                            #:duration-ms [dur-ms 5000]
                            #:changed? [changed? #f]
                            #:author [author "tester"])
  (define log-dir (revision-log-dir rev))
  (define log-pth (build-path log-dir test-file-path))

  (make-directory* (path-only log-pth))

  ;; Write commit-msg
  (define short-hash (substring (string-append (make-string 40 #\a)) 0 40))
  (define commit
    (make-git-diff* "refs/heads/master"
                    short-hash
                    author
                    "2026-02-15 10:00:00 +0000"
                    (list (format "Test commit for rev ~a" rev))
                    (list "collects/tests/test.rkt")))
  (write-to-file* (make-git-push rev author (list commit)) (revision-commit-msg rev))

  ;; Write analyzed marker
  (write-to-file* (current-seconds) (build-path (revision-dir rev) "analyzed"))

  ;; Write log (status struct)
  (define start-ms (* 1000000000.0))
  (define end-ms (+ start-ms dur-ms))
  (define the-log
    (case status-type
      [(timeout)
       (make-timeout start-ms
                     end-ms
                     (list "raco" "test" test-file-path)
                     (list (make-stdout #"running tests...\n") (make-stderr #"timeout exceeded\n")))]
      [(failure)
       (make-exit start-ms
                  end-ms
                  (list "raco" "test" test-file-path)
                  (list (make-stdout #"running tests...\n") (make-stderr #"FAILURE: test failed\n"))
                  1)]
      [else
       (make-exit start-ms
                  end-ms
                  (list "raco" "test" test-file-path)
                  (list (make-stdout #"running tests...\nall tests passed\n"))
                  0)]))
  (write-to-file* the-log log-pth)

  ;; Run analysis to create all analyze cache files
  (parameterize ([current-rev rev])
    (analyze-logs rev)))

(define (call-with-test-data thunk)
  (define test-dir (make-temporary-file "drdr-test-~a" 'directory))
  (dynamic-wind
   (lambda ()
     (plt-directory test-dir)
     (make-directory* (plt-build-directory))
     (make-directory* (plt-future-build-directory))
     (make-directory* (plt-data-directory))
     ;; Use 'cache mode during setup so analyze-logs can write cache files
     (cache/file-mode 'cache)
     (make-test-revision 100 #:status 'success #:duration-ms 3200 #:author "alice")
     (make-test-revision 101 #:status 'success #:duration-ms 3400 #:changed? #t #:author "bob")
     (make-test-revision 102 #:status 'failure #:duration-ms 4100 #:changed? #t #:author "alice")
     (make-test-revision 103 #:status 'timeout #:duration-ms 90000 #:changed? #t #:author "bob")
     ;; Switch to 'no-cache for tests, matching the web server's mode
     (cache/file-mode 'no-cache))
   thunk
   (lambda () (delete-directory/files test-dir #:must-exist? #f))))

;; --- Test helpers ---

(define (test-request/url url-str)
  (make-request #"GET"
                (string->url url-str)
                empty
                (delay
                  empty)
                #f
                "127.0.0.1"
                80
                "127.0.0.1"))

(define (dispatch-request url-str)
  (parameterize ([drdr-start-request (current-inexact-milliseconds)])
    (top-dispatch (test-request/url url-str))))

(define (response-body resp)
  (define out (open-output-bytes))
  ((response-output resp) out)
  (bytes->string/utf-8 (get-output-bytes out)))

;; --- Tests ---

(define render-tests
  (test-suite "DrDr web rendering"

    (test-case "front page lists revisions"
      (call-with-test-data (lambda ()
                             (define resp (dispatch-request "http://localhost/"))
                             (check-equal? (response-code resp) 200)
                             (define body (response-body resp))
                             (check-regexp-match #rx"103" body)
                             (check-regexp-match #rx"102" body)
                             (check-regexp-match #rx"101" body)
                             (check-regexp-match #rx"100" body)
                             (check-regexp-match #rx"alice" body)
                             (check-regexp-match #rx"bob" body))))

    (test-case "revision page shows directory listing"
      (call-with-test-data (lambda ()
                             (define resp (dispatch-request "http://localhost/101/"))
                             (check-equal? (response-code resp) 200)
                             (define body (response-body resp))
                             (check-regexp-match #rx"bob" body)
                             (check-regexp-match #rx"Test commit for rev 101" body))))

    (test-case "file result page shows test output"
      (call-with-test-data (lambda ()
                             (define resp
                               (dispatch-request (format "http://localhost/101/~a" test-file-path)))
                             (check-equal? (response-code resp) 200)
                             (define body (response-body resp))
                             (check-regexp-match #rx"all tests passed" body)
                             (check-regexp-match #rx"3\\.40s" body)
                             (check-regexp-match #rx"Exit Code.*0" body))))

    (test-case "failure file result shows stderr"
      (call-with-test-data (lambda ()
                             (define resp
                               (dispatch-request (format "http://localhost/102/~a" test-file-path)))
                             (check-equal? (response-code resp) 200)
                             (define body (response-body resp))
                             (check-regexp-match #rx"FAILURE" body)
                             (check-regexp-match #rx"Exit Code.*1" body))))

    (test-case "timeout file result shows timeout"
      (call-with-test-data (lambda ()
                             (define resp
                               (dispatch-request (format "http://localhost/103/~a" test-file-path)))
                             (check-equal? (response-code resp) 200)
                             (define body (response-body resp))
                             (check-regexp-match #rx"timeout exceeded" body)
                             (check-regexp-match #rx"10004" body)))) ; checkmark entity for timeout

    (test-case "help page renders"
      (call-with-test-data (lambda ()
                             (define resp (dispatch-request "http://localhost/help"))
                             (check-equal? (response-code resp) 200)
                             (define body (response-body resp))
                             (check-regexp-match #rx"What is DrDr" body))))

    (test-case "nonexistent file returns not found message"
      (call-with-test-data (lambda ()
                             (define resp (dispatch-request "http://localhost/101/no/such/file.rkt"))
                             (check-equal? (response-code resp) 200)
                             (define body (response-body resp))
                             (check-regexp-match #rx"does not exist" body))))

    (test-case "file history page lists all revisions"
      (call-with-test-data (lambda ()
                             (define resp
                               (dispatch-request
                                (format "http://localhost/file-history/~a" test-file-path)))
                             (check-equal? (response-code resp) 200)
                             (define body (response-body resp))
                             (check-regexp-match #rx"File History" body)
                             (check-regexp-match #rx"100" body)
                             (check-regexp-match #rx"101" body)
                             (check-regexp-match #rx"102" body)
                             (check-regexp-match #rx"103" body))))

    (test-case "file history page shows status for each revision"
      (call-with-test-data (lambda ()
                             (define resp
                               (dispatch-request
                                (format "http://localhost/file-history/~a" test-file-path)))
                             (define body (response-body resp))
                             (check-regexp-match #rx"Success" body)
                             (check-regexp-match #rx"Failure" body)
                             (check-regexp-match #rx"Timeout" body))))

    (test-case "file history page shows exit codes"
      (call-with-test-data (lambda ()
                             (define resp
                               (dispatch-request
                                (format "http://localhost/file-history/~a" test-file-path)))
                             (define body (response-body resp))
                             (check-regexp-match #rx"Exit Code" body)
                             ;; Success revisions show exit code 0
                             (check-regexp-match #rx"<td>0</td>" body)
                             ;; Failure revision shows exit code 1
                             (check-regexp-match #rx"<td>1</td>" body))))

    (test-case "file history page shows missing for revisions without file"
      (call-with-test-data (lambda ()
                             ;; Create a revision with no log for test-file-path
                             (make-directory* (revision-log-dir 99))
                             (make-directory* (revision-analyze-dir 99))
                             (write-to-file* (current-seconds)
                                             (build-path (revision-dir 99) "analyzed"))
                             (define resp
                               (dispatch-request
                                (format "http://localhost/file-history/~a" test-file-path)))
                             (define body (response-body resp))
                             (check-regexp-match #rx"99" body)
                             (check-regexp-match #rx"Missing" body))))

    (test-case "file history page shows pending for incomplete revisions"
      (call-with-test-data (lambda ()
                             ;; Create a revision directory with no "analyzed" marker
                             (make-directory* (revision-log-dir 104))
                             (make-directory* (revision-analyze-dir 104))
                             (define resp
                               (dispatch-request
                                (format "http://localhost/file-history/~a" test-file-path)))
                             (define body (response-body resp))
                             (check-regexp-match #rx"104" body)
                             (check-regexp-match #rx"Pending" body)
                             ;; Should NOT show "Missing" for rev 104
                             ;; (Missing should only appear for completed rev 99 if present)
                             )))

    (test-case "file result page links to file history"
      (call-with-test-data (lambda ()
                             (define resp
                               (dispatch-request (format "http://localhost/101/~a" test-file-path)))
                             (define body (response-body resp))
                             (check-regexp-match #rx"file-history" body)
                             (check-regexp-match #rx"All results for this file" body))))))

(module+ test
  (require rackunit/text-ui)
  (run-tests render-tests))
