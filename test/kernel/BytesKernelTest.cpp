// Unit tests of the Bytes kernel's extern-"C" exports (elm-kernel-cpp/src/bytes/BytesExports.cpp).
//
// read_bytes: the export `Elm_Kernel_Bytes_read_bytes` rejects a negative length (or offset), and an
// overrun, by throwing `Elm::BytesDecodeFailure` (the decoder's Nothing). It is a pin (DEAD-14): the dead
// `Elm::Kernel::Bytes` namespace API, deleted since, had a `read_bytes` with no negative-length check.
//
// The 4 GiB limit (BYTES-04): `elm_encoder_size` narrowed the size_t encoder width to u32 with no check, so an
// encoding wider than 4 GiB got a silently wrong size (and the fused and `Bytes.encode` paths then wrote past
// the buffer they allocated). The cases forge a sequence encoder node whose cached width is 2^32 + 8 and whose
// child list is empty, so nothing is written and no 4 GiB buffer is needed. It returned 8 before the fix; now
// `elm_encoder_size` and `Elm_Kernel_Bytes_encode` die with a clear "exceeds the 4 GiB Bytes limit" error
// before anything is allocated, which these crash tests (in a forked child) expect.

#include "BytesKernelTest.hpp"

#include "../ForkedChild.hpp"
#include "../TestSuite.hpp"
#include "../allocator/TestHelpers.hpp"

#include "../../elm-kernel-cpp/src/ExportHelpers.hpp"
#include "../../elm-kernel-cpp/src/KernelExports.h"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/BytesOps.hpp"
#include "../../runtime/src/allocator/ElmBytesRuntime.h"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"

#include <cstdint>
#include <cstdio>
#include <functional>
#include <string>
#include <vector>

using namespace Elm;

namespace {

template <typename F>
bool throwsDecodeFailure(F&& read) {
    try {
        (void)read();
    } catch (const Elm::BytesDecodeFailure&) {
        return true;
    }
    return false;
}

// DEAD-14 pin: Elm_Kernel_Bytes_read_bytes rejects a negative length or offset (and an overrun);
// an in-range read still succeeds, so the rejection is not a blanket failure.
void testReadBytesRejectsNegativeLength() {
    initAllocator();
    std::vector<u8> data(8);
    for (size_t i = 0; i < data.size(); ++i) data[i] = static_cast<u8>(i);
    HPtr bb = HPtr::fromHPointer(BytesOps::fromVector(data));

    TEST_ASSERT(!throwsDecodeFailure([&] { return Elm_Kernel_Bytes_read_bytes(4, bb, 0); }));
    TEST_ASSERT(throwsDecodeFailure([&] { return Elm_Kernel_Bytes_read_bytes(-1, bb, 0); }));
    TEST_ASSERT(throwsDecodeFailure([&] { return Elm_Kernel_Bytes_read_bytes(INT64_MIN, bb, 0); }));
    TEST_ASSERT(throwsDecodeFailure([&] { return Elm_Kernel_Bytes_read_bytes(1, bb, -1); }));
    TEST_ASSERT(throwsDecodeFailure([&] { return Elm_Kernel_Bytes_read_bytes(9, bb, 0); }));
}

// ---- The 4 GiB width limit -----------------------------------------------------------------------

// The ctor of a sequence encoder node (`ENC_SEQ` in BytesExports.cpp): field 0 the unboxed total width, field 1
// the boxed list of child encoders.
constexpr u32 kEncSeq = 8;

// Forges a sequence encoder node of width 2^32 + 8 with an empty child list, from a real two-field encoder node
// (a String encoder: field 0 unboxed width, field 1 boxed).
HPtr forgeWideSequenceEncoder() {
    const char16_t text[] = u"hi";
    HPtr enc = Elm_Kernel_Bytes_write_string(
        HPtr::fromHPointer(alloc::allocString(reinterpret_cast<const u16*>(text), 2)));
    Custom* node = static_cast<Custom*>(Allocator::instance().resolve(Kernel::Export::decode(enc.toBits())));
    TEST_ASSERT(node != nullptr && node->header.size == 2);
    const int64_t wide = (int64_t(1) << 32) + 8;
    node->ctor = kEncSeq;
    node->unboxed = 1;
    node->values[0].i = wide;
    node->values[1].p = alloc::listNil();
    return enc;
}

#if !defined(_WIN32)
// Runs `call` on a forged wide encoder in a forked child, and fails unless the child dies with the
// "exceeds the 4 GiB Bytes limit" message instead of returning.
void checkWideEncoderRefused(const char* what, const std::function<void(HPtr)>& call) {
    ForkedChild::ChildResult r = ForkedChild::runInChild([&call]() -> int {
        initAllocator();
        call(forgeWideSequenceEncoder());
        std::fprintf(stderr, "returned\n");
        return 0;
    });
    const bool died = !(WIFEXITED(r.status) && WEXITSTATUS(r.status) == 0);
    const bool message = r.stderrText.find("an encoding of 4294967304 bytes exceeds the 4 GiB Bytes limit") !=
                         std::string::npos;
    if (!died || !message) {
        TEST_FAIL(std::string(what) + " on an encoder of width 2^32 + 8 did not die with the 4 GiB limit message; "
                  "stderr: " + r.stderrText);
    }
}

void testEncoderSizeRefusesWide() {
    checkWideEncoderRefused("elm_encoder_size", [](HPtr enc) {
        const u32 sz = elm_encoder_size(enc);
        std::fprintf(stderr, "elm_encoder_size returned %u\n", sz);
    });
}

void testBytesEncodeRefusesWide() {
    // The check comes before the buffer is allocated, so nothing near 4 GiB is allocated or zeroed.
    checkWideEncoderRefused("Elm_Kernel_Bytes_encode", [](HPtr enc) { (void)Elm_Kernel_Bytes_encode(enc); });
}
#endif

}  // namespace

void registerBytesKernelTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
    // Each case initializes the allocator, so each runs in its own process (and the width-limit
    // cases fork a child that dies).
    suite.add(Testing::TestCase("bytes-kernel/read-bytes-rejects-negative-length", testReadBytesRejectsNegativeLength));
#if !defined(_WIN32)
    suite.add(Testing::TestCase("bytes-kernel/encoder-size-refuses-width-over-4-gib", testEncoderSizeRefusesWide));
    suite.add(Testing::TestCase("bytes-kernel/encode-refuses-width-over-4-gib", testBytesEncodeRefusesWide));
#endif
}
