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
// A port is named by a string only until it is resolved: its registry entry,
// `eco_port`, is its handle (PORT_011). Entries are never erased and do not
// move, so a handle stays valid for the life of the process, and every
// operation after registration, the port managers' included, works on the
// handle instead of the name.
//
// A subscriber is a host callback attached to an outgoing port. Payloads sent
// on an outgoing port before it has ever had a subscriber are buffered and
// handed, in order, to the first subscriber; two threads subscribing at once
// may split them. Once a port has had a subscriber, a payload sent while it
// has none is dropped. No collection runs while a subscriber is called on the
// eco thread (HEAP_083): the stack walk cannot be trusted across host frames.
//
// A bytes port is a port whose whole payload is `Bytes` (PORT_008). It has no
// JSON codec: its payloads cross as raw bytes, a pointer and a length, with no
// conversion. An outgoing bytes port hands each subscriber a pointer straight
// into the Bytes value, valid during the call; a borrowed subscriber gets the
// same bytes behind an `eco_borrowed_bytes`, which it may retain as an owned,
// refcounted copy. An incoming bytes port takes the host's bytes as a lent
// buffer, copied once on the eco thread into a new Bytes value, or as an emit
// (PORT_010), whose fill function writes them: straight into a new heap Bytes
// value when the emit is made inside an outgoing callback, else into a buffer
// that is copied in later. Bytes subscribers and buffered payloads are kept
// apart from JSON ones.
//
// The C functions at the end, `eco_port_*`, are the host-facing form of the
// host API here.
#ifndef ECO_PLATFORM_PORT_RUNTIME_HPP
#define ECO_PLATFORM_PORT_RUNTIME_HPP

#include "allocator/Heap.hpp"
#include "platform/Liveness.hpp"
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace Elm::Platform {

// A host function that receives the payloads sent on an outgoing port, the
// same signature as `eco_port_callback` in `eco/eco_embed.h`.
//
// It is called with one payload as UTF-8 JSON, valid only during the call,
// and the `user` pointer it was subscribed with. It runs on the eco thread
// while the port's commands are dispatched, or, for payloads buffered before
// the port's first subscriber, on the thread that subscribed. It must not
// touch Elm values; it may call the functions PORT_006 lists.
using EcoPortCallback = void (*)(const char* json_utf8, void* user);

// A host function that receives the payloads sent on an outgoing bytes port,
// the same signature as `eco_port_bytes_callback` in `eco/eco_embed.h`.
//
// It is called with one payload's `length` bytes at `data`, and the `user`
// pointer it was subscribed with. `data` may be null when `length` is 0. The
// bytes are those of the Elm value itself, valid only during the call and not
// to be written. It runs where an `EcoPortCallback` runs, under the same rules.
using EcoPortBytesCallback = void (*)(const uint8_t* data, size_t length, void* user);

// A host function that takes back a buffer it lent to `sendIncomingBytes`,
// called with the `ctx` given there.
using EcoPortRelease = void (*)(void* ctx);

// A host function called once with a subscriber's `user` pointer when no
// delivery can reach the subscriber any more, the same signature as
// `eco_destroy_fn` in `eco/eco_embed.h`.
using EcoDestroyFn = void (*)(void* user);

// A host function that writes at most `capacity` bytes to `out` and returns how
// many it wrote, or `kFillCancel` to send nothing, the same signature as
// `eco_bytes_fill` in `eco/eco_embed.h`.
using EcoBytesFill = size_t (*)(uint8_t* out, size_t capacity, void* user);

// What a fill function returns to send nothing (`ECO_FILL_CANCEL`).
constexpr size_t kFillCancel = static_cast<size_t>(-1);

// A port's kind as the host API reports it, the `ECO_PORT_*` values of
// `eco/eco_embed.h`.
enum PortKindCode : int {
    kPortUnregistered = 0,
    kPortInJson = 1,
    kPortInBytes = 2,
    kPortOutJson = 3,
    kPortOutBytes = 4,
};

// The results of `PortRuntime::emit`, the `ECO_EMIT_*` values of
// `eco/eco_embed.h`.
enum EmitCode : int {
    kEmitQueued = 0,
    kEmitNotAPort = 1,
    kEmitCancelled = 2,
    kEmitOverrun = 3,
    kEmitNested = 4,
    kEmitNoMemory = 5,
};

struct PortSink;

}  // namespace Elm::Platform

