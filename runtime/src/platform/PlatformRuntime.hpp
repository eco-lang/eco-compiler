#ifndef ECO_PLATFORM_RUNTIME_HPP
#define ECO_PLATFORM_RUNTIME_HPP

// An Elm program does no input or output itself. Its `init` and `update` return commands (`Cmd`) and its
// `subscriptions` returns subscriptions (`Sub`), and the platform carries them out. This component is that
// platform for `Platform.worker` programs: it starts the program, runs its update cycle, and hands every
// command and subscription to the effect manager that owns it.
//
// An *effect manager* is a kernel module, identified by a name called its *home*, that does one kind of
// effect (timers, HTTP, tasks, a port). It registers itself with up to five Elm values: `init` gives its
// initial state, `onEffects` is given the manager's commands and subscriptions from one update and returns
// a Task producing its new state, `onSelfMsg` handles a message the manager sent itself and also returns a
// Task producing its new state, and `cmdMap` and `subMap` apply a message-transforming function to one of
// its commands or subscriptions. Each manager has a *self-process*, a scheduler process waiting for
// messages, and a *router*, a value the manager's closures are given in order to send a message to the
// application (`sendToApp`) or to the manager itself (`sendToSelf`). A router is a Custom with constructor
// `CTOR_Router` whose field 0 is the program's sendToApp closure and whose field 1 is the self-process's id
// as an unboxed Int. It holds the id rather than the Process because a Process is immutable and every step
// makes a new version; the id finds the latest one.
//
// Commands and subscriptions reach this component as *bags*: a tree whose leaves (`Fx_Leaf`) name a home and
// carry one effect value, whose nodes (`Fx_Node`) hold a list of bags, and whose map nodes (`Fx_Map`) wrap a
// bag in a function to apply to every message it produces. Dispatching one batch of effects walks both bags,
// collects each manager's values into a list, calls each manager's `onEffects`, and runs the returned Task to
// completion to get the manager's next state. A value under one or more `Fx_Map` nodes is first given to
// the manager's `cmdMap` or `subMap` together with a closure that applies the collected functions, innermost
// first; a manager registered with no map function has them applied to the value directly.
//
// All of this runs Elm code, which may allocate and so move any nursery object. Every heap value this
// component keeps between calls is therefore stored as an encoded HPointer word in a member, and a GC
// external root scanner registered by the constructor evacuates those words, so a collection updates them in
// place. The values that only live while one batch is being dispatched are kept in members for the same
// reason, and are scanned only during that window.
//
// The component is a process singleton and runs on the eco thread, the one thread that runs Elm code; its
// state has no lock. Its scanner is registered with the root set of the thread that first calls `instance`.

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "Scheduler.hpp"
#include <string>
#include <unordered_map>
#include <vector>
#include <cstdint>

namespace Elm::Platform {

/**
 * The runtime of an Elm `Platform.worker` program: its effect-manager registry, the state of each manager,
 * the current model, and the dispatch of commands and subscriptions.
 *
 * There is one, obtained with `instance`, created on first use and never destroyed. Nothing in the class
 * prevents a copy, but a copy would not be scanned by the collector and must not be made. Every function
 * must be called on the eco thread.
 */
class PlatformRuntime {
public:
    // Returns the process's one `PlatformRuntime`, creating it on the first call. The constructor registers
    // the runtime's GC root scanner with the calling thread's root set, so the first call must be made on the
    // eco thread. If that thread has no heap yet, the first call gives it one.
    static PlatformRuntime& instance();

    /**
     * The closures an effect manager registers with, each stored as an encoded HPointer word so that the
     * runtime's root scanner can update it when a collection moves the value.
     *
     * The caller encodes the words; `registerManager` copies them as they are. A field holding the Empty
     * constant (`listNil()`), or any other embedded constant, means the manager has no such closure.
     */
    struct ManagerInfo {
        uint64_t init;        // A Task giving the initial state, or a closure of arity 0 that returns one.
        uint64_t onEffects;   // Closure of `router`, commands, subscriptions and state, returning a Task.
        uint64_t onSelfMsg;   // Closure of `router`, message and state, returning a Task.
        uint64_t cmdMap;      // Closure of a tagging function and a command.
        uint64_t subMap;      // Closure of a tagging function and a subscription.
    };

