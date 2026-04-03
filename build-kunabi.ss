#!chezscheme
;;; build-kunabi.ss — Compile kunabi modules and build static binary
;;;
;;; Usage: scheme -q --libdirs lib:<deps> --compile-imported-libraries < build-kunabi.ss

(import (chezscheme))

;; --- Helper: generate C header from binary file ---
(define (file->c-header input-path output-path array-name size-name)
  (let* ((port (open-file-input-port input-path))
         (data (get-bytevector-all port))
         (size (bytevector-length data)))
    (close-port port)
    (call-with-output-file output-path
      (lambda (out)
        (fprintf out "/* Auto-generated — do not edit */~n")
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

;; --- Locate Chez install directory ---
(define chez-dir
  (or (getenv "CHEZ_DIR")
      (let* ((mt (symbol->string (machine-type)))
             (search-dirs (list (format "~a/.local/lib" (getenv "HOME"))
                                "/usr/local/lib"
                                "/usr/lib")))
        (let dir-lp ((dirs search-dirs))
          (if (null? dirs) #f
            (let ((lib-dir (car dirs)))
              (or (let lp ((entries (guard (e (#t '())) (directory-list lib-dir))))
                    (cond
                      ((null? entries) #f)
                      ((and (> (string-length (car entries)) 3)
                            (string=? "csv" (substring (car entries) 0 3)))
                       (let ((csv-dir (format "~a/~a/~a" lib-dir (car entries) mt)))
                         (and (file-exists? (format "~a/main.o" csv-dir))
                              csv-dir)))
                      (else (lp (cdr entries)))))
                  (dir-lp (cdr dirs)))))))))

(unless chez-dir
  (display "Error: Cannot find Chez install dir. Set CHEZ_DIR.\n")
  (exit 1))

;; --- Locate dependency directories ---
(define jerboa-dir
  (or (getenv "JERBOA_DIR")
      (format "~a/mine/jerboa/lib" (getenv "HOME"))))

(define jerboa-aws-dir
  (or (getenv "JERBOA_AWS_DIR")
      (format "~a/mine/jerboa-aws/lib" (getenv "HOME"))))

(define chez-leveldb-dir
  (or (getenv "CHEZ_LEVELDB_DIR")
      (format "~a/mine/chez-leveldb" (getenv "HOME"))))

(define chez-yaml-dir
  (or (getenv "CHEZ_YAML_DIR")
      (format "~a/mine/chez-yaml/src" (getenv "HOME"))))

(define chez-zlib-dir
  (or (getenv "CHEZ_ZLIB_DIR")
      (format "~a/mine/chez-zlib/src" (getenv "HOME"))))

(define chez-https-dir
  (or (getenv "CHEZ_HTTPS_DIR")
      (format "~a/mine/chez-https/src" (getenv "HOME"))))

(define chez-ssl-dir
  (or (getenv "CHEZ_SSL_DIR")
      (format "~a/mine/chez-ssl/src" (getenv "HOME"))))

(printf "Chez dir:        ~a~n" chez-dir)
(printf "Jerboa dir:      ~a~n" jerboa-dir)
(printf "jerboa-aws dir:  ~a~n" jerboa-aws-dir)
(printf "chez-leveldb:    ~a~n" chez-leveldb-dir)
(printf "chez-yaml:       ~a~n" chez-yaml-dir)
(printf "chez-zlib:       ~a~n" chez-zlib-dir)
(printf "chez-https:      ~a~n" chez-https-dir)
(printf "chez-ssl:        ~a~n" chez-ssl-dir)

;; --- Step 1: Compile all modules + entry point ---
(printf "~n[1/7] Compiling all modules (optimize-level 3, WPO)...~n")
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
               [generate-wpo-files #t])
  (compile-program "kunabi.ss"))

;; --- Step 2: Whole-program optimization ---
(printf "[2/7] Running whole-program optimization...~n")
(let ((missing (compile-whole-program "kunabi.wpo" "kunabi-all.so")))
  (unless (null? missing)
    (printf "  WPO: ~a libraries not incorporated (missing .wpo):~n" (length missing))
    (for-each (lambda (lib) (printf "    ~a~n" lib)) missing)))

;; --- Step 3: Make libs-only boot file ---
(printf "[3/7] Creating libs-only boot file...~n")
(apply make-boot-file "kunabi.boot" '("scheme" "petite")
  (append
    ;; Jerboa runtime + stdlib modules
    (map (lambda (m) (format "~a/~a.so" jerboa-dir m))
      '("jerboa/core"
        "jerboa/runtime"
        "std/error"
        "std/error/conditions"
        "std/format"
        "std/match2"
        "std/misc/alist"
        "std/misc/list"
        "std/misc/ports"
        "std/misc/string"
        "std/misc/func"
        "std/os/path"
        "std/result"
        "std/sort"
        "std/sugar"
        "std/text/json"
        "std/datetime"
        "std/iter"
        "std/misc/thread"
        "std/csv"
        "std/debug/pp"
        "std/ergo"
        "std/typed"))
    ;; chez-ssl (TLS bindings)
    (if (file-exists? (format "~a/chez-ssl.so" chez-ssl-dir))
      (list (format "~a/chez-ssl.so" chez-ssl-dir))
      '())
    ;; chez-https (HTTPS client)
    (if (file-exists? (format "~a/chez-https.so" chez-https-dir))
      (list (format "~a/chez-https.so" chez-https-dir))
      '())
    ;; jerboa-aws modules
    (let ([aws-modules '("jerboa-aws/json" "jerboa-aws/xml" "jerboa-aws/uri"
                         "jerboa-aws/time" "jerboa-aws/crypto" "jerboa-aws/sigv4"
                         "jerboa-aws/creds" "jerboa-aws/request"
                         "jerboa-aws/s3/api" "jerboa-aws/s3/objects")])
      (filter file-exists?
        (map (lambda (m) (format "~a/~a.so" jerboa-aws-dir m)) aws-modules)))
    ;; chez-leveldb
    (if (file-exists? (format "~a/leveldb.so" chez-leveldb-dir))
      (list (format "~a/leveldb.so" chez-leveldb-dir))
      '())
    ;; chez-yaml
    (if (file-exists? (format "~a/yaml.so" chez-yaml-dir))
      (list (format "~a/yaml.so" chez-yaml-dir))
      '())
    ;; chez-zlib
    (if (file-exists? (format "~a/chez-zlib.so" chez-zlib-dir))
      (list (format "~a/chez-zlib.so" chez-zlib-dir))
      '())
    ;; Kunabi modules
    (map (lambda (m) (format "lib/kunabi/~a.so" m))
      '("parser" "config" "storage" "loader" "query" "detection" "billing"))))

;; --- Step 4: Generate C headers with embedded data ---
(printf "[4/7] Embedding boot files + program as C headers...~n")
(file->c-header "kunabi-all.so" "kunabi_program.h"
                "kunabi_program_data" "kunabi_program_size")
(file->c-header (format "~a/petite.boot" chez-dir) "kunabi_petite_boot.h"
                "petite_boot_data" "petite_boot_size")
(file->c-header (format "~a/scheme.boot" chez-dir) "kunabi_scheme_boot.h"
                "scheme_boot_data" "scheme_boot_size")
(file->c-header "kunabi.boot" "kunabi_kunabi_boot.h"
                "kunabi_boot_data" "kunabi_boot_size")

;; --- Step 5: Compile C sources ---
(printf "[5/7] Compiling C sources...~n")

;; LevelDB shim
(let ([leveldb-shim (format "~a/chez_leveldb_shim.c" chez-leveldb-dir)])
  (if (file-exists? leveldb-shim)
    (unless (= 0 (system (format "gcc -c -fPIC -O2 -o chez-leveldb-shim.o ~a -Wall 2>&1" leveldb-shim)))
      (display "Error: chez-leveldb shim compilation failed\n")
      (exit 1))
    (begin
      (display "Warning: chez-leveldb shim not found, creating stub\n")
      (system "echo '' | gcc -c -x c -o chez-leveldb-shim.o -"))))

;; YAML shim
(let ([yaml-shim (format "~a/../chez_yaml_shim.c" chez-yaml-dir)])
  (if (file-exists? yaml-shim)
    (unless (= 0 (system (format "gcc -c -fPIC -O2 -o chez-yaml-shim.o ~a -Wall 2>&1" yaml-shim)))
      (display "Error: chez-yaml shim compilation failed\n")
      (exit 1))
    (begin
      (display "Warning: chez-yaml shim not found, creating stub\n")
      (system "echo '' | gcc -c -x c -o chez-yaml-shim.o -"))))

;; Zlib shim
(let ([zlib-shim (format "~a/../chez_zlib_shim.c" chez-zlib-dir)])
  (if (file-exists? zlib-shim)
    (unless (= 0 (system (format "gcc -c -fPIC -O2 -o chez-zlib-shim.o ~a -Wall 2>&1" zlib-shim)))
      (display "Error: chez-zlib shim compilation failed\n")
      (exit 1))
    (begin
      (display "Warning: chez-zlib shim not found, creating stub\n")
      (system "echo '' | gcc -c -x c -o chez-zlib-shim.o -"))))

;; Custom main
(let ((cmd (format "gcc -c -O2 -o kunabi-main.o kunabi-main.c -I~a -I. -Wall 2>&1" chez-dir)))
  (unless (= 0 (system cmd))
    (display "Error: kunabi-main.c compilation failed\n")
    (exit 1)))

;; --- Step 6: Link native binary ---
(printf "[6/7] Linking native binary...~n")
(let* ((platform-libs "-lleveldb -lyaml -lz -lcrypto -lm -ldl -lpthread")
       (cmd (format "gcc -rdynamic -o kunabi kunabi-main.o chez-leveldb-shim.o chez-yaml-shim.o chez-zlib-shim.o -L~a -lkernel ~a -Wl,-rpath,~a"
              chez-dir platform-libs chez-dir)))
  (printf "  ~a~n" cmd)
  (unless (= 0 (system cmd))
    (display "Error: Link failed\n")
    (exit 1)))

;; --- Step 7: Clean up intermediate files ---
(printf "[7/7] Cleaning up...~n")
(for-each (lambda (f)
            (when (file-exists? f) (delete-file f)))
  '("kunabi-main.o" "chez-leveldb-shim.o" "chez-yaml-shim.o" "chez-zlib-shim.o"
    "kunabi_program.h" "kunabi_petite_boot.h" "kunabi_scheme_boot.h" "kunabi_kunabi_boot.h"
    "kunabi-all.so" "kunabi.so" "kunabi.wpo" "kunabi.boot"))

(printf "~n========================================~n")
(printf "Build complete!~n~n")
(printf "  Binary: ./kunabi  (self-contained ELF, ~a KB)~n"
  (quotient (file-length (open-file-input-port "kunabi")) 1024))
(printf "~nRun:~n")
(printf "  ./kunabi help~n")
(printf "  ./kunabi load --bucket <bucket> --prefix <prefix>~n")
(printf "  ./kunabi detect --summary~n")
