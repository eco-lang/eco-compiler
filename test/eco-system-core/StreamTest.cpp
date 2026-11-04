// Stream unit tests of eco-system-core-test (system-kernel-cpp/src/eco-system/Stream/).
//
// STREAM-07: `maybeErase` (system-kernel-cpp/src/eco-system/Stream/Stream.cpp) erases a pair only when
// both sides are Closed, so a pair whose side ended Errored (a read or write error on its channel) stays
// in the stream table for the rest of the run, with its channel and its scanned closure words. The test
// errors many mapped sources (read ECONNRESET) and text channel sinks (write EPIPE), checks that each
// still reports its stored Stream.Failed reason (which the fix must keep), and then expects the table
// back at its starting size with every channel destroyed. Before the fix the table grew by one per
// pair and no channel was destroyed; the check now guards against a regression.

#include "EcoSystemCoreTest.hpp"

#include "eco-system/Core/ByteChannel.hpp"
#include "eco-system/Core/Core.hpp"
#include "eco-system/Stream/Stream.hpp"
#include "eco-system/Stream/StreamTable.hpp"

#include "allocator/Allocator.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RootSet.hpp"

#include <cerrno>
#include <cstdio>
#include <deque>
#include <memory>
#include <string>
#include <tuple>
#include <vector>

using namespace Eco::System;
using namespace Elm;

