// Unit tests of the runtime's TimerService (runtime/src/platform/TimerService.cpp).

#include "TimerServiceTest.hpp"

#include "../TestSuite.hpp"
#include "../allocator/TestHelpers.hpp"

#include "../../runtime/src/platform/Scheduler.hpp"
#include "../../runtime/src/platform/TimerService.hpp"

#include <chrono>
#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

// TIME-08 (a): TimerService::schedule converts the delay with `duration_cast` and adds it to `now()`
// with no check, so NaN, +-inf and +-1e300 are undefined behaviour (float-to-int overflow, then signed
// overflow in the addition). The case pins the post-fix semantics of plans/kernel-lib-bug-fixes.md D30
// (Node-exact: a non-finite or out-of-range delay becomes 1 ms): each of those timers fires, before a
// 50 ms reference timer, and nothing crashes. In a normal x86 build the UB happens to give "fire at
// once", so the case passes today; the UB itself shows only under
// -fsanitize=float-cast-overflow,signed-integer-overflow (plans/kernel-lib-bug-fixes.md, TIME-08).
void testTimerNonFiniteDelays() {
    using Elm::Platform::TimerService;
    Elm::TestHelpers::initAllocator();
    (void)Elm::Platform::Scheduler::instance();
    auto& ts = TimerService::instance();

    constexpr std::uint64_t kBase = 0xEC06'0000'0000'0000ull;   // never registered as resumes
    const double inf = std::numeric_limits<double>::infinity();
    const std::vector<double> delays = {inf, -inf, std::nan(""), 1e300, -1e300};
    const std::uint64_t refToken = kBase + 100;
    ts.schedule(50.0, refToken);
    for (size_t i = 0; i < delays.size(); ++i) ts.schedule(delays[i], kBase + i);

    std::vector<std::uint64_t> order;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (order.size() < delays.size() + 1 && std::chrono::steady_clock::now() < deadline) {
        std::uint64_t t = 0;
        if (ts.tryPopReadyToken(t)) order.push_back(t);
        else std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    std::string seen;
    for (auto t : order) seen += (t == refToken ? std::string("ref") : std::to_string(t - kBase)) + " ";
    // Withdraw whatever did not fire, so nothing is left behind.
    for (size_t i = 0; i < delays.size(); ++i) (void)ts.cancel(kBase + i);
    (void)ts.cancel(refToken);

    size_t refAt = order.size();
    for (size_t i = 0; i < order.size(); ++i) if (order[i] == refToken) refAt = i;
    if (order.size() != delays.size() + 1) TEST_FAIL("not every timer fired within 3 s; fired (in order): " + seen);
    if (refAt != delays.size()) TEST_FAIL("non-finite/huge delays must fire before the 50 ms timer; fired: " + seen);
}

}  // namespace

void registerTimerServiceTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
    // Initializes the allocator and starts the timer thread: own process.
    suite.add(Testing::TestCase("timer-service/non-finite-and-huge-delays-fire-at-once", testTimerNonFiniteDelays));
}