// The bytes of one outgoing bytes payload as a borrowed subscriber sees them:
// valid only during its call, and only on the thread that runs it. Nothing
// collects while a subscriber runs on the eco thread (HEAP_083), so `data`
// does not move during the call.
struct eco_borrowed_bytes {
    const uint8_t* data;
    size_t length;
};

// A refcounted, immutable copy of a payload's bytes (eco_borrowed_retain),
// defined in PortRuntime.cpp.
struct eco_owned_bytes;

// A port's registry entry, which is also its handle (PORT_011). It is made by
// the first `PortRuntime::get` or subscription that names the port, or by its
// registration, whichever comes first, and is never destroyed or moved.
// Every field but `name` and `kind` is guarded by `PortRuntime::portsMutex_`.
struct eco_port {
    std::string name;      // Set when the entry is made; never changes.
    // The port's PortKindCode: stored, release, whenever `registered`,
    // `incoming` or `bytes` changes; loaded, acquire, by the handle operations,
    // which therefore check a port's kind without the mutex.
    std::atomic<int> kind{Elm::Platform::kPortUnregistered};
    bool registered = false;
    bool incoming = false;
    bool bytes = false;    // A bytes port; meaningful once registered.
    uint64_t decoder = 0;  // Encoded HPointer of an incoming JSON port's decoder; 0 if none.
    std::string schema;    // An incoming JSON port's payload descriptor (PORT_009); empty for none.
    uint64_t subs = 0;     // Encoded HPointer of the tagger list; 0 until the first `setIncomingSubs`.
    std::vector<std::shared_ptr<Elm::Platform::PortSink>> sinks;  // JSON subscribers of an outgoing port.
    std::vector<std::string> buffered;  // JSON payloads sent before the first JSON subscriber.
    bool everSubscribed = false;  // Set by the first JSON subscription; JSON buffering stops from then on.
    // Bytes subscribers, interim and borrowed, in subscription order.
    std::vector<std::shared_ptr<Elm::Platform::PortSink>> byteSinks;
    std::vector<std::vector<uint8_t>> bufferedBytes;  // Copies of bytes payloads sent before the first.
    bool everSubscribedBytes = false;  // `everSubscribed` for bytes subscribers.
};

namespace Elm::Platform {

using PortInfo = ::eco_port;

// A host function that receives the payloads sent on an outgoing bytes port
// as borrowed bytes, the same signature as `eco_port_borrowed_callback` in
// `eco/eco_embed.h`. It runs where an `EcoPortBytesCallback` runs, under the
// same rules.
using EcoPortBorrowedCallback = void (*)(const eco_borrowed_bytes* bytes, void* user);

/**
 * One subscriber of an outgoing port: a JSON callback, an interim bytes
 * callback or a borrowed bytes callback, with its `user` pointer and the
 * function that is called with `user` when the subscriber can no longer be
 * reached. Subscribers are held by `shared_ptr`, and a delivery holds its own
 * references while it calls them, so the last reference, and with it
 * `destroy`, goes only after any delivery in progress has returned.
 */
struct PortSink {
    enum Kind { Json, Interim, Borrowed };
    Kind kind = Json;
    EcoPortCallback json = nullptr;
    EcoPortBytesCallback interim = nullptr;
    EcoPortBorrowedCallback borrowed = nullptr;
    void* user = nullptr;
    EcoDestroyFn destroy = nullptr;  // Set once the subscription has been made.
    ~PortSink() {
        if (destroy) destroy(user);
    }
};

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
    // `PlatformRuntime`. `schema` is the payload type's descriptor
    // (`Mono.payloadSchema`, PORT_009), which `sendIncoming` checks a host's
    // JSON against; empty for none. Allocates, so it may collect.
    //
    // Prints a message to `stderr` and aborts the process if an effect
    // manager, including another port, is already registered as `name`. The
    // first registration of either kind also installs the root scanner, the
    // scheduler async source and the stop hook this component relies on.
    void registerIncoming(const std::string& name, HPointer decoder, const std::string& schema);