namespace {

// --- Helpers (copies of EcoSystemCoreTest.cpp's Stream helpers, which are file-local there) -------

std::vector<std::string> g_resumed;   // "ok:<String>" / "err:<kind>:<reason>"

void drainResults() {
    ChannelResult tmp;
    while (tryPopChannelResult(tmp)) {}
}

void* recordResumeEval(void* args[]) {
    HPointer task = dec(args[0]);
    auto* t = static_cast<Elm::Task*>(Allocator::instance().resolve(task));
    if (t->ctor == Elm::alloc::Task_Succeed) {
        g_resumed.push_back("ok:" + toStdString(t->value.p));
    } else {
        Tuple2* tup = asTuple2(t->value.p);
        g_resumed.push_back("err:" + std::to_string(tup->a.i) + ":" + toStdString(tup->b.p));
    }
    return reinterpret_cast<void*>(enc(alloc::unit()));
}

// fromWire ( tag, text, bytes ) = text.
void* fromWireEval(void* args[]) {
    std::string out;
    {
        Tuple3* t3 = asTuple3(dec(args[0]));
        out = toStdString(t3->b.p);
    }
    return reinterpret_cast<void*>(enc(alloc::allocStringFromUTF8(out)));
}

HPointer nativeClosure1(EvalFunction fn) { return alloc::allocClosureK(fn, 1, PK_Boxed); }

struct ChanLog {
    std::deque<uint64_t> reads;
    std::vector<uint64_t> writes;
    int shutdowns = 0;
    bool destroyed = false;
};

// A channel whose requests the test answers by hand.
class ErrChannel final : public ByteChannel {
public:
    explicit ErrChannel(std::shared_ptr<ChanLog> log) : log_(std::move(log)) {}
    ~ErrChannel() override { log_->destroyed = true; }
    void requestRead(uint64_t token, size_t) override { log_->reads.push_back(token); }
    void requestWrite(uint64_t token, std::string) override { log_->writes.push_back(token); }
    void requestWriteTagged(uint64_t token, int64_t, bool, std::string) override { log_->writes.push_back(token); }
    void close(uint64_t token) override {
        // Answer the close at once, as a real channel eventually does.
        ChannelResult r;
        r.channelId = id();
        r.token = token;
        r.op = ChannelResult::Op::Close;
        postChannelResult(std::move(r));
    }
    void shutdown() override {
        ++log_->shutdowns;
        while (!log_->reads.empty()) {   // pending requests complete ECANCELED
            ChannelResult r;
            r.channelId = id();
            r.token = log_->reads.front();
            r.op = ChannelResult::Op::Read;
            r.err = ECANCELED;
            log_->reads.pop_front();
            postChannelResult(std::move(r));
        }
    }

private:
    std::shared_ptr<ChanLog> log_;
};

template <typename Body>
void callBody(Body body, HPointer captured) {
    HPointer resume = alloc::listNil();
    Elm::StackRootGuard g(&captured, &resume);
    resume = nativeClosure1(&recordResumeEval);
    body(captured, resume);
}

void streamRead(int64_t id) { callBody(&streamReadBody, alloc::allocInt(id)); }

void streamWrite(int64_t id, const std::string& s) {
    HPointer v = alloc::allocStringFromUTF8(s);
    Elm::StackRootGuard g(&v);
    HPointer cap = alloc::tuple2(alloc::boxed(v), alloc::unboxedInt(id), 0x4);
    callBody(&streamWriteBody, cap);
}

std::string lastResumed() { return g_resumed.empty() ? std::string("<none>") : g_resumed.back(); }

// --- STREAM-07 ------------------------------------------------------------------------------------

void testErroredPairsErased() {
    std::printf("stream/errored-pairs-are-erased\n");
    drainResults();
    g_resumed.clear();
    constexpr int N = 200;
    const std::string readFailed = std::string("err:1:\x01stream\x1f" "ECONNRESET\x1f" "read ECONNRESET");
    const std::string writeFailed = std::string("err:1:\x01stream\x1f" "EPIPE\x1f" "write EPIPE");

    // Mapped sources whose read-ahead fails.
    const size_t base = streamTable().size();
    std::vector<std::shared_ptr<ChanLog>> srcLogs;
    int srcReasonsKept = 0;
    for (int i = 0; i < N; ++i) {
        auto log = std::make_shared<ChanLog>();
        auto* ch = new ErrChannel(log);
        const uint64_t chan = ch->id();
        const int64_t id = createMappedSource(ch, enc(nativeClosure1(&fromWireEval)));
        CHECK(log->reads.size() == 1);
        if (log->reads.empty()) continue;
        ChannelResult r;
        r.channelId = chan;
        r.token = log->reads.front();
        log->reads.pop_front();
        r.op = ChannelResult::Op::Read;
        r.err = ECONNRESET;
        r.reason = "read ECONNRESET";
        postChannelResult(std::move(r));
        channelDrain();
        streamRead(id);   // a later read still gets the stored reason
        if (lastResumed() == readFailed) ++srcReasonsKept;
        channelDrain();
        srcLogs.push_back(log);
    }
    channelDrain();
    const size_t afterSources = streamTable().size();
    int srcDestroyed = 0;
    for (auto& l : srcLogs) srcDestroyed += l->destroyed ? 1 : 0;
    CHECK_MSG(srcReasonsKept == N, "sources reporting Stream.Failed after the error: " + std::to_string(srcReasonsKept));

    // Text channel sinks whose write fails.
    std::vector<std::shared_ptr<ChanLog>> sinkLogs;
    int sinkReasonsKept = 0;
    for (int i = 0; i < N; ++i) {
        auto log = std::make_shared<ChanLog>();
        auto* ch = new ErrChannel(log);
        const uint64_t chan = ch->id();
        const int64_t id = createTextChannelSink(ch);
        streamWrite(id, "x");
        CHECK(log->writes.size() == 1);
        if (log->writes.empty()) continue;
        ChannelResult r;
        r.channelId = chan;
        r.token = log->writes.front();
        r.op = ChannelResult::Op::Write;
        r.err = EPIPE;
        r.reason = "write EPIPE";
        postChannelResult(std::move(r));
        channelDrain();
        streamWrite(id, "y");   // a later write still fails with the stored reason
        if (lastResumed() == writeFailed) ++sinkReasonsKept;
        channelDrain();
        sinkLogs.push_back(log);
    }
    channelDrain();
    const size_t afterSinks = streamTable().size();
    int sinkDestroyed = 0;
    for (auto& l : sinkLogs) sinkDestroyed += l->destroyed ? 1 : 0;
    CHECK_MSG(sinkReasonsKept == N, "sinks reporting Stream.Failed after the error: " + std::to_string(sinkReasonsKept));

    const std::string how = "table size " + std::to_string(base) + " -> " + std::to_string(afterSources) +
                            " after " + std::to_string(N) + " errored mapped sources -> " +
                            std::to_string(afterSinks) + " after " + std::to_string(N) +
                            " errored text sinks; channels destroyed: sources " + std::to_string(srcDestroyed) +
                            "/" + std::to_string(N) + ", sinks " + std::to_string(sinkDestroyed) + "/" +
                            std::to_string(N);
    std::printf("  %s\n", how.c_str());
    CHECK_MSG(afterSinks == base && srcDestroyed == N && sinkDestroyed == N, "STREAM-07: " + how);
}

}  // namespace

void runStreamTests() {
    testErroredPairsErased();
}

void registerStreamScenarios() {}
