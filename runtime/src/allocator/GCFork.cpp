// plans/threaded-gc-register-fixes.md §7.1 (HEAP_075): the single pthread_atfork
// registration. See GCFork.hpp.

#include "GCFork.hpp"

#include <atomic>
#include <mutex>

#if !defined(_WIN32)
#include <pthread.h>
#endif

namespace Elm::gc {

namespace {

std::atomic<const ForkHooks*> g_layers[kForkLayers];

// The layers whose prepare ran in THIS fork (glibc serialises the handlers of one
// fork on the forking thread). A layer registered between the prepare and the
// parent/child handlers is skipped there: its locks were never taken.
const ForkHooks* g_ran[kForkLayers];

void prep() {
    for (unsigned i = 0; i < kForkLayers; ++i) {
        const ForkHooks* h = g_layers[i].load(std::memory_order_acquire);
        g_ran[i] = h;
        if (h != nullptr) h->prepare();
    }
}

void parent() {
    for (unsigned i = kForkLayers; i-- > 0;) {
        const ForkHooks* h = g_ran[i];
        g_ran[i] = nullptr;
        if (h != nullptr) h->parent();
    }
}

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
