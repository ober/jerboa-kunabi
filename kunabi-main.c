/*
 * kunabi-main.c — Custom entry point for kunabi static binary.
 *
 * Saves all user args in positional env vars (KUNABI_ARGC, KUNABI_ARG0, ...),
 * then calls the Chez runtime. The Scheme entry point reads these env vars.
 *
 * Boot files (petite.boot, scheme.boot, kunabi.boot) are embedded as C byte
 * arrays and registered via Sregister_boot_file_bytes — no external files needed.
 *
 * Threading workaround: Programs embedded in boot files cannot create threads
 * (fork-thread blocks forever on internal GC futex). The program is loaded
 * separately via Sscheme_script.
 */

#define _GNU_SOURCE
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/mman.h>
#include "scheme.h"
#include "kunabi_program.h"      /* generated: kunabi_program_data[], kunabi_program_size */
#include "kunabi_petite_boot.h"  /* generated: petite_boot_data[], petite_boot_size */
#include "kunabi_scheme_boot.h"  /* generated: scheme_boot_data[], scheme_boot_size */
#include "kunabi_kunabi_boot.h"  /* kunabi custom entry point */

/* LevelDB FFI symbol registration */
extern void Sforeign_symbol(const char *name, void *addr);

/* From leveldb shim */
extern void* leveldb_open_db(const char* path, int create_if_missing, int bloom_bits,
                             size_t write_buffer_size, size_t lru_cache_capacity);
extern void leveldb_close_db(void* db);
extern char* leveldb_get(void* db, const char* key, size_t key_len, size_t* value_len);
extern int leveldb_put(void* db, const char* key, size_t key_len, const char* value, size_t value_len);
extern int leveldb_delete(void* db, const char* key, size_t key_len);
extern void* leveldb_create_iterator(void* db);
extern void leveldb_destroy_iterator(void* iter);
extern void leveldb_iterator_seek(void* iter, const char* key, size_t key_len);
extern void leveldb_iterator_seek_to_first(void* iter);
extern void leveldb_iterator_seek_to_last(void* iter);
extern int leveldb_iterator_valid(void* iter);
extern void leveldb_iterator_next(void* iter);
extern void leveldb_iterator_prev(void* iter);
extern char* leveldb_iterator_key(void* iter, size_t* key_len);
extern char* leveldb_iterator_value(void* iter, size_t* value_len);
extern void* leveldb_create_writebatch(void);
extern void leveldb_destroy_writebatch(void* batch);
extern void leveldb_writebatch_put(void* batch, const char* key, size_t key_len, const char* value, size_t value_len);
extern void leveldb_writebatch_delete(void* batch, const char* key, size_t key_len);
extern int leveldb_write(void* db, void* batch);
extern void* leveldb_create_snapshot(void* db);
extern void leveldb_release_snapshot(void* db, void* snapshot);
extern void leveldb_compact_range(void* db, const char* start_key, size_t start_len,
                                  const char* limit_key, size_t limit_len);

/* From zlib shim */
extern int chez_gunzip(const unsigned char* in, size_t in_len, void* out_ptr, void* out_len_ptr);
extern int chez_inflate(const unsigned char* in, size_t in_len, void* out_ptr, void* out_len_ptr);
extern int chez_gzip(const unsigned char* in, size_t in_len, void* out_ptr, void* out_len_ptr);
extern int chez_deflate(const unsigned char* in, size_t in_len, void* out_ptr, void* out_len_ptr);
extern int chez_gzip_check(const unsigned char* in, size_t in_len);

/* YAML FFI from chez-yaml shim */
extern void* yaml_parser_new(void);
extern void yaml_parser_free(void* parser);
extern int yaml_parser_parse_file(void* parser, const char* path);
extern int yaml_parser_parse_string(void* parser, const char* str, size_t len);
extern int yaml_doc_type(void* parser);
extern char* yaml_doc_scalar(void* parser);
extern int yaml_doc_sequence_length(void* parser);
extern int yaml_doc_enter_sequence_item(void* parser, int idx);
extern int yaml_doc_mapping_length(void* parser);
extern char* yaml_doc_mapping_key(void* parser, int idx);
extern int yaml_doc_enter_mapping_value(void* parser, int idx);
extern void yaml_doc_leave(void* parser);

