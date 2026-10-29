// A program compiled by Eco can be linked into another application as a library, and this header is the C
// interface through which that application, the host, runs it.
//
// An Elm program runs on one thread, the eco thread, which is the only thread that runs Elm code or touches
// Elm values. `eco_app_start` creates that thread and starts the program on it. The host's threads never touch
// an Elm value; they reach the program only through these functions, which hand in and take out JSON text.
//
// The functions fall into two groups. The application functions start the one program a process may run, ask
// it to stop, wait for it to finish and report its exit code, and let the host learn when the program is busy.
// The port functions are the host's end of the program's Elm ports: an incoming port takes JSON text from the
// host as a message to the program, and an outgoing port hands the host the JSON text of each value the program
// sends on it. What they do is stated by `Elm::Platform::PortRuntime`, whose host API they wrap.
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

#ifdef __cplusplus
extern "C" {
#endif

/// A host function that receives the payloads sent on an outgoing port, the same type as
/// `Elm::Platform::EcoPortCallback`.
///
/// It is called with one payload as UTF-8 JSON, valid only during the call, and the `user` pointer it was
/// subscribed with. It runs on the eco thread, or, for payloads buffered before the port's first subscriber,
/// on the thread that subscribed. It must not touch Elm values; it may call `eco_port_send`.
typedef void (*eco_port_callback)(const char* json_utf8, void* user);

// ---- Application lifecycle ----

/// Starts the program on a new eco thread with a 64 MiB stack, and returns once it has started.
///
/// For a `Platform.worker` program, "started" means the effects of its `init` have been dispatched, as
/// `Elm::Platform::PlatformRuntime::setReadyHook` describes. For any other program, and for a worker that
/// returns before that point, it means the program's `main` has returned. Until `eco_app_stop` is called,
/// the program's event loop is kept from returning when it runs out of work, so that it can wait for the host
/// to send it something.
///
/// `argc` and `argv` are the arguments the program reads as its command line. `argv` is kept, and must stay
/// valid until the program has finished. `flags_json` is the program's flags as UTF-8 JSON, or `NULL` for
/// none; it is copied. A worker decodes it as `Elm::Platform::PlatformRuntime::initWorker` describes, which
/// aborts the process if it does not decode.
///
/// Returns 0 once the program has started, `ECO_APP_ERR_ALREADY_STARTED` if this has been called before in
/// this process, and `ECO_APP_ERR_THREAD` if the thread could not be created. A first call that fails with
/// `ECO_APP_ERR_THREAD` still counts as the first, so no later call can start a program.
int eco_app_start(int argc, char** argv, const char* flags_json);

/// The result of `eco_app_start` when it has already been called in this process.
#define ECO_APP_ERR_ALREADY_STARTED 1
/// Reserved: no function returns this code, and its value is kept so that no other result reuses it.
#define ECO_APP_ERR_FLAGS_UNSUPPORTED 2
/// The result of `eco_app_start` when the eco thread could not be created.
#define ECO_APP_ERR_THREAD 3

/// Asks the program to stop, and returns without waiting for it.
///
/// Once `eco_app_start` has returned 0, this asks the event loop to return, as
/// `Elm::Platform::Scheduler::requestStop` describes, and stops keeping it from returning when it runs out of
/// work. A call before `eco_app_start`, and every call after the first, does nothing. Must not be called while
/// `eco_app_start` is in progress on another thread. May be called from any other thread, but not from the
/// idle hook, which may run with the scheduler's lock held.
void eco_app_stop(void);

/// Called after `eco_app_start` has returned, waits for the eco thread to finish, and returns the program's
/// exit code: the code last recorded by `eco_set_exit_code`, or 0 if none was.
///
/// Returns -1 if `eco_app_start` has not been called. Once the thread has been waited for, a later call
/// returns the same code at once. If `eco_app_start` failed with `ECO_APP_ERR_THREAD`, it returns 0. Must not be
/// called on the eco thread, which would be waiting for itself.
int eco_app_join(void);

/// Sets the idle hook, a function called with `user` and whether the program is busy (1) or idle (0), so that a
/// host can keep itself running while the program has work in progress and not while it only waits for input.
///
/// When it is called, and what busy means, is as `Elm::Platform::Scheduler::ActivityHook` describes; the hold
/// that `eco_app_start` takes to keep the event loop up does not count as busy. It is called on the eco thread,
/// possibly with the scheduler's lock held, so it must not call `eco_app_stop` or `eco_port_send`, both of
/// which call into the scheduler. `user` is kept.
///
/// Must be called before `eco_app_start` and not changed after. A later call has no effect if the program was
/// started without a hook, and races the eco thread if it was started with one. A null `cb` sets no hook.
void eco_set_idle_hook(void (*cb)(int busy, void* user), void* user);

// ---- Ports ----

/// Queues a copy of the JSON text `json_utf8` for the incoming port named `port`, to be decoded and delivered
/// to the program on the eco thread, as `Elm::Platform::PortRuntime::sendIncoming` describes. May be called from
/// any thread.
///
/// Returns 0 if the payload was queued, and 1 if either argument is null or `port` is not a registered incoming
/// port, which includes any port before the program has registered its ports. A payload that does not decode
/// aborts the process later, on the eco thread.
int eco_port_send(const char* port, const char* json_utf8);

/// Subscribes `cb`, called with `user`, to the payloads sent on the outgoing port named `port`, as
/// `Elm::Platform::PortRuntime::subscribeOutgoing` describes. May be called before `eco_app_start`.
///
/// Returns 1 if `port` or `cb` is null, and 0 otherwise, whether or not `port` is or becomes an outgoing port.
/// `user` is kept, and must stay valid until the subscription is removed and any delivery in progress has
/// returned. A first subscriber is first called, on the calling thread, with the payloads sent before it.
int eco_port_subscribe(const char* port, eco_port_callback cb, void* user);
/// Removes one subscription of `cb` with `user` from the outgoing port named `port`, and returns 0 if there was
/// one and 1 otherwise. `cb` may still be called once more if a delivery is in progress on another thread.
int eco_port_unsubscribe(const char* port, eco_port_callback cb, void* user);

// ---- Introspection ----
//
// These see a port once the program has registered it. A name known only from `eco_port_subscribe` is not a
// port here.

/// Returns the number of ports the program has registered.
int eco_port_count(void);
/// Returns the name of the `i`th port registered, counting from 0, or `NULL` if `i` is out of range. The string
/// stays valid for the rest of the process.
const char* eco_port_name(int i);
/// Returns 1 if `port` names a registered incoming port, 0 if it names a registered outgoing port, and -1 if
/// neither or if it is null.
int eco_port_is_incoming(const char* port);

#ifdef __cplusplus
}
#endif

#endif /* ECO_EMBED_H */
