// Elm ports let a program exchange JSON with the program that hosts it, and
// this component is the native runtime behind them.
//
// An Elm port is declared in Elm source and has a name. An outgoing port sends
// values from the program to the host; an incoming port delivers values from
// the host to the program as messages. Each port is registered as its own
// effect manager with `PlatformRuntime`, keyed by the bare port name, so port
// names must be unique within a program and must not collide with any other
// effect manager. Port commands and subscriptions are therefore gathered and
// dispatched like any other effect, and this component supplies the closures
// that a port's manager is made of.
//
// Two facts shape the rest. First, Elm code runs only on the eco thread, while
// a host may call in from any thread. So a host never touches an Elm value:
// it hands in JSON text, which is copied into a queue and decoded later on the
// eco thread, and it receives JSON text through a plain C callback. Second, an
// incoming port keeps two Elm values between calls, its decoder and the current
// list of taggers its subscriptions apply. The collector may move them, so this
// component reports them to the collector as roots.
//
// A subscriber is a host callback attached to an outgoing port. Payloads sent
// on an outgoing port before it has ever had a subscriber are buffered and
// handed, in order, to the first subscriber; two threads subscribing at once
// may split them. Once a port has had a subscriber, a payload sent while it
// has none is dropped.
//
// The C functions at the end, `eco_port_*`, are the host-facing form of the
// host API here.
#ifndef ECO_PLATFORM_PORT_RUNTIME_HPP
#define ECO_PLATFORM_PORT_RUNTIME_HPP

