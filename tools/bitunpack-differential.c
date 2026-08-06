/* Differential test for carquet's general-case bit unpacker.
 *
 *   cc -O2 -o /tmp/bitunpack-differential tools/bitunpack-differential.c
 *   /tmp/bitunpack-differential
 *
 * Widths 1-8 and 16 have specialized or SIMD kernels; every other width goes
 * through the general case in src/carquet/core/bitpack.c. That case was
 * rewritten from a byte-at-a-time extraction loop to a 64-bit accumulator, and
 * a bit unpacker that is wrong for one width and one alignment would corrupt
 * dictionary indices into plausible neighbouring values rather than failing.
 *
 * This compares the accumulator against the exact algorithm it replaced, over
 * random inputs at every width 9..32. Both are copied here rather than linked:
 * the point is to pin the new one against the old behaviour, so the reference
 * must not change when carquet does.
 *
 * Not part of R CMD check; run it by hand when touching the unpacker. */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static void reference(const uint8_t* input, int bit_width, uint32_t* values) {
    uint32_t mask = (uint32_t)((1ULL << bit_width) - 1);
    int bit_pos = 0, byte_pos = 0;
    for (int i = 0; i < 8; i++) {
        uint64_t bits = 0; int bits_needed = bit_width, bits_in_buffer = 0;
        while (bits_needed > 0) {
            int bits_from_byte = 8 - (bit_pos % 8);
            if (bits_from_byte > bits_needed) bits_from_byte = bits_needed;
            uint8_t byte_val = input[byte_pos];
            int shift_down = bit_pos % 8;
            uint64_t extracted = (byte_val >> shift_down) & ((1U << bits_from_byte) - 1);
            bits |= extracted << bits_in_buffer;
            bit_pos += bits_from_byte; bits_in_buffer += bits_from_byte;
            bits_needed -= bits_from_byte;
            if (bit_pos % 8 == 0) byte_pos++;
        }
        values[i] = (uint32_t)(bits & mask);
    }
}

static void accumulator(const uint8_t* input, int bit_width, uint32_t* values) {
    uint32_t mask = (uint32_t)((1ULL << bit_width) - 1);
    uint64_t acc = 0; int bits_held = 0, byte_pos = 0;
    for (int i = 0; i < 8; i++) {
        while (bits_held < bit_width) {
            acc |= (uint64_t)input[byte_pos++] << bits_held;
            bits_held += 8;
        }
        values[i] = (uint32_t)(acc & mask);
        acc >>= bit_width; bits_held -= bit_width;
    }
}

int main(void) {
    srand(20260802);
    long long checked = 0, bad = 0;
    for (int bw = 9; bw <= 32; bw++) {
        for (int trial = 0; trial < 200000; trial++) {
            uint8_t in[40];
            for (int i = 0; i < bw; i++) in[i] = (uint8_t)(rand() & 0xFF);
            uint32_t a[8], b[8];
            reference(in, bw, a);
            accumulator(in, bw, b);
            checked++;
            if (memcmp(a, b, sizeof(a)) != 0) {
                if (bad++ < 3) {
                    printf("MISMATCH bw=%d:\n", bw);
                    for (int i = 0; i < 8; i++)
                        printf("  [%d] ref=%u acc=%u\n", i, a[i], b[i]);
                }
            }
        }
    }
    printf("compared %lld unpacks across widths 9-32: %lld mismatches\n", checked, bad);
    return bad != 0;
}
