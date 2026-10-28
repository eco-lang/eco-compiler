#include "GCFork.hpp"

#include <atomic>
#include <mutex>

#if !defined(_WIN32)
#include <pthread.h>
#endif

namespace Elm::gc {

namespace {

// The hooks installed for each layer, or null for a layer not yet registered.
std::atomic<const ForkHooks*> g_layers[kForkLayers];

// The hooks whose prepare ran in the current fork, so that parent and child undo exactly
// those. A layer registered after the prepare is skipped there: its locks were never taken.
// Plain, not atomic: the handlers of one fork run in turn on the forking thread.
const ForkHooks* g_ran[kForkLayers];

// Runs every installed layer's prepare in increasing layer order and records which ran.
void prep() {
    for (unsigned i = 0; i < kForkLayers; ++i) {
        const ForkHooks* h = g_layers[i].load(std::memory_order_acquire);
        g_ran[i] = h;
        if (h != nullptr) h->prepare();
    }
}

// Runs the parent handler of each layer whose prepare ran, in decreasing order, and clears the record.
void parent() {
    for (unsigned i = kForkLayers; i-- > 0;) {
        const ForkHooks* h = g_ran[i];
        g_ran[i] = nullptr;
        if (h != nullptr) h->parent();
    }
}

// Runs the child handler of each layer whose prepare ran, in decreasing order, and clears the record.
void child() {
    for (unsigned i = kForkLayers; i-- > 0;) {
        const ForkHooks* h = g_ran[i];
        g_ran[i] = nullptr;
        if (h != nullptr) h->child();
    }
}

} // namespace

void registerForkLayer(ForkLayer layer, const ForkHooks& hooks) {
#if !defined(_WIN32)
    static std::once_flag once;
    std::call_once(once, [] { pthread_atfork(&prep, &parent, &child); });
#endif
    g_layers[layer].store(&hooks, std::memory_order_release);
}

} // namespace Elm::gc
