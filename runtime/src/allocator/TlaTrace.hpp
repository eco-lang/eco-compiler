#pragma once

// Event hooks that let a test harness record what the concurrent GC code does, so that the recording can be checked
// against the TLA+ models of that code (trace validation). In every ordinary build the hooks compile to nothing.
//
//   ECO_TLA_TRACE("ev", "key", value, "key", value, ...);
//
// A trace build is a harness compiled with -DECO_TLA_TRACE=1 and linked with test/tla/trace/TlaTrace.cpp, which
// defines the functions declared here. In a trace build a hook appends one event, named "ev" and carrying the given
// key/value fields, to the calling thread's private buffer, numbered by a per-thread sequence number. In every other
// build the hook expands to ((void)0): its arguments are not evaluated and nothing from this header is linked, so
// the code that holds the hooks behaves exactly as it would without them. Even in a trace build the arguments are
// evaluated only when the event is being recorded. Hook arguments must therefore have no side effect the code relies
// on.
//
// Values: integers, enums, bool, string literals, Elm::tlatrace::obj(p) (an object; logged as the harness's id for
// it, else as its address) and Elm::tlatrace::key(prefix, a[, b]) (a string "<prefix><a>[.<b>]", for the ordering
// fields below).
//
// The recorded buffers are later merged into one interleaving of all threads' events, an order consistent with each
// thread's sequence numbers and with these ordering fields:
//   "put", k / "get", k    every event that gets key k follows every event that puts it (a publication: a launch
//                          and the members it starts, an exit and the join that waits for it, a push and the scan of
//                          that entry);
//   "rmw", loc, "old", v, "new", w
//                          an atomic read-modify-write of location loc that read v and wrote w; the RMWs of one
//                          location are chained by value into its modification order;
//   "rd", loc, "val", v    a load of loc that read v: placed after the write of v and before the next write of loc;
//   "clk", c, "tick", n    a totally ordered stamp (a counter taken under a lock, or a global seq_cst counter):
//                          events of clock c are ordered by n.
//
// Trace builds are kept separate from ThreadSanitizer builds: the recorder registers a thread's buffer under a lock
// at its first event of a trace, which adds a happens-before edge that would hide races TSan should report.
//
// This header uses only the standard library and declares nothing unless ECO_TLA_TRACE is defined. The build flag
// and the hook share the name ECO_TLA_TRACE, so the header replaces the flag with the hook: code that must know
// whether it is in a trace build tests ECO_TLA_TRACE_ENABLED (1 or 0) after including it.
//
// Event fields must not be named t, s, ts, ev, i, n, vc, nxt or pk: the recorder and the merger write fields with
// those names into each event.

#if defined(ECO_TLA_TRACE)
#undef ECO_TLA_TRACE
/// 1 in a trace build: the hooks record events.
#define ECO_TLA_TRACE_ENABLED 1

#include <cstdint>
#include <string>
#include <type_traits>

