/* Differential test for qio's UTF-8 validator.
 *
 *   cc -O2 -o /tmp/utf8-differential tools/utf8-validation-differential.c
 *   /tmp/utf8-differential
 *
 * qio rejects invalid UTF-8 and reports the offset of the first bad byte;
 * Rf_mkCharLenCE(CE_UTF8) does no checking, so this is the only thing standing
 * between a byte column mislabelled as text and CHARSXPs that lie about their
 * encoding. The validator in src/qio_file.c gained a word-at-a-time skip over
 * ASCII runs, and an accelerated validator that accepts one invalid sequence
 * is worse than a slow one.
 *
 * This compares it against the exact byte-at-a-time algorithm it replaced,
 * over random inputs spliced with adversarial sequences: overlong forms,
 * surrogate halves, values above U+10FFFF, truncated sequences and stray
 * continuation bytes. Both implementations are copied here rather than linked,
 * so the reference cannot drift when qio changes.
 *
 * Not part of R CMD check; run it by hand when touching the validator. */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static int64_t reference(const uint8_t *bytes, int32_t length) {
    int32_t i = 0;
    while (i < length) {
        uint8_t byte = bytes[i]; int32_t extra; uint32_t code;
        if (byte < 0x80) { i++; continue; }
        else if ((byte & 0xE0) == 0xC0) { extra = 1; code = byte & 0x1Fu; }
        else if ((byte & 0xF0) == 0xE0) { extra = 2; code = byte & 0x0Fu; }
        else if ((byte & 0xF8) == 0xF0) { extra = 3; code = byte & 0x07u; }
        else return (int64_t)i + 1;
        if (i + extra >= length) return (int64_t)i + 1;
        for (int32_t k = 1; k <= extra; k++) {
            uint8_t cont = bytes[i + k];
            if ((cont & 0xC0) != 0x80) return (int64_t)i + 1;
            code = (code << 6) | (uint32_t)(cont & 0x3Fu);
        }
        if ((extra == 1 && code < 0x80u) || (extra == 2 && code < 0x800u) ||
            (extra == 3 && code < 0x10000u)) return (int64_t)i + 1;
        if (code > 0x10FFFFu || (code >= 0xD800u && code <= 0xDFFFu)) return (int64_t)i + 1;
        i += extra + 1;
    }
    return 0;
}

#define QIO_ASCII_HIGH_BITS 0x8080808080808080ULL
static int32_t qio_skip_ascii(const uint8_t *bytes, int32_t length, int32_t i) {
    while (length - i >= 8) {
        uint64_t word; memcpy(&word, bytes + i, sizeof(word));
        if (word & QIO_ASCII_HIGH_BITS) break;
        i += 8;
    }
    return i;
}
static int64_t accelerated(const uint8_t *bytes, int32_t length) {
    int32_t i = 0;
    while (i < length) {
        i = qio_skip_ascii(bytes, length, i);
        if (i >= length) break;
        uint8_t byte = bytes[i]; int32_t extra; uint32_t code;
        if (byte < 0x80) { i++; continue; }
        else if ((byte & 0xE0) == 0xC0) { extra = 1; code = byte & 0x1Fu; }
        else if ((byte & 0xF0) == 0xE0) { extra = 2; code = byte & 0x0Fu; }
        else if ((byte & 0xF8) == 0xF0) { extra = 3; code = byte & 0x07u; }
        else return (int64_t)i + 1;
        if (i + extra >= length) return (int64_t)i + 1;
        for (int32_t k = 1; k <= extra; k++) {
            uint8_t cont = bytes[i + k];
            if ((cont & 0xC0) != 0x80) return (int64_t)i + 1;
            code = (code << 6) | (uint32_t)(cont & 0x3Fu);
        }
        if ((extra == 1 && code < 0x80u) || (extra == 2 && code < 0x800u) ||
            (extra == 3 && code < 0x10000u)) return (int64_t)i + 1;
        if (code > 0x10FFFFu || (code >= 0xD800u && code <= 0xDFFFu)) return (int64_t)i + 1;
        i += extra + 1;
    }
    return 0;
}

int main(void) {
    srand(20260802);
    long long checked = 0, bad = 0;
    uint8_t buf[512];
    /* Adversarial seeds: overlong forms, surrogate halves, above U+10FFFF,
     * truncated sequences, lone continuations. */
    const char *seeds[] = {
        "\xC0\x80", "\xE0\x80\x80", "\xF0\x80\x80\x80",      /* overlong */
        "\xED\xA0\x80", "\xED\xBF\xBF",                       /* surrogates */
        "\xF4\x90\x80\x80", "\xF7\xBF\xBF\xBF",               /* > U+10FFFF */
        "\xE2\x82", "\xF0\x9F\x98",                           /* truncated */
        "\x80", "\xBF", "\xFE", "\xFF",                       /* stray */
        "\xC3\xA9", "\xE2\x82\xAC", "\xF0\x9F\x98\x80",       /* valid */
    };
    int nseeds = (int)(sizeof(seeds)/sizeof(seeds[0]));
    for (int trial = 0; trial < 3000000; trial++) {
        int len = rand() % 200;
        int mode = rand() % 3;
        for (int i = 0; i < len; i++) {
            if (mode == 0) buf[i] = (uint8_t)(rand() % 128);          /* ASCII */
            else if (mode == 1) buf[i] = (uint8_t)(rand() & 0xFF);    /* random */
            else buf[i] = (uint8_t)((rand() % 2) ? (rand() % 128) : (rand() & 0xFF));
        }
        /* Splice an adversarial sequence at a random offset. */
        if (len > 8 && (rand() % 2)) {
            const char *s = seeds[rand() % nseeds];
            int sl = (int)strlen(s), at = rand() % (len - sl > 0 ? len - sl : 1);
            if (at + sl <= len) memcpy(buf + at, s, (size_t)sl);
        }
        int64_t a = reference(buf, len), b = accelerated(buf, len);
        checked++;
        if (a != b) { if (bad++ < 5) printf("MISMATCH len=%d ref=%lld acc=%lld\n", len, (long long)a, (long long)b); }
    }
    printf("compared %lld strings: %lld mismatches\n", checked, bad);
    return bad != 0;
}
