/*
 * kunabi-main.c — Custom entry point for kunabi static binary.
 *
 * Boot files (petite.boot, scheme.boot, kunabi.boot) are embedded as C byte
 * arrays and registered via Sregister_boot_file_bytes — no external files needed.
 *
 * Threading workaround: Programs embedded in boot files cannot create threads
 * (fork-thread blocks forever on internal GC futex). The program is loaded
 * separately via Sscheme_script.
 *
 * FFI symbols are found via dlsym(RTLD_DEFAULT) because we link with -rdynamic.
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

int main(int argc, char *argv[]) {
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

    /* Register embedded boot files (no external files needed) */
    Sregister_boot_file_bytes("petite", (void*)petite_boot_data, petite_boot_size);
    Sregister_boot_file_bytes("scheme", (void*)scheme_boot_data, scheme_boot_size);
    Sregister_boot_file_bytes("kunabi", (void*)kunabi_boot_data, kunabi_boot_size);

    /* Build heap from registered boot files (libraries only — no program) */
    Sbuild_heap(NULL, NULL);

    /* Run the program via Sscheme_script (NOT Sscheme_start).
     * Pass full argv so (command-line-arguments) includes all args. */
    int status = Sscheme_script(prog_path, argc, (const char **)argv);

    if (fd >= 0) close(fd);
    if (use_tmpfile) unlink(prog_path);
    Sscheme_deinit();
    return status;
}
