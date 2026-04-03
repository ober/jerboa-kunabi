#!chezscheme
;;; build-static-artifacts.ss — Generate C headers with embedded boot/program data
;;;
;;; Run after build-kunabi.ss to regenerate WPO + boot + C headers for static linking.
;;; Usage: CHEZ_DIR=... scheme -q --libdirs ... < build-static-artifacts.ss

(import (chezscheme))

;; --- Helper: generate C header from binary file ---
(define (file->c-header input-path output-path array-name size-name)
  (let* ((port (open-file-input-port input-path))
         (data (get-bytevector-all port))
         (size (bytevector-length data)))
    (close-port port)
    (call-with-output-file output-path
      (lambda (out)
        (fprintf out "/* Auto-generated */~n")
        (fprintf out "static const unsigned char ~a[] = {~n" array-name)
        (let loop ((i 0))
          (when (< i size)
            (when (= 0 (modulo i 16)) (fprintf out "  "))
            (fprintf out "0x~2,'0x" (bytevector-u8-ref data i))
            (when (< (+ i 1) size) (fprintf out ","))
            (when (= 15 (modulo i 16)) (fprintf out "~n"))
            (loop (+ i 1))))
        (fprintf out "~n};~n")
        (fprintf out "static const unsigned int ~a = ~a;~n" size-name size))
      'replace)
    (printf "  ~a: ~a bytes~n" output-path size)))

(define (existing-files paths) (filter file-exists? paths))

(define home (getenv "HOME"))
(define chez-dir (or (getenv "CHEZ_DIR")
                     (error 'build "CHEZ_DIR not set")))
(define jerboa-dir (or (getenv "JERBOA_DIR") (format "~a/mine/jerboa/lib" home)))
(define jerboa-aws-dir (or (getenv "JERBOA_AWS_DIR") (format "~a/mine/jerboa-aws/lib" home)))
(define chez-leveldb-dir (or (getenv "CHEZ_LEVELDB_DIR") (format "~a/mine/chez-leveldb" home)))
(define chez-yaml-dir (or (getenv "CHEZ_YAML_DIR") (format "~a/mine/chez-yaml" home)))
(define chez-zlib-dir (or (getenv "CHEZ_ZLIB_DIR") (format "~a/mine/chez-zlib/src" home)))
(define chez-https-dir (or (getenv "CHEZ_HTTPS_DIR") (format "~a/mine/chez-https/src" home)))
(define chez-ssl-dir (or (getenv "CHEZ_SSL_DIR") (format "~a/mine/chez-ssl/src" home)))
(define gherkin-dir (or (getenv "GHERKIN_DIR") (format "~a/mine/gherkin/src" home)))

;; ========== Step 0: Stage FFI libraries with load-shared-object patched out ==========
;; In a static binary, dlopen doesn't work. FFI symbols are registered via
;; Sforeign_symbol in kunabi-main-static.c instead. We patch (load-shared-object ...)
;; to (void) so the compiled .so files don't try to dlopen at load time.

(printf "[0/5] Staging FFI libraries for static build...~n")

(define ssl-stage (format "~a/ssl-stage" (current-directory)))
(define zlib-stage (format "~a/zlib-stage" (current-directory)))
(define leveldb-stage (format "~a/leveldb-stage" (current-directory)))
(define yaml-stage (format "~a/yaml-stage" (current-directory)))
(define aws-stage (format "~a/aws-stage" (current-directory)))

;; chez-ssl: patch load-shared-object
(system (format "rm -rf '~a' && mkdir -p '~a'" ssl-stage ssl-stage))
(system (format "cp '~a/chez-ssl.sls' '~a/chez-ssl.sls'" chez-ssl-dir ssl-stage))
(system (format "sed -i 's/(load-shared-object[^)]*)/(void)/g' '~a/chez-ssl.sls'" ssl-stage))
;; chez-https: copy (imports chez-ssl)
(system (format "cp '~a/chez-https.sls' '~a/chez-https.sls'" chez-https-dir ssl-stage))

;; chez-zlib: patch load-shared-object
(system (format "rm -rf '~a' && mkdir -p '~a'" zlib-stage zlib-stage))
(system (format "cp '~a/chez-zlib.sls' '~a/chez-zlib.sls'" chez-zlib-dir zlib-stage))
(system (format "sed -i 's/(load-shared-object[^)]*)/(void)/g' '~a/chez-zlib.sls'" zlib-stage))

;; chez-leveldb: patch load-shared-object
(system (format "rm -rf '~a' && mkdir -p '~a'" leveldb-stage leveldb-stage))
(let ([src-ss (format "~a/leveldb.ss" chez-leveldb-dir)]
      [src-sls (format "~a/leveldb.sls" chez-leveldb-dir)])
  (cond
    [(file-exists? src-ss)
     (system (format "cp '~a' '~a/leveldb.sls'" src-ss leveldb-stage))
     (system (format "sed -i 's/(load-shared-object[^)]*)/(void)/g' '~a/leveldb.sls'" leveldb-stage))]
    [(file-exists? src-sls)
     (system (format "cp '~a' '~a/leveldb.sls'" src-sls leveldb-stage))
     (system (format "sed -i 's/(load-shared-object[^)]*)/(void)/g' '~a/leveldb.sls'" leveldb-stage))]
    [else
     (printf "Warning: leveldb library not found at ~a~n" chez-leveldb-dir)]))

;; chez-yaml: copy
(system (format "rm -rf '~a' && mkdir -p '~a'" yaml-stage yaml-stage))
(when (file-exists? (format "~a/yaml.sls" chez-yaml-dir))
  (system (format "cp '~a/yaml.sls' '~a/yaml.sls'" chez-yaml-dir yaml-stage)))

;; jerboa-aws: copy entire tree
(system (format "rm -rf '~a' && mkdir -p '~a'" aws-stage aws-stage))
(system (format "cp -a '~a/jerboa-aws' '~a/'" jerboa-aws-dir aws-stage))
(system (format "find '~a/jerboa-aws' -name '*.so' -delete" aws-stage))
(system (format "find '~a/jerboa-aws' -name '*.wpo' -delete" aws-stage))

;; Compile staged modules
(printf "  Compiling staged FFI modules...~n")
(parameterize ([optimize-level 2]
               [generate-inspector-information #f]
               [compile-imported-libraries #t]
               [library-directories
                 (cons* (cons ssl-stage ssl-stage)
                        (cons zlib-stage zlib-stage)
                        (cons leveldb-stage leveldb-stage)
                        (cons yaml-stage yaml-stage)
                        (cons aws-stage aws-stage)
                        (library-directories))])
  (printf "    chez-ssl...~n")
  (compile-library (format "~a/chez-ssl.sls" ssl-stage))
  (printf "    chez-https...~n")
  (compile-library (format "~a/chez-https.sls" ssl-stage))
  (printf "    chez-zlib...~n")
  (compile-library (format "~a/chez-zlib.sls" zlib-stage))
  (printf "    chez-leveldb...~n")
  (compile-library (format "~a/leveldb.sls" leveldb-stage))
  (when (file-exists? (format "~a/yaml.sls" yaml-stage))
    (printf "    chez-yaml...~n")
    (compile-library (format "~a/yaml.sls" yaml-stage)))
  (printf "    jerboa-aws...~n")
  (for-each
    (lambda (f)
      (let ([path (format "~a/jerboa-aws/~a.sls" aws-stage f)])
        (when (file-exists? path) (compile-library path))))
    '("json" "xml" "uri" "time" "crypto" "creds" "sigv4"
      "request" "api" "json-api"
      "s3/xml" "s3/api" "s3/buckets" "s3/objects"
      "sts/api" "sts/operations")))

;; Recompile kunabi modules against staged libraries
(printf "  Recompiling kunabi modules...~n")
(parameterize ([optimize-level 2]
               [generate-inspector-information #f]
               [compile-imported-libraries #t]
               [generate-wpo-files #t]
               [library-directories
                 (cons* (cons ssl-stage ssl-stage)
                        (cons zlib-stage zlib-stage)
                        (cons leveldb-stage leveldb-stage)
                        (cons yaml-stage yaml-stage)
                        (cons aws-stage aws-stage)
                        (library-directories))])
  (for-each compile-library
    '("lib/kunabi/config.sls"
      "lib/kunabi/parser.sls"
      "lib/kunabi/storage.sls"
      "lib/kunabi/loader.sls"
      "lib/kunabi/query.sls"
      "lib/kunabi/detection.sls"
      "lib/kunabi/billing.sls")))

;; Step 1: Recompile program with WPO
(printf "[1/5] Compiling kunabi.ss with WPO...~n")
(parameterize ([compile-imported-libraries #t]
               [optimize-level 3]
               [cp0-effort-limit 500]
               [cp0-score-limit 50]
               [cp0-outer-unroll-limit 1]
               [commonization-level 4]
               [enable-unsafe-application #t]
               [enable-unsafe-variable-reference #t]
               [enable-arithmetic-left-associative #t]
               [debug-level 0]
               [generate-inspector-information #f]
               [generate-wpo-files #t]
               [library-directories
                 (cons* (cons ssl-stage ssl-stage)
                        (cons zlib-stage zlib-stage)
                        (cons leveldb-stage leveldb-stage)
                        (cons yaml-stage yaml-stage)
                        (cons aws-stage aws-stage)
                        (library-directories))])
  (compile-program "kunabi.ss"))

;; Step 2: WPO
(printf "[2/5] Running whole-program optimization...~n")
(parameterize ([library-directories
                 (cons* (cons ssl-stage ssl-stage)
                        (cons zlib-stage zlib-stage)
                        (cons leveldb-stage leveldb-stage)
                        (cons yaml-stage yaml-stage)
                        (cons aws-stage aws-stage)
                        (library-directories))])
  (let ((missing (compile-whole-program "kunabi.wpo" "kunabi-all.so")))
    (unless (null? missing)
      (printf "  WPO: ~a libraries not incorporated~n" (length missing))
      (for-each (lambda (lib) (printf "    ~a~n" lib)) missing))))

;; Step 3: Boot file
(printf "[3/5] Creating boot file...~n")
(apply make-boot-file "kunabi.boot" '("scheme" "petite")
  (existing-files
    (append
      (map (lambda (m) (format "~a/~a.so" jerboa-dir m))
        '("jerboa/core" "jerboa/runtime"
          "std/error" "std/format" "std/sort" "std/pregexp" "std/match2"
          "std/sugar" "std/misc/string" "std/misc/list" "std/misc/alist"
          "std/misc/thread" "std/foreign" "std/os/path" "std/text/json"
          "std/text/base64" "std/misc/ports" "std/misc/func" "std/result"
          "std/datetime" "std/iter" "std/csv" "std/debug/pp" "std/ergo"
          "std/typed" "std/cli/getopt" "std/crypto/digest"))
      (map (lambda (m) (format "~a/~a.so" gherkin-dir m))
        '("compat/types" "compat/gambit-compat" "runtime/util" "runtime/table"
          "runtime/c3" "runtime/mop" "runtime/error" "runtime/hash"
          "runtime/syntax" "runtime/eval" "reader/reader"
          "compiler/compile" "boot/gherkin"))
      ;; Use staged (patched) FFI libraries — no load-shared-object calls
      (list (format "~a/chez-ssl.so" ssl-stage)
            (format "~a/chez-https.so" ssl-stage)
            (format "~a/chez-zlib.so" zlib-stage)
            (format "~a/leveldb.so" leveldb-stage)
            (format "~a/yaml.so" yaml-stage))
      (map (lambda (m) (format "~a/~a.so" aws-stage m))
        '("jerboa-aws/json" "jerboa-aws/xml" "jerboa-aws/uri"
          "jerboa-aws/time" "jerboa-aws/crypto" "jerboa-aws/sigv4"
          "jerboa-aws/creds" "jerboa-aws/request" "jerboa-aws/api"
          "jerboa-aws/json-api" "jerboa-aws/s3/xml" "jerboa-aws/s3/api"
          "jerboa-aws/s3/buckets" "jerboa-aws/s3/objects"
          "jerboa-aws/sts/api" "jerboa-aws/sts/operations"))
      (map (lambda (m) (format "lib/kunabi/~a.so" m))
        '("config" "parser" "storage" "loader" "query" "detection" "billing")))))

;; Step 4: Generate C headers
(printf "[4/5] Generating C headers with embedded data...~n")
(file->c-header "kunabi-all.so" "kunabi_program.h"
                "kunabi_program_data" "kunabi_program_size")
(file->c-header (format "~a/petite.boot" chez-dir) "kunabi_petite_boot.h"
                "petite_boot_data" "petite_boot_size")
(file->c-header (format "~a/scheme.boot" chez-dir) "kunabi_scheme_boot.h"
                "scheme_boot_data" "scheme_boot_size")
(file->c-header "kunabi.boot" "kunabi_kunabi_boot.h"
                "kunabi_boot_data" "kunabi_boot_size")

;; Step 5: Generate FFI symbol registration header
;; Scans chez-ssl, chez-zlib, and chez-leveldb .sls files for foreign-procedure
;; declarations and generates a C header that registers them all via Sforeign_symbol.
(printf "[5/6] Generating kunabi_ffi_symbols.h...~n")

(define (extract-foreign-symbols file)
  "Extract foreign-procedure symbol names from a Scheme file."
  (if (file-exists? file)
    (let ([text (call-with-input-file file
                  (lambda (p) (get-string-all p)))])
      (let loop ([pos 0] [syms '()])
        (let ([idx (let search ([i pos])
                     (if (>= i (- (string-length text) 20))
                       #f
                       (if (and (char=? (string-ref text i) #\f)
                                (>= (- (string-length text) i) 19)
                                (string=? "foreign-procedure \""
                                          (substring text i (+ i 19))))
                         (+ i 19)
                         (search (+ i 1)))))])
          (if (not idx)
            (reverse syms)
            (let ([end (let find-end ([j idx])
                         (if (char=? (string-ref text j) #\")
                           j
                           (find-end (+ j 1))))])
              (loop (+ end 1)
                    (cons (substring text idx end) syms)))))))
    '()))

(define all-ffi-symbols
  (let ([syms (append
                (extract-foreign-symbols (format "~a/chez-ssl.sls" chez-ssl-dir))
                (extract-foreign-symbols (format "~a/chez-zlib.sls" chez-zlib-dir))
                (let ([ss (format "~a/leveldb.ss" chez-leveldb-dir)]
                      [sls (format "~a/leveldb.sls" chez-leveldb-dir)])
                  (cond
                    [(file-exists? ss) (extract-foreign-symbols ss)]
                    [(file-exists? sls) (extract-foreign-symbols sls)]
                    [else '()])))])
    ;; Deduplicate
    (let loop ([in syms] [seen '()] [out '()])
      (if (null? in)
        (reverse out)
        (if (member (car in) seen)
          (loop (cdr in) seen out)
          (loop (cdr in) (cons (car in) seen) (cons (car in) out)))))))

(printf "  Found ~a FFI symbols~n" (length all-ffi-symbols))

(call-with-output-file "kunabi_ffi_symbols.h"
  (lambda (out)
    (display "/* Auto-generated FFI symbol registration for static builds */\n" out)
    (display "/* Do not edit — regenerated by build-static-artifacts.ss */\n\n" out)
    ;; Extern declarations
    (for-each
      (lambda (sym)
        (fprintf out "extern void ~a();\n" sym))
      all-ffi-symbols)
    ;; Rust native symbols (conditional)
    (display "\n#ifdef HAS_JERBOA_NATIVE\n" out)
    (for-each
      (lambda (sym)
        (fprintf out "extern void ~a();\n" sym))
      '("jerboa_last_error"
        "jerboa_sha1" "jerboa_sha256" "jerboa_sha384" "jerboa_sha512" "jerboa_md5"
        "jerboa_hmac_sha256" "jerboa_hmac_sha256_verify"
        "jerboa_random_bytes" "jerboa_timing_safe_equal"
        "jerboa_aead_seal" "jerboa_aead_open"
        "jerboa_chacha20_seal" "jerboa_chacha20_open"
        "jerboa_scrypt"
        "jerboa_deflate" "jerboa_inflate" "jerboa_gzip" "jerboa_gunzip"))
    (display "#endif\n\n" out)
    ;; Registration function
    (display "static void register_ffi_symbols(void) {\n" out)
    (for-each
      (lambda (sym)
        (fprintf out "    Sforeign_symbol(\"~a\", (void*)~a);\n" sym sym))
      all-ffi-symbols)
    (display "#ifdef HAS_JERBOA_NATIVE\n" out)
    (for-each
      (lambda (sym)
        (fprintf out "    Sforeign_symbol(\"~a\", (void*)~a);\n" sym sym))
      '("jerboa_last_error"
        "jerboa_sha1" "jerboa_sha256" "jerboa_sha384" "jerboa_sha512" "jerboa_md5"
        "jerboa_hmac_sha256" "jerboa_hmac_sha256_verify"
        "jerboa_random_bytes" "jerboa_timing_safe_equal"
        "jerboa_aead_seal" "jerboa_aead_open"
        "jerboa_chacha20_seal" "jerboa_chacha20_open"
        "jerboa_scrypt"
        "jerboa_deflate" "jerboa_inflate" "jerboa_gzip" "jerboa_gunzip"))
    (display "#endif\n" out)
    (display "}\n" out))
  'replace)

;; Step 6: Summary
(printf "[6/6] Artifacts ready for static linking.~n")
(for-each (lambda (f)
            (when (file-exists? f)
              (printf "  ~a (~a bytes)~n" f
                (file-length (open-file-input-port f)))))
  '("kunabi_program.h" "kunabi_petite_boot.h"
    "kunabi_scheme_boot.h" "kunabi_kunabi_boot.h"
    "kunabi-all.so" "kunabi.boot"))
