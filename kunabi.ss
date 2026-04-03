#!/usr/bin/env scheme --script
;;; kunabi.ss — CloudTrail log analyzer CLI
;;;
;;; Usage: kunabi <command> [options]
#!chezscheme

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
        (kunabi config)
        (kunabi parser)
        (kunabi storage)
        (kunabi loader)
        (kunabi query)
        (kunabi detection)
        (kunabi billing))

(define (println . args)
  (for-each display args)
  (newline)
  (flush-output-port (current-output-port)))

;; Get args from KUNABI_ARGC/KUNABI_ARGn env vars (set by kunabi-main.c for static binary)
;; or fall back to (command-line) for interpreted mode.
(define (get-real-args)
  (let ((argc-str (getenv "KUNABI_ARGC")))
    (if argc-str
      (let ((argc (string->number argc-str)))
        (let loop ((i 0) (acc '()))
          (if (>= i argc)
            (reverse acc)
            (let ((val (getenv (format "KUNABI_ARG~a" i))))
              (loop (+ i 1) (cons (or val "") acc))))))
      (let ((cmdline (command-line)))
        (if (pair? cmdline) (cdr cmdline) '())))))

;; ---- Help Text ----

(define help-text "
kunabi - CloudTrail Log Analyzer (Jerboa Edition)

Usage: kunabi <command> [options]

Commands:
  load                     Download CloudTrail logs from S3
  report                   Query CloudTrail events
  list <type>              List unique values (users, events, dates, regions)
  detect                   Security detection scan
  billing                  Billing impact analysis
  search <term>            Full-text search
  get <event-id>           Fetch single event by ID
  purge <cutoff-date>      Delete old events
  compact                  Strip ResponseElements from stored events
  leveldb-compact          Trigger LevelDB compaction
  reindex                  Build composite user-event indices
  help                     Show this help

Global Options:
  --db <path>              Path to LevelDB database (default: ./cloudtrail.db)
  --config <path>          Path to config file (default: ~/.kunabi.yaml)

Load Options:
  --bucket <name>          S3 bucket name
  --prefix <path>          S3 key prefix
  --region <region>        AWS region for S3 (default: us-east-1)
  --workers <n>            Number of parallel workers (default: 16)
  --verbose                Show each file being processed

Report Options:
  --user <name>            Filter by username
  --event <name>           Filter by event name
  --error <code>           Filter by error code
  --region <name>          Filter by AWS region
  --start <YYYY-MM-DD>     Start date
  --end <YYYY-MM-DD>       End date
  --summary                Show aggregated summary
  --warnings               Include source IP warnings

Detect Options:
  --severity <level>       Minimum severity (CRITICAL, HIGH, MEDIUM, LOW)
  --category <name>        Filter by category
  --summary                Show detection summary only

Billing Options:
  --impact <type>          Filter by impact (\"Cost Increase\", \"Cost Decrease\", \"Cost Change\")
  --service <name>         Filter by service
  --summary                Show billing summary only

Search Options:
  --case-insensitive       Case-insensitive search
  --limit <n>              Maximum results (default: unlimited)

Purge Options:
  --dry-run                Show what would be deleted without deleting
")

;; ---- Argument Parsing ----

(define (parse-args args)
  (let ((result (make-hash-table)))
    (let loop ((rest args))
      (cond
        ((null? rest) result)
        ((string=? (car rest) "--db")
         (when (pair? (cdr rest))
           (hash-put! result 'db (cadr rest))
           (loop (cddr rest))))
        ((string=? (car rest) "--config")
         (when (pair? (cdr rest))
           (hash-put! result 'config (cadr rest))
           (loop (cddr rest))))
        ((string=? (car rest) "--bucket")
         (when (pair? (cdr rest))
           (hash-put! result 'bucket (cadr rest))
           (loop (cddr rest))))
        ((string=? (car rest) "--prefix")
         (when (pair? (cdr rest))
           (hash-put! result 'prefix (cadr rest))
           (loop (cddr rest))))
        ((string=? (car rest) "--region")
         (when (pair? (cdr rest))
           (hash-put! result 'region (cadr rest))
           (loop (cddr rest))))
        ((string=? (car rest) "--workers")
         (when (pair? (cdr rest))
           (hash-put! result 'workers (string->number (cadr rest)))
           (loop (cddr rest))))
        ((string=? (car rest) "--user")
         (when (pair? (cdr rest))
           (hash-put! result 'user (cadr rest))
           (loop (cddr rest))))
        ((string=? (car rest) "--event")
         (when (pair? (cdr rest))
           (hash-put! result 'event (cadr rest))
           (loop (cddr rest))))
        ((string=? (car rest) "--error")
         (when (pair? (cdr rest))
           (hash-put! result 'error (cadr rest))
           (loop (cddr rest))))
        ((string=? (car rest) "--start")
         (when (pair? (cdr rest))
           (hash-put! result 'start-date (cadr rest))
           (loop (cddr rest))))
        ((string=? (car rest) "--end")
         (when (pair? (cdr rest))
           (hash-put! result 'end-date (cadr rest))
           (loop (cddr rest))))
        ((string=? (car rest) "--severity")
         (when (pair? (cdr rest))
           (hash-put! result 'severity (cadr rest))
           (loop (cddr rest))))
        ((string=? (car rest) "--category")
         (when (pair? (cdr rest))
           (hash-put! result 'category (cadr rest))
           (loop (cddr rest))))
        ((string=? (car rest) "--impact")
         (when (pair? (cdr rest))
           (hash-put! result 'impact (cadr rest))
           (loop (cddr rest))))
        ((string=? (car rest) "--service")
         (when (pair? (cdr rest))
           (hash-put! result 'service (cadr rest))
           (loop (cddr rest))))
        ((string=? (car rest) "--limit")
         (when (pair? (cdr rest))
           (hash-put! result 'limit (string->number (cadr rest)))
           (loop (cddr rest))))
        ((string=? (car rest) "--summary")
         (hash-put! result 'summary #t)
         (loop (cdr rest)))
        ((string=? (car rest) "--warnings")
         (hash-put! result 'warnings #t)
         (loop (cdr rest)))
        ((string=? (car rest) "--verbose")
         (hash-put! result 'verbose #t)
         (loop (cdr rest)))
        ((string=? (car rest) "--dry-run")
         (hash-put! result 'dry-run #t)
         (loop (cdr rest)))
        ((string=? (car rest) "--case-insensitive")
         (hash-put! result 'case-insensitive #t)
         (loop (cdr rest)))
        ((string-prefix? "--" (car rest))
         ;; Unknown option, skip
         (loop (cdr rest)))
        (else
         ;; Positional argument
         (let ((positionals (or (hash-get result 'positionals) '())))
           (hash-put! result 'positionals (append positionals (list (car rest)))))
         (loop (cdr rest)))))
    result))

;; ---- Commands ----

(define (cmd-load opts cfg)
  (let* ((bucket (or (hash-get opts 'bucket) (config-bucket cfg)))
         (prefix (or (hash-get opts 'prefix) (config-prefix cfg)))
         (region (or (hash-get opts 'region) "us-east-1"))
         (workers (or (hash-get opts 'workers) 16))
         (verbose? (hash-get opts 'verbose))
         (regions (config-regions cfg))
         (duration (config-duration cfg))
         (date-paths-list (date-paths duration)))

    (when (equal? bucket "")
      (println "Error: --bucket is required (or set in config)")
      (exit 1))

    (when (equal? prefix "")
      (println "Error: --prefix is required (or set in config)")
      (exit 1))

    (println (format "Loading CloudTrail logs from s3://~a/~a" bucket prefix))
    (println (format "  Region: ~a, Workers: ~a" region workers))

    ;; If regions are configured, iterate over them
    (if (and (pair? regions) (pair? date-paths-list))
      ;; Multi-region, multi-date loading
      (for-each
        (lambda (r)
          (for-each
            (lambda (date-path)
              (let ((full-prefix (string-append prefix "/" r "/" date-path)))
                (println (format "\nScanning ~a" full-prefix))
                (let ((loader-cfg (create-s3-loader-config bucket full-prefix region workers #t verbose?)))
                  (s3-load! loader-cfg))))
            date-paths-list))
        regions)
      ;; Simple single prefix loading
      (let ((loader-cfg (create-s3-loader-config bucket prefix region workers #t verbose?)))
        (s3-load! loader-cfg)))

    (println "\nLoad complete")))

(define (cmd-report opts cfg)
  (let* ((user (or (hash-get opts 'user) ""))
         (event (or (hash-get opts 'event) ""))
         (error-code (or (hash-get opts 'error) ""))
         (region (or (hash-get opts 'region) ""))
         (start-date (or (hash-get opts 'start-date) ""))
         (end-date (or (hash-get opts 'end-date) ""))
         (summary? (hash-get opts 'summary))
         (warnings? (hash-get opts 'warnings))
         (f (make-filters user event error-code region start-date end-date))
         (results (query-search f)))

    (cond
      ((and summary? warnings?)
       (print-summary-with-warnings results))
      (summary?
       (print-summary results))
      (else
       (print-results results)))))

(define (cmd-list opts cfg)
  (let ((positionals (or (hash-get opts 'positionals) '())))
    (if (< (length positionals) 2)
      (begin
        (println "Usage: kunabi list <type>")
        (println "Types: users, events, dates, regions")
        (exit 1))
      (let ((list-type (cadr positionals)))
        (cond
          ((string=? list-type "users")
           (for-each displayln (list-users)))
          ((string=? list-type "events")
           (for-each displayln (list-events)))
          ((string=? list-type "dates")
           (for-each displayln (list-dates)))
          ((string=? list-type "regions")
           (for-each displayln (list-regions)))
          (else
           (println (format "Unknown list type: ~a" list-type))
           (println "Types: users, events, dates, regions")
           (exit 1)))))))

(define (cmd-detect opts cfg)
  ;; Apply omit configuration
  (set-omit-events! (config-omit-events cfg))
  (set-omit-filters! (config-omit-filters cfg))

  (let* ((severity (hash-get opts 'severity))
         (category (hash-get opts 'category))
         (summary? (hash-get opts 'summary))
         (findings (cond
                     (severity (scan-by-severity severity))
                     (category (scan-by-category category))
                     (else (scan-all)))))
    (if summary?
      (print-detection-summary findings)
      (print-findings findings))))

(define (cmd-billing opts cfg)
  (let* ((impact (hash-get opts 'impact))
         (service (hash-get opts 'service))
         (summary? (hash-get opts 'summary))
         (findings (cond
                     (impact (scan-billing-by-impact impact))
                     (service (scan-billing-by-service service))
                     (else (scan-billing)))))
    (if summary?
      (print-billing-summary findings)
      (print-billing-findings findings))))

(define (cmd-search opts cfg)
  (let ((positionals (or (hash-get opts 'positionals) '())))
    (if (< (length positionals) 2)
      (begin
        (println "Usage: kunabi search <term> [--case-insensitive] [--limit N]")
        (exit 1))
      (let* ((search-term (cadr positionals))
             (case-insensitive? (hash-get opts 'case-insensitive))
             (limit (or (hash-get opts 'limit) 0))
             (results (search-string search-term case-insensitive? limit)))
        (print-full-records results search-term)))))

(define (cmd-get opts cfg)
  (let ((positionals (or (hash-get opts 'positionals) '())))
    (if (< (length positionals) 2)
      (begin
        (println "Usage: kunabi get <event-id>")
        (exit 1))
      (let* ((event-id (cadr positionals))
             (record (db-get event-id)))
        (print-single-record record)))))

(define (cmd-purge opts cfg)
  (let ((positionals (or (hash-get opts 'positionals) '())))
    (if (< (length positionals) 2)
      (begin
        (println "Usage: kunabi purge <cutoff-date> [--dry-run]")
        (println "  cutoff-date: YYYY-MM-DD (events older than this will be deleted)")
        (exit 1))
      (let* ((cutoff-date (cadr positionals))
             (dry-run? (hash-get opts 'dry-run))
             (count (purge cutoff-date dry-run?)))
        (if dry-run?
          (println (format "Would delete ~a events older than ~a" count cutoff-date))
          (println (format "Deleted ~a events older than ~a" count cutoff-date)))))))

(define (cmd-compact opts cfg)
  (let* ((dry-run? (hash-get opts 'dry-run))
         (count (compact-records dry-run?)))
    (if dry-run?
      (println (format "Would compact ~a events with ResponseElements" count))
      (println (format "Compacted ~a events" count)))))

(define (cmd-leveldb-compact opts cfg)
  (println "Running LevelDB compaction...")
  (compact-db)
  (println "Compaction complete"))

(define (cmd-reindex opts cfg)
  (println "Building composite user-event indices...")
  (build-composite-index)
  (println "Reindex complete"))

;; ---- Main ----

(define (main args)
  (if (or (null? args)
          (member (car args) '("help" "--help" "-h")))
    (begin
      (display help-text)
      (exit 0))
    (let* ((opts (parse-args args))
           (config-path (hash-get opts 'config))
           (cfg (load-config config-path))
           (db-path (or (hash-get opts 'db) (config-db cfg)))
           (command (car args)))

      ;; Commands that don't need DB
      (cond
        ((string=? command "help")
         (display help-text)
         (exit 0)))

      ;; Open database for commands that need it
      (db-open db-path)

      (guard (e [#t
                 (db-close)
                 (println (format "Error: ~a" (condition-message e)))
                 (exit 1)])
        (cond
          ((string=? command "load")
           (cmd-load opts cfg))
          ((string=? command "report")
           (cmd-report opts cfg))
          ((string=? command "list")
           (cmd-list opts cfg))
          ((string=? command "detect")
           (cmd-detect opts cfg))
          ((string=? command "billing")
           (cmd-billing opts cfg))
          ((string=? command "search")
           (cmd-search opts cfg))
          ((string=? command "get")
           (cmd-get opts cfg))
          ((string=? command "purge")
           (cmd-purge opts cfg))
          ((string=? command "compact")
           (cmd-compact opts cfg))
          ((string=? command "leveldb-compact")
           (cmd-leveldb-compact opts cfg))
          ((string=? command "reindex")
           (cmd-reindex opts cfg))
          (else
           (println (format "Unknown command: ~a" command))
           (println "Run 'kunabi help' for usage")
           (db-close)
           (exit 1))))

      (db-close))))

;; Entry point
(main (get-real-args))
