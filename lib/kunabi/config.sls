;;; (kunabi config) — Configuration loader for ~/.kunabi.yaml
;;;
;;; Loads configuration from YAML file with sensible defaults.
#!chezscheme

(library (kunabi config)
  (export load-config
          config-db
          config-bucket
          config-prefix
          config-regions
          config-duration
          config-omit-events
          config-omit-filters
          date-paths)

  (import (except (chezscheme)
                  make-hash-table hash-table?
                  sort sort!
                  printf fprintf
                  path-extension path-absolute?
                  with-input-from-string with-output-to-string
                  iota 1+ 1-
                  partition
                  make-date make-time)
          (except (jerboa prelude) days-in-month)
          (yaml))

  ;; Find the config file path
  (def (find-config-path)
    (let ((kunabi-path (path-expand "~/.kunabi.yaml")))
      (if (file-exists? kunabi-path)
        kunabi-path
        kunabi-path)))

  ;; Load config from YAML file, returns a hash table (or empty hash if file missing)
  (def (load-config (path #f))
    (let ((config-path (or path (find-config-path))))
      (if (file-exists? config-path)
        (let ((docs (yaml-load config-path)))
          (if (and (pair? docs) (hashtable? (car docs)))
            (car docs)
            (make-hash-table)))
        (make-hash-table))))

  ;; Config accessors
  (def (config-db cfg)
    (or (ht-get cfg "db") "./cloudtrail.db"))

  (def (config-bucket cfg)
    (or (ht-get cfg "bucket") ""))

  (def (config-prefix cfg)
    (or (ht-get cfg "prefix") ""))

  (def (config-regions cfg)
    (or (ht-get cfg "regions") '()))

  (def (config-duration cfg)
    (or (ht-get cfg "duration") ""))

  (def (config-omit-events cfg)
    (or (ht-get cfg "omit_events") '()))

  (def (config-omit-filters cfg)
    (or (ht-get cfg "omit_filters") '()))

  ;; Helper to get from either Chez hashtable or Jerboa hash-table
  (def (ht-get ht key)
    (cond
      ((hashtable? ht)
       (hashtable-ref ht key #f))
      (else
       (hash-get ht key))))

  ;; Days in a given month (handles leap years)
  (def (days-in-month year month)
    (cond
      ((memv month '(1 3 5 7 8 10 12)) 31)
      ((memv month '(4 6 9 11)) 30)
      ((= month 2) (if (or (and (zero? (modulo year 4))
                                 (not (zero? (modulo year 100))))
                            (zero? (modulo year 400)))
                     29 28))
      (else 31)))

  ;; Format a date as "YYYY/MM/DD"
  (def (format-date-path year month day)
    (format "~4,'0d/~2,'0d/~2,'0d" year month day))

  ;; Get current date components
  (def (current-date-parts)
    (let* ((t (current-time))
           (d (time-utc->date t 0)))
      (values (date-year d) (date-month d) (date-day d))))

  ;; Generate date-based S3 prefix paths based on duration setting
  ;; Returns a list of "YYYY/MM/DD" strings, or '() if no duration set
  (def (date-paths duration)
    (cond
      ((equal? duration "current_month")
       (let-values (((year month day) (current-date-parts)))
         (let loop ((d 1) (acc '()))
           (if (> d day)
             (reverse acc)
             (loop (+ d 1)
                   (cons (format-date-path year month d) acc))))))
      ((equal? duration "previous_month")
       (let-values (((year month _day) (current-date-parts)))
         (let* ((prev-month (if (= month 1) 12 (- month 1)))
                (prev-year (if (= month 1) (- year 1) year))
                (dim (days-in-month prev-year prev-month)))
           (let loop ((d 1) (acc '()))
             (if (> d dim)
               (reverse acc)
               (loop (+ d 1)
                     (cons (format-date-path prev-year prev-month d) acc)))))))
      ((equal? duration "current_day")
       (let-values (((year month day) (current-date-parts)))
         (list (format-date-path year month day))))
      (else '())))

) ;; end library
