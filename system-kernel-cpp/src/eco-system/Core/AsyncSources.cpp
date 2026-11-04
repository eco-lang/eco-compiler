//===- AsyncSources.cpp - The single eco/system scheduler async source ----===//
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/AsyncSources.hpp"
#include "eco-system/Core/Core.hpp"

#include <mutex>
#include <vector>

namespace Eco::System {

namespace {

// One drain source: a drain and its ready predicate.
struct Source {
    DrainFn drain;
    ReadyFn ready;
};

// Returns the drain source list, in the order added. It is allocated on first use and never freed, so it
// outlives static destruction.
std::vector<Source>& sources() {
    static auto* v = new std::vector<Source>();   // eco thread only
    return *v;
}

// Returns whether any drain source's predicate is true. This is the ready predicate of the source
// `ensureAsyncSource` registers.
bool anyReady() {
    auto& v = sources();
    for (size_t i = 0; i < v.size(); ++i) {
        if (v[i].ready()) return true;
    }
    return false;
}

} // namespace

void runDrainSources() {
    auto& v = sources();
    // By index: a drain may add a source (the vector may reallocate).
    for (size_t i = 0; i < v.size(); ++i) {
        DrainFn d = v[i].drain;
        d();
    }
}

void ensureAsyncSource() {
    static std::once_flag flag;
    std::call_once(flag, [] {
        Scheduler::instance().registerAsyncSource(
            [] { runDrainSources(); },
            [] { return anyReady(); });
    });
}

void addDrainSource(DrainFn drain, ReadyFn ready) {
    ensureAsyncSource();
    auto& v = sources();
    for (const auto& s : v) {
        if (s.drain == drain) return;
    }
    v.push_back(Source{drain, ready});
}

} // namespace Eco::System
