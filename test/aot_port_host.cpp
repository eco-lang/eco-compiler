// aot_port_host.cpp — the port host of the AOT E2E runner (aot_e2e_main.cpp).
//
//   usage: aot-port-host <program.so> [args...]
//
// A standalone executable has no host at the other end of its ports, so a test that
// talks to the harness through ports is lowered to a shared library instead, and this
// program runs it through the embedding API (runtime/include/eco/eco_embed.h). It gives
// the program the generic port echo of the JIT harness (ElmE2ETestBase.hpp
// installPortEchoBounce): every payload sent out through `echoOut` is sent back in
// through `echoIn`, a JSON payload with eco_port_send and the payload of a bytes port, whose
// whole payload is `Bytes`, with eco_port_send_bytes. The library is loaded with dlopen, so
// one host serves every test.
//
// It also serves PortBytesEmitTest's emit harness (plans/native-bytes-ports-2.md §4 step 5) through the
// port-handle, borrowed-bytes and emit functions: every `emitOut` request is answered on `emitIn` and
// `emitVerdict` as the JIT harness answers it. This host cannot see the runtime's emit counters, so its
// verdict is always 1, and ops 7 and 8, which need the runtime's test hooks, are served as op 0.
//
// The program is started with `args` as its command line and no flags. When its event
// loop reports idle (eco_set_idle_hook: nothing left to do but wait for the host), the
// host stops it, waits for it, and exits with the program's exit code. A program's
// output goes to this process's stdout and stderr, which the runner captures.

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <thread>
#include <vector>

#include <dlfcn.h>

