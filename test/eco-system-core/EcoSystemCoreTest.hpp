#pragma once

// The area files of eco-system-core-test (test/eco-system-core/<Area>Test.cpp). Each defines
//   void run<Area>Tests();            its in-process checks (CHECK, CHECK_MSG), run by main after the
//                                     tests of EcoSystemCoreTest.cpp and before testReactorQuiesce;
//   void register<Area>Scenarios();   ChildScenario::add(...) for its child scenarios.
// Scenario names are "<area>/<what>"; `eco-system-core-test --list-scenarios` lists them, and
// `eco-system-core-test --child <name>` runs one.

#include "../ChildScenario.hpp"
#include "CoreCheck.hpp"

// Initializes what the in-process tests share and what a child scenario usually needs first:
// the allocator on this thread and the Scheduler singleton. A child scenario calls it itself
// (after setting any environment it needs); the parent process has called it before any area runs.
void initCoreRuntime();

#define CORE_DECLARE_AREA(Area)    \
    void run##Area##Tests();       \
    void register##Area##Scenarios();

CORE_DECLARE_AREA(WebSocket)
CORE_DECLARE_AREA(HeapReset)
CORE_DECLARE_AREA(Stream)
CORE_DECLARE_AREA(ChildProcess)
CORE_DECLARE_AREA(Signal)
CORE_DECLARE_AREA(HttpServer)
CORE_DECLARE_AREA(Terminal)
CORE_DECLARE_AREA(Tls)
CORE_DECLARE_AREA(Watch)
CORE_DECLARE_AREA(FileSystem)
CORE_DECLARE_AREA(CoreServices)
CORE_DECLARE_AREA(FdChannel)
CORE_DECLARE_AREA(Socket)
CORE_DECLARE_AREA(Zlib)

#undef CORE_DECLARE_AREA

struct CoreArea {
    const char* name;             // the `--only` argument
    void (*run)();
    void (*registerScenarios)();
};

// In run order.
inline constexpr CoreArea kCoreAreas[] = {
    {"websocket", runWebSocketTests, registerWebSocketScenarios},
    {"heap-reset", runHeapResetTests, registerHeapResetScenarios},
    {"stream", runStreamTests, registerStreamScenarios},
    {"child-process", runChildProcessTests, registerChildProcessScenarios},
    {"signal", runSignalTests, registerSignalScenarios},
    {"http-server", runHttpServerTests, registerHttpServerScenarios},
    {"terminal", runTerminalTests, registerTerminalScenarios},
    {"tls", runTlsTests, registerTlsScenarios},
    {"watch", runWatchTests, registerWatchScenarios},
    {"filesystem", runFileSystemTests, registerFileSystemScenarios},
    {"core-services", runCoreServicesTests, registerCoreServicesScenarios},
    {"fd-channel", runFdChannelTests, registerFdChannelScenarios},
    {"socket", runSocketTests, registerSocketScenarios},
    {"zlib", runZlibTests, registerZlibScenarios},
};
