#include "include/copus_shim.h"

int wc_opus_encoder_set(OpusEncoder *st, int request, opus_int32 value) {
    return opus_encoder_ctl(st, request, value);
}

int wc_opus_encoder_get(OpusEncoder *st, int request, opus_int32 *out) {
    return opus_encoder_ctl(st, request, out);
}

int wc_opus_decoder_set(OpusDecoder *st, int request, opus_int32 value) {
    return opus_decoder_ctl(st, request, value);
}

int wc_opus_decoder_get(OpusDecoder *st, int request, opus_int32 *out) {
    return opus_decoder_ctl(st, request, out);
}
