// The recording side of ECO_TLA_TRACE (runtime/src/allocator/TlaTrace.hpp):
// linked into TRACE builds of the harnesses only (never into the runtime,
// never into a TSan build). See test/tla/README.md, "Trace validation".
//
// Each thread appends events to its own buffer, numbered by a per-thread
// sequence number. The buffer is registered under a lock at the thread's
// first event of a trace. begin() and end() must be called while no other
// thread logs (the harness calls them between collections, with every gang
// parked); end() writes the raw log:
//
//   line 1   {"hdr": <the harness's header object>}
//   then     one event per line, grouped by thread, in sequence order:
//            {"t": "<thread>", "s": <seq>, "ts": <ns>, "ev": "<name>", <fields>}
//
// test/tla/trace/merge_trace.py turns that into the merged log a trace spec
// reads. "ts" (steady clock) is only a tie-breaking hint for the merger; the
// order it builds comes from the sequence numbers and the ordering fields.
#include "TlaTrace.hpp"

#include <atomic>
#include <chrono>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace Elm::tlatrace {
namespace {

struct Buf {
    std::string name;
    uint64_t seq = 0;
    std::string text;          // one event per line, each WITHOUT its leading {"t":...,
};

std::mutex g_mu;                           // registry, names, binds
std::vector<Buf*> g_bufs;                  // this trace's buffers (owned)
std::atomic<bool> g_on{false};
std::atomic<uint64_t> g_gen{0};
std::string g_header;
std::vector<std::string> g_keep;           // empty: keep every event
int64_t (*g_objid)(const void*) = nullptr;
void (*g_probe)(const char*) = nullptr;
std::map<std::pair<const void*, int>, int64_t> g_binds;
int64_t g_serial = 0;
uint64_t g_unnamed = 0;

thread_local Buf* tl_buf = nullptr;        // valid only while tl_gen == g_gen
thread_local uint64_t tl_gen = 0;
thread_local std::string tl_name;          // sticks across traces

bool nameTakenLocked(const std::string& n, const Buf* self) {
    for (const Buf* b : g_bufs)
        if (b != self && b->name == n) return true;
    return false;
}

std::string uniqueLocked(const std::string& want, const Buf* self) {
    if (!nameTakenLocked(want, self)) return want;
    for (int k = 2;; ++k) {
        std::string n = want + "." + std::to_string(k);
        if (!nameTakenLocked(n, self)) return n;
    }
}

Buf* myBuf() {
    const uint64_t gen = g_gen.load(std::memory_order_acquire);
    if (tl_buf != nullptr && tl_gen == gen) return tl_buf;
    std::lock_guard<std::mutex> lk(g_mu);
    Buf* b = new Buf();
    if (tl_name.empty()) tl_name = "T" + std::to_string(g_unnamed++);
    b->name = uniqueLocked(tl_name, b);
    g_bufs.push_back(b);
    tl_buf = b;
    tl_gen = gen;
    return b;
}

void appendEscaped(std::string& out, const char* s) {
    out += '"';
    for (const char* c = s; *c; ++c) {
        if (*c == '"' || *c == '\\') { out += '\\'; out += *c; }
        else if (static_cast<unsigned char>(*c) < 0x20) { out += ' '; }
        else out += *c;
    }
    out += '"';
}

void appendHex(std::string& out, const void* p) {
    char tmp[32];
    std::snprintf(tmp, sizeof tmp, "\"0x%" PRIxPTR "\"", reinterpret_cast<uintptr_t>(p));
    out += tmp;
}

}  // namespace

bool recording() { return g_on.load(std::memory_order_relaxed); }

bool wants(const char* ev) {
    if (!g_on.load(std::memory_order_acquire)) return false;
    if (g_keep.empty()) return true;
    for (const std::string& k : g_keep) {
        if (!k.empty() && k.back() == '.') {
            if (std::strncmp(ev, k.data(), k.size()) == 0) return true;
        } else if (k == ev) {
            return true;
        }
    }
    return false;
}