    // Registers `name` as an incoming bytes port, which has no decoder, with
    // the same effects as `registerIncoming`.
    void registerIncomingBytes(const std::string& name);

    // Registers `name` as an outgoing port, a bytes port if `bytes`, and
    // registers its effect manager with `PlatformRuntime`, with the same
    // failure and first-call effects as `registerIncoming`.
    void registerOutgoing(const std::string& name, bool bytes);

    // Makes `subsList`, a list of taggers, the subscriptions of the incoming
    // port `port`, replacing any earlier list. Each tagger turns a decoded
    // payload into a message for the program. Does nothing if `port` is not
    // an incoming port.
    void setIncomingSubs(PortInfo* port, HPointer subsList);

    // Sends the JSON payload `json` on the outgoing port `port`: calls each
    // of its subscribers with it, buffers it if the port has never had a
    // subscriber, and drops it otherwise.
    //
    // The subscribers are called on the eco thread without this registry's
    // locks held and with no collection allowed (HEAP_083). A subscriber
    // removed by another thread during the call may still be called once
    // after it has been unsubscribed; its `destroy` waits for that call.
    void deliverOutgoing(PortInfo* port, const std::string& json);

    // Sends the `length` bytes at `data` on the outgoing bytes port `port`, as
    // `deliverOutgoing` sends JSON: to each bytes subscriber in subscription
    // order, or into the buffer, as a copy, if the port has never had a bytes
    // subscriber. The subscribers get `data` itself; the caller keeps it valid
    // until this returns, which it can, since nothing collects meanwhile.
    void deliverOutgoingBytes(PortInfo* port, const uint8_t* data, size_t length);

    // Processes the payloads queued by `sendIncoming`, `sendIncomingBytes` and
    // `emit` when it starts, oldest first, on the eco thread: makes each
    // payload's value (decoding JSON, copying lent bytes, or taking the Bytes
    // value an emit built), applies each of the port's taggers to it, and
    // delivers each message to the program with
    // `PlatformRuntime::deliverToApp`. Releases each payload's hold once it has
    // been processed. Payloads queued meanwhile wait for the next call, which
    // the event loop is woken for. Runs Elm code, so it may collect.
    //
    // A JSON payload the decoder rejects is fatal: this prints the port name
    // and the JSON to `stderr` and aborts the process. A payload for a port
    // with no subscriptions is made and then discarded. A lent bytes payload's
    // buffer is handed back through its release function, as
    // `sendIncomingBytes` describes.
    void drainPendingSends();
    // Returns whether any payload is queued. May be called from any thread; it
    // never waits on the collector's root scan.
    bool hasPendingSends();

    // ---- host API (any thread) ----

    // Returns the handle of the port named `name`, making its registry entry
    // if no registration or subscription has named it yet, or null if `name`
    // is null. The handle stays valid for the rest of the process (PORT_011).
    PortInfo* get(const char* name);
    // Returns the PortKindCode of `port`, or -1 if it is null. Does not lock.
    static int kindOf(const PortInfo* port);

    // What `sendIncoming` did with a payload.
    enum class SendResult {
        Queued,      // queued for the eco thread
        NotAPort,    // a null argument, or the port is not a registered incoming JSON port
        Rejected,    // the JSON does not decode as the port's payload type; see `lastError`
    };

