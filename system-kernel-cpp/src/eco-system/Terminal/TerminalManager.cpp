//===- TerminalManager.cpp - The C++ effect manager of System.Terminal ----===//
//
// plans/eco-system-library.md §3.6, Appendix C.0 / C.4 and Phase 5 step
// 5.3. Layout: TerminalManager.hpp.
//
//   * onEffects: the OnResize taggers replace the stored list (encoded words
//     in a T5 registry, with the router). A SignalService SIGWINCH listener
//     is registered while the list is non-empty (it holds no pendingAsync:
//     resize subscriptions do not keep the program alive, §3.4).
//   * Delivery (the SIGWINCH listener, main thread): read the new size with
//     TIOCGWINSZ (nothing is delivered when no stdio fd is a terminal, like
//     Node's stdout 'resize'), snapshot the taggers into one rooted buffer,
//     then for each: tagger ( columns, rows ) → sendToApp → drain() (T8,
//     G12).
//   * subMap composes the tagger (TimeEffectManager composition pattern).
//     There are no commands.
//
// Templates used: T6 (rooted registration per G14), T5, T8, G6.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Terminal/TerminalManager.hpp"

#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/Registry.hpp"
#include "eco-system/Core/SignalService.hpp"
#include "eco-system/Terminal/Terminal.hpp"

#include <csignal>
#include <vector>

#ifndef SIGWINCH
#define SIGWINCH 28   // Windows: never subscribed (SignalService is a no-op there)
#endif

namespace Eco::System {

namespace {

using namespace TerminalManager;

struct ManagerState {
    uint64_t routerEnc = 0;
    std::vector<uint64_t> taggers;   // encoded OnResize taggers