void emitv(const char* ev, const Field* fs, unsigned n) {
    if (!g_on.load(std::memory_order_relaxed)) return;
    Buf* b = myBuf();
    const uint64_t ts = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
    std::string& o = b->text;
    o += "\"s\":" + std::to_string(++b->seq);
    o += ",\"ts\":" + std::to_string(ts);
    o += ",\"ev\":";
    appendEscaped(o, ev);
    for (unsigned k = 0; k < n; ++k) {
        const Field& f = fs[k];
        o += ',';
        appendEscaped(o, f.key);
        o += ':';
        switch (f.kind) {
        case Kind::Int: o += std::to_string(f.i); break;
        case Kind::Bool: o += f.i ? "true" : "false"; break;
        case Kind::Str: appendEscaped(o, f.s != nullptr ? f.s : ""); break;
        case Kind::Obj: {
            const int64_t id = (g_objid != nullptr && f.p != nullptr) ? g_objid(f.p) : -1;
            if (f.p == nullptr) o += "0";
            else if (id >= 0) o += std::to_string(id);
            else appendHex(o, f.p);
            break;
        }
        case Kind::Key: {
            std::string s = f.s != nullptr ? f.s : "";
            s += std::to_string(f.i);
            if (f.j >= 0) s += "." + std::to_string(f.j);
            appendEscaped(o, s.c_str());
            break;
        }
        }
    }
    o += "}\n";
}

void nameThread(const char* prefix, int64_t index) {
    if (!tl_name.empty()) return;
    std::string n = prefix;
    if (index >= 0) n += std::to_string(index);
    tl_name = n;
    if (tl_buf != nullptr && tl_gen == g_gen.load(std::memory_order_acquire)) {
        std::lock_guard<std::mutex> lk(g_mu);
        tl_buf->name = uniqueLocked(n, tl_buf);
    }
}

int64_t bind(const void* p, int tag) {
    std::lock_guard<std::mutex> lk(g_mu);
    const int64_t s = ++g_serial;
    g_binds[{p, tag}] = s;
    return s;
}

int64_t bound(const void* p, int tag) {
    std::lock_guard<std::mutex> lk(g_mu);
    auto it = g_binds.find({p, tag});
    return it == g_binds.end() ? -1 : it->second;
}

void setObjId(int64_t (*fn)(const void*)) { g_objid = fn; }

void setProbe(void (*fn)(const char*)) { g_probe = fn; }

void probe(const char* where) {
    if (g_probe != nullptr && g_on.load(std::memory_order_acquire)) g_probe(where);
}

void begin(const std::string& header_json, const std::string& keep) {
    std::lock_guard<std::mutex> lk(g_mu);
    for (Buf* b : g_bufs) delete b;
    g_bufs.clear();
    g_header = header_json.empty() ? std::string("{}") : header_json;
    g_keep.clear();
    size_t at = 0;
    while (at <= keep.size()) {
        const size_t comma = keep.find(',', at);
        const std::string w = keep.substr(at, comma == std::string::npos ? std::string::npos : comma - at);
        if (!w.empty()) g_keep.push_back(w);
        if (comma == std::string::npos) break;
        at = comma + 1;
    }
    g_gen.fetch_add(1, std::memory_order_acq_rel);
    g_on.store(true, std::memory_order_release);
}

bool end(const char* path) {
    g_on.store(false, std::memory_order_release);
    if (path == nullptr) path = std::getenv("ECO_TLA_TRACE_OUT");
    std::lock_guard<std::mutex> lk(g_mu);
    bool ok = true;
    if (path != nullptr && *path) {
        FILE* f = std::fopen(path, "w");
        if (f == nullptr) {
            std::fprintf(stderr, "tlatrace: cannot write %s\n", path);
            ok = false;
        } else {
            std::fprintf(f, "{\"hdr\":%s}\n", g_header.c_str());
            for (const Buf* b : g_bufs) {
                std::string prefix = "{\"t\":";
                appendEscaped(prefix, b->name.c_str());
                prefix += ',';
                size_t at = 0;
                while (at < b->text.size()) {
                    const size_t nl = b->text.find('\n', at);
                    std::fwrite(prefix.data(), 1, prefix.size(), f);
                    std::fwrite(b->text.data() + at, 1, nl - at + 1, f);
                    at = nl + 1;
                }
            }
            ok = std::fclose(f) == 0;
        }
    }
    for (Buf* b : g_bufs) delete b;
    g_bufs.clear();
    g_gen.fetch_add(1, std::memory_order_acq_rel);   // stale thread-locals re-register
    return ok;
}

}  // namespace Elm::tlatrace
