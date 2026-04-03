;;; (kunabi loader) — S3 CloudTrail log loader with thread pool
;;;
;;; Downloads CloudTrail logs from S3, decompresses, parses, and stores in LevelDB.
#!chezscheme

(library (kunabi loader)
  (export s3-loader-config
          make-s3-loader-config
          s3-loader-config?
          s3-loader-config-bucket
          s3-loader-config-prefix
          s3-loader-config-region
          s3-loader-config-workers
          s3-loader-config-compact?
          s3-loader-config-verbose?
          s3-load!
          create-s3-loader-config)

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
          (jerboa-aws s3 api)
          (jerboa-aws s3 objects)
          (chez-zlib)
          (kunabi parser)
          (kunabi storage))

  (define (println . args)
    (for-each display args)
    (newline)
    (flush-output-port (current-output-port)))

  ;; Loader configuration record
  (define-record-type s3-loader-config
    (fields bucket prefix region workers compact? verbose?)
    (protocol
      (lambda (new)
        (lambda (bucket prefix region workers compact? verbose?)
          (new bucket prefix region workers compact? verbose?)))))

  (def (create-s3-loader-config bucket prefix
                                (region "us-east-1")
                                (workers 16)
                                (compact? #t)
                                (verbose? #f))
    (make-s3-loader-config bucket prefix region workers compact? verbose?))

  ;; List all objects under a prefix with pagination
  (def (list-all-objects client bucket-name prefix)
    (let loop ((token #f) (acc '()) (pages 0))
      (let* ((args (if token
                     (list-objects-v2 client bucket-name
                       'prefix: prefix
                       'continuation-token: token)
                     (list-objects-v2 client bucket-name
                       'prefix: prefix)))
             (contents (or (ht-ref args 'Contents) '()))
             ;; Contents can be a single hash (1 result) or a list of hashes
             (contents (cond
                         ((and (hashtable? contents) (not (list? contents)))
                          (list contents))
                         ((list? contents) contents)
                         (else '())))
             (keys (filter-map
                     (lambda (obj)
                       (if (hashtable? obj)
                         (ht-ref obj 'Key)
                         obj))
                     contents))
             (keys (filter string? keys))
             ;; Prepend keys in reverse to accumulator
             (acc (fold-left (lambda (a k) (cons k a)) acc keys))
             (pages (+ pages 1))
             (truncated? (let ((v (ht-ref args 'IsTruncated)))
                           (or (equal? v "true") (eq? v #t))))
             (next-token (ht-ref args 'NextContinuationToken)))
        (when (= (modulo pages 10) 0)
          (println (format "  Listing S3 objects... ~a found so far" (length acc))))
        (if (and truncated? next-token)
          (loop next-token acc pages)
          (reverse acc)))))

  ;; Helper for hash/hashtable ref
  (def (ht-ref ht key)
    (cond
      ((hashtable? ht)
       (guard (e [#t #f])
         (hashtable-ref ht key #f)))
      (else
       (hash-get ht key))))

  ;; Main load function: download CloudTrail logs from S3 and store in LevelDB
  (def (s3-load! cfg)
    (let* ((bucket-name (s3-loader-config-bucket cfg))
           (prefix (s3-loader-config-prefix cfg))
           (region (s3-loader-config-region cfg))
           (num-workers (s3-loader-config-workers cfg))
           (compact? (s3-loader-config-compact? cfg))
           (verbose? (s3-loader-config-verbose? cfg))
           (client (S3Client 'region: region)))

      ;; List objects in the bucket with pagination
      (let ((all-keys (list-all-objects client bucket-name prefix)))
        (println (format "Found ~a objects in S3" (length all-keys)))

        ;; Filter to only .json.gz files
        (let* ((prefix-keys (filter
                              (lambda (key)
                                (string-suffix? ".json.gz" key))
                              all-keys))
               ;; Filter out already-processed files
               (to-process (filter
                             (lambda (key)
                               (not (is-file-processed? bucket-name key "done")))
                             prefix-keys)))

          (println (format "Skipping ~a already processed, ~a new objects to process"
                             (- (length prefix-keys) (length to-process))
                             (length to-process)))

          (when (null? to-process)
            (println "No new objects to process"))

          (unless (null? to-process)
            ;; Process objects with thread pool
            (process-objects region bucket-name to-process num-workers compact? verbose?))))))

  ;; Process S3 objects using Chez threads
  ;; Each worker gets its own S3Client.
  (def (process-objects region bucket-name keys num-workers compact? verbose?)
    (let* ((total (length keys))
           (processed (box 0))
           (failed (box 0))
           (mx (make-mutex))
           (keys-queue (list->vector keys))
           (queue-idx (box 0)))

      (println (format "Processing ~a objects with ~a workers" total num-workers))

      ;; Worker function - grabs keys from queue
      (letrec ((worker-fn
                (lambda ()
                  (let ((client (S3Client 'region: region)))
                    (let loop ()
                      (let ((idx #f))
                        ;; Grab next index atomically
                        (mutex-acquire mx)
                        (when (< (unbox queue-idx) total)
                          (set! idx (unbox queue-idx))
                          (set-box! queue-idx (+ (unbox queue-idx) 1)))
                        (mutex-release mx)

                        (when idx
                          (let ((key (vector-ref keys-queue idx)))
                            (guard (e [#t
                                       (mutex-acquire mx)
                                       (set-box! failed (+ (unbox failed) 1))
                                       (let ((f (unbox failed)))
                                         (mutex-release mx)
                                         (println (format "FAIL [~a/~a]: ~a: ~a" f total key e)))])
                              (when verbose?
                                (println (format "  >> ~a" key)))
                              (let ((records (download-and-parse client bucket-name key compact?)))
                                (store-batch records)
                                (mark-file-processed! bucket-name key "done"))
                              (mutex-acquire mx)
                              (set-box! processed (+ (unbox processed) 1))
                              (let ((p (unbox processed)) (f (unbox failed)))
                                (mutex-release mx)
                                (when (or (= p 1) (= (modulo p 100) 0))
                                  (println (format "Progress: ~a/~a processed, ~a failed"
                                                     p total f))))))
                          (loop))))))))

        ;; Start worker threads
        (let ((threads (map (lambda (_) (fork-thread worker-fn))
                            (iota num-workers))))
          ;; Wait for all workers
          (for-each thread-join threads)))

      (println (format "Completed: ~a objects processed, ~a failed"
                         (unbox processed) (unbox failed)))))

  ;; Download and parse a single S3 object (decompresses gzip)
  (def (download-and-parse client bucket-name key compact?)
    (let* ((data (get-object client bucket-name key))
           ;; Data is gzipped, decompress it
           (decompressed (gunzip-bytevector (if (string? data)
                                   (string->utf8 data)
                                   data)))
           (json-str (utf8->string decompressed))
           (records (parse-cloudtrail json-str)))
      (if compact?
        (map strip-response-elements records)
        records)))

) ;; end library