    // Queues a copy of the JSON text `json` for the incoming port `port` and
    // wakes the event loop, which decodes it later on the eco thread as
    // `drainPendingSends` describes. Before queuing, checks the JSON against
    // the port's payload descriptor on the calling thread (PORT_009); JSON
    // that would not decode is refused, with the reason in `lastError`. Queues
    // nothing unless it returns `Queued`; in particular it returns `NotAPort`
    // before the program has registered its ports.
    //
    // Each queued payload holds a `HoldKind::Port` hold from before it is
    // queued until it has been processed, so the event loop does not finish
    // while it waits.
    SendResult sendIncoming(PortInfo* port, const char* json);
    // `sendIncoming` for the port named `name`.
    SendResult sendIncoming(const char* name, const char* json);

    // The message of the last refusal on the calling thread: a send that
    // `sendIncoming` rejected, or flags `eco_app_start` rejected. Each thread
    // has its own; it is overwritten by the next refusal there.
    static std::string& lastError();

    // Queues the `length` bytes at `data` for the incoming bytes port `port`
    // and wakes the event loop, as `sendIncoming` does for JSON. Returns false,
    // and queues nothing, if `port` is null, `data` is null with a nonzero
    // `length`, or `port` is not a registered incoming bytes port.
    //
    // With a `release` function the buffer is lent, not copied: the caller
    // keeps `data` valid and unchanged until the eco thread calls
    // `release(ctx)`, once, after copying the bytes into the Elm heap or
    // dropping them, at the latest when the program stops. With a null
    // `release` the bytes are copied before this returns. When this returns
    // false, `release` is not called.
    bool sendIncomingBytes(PortInfo* port, const uint8_t* data, size_t length,
                           EcoPortRelease release, void* ctx);
    // `sendIncomingBytes` for the port named `name`.
    bool sendIncomingBytes(const char* name, const uint8_t* data, size_t length,
                           EcoPortRelease release, void* ctx);

    // Has `fill` write at most `capacity` bytes and queues them for the
    // incoming bytes port `port`, as `eco_port_emit` describes (PORT_010).
    // Returns an `EmitCode`.
    //
    // Inside an outgoing callback on the eco thread the bytes are written
    // straight into a new Bytes value, allocated without collecting, and the
    // value is queued; when it cannot be allocated without collecting, and
    // everywhere else, they are written into a malloc'd buffer that the eco
    // thread copies in, as a lent `sendIncomingBytes` payload.
    int emit(PortInfo* port, size_t capacity, EcoBytesFill fill, void* user);

    // Subscribes `cb`, called with `user`, to the payloads sent on the
    // outgoing JSON port `port`. Returns false if `port` or `cb` is null or
    // `port` is a registered bytes port, and true otherwise. True does not
    // mean `port` is, or will become, an outgoing port.
    //
    // `port` need not be registered yet: a host may subscribe before the
    // program registers its ports. If the port has never had a subscriber,
    // this first calls `cb` with the buffered payloads, in order, on the
    // calling thread, before the subscription takes effect; two threads
    // subscribing at once may split the buffer between them. Subscribing the
    // same `cb` and `user` twice makes two subscriptions.
    //
    // `destroy`, if not null, is called with `user` exactly once, after the
    // subscription has been removed and no delivery can call `cb` again, with
    // no lock of this registry held; it is not called when this returns false.
    bool subscribeOutgoing(PortInfo* port, EcoPortCallback cb, void* user, EcoDestroyFn destroy);
    // `subscribeOutgoing` for the port named `name`, with no `destroy`.
    bool subscribeOutgoing(const char* name, EcoPortCallback cb, void* user);
    // Removes one subscription of `cb` with `user` from the outgoing port
    // `port`, and returns whether there was one. `cb` may still be called
    // once more if a delivery is in progress on another thread; its `destroy`
    // runs after that call.
    bool unsubscribeOutgoing(PortInfo* port, EcoPortCallback cb, void* user);
    // `unsubscribeOutgoing` for the port named `name`.
    bool unsubscribeOutgoing(const char* name, EcoPortCallback cb, void* user);

