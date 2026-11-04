//===- TerminalManager.cpp - The C++ effect manager of Terminal ----===//
//
// The manager keeps its state in C++, not in the Elm state value, which is always `()`. The state is the router
// and the current taggers, held as encoded words in a single-entry `Registry`, so the collector keeps them alive
// and up to date. A heap reset empties the registry, and the next lookup creates a new, empty entry.
//
// The SIGWINCH listener is process-wide, since `SignalService` survives a heap reset. `onEffects` adds it when
// there are taggers and none is registered, and removes it when the taggers are empty; a heap reset leaves it
// registered until the next `onEffects`, and `onWinch` then does nothing. It takes no liveness hold, which is why a
// resize subscription does not keep the program running.
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
#define SIGWINCH 28   // Windows has no SIGWINCH; defined only so the code compiles, and never subscribed
#endif

namespace Eco::System {

namespace {

using namespace TerminalManager;

/// The manager's state: the router messages are sent through and the taggers of the current subscriptions, in
/// the order the subscription list gave them, all as encoded HPointer words. `routerEnc` is 0 until the first
/// `onEffects`.
struct ManagerState {
    uint64_t routerEnc = 0;
    std::vector<uint64_t> taggers;

    /// Calls `f` on every encoded word the state holds, for the registry's root scanner.
    template <typename F>
    void forEachWord(F&& f) {
        f(routerEnc);
        for (auto& w : taggers) f(w);
    }
};

/// Returns the registry that holds the manager's state, creating it on the first call. It is never deleted.
Registry<ManagerState>& registry() {
    static auto* r = new Registry<ManagerState>("eco-system-terminal-manager");
    return *r;
}

/// Returns the manager's single state entry, creating an empty one when there is none, as on the first call and
/// after a heap reset. The reference is valid until the next heap reset; look it up again after calling into Elm.
ManagerState& state() {
    static int64_t id = 0;
    auto& r = registry();
    if (ManagerState* s = r.find(id)) return *s;
    id = r.insert(ManagerState{});
    return *r.find(id);
}

/// The SIGWINCH listener's identifier, or 0 when not listening. Process-wide, because a listener outlives a heap
/// reset.
SignalService::ListenerId g_winchListener = 0;

/// Sends the terminal's new size to the program once for each current subscription: each tagger is applied to
/// `( columns, rows )` and the result sent through the router, and the scheduler is drained after each one. Sends
/// nothing when `terminalSize` finds no size or there are no taggers. The SIGWINCH listener; runs on the eco
/// thread from the signal drain.
void onWinch(int, void*) {
    int columns = 0, rows = 0;
    if (!terminalSize(columns, rows)) return;
    ManagerState& st = state();
    if (st.routerEnc == 0 || st.taggers.empty()) return;
    // Snapshot, rooted as one range: the program may change its subscriptions during delivery.
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
        msg = Scheduler::callClosure1(taggers[i], arg);
        PlatformRuntime::instance().sendToApp(router, msg);
        Scheduler::instance().drain();
    }
    rs.restoreStackRangePoint(saved);
}

/// Returns a Task that succeeds with `()`, the manager's initial Elm state. The evaluator of the arity-0 `init`
/// closure.
void* initEval(void*[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

/// Replaces the stored router and taggers with `args[0]` and the taggers of the `OnResize` values in the
/// subscription list `args[2]`, adds the SIGWINCH listener when the list becomes non-empty and removes it when it
/// becomes empty, and returns a Task that succeeds with `()`. The commands `args[1]` and state `args[3]` are
/// ignored. On Windows a non-empty list ends the process with `Eco::Kernel::reportFatal`. If `addListener` fails,
/// as in embed mode, nothing is listened for, and the next call tries again.
void* onEffectsEval(void* args[]) {
    HPointer router = dec(args[0]);
    HPointer subs = dec(args[2]);
    Elm::StackRootGuard g(&router, &subs);

    // The walk does not allocate, so `obj` stays valid while it is read.
    std::vector<uint64_t> wanted;
    for (alloc::ListCursor c(subs); !c.done(); c.next()) {
        void* obj = Allocator::instance().resolve(c.current().p);
        if (!obj) continue;
        Custom* sub = static_cast<Custom*>(obj);
        if (sub->ctor == CTOR_ON_RESIZE) wanted.push_back(enc(sub->values[ON_RESIZE_TAGGER_FIELD].p));
    }
#ifdef _WIN32
    // A Sub cannot report failure, so an unsupported one ends the process.
    if (!wanted.empty())
        ::Eco::Kernel::reportFatal("eco/system: Terminal.onResize is not supported on Windows yet");
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

/// Returns a Task that succeeds with the state `args[2]` unchanged. Nothing sends this manager a self-message.
void* onSelfMsgEval(void* args[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(dec(args[2]))));
}

/// Returns `f (tagger size)`, where `f` is `args[0]`, `tagger` is `args[1]` and `size` is `args[2]`. The evaluator
/// of the closures `subMapEval` builds, whose two captures are `f` and `tagger`.
void* composedTaggerEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer tagger = dec(args[1]);
    HPointer x = dec(args[2]);
    HPointer inner = alloc::listNil();
    Elm::StackRootGuard g({&f, &tagger, &x, &inner});
    inner = Scheduler::callClosure1(tagger, x);
    return reinterpret_cast<void*>(enc(Scheduler::callClosure1(f, inner)));
}

/// Returns an `OnResize` whose tagger is the subscription `args[1]`'s tagger followed by the function `args[0]`.
/// Returns `args[1]` itself when it is not an `OnResize` value.
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
        void* p = Allocator::instance().resolve(composed);   // no allocation until both captures are stored
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

/// Allocates the manager's closures and registers them with the runtime under "Terminal". The cmdMap slot is the
/// Empty constant, since the manager has no commands.
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
    PlatformRuntime::instance().registerManager("Terminal", info);   // no allocation after encode
}

} // namespace

extern "C" uint64_t Eco_System_registerManager_Terminal() {
    ECO_KERNEL_GUARD(
        registerTerminalManager();
        return enc(alloc::unit());
    )
}
