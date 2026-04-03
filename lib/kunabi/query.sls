;;; (kunabi query) — Query engine with index selection and output formatting
;;;
;;; Provides efficient query execution using index-based lookup and filtering.
#!chezscheme

(library (kunabi query)
  (export filters
          make-filters
          filters?
          filters-username
          filters-event-name
          filters-error-code
          filters-region
          filters-start-date
          filters-end-date
          query-search
          print-results
          print-summary
          print-summary-with-warnings
          print-single-record
          print-full-records
          categorize-event)

  (import (except (chezscheme)
                  make-hash-table hash-table?
                  sort sort!
                  printf fprintf
                  path-extension path-absolute?
                  with-input-from-string with-output-to-string
                  iota 1+ 1-
                  partition
                  make-date make-time)
          (jerboa prelude)
          (kunabi parser)
          (kunabi storage))

  ;; High byte for range scan upper bounds
  (define max-key-char (string (integer->char 255)))

  ;; ---- Query Filters ----

  (define-record-type filters
    (fields username event-name error-code region start-date end-date)
    (protocol
      (lambda (new)
        (lambda (username event-name error-code region start-date end-date)
          (new username event-name error-code region start-date end-date)))))

  ;; ---- Index Selection ----

  ;; Determine best index scan strategy.
  ;; Returns: (values mode arg1 arg2)
  ;; mode: 'prefix or 'range
  (def (build-index-scan f)
    (let* ((has-date? (or (and (filters-start-date f) (not (equal? (filters-start-date f) "")))
                          (and (filters-end-date f) (not (equal? (filters-end-date f) "")))))
           (start-time (if (and (filters-start-date f) (not (equal? (filters-start-date f) "")))
                         (string-append (filters-start-date f) "T00:00:00Z")
                         #f))
           (limit-time (if (and (filters-end-date f) (not (equal? (filters-end-date f) "")))
                         (string-append (filters-end-date f) "T23:59:59Z" max-key-char)
                         #f)))
      (let ((build-scan
              (lambda (index-prefix)
                (if (not has-date?)
                  (values 'prefix index-prefix #f)
                  (let ((start (if start-time
                                 (string-append index-prefix start-time)
                                 index-prefix))
                        (limit (if limit-time
                                 (string-append index-prefix limit-time)
                                 (string-append index-prefix max-key-char))))
                    (values 'range start limit))))))

        ;; Priority: composite user-event > user > event > error > region > date
        (cond
          ((and (filters-username f) (not (equal? (filters-username f) ""))
                (filters-event-name f) (not (equal? (filters-event-name f) "")))
           (build-scan (format "idx:user-event:~a:~a:"
                               (filters-username f) (filters-event-name f))))
          ((and (filters-username f) (not (equal? (filters-username f) "")))
           (build-scan (format "idx:user:~a:" (filters-username f))))
          ((and (filters-event-name f) (not (equal? (filters-event-name f) "")))
           (build-scan (format "idx:event:~a:" (filters-event-name f))))
          ((and (filters-error-code f) (not (equal? (filters-error-code f) "")))
           (build-scan (format "idx:error:~a:" (filters-error-code f))))
          ((and (filters-region f) (not (equal? (filters-region f) "")))
           (build-scan (format "idx:region:~a:" (filters-region f))))
          (has-date?
           (let ((start (if (and (filters-start-date f) (not (equal? (filters-start-date f) "")))
                          (format "idx:date:~a:" (filters-start-date f))
                          "idx:date:"))
                 (limit (if (and (filters-end-date f) (not (equal? (filters-end-date f) "")))
                          (string-append "idx:date:" (filters-end-date f) max-key-char)
                          (string-append "idx:date:" max-key-char))))
             (values 'range start limit)))
          (else
           (values 'prefix "idx:date:" #f))))))

  ;; Check if a record matches all filters (post-filter after index scan)
  (def (matches-filters? record f)
    (and (or (not (filters-username f)) (equal? (filters-username f) "")
             (equal? (get-username record) (filters-username f)))
         (or (not (filters-event-name f)) (equal? (filters-event-name f) "")
             (equal? (get-event-name record) (filters-event-name f)))
         (or (not (filters-error-code f)) (equal? (filters-error-code f) "")
             (equal? (get-error-code record) (filters-error-code f)))
         (or (not (filters-region f)) (equal? (filters-region f) "")
             (equal? (get-aws-region record) (filters-region f)))
         ;; Date range filtering
         (or (not (filters-start-date f)) (equal? (filters-start-date f) "")
             (string>=? (get-event-time record)
                        (string-append (filters-start-date f) "T00:00:00Z")))
         (or (not (filters-end-date f)) (equal? (filters-end-date f) "")
             (string<=? (get-event-time record)
                        (string-append (filters-end-date f) "T23:59:59Z")))))

  ;; ---- Main Search Function ----

  ;; 3-pass query: scan index -> batch fetch -> post-filter
  (def (query-search f)
    (let-values (((mode arg1 arg2) (build-index-scan f)))
      ;; Pass 1: Scan index and collect unique event IDs
      (let* ((entries (if (eq? mode 'prefix)
                        (scan-prefix arg1)
                        (scan-range arg1 arg2)))
             (seen (make-hash-table))
             (event-ids (filter-map
                          (lambda (entry)
                            (let ((eid (cdr entry)))
                              (if (hash-key? seen eid)
                                #f
                                (begin (hash-put! seen eid #t) eid))))
                          entries)))
        (if (null? event-ids)
          '()
          ;; Pass 2: Batch fetch records
          (let ((record-map (get-batch event-ids)))
            ;; Pass 3: Post-filter
            (let ((results (filter-map
                             (lambda (eid)
                               (let ((record (hash-get record-map eid)))
                                 (if (and record (matches-filters? record f))
                                   record
                                   #f)))
                             event-ids)))
              results))))))

  ;; ---- Event Categorization ----

  (def (categorize-event event-name)
    (cond
      ((or (string-prefix? "Create" event-name)
           (string-prefix? "Put" event-name)
           (string-prefix? "Run" event-name)
           (string-prefix? "Start" event-name)
           (string-prefix? "Allocate" event-name)
           (string-prefix? "Register" event-name))
       "Create")
      ((or (string-prefix? "Delete" event-name)
           (string-prefix? "Remove" event-name)
           (string-prefix? "Deregister" event-name)
           (string-prefix? "Terminate" event-name)
           (string-prefix? "Release" event-name)
           (string-prefix? "Stop" event-name))
       "Delete")
      ((or (string-prefix? "Modify" event-name)
           (string-prefix? "Update" event-name)
           (string-prefix? "Set" event-name)
           (string-prefix? "Change" event-name)
           (string-prefix? "Attach" event-name)
           (string-prefix? "Detach" event-name)
           (string-prefix? "Enable" event-name)
           (string-prefix? "Disable" event-name))
       "Modify")
      ((or (string-prefix? "Get" event-name)
           (string-prefix? "Describe" event-name)
           (string-prefix? "List" event-name)
           (string-prefix? "Lookup" event-name)
           (string-prefix? "Head" event-name)
           (string-prefix? "Search" event-name))
       "Read")
      ((or (string-prefix? "Assume" event-name)
           (string-prefix? "Login" event-name)
           (string-prefix? "ConsoleLogin" event-name)
           (string-prefix? "Federat" event-name))
       "Auth")
      ((or (string-prefix? "Authorize" event-name)
           (string-prefix? "Revoke" event-name))
       "Network")
      (else "Other")))

  ;; ---- Output Formatting ----

  (def (pad-right str width)
    (let ((len (string-length str)))
      (if (>= len width)
        (substring str 0 width)
        (string-append str (make-string (- width len) #\space)))))

  (def (truncate-str str max-len)
    (if (<= (string-length str) max-len)
      str
      (string-append (substring str 0 (- max-len 3)) "...")))

  ;; Print results in tabular format
  (def (print-results records)
    (if (null? records)
      (displayln "No results found.")
      (begin
        (displayln (format "Found ~a events:\n" (length records)))
        ;; Header
        (displayln (format "~a ~a ~a ~a ~a ~a ~a"
                           (pad-right "Time" 22)
                           (pad-right "User" 30)
                           (pad-right "Event" 35)
                           (pad-right "Region" 15)
                           (pad-right "Source IP" 18)
                           (pad-right "Error" 20)
                           "Category"))
        (displayln (make-string 160 #\-))
        (for-each
          (lambda (record)
            (let ((time-str (truncate-str (get-event-time record) 20))
                  (user (truncate-str (get-username record) 28))
                  (event (truncate-str (get-event-name record) 33))
                  (region (truncate-str (get-aws-region record) 13))
                  (ip (truncate-str (get-source-ip record) 16))
                  (ec (truncate-str (get-error-code record) 18))
                  (cat (categorize-event (get-event-name record))))
              (displayln (format "~a ~a ~a ~a ~a ~a ~a"
                                 (pad-right time-str 22)
                                 (pad-right user 30)
                                 (pad-right event 35)
                                 (pad-right region 15)
                                 (pad-right ip 18)
                                 (pad-right ec 20)
                                 cat))))
          records))))

  ;; Print aggregated summary
  (def (print-summary records)
    (if (null? records)
      (displayln "No results found.")
      (let ((by-event (make-hash-table))
            (by-user (make-hash-table))
            (by-region (make-hash-table))
            (by-category (make-hash-table)))
        (for-each
          (lambda (record)
            (hash-update! by-event (get-event-name record) (lambda (n) (+ n 1)) 0)
            (let ((u (get-username record)))
              (when (not (equal? u ""))
                (hash-update! by-user u (lambda (n) (+ n 1)) 0)))
            (hash-update! by-region (get-aws-region record) (lambda (n) (+ n 1)) 0)
            (hash-update! by-category (categorize-event (get-event-name record))
                          (lambda (n) (+ n 1)) 0))
          records)

        (displayln (format "Summary: ~a events\n" (length records)))

        (displayln "By Event:")
        (for-each
          (lambda (p) (displayln (format "  ~a ~a" (pad-right (car p) 40) (cdr p))))
          (sort (hash->list by-event) (lambda (a b) (> (cdr a) (cdr b)))))

        (displayln "\nBy User:")
        (for-each
          (lambda (p) (displayln (format "  ~a ~a" (pad-right (car p) 40) (cdr p))))
          (sort (hash->list by-user) (lambda (a b) (> (cdr a) (cdr b)))))

        (displayln "\nBy Region:")
        (for-each
          (lambda (p) (displayln (format "  ~a ~a" (pad-right (car p) 20) (cdr p))))
          (sort (hash->list by-region) (lambda (a b) (> (cdr a) (cdr b)))))

        (displayln "\nBy Category:")
        (for-each
          (lambda (p) (displayln (format "  ~a ~a" (pad-right (car p) 15) (cdr p))))
          (sort (hash->list by-category) (lambda (a b) (> (cdr a) (cdr b))))))))

  ;; Print summary with source IP warnings
  (def (print-summary-with-warnings records)
    (print-summary records)
    ;; Detect users accessing from multiple IPs
    (let ((user-ips (make-hash-table)))
      (for-each
        (lambda (record)
          (let ((user (get-username record))
                (ip (get-source-ip record)))
            (when (and (not (equal? user "")) (not (equal? ip "")))
              (let ((ips (or (hash-get user-ips user) (make-hash-table))))
                (hash-put! ips ip #t)
                (hash-put! user-ips user ips)))))
        records)
      (let ((warnings '()))
        (hash-for-each
          (lambda (user ips)
            (when (> (hash-length ips) 1)
              (set! warnings (cons (cons user (sort (hash-keys ips) string<?)) warnings))))
          user-ips)
        (unless (null? warnings)
          (displayln "\nSource IP Warnings:")
          (for-each
            (lambda (w)
              (displayln (format "  ~a: ~a unique IPs - ~a"
                                 (car w) (length (cdr w))
                                 (string-join (cdr w) ", "))))
            (sort warnings (lambda (a b) (> (length (cdr a)) (length (cdr b))))))))))

  ;; Print a single record in detail
  (def (print-single-record record)
    (if (not record)
      (displayln "Event not found.")
      (begin
        (displayln (make-string 80 #\=))
        (displayln (format "Event ID:      ~a" (get-event-id record)))
        (displayln (format "Event Time:    ~a" (get-event-time record)))
        (displayln (format "Event Name:    ~a" (get-event-name record)))
        (displayln (format "Event Source:  ~a" (get-event-source record)))
        (displayln (format "Event Type:    ~a" (get-event-type record)))
        (displayln (format "User:          ~a" (get-username record)))
        (displayln (format "Source IP:     ~a" (get-source-ip record)))
        (displayln (format "User Agent:    ~a" (get-user-agent record)))
        (displayln (format "Region:        ~a" (get-aws-region record)))
        (displayln (format "Account:       ~a" (get-recipient-account-id record)))
        (displayln (format "Request ID:    ~a" (get-request-id record)))
        (let ((ec (get-error-code record)))
          (when (not (equal? ec ""))
            (displayln (format "Error Code:    ~a" ec))
            (displayln (format "Error Message: ~a" (get-error-message record)))))
        (let ((rp (get-request-parameters record)))
          (when rp
            (displayln "\nRequest Parameters:")
            (displayln (json-object->string rp))))
        (let ((re (get-response-elements record)))
          (when re
            (displayln "\nResponse Elements:")
            (displayln (json-object->string re))))
        (displayln (make-string 80 #\=)))))

  ;; Print full search results with search term highlighted
  (def (print-full-records records search-term)
    (if (null? records)
      (displayln "No results found.")
      (begin
        (displayln (format "Found ~a matching events:\n" (length records)))
        (for-each
          (lambda (record)
            (displayln (make-string 60 #\-))
            (displayln (format "Time:    ~a" (get-event-time record)))
            (displayln (format "User:    ~a" (get-username record)))
            (displayln (format "Event:   ~a" (get-event-name record)))
            (displayln (format "Source:  ~a" (get-event-source record)))
            (displayln (format "Region:  ~a" (get-aws-region record)))
            (displayln (format "IP:      ~a" (get-source-ip record)))
            (let ((ec (get-error-code record)))
              (when (not (equal? ec ""))
                (displayln (format "Error:   ~a" ec))))
            (displayln (format "ID:      ~a" (get-event-id record))))
          records)
        (displayln (make-string 60 #\-)))))

) ;; end library