namespace Elm::tlatrace {

/// The type of one field's value, which says which members of a `Field` hold it.
enum class Kind : uint8_t { Int, Bool, Str, Obj, Key };

/// An object to log by identity: `p` is logged as the harness's id for it, as its address in hex if the harness has
/// none, or as 0 if `p` is null. Only the pointer value is used; `p` is not dereferenced by the recorder.
struct ObjRef { const void* p; };
/// An ordering key, logged as the string "<prefix><a>", or "<prefix><a>.<b>" when `b` is not negative.
struct KeyRef { const char* prefix; int64_t a; int64_t b; };

/// One key/value field of an event. `kind` says which of the value members hold the value; the others are unused.
/// The recorder copies `key` and any string into the event, so the pointers need only stay valid for the call that
/// records it.
struct Field {
    const char* key;
    Kind kind;
    int64_t i;          // Int, Bool, Key (first number)
    int64_t j;          // Key (second number, -1 = none)
    const char* s;      // Str, Key (prefix)
    const void* p;      // Obj
};

// ---- implemented in test/tla/trace/TlaTrace.cpp ----------------------------
/// Returns whether a trace is being recorded and its keep list (see `begin`) admits events named `ev`. The hook
/// calls it before it evaluates its other arguments.
bool wants(const char* ev);
/// Appends an event named `ev` with the first `n` of `fields` to the calling thread's buffer, or does nothing if no
/// trace is being recorded. Nothing passed in is kept after the call.
void emitv(const char* ev, const Field* fields, unsigned n);
/// Names the calling thread "<prefix><index>" (index < 0: just "<prefix>") in every trace it logs to. The first name
/// a thread is given sticks; a name already taken by another thread gets a ".<k>" suffix. A thread never named is
/// logged as "T<number>". Has effect only if called before the thread's first event; after that the thread keeps
/// its "T<number>" name.
void nameThread(const char* prefix, int64_t index);
/// Returns a fresh serial number and binds it to the pair (`p`, `tag`), replacing any earlier binding. For keys
/// that two threads must agree on, e.g. an episode number that the launching thread binds to its control block and
/// each member reads back with `bound`. Bindings are not cleared between traces.
int64_t bind(const void* p, int tag);
/// Returns the serial number last bound to (`p`, `tag`) by `bind`, or -1 if none has been.
int64_t bound(const void* p, int tag);
/// While a trace is being recorded, calls the harness's probe callback (see `setProbe`), if one is set, with
/// `where` on the calling thread, e.g. to log what the heap looks like at that point.
void probe(const char* where);

// Harness side.
/// Starts recording a new trace, discarding any events not yet written. `header_json` is a JSON object written,
/// wrapped as {"hdr": ...}, as the trace's first line ("{}" if empty). `keep` is a comma-separated list of the
/// event names to record, a name ending in "." standing for every name with that prefix ("gang."); empty means
/// every event. Must be called while no other thread logs.
void begin(const std::string& header_json, const std::string& keep = "");
/// Stops recording, writes the trace to `path` (when null, to the file named by $ECO_TLA_TRACE_OUT; nothing is
/// written if that is unset or empty) and discards the events. Returns false if the file could not be opened or
/// closed. Must be called while no other thread logs.
bool end(const char* path);
/// Returns whether a trace is being recorded.
bool recording();
/// Sets how obj(p) is logged: `fn` returns the harness's id for p, or a negative value for "not mine", in which case
/// the address is logged as a hex string. `fn` may be null (every object logged by address); it is kept until the
/// next call and is called on the logging thread. Must be called while no other thread logs.
void setObjId(int64_t (*fn)(const void* p));
/// Sets the callback `probe` calls; null removes it. It is kept until the next call. Must be called while no other
/// thread logs.
void setProbe(void (*fn)(const char* where));

// ---- value constructors ----------------------------------------------------
/// Returns a value that logs the object at `p` by identity (see `ObjRef`).
inline ObjRef obj(const void* p) { return ObjRef{p}; }
/// Returns an ordering key "<prefix><a>", or "<prefix><a>.<b>" when `b` is not negative.
inline KeyRef key(const char* prefix, int64_t a, int64_t b = -1) { return KeyRef{prefix, a, b}; }
/// Returns an ordering key as the other overload does, with the address `p`, as a decimal integer, in place of `a`.
inline KeyRef key(const char* prefix, const void* p, int64_t b = -1) {
    return KeyRef{prefix, static_cast<int64_t>(reinterpret_cast<uintptr_t>(p)), b};
}

/// Returns field `k` holding the bool `v`.
inline Field mk(const char* k, bool v) { return Field{k, Kind::Bool, v ? 1 : 0, -1, nullptr, nullptr}; }
/// Returns field `k` holding the string `v`; a null `v` is logged as "".
inline Field mk(const char* k, const char* v) { return Field{k, Kind::Str, 0, -1, v, nullptr}; }
/// Returns field `k` holding the object `v`.
inline Field mk(const char* k, ObjRef v) { return Field{k, Kind::Obj, 0, -1, nullptr, v.p}; }
/// Returns field `k` holding the ordering key `v`.
inline Field mk(const char* k, KeyRef v) { return Field{k, Kind::Key, v.a, v.b, v.prefix, nullptr}; }
/// Returns field `k` holding the integer `v`, converted to int64_t.
template <class T, std::enable_if_t<std::is_integral_v<T> && !std::is_same_v<T, bool>, int> = 0>
inline Field mk(const char* k, T v) { return Field{k, Kind::Int, static_cast<int64_t>(v), -1, nullptr, nullptr}; }
/// Returns field `k` holding the enum `v` as its underlying integer value.
template <class T, std::enable_if_t<std::is_enum_v<T>, int> = 0>
inline Field mk(const char* k, T v) { return mk(k, static_cast<int64_t>(v)); }

/// Ends the recursion of the overload below: no pairs left.
inline void fill(Field*, unsigned&) {}
/// Writes one field per key/value pair into `fs` from index `n` on, advancing `n` past them. `fs` must have room.
template <class V, class... R>
inline void fill(Field* fs, unsigned& n, const char* k, const V& v, const R&... rest) {
    fs[n++] = mk(k, v);
    fill(fs, n, rest...);
}

/// Records an event named `ev` whose fields are the key/value pairs `kv`; an odd number of arguments does not
/// compile.
template <class... A>
inline void emit(const char* ev, const A&... kv) {
    static_assert(sizeof...(A) % 2 == 0, "ECO_TLA_TRACE takes key/value pairs after the event name");
    Field fs[sizeof...(A) / 2 + 1];
    unsigned n = 0;
    fill(fs, n, kv...);
    emitv(ev, fs, n);
}

}  // namespace Elm::tlatrace

/// Records event `ev` with the key/value pairs that follow, if the trace being recorded wants it. Expands to a
/// statement. `ev` is evaluated twice, and the pairs only when the event is recorded.
#define ECO_TLA_TRACE(ev, ...)                                                   \
    do {                                                                         \
        if (::Elm::tlatrace::wants(ev)) ::Elm::tlatrace::emit(ev __VA_OPT__(, ) __VA_ARGS__); \
    } while (0)
/// Expands to its arguments in a trace build and to nothing otherwise: a statement that exists only in trace builds
/// (e.g. a local a hook needs).
#define ECO_TLA_TRACE_ONLY(...) __VA_ARGS__

#else

/// 0 outside a trace build: the hooks compile to nothing.
#define ECO_TLA_TRACE_ENABLED 0
#define ECO_TLA_TRACE(...) ((void)0)
#define ECO_TLA_TRACE_ONLY(...)

#endif
