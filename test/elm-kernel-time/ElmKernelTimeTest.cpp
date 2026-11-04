//===- ElmKernelTimeTest.cpp - Unit tests for elm-kernel-cpp's time code ---===//
//
// The `test` binary does not link elm-kernel-cpp, so the time effect manager's unit tests live in
// this binary, set up like eco-system-core-test. The tests are in TimeKernelTest.cpp.
//
// Build: cmake --build <dir> --target elm-kernel-time-test
// Run:   <dir>/elm-kernel-cpp/elm-kernel-time-test
//        <dir>/elm-kernel-cpp/elm-kernel-time-test --child <scenario>
//
//===----------------------------------------------------------------------===//

#include "TimeKernelTest.hpp"

#include "allocator/Allocator.hpp"
#include "KernelExports.h"
#include "platform/Scheduler.hpp"

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <string>

using namespace Elm;
using Elm::Platform::Scheduler;

void initTimeRuntime() {
    auto& a = Allocator::instance();
    a.initialize();
    a.initThread();
    (void)Scheduler::instance();
}

namespace {

int scenarioSelfTest() {
    initTimeRuntime();
    const char* v = std::getenv("ECO_TIME_SELFTEST_VALUE");
    std::printf("time selftest %s\n", v ? v : "(unset)");
    return 0;
}

// The harness itself: the time kernel is linked, and a child scenario runs.
void testHarness() {
    std::printf("testHarness\n");
    void (*volatile reg)() = &eco_register_time_effect_manager;
    HPtr (*volatile leaf)(HPtr, HPtr) = &Elm_Kernel_Platform_leaf;
    CHECK(reg != nullptr && leaf != nullptr);
    auto r = ChildScenario::runChildScenario("selftest/time", {{"ECO_TIME_SELFTEST_VALUE", "7"}});
    CHECK(r.ok());
    CHECK(r.out.find("time selftest 7") != std::string::npos);
}

}  // namespace

int main(int argc, char** argv) {
    ChildScenario::add("selftest/time", scenarioSelfTest);
    registerTimeKernelScenarios();
    ChildScenario::dispatch(argc, argv);
    if (argc > 1) {
        std::printf("usage: %s | %s --child <scenario> | %s --list-scenarios\n", argv[0], argv[0], argv[0]);
        return 2;
    }

    initTimeRuntime();
    testHarness();
    std::printf("== time\n");
    runTimeKernelTests();

    std::printf("\n%d checks, %d failures\n", CoreTest::g_checks.load(), CoreTest::g_failures.load());
    std::printf(CoreTest::g_failures == 0 ? "ALL PASSED\n" : "FAILED\n");
    return CoreTest::g_failures == 0 ? 0 : 1;
}
