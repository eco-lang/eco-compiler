//===- Runtime.cpp - Runtime kernel module implementation -----------------===//
//
// Per KERNEL_TASK_IO_001 / plans/defer-eager-kernel-tasks-via-binding.md
// Phase 7: `dirname`, `random`, `saveState`, `loadState` are returned as
// Task_Bindings. In particular `random()` now draws a fresh sample EACH
// time the scheduler steps the binding — mirrors the same fix that
// `Time.now` got via deferral (`plans/...time-now...`).
//
//===----------------------------------------------------------------------===//

#include "Runtime.hpp"
#include "ExportHelpers.hpp"
#include "KernelHelpers.hpp"
#include "TaskBinding.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/RootSet.hpp"
#include "../../../runtime/src/platform/PlatformPaths.hpp"
#include <random>
#include <string>
#if !defined(_WIN32)
#include <unistd.h>
#endif
#include <climits>

namespace Eco::Kernel::Runtime {

static HPointer s_savedState = {};
static bool s_hasState = false;

namespace {

HPointer dirnameBody(HPointer /*captured*/) {
    std::string dir = eco::platform::currentExecutableDir();
    if (dir.empty()) {
        return failString("Cannot determine executable path");
    }
    return succeedString(dir);
}

HPointer randomBody(HPointer /*captured*/) {
    static std::mt19937_64 gen(std::random_device{}());
    static std::uniform_real_distribution<double> dist(0.0, 1.0);
    return succeedFloat(dist(gen));
}

// `saveState` captures the state HPointer in slot 0 (boxed). The body
// stores it into s_savedState; the registered external root scanner keeps
// it alive across subsequent GCs.
HPointer saveStateBody(HPointer captured) {
    s_savedState = captured;
    s_hasState = true;
    return succeedUnit();
}

HPointer loadStateBody(HPointer /*captured*/) {
    if (s_hasState) {
        return succeed(s_savedState);
    }
    return succeed(Elm::alloc::nothing());
}

} // anonymous namespace

uint64_t dirname() {
    return Export::encode(
        Eco::Kernel::makeBinding<dirnameBody>(Elm::alloc::unit()));
}

uint64_t random() {
    return Export::encode(
        Eco::Kernel::makeBinding<randomBody>(Elm::alloc::unit()));
}

uint64_t saveState(uint64_t state) {
    return Export::encode(
        Eco::Kernel::makeBinding<saveStateBody>(Export::decode(state)));
}

uint64_t loadState() {
    return Export::encode(
        Eco::Kernel::makeBinding<loadStateBody>(Elm::alloc::unit()));
}

void registerGcRootScanner() {
    Elm::Allocator::instance().getRootSet().addExternalRootScanner(
        [](Elm::RootSet::EvacuateFn evacuate) {
            if (!s_hasState) return;
            uint64_t encoded = Export::encode(s_savedState);
            evacuate(encoded);
            s_savedState = Export::decode(encoded);
        });
}

} // namespace Eco::Kernel::Runtime