    // `subscribeOutgoing` and `unsubscribeOutgoing` for the interim bytes
    // subscribers of an outgoing bytes port. Subscribing returns false if
    // `name` is a registered port that is not a bytes port; a subscription
    // made before `name` registers as a JSON port is kept but never called.
    bool subscribeOutgoingBytes(const char* name, EcoPortBytesCallback cb, void* user);
    bool unsubscribeOutgoingBytes(const char* name, EcoPortBytesCallback cb, void* user);

    // `subscribeOutgoing` and `unsubscribeOutgoing` for the borrowed
    // subscribers of an outgoing bytes port, which share the port's bytes
    // subscriber list with the interim ones.
    bool subscribeOutgoingBorrowed(PortInfo* port, EcoPortBorrowedCallback cb, void* user,
                                   EcoDestroyFn destroy);
    bool unsubscribeOutgoingBorrowed(PortInfo* port, EcoPortBorrowedCallback cb, void* user);

    // Introspection. A port counts once its registration has run; a name
    // known only from a subscription or `get` does not.

    // Returns the number of registered ports.
    int portCount();
    // Returns the name of the `i`th port registered, counting from 0, or a
    // null pointer if `i` is out of range. The string stays valid for the
    // rest of the process.
    const char* portName(int i);
    // Returns 1 if `name` is a registered incoming port, 0 if it is a
    // registered outgoing port, and -1 if it is neither or is null.
    int isIncoming(const char* name);
    // Returns 1 if `name` is a registered bytes port, 0 if it is a registered
    // JSON port, and -1 if it is neither or is null.
    int isBytes(const char* name);

    // ---- tests only ----

    // How the emits so far were made: written into the heap inside a callback,
    // written off the heap outside one, or off the heap inside one because the
    // heap could not supply the bytes without collecting.
    struct EmitStats {
        std::atomic<uint64_t> direct{0};
        std::atomic<uint64_t> offHeap{0};
        std::atomic<uint64_t> fallback{0};
        std::atomic<uint64_t> shrunk{0};  // Direct emits whose short fill kept the large value, shrunk in place.
    };
    const EmitStats& emitStats() const { return emitStats_; }
    // Makes emits inside a callback act as if the heap could not supply their
    // bytes, so that they fall back.
    void setEmitForceOffHeapForTest(bool on) { testForceOffHeap_.store(on); }
    // Makes the next `drainPendingSends` run a minor and a major collection
    // before it processes anything, and abort unless the first queued value an
    // emit built has moved, which shows the root scanner reports it.
    void setCollectAtNextDrainForTest(bool on) { testCollectAtDrain_.store(on); }

private:
    // Creates an empty registry; used only by `instance`.
    PortRuntime();

    // Installs, once, the scheduler async source made of `drainPendingSends`
    // and `hasPendingSends` and the stop hook `dropPendingAtStop`, and, once
    // per heap generation, the root scanner that reports every port's decoder
    // and tagger list, and every queued value an emit built, to the collector.
    // A heap reset (tests only) loses the scanner with the old root set; the
    // first call after it drops every port's decoder and tagger list, which
    // belong to the dead heap, and marks every port unregistered, so that the
    // next program can register it again. Not synchronised: it must be called
    // on the eco thread.
    void ensureRuntimeHooks();
    // Appends `name` to `registrationOrder_` unless it is already there (a
    // port registered again after a heap reset). Requires `portsMutex_`.
    void noteRegistered(const std::string& name);
    // Returns the registry entry of `name`, making it if needed. Requires
    // `portsMutex_`.
    PortInfo& entryLocked(const std::string& name);
    // Drops every queued payload, handing back lent buffers and releasing
    // holds; the scheduler's stop hook.
    static void dropPendingAtStop();

    // Guards ports_, registrationOrder_ and every PortInfo field but `name`
    // and `kind`. The collector's root scanner takes this mutex, so the eco
    // thread must not hold it across an allocation.
    std::mutex portsMutex_;
    // The registry. Entries are never erased, and an unordered_map does not
    // move its elements, so a PortInfo* is a stable handle.
    std::unordered_map<std::string, PortInfo> ports_;
    // Port names in registration order. A deque, so that growing it moves no
    // element and portName can return c_str() pointers that stay valid.
    std::deque<std::string> registrationOrder_;

