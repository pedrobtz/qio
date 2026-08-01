#ifndef QIO_PATH_H
#define QIO_PATH_H

#include <Rinternals.h>
#include <stdio.h>

/* File paths that survive leaving the active code page.
 *
 * carquet opens paths with fopen(), which on Windows interprets its bytes in
 * the active code page. A path outside that page therefore cannot be opened at
 * all, whatever R hands over -- and for a user whose language is not covered by
 * their code page, that is most of their paths. Windows has taken UTF-16 since
 * NT; the byte interface is the lossy one.
 *
 * So qio opens the file itself and passes carquet the stream, through
 * carquet_reader_open_file() and carquet_writer_create_file(). Memory mapping
 * is the exception: carquet maps from a path, so a mapped read of a path the
 * code page cannot express falls back to buffered I/O rather than failing.
 *
 * A resolved path holds every form up front because the writer's cleanup runs
 * during an unwind, where calling back into R to translate a string could
 * longjmp again. Resolve while it is still safe to raise an error; use the
 * result anywhere. */
typedef struct {
    const char *display; /* UTF-8, for messages */
    const char *native;  /* fopen()/remove() bytes; lossy on Windows */
#ifdef _WIN32
    const wchar_t *wide; /* what _wfopen()/_wremove() take */
    int native_ok;       /* whether `native` round-trips through the code page */
#endif
} qio_path_t;

/* Resolve a path from R. Calls R APIs, so it must run before entering any
 * window that must not longjmp, and it raises an R error if the string cannot
 * be translated. Memory belongs to R's vmax stack. */
void qio_path_resolve(SEXP path_sexp, qio_path_t *path);

/* fopen()/remove() equivalents that do not lose the path on Windows. */
FILE *qio_path_fopen(const qio_path_t *path, const char *mode);
int qio_path_remove(const qio_path_t *path);

/* Whether carquet's own path-based entry points can open this path. False
 * only on Windows, and only for a path the active code page cannot represent.
 * `native` is meaningful exactly when this is true. */
int qio_path_opens_natively(const qio_path_t *path);

#endif