    template <typename F>
    void forEachWord(F&& f) {
        f(routerEnc);
        for (auto& w : taggers) f(w);
    }
};

Registry<ManagerState>& registry() {
    static auto* r = new Registry<ManagerState>("eco-system-terminal-manager");   // leaky
    return *r;
}

// The single state entry (re-created after a heap reset, F24).
ManagerState& state() {
    static int64_t id = 0;
    auto& r = registry();
    if (ManagerState* s = r.find(id)) return *s;
    id = r.insert(ManagerState{});
    return *r.find(id);
}

// Process-wide: SignalService listeners outlive any heap. 0 = not listening.
SignalService::ListenerId g_winchListener = 0;

// --- Delivery ----------------------------------------------------------------

void onWinch(int, void*) {
    int columns = 0, rows = 0;
    if (!terminalSize(columns, rows)) return;
    ManagerState& st = state();
    if (st.routerEnc == 0 || st.taggers.empty()) return;
    // Snapshot: update may change the subscriptions while we deliver.
    std::vector<HPointer> taggers;
    taggers.reserve(st.taggers.size());
    for (uint64_t w : st.taggers) taggers.push_back(dec(w));
    HPointer router = dec(st.routerEnc);
    HPointer arg = alloc::listNil();
    HPointer msg = alloc::listNil();
    // No allocation since the decodes above.
    Elm::StackRootGuard g({&router, &arg, &msg});
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(taggers.data(), taggers.size(), ~0ULL);
    for (size_t i = 0; i < taggers.size(); ++i) {
        arg = alloc::tuple2(alloc::unboxedInt(columns), alloc::unboxedInt(rows), 0x5);
        msg = Scheduler::callClosure1(taggers[i], arg);   // Elm call (G11)
        PlatformRuntime::instance().sendToApp(router, msg);
        Scheduler::instance().drain();
    }
    rs.restoreStackRangePoint(saved);
}

// --- Manager closures (C.0) ------------------------------------------------------

// init : Task Never ()  (a 0-arity thunk, forced by setupEffects)
void* initEval(void*[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

// onEffects : Router -> List (MyCmd msg) -> List (MySub msg) -> () -> Task Never ()
void* onEffectsEval(void* args[]) {
    HPointer router = dec(args[0]);
    HPointer subs = dec(args[2]);
    Elm::StackRootGuard g(&router, &subs);

    // A non-allocating walk (G5), then the registry update.
    std::vector<uint64_t> wanted;
    for (alloc::ListCursor c(subs); !c.done(); c.next()) {
        void* obj = Allocator::instance().resolve(c.current().p);
        if (!obj) continue;
        Custom* sub = static_cast<Custom*>(obj);
        if (sub->ctor == CTOR_ON_RESIZE) wanted.push_back(enc(sub->values[ON_RESIZE_TAGGER_FIELD].p));
    }
#ifdef _WIN32
    // A Sub is infallible: crash with a clear message (§1).
    if (!wanted.empty())
        ::Eco::Kernel::reportFatal("eco/system: System.Terminal.onResize is not supported on Windows yet");
#endif
    {
        ManagerState& st = state();
        st.routerEnc = enc(router);
        st.taggers = std::move(wanted);
        // POD service calls only (no heap allocation) while `st` is live.
        auto& svc = SignalService::instance();
        if (!st.taggers.empty() && g_winchListener == 0) {
            g_winchListener = svc.addListener(SIGWINCH, &onWinch, nullptr);
        } else if (st.taggers.empty() && g_winchListener != 0) {
            svc.removeListener(g_winchListener);
            g_winchListener = 0;
        }
    }
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

// onSelfMsg : Router -> Never -> () -> Task Never ()  (never sent)
void* onSelfMsgEval(void* args[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(dec(args[2]))));
}

// \size -> f (tagger size): args[0] = f, args[1] = tagger, args[2] = size.
void* composedTaggerEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer tagger = dec(args[1]);
    HPointer x = dec(args[2]);
    HPointer inner = alloc::listNil();
    Elm::StackRootGuard g({&f, &tagger, &x, &inner});
    inner = Scheduler::callClosure1(tagger, x);   // Elm call (G11)
    return reinterpret_cast<void*>(enc(Scheduler::callClosure1(f, inner)));
}

// subMap : (a -> b) -> MySub a -> MySub b — compose the tagger.
void* subMapEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer sub = dec(args[1]);
    HPointer tagger = alloc::listNil();
    HPointer composed = alloc::listNil();
    Elm::StackRootGuard g({&f, &sub, &tagger, &composed});
    {
        Custom* s = static_cast<Custom*>(Allocator::instance().resolve(sub));
        if (!s || s->ctor != CTOR_ON_RESIZE) return args[1];
        tagger = s->values[ON_RESIZE_TAGGER_FIELD].p;
    }
    composed = alloc::allocClosure(&composedTaggerEval, 3);
    {
        void* p = Allocator::instance().resolve(composed);   // captures right away (G8)
        alloc::closureCapture(p, alloc::boxed(f), PK_Boxed);
        alloc::closureCapture(p, alloc::boxed(tagger), PK_Boxed);
    }
    std::vector<Unboxable> fields{alloc::boxed(composed)};
    return reinterpret_cast<void*>(enc(alloc::custom(CTOR_ON_RESIZE, fields, 0)));
}

} // namespace

} // namespace Eco::System

using namespace Eco::System;

namespace {

// Allocates the manager closures in the rooted PortRuntime form (G14) and
// registers them under "System.Terminal". Subscriptions only: no cmdMap.
void registerTerminalManager() {
    HPointer initCl = alloc::listNil();
    HPointer effCl = alloc::listNil();
    HPointer selfCl = alloc::listNil();
    HPointer cmdMapCl = alloc::listNil();
    HPointer subMapCl = alloc::listNil();
    Elm::StackRootGuard g({&initCl, &effCl, &selfCl, &cmdMapCl, &subMapCl});
    initCl = alloc::allocClosure(&initEval, 0);
    effCl = alloc::allocClosure(&onEffectsEval, 4);
    selfCl = alloc::allocClosure(&onSelfMsgEval, 3);
    subMapCl = alloc::allocClosure(&subMapEval, 2);
    PlatformRuntime::ManagerInfo info{enc(initCl), enc(effCl), enc(selfCl),
                                      enc(cmdMapCl), enc(subMapCl)};
    PlatformRuntime::instance().registerManager("System.Terminal", info);   // no allocation after encode
}

} // namespace

extern "C" uint64_t Eco_System_registerManager_System_Terminal() {
    ECO_KERNEL_GUARD(
        registerTerminalManager();
        return enc(alloc::unit());
    )
}
