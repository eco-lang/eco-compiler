// A program compiled by Eco can be linked into another application as a library, and this header is the C
// interface through which that application, the host, runs it. `eco/eco_embed.hpp` is a C++20 layer over it.
//
// An Elm program runs on one thread, the eco thread, which is the only thread that runs Elm code or touches
// Elm values. `eco_app_start` creates that thread and starts the program on it. The host's threads never touch
// an Elm value; they reach the program only through these functions, which hand in and take out JSON text or,
// for a bytes port, raw bytes.
//
// The functions fall into groups. The application functions start the one program a process may run, ask it to
// stop, wait for it to finish and report its exit code, and let the host learn when the program is busy. The
// port functions are the host's end of the program's Elm ports: an incoming port takes a payload from the host
// as a message to the program, and an outgoing port hands the host each value the program sends on it. What
// they do is stated by `Elm::Platform::PortRuntime`, whose host API they wrap.
//
// A port can be named by its string on every call, or resolved once with `eco_port_get` into an `eco_port`
// handle that stays valid for the life of the process; the handle functions then do no name lookup. Newer
// functions take only handles.
//
// A port whose whole payload is `Bytes` is a bytes port, and carries raw bytes rather than JSON. An outgoing
// bytes port hands a subscriber the bytes of the Elm value itself, valid during the call, which it may retain
// as an owned, refcounted copy. An incoming bytes port takes a buffer the host lends, or an emit: a function
// the host supplies fills the payload, straight into the Elm heap when the emit is made inside an outgoing
// callback.
//
// A callback runs on the eco thread while the program is paused at the port, and no garbage collection runs
// until it returns. So bytes a callback is given stay where they are for the whole call, emits included, and a
// callback should return promptly: the program waits for it.
//
// A host might use them like this:
//
//     eco_port_subscribe("logPort", on_log, NULL);   // before start is fine
//     if (eco_app_start(argc, argv, NULL) != 0) return 1;
//     eco_port_send("onP2PSend", "{\"subjectId\":1,\"messageId\":2}");
//     ...
//     eco_app_stop();
//     return eco_app_join();

#ifndef ECO_EMBED_H
#define ECO_EMBED_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// A host function that receives the payloads sent on an outgoing port, the same type as
// `Elm::Platform::EcoPortCallback`.
//
// It is called with one payload as UTF-8 JSON, valid only during the call, and the `user` pointer it was
// subscribed with. It runs on the eco thread, or, for payloads buffered before the port's first subscriber,
// on the thread that subscribed. It must not touch Elm values. It may call the send, emit, subscription,
// borrowed and owned functions here, but not `eco_app_join`, which would wait for the eco thread itself.
typedef void (*eco_port_callback)(const char* json_utf8, void* user);

// A host function that receives the payloads sent on an outgoing bytes port, the same type as
// `Elm::Platform::EcoPortBytesCallback`.
//
// It is called with one payload's `length` bytes at `data` (null when `length` is 0) and the `user` pointer it
// was subscribed with. `data` points into the Elm value itself: it is valid only during the call and must not be
// written. It runs where an `eco_port_callback` runs, under the same rules.
typedef void (*eco_port_bytes_callback)(const uint8_t* data, size_t length, void* user);

// A host function that takes back a buffer lent to `eco_port_send_bytes`, called once with the `ctx` given
// there, on the eco thread.
typedef void (*eco_port_release)(void* ctx);

// ---- Application lifecycle ----

// Starts the program on a new eco thread with a 64 MiB stack, and returns once it has started.
//
// For a `Platform.worker` program, "started" means the effects of its `init` have been dispatched, as
// `Elm::Platform::PlatformRuntime::setReadyHook` describes. For any other program, and for a worker that
// returns before that point, it means the program's `main` has returned. Until `eco_app_stop` is called,
// the program's event loop is kept from returning when it runs out of work, so that it can wait for the host
// to send it something.
//
// `argc` and `argv` are the arguments the program reads as its command line. `argv` is kept, and must stay
// valid until the program has finished. `flags_json` is the program's flags as UTF-8 JSON, or `NULL` for
// none; it is copied. A worker decodes it as `Elm::Platform::PlatformRuntime::initWorker` describes, which
// aborts the process if it does not decode.
//
// Returns 0 once the program has started, `ECO_APP_ERR_ALREADY_STARTED` if it has been started before in
// this process, `ECO_APP_ERR_BAD_FLAGS` if `flags_json` (or `null`, when it is `NULL`) does not decode as the
// program's flags, and `ECO_APP_ERR_THREAD` if the thread could not be created. Bad flags are found before
// anything starts, on the calling thread, with the reason in `eco_last_error`, and the call does not count:
// the host may call again with other flags. A call that fails with `ECO_APP_ERR_THREAD` counts, so no later
// call can start a program.
int eco_app_start(int argc, char** argv, const char* flags_json);

