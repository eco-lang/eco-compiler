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
};

} // namespace Elm::Platform

#endif // ECO_PLATFORM_RUNTIME_HPP
