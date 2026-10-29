//===- eco_node_addon.cpp - N-API glue for .node output --------------------===//
//
// A program compiled by Eco can be built as a Node.js native addon, a `.node` file, and this file is what lets
// JavaScript load and drive it with the same calls it would use on the program compiled to JavaScript:
//
//     const { Elm } = require("./main.node");
//     const app = Elm.Main.init({ flags: null });
//     app.ports.logPort.subscribe(msg => console.log(msg));
//     app.ports.onP2PSend.send({ subjectId: 1, messageId: 2 });
//     app.stop();   // stops the program and waits for it
//
// It is written against Node's C API, N-API, and against the embedding interface in `eco_embed.h`. The program
// runs on its own eco thread, as `eco_app_start` describes; JavaScript runs on Node's main thread. Values cross
// between the two only as JSON text: `JSON.stringify` on the main thread for flags and incoming port values, and
// `JSON.parse` on the main thread for each payload an outgoing port sends.
//
// The eco thread may not call JavaScript, so it hands work to the main thread through N-API thread-safe
// functions (TSFNs): a TSFN wraps a function to be run on the main thread and lets any thread queue a call to
// it. A TSFN is either referenced, in which case it keeps Node's event loop from exiting, or unreferenced, in
// which case it does not. Most of this file is about which TSFNs are referenced, and when:
//
// - Each outgoing-port subscription has its own TSFN, unreferenced, so a subscription alone does not keep the
//   process running.
// - One keepalive TSFN, `g_keepalive`, is referenced from its creation and while the program reports itself
//   busy through the idle hook (`eco_set_idle_hook`), and from each port send until the next idle report; an
//   idle report unreferences it.
//
//===----------------------------------------------------------------------===//

#define NAPI_VERSION 8
#include <node_api.h>

#include "eco_embed.h"

#include <atomic>
#include <mutex>
#include <new>
#include <string>
#include <vector>

