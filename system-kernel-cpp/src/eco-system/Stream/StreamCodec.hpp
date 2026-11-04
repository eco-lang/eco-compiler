//===- StreamCodec.hpp - Codec state of Codec-kind stream pairs -----------===//
//
// A codec stream turns each chunk written into it into zero or more chunks to be
// read out, and some of those transformations keep state from one chunk to the
// next. This component is that state and the engines that advance it.
//
// There are three engines, and a codec is one of four kinds: a compressor, a
// decompressor, a text encoder or a text decoder.
//
//   * Compression uses zlib in one of three formats, chosen by `kCodecGzip`,
//     `kCodecDeflate` (the zlib format) or `kCodecDeflateRaw`. Each output chunk
//     is at most 64 KiB. Decompression fails on corrupt input, on any data after
//     the end of the compressed stream, and on a flush before that end.
//   * The text encoder turns UTF-16 code units into UTF-8 bytes. A high
//     surrogate at the end of a chunk is carried into the next one, and a
//     surrogate with no partner becomes U+FFFD.
//   * The text decoder turns UTF-8 bytes into text, leniently, in the manner of
//     the WHATWG UTF-8 decoder: each maximal invalid subsequence becomes one
//     U+FFFD, a sequence cut by a chunk boundary is completed from the next
//     chunk, and a byte order mark at the very start is dropped.
//
// Because a chunk can end partway through something, every codec has a final
// step, the flush, run once no more input will come: it finishes the zlib
// stream, or turns a carried surrogate or an unfinished UTF-8 sequence into
// U+FFFD.
//
// Everything here works on ordinary C++ strings and never touches the Elm heap,
// so inputs must be copied out of the heap before a call, and heap values built
// from the outputs after it. No engine appends an empty output chunk.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_STREAM_STREAM_CODEC_HPP
#define ECO_SYSTEM_STREAM_STREAM_CODEC_HPP

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace Eco::System {

/// The state of one codec: its kind and whatever it carries between chunks.
///
/// The type is opaque here. A codec is made by `newZlibCodec`, `newTextEncoder`
/// or `newTextDecoder`, and used only through the functions below. Nothing in it
/// is synchronised, so one codec must not be used from two threads at once.
struct CodecState;

/// The deleter of a `CodecPtr`, which destroys the codec and releases any zlib
/// stream it holds.
struct CodecDeleter {
    /// Destroys `c`, which must have come from one of the `new*` functions
    /// below.
    void operator()(CodecState* c) const;
};

/// Sole ownership of a codec. The codec is never moved in memory, so a
/// `CodecPtr` can itself be moved freely.
using CodecPtr = std::unique_ptr<CodecState, CodecDeleter>;

/// The `algorithm` value of `newZlibCodec` for the gzip format.
constexpr int kCodecGzip = 0;
/// The `algorithm` value of `newZlibCodec` for the zlib format.
constexpr int kCodecDeflate = 1;
/// The `algorithm` value of `newZlibCodec` for raw deflate data, with neither
/// header nor checksum.
constexpr int kCodecDeflateRaw = 2;

/// Creates a compressor (`compress` true) or decompressor for the format that
/// `algorithm` names. Any value other than `kCodecGzip` and `kCodecDeflate` is
/// taken as `kCodecDeflateRaw`. A gzip decompressor accepts only gzip data.
///
/// Compression uses zlib's default level. Throws `std::runtime_error` if zlib
/// cannot set up the stream.
CodecPtr newZlibCodec(bool compress, int algorithm);
/// Creates a text encoder, which turns UTF-16 code units into UTF-8 bytes.
CodecPtr newTextEncoder();
/// Creates a text decoder, which turns UTF-8 bytes into text.
CodecPtr newTextDecoder();

/// Returns whether `c` takes its input as UTF-16 code units (a text encoder)
/// rather than as bytes (every other kind).
bool codecTakesString(const CodecState& c);
/// Returns whether `c`'s outputs are text (a text decoder, whose output strings
/// hold UTF-8) rather than bytes (every other kind).
bool codecMakesString(const CodecState& c);

/// Feeds one input chunk to `c` and appends any outputs it produces to `out`.
///
/// A text encoder reads `units` and ignores `bytes`; every other kind reads
/// `bytes` and ignores `units`. An empty chunk produces no output.
///
/// Returns an empty string on success, or otherwise the reason for the failure.
/// Only a zlib codec fails. Once one has failed, every later call to it, and
/// to `codecFlush`, returns "The compression stream has failed.". Outputs
/// from earlier passes within the same call are still appended; output from
/// the pass that failed is dropped.
std::string codecTransform(CodecState& c, const std::string& bytes,
                           const std::u16string& units,
                           std::vector<std::string>& out);

/// Runs `c`'s final step, the flush, and appends any last outputs to `out`.
///
/// A compressor writes the end of its compressed stream. A decompressor
/// produces nothing, and fails if it has not seen the end of the compressed
/// stream. A text encoder turns a carried high surrogate into U+FFFD, and a text
/// decoder does the same with an unfinished UTF-8 sequence. Returns an empty
/// string on success or the reason for the failure, as `codecTransform` does.
std::string codecFlush(CodecState& c, std::vector<std::string>& out);

} // namespace Eco::System

#endif // ECO_SYSTEM_STREAM_STREAM_CODEC_HPP