// The result of `eco_app_start` when it has already been called in this process.
#define ECO_APP_ERR_ALREADY_STARTED 1
// Reserved: no function returns this code, and its value is kept so that no other result reuses it.
#define ECO_APP_ERR_FLAGS_UNSUPPORTED 2
// The result of `eco_app_start` when the eco thread could not be created.
#define ECO_APP_ERR_THREAD 3
// The result of `eco_app_start` when the flags do not decode as the program's flags type.
#define ECO_APP_ERR_BAD_FLAGS 4

// Returns the reason for the last refusal on the calling thread: flags `eco_app_start` rejected, or a payload
// `eco_port_send` rejected. The text, in the words the JS backend's error uses, is valid until the next
// refusal on this thread, and empty if there has been none.
const char* eco_last_error(void);

// Asks the program to stop, and returns without waiting for it.
//
// Once `eco_app_start` has returned 0, this asks the event loop to return, as
// `Elm::Platform::Scheduler::requestStop` describes, and stops keeping it from returning when it runs out of
// work. A call before `eco_app_start`, and every call after the first, does nothing. Must not be called while
// `eco_app_start` is in progress on another thread. May be called from any other thread, but not from the
// idle hook, which may run with the scheduler's lock held.
void eco_app_stop(void);

// Called after `eco_app_start` has returned, waits for the eco thread to finish, and returns the program's
// exit code: the code last recorded by `eco_set_exit_code`, or 0 if none was.
//
// Returns -1 if `eco_app_start` has not been called. Once the thread has been waited for, a later call
// returns the same code at once. If `eco_app_start` failed with `ECO_APP_ERR_THREAD`, it returns 0. Must not be
// called on the eco thread, which would be waiting for itself.
int eco_app_join(void);

// Sets the idle hook, a function called with `user` and whether the program is busy (1) or idle (0), so that a
// host can keep itself running while the program has work in progress and not while it only waits for input.
//
// When it is called, and what busy means, is as `Elm::Platform::Scheduler::ActivityHook` describes; the hold
// that `eco_app_start` takes to keep the event loop up does not count as busy. It is called on the eco thread,
// possibly with the scheduler's lock held, so it must not call `eco_app_stop` or `eco_port_send`, both of
// which call into the scheduler. `user` is kept.
//
// Must be called before `eco_app_start` and not changed after. A later call has no effect if the program was
// started without a hook, and races the eco thread if it was started with one. A null `cb` sets no hook.
void eco_set_idle_hook(void (*cb)(int busy, void* user), void* user);

// Returns 1 if the program holds work that counts as busy, such as a port payload it has not handled yet, a timer
// or a request in flight, and 0 otherwise. Unlike the idle hook's last report, it is current when called: a port
// send counts from the moment `eco_port_send` or `eco_port_send_bytes` returns. Work the eco thread is running
// without a hold is not counted; the idle hook reports it. May be called from any thread once `eco_app_start` has
// returned 0, and returns 0 before then; must not be called while `eco_app_start` is in progress.
int eco_app_is_busy(void);

// ---- Ports ----

// Queues a copy of the JSON text `json_utf8` for the incoming port named `port`, to be decoded and delivered
// to the program on the eco thread, as `Elm::Platform::PortRuntime::sendIncoming` describes. May be called from
// any thread.
//
// Returns 0 if the payload was queued, 1 if either argument is null or `port` is not a registered incoming JSON
// port, which includes any port before the program has registered its ports, and 2 if the JSON does not decode
// as the port's payload type, with the reason in `eco_last_error`. The JSON is checked on the calling thread,
// against the payload type the compiler recorded for the port, so a bad value is refused here rather than
// found later on the eco thread.
int eco_port_send(const char* port, const char* json_utf8);

// Subscribes `cb`, called with `user`, to the payloads sent on the outgoing port named `port`, as
// `Elm::Platform::PortRuntime::subscribeOutgoing` describes. May be called before `eco_app_start`.
//
// Returns 1 if `port` or `cb` is null, and 0 otherwise, whether or not `port` is or becomes an outgoing port.
// `user` is kept, and must stay valid until the subscription is removed and any delivery in progress has
// returned. A first subscriber is first called, on the calling thread, with the payloads sent before it.
int eco_port_subscribe(const char* port, eco_port_callback cb, void* user);
// Removes one subscription of `cb` with `user` from the outgoing port named `port`, and returns 0 if there was
// one and 1 otherwise. `cb` may still be called once more if a delivery is in progress on another thread.
int eco_port_unsubscribe(const char* port, eco_port_callback cb, void* user);