    // Guards pendingSends_. Never held across an allocation or together with
    // portsMutex_.
    std::mutex pendingMutex_;
    /**
     * One payload queued by sendIncoming, sendIncomingBytes or emit, with the
     * HoldKind::Port hold it owns until drainPendingSends has processed it.
     * A Json payload is `json`. A Bytes payload is either lent (`data`,
     * `length`, and the `release` that hands it back) or, when sent with no
     * release function, copied into `copy`. A Heap payload is the Bytes value
     * an emit built, the encoded HPointer `value`, made in heap generation
     * `generation`; the root scanner reports it while it is queued.
     */
    struct PendingSend {
        enum class Kind : uint8_t { Json, Bytes, Heap };
        Kind kind = Kind::Json;
        PortInfo* port = nullptr;
        std::string json;
        HoldToken hold = kNoHold;
        const uint8_t* data = nullptr;
        size_t length = 0;
        EcoPortRelease release = nullptr;
        void* ctx = nullptr;
        std::vector<uint8_t> copy;
        uint64_t value = 0;
        uint64_t generation = 0;
    };
    std::deque<PendingSend> pendingSends_;
    // Takes a `HoldKind::Port` hold for `item`, queues it and wakes the event
    // loop, and returns true; or, once the program has stopped, queues nothing
    // and returns false, leaving any lent buffer with the caller.
    bool enqueueSend(PendingSend item);
    // Set by `dropPendingAtStop` and cleared by the next registration, under
    // `pendingMutex_`: while set, nothing more is queued, so nothing is left
    // queued with its buffer unreleased after the program has stopped.
    bool stopped_ = false;
    // Clears `stopped_`: a program is registering its ports.
    void reopenQueue();
    // Subscribes `sink` to the bytes subscribers of `port`, as
    // `subscribeOutgoingBytes` does.
    bool subscribeBytesSink(PortInfo* port, std::shared_ptr<PortSink> sink, EcoDestroyFn destroy);
    // Removes the first bytes subscriber of `port` of kind `kind` whose
    // callback is `cb` and whose user pointer is `user`.
    bool unsubscribeBytesSink(PortInfo* port, PortSink::Kind kind, const void* cb, void* user);

    bool hooksInstalled_ = false;  // Set by ensureRuntimeHooks; read and written on the eco thread only.
    // The heap generation whose root set has the scanner; 0 before the first. Eco thread only.
    uint64_t scannerGeneration_ = 0;

    EmitStats emitStats_;
    std::atomic<bool> testForceOffHeap_{false};
    std::atomic<bool> testCollectAtDrain_{false};
};

// The bodies of the borrowed and owned bytes functions of the C ABI, shared by
// the weak definitions in PortRuntime.cpp and the strong ones in eco_embed.cpp.
namespace embed_detail {
const uint8_t* borrowedData(const eco_borrowed_bytes* b);
size_t borrowedSize(const eco_borrowed_bytes* b);
eco_owned_bytes* retain(const eco_borrowed_bytes* b);
const uint8_t* ownedData(const eco_owned_bytes* o);
size_t ownedSize(const eco_owned_bytes* o);
void ownedRef(eco_owned_bytes* o);
void ownedUnref(eco_owned_bytes* o);
}  // namespace embed_detail

}  // namespace Elm::Platform

