//===- SystemManager.cpp - The C++ effect manager of `System` -------------===//
//
// plans/eco-system-library.md §3.6, §3.7 and Appendix C.0 / C.1. Layout:
// SystemManager.hpp.
//
//   * onEffects: every `Execute t` is rawSpawn'ed (its result is ignored),
//     then the scheduler is drained once. The subscriptions replace the
//     three stored msg lists (encoded words in a T5 registry). A
//     SignalService listener for SIGINT / SIGTERM is registered while the
//     matching list is non-empty; the quiescence listener is registered
//     once, on the first OnEmptyEventLoop subscription.
//   * subMap applies `f` to the stored msg now and rebuilds the same
//     constructor (as gren does); cmdMap returns the command unchanged.
//   * Delivery (quiescence listener, signal dispatch): snapshot the msgs of
//     the event into one rooted buffer, then sendToApp + drain() per msg
//     (G12).
//
// Signal subscriptions and the quiescence hook hold no pendingAsync (§3.4
// keep-alive rule): a program that only listens for them exits. Neither
// fires in embed mode (SignalService and the Scheduler check embedMode()).
//
// Templates used: T6 (manager, rooted registration per G14), T5 (state),
// T8/G12 (delivery), G6 (one root range for the snapshot).
//
//===----------------------------------------------------------------------===//

#include "eco-system/System/SystemManager.hpp"

#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/Registry.hpp"
#include "eco-system/Core/SignalService.hpp"

#include <csignal>
#include <vector>

namespace Eco::System {

namespace {

using namespace SystemManager;

struct ManagerState {
    uint64_t routerEnc = 0;
    std::vector<uint64_t> msgs[SUB_CTOR_COUNT];   // encoded msgs per MySub tag

