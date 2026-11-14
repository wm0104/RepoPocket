#include "DebCodecs.h"
#include "xz/xz.h"
#define ZSTD_STATIC_LINKING_ONLY
#include "zstd/zstd.h"
int rpp_decode(int format, const void *src, size_t length, void *dst, size_t capacity, size_t *written) {
    *written = 0;
    if (format == 1) {
        xz_crc32_init(); xz_crc64_init();
        struct xz_dec *s = xz_dec_init(XZ_DYNALLOC, 32U * 1024U * 1024U);
        if (!s) return -1;
        struct xz_buf b = {0}; b.in = src; b.in_size = length; b.out = dst; b.out_size = capacity;
        enum xz_ret r = xz_dec_run(s, &b);
        xz_dec_end(s);
        if (r != XZ_STREAM_END || b.in_pos != length) return -1;
        *written = b.out_pos; return 0;
    }
    if (format == 2) {
        size_t frame = ZSTD_findFrameCompressedSize(src, length);
        if (ZSTD_isError(frame) || frame != length) return -1;
        ZSTD_DCtx *s = ZSTD_createDCtx(); if (!s) return -1;
        size_t r = ZSTD_DCtx_setParameter(s, ZSTD_d_windowLogMax, 25);
        ZSTD_inBuffer in = {src, length, 0}; ZSTD_outBuffer out = {dst, capacity, 0};
        if (!ZSTD_isError(r)) {
            do { size_t before = in.pos; r = ZSTD_decompressStream(s, &out, &in);
                if (ZSTD_isError(r) || (r && (out.pos == capacity || in.pos == before))) break;
            } while (r);
        }
        ZSTD_freeDCtx(s);
        if (ZSTD_isError(r) || r != 0 || in.pos != length) return -1;
        *written = out.pos; return 0;
    }
    return -1;
}