static void register_ffi_symbols(void) {
    /* LevelDB */
    Sforeign_symbol("leveldb_open_db", leveldb_open_db);
    Sforeign_symbol("leveldb_close_db", leveldb_close_db);
    Sforeign_symbol("leveldb_get", leveldb_get);
    Sforeign_symbol("leveldb_put", leveldb_put);
    Sforeign_symbol("leveldb_delete", leveldb_delete);
    Sforeign_symbol("leveldb_create_iterator", leveldb_create_iterator);
    Sforeign_symbol("leveldb_destroy_iterator", leveldb_destroy_iterator);
    Sforeign_symbol("leveldb_iterator_seek", leveldb_iterator_seek);
    Sforeign_symbol("leveldb_iterator_seek_to_first", leveldb_iterator_seek_to_first);
    Sforeign_symbol("leveldb_iterator_seek_to_last", leveldb_iterator_seek_to_last);
    Sforeign_symbol("leveldb_iterator_valid", leveldb_iterator_valid);
    Sforeign_symbol("leveldb_iterator_next", leveldb_iterator_next);
    Sforeign_symbol("leveldb_iterator_prev", leveldb_iterator_prev);
    Sforeign_symbol("leveldb_iterator_key", leveldb_iterator_key);
    Sforeign_symbol("leveldb_iterator_value", leveldb_iterator_value);
    Sforeign_symbol("leveldb_create_writebatch", leveldb_create_writebatch);
    Sforeign_symbol("leveldb_destroy_writebatch", leveldb_destroy_writebatch);
    Sforeign_symbol("leveldb_writebatch_put", leveldb_writebatch_put);
    Sforeign_symbol("leveldb_writebatch_delete", leveldb_writebatch_delete);
    Sforeign_symbol("leveldb_write", leveldb_write);
    Sforeign_symbol("leveldb_create_snapshot", leveldb_create_snapshot);
    Sforeign_symbol("leveldb_release_snapshot", leveldb_release_snapshot);
    Sforeign_symbol("leveldb_compact_range", leveldb_compact_range);

    /* zlib */
    Sforeign_symbol("chez_gunzip", chez_gunzip);
    Sforeign_symbol("chez_inflate", chez_inflate);
    Sforeign_symbol("chez_gzip", chez_gzip);
    Sforeign_symbol("chez_deflate", chez_deflate);
    Sforeign_symbol("chez_gzip_check", chez_gzip_check);

    /* YAML */
    Sforeign_symbol("yaml_parser_new", yaml_parser_new);
    Sforeign_symbol("yaml_parser_free", yaml_parser_free);
    Sforeign_symbol("yaml_parser_parse_file", yaml_parser_parse_file);
    Sforeign_symbol("yaml_parser_parse_string", yaml_parser_parse_string);
    Sforeign_symbol("yaml_doc_type", yaml_doc_type);
    Sforeign_symbol("yaml_doc_scalar", yaml_doc_scalar);
    Sforeign_symbol("yaml_doc_sequence_length", yaml_doc_sequence_length);
    Sforeign_symbol("yaml_doc_enter_sequence_item", yaml_doc_enter_sequence_item);
    Sforeign_symbol("yaml_doc_mapping_length", yaml_doc_mapping_length);
    Sforeign_symbol("yaml_doc_mapping_key", yaml_doc_mapping_key);
    Sforeign_symbol("yaml_doc_enter_mapping_value", yaml_doc_enter_mapping_value);
    Sforeign_symbol("yaml_doc_leave", yaml_doc_leave);
}

int main(int argc, char *argv[]) {
    /* Save args in positional env vars: KUNABI_ARGC, KUNABI_ARG0, KUNABI_ARG1, ... */
    char countbuf[32];
    snprintf(countbuf, sizeof(countbuf), "%d", argc - 1);
    setenv("KUNABI_ARGC", countbuf, 1);

    for (int i = 1; i < argc; i++) {
        char name[32];
        snprintf(name, sizeof(name), "KUNABI_ARG%d", i - 1);
        setenv(name, argv[i], 1);
    }

    /* Create memfd / tmpfile for embedded program .so */
    char prog_path[256];
    int fd = -1;
    int use_tmpfile = 0;

#ifdef __linux__
    fd = memfd_create("kunabi-program", MFD_CLOEXEC);
    if (fd >= 0) {
        if (write(fd, kunabi_program_data, kunabi_program_size) != (ssize_t)kunabi_program_size) {
            perror("write memfd");
            close(fd);
            return 1;
        }
        snprintf(prog_path, sizeof(prog_path), "/proc/self/fd/%d", fd);
    } else {
        use_tmpfile = 1;
    }
#else
    use_tmpfile = 1;
#endif

    if (use_tmpfile) {
        const char *tmpdir = getenv("TMPDIR");
        if (!tmpdir) tmpdir = "/tmp";
        snprintf(prog_path, sizeof(prog_path), "%s/.kunabi-program-%d.so", tmpdir, getpid());
        FILE *fp = fopen(prog_path, "wb");
        if (!fp) { perror("fopen tmpfile"); return 1; }
        if (fwrite(kunabi_program_data, 1, kunabi_program_size, fp) != kunabi_program_size) {
            perror("fwrite tmpfile");
            fclose(fp);
            unlink(prog_path);
            return 1;
        }
        fclose(fp);
    }

    /* Initialize Chez Scheme */
    Sscheme_init(NULL);

    /* Register FFI symbols before building heap */
    register_ffi_symbols();

    /* Register embedded boot files (no external files needed) */
    Sregister_boot_file_bytes("petite", (void*)petite_boot_data, petite_boot_size);
    Sregister_boot_file_bytes("scheme", (void*)scheme_boot_data, scheme_boot_size);
    Sregister_boot_file_bytes("kunabi", (void*)kunabi_boot_data, kunabi_boot_size);

    /* Build heap from registered boot files (libraries only — no program) */
    Sbuild_heap(NULL, NULL);

    /* Run the program via Sscheme_script (NOT Sscheme_start) */
    const char *script_args[] = { argv[0] };
    int status = Sscheme_script(prog_path, 1, script_args);

    if (fd >= 0) close(fd);
    if (use_tmpfile) unlink(prog_path);
    Sscheme_deinit();
    return status;
}
