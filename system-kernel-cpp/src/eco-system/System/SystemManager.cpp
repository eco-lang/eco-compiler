//===- SystemManager.cpp - The C++ effect manager of `System` -------------===//
//
// The manager's state is one `Registry` entry, `ManagerState`: the router `onEffects` was last given, and, per
// `MySub` tag, the msgs of the current subscriptions, all as encoded words the registry's root scanner keeps up to
// date. Each `onEffects` replaces the lists wholesale and then makes the process-wide listeners match them: a
// `SignalService` listener for SIGINT or SIGTERM exists exactly while its list is non-empty, and the quiescence
// listener is added on the first `OnEmptyEventLoop` subscription and never removed (it returns false while unarmed or
// while there is nothing to deliver).
//
// Delivery may run the program's update, which may call `onEffects` and replace the very list being delivered. So
// `deliver` first copies the msgs into a local buffer pushed as one stack root range, then sends each one.
//
// `subMap` applies the tagging function to the stored msg at once and rebuilds the same constructor, rather than
// composing taggers; `cmdMap` returns the command unchanged, since `Execute` carries no msg.
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

/// The state of the System manager for one heap, as one `Registry` entry. Used on the eco thread only.
struct ManagerState {
    uint64_t routerEnc = 0;                       ///< 0 until the first `onEffects`.
    std::vector<uint64_t> msgs[SUB_CTOR_COUNT];   ///< Encoded msgs of the current subscriptions, per `MySub` tag.
    /// Whether the next empty event loop delivers `OnEmptyEventLoop`. Kept in the registry entry, so a heap
    /// reset, which re-creates the entry, arms it again.
    bool emptyLoopArmed = true;

    /// Calls `f` on every encoded word the entry holds, as `Registry` requires.
    template <typename F>
    void forEachWord(F&& f) {
        f(routerEnc);
        for (auto& list : msgs)
            for (auto& w : list) f(w);
    }
};

/// Returns the registry that holds the manager's state, creating it on first use. It is never destroyed.
Registry<ManagerState>& registry() {
    static auto* r = new Registry<ManagerState>("eco-system-system-manager");   // leaky
    return *r;
}

/// Returns the manager's one state entry, creating a fresh one (empty lists, armed) when there is none, which is
/// so on first use and after a heap reset clears the registry. The reference is valid until the next heap reset.
ManagerState& state() {
    static int64_t id = 0;
    auto& r = registry();
    if (ManagerState* s = r.find(id)) return *s;
    id = r.insert(ManagerState{});
    return *r.find(id);
}

// The process-wide listeners. They outlive any heap, so they are not in the registry entry.

/// The `SignalService` listener for SIGINT, or 0 when there is none.
SignalService::ListenerId g_sigintListener = 0;
/// The `SignalService` listener for SIGTERM, or 0 when there is none.
SignalService::ListenerId g_sigtermListener = 0;
/// Whether `onQuiescent` has been added as a scheduler quiescence listener. Never cleared.
bool g_quiescenceRegistered = false;

// --- Delivery ----------------------------------------------------------------

/// Sends each msg stored for `MySub` tag `which`, as it was on entry, to the program, draining the scheduler after
/// each. Does nothing before the first `onEffects` or when there are no such msgs.
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

/// The scheduler quiescence listener: when armed and there is an `OnEmptyEventLoop` subscription, disarms and
/// delivers its msgs, returning true; otherwise returns false. It disarms before delivering, so a
/// `rearmEmptyEventLoop` made while handling the msg stays in effect. An exception from the delivery is reported
/// as fatal, so none unwinds into the event loop.
bool onQuiescent(void*) {
    ManagerState& st = state();
    if (!st.emptyLoopArmed || st.msgs[CTOR_ON_EMPTY_EVENT_LOOP].empty()) return false;
    st.emptyLoopArmed = false;
    try {
        deliver(CTOR_ON_EMPTY_EVENT_LOOP);
    } catch (const std::exception& e) {
        ::Eco::Kernel::reportFatal(e.what());
    } catch (...) {
        ::Eco::Kernel::reportFatal("unknown native exception in onEmptyEventLoop");
    }
    return true;
}

} // namespace

namespace SystemManager {

void rearmEmptyEventLoop() { state().emptyLoopArmed = true; }

} // namespace SystemManager

namespace {

/// The `SignalService` listener for SIGINT and SIGTERM: delivers the msgs of the matching subscription.
void onSignal(int signo, void*) {
    if (signo == SIGINT) deliver(CTOR_ON_SIGNAL_INTERRUPT);
    else if (signo == SIGTERM) deliver(CTOR_ON_SIGNAL_TERMINATE);
}

/// Adds a listener for `signo` into `listener` when `wanted` and there is none, and removes the one in `listener`,
/// setting it to 0, when not `wanted`.
void reconcileSignal(int signo, bool wanted, SignalService::ListenerId& listener) {
    if (wanted && listener == 0) {
        // `addListener` gives 0 in embed mode and on Windows, so the next onEffects tries again, and fails again.
        listener = SignalService::instance().addListener(signo, &onSignal, nullptr);
    } else if (!wanted && listener != 0) {
        SignalService::instance().removeListener(listener);
        listener = 0;
    }
}

// --- Manager closures ---------------------------------------------------------

/// Evaluates `init : Task Never ()`, a closure of no arguments: returns a Task that succeeds with Unit.
void* initEval(void*[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

/// Evaluates `onEffects : Router -> List (MyCmd msg) -> List (MySub msg) -> () -> Task Never ()`.
///
/// Replaces the stored subscriptions with `args[2]` and the router with `args[0]`, adds or removes the signal
/// listeners to match, and adds the quiescence listener if there is an `OnEmptyEventLoop` subscription and it has
/// not been added yet. Then spawns the task of each command in `args[1]`, in order, and if it spawned any, drains
/// the scheduler once. Returns a Task that succeeds with Unit. Subscriptions for which `resolve` returns null, or
/// whose tag is not a `MySub` tag, are ignored.
void* onEffectsEval(void* args[]) {
    HPointer router = dec(args[0]);
    HPointer cmds = dec(args[1]);
    HPointer subs = dec(args[2]);
    Elm::StackRootGuard g(&router, &cmds, &subs);

    // Subscriptions: a walk that does not allocate, so the raw pointers stay valid, then the registry update.
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

/// Evaluates `onSelfMsg : Router -> Never -> () -> Task Never ()`: returns a Task that succeeds with the state,
/// `args[2]`. The manager sends itself no messages.
void* onSelfMsgEval(void* args[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(dec(args[2]))));
}

/// Evaluates `cmdMap : (a -> b) -> MyCmd a -> MyCmd b`: returns the command `args[1]` unchanged.
void* cmdMapEval(void* args[]) {
    return args[1];
}

/// Evaluates `subMap : (a -> b) -> MySub a -> MySub b`: returns a new subscription with the constructor of
/// `args[1]` and its msg replaced by the result of calling `args[0]` on it. `args[1]` must be a heap object.
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
    mapped = Scheduler::callClosure1(f, msg);
    std::vector<Unboxable> fields{alloc::boxed(mapped)};
    return reinterpret_cast<void*>(enc(alloc::custom(ctor, fields, 0)));
}

} // namespace

} // namespace Eco::System

using namespace Eco::System;

namespace {

/// Allocates the five manager closures, rooted until they are encoded, and registers them under "System".
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
