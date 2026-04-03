;;; (kunabi parser) — CloudTrail JSON parser
;;;
;;; Parses CloudTrail JSON data and extracts fields from records.
#!chezscheme

(library (kunabi parser)
  (export parse-cloudtrail
          get-event-time
          get-username
          get-event-id
          get-event-name
          get-event-source
          get-aws-region
          get-source-ip
          get-user-agent
          get-error-code
          get-error-message
          get-request-parameters
          get-response-elements
          get-request-id
          get-event-type
          get-recipient-account-id
          get-user-identity
          record->json-string
          strip-response-elements)

  (import (except (chezscheme)
                  make-hash-table hash-table?
                  sort sort!
                  printf fprintf
                  path-extension path-absolute?
                  with-input-from-string with-output-to-string
                  iota 1+ 1-
                  partition
                  make-date make-time)
          (jerboa prelude))

  ;; Parse CloudTrail JSON data (bytevector or string) into a list of record hash tables
  (def (parse-cloudtrail data)
    (let* ((json (cond
                   ((bytevector? data)
                    (string->json-object (utf8->string data)))
                   ((string? data)
                    (string->json-object data))
                   (else (error 'parse-cloudtrail "expected bytevector or string" data))))
           (records (hash-get json "Records")))
      (if (list? records) records '())))

  ;; Accessors for CloudTrail record fields
  (def (get-event-id record)
    (or (hash-get record "eventID") ""))

  (def (get-event-time record)
    (or (hash-get record "eventTime") ""))

  (def (get-event-name record)
    (or (hash-get record "eventName") ""))

  (def (get-event-source record)
    (or (hash-get record "eventSource") ""))

  (def (get-aws-region record)
    (or (hash-get record "awsRegion") ""))

  (def (get-source-ip record)
    (or (hash-get record "sourceIPAddress") ""))

  (def (get-user-agent record)
    (or (hash-get record "userAgent") ""))

  (def (get-error-code record)
    (or (hash-get record "errorCode") ""))

  (def (get-error-message record)
    (or (hash-get record "errorMessage") ""))

  (def (get-request-parameters record)
    (hash-get record "requestParameters"))

  (def (get-response-elements record)
    (hash-get record "responseElements"))

  (def (get-request-id record)
    (or (hash-get record "requestID") ""))

  (def (get-event-type record)
    (or (hash-get record "eventType") ""))

  (def (get-recipient-account-id record)
    (or (hash-get record "recipientAccountId") ""))

  (def (get-user-identity record)
    (hash-get record "userIdentity"))

  ;; Extract username from CloudTrail record
  ;; Handles: IAMUser, AssumedRole, FederatedUser, Root, AWSService
  (def (get-username record)
    (let ((identity (get-user-identity record)))
      (if (not identity)
        ""
        (let ((username (hash-get identity "userName")))
          (if (and username (not (equal? username "")))
            username
            (let ((arn (hash-get identity "arn")))
              (if (and arn (not (equal? arn "")))
                (extract-username-from-arn arn)
                (let ((principal-id (hash-get identity "principalId")))
                  (or principal-id "")))))))))

  ;; Extract readable username from AWS ARN
  ;; arn:aws:iam::123:user/Alice -> Alice
  ;; arn:aws:sts::123:assumed-role/RoleName/session -> RoleName/session
  ;; arn:aws:sts::123:federated-user/UserName -> UserName
  ;; arn:aws:iam::123:root -> root
  (def (extract-username-from-arn arn)
    (let ((parts (string-split arn #\:)))
      (if (< (length parts) 6)
        arn
        (let ((resource (list-ref parts 5)))
          (cond
            ((string-prefix? "user/" resource)
             (substring resource 5 (string-length resource)))
            ((string-prefix? "assumed-role/" resource)
             (substring resource 13 (string-length resource)))
            ((string-prefix? "federated-user/" resource)
             (substring resource 15 (string-length resource)))
            ((string-prefix? "role/" resource)
             (substring resource 5 (string-length resource)))
            (else resource))))))

  ;; Serialize a record back to JSON string
  (def (record->json-string record)
    (json-object->string record))

  ;; Return a copy of the record with responseElements removed
  (def (strip-response-elements record)
    (let ((new-rec (hash-copy record)))
      (hash-remove! new-rec "responseElements")
      new-rec))

) ;; end library