namespace {

using PortCallback = void (*)(const char* json_utf8, void* user);
using PortBytesCallback = void (*)(const uint8_t* data, size_t length, void* user);
struct Port;
struct Borrowed;
struct Owned;
using BorrowedCallback = void (*)(const Borrowed* bytes, void* user);
using Fill = size_t (*)(uint8_t* out, size_t capacity, void* user);
constexpr size_t kFillCancel = static_cast<size_t>(-1);

struct EmbedApi {
    int (*app_start)(int argc, char** argv, const char* flags_json);
    void (*app_stop)();
    int (*app_join)();
    void (*set_idle_hook)(void (*cb)(int busy, void* user), void* user);
    int (*port_send)(const char* port, const char* json_utf8);
    int (*port_subscribe)(const char* port, PortCallback cb, void* user);
    int (*port_send_bytes)(const char* port, const uint8_t* data, size_t length,
                           void (*release)(void* ctx), void* ctx);
    int (*port_subscribe_bytes)(const char* port, PortBytesCallback cb, void* user);
    Port* (*port_get)(const char* name);
    int (*port_subscribe_borrowed)(Port* port, BorrowedCallback cb, void* user, void (*destroy)(void*));
    const uint8_t* (*borrowed_data)(const Borrowed* bytes);
    size_t (*borrowed_size)(const Borrowed* bytes);
    Owned* (*borrowed_retain)(const Borrowed* bytes);
    const uint8_t* (*owned_data)(const Owned* owned);
    size_t (*owned_size)(const Owned* owned);
    void (*owned_unref)(Owned* owned);
    int (*port_emit)(Port* port, size_t capacity, Fill fill, void* user);
};

EmbedApi api;

std::mutex idleMutex;
std::condition_variable idleChanged;
bool idle = false;

// Runs on the eco thread, which may call eco_port_send.
void echoBounce(const char* json, void* /*user*/) {
    api.port_send("echoIn", json);
}

// The bytes are valid only during the call, so they are sent back with no release function,
// which copies them.
void echoBounceBytes(const uint8_t* data, size_t length, void* /*user*/) {
    api.port_send_bytes("echoIn", data, length, nullptr, nullptr);
}

// ---- PortBytesEmitTest's emit harness ----

Port* emitInPort = nullptr;
Port* emitVerdictPort = nullptr;
std::thread worker;  // The thread of the last op 5 or 6, joined by the next request.

struct Source {
    const uint8_t* data;
    size_t length;
};

// Writes the source's bytes reversed.
size_t fillReversed(uint8_t* out, size_t capacity, void* user) {
    const Source& src = *static_cast<const Source*>(user);
    if (src.length > capacity) return kFillCancel;
    for (size_t i = 0; i < src.length; ++i) out[i] = src.data[src.length - 1 - i];
    return src.length;
}

int emitReversed(const uint8_t* data, size_t length, size_t capacity) {
    Source src{data, length};
    return api.port_emit(emitInPort, capacity, fillReversed, &src);
}

size_t fillByte(uint8_t* out, size_t, void* user) {
    out[0] = *static_cast<const uint8_t*>(user);
    return 1;
}

void emitByte(Port* port, uint8_t b) {
    api.port_emit(port, 1, fillByte, &b);
}

size_t fillCancel(uint8_t*, size_t, void*) {
    return kFillCancel;
}

size_t fillNested(uint8_t* out, size_t, void*) {
    uint8_t zero = 0;
    out[0] = static_cast<uint8_t>(api.port_emit(emitInPort, 1, fillByte, &zero));
    return 1;
}

void onEmitRequest(const Borrowed* request, void*) {
    if (worker.joinable()) worker.join();
    const uint8_t* all = api.borrowed_data(request);
    const size_t size = api.borrowed_size(request);
    if (size == 0) return;
    const int op = all[0];
    const uint8_t* body = all + 1;
    const size_t len = size - 1;
    switch (op) {
        case 1: emitReversed(body, len, len + len / 2 + 1); break;
        case 2: emitReversed(body, len, 4 * len + 64); break;
        case 3: emitByte(emitInPort, static_cast<uint8_t>(api.port_emit(emitInPort, len, fillCancel, nullptr))); break;
        case 4: api.port_emit(emitInPort, 1, fillNested, nullptr); break;
        case 5: {
            std::vector<uint8_t> copy(body, body + len);
            std::thread t([&] { emitReversed(copy.data(), copy.size(), copy.size()); });
            t.join();
            break;
        }
        case 6: {
            // The result and the verdict come from the thread, after this callback, from a retained copy.
            Owned* owned = api.borrowed_retain(request);
            worker = std::thread([owned] {
                const uint8_t* b = api.owned_data(owned) + 1;
                const size_t n = api.owned_size(owned) - 1;
                emitReversed(b, n, n);
                api.owned_unref(owned);
                emitByte(emitVerdictPort, 1);
            });
            return;
        }
        default: emitReversed(body, len, len); break;  // 0, and 7 and 8 without the runtime's hooks
    }
    emitByte(emitVerdictPort, 1);
}

// Runs on the eco thread, maybe with the scheduler's lock held: it only records the state.
void onActivity(int busy, void* /*user*/) {
    {
        std::lock_guard<std::mutex> lock(idleMutex);
        idle = (busy == 0);
    }
    idleChanged.notify_all();
}

template <typename F>
bool bind(void* lib, const char* name, F& slot) {
    slot = reinterpret_cast<F>(dlsym(lib, name));
    if (!slot) std::fprintf(stderr, "aot-port-host: %s not found: %s\n", name, dlerror());
    return slot != nullptr;
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: aot-port-host <program.so> [args...]\n");
        return 127;
    }
    void* lib = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
    if (!lib) {
        std::fprintf(stderr, "aot-port-host: dlopen %s: %s\n", argv[1], dlerror());
        return 127;
    }
    if (!bind(lib, "eco_app_start", api.app_start) || !bind(lib, "eco_app_stop", api.app_stop) ||
        !bind(lib, "eco_app_join", api.app_join) || !bind(lib, "eco_set_idle_hook", api.set_idle_hook) ||
        !bind(lib, "eco_port_send", api.port_send) || !bind(lib, "eco_port_subscribe", api.port_subscribe) ||
        !bind(lib, "eco_port_send_bytes", api.port_send_bytes) ||
        !bind(lib, "eco_port_subscribe_bytes", api.port_subscribe_bytes) ||
        !bind(lib, "eco_port_get", api.port_get) ||
        !bind(lib, "eco_port_subscribe_borrowed", api.port_subscribe_borrowed) ||
        !bind(lib, "eco_borrowed_data", api.borrowed_data) || !bind(lib, "eco_borrowed_size", api.borrowed_size) ||
        !bind(lib, "eco_borrowed_retain", api.borrowed_retain) || !bind(lib, "eco_owned_data", api.owned_data) ||
        !bind(lib, "eco_owned_size", api.owned_size) || !bind(lib, "eco_owned_unref", api.owned_unref) ||
        !bind(lib, "eco_port_emit", api.port_emit))
        return 127;

    // Before the start: the program's init command may already send on `echoOut`. Only the
    // subscription of the kind `echoOut` registers as is ever called.
    api.port_subscribe("echoOut", echoBounce, nullptr);
    api.port_subscribe_bytes("echoOut", echoBounceBytes, nullptr);
    emitInPort = api.port_get("emitIn");
    emitVerdictPort = api.port_get("emitVerdict");
    api.port_subscribe_borrowed(api.port_get("emitOut"), onEmitRequest, nullptr, nullptr);
    api.set_idle_hook(onActivity, nullptr);

    if (int rc = api.app_start(argc - 1, argv + 1, nullptr); rc != 0) {
        std::fprintf(stderr, "aot-port-host: eco_app_start failed (%d)\n", rc);
        return 127;
    }
    {
        std::unique_lock<std::mutex> lock(idleMutex);
        idleChanged.wait(lock, [] { return idle; });
    }
    api.app_stop();
    const int code = api.app_join();
    if (worker.joinable()) worker.join();
    std::fflush(stdout);
    std::fflush(stderr);
    return code;
}
