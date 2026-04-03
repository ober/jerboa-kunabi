#!chezscheme
;;; build-kunabi-musl.ss — Build a fully static kunabi binary using musl libc
;;;
;;; Usage: scheme -q --libdirs lib:<jerboa-lib>:<gherkin-src>:<deps> < build-kunabi-musl.ss
;;;
;;; This script:
;;;   1. Compiles kunabi modules (using stock scheme with glibc)
;;;   2. Creates boot file + optimized program .so
;;;   3. Generates C files with embedded boot data
;;;   4. Compiles C with musl-gcc against musl-built Chez's scheme.h
;;;   5. Links fully static binary with libkernel.a from musl-built Chez
;;;
;;; The resulting kunabi-musl binary has zero runtime dependencies.

(import
  (except (chezscheme) void box box? unbox set-box!
          andmap ormap iota last-pair find
          1+ 1- fx/ fx1+ fx1-
          error error? raise with-exception-handler identifier?
          hash-table? make-hash-table)
  (jerboa build)
  (jerboa build musl))

;; ========== Validate musl setup ==========

(let ([result (validate-musl-setup)])
  (unless (eq? (car result) 'ok)
    (printf "Error: ~a~n" (cdr result))
    (printf "~nTo build Chez Scheme with musl:~n")
    (printf "  cd ~/mine/ChezScheme~n")
    (printf "  ./configure --threads --static CC=musl-gcc --installprefix=$HOME/chez-musl~n")
    (printf "  make -j$(nproc) && make install~n")
    (exit 1)))

(printf "musl Chez found: ~a~n~n" (musl-chez-lib-dir))

;; ========== Locate directories ==========

(define home (getenv "HOME"))

(define jerboa-dir
  (or (getenv "JERBOA_DIR")
      (format "~a/mine/jerboa/lib" home)))

(define jerboa-dir-base
  (or (getenv "JERBOA_BASE_DIR")
      (format "~a/mine/jerboa" home)))

(define gherkin-dir
  (or (getenv "GHERKIN_DIR")
      (format "~a/mine/gherkin/src" home)))

(define jerboa-aws-dir
  (or (getenv "JERBOA_AWS_DIR")
      (format "~a/mine/jerboa-aws/lib" home)))

(define chez-leveldb-dir
  (or (getenv "CHEZ_LEVELDB_DIR")
      (format "~a/mine/chez-leveldb" home)))

(define chez-yaml-dir
  (or (getenv "CHEZ_YAML_DIR")
      (format "~a/mine/chez-yaml" home)))

(define chez-zlib-dir
  (or (getenv "CHEZ_ZLIB_DIR")
      (format "~a/mine/chez-zlib/src" home)))

(define chez-https-dir
  (or (getenv "CHEZ_HTTPS_DIR")
      (format "~a/mine/chez-https/src" home)))

(define chez-ssl-dir
  (or (getenv "CHEZ_SSL_DIR")
      (format "~a/mine/chez-ssl/src" home)))

;; Rust native library
(define native-lib-path
  (format "~a/mine/jerboa/jerboa-native-rs/target/x86_64-unknown-linux-musl/release/libjerboa_native.a"
          home))
(define has-native-lib? (file-exists? native-lib-path))
(unless has-native-lib?
  (printf "  Warning: libjerboa_native.a not found — Rust native symbols disabled~n"))

;; ========== Step 0: Stage dependencies for static build ==========
(printf "[0/7] Staging dependencies for static build...~n")

;; chez-ssl: patch load-shared-object
(define ssl-stage (format "~a/ssl-stage" (current-directory)))
(system (format "rm -rf '~a' && mkdir -p '~a'" ssl-stage ssl-stage))
(system (format "cp '~a/chez-ssl.sls' '~a/chez-ssl.sls'" chez-ssl-dir ssl-stage))
(system (format "sed -i 's/(load-shared-object[^)]*)/(void)/g' '~a/chez-ssl.sls'" ssl-stage))

;; chez-https: copy (imports chez-ssl)
(system (format "cp '~a/chez-https.sls' '~a/chez-https.sls'" chez-https-dir ssl-stage))

;; chez-zlib: patch load-shared-object
(define zlib-stage (format "~a/zlib-stage" (current-directory)))
(system (format "rm -rf '~a' && mkdir -p '~a'" zlib-stage zlib-stage))
(system (format "cp '~a/chez-zlib.sls' '~a/chez-zlib.sls'" chez-zlib-dir zlib-stage))
(system (format "sed -i 's/(load-shared-object[^)]*)/(void)/g' '~a/chez-zlib.sls'" zlib-stage))

;; chez-leveldb: patch load-shared-object (it uses .ss extension)
(define leveldb-stage (format "~a/leveldb-stage" (current-directory)))
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
(define yaml-stage (format "~a/yaml-stage" (current-directory)))
(system (format "rm -rf '~a' && mkdir -p '~a'" yaml-stage yaml-stage))
(when (file-exists? (format "~a/yaml.sls" chez-yaml-dir))
  (system (format "cp '~a/yaml.sls' '~a/yaml.sls'" chez-yaml-dir yaml-stage)))

;; jerboa-aws: copy entire tree
(define aws-stage (format "~a/aws-stage" (current-directory)))
(system (format "rm -rf '~a' && mkdir -p '~a'" aws-stage aws-stage))
(system (format "cp -a '~a/jerboa-aws' '~a/'" jerboa-aws-dir aws-stage))
(system (format "find '~a/jerboa-aws' -name '*.so' -delete" aws-stage))
(system (format "find '~a/jerboa-aws' -name '*.wpo' -delete" aws-stage))

;; Compile staged modules
(printf "  Compiling staged modules...~n")
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
  ;; chez-ssl first
  (printf "    chez-ssl...~n")
  (compile-library (format "~a/chez-ssl.sls" ssl-stage))

  ;; chez-https (depends on chez-ssl)
  (printf "    chez-https...~n")
  (compile-library (format "~a/chez-https.sls" ssl-stage))

  ;; chez-zlib
  (printf "    chez-zlib...~n")
  (compile-library (format "~a/chez-zlib.sls" zlib-stage))

  ;; chez-leveldb
  (printf "    chez-leveldb...~n")
  (compile-library (format "~a/leveldb.sls" leveldb-stage))

  ;; chez-yaml (if available)
  (when (file-exists? (format "~a/yaml.sls" yaml-stage))
    (printf "    chez-yaml...~n")
    (compile-library (format "~a/yaml.sls" yaml-stage)))

  ;; jerboa-aws modules
  (printf "    jerboa-aws...~n")
  (for-each
    (lambda (f)
      (let ([path (format "~a/jerboa-aws/~a.sls" aws-stage f)])
        (when (file-exists? path) (compile-library path))))
    '("json" "xml" "uri" "time" "crypto" "creds" "sigv4"
      "request" "api" "json-api"
      "s3/xml" "s3/api" "s3/buckets" "s3/objects"
      "sts/api" "sts/operations")))

