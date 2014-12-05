#lang racket/base
(require racket/file)

(printf "Setting the default browser to something safe...\n")

(put-preferences 
 '(external-browser)
 '(("echo " . "")))
