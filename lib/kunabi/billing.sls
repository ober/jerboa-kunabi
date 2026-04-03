;;; (kunabi billing) — Billing impact detection rules and scanning engine
;;;
;;; Detects operations that affect AWS billing (cost increases/decreases).
#!chezscheme

(library (kunabi billing)
  (export billing-rule
          make-billing-rule
          billing-rule?
          billing-rule-event-name
          billing-rule-impact
          billing-rule-service
          billing-rule-description
          billing-finding
          make-billing-finding
          billing-finding?
          billing-finding-rule
          billing-finding-record
          billing-finding-event-time-str
          billing-finding-username
          billing-finding-source-ip
          billing-finding-account-id
          billing-finding-region
          billing-finding-details
          billing-rules
          scan-billing
          scan-billing-by-impact
          scan-billing-by-service
          print-billing-findings
          print-billing-summary)

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

  ;; ---- Data Structures ----

  (define-record-type billing-rule
    (fields event-name impact service description)
    (protocol
      (lambda (new)
        (lambda (event-name impact service description)
          (new event-name impact service description)))))

  (define-record-type billing-finding
    (fields rule record event-time-str username source-ip account-id region details)
    (protocol
      (lambda (new)
        (lambda (rule record event-time-str username source-ip account-id region details)
          (new rule record event-time-str username source-ip account-id region details)))))

  ;; Impact constants
  (define cost-increase "Cost Increase")
  (define cost-decrease "Cost Decrease")
  (define cost-change   "Cost Change")

  ;; ---- All Billing Rules ----

  (define billing-rules
    (list
      ;; EC2 - Instance lifecycle
      (make-billing-rule "RunInstances"            cost-increase "EC2" "EC2 instances launched")
      (make-billing-rule "StartInstances"          cost-increase "EC2" "EC2 instances started")
      (make-billing-rule "StopInstances"           cost-decrease "EC2" "EC2 instances stopped")
      (make-billing-rule "TerminateInstances"      cost-decrease "EC2" "EC2 instances terminated")
      (make-billing-rule "ModifyInstanceAttribute" cost-change   "EC2" "EC2 instance attribute modified")
      ;; EBS
      (make-billing-rule "CreateVolume"   cost-increase "EBS" "EBS volume created")
      (make-billing-rule "DeleteVolume"   cost-decrease "EBS" "EBS volume deleted")
      (make-billing-rule "ModifyVolume"   cost-change   "EBS" "EBS volume modified")
      (make-billing-rule "CreateSnapshot" cost-increase "EBS" "EBS snapshot created")
      (make-billing-rule "CopySnapshot"   cost-increase "EBS" "EBS snapshot copied")
      (make-billing-rule "DeleteSnapshot" cost-decrease "EBS" "EBS snapshot deleted")
      ;; EC2 - Reserved/Savings
      (make-billing-rule "PurchaseReservedInstancesOffering" cost-change "EC2" "Reserved instances purchased")
      (make-billing-rule "CreateSavingsPlan" cost-change "SavingsPlans" "Savings plan created")
      ;; RDS
      (make-billing-rule "CreateDBInstance" cost-increase "RDS" "RDS instance created")
      (make-billing-rule "DeleteDBInstance" cost-decrease "RDS" "RDS instance deleted")
      (make-billing-rule "StartDBInstance"  cost-increase "RDS" "RDS instance started")
      (make-billing-rule "StopDBInstance"   cost-decrease "RDS" "RDS instance stopped")
      (make-billing-rule "ModifyDBInstance" cost-change   "RDS" "RDS instance modified")
      (make-billing-rule "CreateDBCluster"  cost-increase "RDS" "RDS cluster created")
      (make-billing-rule "DeleteDBCluster"  cost-decrease "RDS" "RDS cluster deleted")
      (make-billing-rule "CreateDBSnapshot" cost-increase "RDS" "RDS snapshot created")
      (make-billing-rule "DeleteDBSnapshot" cost-decrease "RDS" "RDS snapshot deleted")
      ;; S3
      (make-billing-rule "CreateBucket"              cost-increase "S3" "S3 bucket created")
      (make-billing-rule "DeleteBucket"              cost-decrease "S3" "S3 bucket deleted")
      (make-billing-rule "PutBucketVersioning"       cost-change   "S3" "S3 versioning changed")
      (make-billing-rule "PutLifecycleConfiguration" cost-change   "S3" "S3 lifecycle policy changed")
      (make-billing-rule "PutBucketReplication"      cost-increase "S3" "S3 replication enabled")
      ;; Lambda
      (make-billing-rule "CreateFunction20150331"                  cost-increase "Lambda" "Lambda function created")
      (make-billing-rule "CreateFunction"                          cost-increase "Lambda" "Lambda function created")
      (make-billing-rule "DeleteFunction20150331"                  cost-decrease "Lambda" "Lambda function deleted")
      (make-billing-rule "DeleteFunction"                          cost-decrease "Lambda" "Lambda function deleted")
      (make-billing-rule "UpdateFunctionConfiguration20150331v2"   cost-change   "Lambda" "Lambda config updated")
      (make-billing-rule "UpdateFunctionConfiguration"             cost-change   "Lambda" "Lambda config updated")
      (make-billing-rule "PutProvisionedConcurrencyConfig"         cost-increase "Lambda" "Lambda provisioned concurrency configured")
      (make-billing-rule "DeleteProvisionedConcurrencyConfig"      cost-decrease "Lambda" "Lambda provisioned concurrency removed")
      ;; ECS/Fargate
      (make-billing-rule "CreateCluster" cost-increase "ECS" "ECS cluster created")
      (make-billing-rule "DeleteCluster" cost-decrease "ECS" "ECS cluster deleted")
      (make-billing-rule "CreateService" cost-increase "ECS" "ECS service created")
      (make-billing-rule "DeleteService" cost-decrease "ECS" "ECS service deleted")
      (make-billing-rule "UpdateService" cost-change   "ECS" "ECS service updated")
      (make-billing-rule "RunTask"       cost-increase "ECS" "ECS task launched")
      ;; EKS
      (make-billing-rule "CreateCluster"         cost-increase "EKS" "EKS cluster created")
      (make-billing-rule "DeleteCluster"         cost-decrease "EKS" "EKS cluster deleted")
      (make-billing-rule "CreateNodegroup"       cost-increase "EKS" "EKS node group created")
      (make-billing-rule "DeleteNodegroup"       cost-decrease "EKS" "EKS node group deleted")
      (make-billing-rule "UpdateNodegroupConfig" cost-change   "EKS" "EKS node group config updated")
      ;; ElastiCache
      (make-billing-rule "CreateCacheCluster"     cost-increase "ElastiCache" "ElastiCache cluster created")
      (make-billing-rule "DeleteCacheCluster"     cost-decrease "ElastiCache" "ElastiCache cluster deleted")
      (make-billing-rule "ModifyCacheCluster"     cost-change   "ElastiCache" "ElastiCache cluster modified")
      (make-billing-rule "CreateReplicationGroup" cost-increase "ElastiCache" "ElastiCache replication group created")
      (make-billing-rule "DeleteReplicationGroup" cost-decrease "ElastiCache" "ElastiCache replication group deleted")
      ;; DynamoDB
      (make-billing-rule "CreateTable"       cost-increase "DynamoDB" "DynamoDB table created")
      (make-billing-rule "DeleteTable"       cost-decrease "DynamoDB" "DynamoDB table deleted")
      (make-billing-rule "UpdateTable"       cost-change   "DynamoDB" "DynamoDB table updated")
      (make-billing-rule "CreateGlobalTable" cost-increase "DynamoDB" "DynamoDB global table created")
      ;; Redshift
      (make-billing-rule "CreateCluster"  cost-increase "Redshift" "Redshift cluster created")
      (make-billing-rule "DeleteCluster"  cost-decrease "Redshift" "Redshift cluster deleted")
      (make-billing-rule "ResizeCluster"  cost-change   "Redshift" "Redshift cluster resized")
      (make-billing-rule "PauseCluster"   cost-decrease "Redshift" "Redshift cluster paused")
      (make-billing-rule "ResumeCluster"  cost-increase "Redshift" "Redshift cluster resumed")
      ;; VPC / Networking
      (make-billing-rule "CreateNatGateway"      cost-increase "VPC" "NAT Gateway created")
      (make-billing-rule "DeleteNatGateway"      cost-decrease "VPC" "NAT Gateway deleted")
      (make-billing-rule "AllocateAddress"       cost-increase "EC2" "Elastic IP allocated")
      (make-billing-rule "ReleaseAddress"        cost-decrease "EC2" "Elastic IP released")
      (make-billing-rule "CreateVpnConnection"   cost-increase "VPC" "VPN connection created")
      (make-billing-rule "DeleteVpnConnection"   cost-decrease "VPC" "VPN connection deleted")
      (make-billing-rule "CreateTransitGateway"  cost-increase "VPC" "Transit Gateway created")
      (make-billing-rule "DeleteTransitGateway"  cost-decrease "VPC" "Transit Gateway deleted")
      ;; Load Balancers
      (make-billing-rule "CreateLoadBalancer" cost-increase "ELB" "Load balancer created")
      (make-billing-rule "DeleteLoadBalancer" cost-decrease "ELB" "Load balancer deleted")
      ;; CloudFront
      (make-billing-rule "CreateDistribution" cost-increase "CloudFront" "CloudFront distribution created")
      (make-billing-rule "DeleteDistribution" cost-decrease "CloudFront" "CloudFront distribution deleted")
      ;; OpenSearch
      (make-billing-rule "CreateDomain"       cost-increase "OpenSearch" "OpenSearch domain created")
      (make-billing-rule "DeleteDomain"       cost-decrease "OpenSearch" "OpenSearch domain deleted")
      (make-billing-rule "UpdateDomainConfig" cost-change   "OpenSearch" "OpenSearch domain config updated")
      ;; Kinesis
      (make-billing-rule "CreateStream"         cost-increase "Kinesis"  "Kinesis stream created")
      (make-billing-rule "DeleteStream"         cost-decrease "Kinesis"  "Kinesis stream deleted")
      (make-billing-rule "UpdateShardCount"     cost-change   "Kinesis"  "Kinesis shard count updated")
      (make-billing-rule "CreateDeliveryStream" cost-increase "Firehose" "Firehose delivery stream created")
      (make-billing-rule "DeleteDeliveryStream" cost-decrease "Firehose" "Firehose delivery stream deleted")
      ;; SageMaker
      (make-billing-rule "CreateNotebookInstance" cost-increase "SageMaker" "SageMaker notebook created")
      (make-billing-rule "DeleteNotebookInstance" cost-decrease "SageMaker" "SageMaker notebook deleted")
      (make-billing-rule "StartNotebookInstance"  cost-increase "SageMaker" "SageMaker notebook started")
      (make-billing-rule "StopNotebookInstance"   cost-decrease "SageMaker" "SageMaker notebook stopped")
      (make-billing-rule "CreateEndpoint"         cost-increase "SageMaker" "SageMaker endpoint created")
      (make-billing-rule "DeleteEndpoint"         cost-decrease "SageMaker" "SageMaker endpoint deleted")
      ;; CloudWatch
      (make-billing-rule "PutMetricAlarm"   cost-increase "CloudWatch" "CloudWatch alarm created/updated")
      (make-billing-rule "DeleteAlarms"     cost-decrease "CloudWatch" "CloudWatch alarm deleted")
      (make-billing-rule "PutDashboard"     cost-increase "CloudWatch" "CloudWatch dashboard created")
      (make-billing-rule "DeleteDashboards" cost-decrease "CloudWatch" "CloudWatch dashboard deleted")
      ;; Secrets Manager
      (make-billing-rule "CreateSecret" cost-increase "SecretsManager" "Secret created")
      (make-billing-rule "DeleteSecret" cost-decrease "SecretsManager" "Secret deleted")))

  ;; Pre-indexed lookup tables
  (define billing-rules-by-event (make-hash-table))
  (define billing-rules-by-service (make-hash-table))
  (define billing-rules-by-impact (make-hash-table))

  ;; ---- Scanning ----

  ;; Deduplicate rules by event name (some events appear under multiple services)
  (def (dedup-rules rules)
    (let ((seen (make-hash-table))
          (result '()))
      (for-each
        (lambda (r)
          (unless (hash-key? seen (billing-rule-event-name r))
            (hash-put! seen (billing-rule-event-name r) #t)
            (set! result (cons r result))))
        rules)
      (reverse result)))

  (def (scan-billing)
    (scan-billing-rules billing-rules))

  (def (scan-billing-by-impact impact)
    (let ((rules (or (hash-get billing-rules-by-impact impact) '())))
      (scan-billing-rules rules)))

  (def (scan-billing-by-service service)
    (let ((rules (or (hash-get billing-rules-by-service service) '())))
      (scan-billing-rules rules)))

  (def (scan-billing-rules rules)
    (let* ((unique-rules (dedup-rules rules))
           (findings (apply append (map scan-for-billing-event unique-rules))))
      (sort findings
            (lambda (a b)
              (string>? (billing-finding-event-time-str a)
                        (billing-finding-event-time-str b))))))

  (def (scan-for-billing-event r (read-opts #f))
    (let* ((prefix (format "idx:event:~a:" (billing-rule-event-name r)))
           (entries (scan-prefix prefix read-opts))
           (event-ids (map cdr entries)))
      (if (null? event-ids)
        '()
        (let ((records (get-batch event-ids read-opts)))
          (filter-map
            (lambda (eid)
              (let ((record (hash-get records eid)))
                (and record
                     ;; Skip failed events - no billing impact
                     (let ((ec (get-error-code record)))
                       (and (equal? ec "")
                            (make-billing-finding r record
                              (get-event-time record)
                              (get-username record)
                              (get-source-ip record)
                              (get-recipient-account-id record)
                              (get-aws-region record)
                              (extract-billing-details record)))))))
            event-ids)))))

  ;; Helper for hash/hashtable ref
  (def (ht-ref ht key)
    (cond
      ((hashtable? ht)
       (guard (e [#t #f])
         (hashtable-ref ht key #f)))
      (else
       (hash-get ht key))))

  ;; Extract billing-relevant details from request parameters
  (def (extract-billing-details record)
    (let ((params (get-request-parameters record))
          (details '()))
      (when (and params (hashtable? params))
        (let ((try-add (lambda (key label)
                         (let ((v (ht-ref params key)))
                           (cond
                             ((string? v)
                              (set! details (cons (format "~a=~a" label v) details)))
                             ((number? v)
                              (set! details (cons (format "~a=~a" label v) details))))))))
          (try-add "instanceType" "instanceType")
          (try-add "volumeType" "volumeType")
          (try-add "size" "size")
          (try-add "dBInstanceClass" "dbClass")
          (try-add "dBInstanceIdentifier" "dbInstance")
          (try-add "allocatedStorage" "storage")
          (try-add "bucketName" "bucket")
          (try-add "functionName" "function")
          (try-add "memorySize" "memory")
          (try-add "serviceName" "service")
          (try-add "desiredCount" "desiredCount")
          (try-add "clusterName" "cluster")
          (when (null? details)
            (try-add "name" "name"))))
      (string-join (reverse details) ", ")))

  ;; ---- Output Formatting ----

  (def (pad-right str width)
    (let ((len (string-length str)))
      (if (>= len width)
        str
        (string-append str (make-string (- width len) #\space)))))

  (def (take-at-most lst n)
    (if (<= (length lst) n) lst (take lst n)))

  (def (print-billing-findings findings)
    (if (null? findings)
      (displayln "No billing-impacting events detected.")
      (begin
        (displayln (format "Found ~a billing-impacting events:\n" (length findings)))
        (for-each
          (lambda (impact)
            (let ((impact-findings (filter (lambda (f) (equal? (billing-rule-impact (billing-finding-rule f)) impact))
                                          findings)))
              (unless (null? impact-findings)
                (displayln (format "=== ~a (~a) ===" impact (length impact-findings)))
                (for-each
                  (lambda (f)
                    (let ((r (billing-finding-rule f)))
                      (displayln (format "\n[~a] ~a" (billing-rule-service r) (billing-rule-event-name r)))
                      (displayln (format "  Description: ~a" (billing-rule-description r)))
                      (displayln (format "  Time:        ~a" (billing-finding-event-time-str f)))
                      (displayln (format "  User:        ~a" (billing-finding-username f)))
                      (displayln (format "  Account:     ~a" (billing-finding-account-id f)))
                      (displayln (format "  Region:      ~a" (billing-finding-region f)))
                      (when (not (equal? (billing-finding-details f) ""))
                        (displayln (format "  Details:     ~a" (billing-finding-details f))))))
                  impact-findings)
                (newline))))
          (list cost-increase cost-decrease cost-change)))))

  (def (print-billing-summary findings)
    (if (null? findings)
      (displayln "No billing-impacting events detected.")
      (let ((by-impact  (make-hash-table))
            (by-service (make-hash-table))
            (by-event   (make-hash-table))
            (by-user    (make-hash-table)))
        (for-each
          (lambda (f)
            (let ((r (billing-finding-rule f)))
              (hash-update! by-impact  (billing-rule-impact r) (lambda (n) (+ n 1)) 0)
              (hash-update! by-service (billing-rule-service r) (lambda (n) (+ n 1)) 0)
              (hash-update! by-event   (billing-rule-event-name r) (lambda (n) (+ n 1)) 0)
              (when (not (equal? (billing-finding-username f) ""))
                (hash-update! by-user (billing-finding-username f) (lambda (n) (+ n 1)) 0))))
          findings)

        (displayln (format "Billing Impact Summary: ~a events\n" (length findings)))

        (displayln "By Impact Type:")
        (for-each
          (lambda (impact)
            (let ((count (hash-get by-impact impact)))
              (when (and count (> count 0))
                (displayln (format "  ~a ~a" (pad-right impact 15) count)))))
          (list cost-increase cost-decrease cost-change))

        (displayln "\nBy Service:")
        (let ((services (sort (hash->list by-service) (lambda (a b) (> (cdr a) (cdr b))))))
          (for-each (lambda (p) (displayln (format "  ~a ~a" (pad-right (car p) 20) (cdr p)))) services))

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
            (for-each (lambda (p) (displayln (format "  ~a ~a" (pad-right (car p) 35) (cdr p)))) users))))))

  ;; Initialize lookup tables (must come after all definitions)
  (for-each
    (lambda (r)
      (hash-update! billing-rules-by-event (billing-rule-event-name r)
                    (lambda (lst) (cons r lst)) '())
      (hash-update! billing-rules-by-service (billing-rule-service r)
                    (lambda (lst) (cons r lst)) '())
      (hash-update! billing-rules-by-impact (billing-rule-impact r)
                    (lambda (lst) (cons r lst)) '()))
    billing-rules)

) ;; end library
