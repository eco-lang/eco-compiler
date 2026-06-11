#ifndef ECO_PLATFORM_PORT_RUNTIME_HPP
#define ECO_PLATFORM_PORT_RUNTIME_HPP

#include "allocator/Heap.hpp"
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace Elm::Platform {

/// Host-facing outgoing-port callback. Invoked with the port payload
/// serialized as a UTF-8 JSON string. Runs on the eco thread during effect
/// dispatch (or, for messages buffered before the first subscribe, on the
/// subscribing thread during the flush). Callbacks must be quick, must not
/// touch Elm values, and may only re-enter the runtime via eco_port_send.
using EcoPortCallback = void (*)(const char* json_utf8, void* user);

/// Native ports runtime (see plans/native-ports-and-embedding.md).
///
/// Each Elm port is registered as a pseudo effect manager with
/// PlatformRuntime, keyed by the bare port name (PORT_001: globally unique,
/// JS _Platform_checkPortName parity). The registry additionally holds:
///   - incoming ports: the Json decoder and the current subscription list
///     (composed taggers) — both encoded HPointers, GC-scanned (PORT_004)
///   - outgoing ports: native subscriber callbacks and the
///     buffer-until-first-subscribe queue (plain bytes, no GC interaction)
///
/// Threading (PORT_006): all Elm execution stays on the eco thread.
/// Host threads interact only via sendIncoming (queued, drained on the eco
/// thread through the Scheduler asyncSource mechanism) and the
/// subscribe/introspection API.
class PortRuntime {
public:
    static PortRuntime& instance();

    // ---- eco-thread API (kernel exports / port effect managers) ----

    /// Register an incoming port and its pseudo effect manager. Crashes on
    /// duplicate registration (PORT_001). Called from the generated
    /// @__eco_register_ports preamble via
    /// Elm_Kernel_Platform_registerIncomingPort.
    void registerIncoming(const std::string& name, HPointer decoder);

    /// Register an outgoing port and its pseudo effect manager.
    void registerOutgoing(const std::string& name);

    /// Incoming manager onEffects: snapshot the current composed-tagger
    /// subscription list for `name`.
    void setIncomingSubs(const std::string& name, HPointer subsList);

    /// Outgoing manager onEffects: deliver one serialized payload to the
    /// port's native subscribers, or buffer it if none are attached yet.
    void deliverOutgoing(const std::string& name, const std::string& json);

    /// Scheduler asyncSource hooks. drainPendingSends runs on the eco
    /// thread and performs decode + tagger application + deliverToApp for
    /// each queued incoming send; hasPendingSends is the (any-thread)
    /// ready predicate folded into the event-loop wait condition.
    void drainPendingSends();
    bool hasPendingSends();

    // ---- host API (any thread) ----

    /// Queue a JSON payload for an incoming port and wake the event loop.
    /// Returns false if the port is unknown or not incoming.
    bool sendIncoming(const char* name, const char* json);

    /// Attach a native callback to an outgoing port. Unknown names create
    /// a placeholder entry so hosts may subscribe before the program
    /// registers its ports. The first subscriber receives any buffered
    /// messages (flushed in order, on the calling thread).
    bool subscribeOutgoing(const char* name, EcoPortCallback cb, void* user);
    bool unsubscribeOutgoing(const char* name, EcoPortCallback cb, void* user);

    // ---- introspection (valid once registration has run) ----
    int portCount();
    const char* portName(int i);          // nullptr if out of range
    int isIncoming(const char* name);     // 1 incoming, 0 outgoing, -1 unknown

private:
    PortRuntime();

    struct PortInfo {
        bool registered = false;  // true once register{In,Out}going ran
        bool incoming = false;
        uint64_t decoder = 0;  // encoded HPointer (incoming) — GC-scanned
        uint64_t subs = 0;     // encoded HPointer tagger list — GC-scanned
        std::vector<std::pair<EcoPortCallback, void*>> sinks;  // outgoing
        std::vector<std::string> buffered;  // outgoing, pre-first-subscribe
        bool everSubscribed = false;  // buffering stops after the first sub
    };

    void ensureRuntimeHooks();  // root scanner + scheduler asyncSource

    // Guards ports_ and registrationOrder_. The GC root scanner takes this
    // mutex, so the eco thread must NEVER hold it across a GC allocation
    // (same discipline as TimeEffectManager's g_timerMutex).
    std::mutex portsMutex_;
    std::unordered_map<std::string, PortInfo> ports_;
    // Registration order for introspection. deque: stable element
    // addresses so portName() can return long-lived c_str() pointers.
    std::deque<std::string> registrationOrder_;

    std::mutex pendingMutex_;
    std::deque<std::pair<std::string, std::string>> pendingSends_;

    bool hooksInstalled_ = false;
};

}  // namespace Elm::Platform

// C ABI for host embedding (Phase 3 re-exports these from eco/embed.h).
extern "C" {
int eco_port_send(const char* port, const char* json_utf8);
int eco_port_subscribe(const char* port,
                       Elm::Platform::EcoPortCallback cb, void* user);
int eco_port_unsubscribe(const char* port,
                         Elm::Platform::EcoPortCallback cb, void* user);
int eco_port_count(void);
const char* eco_port_name(int i);
int eco_port_is_incoming(const char* port);
}

#endif  // ECO_PLATFORM_PORT_RUNTIME_HPP
