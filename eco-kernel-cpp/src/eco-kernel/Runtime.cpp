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
#include <random>
#include <string>
#if !defined(_WIN32)
#include <unistd.h>
#endif
#include <climits>

namespace Eco::Kernel::Runtime {

// The value stored by the most recent `saveState` run. It is meaningful only while `s_hasState` is set, and it is
// reached by the collector only through the scanner `registerGcRootScanner` adds.
static HPointer s_savedState = {};
// Whether any `saveState` run has stored a value. Nothing clears it.
static bool s_hasState = false;

namespace {

// Returns the Task that `dirname` describes, reading the directory now.
HPointer dirnameBody(HPointer /*captured*/) {
    std::string dir = eco::platform::currentExecutableDir();
    if (dir.empty()) {
        return failString("Cannot determine executable path");
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
// store happens before the allocation of that Task, so the scanner, if registered, already covers it.
HPointer saveStateBody(HPointer captured) {
    s_savedState = captured;
    s_hasState = true;
    return succeedUnit();
}

/// The null-constructor tag of `Json.Encode.null` (the `ENC_NULL` encoder constant in JsonExports.cpp).
constexpr u16 JSON_ENC_NULL = 0;

/// Returns a Task that succeeds with the saved state, or, when none has been stored, with JSON `null` (the
/// `Json.Encode.null` value, which `Json.Decode.null` accepts), as the JS kernel does.
HPointer loadStateBody(HPointer /*captured*/) {
    if (s_hasState) {
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
    Elm::Allocator::instance().getRootSet().addExternalRootScanner(
        // The scanner works on the encoded word, the form `EvacuateFn` takes, and writes back whatever it is
        // rewritten to.
        [](Elm::RootSet::EvacuateFn evacuate) {
            if (!s_hasState) return;
            uint64_t encoded = Export::encode(s_savedState);
            evacuate(encoded);
            s_savedState = Export::decode(encoded);
        });
}

} // namespace Eco::Kernel::Runtime