// Queues the `length` bytes at `data` for the incoming bytes port named `port`, to be delivered to the program
// on the eco thread, as `Elm::Platform::PortRuntime::sendIncomingBytes` describes. May be called from any thread.
//
// With a `release` function the buffer is lent, not copied: it must stay valid and unchanged until the eco thread
// calls `release(ctx)`, which it does once, after copying the bytes into the program's heap or dropping them.
// With a null `release` the bytes are copied before this returns. For example, a host that malloc'd `buf` can
// hand it over with `eco_port_send_bytes(port, buf, n, free, buf)`.
//
// Returns 0 if the payload was queued, and 1, without calling `release`, if `port` is null, `data` is null with
// a nonzero `length`, `port` is not a registered incoming bytes port, or the program has stopped. `eco_port_send`
// refuses a bytes port. Once queued, the buffer is released exactly once, at the latest when the program stops.
int eco_port_send_bytes(const char* port, const uint8_t* data, size_t length, eco_port_release release,
                        void* ctx);

// Subscribes `cb`, called with `user`, to the payloads sent on the outgoing bytes port named `port`, as
// `eco_port_subscribe` does for a JSON port. Returns 1 if `port` or `cb` is null or `port` is a registered port
// that is not a bytes port, and 0 otherwise. `eco_port_subscribe` refuses a registered bytes port. A
// subscription of either kind made before the port registers as the other kind is kept but never called.
int eco_port_subscribe_bytes(const char* port, eco_port_bytes_callback cb, void* user);
// Removes one bytes subscription of `cb` with `user` from the port named `port`, as `eco_port_unsubscribe`
// does for a JSON one.
int eco_port_unsubscribe_bytes(const char* port, eco_port_bytes_callback cb, void* user);

// ---- Port handles ----
//
// A handle names a port without a string lookup. `eco_port_get` makes it from a name, at any time and on any
// thread, before the program has registered its ports or after; it stays valid for the life of the process.

// A port's handle.
typedef struct eco_port eco_port;

// A port's kind, from `eco_port_kind`. A port the program has not registered (yet) is
// `ECO_PORT_UNREGISTERED`.
#define ECO_PORT_UNREGISTERED 0
#define ECO_PORT_IN_JSON 1
#define ECO_PORT_IN_BYTES 2
#define ECO_PORT_OUT_JSON 3
#define ECO_PORT_OUT_BYTES 4

// Returns the handle of the port named `name`, or NULL if `name` is NULL.
eco_port* eco_port_get(const char* name);
// Returns the kind of `port`, one of the `ECO_PORT_*` values, or -1 if `port` is NULL.
int eco_port_kind(const eco_port* port);
// Returns the name of `port`, valid for the life of the process, or NULL if `port` is NULL.
const char* eco_port_get_name(const eco_port* port);

// A host function called once with a subscription's `user` pointer when no delivery can reach the subscription
// any more: after it has been removed, and after any call in progress has returned. It runs on the thread that
// removed the subscription or on the eco thread, with no runtime lock held.
typedef void (*eco_destroy_fn)(void* user);

// `eco_port_send` on a handle: queues the JSON text for the incoming JSON port `port`. Returns 0, 1 or 2 as
// `eco_port_send` does.
int eco_port_send_json(eco_port* port, const char* json_utf8);
// `eco_port_send_bytes` on a handle: queues or lends the bytes for the incoming bytes port `port`. Returns 0 or
// 1 as `eco_port_send_bytes` does.
int eco_port_send_buffer(eco_port* port, const uint8_t* data, size_t length, eco_port_release release,
                         void* ctx);
// `eco_port_subscribe` on a handle, with a `destroy` function (which may be NULL) for `user`. Returns 0 on
// success and 1 if `port` or `cb` is NULL or `port` is a bytes port; on failure `destroy` is not called.
int eco_port_subscribe_json(eco_port* port, eco_port_callback cb, void* user, eco_destroy_fn destroy);
// Removes one subscription of `cb` with `user`, and returns 0 if there was one and 1 otherwise.
int eco_port_unsubscribe_json(eco_port* port, eco_port_callback cb, void* user);

// ---- Bytes ports: borrowed, owned and emitted ----

// The bytes of one payload of an outgoing bytes port, as a borrowed subscriber receives them. They are those of
// the Elm value itself: valid only during the call, only on the thread that runs it, and never to be written.
typedef struct eco_borrowed_bytes eco_borrowed_bytes;

// A host function that receives the payloads sent on an outgoing bytes port as borrowed bytes. It runs where an
// `eco_port_callback` runs, under the same rules.
typedef void (*eco_port_borrowed_callback)(const eco_borrowed_bytes* bytes, void* user);

