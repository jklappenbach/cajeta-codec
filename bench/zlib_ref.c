/*
 * Raw-zlib reference benchmark for Unit 6 (native-vs-zlib perf gate).
 *
 * Compresses/inflates the SAME 128 KiB payload the cajeta CompressBench uses
 * (identical word dictionary + xorshift64 order + seed), through zlib's one-shot
 * raw-DEFLATE path (windowBits -15) at levels 1/6/9, and reports MB/s — so the
 * cajeta native backend (which wraps this very library) can be compared to the
 * library alone on the same machine. The gate: native >= 0.8x these numbers.
 *
 * Build against the vendored zlib:
 *   cc -O3 -DNDEBUG -Inative/zlib bench/zlib_ref.c native/<plat>/libcajeta_zlib.a -o zref
 */
#include "zlib.h"
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static const char *WORDS[32] = {
    "the ", "quick ", "brown ", "fox ", "jumps ", "over ", "a ", "lazy ",
    "dog ", "while ", "counting ", "numbers ", "and ", "letters ", "in ",
    "streams ", "of ", "data ", "that ", "compresses ", "well ", "like ",
    "real ", "text. ", "json ", "html ", "content ", "here ", "now ", "then ",
    "again ", "yes "
};

/* Byte-identical to CompressBench.payload(). */
static void gen_payload(unsigned char *p, int n) {
    uint64_t st = 0x243F6A8885A308D3ULL;
    int off = 0;
    while (off < n) {
        st ^= st << 13;
        st ^= st >> 7;
        st ^= st << 17;
        int wi = (int) ((st >> 40) & 31);
        const char *w = WORDS[wi];
        int wl = (int) strlen(w);
        for (int j = 0; j < wl && off < n; j++) { p[off++] = (unsigned char) w[j]; }
    }
}

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double) ts.tv_sec + (double) ts.tv_nsec / 1e9;
}

static long comp_raw(const unsigned char *src, int n, unsigned char *dst, int cap,
                     int level) {
    z_stream s;
    memset(&s, 0, sizeof s);
    if (deflateInit2(&s, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        return -1;
    }
    s.next_in = (unsigned char *) src; s.avail_in = (unsigned) n;
    s.next_out = dst; s.avail_out = (unsigned) cap;
    int rc = deflate(&s, Z_FINISH);
    long out = (long) s.total_out;
    deflateEnd(&s);
    return rc == Z_STREAM_END ? out : -1;
}

static long uncomp_raw(const unsigned char *src, int n, unsigned char *dst, int cap) {
    z_stream s;
    memset(&s, 0, sizeof s);
    if (inflateInit2(&s, -15) != Z_OK) { return -1; }
    s.next_in = (unsigned char *) src; s.avail_in = (unsigned) n;
    s.next_out = dst; s.avail_out = (unsigned) cap;
    int rc = inflate(&s, Z_FINISH);
    long out = (long) s.total_out;
    inflateEnd(&s);
    return rc == Z_STREAM_END ? out : -1;
}

int main(void) {
    int sz = 131072, iters = 200;
    unsigned char *data = malloc(sz);
    unsigned char *cbuf = malloc((size_t) sz * 2 + 64);
    unsigned char *dbuf = malloc((size_t) sz + 64);
    gen_payload(data, sz);

    printf("payload=%d bytes (raw zlib reference, iters=%d)\n", sz, iters);

    int levels[3] = {1, 6, 9};
    for (int i = 0; i < 3; i++) {
        int L = levels[i];
        long cl = comp_raw(data, sz, cbuf, sz * 2 + 64, L);
        double t0 = now_s();
        for (int k = 0; k < iters; k++) { comp_raw(data, sz, cbuf, sz * 2 + 64, L); }
        double dt = now_s() - t0;
        double mbps = (double) sz * iters / (dt * 1048576.0);
        printf("  COMPRESS L%d      : %.1f MB/s  (%ld bytes, %ld%%)\n",
               L, mbps, cl, cl * 100 / sz);
    }

    long cl6 = comp_raw(data, sz, cbuf, sz * 2 + 64, 6);
    double t0 = now_s();
    for (int k = 0; k < iters; k++) { uncomp_raw(cbuf, (int) cl6, dbuf, sz + 64); }
    double dt = now_s() - t0;
    printf("  INFLATE one-shot : %.1f MB/s\n",
           (double) sz * iters / (dt * 1048576.0));

    free(data); free(cbuf); free(dbuf);
    return 0;
}