// The host-facing C functions declared in eco/eco_embed.h, each a thin
// wrapper over the PortRuntime function of the same purpose. The definitions in
// PortRuntime.cpp are weak on non-Windows targets, so the ones in
// embed/eco_embed.cpp take precedence wherever both are linked.
extern "C" {
// Calls `PortRuntime::sendIncoming`; returns 0 if it queued the payload, 2 if
// it rejected it (the reason is in `eco_last_error`), and 1 otherwise.
int eco_port_send(const char* port, const char* json_utf8);
// Returns `PortRuntime::lastError()` for the calling thread, as a C string
// valid until the next refusal on this thread.
const char* eco_last_error(void);
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
// Calls `PortRuntime::sendIncomingBytes`; returns 0 if it queued the payload
// and 1 otherwise.
int eco_port_send_bytes(const char* port, const uint8_t* data, size_t length,
                        Elm::Platform::EcoPortRelease release, void* ctx);
// Calls `PortRuntime::subscribeOutgoingBytes`; returns 0 on success and 1
// otherwise.
int eco_port_subscribe_bytes(const char* port,
                             Elm::Platform::EcoPortBytesCallback cb, void* user);
// Calls `PortRuntime::unsubscribeOutgoingBytes`; returns 0 if a subscription
// was removed and 1 otherwise.
int eco_port_unsubscribe_bytes(const char* port,
                               Elm::Platform::EcoPortBytesCallback cb, void* user);
// Returns `PortRuntime::isBytes(port)`.
int eco_port_is_bytes(const char* port);

// Port handles (PORT_011).
// Returns `PortRuntime::get(name)`.
eco_port* eco_port_get(const char* name);
// Returns `PortRuntime::kindOf(port)`.
int eco_port_kind(const eco_port* port);
// Returns the port's name, or null for a null port.
const char* eco_port_get_name(const eco_port* port);
// `eco_port_send` and `eco_port_send_bytes` on a handle.
int eco_port_send_json(eco_port* port, const char* json_utf8);
int eco_port_send_buffer(eco_port* port, const uint8_t* data, size_t length,
                         Elm::Platform::EcoPortRelease release, void* ctx);
// Calls `PortRuntime::subscribeOutgoing` with `destroy`; returns 0 on success
// and 1 otherwise.
int eco_port_subscribe_json(eco_port* port, Elm::Platform::EcoPortCallback cb, void* user,
                            Elm::Platform::EcoDestroyFn destroy);
// Calls `PortRuntime::unsubscribeOutgoing`; returns 0 if a subscription was
// removed and 1 otherwise.
int eco_port_unsubscribe_json(eco_port* port, Elm::Platform::EcoPortCallback cb, void* user);

// Borrowed, owned and emitted bytes (PORT_010).
// Calls `PortRuntime::subscribeOutgoingBorrowed`; returns 0 on success and 1
// otherwise.
int eco_port_subscribe_borrowed(eco_port* port, Elm::Platform::EcoPortBorrowedCallback cb,
                                void* user, Elm::Platform::EcoDestroyFn destroy);
// Calls `PortRuntime::unsubscribeOutgoingBorrowed`; returns 0 if a
// subscription was removed and 1 otherwise.
int eco_port_unsubscribe_borrowed(eco_port* port, Elm::Platform::EcoPortBorrowedCallback cb,
                                  void* user);
// The bytes of a borrowed payload: null when its length is 0.
const uint8_t* eco_borrowed_data(const eco_borrowed_bytes* bytes);
size_t eco_borrowed_size(const eco_borrowed_bytes* bytes);
// Returns a refcounted copy of a borrowed payload, or null if it cannot be
// allocated.
eco_owned_bytes* eco_borrowed_retain(const eco_borrowed_bytes* bytes);
// The bytes of an owned copy: null when its length is 0.
const uint8_t* eco_owned_data(const eco_owned_bytes* owned);
size_t eco_owned_size(const eco_owned_bytes* owned);
// Adds and drops a reference; the last drop frees the copy. Any thread.
void eco_owned_ref(eco_owned_bytes* owned);
void eco_owned_unref(eco_owned_bytes* owned);
// Calls `PortRuntime::emit`.
int eco_port_emit(eco_port* port, size_t capacity, Elm::Platform::EcoBytesFill fill, void* user);
}

#endif  // ECO_PLATFORM_PORT_RUNTIME_HPP
