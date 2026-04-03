;;; (kunabi storage) — LevelDB storage with multi-index scheme
;;;
;;; Stores CloudTrail records with multiple indices for efficient querying.
#!chezscheme

(library (kunabi storage)
  (export db-open
          db-close
          current-db
          with-snapshot
          store-batch
          store-record
          db-get
          get-batch
          scan-prefix
          scan-range
          is-file-processed?
          mark-file-processed!
          list-users
          list-events
          list-dates
          list-regions
          search-string
          purge
          compact-records
          build-composite-index
          compact-db
          extract-instance-info
          get-instance-info
          get-instance-name)

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
          (leveldb)
          (kunabi parser))

  ;; Current database handle
  (define current-db (make-parameter #f))

  ;; Open LevelDB with optimized settings
  (def (db-open path)
    (let ((opts (leveldb-options
                  'bloom-filter-bits 10
                  'write-buffer-size 67108864     ; 64MB
                  'lru-cache-capacity 33554432    ; 32MB
                  'compression #t)))
      (let ((db (leveldb-open path opts)))
        (current-db db)
        db)))

  ;; Close the database
  (def (db-close)
    (when (current-db)
      (leveldb-close (current-db))
      (current-db #f)))

  ;; Snapshot macro: creates a snapshot + read-options, ensures cleanup
  (define-syntax with-snapshot
    (syntax-rules ()
      [(_ db (snap-var opts-var) body ...)
       (let* ([snap-var (leveldb-snapshot db)]
              [opts-var (leveldb-read-options 'snapshot snap-var)])
         (dynamic-wind
           (lambda () #f)
           (lambda () body ...)
           (lambda () (leveldb-snapshot-release db snap-var))))]))

  ;; ---- Instance Info Extraction ----

  ;; Extract instance information from CloudTrail record ResponseElements
  (def (extract-instance-info record)
    (let ((resp (get-response-elements record)))
      (if (not resp)
        '()
        (let ((instances '()))
          ;; RunInstances: responseElements.instancesSet.items[]
          (let ((instances-set (hash-get resp "instancesSet")))
            (when (and instances-set (hashtable? instances-set))
              (let ((items (hash-get instances-set "items")))
                (when (list? items)
                  (set! instances (append instances (extract-instances-from-items items)))))))
          ;; DescribeInstances: responseElements.reservationSet.items[].instancesSet.items[]
          (let ((reservation-set (hash-get resp "reservationSet")))
            (when (and reservation-set (hashtable? reservation-set))
              (let ((res-items (hash-get reservation-set "items")))
                (when (list? res-items)
                  (for-each
                    (lambda (res)
                      (when (hashtable? res)
                        (let ((is (hash-get res "instancesSet")))
                          (when (and is (hashtable? is))
                            (let ((items (hash-get is "items")))
                              (when (list? items)
                                (set! instances (append instances (extract-instances-from-items items)))))))))
                    res-items)))))
          instances))))

  (def (extract-instances-from-items items)
    (let ((result '()))
      (for-each
        (lambda (item)
          (when (hashtable? item)
            (let ((info (make-hash-table)))
              (let ((v (hash-get item "instanceId")))
                (when (string? v) (hash-put! info "instanceId" v)))
              (let ((v (hash-get item "privateDnsName")))
                (when (string? v) (hash-put! info "privateDnsName" v)))
              (let ((v (hash-get item "privateIpAddress")))
                (when (string? v) (hash-put! info "privateIpAddress" v)))
              (let ((v (hash-get item "publicDnsName")))
                (when (string? v) (hash-put! info "publicDnsName" v)))
              (let ((v (hash-get item "publicIpAddress")))
                (when (string? v) (hash-put! info "publicIpAddress" v)))
              (let ((v (hash-get item "instanceType")))
                (when (string? v) (hash-put! info "instanceType" v)))
              ;; Extract Name tag
              (let ((tag-set (hash-get item "tagSet")))
                (when (and tag-set (hashtable? tag-set))
                  (let ((tag-items (hash-get tag-set "items")))
                    (when (list? tag-items)
                      (for-each
                        (lambda (tag)
                          (when (hashtable? tag)
                            (when (equal? (hash-get tag "key") "Name")
                              (let ((val (hash-get tag "value")))
                                (when (string? val)
                                  (hash-put! info "name" val))))))
                        tag-items)))))
              (when (hash-get info "instanceId")
                (set! result (cons info result))))))
        items)
      (reverse result)))

  ;; Merge instance info, preferring non-empty new values
  (def (merge-instance-info existing new-info)
    (let ((result (hash-copy existing)))
      (for-each
        (lambda (key)
          (let ((val (hash-get new-info key)))
            (when (and (string? val) (not (equal? val "")))
              (hash-put! result key val))))
        '("name" "privateDnsName" "privateIpAddress"
          "publicDnsName" "publicIpAddress" "instanceType"))
      result))

  ;; Get instance info by ID
  (def (get-instance-info instance-id)
    (let ((key (format "idx:instance:~a" instance-id)))
      (let ((data (leveldb-get (current-db) key)))
        (if (bytevector? data)
          (string->json-object (utf8->string data))
          #f))))

  ;; Get human-readable name for an instance
  (def (get-instance-name instance-id)
    (let ((info (get-instance-info instance-id)))
      (if info
        (or (hash-get info "name")
            (hash-get info "privateDnsName")
            (hash-get info "privateIpAddress")
            "")
        "")))

  ;; ---- Batch Storage ----

  ;; Store multiple CloudTrail records atomically with all indices
  (def (store-batch records)
    (let ((batch (leveldb-writebatch)))
      (for-each
        (lambda (record)
          (let* ((event-id (get-event-id record))
                 (event-time-str (get-event-time record))
                 (event-name (get-event-name record))
                 (username (get-username record))
                 (error-code (get-error-code record))
                 (region (get-aws-region record))
                 (json-data (record->json-string record)))

            ;; Primary record: event:{eventID} -> JSON
            (leveldb-writebatch-put batch
              (format "event:~a" event-id)
              json-data)

            ;; User index: idx:user:{username}:{time}:{eventID}
            (when (and username (not (equal? username "")))
              (leveldb-writebatch-put batch
                (format "idx:user:~a:~a:~a" username event-time-str event-id)
                event-id))

            ;; Event name index: idx:event:{eventName}:{time}:{eventID}
            (when (and event-name (not (equal? event-name "")))
              (leveldb-writebatch-put batch
                (format "idx:event:~a:~a:~a" event-name event-time-str event-id)
                event-id))

            ;; Composite user-event index
            (when (and username (not (equal? username ""))
                       event-name (not (equal? event-name "")))
              (leveldb-writebatch-put batch
                (format "idx:user-event:~a:~a:~a:~a" username event-name event-time-str event-id)
                event-id))

            ;; Error code index
            (when (and error-code (not (equal? error-code "")))
              (leveldb-writebatch-put batch
                (format "idx:error:~a:~a:~a" error-code event-time-str event-id)
                event-id))

            ;; Region index
            (when (and region (not (equal? region "")))
              (leveldb-writebatch-put batch
                (format "idx:region:~a:~a:~a" region event-time-str event-id)
                event-id))

            ;; Date index: idx:date:{YYYY-MM-DD}:{eventID}
            (when (>= (string-length event-time-str) 10)
              (let ((date-str (substring event-time-str 0 10)))
                (leveldb-writebatch-put batch
                  (format "idx:date:~a:~a" date-str event-id)
                  event-id)))

            ;; Instance info extraction and storage
            (let ((instances (extract-instance-info record)))
              (for-each
                (lambda (inst)
                  (let ((iid (hash-get inst "instanceId")))
                    (when iid
                      (let* ((inst-key (format "idx:instance:~a" iid))
                             (existing-data (leveldb-get (current-db) inst-key))
                             (merged (if (bytevector? existing-data)
                                       (let ((existing (string->json-object
                                                         (utf8->string existing-data))))
                                         (merge-instance-info existing inst))
                                       inst))
                             (inst-json (json-object->string merged)))
                        (leveldb-writebatch-put batch inst-key inst-json)))))
                instances))))
        records)
      (leveldb-write (current-db) batch)))

  ;; Store a single record
  (def (store-record record)
    (store-batch (list record)))

  ;; ---- Retrieval ----

  ;; Get a single record by event ID
  (def (db-get event-id (read-opts #f))
    (let* ((key (format "event:~a" event-id))
           (data (if read-opts
                   (leveldb-get (current-db) key read-opts)
                   (leveldb-get (current-db) key))))
      (if (bytevector? data)
        (string->json-object (utf8->string data))
        #f)))

  ;; Batch retrieve records by event IDs
  (def (get-batch event-ids (read-opts #f))
    (let ((result (make-hash-table))
          (sorted-ids (sort event-ids string<?)))
      (for-each
        (lambda (eid)
          (let* ((key (format "event:~a" eid))
                 (data (if read-opts
                         (leveldb-get (current-db) key read-opts)
                         (leveldb-get (current-db) key))))
            (when (bytevector? data)
              (let ((record (string->json-object (utf8->string data))))
                (hash-put! result eid record)))))
        sorted-ids)
      result))

  ;; ---- Scanning ----

  ;; Prefix scan - returns list of (key . value) pairs as strings
  (def (scan-prefix prefix (read-opts #f))
    (let ((itor (if read-opts
                  (leveldb-iterator (current-db) read-opts)
                  (leveldb-iterator (current-db))))
          (result '()))
      (leveldb-iterator-seek itor prefix)
      (let loop ()
        (when (leveldb-iterator-valid? itor)
          (let ((key (utf8->string (leveldb-iterator-key itor))))
            (when (string-prefix? prefix key)
              (let ((val (utf8->string (leveldb-iterator-value itor))))
                (set! result (cons (cons key val) result))
                (leveldb-iterator-next itor)
                (loop))))))
      (leveldb-iterator-close itor)
      (reverse result)))

  ;; Range scan - returns list of (key . value) pairs for keys in [start, limit)
  (def (scan-range start limit (read-opts #f))
    (let ((itor (if read-opts
                  (leveldb-iterator (current-db) read-opts)
                  (leveldb-iterator (current-db))))
          (result '()))
      (leveldb-iterator-seek itor start)
      (let loop ()
        (when (leveldb-iterator-valid? itor)
          (let ((key (utf8->string (leveldb-iterator-key itor))))
            (when (string<? key limit)
              (let ((val (utf8->string (leveldb-iterator-value itor))))
                (set! result (cons (cons key val) result))
                (leveldb-iterator-next itor)
                (loop))))))
      (leveldb-iterator-close itor)
      (reverse result)))

  ;; ---- File Processing Tracking ----

  (def (is-file-processed? bucket key etag)
    (let* ((k (format "processed:~a:~a" bucket key))
           (data (leveldb-get (current-db) k)))
      (if (bytevector? data)
        (equal? (utf8->string data) etag)
        #f)))

  (def (mark-file-processed! bucket key etag)
    (let ((k (format "processed:~a:~a" bucket key)))
      (leveldb-put (current-db) k etag)))

  ;; ---- List Operations ----

  ;; High byte for seeking past a prefix
  (define seek-suffix (string (integer->char 255)))

  ;; Extract value from index key
  (def (extract-index-value key prefix-len)
    (let* ((len (string-length key))
           (start prefix-len)
           (end (let loop ((i start))
                  (cond
                    ((>= i len) len)
                    ((char=? (string-ref key i) #\:) i)
                    (else (loop (+ i 1)))))))
      (if (> end start)
        (substring key start end)
        #f)))

  ;; Extract unique values from index using seek-skip optimization
  (def (list-unique-from-index prefix)
    (let ((results '())
          (itor (leveldb-iterator (current-db)))
          (prefix-len (string-length prefix)))
      (leveldb-iterator-seek itor prefix)
      (let loop ()
        (when (leveldb-iterator-valid? itor)
          (let ((key (utf8->string (leveldb-iterator-key itor))))
            (when (string-prefix? prefix key)
              (let ((value (extract-index-value key prefix-len)))
                (when value
                  (set! results (cons value results))
                  ;; Seek past all entries with this value
                  (leveldb-iterator-seek itor (string-append prefix value seek-suffix)))
                (loop))))))
      (leveldb-iterator-close itor)
      (sort results string<?)))

  (def (list-users)
    (list-unique-from-index "idx:user:"))

  (def (list-events)
    (list-unique-from-index "idx:event:"))

  (def (list-dates)
    (list-unique-from-index "idx:date:"))

  (def (list-regions)
    (list-unique-from-index "idx:region:"))

  ;; ---- Search ----

  ;; Full-text search across all records
  (def (search-string search-str case-insensitive? (limit 0))
    (let ((itor (leveldb-iterator (current-db)))
          (results '())
          (search-lower (if case-insensitive? (string-downcase search-str) search-str))
          (count 0))
      (leveldb-iterator-seek itor "event:")
      (let loop ()
        (when (and (leveldb-iterator-valid? itor)
                   (or (= limit 0) (< count limit)))
          (let* ((key (utf8->string (leveldb-iterator-key itor))))
            (when (string-prefix? "event:" key)
              (let* ((data (utf8->string (leveldb-iterator-value itor)))
                     (matches? (if case-insensitive?
                                 (string-contains (string-downcase data) search-lower)
                                 (string-contains data search-str))))
                (when matches?
                  (let ((record (string->json-object data)))
                    (set! results (cons record results))
                    (set! count (+ count 1)))))
              (leveldb-iterator-next itor)
              (loop)))))
      (leveldb-iterator-close itor)
      ;; Sort by event time (newest first)
      (sort results
            (lambda (a b)
              (string>? (get-event-time a) (get-event-time b))))))

  ;; ---- Purge ----

  ;; Delete events older than cutoff date. Returns count of deleted events.
  (def (purge cutoff-date-str dry-run?)
    (let ((event-ids '())
          (itor (leveldb-iterator (current-db))))
      (leveldb-iterator-seek itor "idx:date:")
      (let loop ()
        (when (leveldb-iterator-valid? itor)
          (let* ((key (utf8->string (leveldb-iterator-key itor)))
                 (parts (string-split key #\:)))
            (when (and (string-prefix? "idx:date:" key)
                       (>= (length parts) 4))
              (let ((date-str (list-ref parts 2))
                    (event-id (list-ref parts 3)))
                (when (string<? date-str cutoff-date-str)
                  (set! event-ids (cons event-id event-ids))))
              (leveldb-iterator-next itor)
              (loop)))))
      (leveldb-iterator-close itor)

      (if dry-run?
        (length event-ids)
        ;; Delete in batches of 1000
        (let ((deleted 0)
              (total (length event-ids)))
          (let loop ((ids event-ids))
            (unless (null? ids)
              (let* ((batch-size (min 1000 (length ids)))
                     (batch-ids (take ids batch-size))
                     (rest-ids (drop ids batch-size)))
                (delete-event-batch batch-ids)
                (set! deleted (+ deleted batch-size))
                (when (or (= (modulo deleted 1000) 0) (= deleted total))
                  (displayln (format "Deleted ~a/~a events" deleted total)))
                (loop rest-ids))))
          deleted))))

  ;; Delete a batch of events and all their index entries
  (def (delete-event-batch event-ids)
    (let ((batch (leveldb-writebatch)))
      (for-each
        (lambda (event-id)
          (let ((record (db-get event-id)))
            (when record
              (let ((event-time-str (get-event-time record))
                    (event-name (get-event-name record))
                    (username (get-username record))
                    (error-code (get-error-code record))
                    (region (get-aws-region record)))
                ;; Delete primary record
                (leveldb-writebatch-delete batch (format "event:~a" event-id))
                ;; Delete user index
                (when (not (equal? username ""))
                  (leveldb-writebatch-delete batch
                    (format "idx:user:~a:~a:~a" username event-time-str event-id)))
                ;; Delete event name index
                (when (not (equal? event-name ""))
                  (leveldb-writebatch-delete batch
                    (format "idx:event:~a:~a:~a" event-name event-time-str event-id)))
                ;; Delete composite index
                (when (and (not (equal? username "")) (not (equal? event-name "")))
                  (leveldb-writebatch-delete batch
                    (format "idx:user-event:~a:~a:~a:~a" username event-name event-time-str event-id)))
                ;; Delete error index
                (when (not (equal? error-code ""))
                  (leveldb-writebatch-delete batch
                    (format "idx:error:~a:~a:~a" error-code event-time-str event-id)))
                ;; Delete region index
                (when (not (equal? region ""))
                  (leveldb-writebatch-delete batch
                    (format "idx:region:~a:~a:~a" region event-time-str event-id)))
                ;; Delete date index
                (when (>= (string-length event-time-str) 10)
                  (let ((date-str (substring event-time-str 0 10)))
                    (leveldb-writebatch-delete batch
                      (format "idx:date:~a:~a" date-str event-id))))))))
        event-ids)
      (leveldb-write (current-db) batch)))

  ;; ---- Compact Records ----

  ;; Remove ResponseElements from stored events to save space
  (def (compact-records dry-run?)
    (with-snapshot (current-db) (snap snap-opts)
      (let ((itor (leveldb-iterator (current-db) snap-opts))
            (compacted 0)
            (total 0)
            (batch (if dry-run? #f (leveldb-writebatch))))
        (leveldb-iterator-seek itor "event:")
        (let loop ()
          (when (leveldb-iterator-valid? itor)
            (let ((key (utf8->string (leveldb-iterator-key itor))))
              (when (string-prefix? "event:" key)
                (set! total (+ total 1))
                (let* ((data (utf8->string (leveldb-iterator-value itor)))
                       (record (string->json-object data))
                       (resp (get-response-elements record)))
                  (when resp
                    (set! compacted (+ compacted 1))
                    (unless dry-run?
                      (let* ((stripped (strip-response-elements record))
                             (new-data (record->json-string stripped)))
                        (leveldb-writebatch-put batch key new-data))
                      ;; Write batch periodically
                      (when (= (modulo compacted 1000) 0)
                        (leveldb-write (current-db) batch)
                        (set! batch (leveldb-writebatch))
                        (displayln (format "Compacted ~a events" compacted))))))
                (leveldb-iterator-next itor)
                (loop)))))
        (leveldb-iterator-close itor)
        ;; Write remaining batch
        (when (and (not dry-run?) batch)
          (leveldb-write (current-db) batch))
        (when (and (not dry-run?) (> compacted 0))
          (displayln (format "Compacted ~a/~a events" compacted total)))
        compacted)))

  ;; ---- Build Composite Index ----

  (def (build-composite-index)
    (let ((itor (leveldb-iterator (current-db)))
          (created 0)
          (total 0)
          (batch (leveldb-writebatch)))
      (leveldb-iterator-seek itor "event:")
      (let loop ()
        (when (leveldb-iterator-valid? itor)
          (let ((key (utf8->string (leveldb-iterator-key itor))))
            (when (string-prefix? "event:" key)
              (set! total (+ total 1))
              (let* ((data (utf8->string (leveldb-iterator-value itor)))
                     (record (string->json-object data))
                     (event-time-str (get-event-time record))
                     (event-name (get-event-name record))
                     (event-id (get-event-id record))
                     (username (get-username record)))
                (when (and (not (equal? username ""))
                           (not (equal? event-name "")))
                  (let ((composite-key (format "idx:user-event:~a:~a:~a:~a"
                                               username event-name event-time-str event-id)))
                    (leveldb-writebatch-put batch composite-key event-id)
                    (set! created (+ created 1))
                    (when (= (modulo created 1000) 0)
                      (leveldb-write (current-db) batch)
                      (set! batch (leveldb-writebatch))
                      (displayln (format "Indexed ~a/~a events" created total))))))
              (leveldb-iterator-next itor)
              (loop)))))
      (leveldb-iterator-close itor)
      (leveldb-write (current-db) batch)
      (displayln (format "Created ~a composite index entries from ~a events" created total))
      created))

  ;; ---- LevelDB Compaction ----

  (def (compact-db)
    (leveldb-compact-range (current-db) #f #f))

) ;; end library
