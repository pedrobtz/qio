#include "qio_path.h"

#include <R.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#include <wchar.h>

/* UTF-8 to UTF-16 through R's vmax stack, so the result lives until the
 * enclosing .Call() returns and nothing has to free it on an unwind. */
static const wchar_t *qio_widen(const char *utf8) {
    int wide_len = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    if (wide_len <= 0) {
        Rf_error("qio: cannot convert the file path to UTF-16");
    }
    wchar_t *wide = (wchar_t *)R_alloc((size_t)wide_len, sizeof(wchar_t));
    if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, wide_len) != wide_len) {
        Rf_error("qio: cannot convert the file path to UTF-16");
    }
    return wide;
}

/* Whether the path survives a round trip through the active code page, which
 * is what decides if carquet's own fopen() can still find the file.
 *
 * WC_NO_BEST_FIT_CHARS makes the conversion report a substitution rather than
 * quietly approximating; it is rejected outright when the code page is UTF-8,
 * where nothing needs substituting anyway. */
static int qio_fits_code_page(const wchar_t *wide) {
    if (GetACP() == CP_UTF8) {
        return 1;
    }
    int len = WideCharToMultiByte(CP_ACP, 0, wide, -1, NULL, 0, NULL, NULL);
    if (len <= 0) {
        return 0;
    }
    char *buffer = (char *)R_alloc((size_t)len, 1);
    BOOL substituted = FALSE;
    if (WideCharToMultiByte(CP_ACP, WC_NO_BEST_FIT_CHARS, wide, -1, buffer,
                            len, NULL, &substituted) != len) {
        return 0;
    }
    return !substituted;
}
#endif

void qio_path_resolve(SEXP path_sexp, qio_path_t *path) {
    if (TYPEOF(path_sexp) != STRSXP || LENGTH(path_sexp) < 1) {
        Rf_error("qio: `file` must be a single file path");
    }
    SEXP element = STRING_ELT(path_sexp, 0);
    if (element == NA_STRING) {
        Rf_error("qio: `file` must not be NA");
    }

    memset(path, 0, sizeof(*path));
    path->display = Rf_translateCharUTF8(element);
    path->native = Rf_translateChar(element);
#ifdef _WIN32
    path->wide = qio_widen(path->display);
    path->native_ok = qio_fits_code_page(path->wide);
#endif
}

FILE *qio_path_fopen(const qio_path_t *path, const char *mode) {
#ifdef _WIN32
    wchar_t wide_mode[8];
    size_t i = 0;
    for (; mode[i] != '\0' && i < (sizeof(wide_mode) / sizeof(wide_mode[0])) - 1;
         i++) {
        wide_mode[i] = (wchar_t)mode[i];
    }
    wide_mode[i] = L'\0';
    return _wfopen(path->wide, wide_mode);
#else
    return fopen(path->native, mode);
#endif
}

int qio_path_remove(const qio_path_t *path) {
#ifdef _WIN32
    return _wremove(path->wide);
#else
    return remove(path->native);
#endif
}

int qio_path_opens_natively(const qio_path_t *path) {
#ifdef _WIN32
    return path->native_ok;
#else
    (void)path;
    return 1;
#endif
}
