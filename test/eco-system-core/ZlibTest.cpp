// zlib feeding unit tests of eco-system-core-test: the WebSocket Deflater
// (system-kernel-cpp/src/eco-system/WebSocket/WsDeflate.cpp) and the Codec streams.
//
// ZLIB-01: `ws::Deflater::chunk` (system-kernel-cpp/src/eco-system/WebSocket/WsDeflate.cpp) hands
// zlib the whole input with `avail_in = static_cast<uInt>(n)`, a 32-bit field, so a message of 4 GiB
// or more is silently truncated to its size modulo 2^32. The guard deflates (2^32 + 4096) zero
// bytes from an untouched anonymous MAP_NORESERVE mapping (the shared zero page: no RSS), inflates
// the payload back with raw zlib, counting the bytes it produces into a small reused buffer, and
// expects every byte back (before the fix only 4096 came back). It deflates and inflates 4 GiB, so it
// runs only with ECO_CORE_SLOW_TESTS=1. `testZlibSlicedFeeding` covers the same feeding loops in the
// default run, for the Deflater and for the Codec streams' `deflateRun`/`inflateRun`, by cutting the
// zlib slice to 7 bytes through the ZlibFeed.hpp test hook.

#include "EcoSystemCoreTest.hpp"

#include "eco-system/Stream/StreamCodec.hpp"
#include "eco-system/Stream/ZlibFeed.hpp"
#include "eco-system/WebSocket/WsDeflate.hpp"

#include <zlib.h>

#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <string>
#include <vector>

#include <sys/mman.h>