    template <typename F>
    void forEachWord(F&& f) {
        f(routerEnc);
        for (auto& list : msgs)
            for (auto& w : list) f(w);
    }
};

Registry<ManagerState>& registry() {
    static auto* r = new Registry<ManagerState>("eco-system-system-manager");   // leaky
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
SignalService::ListenerId g_sigintListener = 0;
SignalService::ListenerId g_sigtermListener = 0;
bool g_quiescenceRegistered = false;

// --- Delivery ----------------------------------------------------------------

// Sends every stored msg of MySub tag `which` to the app, draining after
// each (G12). The msgs are snapshotted first: update may change the
// subscriptions (and the stored lists) while we deliver.
void deliver(int which) {
    ManagerState& st = state();
    if (st.routerEnc == 0 || st.msgs[which].empty()) return;
    std::vector<HPointer> msgs;
    msgs.reserve(st.msgs[which].size());
    for (uint64_t w : st.msgs[which]) msgs.push_back(dec(w));
    HPointer router = dec(st.routerEnc);
    // No allocation since the decode above.
    Elm::StackRootGuard g(&router);
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    rs.pushStackRootRange(msgs.data(), msgs.size(), ~0ULL);
    for (size_t i = 0; i < msgs.size(); ++i) {
        PlatformRuntime::instance().sendToApp(router, msgs[i]);
        Scheduler::instance().drain();
    }
    rs.restoreStackRangePoint(saved);
}

void onQuiescent(void*) {
    try {
        deliver(CTOR_ON_EMPTY_EVENT_LOOP);
    } catch (const std::exception& e) {
        ::Eco::Kernel::reportFatal(e.what());   // never unwind into the loop (F21)
    } catch (...) {
        ::Eco::Kernel::reportFatal("unknown native exception in onEmptyEventLoop");
    }
}

// SignalService listener (main thread, from the signal drain).
void onSignal(int signo, void*) {
    if (signo == SIGINT) deliver(CTOR_ON_SIGNAL_INTERRUPT);
    else if (signo == SIGTERM) deliver(CTOR_ON_SIGNAL_TERMINATE);
}

void reconcileSignal(int signo, bool wanted, SignalService::ListenerId& listener) {
    if (wanted && listener == 0) {
        // 0 again when inactive (embed mode, Windows): retried on the next
        // onEffects, which is a no-op there.
        listener = SignalService::instance().addListener(signo, &onSignal, nullptr);
    } else if (!wanted && listener != 0) {
        SignalService::instance().removeListener(listener);
        listener = 0;
    }
}

// --- Manager closures (C.0) ----------------------------------------------------

// init : Task Never ()  (a 0-arity thunk, forced by setupEffects)
void* initEval(void*[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

// onEffects : Router -> List (MyCmd msg) -> List (MySub msg) -> () -> Task Never ()
void* onEffectsEval(void* args[]) {
    HPointer router = dec(args[0]);
    HPointer cmds = dec(args[1]);
    HPointer subs = dec(args[2]);
    Elm::StackRootGuard g(&router, &cmds, &subs);

    // Subscriptions: a non-allocating walk (G5), then the registry update.
    std::vector<uint64_t> wanted[SUB_CTOR_COUNT];
    for (alloc::ListCursor c(subs); !c.done(); c.next()) {
        void* obj = Allocator::instance().resolve(c.current().p);
        if (!obj) continue;
        Custom* sub = static_cast<Custom*>(obj);
        if (sub->ctor < SUB_CTOR_COUNT) {
            wanted[sub->ctor].push_back(enc(sub->values[SUB_MSG_FIELD].p));
        }
    }
    {
        ManagerState& st = state();
        st.routerEnc = enc(router);
        for (int i = 0; i < SUB_CTOR_COUNT; ++i) st.msgs[i] = std::move(wanted[i]);
        // POD service calls only (no heap allocation) while `st` is live.
        reconcileSignal(SIGINT, !st.msgs[CTOR_ON_SIGNAL_INTERRUPT].empty(), g_sigintListener);
        reconcileSignal(SIGTERM, !st.msgs[CTOR_ON_SIGNAL_TERMINATE].empty(), g_sigtermListener);
        if (!st.msgs[CTOR_ON_EMPTY_EVENT_LOOP].empty() && !g_quiescenceRegistered) {
            g_quiescenceRegistered = true;
            Scheduler::instance().addQuiescenceListener(&onQuiescent, nullptr);
        }
    }

    // Commands: spawn every Execute task (allocates; the cursor stays rooted).
    bool spawned = false;
    {
        alloc::RootedListCursor c(cmds);
        Unboxable head;
        u8 kind;
        while (c.read(head, kind)) {
            HPointer task;
            {
                Custom* cmd = static_cast<Custom*>(Allocator::instance().resolve(head.p));
                task = cmd->values[EXECUTE_TASK_FIELD].p;   // no allocation in scope
            }
            Scheduler::instance().rawSpawn(task);           // allocProcess roots `task`
            spawned = true;
            c.advance();
        }
    }
    if (spawned) Scheduler::instance().drain();

    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

// onSelfMsg : Router -> Never -> () -> Task Never ()  (never sent)
void* onSelfMsgEval(void* args[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(dec(args[2]))));
}

// cmdMap : (a -> b) -> MyCmd a -> MyCmd b — Execute carries no msg.
void* cmdMapEval(void* args[]) {
    return args[1];
}

// subMap : (a -> b) -> MySub a -> MySub b — apply f to the msg now.
void* subMapEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer sub = dec(args[1]);
    HPointer msg = alloc::listNil();
    HPointer mapped = alloc::listNil();
    Elm::StackRootGuard g({&f, &sub, &msg, &mapped});
    uint16_t ctor;
    {
        Custom* s = static_cast<Custom*>(Allocator::instance().resolve(sub));
        ctor = static_cast<uint16_t>(s->ctor);
        msg = s->values[SUB_MSG_FIELD].p;
    }
    mapped = Scheduler::callClosure1(f, msg);   // Elm call (G11)
    std::vector<Unboxable> fields{alloc::boxed(mapped)};
    return reinterpret_cast<void*>(enc(alloc::custom(ctor, fields, 0)));
}

} // namespace

} // namespace Eco::System

using namespace Eco::System;

namespace {

// Allocates the five manager closures in the rooted PortRuntime form (G14)
// and registers them under "System".
void registerSystemManager() {
    HPointer initCl = alloc::listNil();
    HPointer effCl = alloc::listNil();
    HPointer selfCl = alloc::listNil();
    HPointer cmdMapCl = alloc::listNil();
    HPointer subMapCl = alloc::listNil();
    Elm::StackRootGuard g({&initCl, &effCl, &selfCl, &cmdMapCl, &subMapCl});
    initCl = alloc::allocClosure(&initEval, 0);
    effCl = alloc::allocClosure(&onEffectsEval, 4);
    selfCl = alloc::allocClosure(&onSelfMsgEval, 3);
    cmdMapCl = alloc::allocClosure(&cmdMapEval, 2);
    subMapCl = alloc::allocClosure(&subMapEval, 2);
    PlatformRuntime::ManagerInfo info{enc(initCl), enc(effCl), enc(selfCl),
                                      enc(cmdMapCl), enc(subMapCl)};
    PlatformRuntime::instance().registerManager("System", info);   // no allocation after encode
}

} // namespace

extern "C" uint64_t Eco_System_registerManager_System() {
    ECO_KERNEL_GUARD(
        registerSystemManager();
        return enc(alloc::unit());
    )
}
