#pragma once

// TLA+ trace validation: compiled-out event hooks
// (plans/threaded-gc-tla-verification.md §6.3; test/tla/README.md, "Trace
// validation").
//
//   ECO_TLA_TRACE("ev", "key", value, "key", value, ...);
//
// In a TRACE build (a harness compiled with -DECO_TLA_TRACE=1 and linked with
// test/tla/trace/TlaTrace.cpp) this appends one event to the calling thread's
// private buffer, with a per-thread sequence number. In every other build it
// expands to ((void)0): the arguments are not evaluated, so production code,
// counters and behaviour are unchanged, and nothing here is linked. Hook
// arguments must therefore have no side effect the code relies on.
//
// Values: integers, enums, bool, string literals, Elm::tlatrace::obj(p) (an
// object; logged as the harness's id for it, else as its address) and
// Elm::tlatrace::key(prefix, a[, b]) (a string "<prefix><a>[.<b>]", for the
// ordering fields below).
//
// Ordering fields (read by test/tla/trace/merge_trace.py, which builds one
// interleaving of all threads' events):
//   "put", k / "get", k    every event that gets key k follows every event
//                          that puts it (a publication: a launch and the
//                          members it starts, an exit and the join that waits
//                          for it, a push and the scan of that entry);
//   "rmw", loc, "old", v, "new", w
//                          an atomic read-modify-write of location loc that
//                          read v and wrote w; the RMWs of one location are
//                          chained by value into its modification order;
//   "rd", loc, "val", v    a load of loc that read v: placed after the write
//                          of v and before the next write of loc;
//   "clk", c, "tick", n    a totally ordered stamp (a counter taken under a
//                          lock, or a global seq_cst counter): events of
//                          clock c are ordered by n.
//
// Trace builds are separate from TSan builds (parent plan §6.3, trap 5): the
// library registers a thread's buffer under a lock at its first event of a
// trace, which adds a happens-before edge TSan would otherwise have to find.
//
// This header is std-only and declares nothing unless ECO_TLA_TRACE is
// defined. The build flag and the hook share the name ECO_TLA_TRACE, so the
// header replaces the flag with the hook: code that must know whether it is in
// a trace build tests ECO_TLA_TRACE_ENABLED (1 or 0) after including it.
//
// Event fields must not be named t, s, ts, ev, i, n, vc, nxt or pk (the
// recorder and the merger use those names).

#if defined(ECO_TLA_TRACE)
#undef ECO_TLA_TRACE
#define ECO_TLA_TRACE_ENABLED 1

#include <cstdint>
#include <string>
#include <type_traits>

namespace Elm::tlatrace {

enum class Kind : uint8_t { Int, Bool, Str, Obj, Key };

struct ObjRef { const void* p; };
struct KeyRef { const char* prefix; int64_t a; int64_t b; };

struct Field {
    const char* key;
    Kind kind;
    int64_t i;          // Int, Bool, Key (first number)
    int64_t j;          // Key (second number, -1 = none)
    const char* s;      // Str, Key (prefix)
    const void* p;      // Obj
};

// ---- implemented in test/tla/trace/TlaTrace.cpp ----------------------------
// Whether a trace is being recorded and it keeps events named ev (checked
// before a hook's arguments are evaluated).
bool wants(const char* ev);
// One event on the calling thread.
void emitv(const char* ev, const Field* fields, unsigned n);
// Names the calling thread "<prefix><index>" (index < 0: just "<prefix>") in
// every trace it logs to. The first name a thread is given sticks; a name
// already taken by another thread gets a ".<k>" suffix.
void nameThread(const char* prefix, int64_t index);
// A fresh serial for (p, tag), and the serial last bound to it (-1 if none).
// For keys that two threads must agree on, e.g. an episode number that the
// launching thread binds to its control block and each member reads back.
int64_t bind(const void* p, int tag);
int64_t bound(const void* p, int tag);
// A harness probe: while recording, calls the harness's callback (if any) on
// the calling thread, e.g. to log what the heap looks like at that point.
void probe(const char* where);

// Harness side.
// Start recording (quiescent). keep: a comma-separated list of the event names
// to record, a name ending in "." standing for every name with that prefix
// ("gang."); empty = every event.
void begin(const std::string& header_json, const std::string& keep = "");
bool end(const char* path);                     // stop and write (quiescent);
                                                // path null: $ECO_TLA_TRACE_OUT
bool recording();
// How obj(p) is logged: the harness's id for p, or < 0 for "not mine" (then
// the address is logged, as a hex string).
void setObjId(int64_t (*fn)(const void* p));
void setProbe(void (*fn)(const char* where));

// ---- value constructors ----------------------------------------------------
inline ObjRef obj(const void* p) { return ObjRef{p}; }
inline KeyRef key(const char* prefix, int64_t a, int64_t b = -1) { return KeyRef{prefix, a, b}; }
inline KeyRef key(const char* prefix, const void* p, int64_t b = -1) {
    return KeyRef{prefix, static_cast<int64_t>(reinterpret_cast<uintptr_t>(p)), b};
}

inline Field mk(const char* k, bool v) { return Field{k, Kind::Bool, v ? 1 : 0, -1, nullptr, nullptr}; }
inline Field mk(const char* k, const char* v) { return Field{k, Kind::Str, 0, -1, v, nullptr}; }
inline Field mk(const char* k, ObjRef v) { return Field{k, Kind::Obj, 0, -1, nullptr, v.p}; }
inline Field mk(const char* k, KeyRef v) { return Field{k, Kind::Key, v.a, v.b, v.prefix, nullptr}; }
template <class T, std::enable_if_t<std::is_integral_v<T> && !std::is_same_v<T, bool>, int> = 0>
inline Field mk(const char* k, T v) { return Field{k, Kind::Int, static_cast<int64_t>(v), -1, nullptr, nullptr}; }
template <class T, std::enable_if_t<std::is_enum_v<T>, int> = 0>
inline Field mk(const char* k, T v) { return mk(k, static_cast<int64_t>(v)); }

inline void fill(Field*, unsigned&) {}
template <class V, class... R>
inline void fill(Field* fs, unsigned& n, const char* k, const V& v, const R&... rest) {
    fs[n++] = mk(k, v);
    fill(fs, n, rest...);
}

template <class... A>
inline void emit(const char* ev, const A&... kv) {
    static_assert(sizeof...(A) % 2 == 0, "ECO_TLA_TRACE takes key/value pairs after the event name");
    Field fs[sizeof...(A) / 2 + 1];
    unsigned n = 0;
    fill(fs, n, kv...);
    emitv(ev, fs, n);
}

}  // namespace Elm::tlatrace

#define ECO_TLA_TRACE(ev, ...)                                                   \
    do {                                                                         \
        if (::Elm::tlatrace::wants(ev)) ::Elm::tlatrace::emit(ev __VA_OPT__(, ) __VA_ARGS__); \
    } while (0)
// A statement that exists only in trace builds (e.g. a local a hook needs).
#define ECO_TLA_TRACE_ONLY(...) __VA_ARGS__

#else

#define ECO_TLA_TRACE_ENABLED 0
#define ECO_TLA_TRACE(...) ((void)0)
#define ECO_TLA_TRACE_ONLY(...)

#endif