namespace {

// ---------------------------------------------------------------------------
// Event-loop liveness
//
// The eco thread reports busy and idle through `ecoActivity`, which records the state in `g_ecoBusy` and queues a
// call to `keepaliveTrampoline`; that call, on the main thread, references or unreferences `g_keepalive` to match
// the state it reads then. `portSend` also references it directly, so that the loop is held from the moment a
// value is sent rather than from the moment the eco thread picks it up.

/// The keepalive TSFN, set by `elmInit` and released by `ecoEnvCleanup`; null until `elmInit` creates it.
napi_threadsafe_function g_keepalive = nullptr;
/// Whether the program last reported itself busy; true until the first report. Written on the eco thread, read
/// on the main thread.
std::atomic<bool> g_ecoBusy{true};

/// Evaluates the N-API call `call` and, if it does not return `napi_ok`, tries to throw a JavaScript `Error`
/// carrying N-API's last error message for `env` and returns `ret` from the enclosing function. If a JavaScript
/// exception is already pending, as when a called JavaScript function threw, that exception is what propagates.
///
/// It is a macro because it returns from its caller. It expands to a statement and evaluates `env` more than
/// once.

#define NAPI_CALL_RET(env, call, ret)                                       \
    do {                                                                     \
        napi_status status_ = (call);                                        \
        if (status_ != napi_ok) {                                            \
            const napi_extended_error_info* info_ = nullptr;                 \
            napi_get_last_error_info((env), &info_);                         \
            napi_throw_error((env), nullptr,                                 \
                             info_ && info_->error_message                   \
                                 ? info_->error_message                      \
                                 : "eco: N-API call failed");                \
            return (ret);                                                    \
        }                                                                    \
    } while (0)

/// `NAPI_CALL_RET` returning a null `napi_value`, which N-API treats as `undefined`.
#define NAPI_CALL(env, call) NAPI_CALL_RET(env, call, nullptr)

/// The name of the program's root Elm module, as a C string, defined by the compiler in the program object.
/// The declaration is weak, so the address is null when the program does not define it.
extern "C" __attribute__((weak)) const char* __eco_root_module;

/// Returns `__eco_root_module`, or `"Main"` if it is undefined or null.
const char* rootModuleName() {
    return (&__eco_root_module != nullptr && __eco_root_module != nullptr)
               ? __eco_root_module
               : "Main";
}

// ---------------------------------------------------------------------------
// Outgoing subscriptions: one TSFN per call to subscribe
// ---------------------------------------------------------------------------

/// One JavaScript function subscribed to one outgoing port. Its address is the `user` pointer given to
/// `eco_port_subscribe`, so it is never freed: see `portUnsubscribe`.
struct SubEntry {
    std::string port;
    napi_threadsafe_function tsfn = nullptr;  ///< Calls the subscriber on the main thread; never released.
    napi_ref fnRef = nullptr;                 ///< The subscriber, held to find this entry on unsubscribe.
};

/// Returns the subscriptions not yet unsubscribed, in the order they were made. Used on the main thread only.
std::vector<SubEntry*>& subEntries() {
    static std::vector<SubEntry*> v;
    return v;
}

/// Parses the JSON text `data` points to and calls the subscriber `jsCb` with the result, on the main thread.
///
/// `data` is a `std::string` allocated by `nodeSink`; this deletes it. If `env` or `jsCb` is null, as when the
/// TSFN is being torn down, or if any step fails, the subscriber is not called.
void callJsTrampoline(napi_env env, napi_value jsCb, void* /*ctx*/,
                      void* data) {
    auto* payload = static_cast<std::string*>(data);
    if (env != nullptr && jsCb != nullptr) {
        napi_value jsonStr = nullptr;
        if (napi_create_string_utf8(env, payload->c_str(), payload->size(),
                                    &jsonStr) == napi_ok) {
            napi_value global = nullptr, jsonObj = nullptr, parseFn = nullptr;
            napi_value parsed = nullptr;
            if (napi_get_global(env, &global) == napi_ok &&
                napi_get_named_property(env, global, "JSON", &jsonObj) ==
                    napi_ok &&
                napi_get_named_property(env, jsonObj, "parse", &parseFn) ==
                    napi_ok &&
                napi_call_function(env, jsonObj, parseFn, 1, &jsonStr,
                                   &parsed) == napi_ok) {
                napi_value undef = nullptr;
                napi_get_undefined(env, &undef);
                napi_value argv[1] = {parsed};
                napi_call_function(env, undef, jsCb, 1, argv, nullptr);
            }
        }
    }
    delete payload;
}

/// Queues a copy of the payload `json` on the TSFN of the `SubEntry` that `user` points to, for
/// `callJsTrampoline` to deliver. This is the `eco_port_callback` every subscription is made with.
///
/// It runs wherever `eco_port_callback` describes. The TSFN's queue is unbounded, so the call does not wait. The
/// payload is dropped if `user` or its TSFN is null, if the copy cannot be allocated, or if the TSFN refuses it.
void nodeSink(const char* json, void* user) {
    auto* entry = static_cast<SubEntry*>(user);
    if (entry == nullptr || entry->tsfn == nullptr) return;
    auto* payload = new (std::nothrow) std::string(json);
    if (payload == nullptr) return;
    if (napi_call_threadsafe_function(entry->tsfn, payload,
                                      napi_tsfn_blocking) != napi_ok) {
        delete payload;
    }
}

/// References `g_keepalive` if `g_ecoBusy` is set and unreferences it if not; the call queued by `ecoActivity`.
///
/// It reads the state when it runs, not when it was queued, so after a burst of reports the TSFN matches the
/// latest. It does nothing when `env` is null, as when the TSFN is being torn down.
void keepaliveTrampoline(napi_env env, napi_value /*jsCb*/, void* /*ctx*/,
                         void* /*data*/) {
    if (env == nullptr || g_keepalive == nullptr) return;
    if (g_ecoBusy.load())
        napi_ref_threadsafe_function(env, g_keepalive);
    else
        napi_unref_threadsafe_function(env, g_keepalive);
}

/// Records `busy` in `g_ecoBusy` and queues a call to `keepaliveTrampoline`; the idle hook `elmInit` installs.
///
/// It runs on the eco thread, possibly with the scheduler's lock held, as `eco_set_idle_hook` describes. It does
/// not call into the scheduler, and the queue is unbounded, so it does not wait.
void ecoActivity(int busy, void* /*user*/) {
    g_ecoBusy.store(busy != 0);
    if (g_keepalive != nullptr)
        napi_call_threadsafe_function(g_keepalive, nullptr,
                                      napi_tsfn_nonblocking);
}

// ---------------------------------------------------------------------------
// ports.<name>.subscribe / unsubscribe / send
// ---------------------------------------------------------------------------

/// Returns a heap copy of `name` that is never freed, to be the data pointer of a port's JavaScript functions.
std::string* internPortName(const char* name) {
    static std::vector<std::string*> names;
    names.push_back(new std::string(name));
    return names.back();
}

/// Implements `ports.<name>.subscribe(fn)`: subscribes the JavaScript function `fn` to the outgoing port whose
/// name is the function's data, so that it is called on the main thread with each payload, parsed from JSON.
///
/// Throws a `TypeError` if `fn` is not a function. The subscription does not keep Node's event loop alive.
/// Subscribing the same function twice subscribes it twice.
napi_value portSubscribe(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    void* data = nullptr;
    NAPI_CALL(env, napi_get_cb_info(env, info, &argc, argv, nullptr, &data));
    auto* portName = static_cast<std::string*>(data);

    napi_valuetype type;
    NAPI_CALL(env, napi_typeof(env, argv[0], &type));
    if (argc < 1 || type != napi_function) {
        napi_throw_type_error(env, nullptr,
                              "port.subscribe expects a function");
        return nullptr;
    }

    auto* entry = new SubEntry();
    entry->port = *portName;
    NAPI_CALL(env, napi_create_reference(env, argv[0], 1, &entry->fnRef));

    napi_value resourceName;
    NAPI_CALL(env, napi_create_string_utf8(env, "eco_port", NAPI_AUTO_LENGTH,
                                           &resourceName));
    NAPI_CALL(env,
              napi_create_threadsafe_function(
                  env, argv[0], nullptr, resourceName, /*max_queue=*/0,
                  /*initial_thread_count=*/1, nullptr, nullptr, nullptr,
                  callJsTrampoline, &entry->tsfn));
    NAPI_CALL(env, napi_unref_threadsafe_function(env, entry->tsfn));

    subEntries().push_back(entry);
    eco_port_subscribe(portName->c_str(), nodeSink, entry);

    return nullptr;
}

/// Implements `ports.<name>.unsubscribe(fn)`: removes the earliest subscription of `fn` to the port whose name
/// is the function's data, or does nothing if there is none.
///
/// `fn` may still be called afterwards, once for each payload already queued on its TSFN, which is kept.
napi_value portUnsubscribe(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    void* data = nullptr;
    NAPI_CALL(env, napi_get_cb_info(env, info, &argc, argv, nullptr, &data));
    auto* portName = static_cast<std::string*>(data);

    auto& entries = subEntries();
    for (auto it = entries.begin(); it != entries.end(); ++it) {
        SubEntry* entry = *it;
        if (entry->port != *portName) continue;
        napi_value fn;
        if (napi_get_reference_value(env, entry->fnRef, &fn) != napi_ok)
            continue;
        bool same = false;
        if (napi_strict_equals(env, fn, argv[0], &same) != napi_ok || !same)
            continue;

        eco_port_unsubscribe(portName->c_str(), nodeSink, entry);
        napi_delete_reference(env, entry->fnRef);
        entries.erase(it);
        // The entry and its TSFN are leaked: a delivery in progress may still be using the entry, and
        // N-API forbids releasing a TSFN while another thread may call it. The TSFN is unreferenced, so it
        // does not hold the loop.
        return nullptr;
    }
    return nullptr;
}

/// Implements `ports.<name>.send(value)`: serializes `value` with `JSON.stringify` and sends the text to the
/// incoming port whose name is the function's data, with `eco_port_send`.
///
/// Propagates any exception `JSON.stringify` throws; throws a `TypeError` if it does not return a string, as for
/// `undefined` or a function, and an `Error` if `eco_port_send` refuses the send. On success it references
/// `g_keepalive` before returning, so that Node's event loop is held until the program next reports itself idle,
/// if it does; after the program has stopped none follows.
napi_value portSend(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    void* data = nullptr;
    NAPI_CALL(env, napi_get_cb_info(env, info, &argc, argv, nullptr, &data));
    auto* portName = static_cast<std::string*>(data);

    napi_value global, jsonObj, stringifyFn, jsonStr;
    NAPI_CALL(env, napi_get_global(env, &global));
    NAPI_CALL(env, napi_get_named_property(env, global, "JSON", &jsonObj));
    NAPI_CALL(env, napi_get_named_property(env, jsonObj, "stringify",
                                           &stringifyFn));
    napi_value stringifyArgs[1] = {argv[0]};
    NAPI_CALL(env, napi_call_function(env, jsonObj, stringifyFn, 1,
                                      stringifyArgs, &jsonStr));

    napi_valuetype strType;
    NAPI_CALL(env, napi_typeof(env, jsonStr, &strType));
    if (strType != napi_string) {
        napi_throw_type_error(env, nullptr,
                              "eco: port.send value must be JSON-serializable "
                              "(undefined/functions are not)");
        return nullptr;
    }

    size_t len = 0;
    NAPI_CALL(env, napi_get_value_string_utf8(env, jsonStr, nullptr, 0, &len));
    std::string json(len, '\0');
    NAPI_CALL(env, napi_get_value_string_utf8(env, jsonStr, json.data(),
                                              len + 1, &len));

    if (eco_port_send(portName->c_str(), json.c_str()) != 0) {
        std::string msg = "eco: unknown incoming port '" + *portName + "'";
        napi_throw_error(env, nullptr, msg.c_str());
        return nullptr;
    }
    // Referenced here, not left to the idle hook, so that the loop is held before the eco thread has seen the
    // value and reported itself busy.
    if (g_keepalive != nullptr)
        napi_ref_threadsafe_function(env, g_keepalive);
    return nullptr;
}

/// Implements `app.stop()`: asks the program to stop with `eco_app_stop` and blocks the main thread until the
/// eco thread has finished, with `eco_app_join`.
napi_value appStop(napi_env env, napi_callback_info /*info*/) {
    (void)env;
    eco_app_stop();
    eco_app_join();
    return nullptr;
}

// ---------------------------------------------------------------------------
// Elm.<RootModule>.init(opts)
// ---------------------------------------------------------------------------

/// Returns a new `ports` object with one property per port the program has registered: an object with `send`
/// for an incoming port, or with `subscribe` and `unsubscribe` for any other. Returns null, with a JavaScript
/// exception pending, if an N-API call fails.
napi_value buildPortsObject(napi_env env) {
    napi_value ports;
    NAPI_CALL(env, napi_create_object(env, &ports));

    int count = eco_port_count();
    for (int i = 0; i < count; ++i) {
        const char* name = eco_port_name(i);
        if (name == nullptr) continue;
        std::string* interned = internPortName(name);

        napi_value portObj;
        NAPI_CALL(env, napi_create_object(env, &portObj));

        if (eco_port_is_incoming(name) == 1) {
            napi_value sendFn;
            NAPI_CALL(env, napi_create_function(env, "send", NAPI_AUTO_LENGTH,
                                                portSend, interned, &sendFn));
            NAPI_CALL(env,
                      napi_set_named_property(env, portObj, "send", sendFn));
        } else {
            napi_value subFn, unsubFn;
            NAPI_CALL(env, napi_create_function(env, "subscribe",
                                                NAPI_AUTO_LENGTH,
                                                portSubscribe, interned,
                                                &subFn));
            NAPI_CALL(env, napi_create_function(env, "unsubscribe",
                                                NAPI_AUTO_LENGTH,
                                                portUnsubscribe, interned,
                                                &unsubFn));
            NAPI_CALL(env, napi_set_named_property(env, portObj, "subscribe",
                                                   subFn));
            NAPI_CALL(env, napi_set_named_property(env, portObj,
                                                   "unsubscribe", unsubFn));
        }
        NAPI_CALL(env, napi_set_named_property(env, ports, name, portObj));
    }
    return ports;
}

/// Whether `elmInit` has started the program.
bool g_inited = false;

/// Implements `Elm.<Root>.init(opts)`: starts the program with `opts.flags` as its flags and returns the app
/// object, `{ ports, stop }`.
///
/// `opts.flags` is serialized with `JSON.stringify`; an exception it throws propagates and nothing is started.
/// If `opts` is null, a function or a primitive, or `opts.flags` is `undefined` or `JSON.stringify` returns a
/// non-string, the program is started with no flags, as `eco_app_start` describes for a null `flags_json`. Throws
/// an `Error` if the program has already been started successfully by this function, or fails to start; since
/// `eco_app_start` cannot be retried, a later call after a failed start fails too. Before starting it, creates
/// `g_keepalive`, referenced, and installs `ecoActivity` as the idle hook, so that the loop is held
/// from the start until the program first reports itself idle.
napi_value elmInit(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    NAPI_CALL(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr));

