//===- StreamCodec.hpp - Codec state of Codec-kind stream pairs -----------===//
//
// plans/eco-system-library.md §3.5 (UTF-8 rules) and Phase 6 step 6.2.
// The transformation engines behind `Stream.textEncoder`, `textDecoder`
// and the six compression constructors. They work on plain C++ data only:
// pump() copies each input out of the heap first, runs the codec, and only
// then allocates the outputs (G3). Nothing here touches the Elm heap.
//
//   * Zlib       — deflateInit2 / inflateInit2 with windowBits 31 (gzip),
//                  15 (zlib "deflate") or -15 (raw deflate); output chunks
//                  of at most 64 KiB; Z_FINISH when the writable closes.
//                  Decompression fails on corrupt input, on data after the
//                  end of the compressed stream, and on a close before it.
//   * TextEncode — UTF-16 String units → UTF-8 bytes. A high surrogate at
//                  the end of a chunk is carried into the next one; lone
//                  surrogates become U+FFFD (WHATWG TextEncoderStream).
//   * TextDecode — UTF-8 bytes → String, the lenient WHATWG decoder: one
//                  U+FFFD per maximal invalid subpart, incomplete sequences
//                  carried across chunks (U+FFFD if still open at close),
//                  a leading BOM stripped.
//
// Every engine produces zero or more output chunks per input; empty
// outputs are never emitted.
//
// Templates used: none (no heap access).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_STREAM_STREAM_CODEC_HPP
#define ECO_SYSTEM_STREAM_STREAM_CODEC_HPP

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace Eco::System {

struct CodecState;

struct CodecDeleter {
    void operator()(CodecState* c) const;
};

using CodecPtr = std::unique_ptr<CodecState, CodecDeleter>;

// Compression algorithms (B.2 `compressor`/`decompressor` argument).
constexpr int kCodecGzip = 0;
constexpr int kCodecDeflate = 1;
constexpr int kCodecDeflateRaw = 2;

// Throws std::runtime_error if zlib cannot be initialised.
CodecPtr newZlibCodec(bool compress, int algorithm);
CodecPtr newTextEncoder();
CodecPtr newTextDecoder();

// Input values are Strings (true: textEncoder) or Bytes (false).
bool codecTakesString(const CodecState& c);
// Output values are Strings (true: textDecoder) or Bytes (false).
bool codecMakesString(const CodecState& c);

// Transforms one input chunk. Exactly one of `bytes` / `units` is used,
// per codecTakesString. Appends the outputs (Bytes, or UTF-8 text for a
// String output) to `out`. Returns an empty string on success, otherwise
// the error reason (the codec is then unusable).
std::string codecTransform(CodecState& c, const std::string& bytes,
                           const std::u16string& units,
                           std::vector<std::string>& out);

// Flushes at close (Z_FINISH, carried surrogate / partial sequence).
// Appends the final outputs to `out`. Returns "" or the error reason.
std::string codecFlush(CodecState& c, std::vector<std::string>& out);

} // namespace Eco::System

#endif // ECO_SYSTEM_STREAM_STREAM_CODEC_HPP
