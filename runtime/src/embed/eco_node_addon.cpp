//===- eco_node_addon.cpp - N-API glue for .node output --------------------===//
//
// Makes an Eco-compiled Elm program loadable by Node.js with the same API
// surface as the JS target (plans/native-ports-and-embedding.md Phase 4):
//
//     const { Elm } = require("./main.node");
//     const app = Elm.Main.init({ flags: null });
//     app.ports.logPort.subscribe(msg => console.log(msg));
//     app.ports.onP2PSend.send({ subjectId: 1, messageId: 2 });
//     app.stop();   // extension: cooperative shutdown of the eco thread
//
// Marshalling: JSON strings cross the boundary in both directions.
//   outgoing: eco-thread callback -> napi_threadsafe_function -> JS thread
//             -> JSON.parse -> subscriber
//   incoming: JSON.stringify on the JS thread -> eco_port_send (queued,
//             decoded and delivered on the eco thread)
//
// Liveness matches the JS target: an idle worker does not pin the Node loop
// (output port TSFNs are unref'd), but pending Elm work does — a dedicated
// keepalive TSFN is ref'd exactly while the eco scheduler is busy and
// unref'd when it goes idle, driven by eco_set_idle_hook. So a batch host
// like `node run.js` runs to completion and exits on its own, while a host
// that only reacts to its own timers/stdin still controls process lifetime,
// exactly as with compiled-to-JS Elm. See the liveness block below.
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
// Event-loop liveness (JS parity).
//
// Output port TSFNs are unref'd so an idle subscription never pins the Node
// loop (see portSubscribe). On its own that means async port output can
// arrive after Node has already drained and exited — the work happens on the
// eco thread, and nothing ref'd is holding the loop. The JS target does not
// have this problem: there, port input is processed synchronously on the
// main thread, so pending Elm work keeps the loop alive via the normal
// microtask/timer machinery.
//
// To match that, a single dedicated "keepalive" TSFN is ref'd exactly while
// the eco scheduler has real work in flight and unref'd when it goes idle
// (waiting for external input). The eco thread reports busy/idle transitions
// via eco_set_idle_hook → ecoActivity (below); the actual ref/unref runs on
// the main thread in keepaliveTrampoline, which reads the latest busy state
// so it is robust to message ordering. portSend also refs pre-emptively (on
// the main thread) so the idle→busy edge cannot race Node into exiting before
// the eco thread observes the new input.
napi_threadsafe_function g_keepalive = nullptr;
std::atomic<bool> g_ecoBusy{true};

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

#define NAPI_CALL(env, call) NAPI_CALL_RET(env, call, nullptr)

// Root module name baked into the program object by the compiler (see
// EcoNativeDriver.cpp, opts.rootModule); weak so programs built before the
// symbol existed fall back to "Main".
extern "C" __attribute__((weak)) const char* __eco_root_module;

const char* rootModuleName() {
    return (&__eco_root_module != nullptr && __eco_root_module != nullptr)
               ? __eco_root_module
               : "Main";
}

// ---------------------------------------------------------------------------
// Outgoing subscriptions: one threadsafe function per subscribe(fn).
// ---------------------------------------------------------------------------

struct SubEntry {
    std::string port;
    napi_threadsafe_function tsfn = nullptr;
    napi_ref fnRef = nullptr;  // identity for unsubscribe
};

// Registry of live subscriptions (JS thread only).
std::vector<SubEntry*>& subEntries() {
    static std::vector<SubEntry*> v;
    return v;
}

