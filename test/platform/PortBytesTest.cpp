// Unit tests for plans/native-bytes-ports-2.md; see PortBytesTest.hpp.

#include "PortBytesTest.hpp"

#include "../ForkedChild.hpp"
#include "../TestSuite.hpp"
#include "../allocator/TestHelpers.hpp"

#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/platform/PortRuntime.hpp"

#include <atomic>
#include <condition_variable>
#include <csignal>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#if !defined(_WIN32)
#include <sys/wait.h>
#endif

using Elm::Allocator;
using Elm::HPointer;
using Elm::NoCollectBytes;
using Elm::NoCollectScope;
using Elm::Platform::PortRuntime;

namespace {

#if !defined(_WIN32)

// ---- HEAP_083: a collection inside a no-collection region aborts ------------------------------------------------

void checkGuardAborts(bool major) {
    ForkedChild::ChildResult r = ForkedChild::runInChild([major] {
        initAllocator();
        NoCollectScope scope;
        if (major) {
            Allocator::instance().majorGC();
        } else {
            Allocator::instance().minorGC();
        }
        return 0;
    });
    const bool aborted = WIFSIGNALED(r.status) && WTERMSIG(r.status) == SIGABRT;
    if (!aborted || r.stderrText.find("a collection started inside a host callback (HEAP_083)") == std::string::npos) {
        TEST_FAIL(std::string("a ") + (major ? "major" : "minor") +
                  " collection inside a NoCollectScope did not abort with the HEAP_083 message; stderr: " +
                  r.stderrText);
    }
}

void testGuardAbortsMinor() { checkGuardAborts(false); }
void testGuardAbortsMajor() { checkGuardAborts(true); }

#endif  // !_WIN32

// The control: once the scope has ended, collections run again, and scopes nest.
void testGuardEnds() {
    initAllocator();
    {
        NoCollectScope outer;
        {
            NoCollectScope inner;
        }
        TEST_ASSERT(Allocator::instance().getCurrentThreadHeap()->inNoCollect());
    }
    TEST_ASSERT(!Allocator::instance().getCurrentThreadHeap()->inNoCollect());
    Allocator::instance().minorGC();
    Allocator::instance().majorGC();
}

// ---- Bytes allocated without collecting --------------------------------------------------------------------------

// Each length takes the form allocByteBuffer gives it, writable, with no collection (the scope would abort).
void testNoCollectBytesForms() {
    initAllocator();
    Allocator& a = Allocator::instance();
    const size_t lot = a.getLargeObjectThreshold();
    const size_t lastSmall = lot - sizeof(Elm::ByteBuffer) - 8;
    const size_t firstLarge = lot - sizeof(Elm::ByteBuffer);
    for (size_t len : {size_t{1}, size_t{100}, lastSmall, firstLarge, size_t{100000}}) {
        NoCollectBytes b{};
        {
            NoCollectScope scope;
            b = a.tryAllocByteBufferNoCollect(len);
        }
        TEST_ASSERT(b.bytes != nullptr);
        std::memset(b.bytes, 0x5A, len);
        void* obj = a.resolve(b.hp);
        const Elm::u32 tag = static_cast<Elm::Header*>(obj)->tag;
        const bool large = ((sizeof(Elm::ByteBuffer) + len + 7) & ~size_t{7}) >= lot;
        TEST_ASSERT(tag == static_cast<Elm::u32>(large ? Elm::Tag_LargeByteHeader : Elm::Tag_ByteBuffer));
        Elm::alloc::ByteBufferView v = Elm::alloc::byteBufferView(obj);
        TEST_ASSERT(v.length == len);
        TEST_ASSERT(v.data[0] == 0x5A && v.data[len - 1] == 0x5A);
    }
}

// With the nursery at its limit a small one fails, without collecting, and succeeds again after a collection.
void testNoCollectBytesFailsWhenFull() {
    initAllocator();
    Allocator& a = Allocator::instance();
    {
        NoCollectScope scope;
        // Real objects, with headers, until the nursery's limit.
        while (a.tryAllocByteBufferNoCollect(16).bytes != nullptr) {
        }
        NoCollectBytes b = a.tryAllocByteBufferNoCollect(16);
        TEST_ASSERT(b.bytes == nullptr);
    }
    a.minorGC();
    NoCollectBytes b = a.tryAllocByteBufferNoCollect(16);
    TEST_ASSERT(b.bytes != nullptr);
}

// A filled value survives later collections with its bytes.
void testNoCollectBytesSurvive() {
    initAllocator();
    Allocator& a = Allocator::instance();
    for (size_t len : {size_t{40}, size_t{50000}}) {
        NoCollectBytes b = a.tryAllocByteBufferNoCollect(len);
        TEST_ASSERT(b.bytes != nullptr);
        for (size_t i = 0; i < len; ++i) b.bytes[i] = static_cast<uint8_t>(i * 13);
        HPointer hp = b.hp;
        Elm::StackRootGuard guard(&hp);
        a.minorGC();
        a.majorGC();
        a.minorGC();
        Elm::alloc::ByteBufferView v = Elm::alloc::byteBufferView(a.resolve(hp));
        TEST_ASSERT(v.length == len);
        for (size_t i = 0; i < len; ++i) TEST_ASSERT(v.data[i] == static_cast<uint8_t>(i * 13));
    }
}

// ---- Owned bytes ----------------------------------------------------------------------------------------------

void testOwnedBytes() {
    const uint8_t src[5] = {1, 2, 3, 4, 5};
    const eco_borrowed_bytes borrowed{src, 5};
    eco_owned_bytes* o = eco_borrowed_retain(&borrowed);
    TEST_ASSERT(o != nullptr);
    TEST_ASSERT(eco_owned_size(o) == 5 && std::memcmp(eco_owned_data(o), src, 5) == 0);
    TEST_ASSERT(eco_owned_data(o) != src);

    // Many threads add and drop references; the copy lives until the last drop.
    std::vector<std::thread> threads;
    for (int t = 0; t < 8; ++t) {
        threads.emplace_back([o] {
            for (int i = 0; i < 100000; ++i) {
                eco_owned_ref(o);
                eco_owned_unref(o);
            }
        });
    }
    for (auto& t : threads) t.join();
    TEST_ASSERT(eco_owned_data(o)[4] == 5);
    eco_owned_unref(o);

    const eco_borrowed_bytes empty{nullptr, 0};
    eco_owned_bytes* e = eco_borrowed_retain(&empty);
    TEST_ASSERT(e != nullptr && eco_owned_size(e) == 0 && eco_owned_data(e) == nullptr);
    eco_owned_unref(e);
    TEST_ASSERT(eco_borrowed_data(&empty) == nullptr && eco_borrowed_size(&empty) == 0);
}

// ---- Port handles -----------------------------------------------------------------------------------------------

size_t neverFill(uint8_t*, size_t, void* user) {
    *static_cast<bool*>(user) = true;
    return 0;
}

void testHandles() {
    initAllocator();
    TEST_ASSERT(eco_port_get(nullptr) == nullptr);
    TEST_ASSERT(eco_port_kind(nullptr) == -1);
    eco_port* p = eco_port_get("port-bytes-test/a");
    TEST_ASSERT(p != nullptr && p == eco_port_get("port-bytes-test/a"));
    TEST_ASSERT(std::string(eco_port_get_name(p)) == "port-bytes-test/a");
    TEST_ASSERT(eco_port_kind(p) == Elm::Platform::kPortUnregistered);

    // An unregistered port takes nothing, and an emit to it never calls its fill.
    bool called = false;
    TEST_ASSERT(eco_port_emit(p, 8, neverFill, &called) == Elm::Platform::kEmitNotAPort);
    TEST_ASSERT(!called);
    TEST_ASSERT(eco_port_send_json(p, "1") == 1);
    const uint8_t one = 1;
    TEST_ASSERT(eco_port_send_buffer(p, &one, 1, nullptr, nullptr) == 1);
    TEST_ASSERT(eco_port_emit(p, size_t{1} << 33, neverFill, &called) == Elm::Platform::kEmitNotAPort);

    // The handle survives the rehashes that many more entries cause.
    for (int i = 0; i < 10000; ++i) eco_port_get(("port-bytes-test/n" + std::to_string(i)).c_str());
    TEST_ASSERT(eco_port_get("port-bytes-test/a") == p);
    TEST_ASSERT(std::string(eco_port_get_name(p)) == "port-bytes-test/a");
}

// ---- Subscriber lifetime ----------------------------------------------------------------------------------------

std::atomic<int> destroyed{0};
std::atomic<int> calls{0};

void countDestroy(void*) { destroyed.fetch_add(1); }

struct SelfRemover {
    eco_port* port;
};

void removeSelf(const eco_borrowed_bytes*, void* user) {
    calls.fetch_add(1);
    SelfRemover* self = static_cast<SelfRemover*>(user);
    TEST_ASSERT(eco_port_unsubscribe_borrowed(self->port, removeSelf, user) == 0);
    // Still inside the call: the subscription is gone, but its destroy waits for the call to return.
    TEST_ASSERT(destroyed.load() == 0);
}

// A subscriber that removes itself during its own call is destroyed once, after the call.
void testDestroyAfterOwnCall() {
    initAllocator();
    destroyed = 0;
    calls = 0;
    PortRuntime& rt = PortRuntime::instance();
    eco_port* p = eco_port_get("port-bytes-test/self");
    SelfRemover self{p};
    TEST_ASSERT(eco_port_subscribe_borrowed(p, removeSelf, &self, countDestroy) == 0);
    const uint8_t data[3] = {7, 8, 9};
    rt.deliverOutgoingBytes(p, data, 3);
    TEST_ASSERT(calls.load() == 1);
    TEST_ASSERT(destroyed.load() == 1);
    rt.deliverOutgoingBytes(p, data, 3);
    TEST_ASSERT(calls.load() == 1);
    TEST_ASSERT(destroyed.load() == 1);
}

std::mutex latchMutex;
std::condition_variable latchCv;
bool entered = false;
bool released = false;

void blockingSubscriber(const eco_borrowed_bytes* bytes, void*) {
    TEST_ASSERT(eco_borrowed_size(bytes) == 2 && eco_borrowed_data(bytes)[1] == 6);
    std::unique_lock<std::mutex> lock(latchMutex);
    entered = true;
    latchCv.notify_all();
    latchCv.wait(lock, [] { return released; });
}

// A subscriber removed by another thread while its call is in progress is destroyed only after that call returns.
void testDestroyWaitsForCallOnAnotherThread() {
    initAllocator();
    destroyed = 0;
    entered = false;
    released = false;
    eco_port* p = eco_port_get("port-bytes-test/cross");
    TEST_ASSERT(eco_port_subscribe_borrowed(p, blockingSubscriber, nullptr, countDestroy) == 0);
    std::thread deliverer([p] {
        // This thread delivers as the eco thread would; it needs no heap for that.
        const uint8_t data[2] = {5, 6};
        PortRuntime::instance().deliverOutgoingBytes(p, data, 2);
    });
    {
        std::unique_lock<std::mutex> lock(latchMutex);
        latchCv.wait(lock, [] { return entered; });
    }
    TEST_ASSERT(eco_port_unsubscribe_borrowed(p, blockingSubscriber, nullptr) == 0);
    TEST_ASSERT(destroyed.load() == 0);
    {
        std::lock_guard<std::mutex> lock(latchMutex);
        released = true;
    }
    latchCv.notify_all();
    deliverer.join();
    TEST_ASSERT(destroyed.load() == 1);
}

// A failed subscription does not call destroy.
void testFailedSubscribeKeepsUser() {
    initAllocator();
    destroyed = 0;
    TEST_ASSERT(eco_port_subscribe_borrowed(nullptr, blockingSubscriber, nullptr, countDestroy) == 1);
    TEST_ASSERT(eco_port_subscribe_borrowed(eco_port_get("port-bytes-test/x"), nullptr, nullptr, countDestroy) == 1);
    TEST_ASSERT(destroyed.load() == 0);
}

// An emit made outside any callback takes the off-heap path; one made inside a fill is refused.
size_t nestingFill(uint8_t*, size_t, void* user) {
    *static_cast<int*>(user) = eco_port_emit(eco_port_get("port-bytes-test/a"), 0, neverFill, nullptr);
    return 0;
}

void testNestedEmitRefused() {
    initAllocator();
    // The port is unregistered, so the outer emit is refused before its fill; the refusal for nesting is
    // checked where a fill runs, by the E2E harness's op 4. Here: the result codes for bad arguments.
    eco_port* p = eco_port_get("port-bytes-test/a");
    int inner = -1;
    TEST_ASSERT(eco_port_emit(p, 4, nestingFill, &inner) == Elm::Platform::kEmitNotAPort);
    TEST_ASSERT(inner == -1);
    TEST_ASSERT(eco_port_emit(p, 4, nullptr, nullptr) == Elm::Platform::kEmitNotAPort);
    TEST_ASSERT(eco_port_emit(nullptr, 4, neverFill, nullptr) == Elm::Platform::kEmitNotAPort);
}

}  // namespace

void registerPortBytesTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
#if !defined(_WIN32)
    suite.add(Testing::TestCase("port-bytes/guard-aborts-minor", testGuardAbortsMinor));
    suite.add(Testing::TestCase("port-bytes/guard-aborts-major", testGuardAbortsMajor));
#endif
    suite.add(Testing::TestCase("port-bytes/guard-ends", testGuardEnds));
    suite.add(Testing::TestCase("port-bytes/no-collect-bytes-forms", testNoCollectBytesForms));
    suite.add(Testing::TestCase("port-bytes/no-collect-bytes-fails-when-full", testNoCollectBytesFailsWhenFull));
    suite.add(Testing::TestCase("port-bytes/no-collect-bytes-survive", testNoCollectBytesSurvive));
    suite.add(Testing::TestCase("port-bytes/owned-bytes", testOwnedBytes));
    suite.add(Testing::TestCase("port-bytes/handles", testHandles));
    suite.add(Testing::TestCase("port-bytes/destroy-after-own-call", testDestroyAfterOwnCall));
    suite.add(Testing::TestCase("port-bytes/destroy-waits-for-call-on-another-thread",
                                testDestroyWaitsForCallOnAnotherThread));
    suite.add(Testing::TestCase("port-bytes/failed-subscribe-keeps-user", testFailedSubscribeKeepsUser));
    suite.add(Testing::TestCase("port-bytes/emit-argument-checks", testNestedEmitRefused));
}
