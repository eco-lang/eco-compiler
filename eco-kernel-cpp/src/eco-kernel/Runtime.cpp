//===- Runtime.cpp - Runtime kernel module implementation -----------------===//
//
// Each exported function only builds a binding Task, with Unit as the captured value except for `saveState`, which
// captures the state itself. The bodies in the anonymous namespace do the work when the Task is run.
//
//===----------------------------------------------------------------------===//

#include "Runtime.hpp"
#include "ExportHelpers.hpp"
#include "KernelHelpers.hpp"
#include "TaskBinding.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/RootSet.hpp"
#include "../../../runtime/src/platform/PlatformPaths.hpp"
#include <cerrno>
#include <random>
#include <string>
#if !defined(_WIN32)
#include <unistd.h>
#endif
#include <climits>

namespace Eco::Kernel::Runtime {

// The value stored by the most recent `saveState` run. It is meaningful only while `s_hasState` is set and the heap
// is still the one of `s_stateGeneration`, and it is reached by the collector only through the scanner
// `registerGcRootScanner` adds.
static HPointer s_savedState = {};
// Whether any `saveState` run has stored a value. Nothing clears it; a heap reset makes it stale instead.
static bool s_hasState = false;
// The heap generation (`Allocator::heapGeneration`) `s_savedState` was stored in. A value saved before a heap
// reset (which only tests make) belongs to the dead heap and counts as not saved.
static uint64_t s_stateGeneration = 0;
// The heap generation whose root set has the scanner; 0 before the first registration.
static uint64_t s_scannerGeneration = 0;

// Returns whether a value saved in the current heap generation is held.
static bool hasCurrentState() {
    return s_hasState && s_stateGeneration == Elm::Allocator::instance().heapGeneration();
}

namespace {

// Returns the Task that `dirname` describes, reading the directory now. When the executable's path cannot be
// read, the Task fails with the IO error tuple for `ENOENT` (IO_ERR_002).
HPointer dirnameBody(HPointer /*captured*/) {
    std::string dir = eco::platform::currentExecutableDir();
    if (dir.empty()) {
        return failErrno(ENOENT, "", "cannot determine the executable's directory");
    }
    return succeedString(dir);
}

// Returns a Task that succeeds with the next draw from the process-wide generator, which is created and seeded on
// the first call.
HPointer randomBody(HPointer /*captured*/) {
    static std::mt19937_64 gen(std::random_device{}());
    static std::uniform_real_distribution<double> dist(0.0, 1.0);
    return succeedFloat(dist(gen));
}

// Stores `captured`, the state value itself, as the saved state, and returns a Task that succeeds with Unit. The
// scanner is registered first if this heap generation has none, and the store happens before the allocation of
// that Task, so the scanner already covers it.
HPointer saveStateBody(HPointer captured) {
    registerGcRootScanner();
    s_savedState = captured;
    s_hasState = true;
    s_stateGeneration = Elm::Allocator::instance().heapGeneration();
    return succeedUnit();
}

/// The null-constructor tag of `Json.Encode.null` (the `ENC_NULL` encoder constant in JsonExports.cpp).
constexpr u16 JSON_ENC_NULL = 0;

/// Returns a Task that succeeds with the saved state, or, when none has been stored in this heap generation, with
/// JSON `null` (the `Json.Encode.null` value, which `Json.Decode.null` accepts), as the JS kernel does.
HPointer loadStateBody(HPointer /*captured*/) {
    if (hasCurrentState()) {
        return succeed(s_savedState);
    }
    return succeed(Elm::hpFromBits(Elm::nullConsWordFor(JSON_ENC_NULL)));
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
    const uint64_t gen = Elm::Allocator::instance().heapGeneration();
    if (s_scannerGeneration == gen) return;
    s_scannerGeneration = gen;
    Elm::Allocator::instance().getRootSet().addExternalRootScanner(
        // The scanner works on the encoded word, the form `EvacuateFn` takes, and writes back whatever it is
        // rewritten to. A value of an earlier heap is never handed to the collector.
        [](Elm::RootSet::EvacuateFn evacuate) {
            if (!hasCurrentState()) return;
            uint64_t encoded = Export::encode(s_savedState);
            evacuate(encoded);
            s_savedState = Export::decode(encoded);
        }, "eco-runtime-state");
}

} // namespace Eco::Kernel::Runtime