;; ========== Step 1: Compile kunabi modules ==========

(printf "~n[1/7] Compiling kunabi modules...~n")

(define (compile-kunabi-module name)
  (let ((sls (string-append "lib/kunabi/" name ".sls")))
    (if (file-exists? sls)
      (begin
        (printf "  Compiling ~a...~n" sls)
        (compile-library sls))
      (printf "  SKIP (not found): ~a~n" sls))))

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
  (for-each compile-kunabi-module
    '("config" "parser" "storage" "loader" "query" "detection" "billing")))

;; ========== Step 2: Compile program ==========

(printf "~n[2/7] Compiling kunabi.ss (optimize-level 3)...~n")
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
               [library-directories
                 (cons* (cons ssl-stage ssl-stage)
                        (cons zlib-stage zlib-stage)
                        (cons leveldb-stage leveldb-stage)
                        (cons yaml-stage yaml-stage)
                        (cons aws-stage aws-stage)
                        (library-directories))])
  (compile-program "kunabi.ss"))

;; ========== Step 3: Skip WPO for musl builds ==========
(printf "[3/7] Skipping WPO (using kunabi.so directly)...~n")
(define program-so "kunabi.so")

;; ========== Step 4: Create libs-only boot file ==========

(printf "[4/7] Creating libs-only boot file...~n")
(apply make-boot-file "kunabi.boot" '("scheme" "petite")
  (filter file-exists?
    (append
      ;; Jerboa runtime + stdlib
      (map (lambda (m) (format "~a/~a.so" jerboa-dir m))
        '("jerboa/core"
          "jerboa/runtime"
          "std/error"
          "std/format"
          "std/sort"
          "std/pregexp"
          "std/match2"
          "std/sugar"
          "std/misc/string"
          "std/misc/list"
          "std/misc/alist"
          "std/misc/thread"
          "std/foreign"
          "std/os/path"
          "std/text/json"
          "std/text/base64"
          "std/misc/ports"
          "std/misc/func"
          "std/result"
          "std/datetime"
          "std/iter"
          "std/csv"
          "std/debug/pp"
          "std/ergo"
          "std/typed"
          "std/cli/getopt"
          "std/crypto/digest"))
      ;; Gherkin runtime
      (map (lambda (m) (format "~a/~a.so" gherkin-dir m))
        '("compat/types"
          "compat/gambit-compat"
          "runtime/util"
          "runtime/table"
          "runtime/c3"
          "runtime/mop"
          "runtime/error"
          "runtime/hash"
          "runtime/syntax"
          "runtime/eval"
          "reader/reader"
          "compiler/compile"
          "boot/gherkin"))
      ;; chez-ssl + chez-https
      (list (format "~a/chez-ssl.so" ssl-stage)
            (format "~a/chez-https.so" ssl-stage))
      ;; chez-zlib
      (list (format "~a/chez-zlib.so" zlib-stage))
      ;; chez-leveldb
      (list (format "~a/leveldb.so" leveldb-stage))
      ;; chez-yaml (if available)
      (if (file-exists? (format "~a/yaml.so" yaml-stage))
        (list (format "~a/yaml.so" yaml-stage))
        '())
      ;; jerboa-aws
      (map (lambda (m) (format "~a/~a.so" aws-stage m))
        '("jerboa-aws/json" "jerboa-aws/xml" "jerboa-aws/uri"
          "jerboa-aws/time" "jerboa-aws/crypto" "jerboa-aws/sigv4"
          "jerboa-aws/creds" "jerboa-aws/request"
          "jerboa-aws/api" "jerboa-aws/json-api"
          "jerboa-aws/s3/xml" "jerboa-aws/s3/api"
          "jerboa-aws/s3/buckets" "jerboa-aws/s3/objects"
          "jerboa-aws/sts/api" "jerboa-aws/sts/operations"))
      ;; Kunabi modules
      (map (lambda (m) (format "lib/kunabi/~a.so" m))
        '("config" "parser" "storage" "loader" "query" "detection" "billing")))))

;; ========== Step 5: Generate C with embedded data ==========

(printf "[5/7] Generating C with embedded boot files + program...~n")

(define build-dir "/tmp/jerboa-musl-kunabi-build")
(system (format "rm -rf '~a' && mkdir -p '~a'" build-dir build-dir))

(define musl-lib-dir (musl-chez-lib-dir))
(define gcc (musl-gcc-path))
(define scheme-h-dir musl-lib-dir)
(define harden-cflags
  (string-append "-ffile-prefix-map=" (current-directory) "=."
                 " -ffile-prefix-map=" (or home "/root") "=~"))

;; Get boot file paths from musl Chez installation
(define musl-boots (musl-boot-files))
(define petite-boot-path (cdr (assoc "petite" musl-boots)))
(define scheme-boot-path (cdr (assoc "scheme" musl-boots)))

;; Generate static_boot.c
(define static-boot-c (format "~a/static_boot.c" build-dir))
(call-with-output-file static-boot-c
  (lambda (out)
    (display "#include \"scheme.h\"\n\n" out)
    (display (file->c-array petite-boot-path "petite_boot") out)
    (newline out)
    (display (file->c-array scheme-boot-path "scheme_boot") out)
    (newline out)
    (display (file->c-array "kunabi.boot" "kunabi_boot") out)
    (newline out)
    (display "void static_boot_init(void) {\n" out)
    (display "    Sregister_boot_file_bytes(\"petite\", petite_boot, petite_boot_len);\n" out)
    (display "    Sregister_boot_file_bytes(\"scheme\", scheme_boot, scheme_boot_len);\n" out)
    (display "    Sregister_boot_file_bytes(\"kunabi\", kunabi_boot, kunabi_boot_len);\n" out)
    (display "}\n" out))
  'replace)

;; Generate kunabi_main_musl.c
(define program-c (format "~a/kunabi_main_musl.c" build-dir))
(call-with-output-file program-c
  (lambda (out)
    (display "#define _GNU_SOURCE\n" out)
    (display "#include <stdlib.h>\n" out)
    (display "#include <string.h>\n" out)
    (display "#include <stdio.h>\n" out)
    (display "#include <unistd.h>\n" out)
    (display "#include <sys/mman.h>\n" out)
    (display "#include <sys/types.h>\n" out)
    (display "#include <sys/stat.h>\n" out)
    (display "#include <fcntl.h>\n" out)
    (display "#include <errno.h>\n" out)
    (display "#include \"scheme.h\"\n\n" out)
    (when has-native-lib?
      (display "#define HAS_JERBOA_NATIVE 1\n\n" out))
    ;; dlopen stubs for static builds
    (display "/* dlopen stubs for static builds */\n" out)
    (display "void *dlopen(const char *f, int fl) { (void)f; (void)fl; return (void*)1; }\n" out)
    (display "void *dlsym(void *h, const char *s) { (void)h; (void)s; return NULL; }\n" out)
    (display "int dlclose(void *h) { (void)h; return 0; }\n" out)
    (display "char *dlerror(void) { return NULL; }\n\n" out)
    ;; Embed program .so
    (display (file->c-array program-so "kunabi_program_data") out)
    (newline out)
    ;; Declare static_boot_init
    (display "extern void static_boot_init(void);\n\n" out)
    ;; Declare FFI functions
    (display "/* FFI symbols from shim files */\n" out)
    ;; LevelDB FFI
    (for-each
      (lambda (name) (fprintf out "extern void ~a();\n" name))
      '("leveldb_open" "leveldb_close" "leveldb_put" "leveldb_get"
        "leveldb_delete" "leveldb_free" "leveldb_iter_new" "leveldb_iter_seek"
        "leveldb_iter_seek_to_first" "leveldb_iter_seek_to_last"
        "leveldb_iter_next" "leveldb_iter_prev" "leveldb_iter_valid"
        "leveldb_iter_key" "leveldb_iter_value" "leveldb_iter_destroy"
        "leveldb_compact_range" "leveldb_writeoptions_create"
        "leveldb_writeoptions_destroy" "leveldb_writeoptions_set_sync"
        "leveldb_readoptions_create" "leveldb_readoptions_destroy"
        "leveldb_options_create" "leveldb_options_destroy"
        "leveldb_options_set_create_if_missing"
        "leveldb_options_set_compression"))
    ;; SSL FFI
    (for-each
      (lambda (name) (fprintf out "extern void ~a();\n" name))
      '("chez_ssl_init" "chez_ssl_cleanup"
        "chez_ssl_connect" "chez_ssl_write" "chez_ssl_read"
        "chez_ssl_read_all" "chez_ssl_free_buf" "chez_ssl_close"
        "chez_ssl_memcpy"
        "chez_tcp_listen" "chez_tcp_accept"
        "chez_tcp_connect" "chez_tcp_close"
        "chez_tcp_read" "chez_tcp_write" "chez_tcp_read_all"
        "chez_tcp_set_timeout"))
    ;; Zlib FFI
    (for-each
      (lambda (name) (fprintf out "extern void ~a();\n" name))
      '("chez_zlib_compress" "chez_zlib_uncompress"
        "chez_gzip_compress" "chez_gzip_uncompress"
        "chez_zlib_crc32" "chez_zlib_adler32"))
    ;; Rust native library symbols
    (when has-native-lib?
      (display "#ifdef HAS_JERBOA_NATIVE\n" out)
      (for-each
        (lambda (name) (fprintf out "extern void ~a();\n" name))
        '("jerboa_last_error"
          "jerboa_sha1" "jerboa_sha256" "jerboa_sha384" "jerboa_sha512" "jerboa_md5"
          "jerboa_hmac_sha256" "jerboa_hmac_sha256_verify"
          "jerboa_random_bytes" "jerboa_timing_safe_equal"
          "jerboa_aead_seal" "jerboa_aead_open"
          "jerboa_chacha20_seal" "jerboa_chacha20_open"
          "jerboa_scrypt"
          "jerboa_deflate" "jerboa_inflate" "jerboa_gzip" "jerboa_gunzip"))
      (display "#endif\n" out))
    (newline out)
    ;; Register FFI symbols
    (display "static void register_ffi_symbols(void) {\n" out)
    ;; LevelDB
    (for-each
      (lambda (name) (fprintf out "    Sforeign_symbol(\"~a\", (void*)~a);\n" name name))
      '("leveldb_open" "leveldb_close" "leveldb_put" "leveldb_get"
        "leveldb_delete" "leveldb_free" "leveldb_iter_new" "leveldb_iter_seek"
        "leveldb_iter_seek_to_first" "leveldb_iter_seek_to_last"
        "leveldb_iter_next" "leveldb_iter_prev" "leveldb_iter_valid"
        "leveldb_iter_key" "leveldb_iter_value" "leveldb_iter_destroy"
        "leveldb_compact_range" "leveldb_writeoptions_create"
        "leveldb_writeoptions_destroy" "leveldb_writeoptions_set_sync"
        "leveldb_readoptions_create" "leveldb_readoptions_destroy"
        "leveldb_options_create" "leveldb_options_destroy"
        "leveldb_options_set_create_if_missing"
        "leveldb_options_set_compression"))
    ;; SSL
    (for-each
      (lambda (name) (fprintf out "    Sforeign_symbol(\"~a\", (void*)~a);\n" name name))
      '("chez_ssl_init" "chez_ssl_cleanup"
        "chez_ssl_connect" "chez_ssl_write" "chez_ssl_read"
        "chez_ssl_read_all" "chez_ssl_free_buf" "chez_ssl_close"
        "chez_ssl_memcpy"
        "chez_tcp_listen" "chez_tcp_accept"
        "chez_tcp_connect" "chez_tcp_close"
        "chez_tcp_read" "chez_tcp_write" "chez_tcp_read_all"
        "chez_tcp_set_timeout"))
    ;; Zlib
    (for-each
      (lambda (name) (fprintf out "    Sforeign_symbol(\"~a\", (void*)~a);\n" name name))
      '("chez_zlib_compress" "chez_zlib_uncompress"
        "chez_gzip_compress" "chez_gzip_uncompress"
        "chez_zlib_crc32" "chez_zlib_adler32"))
    ;; Rust native (if available)
    (when has-native-lib?
      (display "#ifdef HAS_JERBOA_NATIVE\n" out)
      (for-each
        (lambda (name) (fprintf out "    Sforeign_symbol(\"~a\", (void*)~a);\n" name name))
        '("jerboa_last_error"
          "jerboa_sha1" "jerboa_sha256" "jerboa_sha384" "jerboa_sha512" "jerboa_md5"
          "jerboa_hmac_sha256" "jerboa_hmac_sha256_verify"
          "jerboa_random_bytes" "jerboa_timing_safe_equal"
          "jerboa_aead_seal" "jerboa_aead_open"
          "jerboa_chacha20_seal" "jerboa_chacha20_open"
          "jerboa_scrypt"
          "jerboa_deflate" "jerboa_inflate" "jerboa_gzip" "jerboa_gunzip"))
      (display "#endif\n" out))
    (display "}\n\n" out)
    ;; main()
    (display "int main(int argc, char *argv[]) {\n" out)
    (display "    /* Save args in env vars */\n" out)
    (display "    char buf[32];\n" out)
    (display "    snprintf(buf, sizeof(buf), \"%d\", argc - 1);\n" out)
    (display "    setenv(\"KUNABI_ARGC\", buf, 1);\n" out)
    (display "    for (int i = 1; i < argc; i++) {\n" out)
    (display "        snprintf(buf, sizeof(buf), \"KUNABI_ARG%d\", i - 1);\n" out)
    (display "        setenv(buf, argv[i], 1);\n" out)
    (display "    }\n\n" out)
    (display "    /* Initialize Chez + register embedded boot files */\n" out)
    (display "    Sscheme_init(NULL);\n" out)
    (display "    static_boot_init();\n" out)
    (display "    Sbuild_heap(NULL, NULL);\n\n" out)
    (display "    /* Register FFI symbols after heap is built */\n" out)
    (display "    register_ffi_symbols();\n\n" out)
    (display "    /* Load program via memfd */\n" out)
    (display "    int fd = memfd_create(\"kunabi-program\", 1 /* MFD_CLOEXEC */);\n" out)
    (display "    if (fd < 0) { perror(\"memfd_create\"); return 1; }\n" out)
    (display "    if (write(fd, kunabi_program_data, kunabi_program_data_len) != (ssize_t)kunabi_program_data_len) {\n" out)
    (display "        perror(\"write\"); close(fd); return 1;\n" out)
    (display "    }\n" out)
    (display "    char prog_path[64];\n" out)
    (display "    snprintf(prog_path, sizeof(prog_path), \"/proc/self/fd/%d\", fd);\n\n" out)
    (display "    const char *script_args[] = { argv[0] };\n" out)
    (display "    int status = Sscheme_script(prog_path, 1, script_args);\n\n" out)
    (display "    close(fd);\n" out)
    (display "    Sscheme_deinit();\n" out)
    (display "    return status;\n" out)
    (display "}\n" out))
  'replace)

