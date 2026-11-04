//===- StreamExports.cpp - C exports of Eco.Kernel.Stream -----------------===//
//
// The C-linkage functions that compiled Elm code calls for the `Eco.Kernel.Stream` kernels. Each one runs
// inside `ECO_KERNEL_GUARD`, so a C++ exception is reported as fatal rather than unwinding into Elm frames.
//
// Apart from the two pure conversions at the end, an export does no stream work itself. It roots its boxed
// arguments, packs them into one heap payload, and returns a Task binding whose body (in Stream.cpp or
// StreamPipe.cpp) receives the payload and acts on the stream table each time the Task runs. A binding made
// with `makeAsyncBinding` may park the task until the stream can answer. The payloads, with their kind masks
// (2 bits per slot: 0 boxed, 1 Int):
//   identity                tuple2( Int readCap, Int writeCap )                    mask 0x5
//   custom                  tuple2( tuple2( fn, state ) mask 0,
//                                   tuple2( Int readCap, Int writeCap ) mask 0x5 ) mask 0
//   textEncoder,
//   textDecoder             ()
//   compressor,
//   decompressor            boxed Int algorithm (0 gzip, 1 deflate, 2 raw deflate)
//   pipeThrough             tuple2( Int transformation, Int readable )             mask 0x5
//   pipeTo                  tuple2( Int writable, Int readable )                   mask 0x5
//   read, readChunk,
//   closeWritable           boxed Int id
//   carryLine               tuple2( Int atEnd, Int id ), atEnd 0 or 1               mask 0x5
//   carryAppend             tuple2( Bytes, Int id )                                mask 0x4
//   write, enqueue          tuple2( value, Int id )                                mask 0x4
//   cancelReadable,
//   cancelWritable          tuple2( String reason, Int id )                        mask 0x4
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/Core.hpp"
#include "eco-system/Stream/StreamTable.hpp"

#include <cstring>
#include <string>

using namespace Eco::System;

extern "C" {

// Returns a Task that creates an Identity pair with capacities `readCap` and `writeCap` and succeeds with its
// id. Elm type: identity : Int -> Int -> Task Never Int.
uint64_t Eco_Kernel_Stream_identity(int64_t readCap, int64_t writeCap) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::tuple2(alloc::unboxedInt(readCap),
                                         alloc::unboxedInt(writeCap), 0x5);
        return enc(makeBinding<streamIdentityBody>(payload));
    )
}

// Returns a Task that creates a Custom pair over the Elm closure `action`, starting from `state`, and succeeds
// with its id. Elm type: custom : (s -> a -> ( Int, s, ( List b, String ) )) -> s -> Int -> Int -> Task Never Int.
uint64_t Eco_Kernel_Stream_custom(uint64_t action, uint64_t state, int64_t readCap,
                                  int64_t writeCap) {
    ECO_KERNEL_GUARD(
        HPointer fn = dec(action);
        HPointer st = dec(state);
        HPointer fs = alloc::listNil();
        HPointer caps = alloc::listNil();
        Elm::StackRootGuard g(&fn, &st, &fs, &caps);
        fs = alloc::tuple2(alloc::boxed(fn), alloc::boxed(st), 0);
        caps = alloc::tuple2(alloc::unboxedInt(readCap), alloc::unboxedInt(writeCap), 0x5);
        HPointer payload = alloc::tuple2(alloc::boxed(fs), alloc::boxed(caps), 0);
        return enc(makeBinding<streamCustomBody>(payload));
    )
}

// Returns a Task that creates a Codec pair encoding Strings as UTF-8 Bytes and succeeds with its id.
// Elm type: textEncoder : Task Never Int.
uint64_t Eco_Kernel_Stream_textEncoder() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<streamTextEncoderBody>(alloc::unit()));
    )
}

// Returns a Task that creates a Codec pair decoding UTF-8 Bytes into Strings and succeeds with its id.
// Elm type: textDecoder : Task Never Int.
uint64_t Eco_Kernel_Stream_textDecoder() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<streamTextDecoderBody>(alloc::unit()));
    )
}

// Returns a Task that creates a compressing Codec pair for `algorithm` and succeeds with its id.
// Elm type: compressor : Int -> Task Never Int.
uint64_t Eco_Kernel_Stream_compressor(int64_t algorithm) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(algorithm);
        return enc(makeBinding<streamCompressorBody>(payload));
    )
}

// Returns a Task that creates a decompressing Codec pair for `algorithm` and succeeds with its id.
// Elm type: decompressor : Int -> Task Never Int.
uint64_t Eco_Kernel_Stream_decompressor(int64_t algorithm) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(algorithm);
        return enc(makeBinding<streamDecompressorBody>(payload));
    )
}

// Returns a Task that pipes the readable side of `readable` into the writable side of `transformation`.
// Elm type: pipeThrough : Int -> Int -> Task SErr ().
uint64_t Eco_Kernel_Stream_pipeThrough(int64_t transformation, int64_t readable) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::tuple2(alloc::unboxedInt(transformation),
                                         alloc::unboxedInt(readable), 0x5);
        return enc(makeBinding<streamPipeThroughBody>(payload));
    )
}

// Returns a Task that pipes the readable side of `readable` into `writable` and completes when the pipe
// finishes. Elm type: pipeTo : Int -> Int -> Task SErr ().
uint64_t Eco_Kernel_Stream_pipeTo(int64_t writable, int64_t readable) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::tuple2(alloc::unboxedInt(writable),
                                         alloc::unboxedInt(readable), 0x5);
        return enc(makeAsyncBinding<streamPipeToBody>(payload));
    )
}

