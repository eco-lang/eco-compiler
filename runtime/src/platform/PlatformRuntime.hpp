#ifndef ECO_PLATFORM_RUNTIME_HPP
#define ECO_PLATFORM_RUNTIME_HPP

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "Scheduler.hpp"
#include <string>
#include <unordered_map>
#include <vector>
#include <cstdint>

namespace Elm::Platform {

/// Stress-test flags passed to Platform.worker as the `flags` argument.
///
/// Consumed by stress-elm programs that opt in by declaring
/// `main : Program StressFlags Model Msg` via StressHarness. When unset
/// (default), initWorker passes Unit so existing tests are unaffected.
struct StressFlags {
    int64_t numLoops;
    int64_t maxSize;
    int64_t timeoutMs;
    int64_t seed;
    int64_t startMs;
    bool    verbose;
};

class PlatformRuntime {
public:
    static PlatformRuntime& instance();

    // Manager registry
    // All fields are encoded HPointers (uint64_t) so the external root
    // scanner can walk/rewrite them across GC. `registerManager` converts
    // HPointer arguments to encoded form; accessors decode on read.
    struct ManagerInfo {
        uint64_t init;        // encoded HPointer to Task or 0-arg Closure
        uint64_t onEffects;   // encoded HPointer to 4-arg Closure
        uint64_t onSelfMsg;   // encoded HPointer to 3-arg Closure
        uint64_t cmdMap;      // encoded HPointer (Nil if no commands)
        uint64_t subMap;      // encoded HPointer (Nil if no subscriptions)
    };

    void registerManager(const std::string& home, const ManagerInfo& info);

    // True if an effect manager is registered under `home`. Used by
    // PortRuntime to reject port names that collide with real effect
    // managers (JS _Platform_checkPortName parity, PORT_001).
    bool hasManager(const std::string& home) const {
        return managers_.find(home) != managers_.end();
    }

    // Effect setup (called once from Platform.worker)
    HPointer setupEffects(HPointer sendToAppClosure);

    // Effect dispatch
    void enqueueEffects(HPointer cmdBag, HPointer subBag);

    // Routing
    void sendToApp(HPointer router, HPointer msg);
    HPointer sendToSelf(HPointer router, HPointer msg);

    // Deliver a message into the app's update cycle via the stored
    // sendToApp closure. Used by incoming ports (PortRuntime) and the
    // applyTaggers closure evaluator. Must run on the eco thread.
    void deliverToApp(HPointer msg);

    // Apply an innermost-first tagger chain to a value. Public so the
    // gatherEffects applyTaggers closure evaluator can reach it.
    HPointer applyTaggers(HPointer taggers, HPointer value);

    // Platform.worker initialization
    HPointer initWorker(HPointer impl);

    // Embedding ready handshake (eco_app_start): invoked by initWorker
    // after the initial effects have dispatched, immediately before the
    // event loop starts blocking. Plain function pointer + user data so
    // no GC interaction is possible.
    using ReadyHook = void (*)(void* user);
    void setReadyHook(ReadyHook hook, void* user) {
        readyHook_ = hook;
        readyHookUser_ = user;
    }

    // Optional stress-test flags: if set, initWorker builds a StressFlags
    // record and passes it as the `flags` arg. Clear to fall back to Unit.
    void setPendingFlags(const StressFlags& flags) {
        pendingFlags_ = flags;
        hasPendingFlags_ = true;
    }
    void clearPendingFlags() { hasPendingFlags_ = false; }

    // Model storage access (for workerSendToAppEvaluator)
    uint64_t getModelStorage() const { return modelStorage_; }
    void setModelStorage(uint64_t val) { modelStorage_ = val; }

private:
    PlatformRuntime();

    // Per-manager scratch: accumulated Cmd/Sub message HPointers for one
    // effect batch. Stored on the runtime so the external root scanner can
    // traverse them across any GC that runs during gatherEffects /
    // onEffects / drain.
    struct PerManagerEffects {
        std::vector<uint64_t> cmdHPs;  // encoded HPointers (Cmd msg values)
        std::vector<uint64_t> subHPs;  // encoded HPointers (Sub msg values)
    };

    // Gather effects from bag tree into per-manager lists
    void gatherEffects(bool isCmd, HPointer bag,
                       std::unordered_map<std::string, PerManagerEffects>& effects,
                       HPointer taggers);

    void dispatchEffects();  // reads activeBatch_ and writes effectsScratch_

    // Self-message protocol for one manager (invoked by the scheduler's
    // dedicated self-process step). Reads the manager's router + current
    // state, runs onSelfMsg(router, msg, state), runs the returned
    // Task Never State to completion, and writes the produced state back
    // into managerStates_[home].state so the next message sees it (P1c).
    void handleSelfMsg(const std::string& home, HPointer msg);

    // Manager registry
    std::unordered_map<std::string, ManagerInfo> managers_;

    // Per-manager runtime state
    struct ManagerState {
        uint64_t selfProcess;  // encoded HPointer to Process
        uint64_t router;       // encoded HPointer to Router Custom
        uint64_t state;        // encoded HPointer to current manager state
    };
    std::unordered_map<std::string, ManagerState> managerStates_;

    // Effects queue
    struct FxBatch { uint64_t cmdBag; uint64_t subBag; };
    std::vector<FxBatch> effectsQueue_;
    bool effectsActive_ = false;

    // Batch currently being dispatched. Valid only while dispatchActive_
    // is true; scanned by the external root scanner during that window so
    // its cmdBag/subBag survive any GC triggered inside dispatchEffects.
    FxBatch activeBatch_{0, 0};
    bool dispatchActive_ = false;

    // Per-manager scratch populated by gatherEffects and drained by
    // dispatchEffects. Scanned by the external root scanner while
    // dispatchActive_ is true.
    std::unordered_map<std::string, PerManagerEffects> effectsScratch_;

    // Global model state for worker (GC-rooted)
    uint64_t modelStorage_ = 0;  // encoded HPointer
    bool modelRooted_ = false;

    // sendToApp closure for the current program
    uint64_t sendToAppClosure_ = 0;

    // Optional pending flags built into the `flags` arg for the next
    // initWorker call. When absent, initWorker passes Unit.
    StressFlags pendingFlags_{};
    bool hasPendingFlags_ = false;

    // Embedding ready handshake (see setReadyHook).
    ReadyHook readyHook_ = nullptr;
    void* readyHookUser_ = nullptr;
};

} // namespace Elm::Platform

#endif // ECO_PLATFORM_RUNTIME_HPP
