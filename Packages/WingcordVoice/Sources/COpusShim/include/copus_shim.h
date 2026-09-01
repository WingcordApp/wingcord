// The five calls Swift cannot make for itself.
//
// `opus_encoder_ctl` and `opus_decoder_ctl` are C variadics, and Swift can only
// call a variadic C function that also publishes a `va_list` form. Opus
// publishes none, so the alternative to these twenty lines is reaching for
// `dlsym` or hand-rolling the calling convention — both of which are ways of
// pretending the shim is not there.
//
// Every setter in `opus_defines.h` takes exactly one `opus_int32` and every
// getter returns one through a pointer, so two functions cover the whole
// surface this app uses.
#ifndef WINGCORD_COPUS_SHIM_H
#define WINGCORD_COPUS_SHIM_H

#include <opus.h>

/// `opus_encoder_ctl(st, request, value)` for any request taking one int.
int wc_opus_encoder_set(OpusEncoder *st, int request, opus_int32 value);

/// `opus_encoder_ctl(st, request, &out)` for any request returning one int.
int wc_opus_encoder_get(OpusEncoder *st, int request, opus_int32 *out);

/// `opus_decoder_ctl(st, request, value)`.
int wc_opus_decoder_set(OpusDecoder *st, int request, opus_int32 value);

/// `opus_decoder_ctl(st, request, &out)`.
int wc_opus_decoder_get(OpusDecoder *st, int request, opus_int32 *out);

#endif