    // Registers the effect manager `home` with the closures in `info`, replacing any manager already
    // registered under that name. A manager registered after `setupEffects` has run has no self-process,
    // router or state, and its effects are gathered but never dispatched. Re-registering a manager that
    // `setupEffects` has started keeps its self-process, router and state.
    void registerManager(const std::string& home, const ManagerInfo& info);

    // Returns whether an effect manager is registered under `home`.
    bool hasManager(const std::string& home) const {
        return managers_.find(home) != managers_.end();
    }

    // Starts every registered effect manager and returns the Empty constant (`{}`).
    //
    // `sendToAppClosure` becomes the program's sendToApp closure, which every router carries and
    // `deliverToApp` calls. For each manager, in no particular order, this spawns its self-process, builds its
    // router, and runs its `init` Task to completion, scheduler drain included. The manager's state is the
    // value the Task succeeds with, or `[]` if it has no `init` or the Task fails or does not finish during the
    // drain. Calling it again starts every manager afresh with new self-processes.
    HPointer setupEffects(HPointer sendToAppClosure);

    // Dispatches the commands in `cmdBag` and the subscriptions in `subBag` to their effect managers.
    //
    // Each manager registered and started by `setupEffects` that has an `onEffects` closure is called once
    // with its own commands and subscriptions, which may be empty lists, and the Task it returns is run to
    // completion; if that Task succeeds during the drain, its value becomes the manager's new state. Managers
    // are visited in no particular order. A leaf whose home names no registered manager is dropped.
    //
    // A call made while a dispatch is already running, from Elm code that dispatch runs, only queues its
    // bags. The outermost call dispatches queued batches in order until the queue is empty, and returns then.
    void enqueueEffects(HPointer cmdBag, HPointer subBag);

    // Calls the sendToApp closure held in field 0 of `router` with `msg`. The closure `initWorker` builds runs
    // the program's update for `msg` before returning. Does nothing if `router` is not a heap object.
    void sendToApp(HPointer router, HPointer msg);

    // Puts `msg` in the mailbox of the self-process whose id `router` holds, now rather than when the
    // returned Task is run, and returns a Task that succeeds with `()`.
    //
    // Nothing is sent if `router` is not a heap object or that process is no longer live.
    HPointer sendToSelf(HPointer router, HPointer msg);

    // Calls the sendToApp closure given to `setupEffects` with `msg`, as `sendToApp` does. Does nothing before
    // `setupEffects` has been called.
    void deliverToApp(HPointer msg);

    // Applies each function in the list `taggers` to `value` in turn, first element first, and returns the
    // result. Each function is Elm code, so this may collect.
    HPointer applyTaggers(HPointer taggers, HPointer value);

    // Runs the `Platform.worker` program whose record of `init`, `subscriptions` and `update` is `impl`, and
    // returns the Empty constant when the event loop returns.
    //
    // In order, this decodes the flags, calls `init` with them, stores the model, builds the sendToApp closure,
    // starts the effect managers (`setupEffects`), dispatches `init`'s command with the first subscriptions,
    // calls the ready hook, and runs the scheduler's event loop. The flags are the JSON given to
    // `setPendingFlagsJson`, or `null` if none was, decoded by the decoder given to `setFlagsDecoder`. Without
    // a decoder the flags are `()`. The process is aborted with a message on standard error if decoding
    // fails, or if there is no decoder and the pending JSON is anything other than `null`.
    //
    // If `impl` or `init`'s result is not a heap object, it returns at once, before the ready hook and the
    // event loop.
    HPointer initWorker(HPointer impl);

    // A function the embedding host gives to be told that the program has started. `initWorker` calls it with
    // the `user` pointer given alongside it, on the eco thread, after the effects of `init` have been
    // dispatched and before the event loop starts.
    using ReadyHook = void (*)(void* user);

    // Makes `hook` the ready hook, replacing any previous one; a null `hook` sets none. `user` is kept and
    // must stay valid until the hook has been called.
    void setReadyHook(ReadyHook hook, void* user) {
        readyHook_ = hook;
        readyHookUser_ = user;
    }

    // Sets the decoder `initWorker` uses to turn the flags JSON into the value given to `init`. The decoder is
    // kept, as a GC root, until replaced.
    void setFlagsDecoder(HPointer decoder);

    // Sets the flags JSON `initWorker` will decode, replacing any set before.
    void setPendingFlagsJson(const std::string& json) {
        pendingFlagsJson_ = json;
        hasPendingFlagsJson_ = true;
    }