    if (g_inited) {
        napi_throw_error(env, nullptr,
                         "eco: Elm.init may only be called once per process");
        return nullptr;
    }

    std::string flagsJson;
    bool hasFlags = false;
    if (argc >= 1) {
        napi_valuetype optsType;
        NAPI_CALL(env, napi_typeof(env, argv[0], &optsType));
        if (optsType == napi_object) {
            napi_value flags;
            if (napi_get_named_property(env, argv[0], "flags", &flags) ==
                napi_ok) {
                napi_valuetype flagsType;
                NAPI_CALL(env, napi_typeof(env, flags, &flagsType));
                if (flagsType != napi_undefined) {
                    napi_value global, jsonObj, stringifyFn, jsonStr;
                    NAPI_CALL(env, napi_get_global(env, &global));
                    NAPI_CALL(env, napi_get_named_property(env, global,
                                                           "JSON", &jsonObj));
                    NAPI_CALL(env,
                              napi_get_named_property(env, jsonObj,
                                                      "stringify",
                                                      &stringifyFn));
                    napi_value stringifyArgs[1] = {flags};
                    NAPI_CALL(env, napi_call_function(env, jsonObj,
                                                      stringifyFn, 1,
                                                      stringifyArgs,
                                                      &jsonStr));
                    napi_valuetype strType;
                    NAPI_CALL(env, napi_typeof(env, jsonStr, &strType));
                    if (strType == napi_string) {
                        size_t len = 0;
                        NAPI_CALL(env, napi_get_value_string_utf8(
                                           env, jsonStr, nullptr, 0, &len));
                        flagsJson.resize(len);
                        NAPI_CALL(env, napi_get_value_string_utf8(
                                           env, jsonStr, flagsJson.data(),
                                           len + 1, &len));
                        hasFlags = true;
                    }
                }
            }
        }
    }