// Returns a Task that reads the next value of stream `id`, handing out the unread `readLine` carry first.
// Elm type: read : Int -> Task SErr a.
uint64_t Eco_Kernel_Stream_read(int64_t id) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(id);
        return enc(makeAsyncBinding<streamReadBody>(payload));
    )
}

// Returns a Task that reads the next value of stream `id`, ignoring the `readLine` carry.
// Elm type: readChunk : Int -> Task SErr Bytes.
uint64_t Eco_Kernel_Stream_readChunk(int64_t id) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(id);
        return enc(makeAsyncBinding<streamReadChunkBody>(payload));
    )
}

// Returns a Task that takes the next line from the `readLine` carry of stream `id`; with `atEnd`, the rest of
// the carry when no newline is left. Elm type: carryLine : Bool -> Int -> Task Never (Maybe Bytes). The
// Bool arrives as the boxed True or False word and is packed as an Int 0 or 1.
uint64_t Eco_Kernel_Stream_carryLine(uint64_t atEnd, int64_t id) {
    ECO_KERNEL_GUARD(
        int64_t end = Export::decodeBoxedBool(atEnd) ? 1 : 0;
        HPointer payload = alloc::tuple2(alloc::unboxedInt(end), alloc::unboxedInt(id), 0x5);
        return enc(makeBinding<streamCarryLineBody>(payload));
    )
}

// Returns a Task that appends `bytes` to the `readLine` carry of stream `id`.
// Elm type: carryAppend : Bytes -> Int -> Task Never ().
uint64_t Eco_Kernel_Stream_carryAppend(uint64_t bytes, int64_t id) {
    ECO_KERNEL_GUARD(
        HPointer b = dec(bytes);
        Elm::StackRootGuard g(&b);
        HPointer payload = alloc::tuple2(alloc::boxed(b), alloc::unboxedInt(id), 0x4);
        return enc(makeBinding<streamCarryAppendBody>(payload));
    )
}

// Returns a Task that writes `value` to stream `id` and completes once the value has been passed on:
// transformed by an in-memory pair, or written by a channel.
// Elm type: write : a -> Int -> Task SErr ().
uint64_t Eco_Kernel_Stream_write(uint64_t value, int64_t id) {
    ECO_KERNEL_GUARD(
        HPointer v = dec(value);
        Elm::StackRootGuard g(&v);
        HPointer payload = alloc::tuple2(alloc::boxed(v), alloc::unboxedInt(id), 0x4);
        return enc(makeAsyncBinding<streamWriteBody>(payload));
    )
}

// Returns a Task that writes `value` to stream `id` and completes once the value has been accepted.
// Elm type: enqueue : a -> Int -> Task SErr ().
uint64_t Eco_Kernel_Stream_enqueue(uint64_t value, int64_t id) {
    ECO_KERNEL_GUARD(
        HPointer v = dec(value);
        Elm::StackRootGuard g(&v);
        HPointer payload = alloc::tuple2(alloc::boxed(v), alloc::unboxedInt(id), 0x4);
        return enc(makeAsyncBinding<streamEnqueueBody>(payload));
    )
}

// Returns a Task that closes the writable side of stream `id` once its queued writes are through.
// Elm type: closeWritable : Int -> Task SErr ().
uint64_t Eco_Kernel_Stream_closeWritable(int64_t id) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(id);
        return enc(makeAsyncBinding<streamCloseWritableBody>(payload));
    )
}

// Returns a Task that cancels the readable side of stream `id` with `reason`.
// Elm type: cancelReadable : String -> Int -> Task SErr ().
uint64_t Eco_Kernel_Stream_cancelReadable(uint64_t reason, int64_t id) {
    ECO_KERNEL_GUARD(
        HPointer r = dec(reason);
        Elm::StackRootGuard g(&r);
        HPointer payload = alloc::tuple2(alloc::boxed(r), alloc::unboxedInt(id), 0x4);
        return enc(makeBinding<streamCancelReadableBody>(payload));
    )
}

// Returns a Task that cancels the writable side of stream `id` with `reason`.
// Elm type: cancelWritable : String -> Int -> Task SErr ().
uint64_t Eco_Kernel_Stream_cancelWritable(uint64_t reason, int64_t id) {
    ECO_KERNEL_GUARD(
        HPointer r = dec(reason);
        Elm::StackRootGuard g(&r);
        HPointer payload = alloc::tuple2(alloc::boxed(r), alloc::unboxedInt(id), 0x4);
        return enc(makeBinding<streamCancelWritableBody>(payload));
    )
}

// Returns `Just` the String whose UTF-8 is `bytes`, or `Nothing` if `bytes` is not well-formed UTF-8
// (`isValidUtf8`). Pure: it acts at once and returns no Task.
uint64_t Eco_Kernel_Stream_utf8ToString(uint64_t bytes) {
    ECO_KERNEL_GUARD(
        std::string data = toStdBytes(dec(bytes));   // copy out before allocating
        if (!isValidUtf8(data)) return enc(alloc::nothing());
        HPointer s = alloc::allocStringFromUTF8(data);
        return enc(alloc::just(alloc::boxed(s), true));   // fresh: `just` roots it
    )
}

// Returns the UTF-8 encoding of `str` as Bytes. Pure: it acts at once and returns no Task.
uint64_t Eco_Kernel_Stream_stringToUtf8(uint64_t str) {
    ECO_KERNEL_GUARD(
        std::string data = toStdString(dec(str));
        if (data.empty()) return enc(alloc::emptyBytes());
        alloc::BlankByteBuffer bb = alloc::allocByteBufferBlank(data.size());
        std::memcpy(bb.bytes, data.data(), data.size());   // no allocation since bb
        return enc(bb.hp);
    )
}

} // extern "C"
