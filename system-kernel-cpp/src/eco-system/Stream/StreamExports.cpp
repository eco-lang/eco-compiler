//===- StreamExports.cpp - C exports of Eco.Kernel.Stream -----------------===//
//
// plans/eco-system-library.md Appendix B.2. Each export decodes and roots
// its arguments, packs them into one payload and returns a binding (G2);
// the bodies live in Stream.cpp. Payload layouts (F5 masks):
//   identity            tuple2( Int readCap, Int writeCap )   mask 0x5
//   read, closeWritable boxed ElmInt id
//   write, enqueue      tuple2( value, Int id )               mask 0x4
//   cancelReadable,
//   cancelWritable      tuple2( String reason, Int id )       mask 0x4
//   custom              tuple2( tuple2( fn, state ) mask 0,
//                               tuple2( Int readCap, Int writeCap ) mask 0x5 ) mask 0
//   pipeThrough         tuple2( Int transformation, Int readable ) mask 0x5
//   pipeTo              tuple2( Int writable, Int readable )        mask 0x5
//   textEncoder,
//   textDecoder         ()
//   compressor,
//   decompressor        boxed ElmInt algorithm (0 gzip, 1 deflate, 2 raw)
// utf8ToString / stringToUtf8 are the two pure conversions allowed by B5.
//
// Templates used: T1 (S-mode exports), T9 (Q-mode exports), T4 (Bytes),
// G4 (custom: fn and state rooted while the payload tuples allocate).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/Core.hpp"
#include "eco-system/Stream/StreamTable.hpp"

#include <cstring>
#include <string>

using namespace Eco::System;

extern "C" {

// identity : Int -> Int -> Task Never Int
uint64_t Eco_Kernel_Stream_identity(int64_t readCap, int64_t writeCap) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::tuple2(alloc::unboxedInt(readCap),
                                         alloc::unboxedInt(writeCap), 0x5);
        return enc(makeBinding<streamIdentityBody>(payload));
    )
}

// custom : (s -> a -> ( Int, s, ( List b, String ) )) -> s -> Int -> Int -> Task Never Int
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

// textEncoder : Task Never Int
uint64_t Eco_Kernel_Stream_textEncoder() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<streamTextEncoderBody>(alloc::unit()));
    )
}

// textDecoder : Task Never Int
uint64_t Eco_Kernel_Stream_textDecoder() {
    ECO_KERNEL_GUARD(
        return enc(makeBinding<streamTextDecoderBody>(alloc::unit()));
    )
}

// compressor : Int -> Task Never Int
uint64_t Eco_Kernel_Stream_compressor(int64_t algorithm) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(algorithm);
        return enc(makeBinding<streamCompressorBody>(payload));
    )
}

// decompressor : Int -> Task Never Int
uint64_t Eco_Kernel_Stream_decompressor(int64_t algorithm) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(algorithm);
        return enc(makeBinding<streamDecompressorBody>(payload));
    )
}

// pipeThrough : Int -> Int -> Task SErr ()
uint64_t Eco_Kernel_Stream_pipeThrough(int64_t transformation, int64_t readable) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::tuple2(alloc::unboxedInt(transformation),
                                         alloc::unboxedInt(readable), 0x5);
        return enc(makeBinding<streamPipeThroughBody>(payload));
    )
}

// pipeTo : Int -> Int -> Task SErr ()
uint64_t Eco_Kernel_Stream_pipeTo(int64_t writable, int64_t readable) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::tuple2(alloc::unboxedInt(writable),
                                         alloc::unboxedInt(readable), 0x5);
        return enc(makeAsyncBinding<streamPipeToBody>(payload));
    )
}

// read : Int -> Task SErr a
uint64_t Eco_Kernel_Stream_read(int64_t id) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(id);
        return enc(makeAsyncBinding<streamReadBody>(payload));
    )
}

// write : a -> Int -> Task SErr ()
uint64_t Eco_Kernel_Stream_write(uint64_t value, int64_t id) {
    ECO_KERNEL_GUARD(
        HPointer v = dec(value);
        Elm::StackRootGuard g(&v);
        HPointer payload = alloc::tuple2(alloc::boxed(v), alloc::unboxedInt(id), 0x4);
        return enc(makeAsyncBinding<streamWriteBody>(payload));
    )
}

// enqueue : a -> Int -> Task SErr ()
uint64_t Eco_Kernel_Stream_enqueue(uint64_t value, int64_t id) {
    ECO_KERNEL_GUARD(
        HPointer v = dec(value);
        Elm::StackRootGuard g(&v);
        HPointer payload = alloc::tuple2(alloc::boxed(v), alloc::unboxedInt(id), 0x4);
        return enc(makeAsyncBinding<streamEnqueueBody>(payload));
    )
}

// closeWritable : Int -> Task SErr ()
uint64_t Eco_Kernel_Stream_closeWritable(int64_t id) {
    ECO_KERNEL_GUARD(
        HPointer payload = alloc::allocInt(id);
        return enc(makeAsyncBinding<streamCloseWritableBody>(payload));
    )
}

// cancelReadable : String -> Int -> Task SErr ()
uint64_t Eco_Kernel_Stream_cancelReadable(uint64_t reason, int64_t id) {
    ECO_KERNEL_GUARD(
        HPointer r = dec(reason);
        Elm::StackRootGuard g(&r);
        HPointer payload = alloc::tuple2(alloc::boxed(r), alloc::unboxedInt(id), 0x4);
        return enc(makeBinding<streamCancelReadableBody>(payload));
    )
}

// cancelWritable : String -> Int -> Task SErr ()
uint64_t Eco_Kernel_Stream_cancelWritable(uint64_t reason, int64_t id) {
    ECO_KERNEL_GUARD(
        HPointer r = dec(reason);
        Elm::StackRootGuard g(&r);
        HPointer payload = alloc::tuple2(alloc::boxed(r), alloc::unboxedInt(id), 0x4);
        return enc(makeBinding<streamCancelWritableBody>(payload));
    )
}

// utf8ToString : Bytes -> Maybe String (pure, strict)
uint64_t Eco_Kernel_Stream_utf8ToString(uint64_t bytes) {
    ECO_KERNEL_GUARD(
        std::string data = toStdBytes(dec(bytes));   // G3: copy out first
        if (!isValidUtf8(data)) return enc(alloc::nothing());
        HPointer s = alloc::allocStringFromUTF8(data);
        return enc(alloc::just(alloc::boxed(s), true));   // fresh: `just` roots it
    )
}

// stringToUtf8 : String -> Bytes (pure)
uint64_t Eco_Kernel_Stream_stringToUtf8(uint64_t str) {
    ECO_KERNEL_GUARD(
        std::string data = toStdString(dec(str));
        if (data.empty()) return enc(alloc::emptyBytes());
        alloc::BlankByteBuffer bb = alloc::allocByteBufferBlank(data.size());
        std::memcpy(bb.bytes, data.data(), data.size());   // G8
        return enc(bb.hp);
    )
}

} // extern "C"
