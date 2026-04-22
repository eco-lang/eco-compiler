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
    struct ManagerInfo {
        HPointer init;        // Task (initial state)
        HPointer onEffects;   // router -> List cmd -> List sub -> state -> Task state
        HPointer onSelfMsg;   // router -> selfMsg -> state -> Task state
        HPointer cmdMap;      // nullable (Nil if no commands)
        HPointer subMap;      // nullable (Nil if no subscriptions)
    };

    void registerManager(const std::string& home, const ManagerInfo& info);

    // Effect setup (called once from Platform.worker)
    HPointer setupEffects(HPointer sendToAppClosure);

    // Effect dispatch
    void enqueueEffects(HPointer cmdBag, HPointer subBag);

    // Routing
    void sendToApp(HPointer router, HPointer msg);
    HPointer sendToSelf(HPointer router, HPointer msg);

    // Platform.worker initialization
    HPointer initWorker(HPointer impl);

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

    // Gather effects from bag tree into per-manager lists
    void gatherEffects(bool isCmd, HPointer bag,
                       std::unordered_map<std::string, std::pair<std::vector<uint64_t>, std::vector<uint64_t>>>& effects,
                       HPointer taggers);

    HPointer applyTaggers(HPointer taggers, HPointer value);

    void dispatchEffects(HPointer cmdBag, HPointer subBag);

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

    // Global model state for worker (GC-rooted)
    uint64_t modelStorage_ = 0;  // encoded HPointer
    bool modelRooted_ = false;

    // sendToApp closure for the current program
    uint64_t sendToAppClosure_ = 0;

    // Optional pending flags built into the `flags` arg for the next
    // initWorker call. When absent, initWorker passes Unit.
    StressFlags pendingFlags_{};
    bool hasPendingFlags_ = false;
};

} // namespace Elm::Platform

#endif // ECO_PLATFORM_RUNTIME_HPP
