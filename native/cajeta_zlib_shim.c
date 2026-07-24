/*
 * Cajeta <-> zlib shim — the C boundary between dev.cajeta.codec's native
 * backend and the vendored zlib (native/zlib/).
 *
 * ABI note: a cajeta `int8[]` is passed to an @Native method as a pointer to
 * its header, laid out as { int64 count; int8 data[count]; } — so the element
 * bytes begin 8 bytes past the header pointer. Each wrapper takes flat buffers
 * only; no zlib `z_stream` struct crosses the FFI boundary.
 *
 * These symbols are bound from `dev.cajeta.codec.compress.NativeZlib` via
 * @Native(symbol=..., lib="cajeta_zlib"). Built into libcajeta_zlib.a by
 * native/build.sh.
 */
#include "zlib.h"
#include <stdint.h>

#define CJ_DATA(hdr) (((const unsigned char *)(hdr)) + 8)

/* CRC-32 (RFC 1952) of the first `len` bytes of the cajeta int8[] `data_hdr`. */
int32_t __cajeta_zlib_crc32(const void *data_hdr, int64_t len) {
    return (int32_t) crc32(0UL, CJ_DATA(data_hdr), (uInt) len);
}
