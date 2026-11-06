// aot_port_host.cpp — the port host of the AOT E2E runner (aot_e2e_main.cpp).
//
//   usage: aot-port-host <program.so> [args...]
//
// A standalone executable has no host at the other end of its ports, so a test that
// talks to the harness through ports is lowered to a shared library instead, and this
// program runs it through the embedding API (runtime/src/embed/eco_embed.h). It gives
// the program the generic port echo of the JIT harness (ElmE2ETestBase.hpp
// installPortEchoBounce): every payload sent out through `echoOut` is sent back in
// through `echoIn`, a JSON payload with eco_port_send and the payload of a bytes port, whose
// whole payload is `Bytes`, with eco_port_send_bytes. The library is loaded with dlopen, so
// one host serves every test.
//
// The program is started with `args` as its command line and no flags. When its event
// loop reports idle (eco_set_idle_hook: nothing left to do but wait for the host), the
// host stops it, waits for it, and exits with the program's exit code. A program's
// output goes to this process's stdout and stderr, which the runner captures.

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <mutex>

#include <dlfcn.h>

namespace {

using PortCallback = void (*)(const char* json_utf8, void* user);
using PortBytesCallback = void (*)(const uint8_t* data, size_t length, void* user);

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
        !bind(lib, "eco_port_subscribe_bytes", api.port_subscribe_bytes))
        return 127;

    // Before the start: the program's init command may already send on `echoOut`. Only the
    // subscription of the kind `echoOut` registers as is ever called.
    api.port_subscribe("echoOut", echoBounce, nullptr);
    api.port_subscribe_bytes("echoOut", echoBounceBytes, nullptr);
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
    std::fflush(stdout);
    std::fflush(stderr);
    return code;
}