// Subscribes `cb`, called with `user`, to the outgoing bytes port `port`, as `eco_port_subscribe_json` does for
// a JSON port. Borrowed and `eco_port_subscribe_bytes` subscribers of a port are called in the order they
// subscribed. Returns 1 if `port` or `cb` is NULL or `port` is a JSON port, and 0 otherwise.
int eco_port_subscribe_borrowed(eco_port* port, eco_port_borrowed_callback cb, void* user,
                                eco_destroy_fn destroy);
// Removes one borrowed subscription of `cb` with `user`, and returns 0 if there was one and 1 otherwise.
int eco_port_unsubscribe_borrowed(eco_port* port, eco_port_borrowed_callback cb, void* user);

// The bytes of a borrowed payload, valid until the callback returns, or NULL when there are none.
const uint8_t* eco_borrowed_data(const eco_borrowed_bytes* bytes);
// The number of bytes of a borrowed payload.
size_t eco_borrowed_size(const eco_borrowed_bytes* bytes);

// A copy of a payload's bytes that outlives the callback: immutable, refcounted, and safe to use and release on
// any thread.
typedef struct eco_owned_bytes eco_owned_bytes;

// Returns an owned copy of the borrowed payload with one reference, or NULL if it cannot be allocated. A copy of
// an empty payload is a valid owned value of size 0.
eco_owned_bytes* eco_borrowed_retain(const eco_borrowed_bytes* bytes);
// The bytes of an owned copy, or NULL when there are none.
const uint8_t* eco_owned_data(const eco_owned_bytes* owned);
// The number of bytes of an owned copy.
size_t eco_owned_size(const eco_owned_bytes* owned);
// Adds a reference to an owned copy.
void eco_owned_ref(eco_owned_bytes* owned);
// Drops a reference to an owned copy, freeing it when the last one goes.
void eco_owned_unref(eco_owned_bytes* owned);

// What a fill function returns to send nothing.
#define ECO_FILL_CANCEL ((size_t)-1)

// A host function that writes at most `capacity` bytes to `out` and returns how many it wrote, or
// `ECO_FILL_CANCEL` to send nothing. `out` may be NULL when `capacity` is 0.
typedef size_t (*eco_bytes_fill)(uint8_t* out, size_t capacity, void* user);

// The results of `eco_port_emit`.
#define ECO_EMIT_QUEUED 0       // The payload is queued.
#define ECO_EMIT_NOT_A_PORT 1   // A NULL argument, a capacity over 4 GiB, or not an incoming bytes port.
#define ECO_EMIT_CANCELLED 2    // The fill function returned ECO_FILL_CANCEL.
#define ECO_EMIT_OVERRUN 3      // The fill function returned more than the capacity; nothing is sent.
#define ECO_EMIT_NESTED 4       // Called from inside a fill function.
#define ECO_EMIT_NO_MEMORY 5    // A buffer could not be allocated.

// Calls `fill` once, with `user`, to write a payload of at most `capacity` bytes, and queues what it wrote for the
// incoming bytes port `port`, to be delivered to the program on the eco thread. May be called from any thread
// but the idle hook's.
//
// Called inside an outgoing callback, on the eco thread, `fill` writes straight into a new Bytes value in the
// program's heap, so the payload is never copied. Called anywhere else, or when the heap cannot supply the
// memory without a garbage collection, `fill` writes into a buffer that the eco thread copies into the heap.
//
// The port is checked before `fill` is called: `fill` is not called when the result is `ECO_EMIT_NOT_A_PORT`,
// `ECO_EMIT_NESTED` or `ECO_EMIT_NO_MEMORY`, so a refused emit consumes nothing the host would have read into
// it. There are three exceptions, after which what `fill` wrote is dropped: the program stopped between the
// check and the queueing (`ECO_EMIT_NOT_A_PORT`); a short fill inside a callback found neither heap nor
// malloc memory for its copy (`ECO_EMIT_NO_MEMORY`); and a test-only heap reset.
int eco_port_emit(eco_port* port, size_t capacity, eco_bytes_fill fill, void* user);

// ---- Introspection ----
//
// These see a port once the program has registered it. A name known only from `eco_port_subscribe` is not a
// port here.

// Returns the number of ports the program has registered.
int eco_port_count(void);
// Returns the name of the `i`th port registered, counting from 0, or `NULL` if `i` is out of range. The string
// stays valid for the rest of the process.
const char* eco_port_name(int i);
// Returns 1 if `port` names a registered incoming port, 0 if it names a registered outgoing port, and -1 if
// neither or if it is null.
int eco_port_is_incoming(const char* port);
// Returns 1 if `port` names a registered bytes port, 0 if it names a registered JSON port, and -1 if neither or
// if it is null.
int eco_port_is_bytes(const char* port);

#ifdef __cplusplus
}
#endif

#endif /* ECO_EMBED_H */
