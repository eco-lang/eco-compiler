/*===- eco_embed.h - C embedding API for Eco-compiled Elm programs --------===*
 *
 * Host-facing C ABI for embedding a natively-compiled Elm program (built
 * with `eco make src/Main.elm --output=libapp.so` or `app.o`) into a C/C++
 * application. See plans/native-ports-and-embedding.md.
 *
 * Threading model (PORT_006): all Elm execution runs on a dedicated "eco"
 * thread spawned by eco_app_start. Host threads interact only through this
 * API. Outgoing-port callbacks are invoked ON THE ECO THREAD (or on the
 * subscribing thread when flushing messages buffered before the first
 * subscribe): be quick, do not block, do not touch Elm state; re-entry is
 * allowed only via eco_port_send.
 *
 * Typical host:
 *
 *     eco_port_subscribe("logPort", on_log, NULL);   // before start is fine
 *     if (eco_app_start(argc, argv, NULL) != 0) return 1;
 *     eco_port_send("onP2PSend", "{\"subjectId\":1,\"messageId\":2}");
 *     ...
 *     eco_app_stop();
 *     return eco_app_join();
 *
 *===----------------------------------------------------------------------===*/

#ifndef ECO_EMBED_H
#define ECO_EMBED_H

#ifdef __cplusplus
extern "C" {
#endif

/* Outgoing-port payloads arrive serialized as UTF-8 JSON strings. The
 * pointer is valid only for the duration of the callback. */
typedef void (*eco_port_callback)(const char* json_utf8, void* user);

/* ---- Application lifecycle ------------------------------------------- */

/* Start the embedded Elm program: spawns the eco thread (GC + runtime
 * init + the program's main), holds the event loop open until
 * eco_app_stop, and blocks until the program has finished initializing
 * (for Platform.worker programs: ports registered and init effects fully
 * dispatched; for plain programs: main has returned).
 *
 * argv must outlive the app (it backs Eco.Kernel.Env). flags_json is the
 * program's flags as a UTF-8 JSON document (NULL when the program takes no
 * flags); it is decoded by the program's compiler-generated flags decoder,
 * and a mismatch crashes the app with a clear message at startup.
 *
 * Returns 0 on success. One app per process; a second call returns
 * ECO_APP_ERR_ALREADY_STARTED. */
int eco_app_start(int argc, char** argv, const char* flags_json);

#define ECO_APP_ERR_ALREADY_STARTED 1
#define ECO_APP_ERR_FLAGS_UNSUPPORTED 2 /* reserved (flags now supported) */
#define ECO_APP_ERR_THREAD 3

/* Request a cooperative shutdown: the event loop exits after finishing
 * the work currently queued. Idempotent; callable from any thread
 * (including from an outgoing-port callback). */
void eco_app_stop(void);

/* Wait for the eco thread to finish and return the program's exit code.
 * Returns -1 if the app was never started. */
int eco_app_join(void);

/* ---- Ports ------------------------------------------------------------ */

/* Queue a JSON payload for an incoming port and wake the event loop.
 * Thread-safe; the decode + delivery happen on the eco thread. Returns 0
 * on success, nonzero if the port is unknown or not incoming. Decode
 * failure crashes the app naming the port (JS parity). */
int eco_port_send(const char* port, const char* json_utf8);

/* Attach a callback to an outgoing port. May be called before
 * eco_app_start (the subscription is applied when the port registers).
 * Messages delivered while a port has no subscribers are buffered and
 * flushed, in order, to the first subscriber. Returns 0 on success. */
int eco_port_subscribe(const char* port, eco_port_callback cb, void* user);
int eco_port_unsubscribe(const char* port, eco_port_callback cb, void* user);

/* ---- Introspection (valid after eco_app_start returns) ---------------- */

int eco_port_count(void);
const char* eco_port_name(int i);          /* NULL if out of range */
int eco_port_is_incoming(const char* port); /* 1 in, 0 out, -1 unknown */

#ifdef __cplusplus
}
#endif

#endif /* ECO_EMBED_H */
