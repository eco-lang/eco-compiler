//===- AsyncSources.cpp - The single eco/system scheduler async source ----===//
//
// See AsyncSources.hpp. Leaky singleton state (§3.4): never destroyed, so a
// late wake-up during std::exit never touches freed memory.
//
// Templates used: none (plumbing for T2/T8/T9 drains).
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/AsyncSources.hpp"
#include "eco-system/Core/Core.hpp"

#include <mutex>
#include <vector>

namespace Eco::System {

namespace {

struct Source {
    DrainFn drain;
    ReadyFn ready;
};

std::vector<Source>& sources() {
    static auto* v = new std::vector<Source>();   // main thread only
    return *v;
}

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