#include "allocator/Heap.hpp"
#include "platform/Liveness.hpp"
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace Elm::Platform {

// A host function that receives the payloads sent on an outgoing port, the
// same signature as `eco_port_callback` in `embed/eco_embed.h`.
//
// It is called with one payload as UTF-8 JSON, valid only during the call,
// and the `user` pointer it was subscribed with. It runs on the eco thread
// while the port's commands are dispatched, or, for payloads buffered before
// the port's first subscriber, on the thread that subscribed. It must not
// touch Elm values; it may call `eco_port_send`.
using EcoPortCallback = void (*)(const char* json_utf8, void* user);

/**
 * The single per-process registry of ports, through which the eco thread
 * and host threads exchange port payloads.
 *
 * The first group of functions is called on the eco thread by the kernel
 * functions and port effect managers. The host API may be called from any
 * thread. Registrations are never removed, so once a port is registered it
 * stays registered for the rest of the process.
 */
class PortRuntime {
public:
    // Returns the single `PortRuntime`, creating it on first use. It is never
    // destroyed.
    static PortRuntime& instance();

    // ---- eco-thread API (kernel exports / port effect managers) ----

    // Registers `name` as an incoming port whose payloads are decoded with
    // the Json decoder `decoder`, and registers its effect manager with
    // `PlatformRuntime`. Allocates, so it may collect.
    //
    // Prints a message to `stderr` and aborts the process if an effect
    // manager, including another port, is already registered as `name`. The
    // first registration of either kind also installs the root scanner and
    // the scheduler async source this component relies on.
    void registerIncoming(const std::string& name, HPointer decoder);

    // Registers `name` as an outgoing port and registers its effect manager
    // with `PlatformRuntime`, with the same failure and first-call effects as
    // `registerIncoming`.
    void registerOutgoing(const std::string& name);

    // Makes `subsList`, a list of taggers, the subscriptions of the incoming
    // port `name`, replacing any earlier list. Each tagger turns a decoded
    // payload into a message for the program. Does nothing if `name` is not
    // an incoming port.
    void setIncomingSubs(const std::string& name, HPointer subsList);

    // Sends the JSON payload `json` on the outgoing port `name`: calls each
    // of its subscribers with it, buffers it if the port has never had a
    // subscriber, and drops it otherwise. Does nothing if no port or subscription has used `name`.
    //
    // The subscribers are called without this registry's locks held, on the
    // calling thread. A subscriber removed by another thread during the call
    // may still be called once after `unsubscribeOutgoing` has returned.
    void deliverOutgoing(const std::string& name, const std::string& json);

    // Processes every payload queued by `sendIncoming`, oldest first, on the
    // eco thread: decodes it with its port's decoder, applies each of the
    // port's taggers to the result, and delivers each message to the program
    // with `PlatformRuntime::deliverToApp`. Releases each payload's hold once
    // it has been processed. Runs Elm code, so it may collect.
    //
    // A payload the decoder rejects is fatal: this prints the port name and
    // the JSON to `stderr` and aborts the process. A payload for a port with
    // no subscriptions is decoded and then discarded.
    void drainPendingSends();
    // Returns whether any payload is queued by `sendIncoming`. May be called
    // from any thread; it never waits on the collector's root scan.
    bool hasPendingSends();

    // ---- host API (any thread) ----

    // Queues a copy of the JSON text `json` for the incoming port `name` and
    // wakes the event loop, which decodes it later on the eco thread as
    // `drainPendingSends` describes. Returns false, and queues nothing, if
    // either argument is null or `name` is not a registered incoming port;
    // in particular it returns false before the program has registered its
    // ports.
    //
    // Each queued payload holds a `HoldKind::Port` hold from before it is
    // queued until it has been processed, so the event loop does not finish
    // while it waits. That the JSON is well formed or decodes is not checked
    // here.
    bool sendIncoming(const char* name, const char* json);

    // Subscribes `cb`, called with `user`, to the payloads sent on the
    // outgoing port `name`. Returns false if `name` or `cb` is null, and
    // true otherwise. True does not mean `name` is, or will become, an
    // outgoing port.
    //
    // `name` need not be registered yet: a host may subscribe before the
    // program registers its ports. `user` is kept and must stay valid until
    // the subscription is removed and any delivery in progress on another
    // thread has returned. If the port has never had a subscriber, this first
    // calls `cb` with the buffered payloads, in order, on the calling thread,
    // before the subscription takes effect; two threads subscribing at once
    // may split the buffer between them. Subscribing the same `cb` and `user`
    // twice makes two subscriptions.
    bool subscribeOutgoing(const char* name, EcoPortCallback cb, void* user);
    // Removes one subscription of `cb` with `user` from the outgoing port
    // `name`, and returns whether there was one. `cb` may still be called
    // once more if a delivery is in progress on another thread.
    bool unsubscribeOutgoing(const char* name, EcoPortCallback cb, void* user);

    // Introspection. A port counts once its registration has run; a name
    // known only from a subscription does not.

    // Returns the number of registered ports.
    int portCount();
    // Returns the name of the `i`th port registered, counting from 0, or a
    // null pointer if `i` is out of range. The string stays valid for the
    // rest of the process.
    const char* portName(int i);
    // Returns 1 if `name` is a registered incoming port, 0 if it is a
    // registered outgoing port, and -1 if it is neither or is null.
    int isIncoming(const char* name);

private:
    // Creates an empty registry; used only by `instance`.
    PortRuntime();

    /**
     * What is known about one port name. An entry made by a subscription
     * before the port registers has `registered` false.
     */
    struct PortInfo {
        bool registered = false;
        bool incoming = false;
        uint64_t decoder = 0;  // Encoded HPointer of an incoming port's decoder; 0 if none.
        uint64_t subs = 0;     // Encoded HPointer of the tagger list; 0 until the first `setIncomingSubs`.
        std::vector<std::pair<EcoPortCallback, void*>> sinks;  // Subscribers of an outgoing port.
        std::vector<std::string> buffered;  // Payloads sent before the first subscriber.
        bool everSubscribed = false;  // Set by the first subscription; buffering stops from then on.
    };

    // Installs, once, the root scanner that reports every port's decoder and
    // tagger list to the collector, and the scheduler async source made of
    // `drainPendingSends` and `hasPendingSends`. Not synchronised: it must be
    // called on the eco thread.
    void ensureRuntimeHooks();

    // Guards ports_ and registrationOrder_. The collector's root scanner takes
    // this mutex, so the eco thread must not hold it across an allocation.
    std::mutex portsMutex_;
    std::unordered_map<std::string, PortInfo> ports_;
    // Port names in registration order. A deque, so that growing it moves no
    // element and portName can return c_str() pointers that stay valid.
    std::deque<std::string> registrationOrder_;

    // Guards pendingSends_.
    std::mutex pendingMutex_;
    /**
     * One payload queued by sendIncoming, with the HoldKind::Port hold it owns
     * until drainPendingSends has processed it.
     */
    struct PendingSend {
        std::string name;
        std::string json;
        HoldToken hold;
    };
    std::deque<PendingSend> pendingSends_;

    bool hooksInstalled_ = false;  // Set by ensureRuntimeHooks; read and written on the eco thread only.
};

}  // namespace Elm::Platform

// The host-facing C functions declared in embed/eco_embed.h, each a thin
// wrapper over the PortRuntime function of the same purpose. The definitions in
// PortRuntime.cpp are weak on non-Windows targets, so the ones in
// embed/eco_embed.cpp take precedence wherever both are linked.
extern "C" {
// Calls `PortRuntime::sendIncoming`; returns 0 if it queued the payload and 1
// otherwise.
int eco_port_send(const char* port, const char* json_utf8);
// Calls `PortRuntime::subscribeOutgoing`; returns 0 on success and 1 otherwise.
int eco_port_subscribe(const char* port,
                       Elm::Platform::EcoPortCallback cb, void* user);
// Calls `PortRuntime::unsubscribeOutgoing`; returns 0 if a subscription was
// removed and 1 otherwise.
int eco_port_unsubscribe(const char* port,
                         Elm::Platform::EcoPortCallback cb, void* user);
// Returns `PortRuntime::portCount`.
int eco_port_count(void);
// Returns `PortRuntime::portName(i)`.
const char* eco_port_name(int i);
// Returns `PortRuntime::isIncoming(port)`.
int eco_port_is_incoming(const char* port);
}

#endif  // ECO_PLATFORM_PORT_RUNTIME_HPP
