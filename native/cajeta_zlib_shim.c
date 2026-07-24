/*
 * Cajeta <-> zlib shim — the C boundary between dev.cajeta.codec's native
 * backend and the vendored zlib (native/zlib/).
 *
 * ABI note: a cajeta `int8[]` is passed to an @Native method as a pointer to
 * its header, laid out as { int64 count; int8 data[count]; } — so the element
 * bytes begin 8 bytes past the header pointer. Each wrapper takes flat buffers
 * only; no zlib `z_stream` struct crosses the FFI boundary.
 *
 * Wrapper selection follows zlib's `windowBits` convention (deflateInit2 /
 * inflateInit2):
 *     -15  raw DEFLATE (RFC 1951)
 *      15  zlib        (RFC 1950)
 *      31  gzip        (RFC 1952, 15 + 16)
 *
 * On success the compress/uncompress wrappers return the byte length written to
 * `dst`; on failure they return a zlib `Z_*` error code (always negative). The
 * caller distinguishes Z_BUF_ERROR (-5, "dst too small — grow and retry") from
 * the terminal errors.
 *
 * These symbols are bound from `dev.cajeta.codec.compress.NativeZlib` via
 * @Native(symbol=..., lib="cajeta_zlib"). Built into libcajeta_zlib.a by
 * native/build.sh.
 */
#include "zlib.h"
#include <stdint.h>

#define CJ_DATA(hdr) (((const unsigned char *)(hdr)) + 8)
#define CJ_MUT(hdr)  (((unsigned char *)(hdr)) + 8)

/* CRC-32 (RFC 1952) of the first `len` bytes of the cajeta int8[] `data_hdr`. */
int32_t __cajeta_zlib_crc32(const void *data_hdr, int64_t len) {
    return (int32_t) crc32(0UL, CJ_DATA(data_hdr), (uInt) len);
}

/* Adler-32 (RFC 1950) of the first `len` bytes. */
int32_t __cajeta_zlib_adler32(const void *data_hdr, int64_t len) {
    return (int32_t) adler32(1UL, CJ_DATA(data_hdr), (uInt) len);
}

/*
 * Worst-case compressed size for `srclen` bytes at the given wrapper, so the
 * caller can size `dst` in one shot. deflateBound accounts for the wrapper's
 * header/trailer (gzip's is larger than zlib's).
 */
int64_t __cajeta_zlib_compress_bound(int64_t srclen, int32_t wbits) {
    z_stream s;
    s.zalloc = Z_NULL; s.zfree = Z_NULL; s.opaque = Z_NULL;
    if (deflateInit2(&s, Z_BEST_COMPRESSION, Z_DEFLATED, wbits, 8,
                     Z_DEFAULT_STRATEGY) != Z_OK) {
        /* Generous fallback bound (zlib's classic formula + gzip slack). */
        return srclen + (srclen >> 10) + 64;
    }
    uLong b = deflateBound(&s, (uLong) srclen);
    deflateEnd(&s);
    return (int64_t) b;
}

/*
 * One-shot compress. Deflates `src[0..srclen)` into `dst[0..dstcap)` at `level`
 * (1..9, or Z_DEFAULT_COMPRESSION == -1) using the `wbits`-selected wrapper.
 * Returns the number of bytes written, or a negative Z_* code on failure
 * (Z_BUF_ERROR if `dstcap` was too small).
 */
int64_t __cajeta_zlib_compress(void *dst_hdr, int64_t dstcap,
                               const void *src_hdr, int64_t srclen,
                               int32_t level, int32_t wbits) {
    z_stream s;
    s.zalloc = Z_NULL; s.zfree = Z_NULL; s.opaque = Z_NULL;
    int rc = deflateInit2(&s, level, Z_DEFLATED, wbits, 8, Z_DEFAULT_STRATEGY);
    if (rc != Z_OK) { return (int64_t) rc; }

    s.next_in = (Bytef *) CJ_DATA(src_hdr);
    s.avail_in = (uInt) srclen;
    s.next_out = (Bytef *) CJ_MUT(dst_hdr);
    s.avail_out = (uInt) dstcap;

    rc = deflate(&s, Z_FINISH);
    if (rc != Z_STREAM_END) {
        deflateEnd(&s);
        /* Didn't finish in one shot => dst too small. */
        return (int64_t) (rc == Z_OK ? Z_BUF_ERROR : rc);
    }
    int64_t produced = (int64_t) s.total_out;
    deflateEnd(&s);
    return produced;
}

/*
 * One-shot inflate. Inflates `src[0..srclen)` into `dst[0..dstcap)` using the
 * `wbits`-selected wrapper (checksums verified natively). Returns the number of
 * bytes written, or a negative Z_* code:
 *   Z_BUF_ERROR (-5)  — dst filled but stream not done: caller grows + retries.
 *   Z_DATA_ERROR (-3) — corrupt or truncated input (or checksum mismatch).
 */
int64_t __cajeta_zlib_uncompress(void *dst_hdr, int64_t dstcap,
                                 const void *src_hdr, int64_t srclen,
                                 int32_t wbits) {
    z_stream s;
    s.zalloc = Z_NULL; s.zfree = Z_NULL; s.opaque = Z_NULL;
    s.next_in = Z_NULL; s.avail_in = 0;
    int rc = inflateInit2(&s, wbits);
    if (rc != Z_OK) { return (int64_t) rc; }

    s.next_in = (Bytef *) CJ_DATA(src_hdr);
    s.avail_in = (uInt) srclen;
    s.next_out = (Bytef *) CJ_MUT(dst_hdr);
    s.avail_out = (uInt) dstcap;

    rc = inflate(&s, Z_FINISH);
    int64_t produced = (int64_t) s.total_out;
    if (rc == Z_STREAM_END) {
        /*
         * Strict framing: the codec's hardening contract (cajeta-http 1.6a)
         * requires the claimed input to be fully consumed — trailing bytes
         * inside `srclen` are corruption, not a second member. zlib itself
         * stops at STREAM_END and ignores them, so reject leftover input here.
         */
        uInt leftover = s.avail_in;
        inflateEnd(&s);
        if (leftover != 0) { return (int64_t) Z_DATA_ERROR; }
        return produced;
    }
    /* Not finished. Filled the whole output => need a bigger buffer. */
    if (s.avail_out == 0) {
        inflateEnd(&s);
        return (int64_t) Z_BUF_ERROR;
    }
    inflateEnd(&s);
    /* Room was left but the stream didn't end => corrupt/truncated input. */
    if (rc == Z_OK || rc == Z_BUF_ERROR) { return (int64_t) Z_DATA_ERROR; }
    return (int64_t) rc;
}