// JS-thread trampoline: parse the JSON payload and invoke the subscriber.
void callJsTrampoline(napi_env env, napi_value jsCb, void* /*ctx*/,
                      void* data) {
    auto* payload = static_cast<std::string*>(data);
    if (env != nullptr && jsCb != nullptr) {
        napi_value jsonStr = nullptr;
        if (napi_create_string_utf8(env, payload->c_str(), payload->size(),
                                    &jsonStr) == napi_ok) {
            // JSON.parse(jsonStr)
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

// Eco-thread sink: post the JSON payload to the subscription's TSFN.
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

// Main-thread trampoline for the keepalive TSFN: ref iff the eco thread is
// currently busy, else unref. Reads g_ecoBusy at run time (not enqueue time)
// so interleaved busy/idle signals self-correct to the latest state. env is
// null while the TSFN is being torn down at shutdown — skip then.
void keepaliveTrampoline(napi_env env, napi_value /*jsCb*/, void* /*ctx*/,
                         void* /*data*/) {
    if (env == nullptr || g_keepalive == nullptr) return;
    if (g_ecoBusy.load())
        napi_ref_threadsafe_function(env, g_keepalive);
    else
        napi_unref_threadsafe_function(env, g_keepalive);
}

// eco_set_idle_hook callback: runs on the ECO thread when the worker
// transitions busy/idle. Records the state and wakes the main thread to
// apply the ref/unref. Non-blocking enqueue (the TSFN is created with an
// unbounded queue), so this is safe to call while the scheduler holds its
// mutex.
void ecoActivity(int busy, void* /*user*/) {
    g_ecoBusy.store(busy != 0);
    if (g_keepalive != nullptr)
        napi_call_threadsafe_function(g_keepalive, nullptr,
                                      napi_tsfn_nonblocking);
}

// ---------------------------------------------------------------------------
// ports.<name>.subscribe / unsubscribe / send
// ---------------------------------------------------------------------------

// Property data: the port name, owned for the addon lifetime.
std::string* internPortName(const char* name) {
    static std::vector<std::string*> names;
    names.push_back(new std::string(name));
    return names.back();
}

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
    // JS parity: port subscriptions do not keep the Node loop alive.
    NAPI_CALL(env, napi_unref_threadsafe_function(env, entry->tsfn));

    subEntries().push_back(entry);
    eco_port_subscribe(portName->c_str(), nodeSink, entry);

    return nullptr;
}

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
        // entry AND its tsfn leak intentionally: the eco thread may be
        // mid-delivery with this entry pointer (the unsubscribe contract
        // allows one trailing callback), and releasing a TSFN that a
        // producer thread is concurrently calling is UB. The tsfn stays
        // unref'd (does not hold the loop) and the leak is bounded by the
        // number of unsubscribes.
        return nullptr;
    }
    return nullptr;
}

napi_value portSend(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    void* data = nullptr;
    NAPI_CALL(env, napi_get_cb_info(env, info, &argc, argv, nullptr, &data));
    auto* portName = static_cast<std::string*>(data);

    // JSON.stringify(value) — exact JS semantics for the payload.
    napi_value global, jsonObj, stringifyFn, jsonStr;
    NAPI_CALL(env, napi_get_global(env, &global));
    NAPI_CALL(env, napi_get_named_property(env, global, "JSON", &jsonObj));
    NAPI_CALL(env, napi_get_named_property(env, jsonObj, "stringify",
                                           &stringifyFn));
    napi_value stringifyArgs[1] = {argv[0]};
    NAPI_CALL(env, napi_call_function(env, jsonObj, stringifyFn, 1,
                                      stringifyArgs, &jsonStr));

    // JSON.stringify(undefined) returns undefined, not a string — reject
    // with a clear message instead of a generic N-API failure.
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
    // Pre-emptively hold the loop open: this send is about to make the eco
    // thread busy, and the ref must land on the main thread before this call
    // returns so Node cannot drain and exit before the eco thread observes
    // the input. The eco thread's idle transition unrefs again when done.
    if (g_keepalive != nullptr)
        napi_ref_threadsafe_function(env, g_keepalive);
    return nullptr;
}

napi_value appStop(napi_env env, napi_callback_info /*info*/) {
    (void)env;
    eco_app_stop();
    eco_app_join();
    return nullptr;
}

// ---------------------------------------------------------------------------
// Elm.<RootModule>.init(opts)
// ---------------------------------------------------------------------------

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

bool g_inited = false;

napi_value elmInit(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    NAPI_CALL(env, napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr));

    if (g_inited) {
        napi_throw_error(env, nullptr,
                         "eco: Elm.init may only be called once per process");
        return nullptr;
    }

    // opts.flags: serialize with JSON.stringify (exact JS payload
    // semantics) and hand the string to the embed API; the program's
    // compiler-generated flags decoder runs it on the eco thread.
    // Absent/undefined flags decode as `null`, matching the JS kernel
    // running the flags decoder on `undefined`.
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

    // Keepalive TSFN: created (referenced by default) and wired to the eco
    // scheduler's idle/busy transitions BEFORE start, so the loop is held
    // open from the first instant and released only when the program is
    // genuinely idle. See the liveness comment at the top of this file.
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

// Stop the eco thread before Node tears down the process (process.exit or
// natural loop exit). Without this, C++ static destructors run while the
// eco thread is still mutating runtime state — a use-after-free race that
// glibc reports as malloc corruption at exit.
void ecoEnvCleanup(void* /*arg*/) {
    if (g_inited) {
        eco_app_stop();
        eco_app_join();
    }
    // The eco thread has now exited (join returned), so no further
    // ecoActivity calls can race this release.
    if (g_keepalive != nullptr) {
        napi_release_threadsafe_function(g_keepalive, napi_tsfn_release);
        g_keepalive = nullptr;
    }
}

}  // namespace

// Module registration: exports = { Elm: { <RootModule>: { init } } }.
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