    {
        napi_value keepaliveName;
        NAPI_CALL(env, napi_create_string_utf8(env, "eco_keepalive",
                                               NAPI_AUTO_LENGTH,
                                               &keepaliveName));
        NAPI_CALL(env, napi_create_threadsafe_function(
                           env, nullptr, nullptr, keepaliveName,
                           /*max_queue=*/0, /*initial_thread_count=*/1,
                           nullptr, nullptr, nullptr, keepaliveTrampoline,
                           &g_keepalive));
        eco_set_idle_hook(ecoActivity, nullptr);
    }

    if (eco_app_start(0, nullptr, hasFlags ? flagsJson.c_str() : nullptr) !=
        0) {
        napi_throw_error(env, nullptr, "eco: app failed to start");
        return nullptr;
    }
    g_inited = true;

    napi_value app;
    NAPI_CALL(env, napi_create_object(env, &app));
    napi_value ports = buildPortsObject(env);
    if (ports == nullptr) return nullptr;
    NAPI_CALL(env, napi_set_named_property(env, app, "ports", ports));

    napi_value stopFn;
    NAPI_CALL(env, napi_create_function(env, "stop", NAPI_AUTO_LENGTH, appStop,
                                        nullptr, &stopFn));
    NAPI_CALL(env, napi_set_named_property(env, app, "stop", stopFn));

