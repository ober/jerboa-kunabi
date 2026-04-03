;;; (kunabi detection) — Security detection rules and scanning engine
;;;
;;; Detects suspicious activity patterns in CloudTrail logs.
#!chezscheme

(library (kunabi detection)
  (export rule
          make-rule
          rule?
          rule-event-name
          rule-severity
          rule-category
          rule-description
          finding
          make-finding
          finding?
          finding-rule
          finding-record
          finding-event-time-str
          finding-username
          finding-source-ip
          finding-account-id
          finding-region
          finding-details
          security-rules
          scan-all
          scan-by-severity
          scan-by-category
          print-findings
          print-detection-summary
          set-omit-events!
          set-omit-filters!
          current-omit-events
          current-omit-filters)

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

  ;; ---- Rule Data Structures ----

  (define-record-type rule
    (fields event-name severity category description)
    (protocol
      (lambda (new)
        (lambda (event-name severity category description)
          (new event-name severity category description)))))

  (define-record-type finding
    (fields rule record event-time-str username source-ip account-id region details)
    (protocol
      (lambda (new)
        (lambda (rule record event-time-str username source-ip account-id region details)
          (new rule record event-time-str username source-ip account-id region details)))))

  ;; Severity constants
  (define CRITICAL "CRITICAL")
  (define HIGH     "HIGH")
  (define MEDIUM   "MEDIUM")
  (define LOW      "LOW")

  ;; Category constants
  (define cat-persistence    "Persistence/Backdoor")
  (define cat-covering       "Covering Tracks")
  (define cat-exfiltration   "Data Exfiltration")
  (define cat-destruction    "Resource Destruction")
  (define cat-network        "Network/DNS Hijacking")
  (define cat-crypto         "Crypto Mining")
  (define cat-privesc        "Privilege Escalation")

  ;; ---- All Detection Rules ----

  (define security-rules
    (list
      ;; Persistence/Backdoors - CRITICAL
      (make-rule "CreateUser"              CRITICAL cat-persistence "New IAM user created")
      (make-rule "CreateAccessKey"         CRITICAL cat-persistence "New access key created")
      (make-rule "CreateLoginProfile"      CRITICAL cat-persistence "Console login enabled for user")
      (make-rule "AttachUserPolicy"        CRITICAL cat-persistence "Policy attached to user")
      (make-rule "AttachRolePolicy"        CRITICAL cat-persistence "Policy attached to role")
      (make-rule "PutUserPolicy"           CRITICAL cat-persistence "Inline policy added to user")
      (make-rule "PutRolePolicy"           CRITICAL cat-persistence "Inline policy added to role")
      (make-rule "UpdateAssumeRolePolicy"  CRITICAL cat-persistence "Role trust policy modified")
      (make-rule "CreateRole"              HIGH     cat-persistence "New IAM role created")
      (make-rule "CreatePolicyVersion"     HIGH     cat-privesc     "New policy version created")
      (make-rule "SetDefaultPolicyVersion" HIGH     cat-privesc     "Default policy version changed")
      (make-rule "AddUserToGroup"          HIGH     cat-privesc     "User added to group")
      ;; Covering Tracks - CRITICAL
      (make-rule "StopLogging"                      CRITICAL cat-covering "CloudTrail logging stopped")
      (make-rule "DeleteTrail"                      CRITICAL cat-covering "CloudTrail trail deleted")
      (make-rule "UpdateTrail"                      HIGH     cat-covering "CloudTrail trail modified")
      (make-rule "PutEventSelectors"                HIGH     cat-covering "CloudTrail event selectors modified")
      (make-rule "DeleteLogGroup"                   CRITICAL cat-covering "CloudWatch log group deleted")
      (make-rule "DeleteLogStream"                  CRITICAL cat-covering "CloudWatch log stream deleted")
      (make-rule "PutRetentionPolicy"               MEDIUM   cat-covering "Log retention policy changed")
      (make-rule "DeleteDetector"                   CRITICAL cat-covering "GuardDuty detector deleted")
      (make-rule "DisableOrganizationAdminAccount"  CRITICAL cat-covering "GuardDuty org admin disabled")
      (make-rule "StopConfigurationRecorder"        CRITICAL cat-covering "AWS Config recorder stopped")
      (make-rule "DeleteConfigurationRecorder"      CRITICAL cat-covering "AWS Config recorder deleted")
      ;; Data Exfiltration - HIGH
      (make-rule "PutBucketPolicy"             HIGH     cat-exfiltration "S3 bucket policy modified")
      (make-rule "PutBucketAcl"                HIGH     cat-exfiltration "S3 bucket ACL modified")
      (make-rule "PutBucketPublicAccessBlock"  HIGH     cat-exfiltration "S3 public access block modified")
      (make-rule "CreateDBSnapshot"            MEDIUM   cat-exfiltration "RDS snapshot created")
      (make-rule "CopyDBSnapshot"              HIGH     cat-exfiltration "RDS snapshot copied")
      (make-rule "ModifyDBSnapshotAttribute"   CRITICAL cat-exfiltration "RDS snapshot sharing modified")
      (make-rule "ModifySnapshotAttribute"     CRITICAL cat-exfiltration "EC2 snapshot sharing modified")
      (make-rule "ModifyImageAttribute"        HIGH     cat-exfiltration "AMI sharing modified")
      (make-rule "CreateSnapshot"              LOW      cat-exfiltration "EC2 snapshot created")
      ;; Resource Destruction - HIGH
      (make-rule "TerminateInstances"  HIGH     cat-destruction "EC2 instances terminated")
      (make-rule "DeleteVolume"        HIGH     cat-destruction "EBS volume deleted")
      (make-rule "DeleteSnapshot"      HIGH     cat-destruction "EC2 snapshot deleted")
      (make-rule "DeleteDBInstance"    CRITICAL cat-destruction "RDS instance deleted")
      (make-rule "DeleteDBCluster"     CRITICAL cat-destruction "RDS cluster deleted")
      (make-rule "DeleteDBSnapshot"    HIGH     cat-destruction "RDS snapshot deleted")
      (make-rule "DeleteBucket"        CRITICAL cat-destruction "S3 bucket deleted")
      (make-rule "DeleteStack"         HIGH     cat-destruction "CloudFormation stack deleted")
      (make-rule "DeleteFunction"      MEDIUM   cat-destruction "Lambda function deleted")
      ;; Network/DNS Hijacking - HIGH
      (make-rule "ChangeResourceRecordSets"      HIGH   cat-network "Route53 DNS records modified")
      (make-rule "CreateHostedZone"              MEDIUM cat-network "Route53 hosted zone created")
      (make-rule "AuthorizeSecurityGroupIngress" HIGH   cat-network "Security group ingress rule added")
      (make-rule "AuthorizeSecurityGroupEgress"  MEDIUM cat-network "Security group egress rule added")
      (make-rule "CreateVpcPeeringConnection"    HIGH   cat-network "VPC peering connection created")
      (make-rule "AcceptVpcPeeringConnection"    HIGH   cat-network "VPC peering connection accepted")
      (make-rule "CreateVpc"                     MEDIUM cat-network "New VPC created")
      (make-rule "CreateInternetGateway"         MEDIUM cat-network "Internet gateway created")
      (make-rule "AttachInternetGateway"         MEDIUM cat-network "Internet gateway attached")
      ;; Crypto Mining - MEDIUM
      (make-rule "RunInstances"         MEDIUM cat-crypto "EC2 instances launched")
      (make-rule "RunTask"              MEDIUM cat-crypto "ECS task started")
      (make-rule "CreateService"        MEDIUM cat-crypto "ECS service created")
      (make-rule "CreateFunction"       MEDIUM cat-crypto "Lambda function created")
      (make-rule "UpdateFunctionCode"   MEDIUM cat-crypto "Lambda function code updated")))

  ;; ---- Pre-indexed Lookup Tables ----

  (define rules-by-event-name (make-hash-table))
  (define rules-by-severity (make-hash-table))
  (define rules-by-category (make-hash-table))

  ;; ---- Omit Configuration ----

  (define current-omit-events (make-parameter (make-hash-table)))
  (define current-omit-filters (make-parameter '()))

  (def (set-omit-events! events)
    (let ((ht (make-hash-table)))
      (for-each (lambda (e) (hash-put! ht e #t)) events)
      (current-omit-events ht)))

  (def (set-omit-filters! filters)
    (current-omit-filters filters))

  ;; Find position of needle in haystack
  (def (str-find haystack needle)
    (let ((hlen (string-length haystack))
          (nlen (string-length needle)))
      (if (> nlen hlen) -1
        (let loop ((i 0))
          (cond
            ((> (+ i nlen) hlen) -1)
            ((string=? (substring haystack i (+ i nlen)) needle) i)
            (else (loop (+ i 1))))))))

  ;; Wildcard matching: supports * for glob patterns
  (def (match-wildcard pattern str)
    (cond
      ((equal? pattern "*") #t)
      ((equal? pattern "") (equal? str ""))
      ((not (string-contains pattern "*")) (equal? pattern str))
      (else
        (let ((parts (string-split pattern #\*)))
          (cond
            ((= (length parts) 2)
             (let ((pfx (car parts))
                   (sfx (cadr parts)))
               (cond
                 ((equal? pfx "") (string-suffix? sfx str))
                 ((equal? sfx "") (string-prefix? pfx str))
                 (else (and (string-prefix? pfx str)
                            (string-suffix? sfx str))))))
            (else
              ;; Complex patterns: check all parts appear in order
              (let loop ((parts parts) (pos 0) (first? #t))
                (cond
                  ((null? parts) #t)
                  ((equal? (car parts) "") (loop (cdr parts) pos #f))
                  (else
                    (let ((idx (str-find (substring str pos (string-length str))
                                            (car parts))))
                      (cond
                        ((< idx 0) #f)
                        ((and first? (> idx 0)) #f)
                        (else
                         (loop (cdr parts)
                               (+ pos idx (string-length (car parts)))
                               #f)))))))))))))

  ;; Filter rules excluding omitted events
  (def (filter-omitted-rules rules)
    (if (zero? (hash-length (current-omit-events)))
      rules
      (filter (lambda (r) (not (hash-key? (current-omit-events) (rule-event-name r)))) rules)))

  ;; Filter findings excluding omitted user+event combinations
  (def (filter-omitted-findings findings)
    (if (null? (current-omit-filters))
      findings
      (filter
        (lambda (f)
          (not (any (lambda (flt)
                      (and (equal? (ht-ref flt "event") (rule-event-name (finding-rule f)))
                           (match-wildcard (or (ht-ref flt "user") "") (finding-username f))))
                    (current-omit-filters))))
        findings)))

  ;; Helper for hash/hashtable ref
  (def (ht-ref ht key)
    (cond
      ((hashtable? ht)
       (guard (e [#t #f])
         (hashtable-ref ht key #f)))
      (else
       (hash-get ht key))))

  ;; ---- Scanning Engine ----

  (define severity-order
    (let ((ht (make-hash-table)))
      (hash-put! ht "CRITICAL" 0)
      (hash-put! ht "HIGH" 1)
      (hash-put! ht "MEDIUM" 2)
      (hash-put! ht "LOW" 3)
      ht))

  (def (severity-rank sev)
    (or (hash-get severity-order sev) 4))

  ;; Scan for a single event rule
  (def (scan-for-event r (read-opts #f))
    (let* ((prefix (format "idx:event:~a:" (rule-event-name r)))
           (entries (scan-prefix prefix read-opts))
           (event-ids (map cdr entries)))
      (if (null? event-ids)
        '()
        (let ((records (get-batch event-ids read-opts)))
          (filter-map
            (lambda (eid)
              (let ((record (hash-get records eid)))
                (when record
                  (make-finding r record
                    (get-event-time record)
                    (get-username record)
                    (get-source-ip record)
                    (get-recipient-account-id record)
                    (get-aws-region record)
                    (extract-details record)))))
            event-ids)))))

  ;; Extract relevant details from request parameters
  (def (extract-details record)
    (let ((params (get-request-parameters record))
          (details '()))
      (when (and params (hashtable? params))
        (let ((try-add (lambda (key label)
                         (let ((v (ht-ref params key)))
                           (when (string? v)
                             (set! details (cons (format "~a=~a" label v) details)))))))
          (try-add "userName" "userName")
          (try-add "roleName" "roleName")
          (try-add "policyArn" "policyArn")
          (try-add "bucketName" "bucket")
          (try-add "instanceType" "instanceType")
          (try-add "groupId" "securityGroup")
          (try-add "hostedZoneId" "hostedZone")
          (try-add "functionName" "function")
          (try-add "dBInstanceIdentifier" "dbInstance")
          (when (null? details)
            (let ((v (ht-ref params "name")))
              (when (string? v)
                (set! details (cons (format "name=~a" v) details)))))))
      (let ((ec (get-error-code record)))
        (when (not (equal? ec ""))
          (set! details (cons (format "error=~a" ec) details))))
      (string-join (reverse details) ", ")))

  ;; Scan all rules (sequential for now - can be parallelized)
  (def (scan-all)
    (let* ((rules (filter-omitted-rules security-rules))
           (findings (apply append (map scan-for-event rules))))
      (sort (filter-omitted-findings findings)
            (lambda (a b)
              (let ((sa (severity-rank (rule-severity (finding-rule a))))
                    (sb (severity-rank (rule-severity (finding-rule b)))))
                (if (= sa sb)
                  (string>? (finding-event-time-str a) (finding-event-time-str b))
                  (< sa sb)))))))

  ;; Scan by minimum severity
  (def (scan-by-severity min-severity)
    (let* ((min-rank (severity-rank min-severity))
           (rules (filter (lambda (r)
                            (<= (severity-rank (rule-severity r)) min-rank))
                          (filter-omitted-rules security-rules)))
           (findings (apply append (map scan-for-event rules))))
      (sort (filter-omitted-findings findings)
            (lambda (a b)
              (let ((sa (severity-rank (rule-severity (finding-rule a))))
                    (sb (severity-rank (rule-severity (finding-rule b)))))
                (if (= sa sb)
                  (string>? (finding-event-time-str a) (finding-event-time-str b))
                  (< sa sb)))))))

  ;; Scan by category
  (def (scan-by-category category)
    (let* ((rules (filter (lambda (r) (equal? (rule-category r) category))
                          (filter-omitted-rules security-rules)))
           (findings (apply append (map scan-for-event rules))))
      (sort (filter-omitted-findings findings)
            (lambda (a b)
              (string>? (finding-event-time-str a) (finding-event-time-str b))))))

  ;; ---- Output Formatting ----

  (def (pad-right str width)
    (let ((len (string-length str)))
      (if (>= len width)
        str
        (string-append str (make-string (- width len) #\space)))))

  (def (take-at-most lst n)
    (if (<= (length lst) n) lst (take lst n)))

  (def (print-findings findings)
    (if (null? findings)
      (displayln "No suspicious activity detected.")
      (begin
        (displayln (format "Found ~a suspicious events:\n" (length findings)))
        ;; Group by severity
        (for-each
          (lambda (sev)
            (let ((sev-findings (filter (lambda (f) (equal? (rule-severity (finding-rule f)) sev))
                                        findings)))
              (unless (null? sev-findings)
                (displayln (format "=== ~a (~a) ===" sev (length sev-findings)))
                (for-each
                  (lambda (f)
                    (let ((r (finding-rule f)))
                      (displayln (format "\n[~a] ~a" (rule-category r) (rule-event-name r)))
                      (displayln (format "  Description: ~a" (rule-description r)))
                      (displayln (format "  Time:        ~a" (finding-event-time-str f)))
                      (displayln (format "  User:        ~a" (finding-username f)))
                      (displayln (format "  Source IP:   ~a" (finding-source-ip f)))
                      (displayln (format "  Account:     ~a" (finding-account-id f)))
                      (displayln (format "  Region:      ~a" (finding-region f)))
                      (when (not (equal? (finding-details f) ""))
                        (displayln (format "  Details:     ~a" (finding-details f))))
                      (let ((ec (get-error-code (finding-record f))))
                        (if (not (equal? ec ""))
                          (displayln (format "  Status:      FAILED (~a)" ec))
                          (displayln "  Status:      SUCCESS")))))
                  sev-findings)
                (newline))))
          (list CRITICAL HIGH MEDIUM LOW)))))

  (def (print-detection-summary findings)
    (if (null? findings)
      (displayln "No suspicious activity detected.")
      (begin
        (let ((by-severity (make-hash-table))
              (by-category (make-hash-table))
              (by-event (make-hash-table))
              (by-user (make-hash-table)))
          (for-each
            (lambda (f)
              (let ((r (finding-rule f)))
                (hash-update! by-severity (rule-severity r) (lambda (n) (+ n 1)) 0)
                (hash-update! by-category (rule-category r) (lambda (n) (+ n 1)) 0)
                (hash-update! by-event (rule-event-name r) (lambda (n) (+ n 1)) 0)
                (when (not (equal? (finding-username f) ""))
                  (hash-update! by-user (finding-username f) (lambda (n) (+ n 1)) 0))))
            findings)

          (displayln (format "Detection Summary: ~a suspicious events\n" (length findings)))

          (displayln "By Severity:")
          (for-each
            (lambda (sev)
              (let ((count (hash-get by-severity sev)))
                (when (and count (> count 0))
                  (displayln (format "  ~a ~a" (pad-right sev 10) count)))))
            (list CRITICAL HIGH MEDIUM LOW))

          (displayln "\nBy Category:")
          (let ((cats (sort (hash->list by-category) (lambda (a b) (> (cdr a) (cdr b))))))
            (for-each (lambda (p) (displayln (format "  ~a ~a" (pad-right (car p) 25) (cdr p)))) cats))

          (displayln "\nTop Events:")
          (let ((events (take-at-most
                          (sort (hash->list by-event) (lambda (a b) (> (cdr a) (cdr b))))
                          10)))
            (for-each (lambda (p) (displayln (format "  ~a ~a" (pad-right (car p) 35) (cdr p)))) events))

          (when (> (hash-length by-user) 0)
            (displayln "\nTop Users:")
            (let ((users (take-at-most
                           (sort (hash->list by-user) (lambda (a b) (> (cdr a) (cdr b))))
                           10)))
              (for-each (lambda (p) (displayln (format "  ~a ~a" (pad-right (car p) 35) (cdr p)))) users)))))))

  ;; Initialize lookup tables (top-level expressions must come after all definitions)
  (for-each
    (lambda (r)
      (hash-put! rules-by-event-name (rule-event-name r) r)
      (hash-update! rules-by-severity (rule-severity r)
                    (lambda (lst) (cons r lst)) '())
      (hash-update! rules-by-category (rule-category r)
                    (lambda (lst) (cons r lst)) '()))
    security-rules)

) ;; end library