    // Forgets the flags JSON, so that `initWorker` decodes `null` if a decoder is set.
    void clearPendingFlagsJson() {
        pendingFlagsJson_.clear();
        hasPendingFlagsJson_ = false;
    }

    // Returns the current model as an encoded HPointer, or 0 before `initWorker` has stored one.
    uint64_t getModelStorage() const { return modelStorage_; }

    // Replaces the current model with the encoded HPointer `val`, which must be a boxed value.
    void setModelStorage(uint64_t val) { modelStorage_ = val; }

private:
    // Creates the runtime and registers its GC external root scanner with the calling thread's root set.
    PlatformRuntime();

    /**
     * The effect values one manager has been given in the batch being dispatched, as encoded HPointers.
     */
    struct PerManagerEffects {
        std::vector<uint64_t> cmdHPs;
        std::vector<uint64_t> subHPs;
    };

    // Walks `bag` and appends each leaf's value to the entry in `effects` for the leaf's home, in the
    // commands list if `isCmd` and the subscriptions list otherwise.
    //
    // `taggers` is the list of functions from the `Fx_Map` nodes above `bag`, innermost first. A leaf with
    // no taggers is appended as it is; otherwise the value appended is what the manager's map closure returns
    // for it, as the file comment describes. A leaf whose home has no entry in `effects` is dropped. Appended
    // values are kept alive across collections only if `effects` is `effectsScratch_` and a dispatch is active.
    void gatherEffects(bool isCmd, HPointer bag,
                       std::unordered_map<std::string, PerManagerEffects>& effects,
                       HPointer taggers);

    // Dispatches the batch in `activeBatch_`, as `enqueueEffects` describes, using `effectsScratch_` for the
    // gathered values. Requires `dispatchActive_` to be set.
    void dispatchEffects();

    // Handles `msg` sent to the self-process of manager `home`: calls `onSelfMsg` with the manager's router,
    // `msg` and its state, and runs the returned Task to completion.
    //
    // The Task's success value becomes the manager's state only if it differs from the state `onSelfMsg` was
    // given, so that a state written meanwhile by an `onEffects` run inside the handler is kept. Does nothing
    // if `home` was not started or has no `onSelfMsg`.
    void handleSelfMsg(const std::string& home, HPointer msg);

    // Every uint64_t below that holds a heap value is an encoded HPointer, evacuated by the root scanner
    // (some only while `dispatchActive_` is set).

    std::unordered_map<std::string, ManagerInfo> managers_;

    /**
     * What `setupEffects` made for one manager, and its current state.
     */
    struct ManagerState {
        uint64_t selfProcess;  // The self-process as spawned, a version that goes stale; its id is in `router`.
        uint64_t router;
        uint64_t state;
    };
    std::unordered_map<std::string, ManagerState> managerStates_;

    /**
     * One call's command bag and subscription bag.
     */
    struct FxBatch { uint64_t cmdBag; uint64_t subBag; };
    std::vector<FxBatch> effectsQueue_;   // Batches waiting for the running dispatch to finish.
    bool effectsActive_ = false;          // Set while `enqueueEffects` is draining the queue.

    // The batch being dispatched and the values gathered from it. They are meaningful, and scanned, only while
    // `dispatchActive_` is set.
    FxBatch activeBatch_{0, 0};
    bool dispatchActive_ = false;
    std::unordered_map<std::string, PerManagerEffects> effectsScratch_;

    uint64_t modelStorage_ = 0;
    bool modelRooted_ = false;  // Whether `modelStorage_` has been registered as a value root.

    uint64_t sendToAppClosure_ = 0;  // 0 until `setupEffects` is called.

    // Returns the value the registered flags decoder produces for `json`, boxed. Aborts the process, after
    // writing `json` to standard error, if decoding fails. Requires a decoder to have been set.
    HPointer decodeFlags(const std::string& json);

    uint64_t flagsDecoder_ = 0;  // 0 when no decoder has been set.
    std::string pendingFlagsJson_;
    bool hasPendingFlagsJson_ = false;

    ReadyHook readyHook_ = nullptr;  // Null when no hook is set.
    void* readyHookUser_ = nullptr;  // May be null; not owned, passed to `readyHook_` unchecked.
};

} // namespace Elm::Platform

#endif // ECO_PLATFORM_RUNTIME_HPP