;; ========== Step 6: Compile C with musl-gcc ==========

(printf "[6/7] Compiling C with musl-gcc...~n")

(define (run-cmd cmd)
  (printf "  ~a~n" cmd)
  (unless (= 0 (system cmd))
    (error 'build-kunabi-musl "Command failed" cmd)))

;; Compile static_boot.c
(run-cmd (format "~a -c -O2 ~a -I'~a' -o '~a/static_boot.o' '~a'"
                 gcc harden-cflags scheme-h-dir
                 build-dir static-boot-c))

;; Compile kunabi_main_musl.c
(run-cmd (format "~a -c -O2 ~a -I'~a' -o '~a/kunabi_main_musl.o' '~a'"
                 gcc harden-cflags scheme-h-dir
                 build-dir program-c))

;; Compile chez-leveldb shim (use regular gcc since musl-gcc doesn't have leveldb headers)
(let ([leveldb-shim (format "~a/mine/chez-leveldb/leveldb_shim.c" home)])
  (if (file-exists? leveldb-shim)
    (run-cmd (format "gcc -c -O2 ~a -fno-stack-protector -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -o '~a/leveldb-shim.o' '~a' -Wall"
                     harden-cflags build-dir leveldb-shim))
    (system (format "echo '' | ~a -c -x c -o '~a/leveldb-shim.o' -" gcc build-dir))))

;; Compile chez-ssl shim (with system gcc for OpenSSL headers)
(let ([ssl-shim (format "~a/mine/chez-ssl/chez_ssl_shim.c" home)])
  (if (file-exists? ssl-shim)
    (run-cmd (format "gcc -c -O2 ~a -fno-stack-protector -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -o '~a/ssl-shim.o' '~a' -Wall"
                     harden-cflags build-dir ssl-shim))
    (system (format "echo '' | ~a -c -x c -o '~a/ssl-shim.o' -" gcc build-dir))))

;; Compile chez-zlib shim (use regular gcc since musl-gcc doesn't have zlib headers)
(let ([zlib-shim (format "~a/mine/chez-zlib/chez_zlib_shim.c" home)])
  (if (file-exists? zlib-shim)
    (run-cmd (format "gcc -c -O2 ~a -fno-stack-protector -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -o '~a/zlib-shim.o' '~a' -Wall"
                     harden-cflags build-dir zlib-shim))
    (system (format "echo '' | ~a -c -x c -o '~a/zlib-shim.o' -" gcc build-dir))))

;; Generate glibc-compat shim
(let ([compat-c (format "~a/glibc-compat.c" build-dir)])
  (call-with-output-file compat-c
    (lambda (out)
      (display "/* glibc-compat shim */\n" out)
      (display "#include <string.h>\n#include <stdio.h>\n#include <stdarg.h>\n#include <stdlib.h>\n" out)
      (display "void *__memcpy_chk(void *d, const void *s, size_t n, size_t ds) { (void)ds; return memcpy(d, s, n); }\n" out)
      (display "void *__memset_chk(void *d, int c, size_t n, size_t ds) { (void)ds; return memset(d, c, n); }\n" out)
      (display "int __fprintf_chk(FILE *f, int flag, const char *fmt, ...) { va_list ap; va_start(ap, fmt); int r = vfprintf(f, fmt, ap); va_end(ap); (void)flag; return r; }\n" out)
      (display "int __vfprintf_chk(FILE *f, int flag, const char *fmt, va_list ap) { (void)flag; return vfprintf(f, fmt, ap); }\n" out)
      (display "int __sprintf_chk(char *s, int flag, size_t sl, const char *fmt, ...) { va_list ap; va_start(ap, fmt); int r = vsprintf(s, fmt, ap); va_end(ap); (void)flag; (void)sl; return r; }\n" out)
      (display "FILE *fopen64(const char *p, const char *m) { return fopen(p, m); }\n" out)
      (display "long __isoc23_strtol(const char *s, char **e, int b) { return strtol(s, e, b); }\n" out)
      (display "unsigned long __fdelt_chk(unsigned long d) { return d / (8 * sizeof(unsigned long)); }\n" out)
      (display "int getcontext(void *u) { (void)u; return -1; }\n" out)
      (display "void makecontext(void *u, void (*f)(void), int a, ...) { (void)u; (void)f; (void)a; }\n" out)
      (display "int swapcontext(void *o, const void *n) { (void)o; (void)n; return -1; }\n" out)
      (display "int _dl_find_object(void *a, void *b) { (void)a; (void)b; return -1; }\n" out))
    'replace)
  (run-cmd (format "~a -c -O2 -o '~a/glibc-compat.o' '~a' -Wall"
                   gcc build-dir compat-c)))

;; ========== Step 7: Link static binary ==========

(printf "[7/7] Linking static kunabi-musl binary...~n")

;; Check for musl-built leveldb (Docker build) or system libleveldb.a
(define leveldb-lib-path
  (let ([musl-path (getenv "LEVELDB_MUSL_PREFIX")])
    (if (and musl-path (file-exists? (format "~a/lib/libleveldb.a" musl-path)))
      (format "~a/lib/libleveldb.a" musl-path)
      (if (file-exists? "/usr/lib/x86_64-linux-gnu/libleveldb.a")
        "/usr/lib/x86_64-linux-gnu/libleveldb.a"
        #f))))

;; Check for musl-built zlib or system libz.a
(define zlib-lib-path
  (let ([musl-path (getenv "ZLIB_MUSL_PREFIX")])
    (if (and musl-path (file-exists? (format "~a/lib/libz.a" musl-path)))
      (format "~a/lib/libz.a" musl-path)
      (if (file-exists? "/usr/lib/x86_64-linux-gnu/libz.a")
        "/usr/lib/x86_64-linux-gnu/libz.a"
        #f))))

(let ([link-cmd (musl-link-command
                  "kunabi-musl"
                  (list (format "~a/kunabi_main_musl.o" build-dir)
                        (format "~a/static_boot.o" build-dir)
                        (format "~a/leveldb-shim.o" build-dir)
                        (format "~a/ssl-shim.o" build-dir)
                        (format "~a/zlib-shim.o" build-dir)
                        (format "~a/glibc-compat.o" build-dir))
                  (append
                    ;; Rust native library
                    (if has-native-lib?
                      (list native-lib-path)
                      '())
                    ;; Static libraries
                    (if (file-exists? "/usr/lib/x86_64-linux-gnu/libssl.a")
                      '("/usr/lib/x86_64-linux-gnu/libssl.a")
                      '())
                    (if (file-exists? "/usr/lib/x86_64-linux-gnu/libcrypto.a")
                      '("/usr/lib/x86_64-linux-gnu/libcrypto.a")
                      '())
                    ;; LevelDB (musl-built or system)
                    (if leveldb-lib-path
                      (list leveldb-lib-path)
                      '())
                    ;; Zlib (musl-built or system)
                    (if zlib-lib-path
                      (list zlib-lib-path)
                      '())))])
  (run-cmd (string-append link-cmd " -Wl,--allow-multiple-definition")))

;; Strip and hash
(when (file-exists? "kunabi-musl")
  (printf "~n[harden] Stripping symbols...~n")
  (let ([pre-size (file-length (open-file-input-port "kunabi-musl"))])
    (run-cmd "strip --strip-all kunabi-musl")
    (when (= 0 (system "objcopy --strip-section-headers kunabi-musl 2>/dev/null"))
      (printf "  Section headers removed~n"))
    (let ([post-size (file-length (open-file-input-port "kunabi-musl"))])
      (printf "  Stripped: ~a → ~a bytes (~a% reduction)~n"
              pre-size post-size
              (inexact->exact (round (* 100 (/ (- pre-size post-size) pre-size))))))))

;; Cleanup
(system (format "rm -rf '~a'" build-dir))
(system (format "rm -rf '~a' '~a' '~a' '~a' '~a'"
                ssl-stage zlib-stage leveldb-stage yaml-stage aws-stage))

;; Summary
(printf "~n========================================~n")
(printf "Static binary created: kunabi-musl~n~n")
(system "ls -lh kunabi-musl")
(printf "~n")
(system "file kunabi-musl")
(printf "~nTest: ./kunabi-musl help~n")