namespace {

// ZLIB-01: a Deflater message of 4 GiB + 4096 bytes must inflate back to all of its bytes.
// It deflates and inflates 4 GiB (about 20 s), so it runs only with ECO_CORE_SLOW_TESTS=1; the default run
// covers the same feeding loops through testZlibSlicedFeeding.
void testDeflaterOver4GiB() {
    std::printf("zlib/deflater-message-over-4-gib\n");
    const char* slow = std::getenv("ECO_CORE_SLOW_TESTS");
    if (!slow || std::string(slow) != "1") {
        std::printf("  skipped: set ECO_CORE_SLOW_TESTS=1 to run it\n");
        return;
    }
    const size_t n = (size_t{1} << 32) + 4096;
    void* mem = mmap(nullptr, n, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    CHECK_MSG(mem != MAP_FAILED, "mmap of 4 GiB + 4096 failed");
    if (mem == MAP_FAILED) return;

    std::string out;
    Eco::System::ws::Deflater d(15, true);
    const bool deflated = d.message(static_cast<const char*>(mem), n, out);
    munmap(mem, n);
    CHECK_MSG(deflated, "Deflater::message failed");
    if (!deflated) return;
    out.append("\x00\x00\xff\xff", 4);   // the sync-flush tail RFC 7692 drops

    z_stream z{};
    CHECK(inflateInit2(&z, -15) == Z_OK);
    z.next_in = reinterpret_cast<Bytef*>(out.data());
    z.avail_in = static_cast<uInt>(out.size());   // a few MB at most
    std::vector<unsigned char> buf(1 << 20);
    uint64_t produced = 0;
    bool allZero = true;
    int r = Z_OK;
    for (;;) {
        z.next_out = buf.data();
        z.avail_out = static_cast<uInt>(buf.size());
        r = inflate(&z, Z_SYNC_FLUSH);
        size_t got = buf.size() - z.avail_out;
        for (size_t i = 0; i < got && allZero; i++) allZero = buf[i] == 0;
        produced += got;
        if (r != Z_OK || (z.avail_in == 0 && got == 0)) break;
    }
    inflateEnd(&z);
    CHECK_MSG(r == Z_OK || r == Z_BUF_ERROR || r == Z_STREAM_END,
              "inflate of the Deflater output failed: " + std::to_string(r));
    CHECK_MSG(allZero, "inflated bytes are not all zero");
    CHECK_MSG(produced == n, "ZLIB-01: deflated " + std::to_string(n) + " bytes (" +
                                 std::to_string(out.size()) + " compressed), inflated back " +
                                 std::to_string(produced));
}

#if ECO_TEST_HOOKS
// Returns `n` bytes of deterministic, moderately compressible text.
std::string zlib01Text(size_t n) {
    std::string s;
    s.reserve(n);
    uint32_t x = 12345;
    while (s.size() < n) {
        x = x * 1103515245u + 12345u;
        s += "word" + std::to_string((x >> 16) % 97) + ' ';
    }
    s.resize(n);
    return s;
}

// Inflates the raw deflate data `in` (window 15) and returns what it produced, or "" with `ok` false.
std::string zlib01RawInflate(const std::string& in, bool& ok) {
    z_stream z{};
    ok = inflateInit2(&z, -15) == Z_OK;
    if (!ok) return {};
    z.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(in.data()));
    z.avail_in = static_cast<uInt>(in.size());
    std::string out;
    std::vector<unsigned char> buf(1 << 16);
    int r = Z_OK;
    for (;;) {
        z.next_out = buf.data();
        z.avail_out = static_cast<uInt>(buf.size());
        r = inflate(&z, Z_SYNC_FLUSH);
        size_t got = buf.size() - z.avail_out;
        out.append(reinterpret_cast<const char*>(buf.data()), got);
        if (r != Z_OK || (z.avail_in == 0 && got == 0)) break;
    }
    inflateEnd(&z);
    ok = r == Z_OK || r == Z_BUF_ERROR || r == Z_STREAM_END;
    return out;
}

// ZLIB-01, the many-slice paths: with the zlib slice cut to 7 bytes (ZlibFeed.hpp test hook), the Codec
// compressor and decompressor (`deflateRun`/`inflateRun`) and the WebSocket Deflater must still round-trip.
void testZlibSlicedFeeding() {
    std::printf("zlib/input-fed-in-7-byte-slices\n");
    using namespace Eco::System;
    const std::string text = zlib01Text(200000);
    zlibSliceForTest().store(7);

    // Codec gzip: compress in 50 000-byte chunks, decompress the whole output in one chunk.
    std::string gz;
    {
        CodecPtr c = newZlibCodec(/*compress=*/true, kCodecGzip);
        std::vector<std::string> outs;
        std::string err;
        for (size_t off = 0; off < text.size() && err.empty(); off += 50000)
            err = codecTransform(*c, text.substr(off, 50000), std::u16string(), outs);
        if (err.empty()) err = codecFlush(*c, outs);
        CHECK_MSG(err.empty(), "ZLIB-01: sliced compress failed: " + err);
        for (auto& o : outs) gz += o;
    }
    std::string back;
    {
        CodecPtr c = newZlibCodec(/*compress=*/false, kCodecGzip);
        std::vector<std::string> outs;
        std::string err = codecTransform(*c, gz, std::u16string(), outs);
        if (err.empty()) err = codecFlush(*c, outs);
        CHECK_MSG(err.empty(), "ZLIB-01: sliced decompress failed: " + err);
        for (auto& o : outs) back += o;
    }
    CHECK_MSG(back == text, "ZLIB-01: Codec round trip in 7-byte slices gave " + std::to_string(back.size()) +
                                " of " + std::to_string(text.size()) + " bytes");
    // Trailing data after the gzip member is still rejected when it arrives in a later slice.
    {
        CodecPtr c = newZlibCodec(/*compress=*/false, kCodecGzip);
        std::vector<std::string> outs;
        std::string err = codecTransform(*c, gz + "junk", std::u16string(), outs);
        CHECK_MSG(err == "Junk found after end of compressed data.",
                  "ZLIB-01: trailing junk in a later slice gave \"" + err + "\"");
    }

    // WebSocket Deflater.
    std::string wire;
    ws::Deflater d(15, true);
    CHECK(d.message(text.data(), text.size(), wire));
    wire.append("\x00\x00\xff\xff", 4);
    bool ok = false;
    const std::string inflated = zlib01RawInflate(wire, ok);
    CHECK_MSG(ok && inflated == text, "ZLIB-01: Deflater in 7-byte slices round-tripped " +
                                          std::to_string(inflated.size()) + " of " + std::to_string(text.size()));

    zlibSliceForTest().store(0);
}
#endif

}  // namespace

void runZlibTests() {
#if ECO_TEST_HOOKS
    testZlibSlicedFeeding();
#endif
    testDeflaterOver4GiB();
}

void registerZlibScenarios() {}