    return app;
}

}  // namespace

namespace {

/// Stops the program and waits for the eco thread to finish, if `elmInit` started it, then releases
/// `g_keepalive`; the cleanup hook registered for Node's environment.
///
/// The program is stopped here so that the eco thread is not still running when the process's static
/// destructors run.
void ecoEnvCleanup(void* /*arg*/) {
    if (g_inited) {
        eco_app_stop();
        eco_app_join();
    }
    // When the program was started, the eco thread has finished, so no `ecoActivity` call races this release.
    if (g_keepalive != nullptr) {
        napi_release_threadsafe_function(g_keepalive, napi_tsfn_release);
        g_keepalive = nullptr;
    }
}

}  // namespace

/// Returns the addon's exports, `{ Elm: { <Root>: { init } } }`, where `<Root>` is `rootModuleName()`, and
/// registers `ecoEnvCleanup` to run when Node's environment is torn down. Node calls this when the addon is
/// loaded. Returns null, with a JavaScript exception pending, if an N-API call fails.
extern "C" napi_value napi_register_module_v1(napi_env env,
                                              napi_value /*exports*/) {
    napi_add_env_cleanup_hook(env, ecoEnvCleanup, nullptr);

    napi_value result, elm, moduleObj, initFn;
    NAPI_CALL(env, napi_create_object(env, &result));
    NAPI_CALL(env, napi_create_object(env, &elm));
    NAPI_CALL(env, napi_create_object(env, &moduleObj));
    NAPI_CALL(env, napi_create_function(env, "init", NAPI_AUTO_LENGTH, elmInit,
                                        nullptr, &initFn));
    NAPI_CALL(env, napi_set_named_property(env, moduleObj, "init", initFn));
    NAPI_CALL(env, napi_set_named_property(env, elm, rootModuleName(),
                                           moduleObj));
    NAPI_CALL(env, napi_set_named_property(env, result, "Elm", elm));
    return result;
}
