//===- eco_entry.cpp - Entry point wrapper for AOT-compiled binaries ------===//
//
// Provides the C main() for executables produced by eco-boot. Initializes the
// Eco runtime (GC, effect managers, globals) then calls the Elm program's
// main function (renamed to eco_main by eco-boot to avoid symbol clash).
//
//===----------------------------------------------------------------------===//

#include "../allocator/Allocator.hpp"
#include "../allocator/StackMap.hpp"
#include "../allocator/GCStats.hpp"
#include "../../eco-kernel-cpp/src/eco/Env.hpp"

#include <pthread.h>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <atomic>
#include <csignal>
#include <iostream>
#include <unistd.h>
#include <elf.h>
#include <link.h>

// Default stack size for AOT-compiled Eco binaries (64 MB).
// The Elm compiler's recursive type decoders can exhaust the default 8 MB
// Linux stack when self-compiling, mirroring the Node.js --stack-size=65536.
static constexpr size_t ECO_DEFAULT_STACK_SIZE = 64ULL * 1024 * 1024;

// Parse the .llvm_stackmaps section from the running executable so the GC
// can discover stack roots at safepoints.  Uses dl_iterate_phdr to walk the
// ELF program headers and find the section in the main executable.
static void initStackMapFromSelf() {
    struct CallbackData { const uint8_t *data; size_t size; uint64_t loadBase; };
    CallbackData cbd{nullptr, 0, 0};

    dl_iterate_phdr([](struct dl_phdr_info *info, size_t /*size*/, void *ctx) -> int {
        // The main executable's name: glibc reports "" (empty); musl-static
        // reports "/proc/self/exe". Accept either as the main program.
        // (For a fully-static binary there is only one object anyway.)
        // NB: the old `dlpi_name[0] != '\0'` test was a glibc-ism — on musl
        // it skipped the main executable, so .llvm_stackmaps was never found
        // and the GC scanned zero stack roots (live stack-referenced objects
        // were then reclaimed, corrupting the heap).
        {
            const char* nm = info->dlpi_name;
            bool is_main = (nm == nullptr) || (nm[0] == '\0') ||
                           (std::strcmp(nm, "/proc/self/exe") == 0);
            if (!is_main)
                return 0;
        }

        // Walk the program headers to find PT_LOAD segments, then scan
        // the ELF section headers (accessible via /proc/self/exe) for
        // the .llvm_stackmaps section.  A simpler approach: look for the
        // section by opening our own binary via /proc/self/exe.
        // (dl_iterate_phdr only gives us program headers, not sections.)
        auto *out = static_cast<CallbackData *>(ctx);

        FILE *f = fopen("/proc/self/exe", "rb");
        if (!f) return 0;

        Elf64_Ehdr ehdr;
        if (fread(&ehdr, sizeof(ehdr), 1, f) != 1) { fclose(f); return 0; }

        // Read section header string table.
        Elf64_Shdr shstrtab_hdr;
        if (fseek(f, ehdr.e_shoff + ehdr.e_shstrndx * ehdr.e_shentsize, SEEK_SET) != 0 ||
            fread(&shstrtab_hdr, sizeof(shstrtab_hdr), 1, f) != 1) {
            fclose(f); return 0;
        }
        std::vector<char> shstrtab(shstrtab_hdr.sh_size);
        if (fseek(f, shstrtab_hdr.sh_offset, SEEK_SET) != 0 ||
            fread(shstrtab.data(), shstrtab_hdr.sh_size, 1, f) != 1) {
            fclose(f); return 0;
        }

        // Scan section headers for .llvm_stackmaps.
        for (uint16_t i = 0; i < ehdr.e_shnum; i++) {
            Elf64_Shdr shdr;
            if (fseek(f, ehdr.e_shoff + i * ehdr.e_shentsize, SEEK_SET) != 0 ||
                fread(&shdr, sizeof(shdr), 1, f) != 1)
                continue;
            if (shdr.sh_name >= shstrtab_hdr.sh_size) continue;
            const char *name = shstrtab.data() + shdr.sh_name;
            if (strcmp(name, ".llvm_stackmaps") == 0) {
                // Found it — the section's sh_addr is the virtual address
                // (relocated by the loader).  For a PIE, add the load base.
                out->data = reinterpret_cast<const uint8_t *>(
                    info->dlpi_addr + shdr.sh_addr);
                out->size = shdr.sh_size;
                out->loadBase = info->dlpi_addr;
                fclose(f);
                return 1; // stop iteration
            }
        }
        fclose(f);
        return 0;
    }, &cbd);

    if (cbd.data && cbd.size > 0) {
        // The .llvm_stackmaps section has relocations that are resolved by
        // the dynamic linker, so function addresses are already absolute.
        // Pass loadBase=0 (no additional relocation needed).
        bool ok = Elm::globalStackMap().parse(cbd.data, cbd.size, /*loadBase=*/0);
#if ECO_GC_DEBUG
        fprintf(stderr, "[init] stackmap: data=%p size=%zu parsed=%d hasRecords=%d\n",
                (void*)cbd.data, cbd.size, (int)ok,
                (int)Elm::globalStackMap().hasRecords());
#endif
        (void)ok;
    } else {
#if ECO_GC_DEBUG
        fprintf(stderr, "[init] stackmap: NOT FOUND (data=%p size=%zu)\n",
                (void*)cbd.data, cbd.size);
#endif
    }
}

extern "C" {

// Generated by EcoToLLVM pass when eco.global ops are present.
// Declared weak so modules without globals link correctly.
__attribute__((weak)) void __eco_init_globals();

// The Elm main function, renamed from "main" to "eco_main" by eco-boot
// during LLVM IR emission to avoid conflict with this C main.
int64_t eco_main();

// Effect manager registration (from ElmKernel_EffectRegistry).
void eco_register_all_effect_managers();

// Eco kernel GC root registration (MVar + Runtime saved-state).
void Eco_Kernel_register_all_gc_roots();

} // extern "C"

struct MainArgs {
    int argc;
    char **argv;
    int result;
};

static void *eco_main_thread(void *arg) {
    auto *args = static_cast<MainArgs *>(arg);

    // Initialize the generational GC and thread-local heap.
    Elm::Allocator::instance().initialize();
    Elm::Allocator::instance().initThread();

    // Register Eco kernel GC roots (MVar table, Runtime saved state) before
    // any Elm code runs so an early GC sees them.
    Eco_Kernel_register_all_gc_roots();

    // Parse the .llvm_stackmaps section so the GC can find stack roots.
    initStackMapFromSelf();

    // Register global variables as GC roots (if the module has any).
    if (__eco_init_globals)
        __eco_init_globals();

    // Store argc/argv so Eco.Kernel.Env.rawArgs can return them.
    Eco::Kernel::Env::init(args->argc, args->argv);

    // Register effect managers (Time, Http, etc.) with the scheduler.
    eco_register_all_effect_managers();

    // Run the Elm program.
    int64_t result = eco_main();

    // Cleanup thread-local allocator state.
    Elm::Allocator::instance().cleanupThread();

    args->result = static_cast<int>(result);
    return nullptr;
}

// ============================================================================
// GC stats reporting on exit / crash.
// ============================================================================
//
// On normal exit, an atexit handler prints the combined GC statistics. To
// also cover crashes (SIGABRT from assert(), SIGSEGV, etc.) we install a
// signal handler that prints the same stats then restores the default
// disposition and re-raises so a core dump (or the assertion message) is
// still produced.
//
// The print path uses iostreams (and acquires a recursive mutex inside
// getCombinedStats), which are not strictly async-signal-safe. In practice
// this is good enough for SIGABRT from assertion failures and for
// SIGINT/SIGTERM, which is the case Stage 7 needs. SIGSEGV from heap
// corruption may deadlock or crash inside the print — accepted risk.
#if ENABLE_GC_STATS
static std::atomic<bool> g_stats_printed{false};

static void printGCStatsOnce(const char *reason) {
    if (g_stats_printed.exchange(true)) return;
    // Use write() syscall for the marker (async-signal-safe). If the
    // process dies mid-print we still know the handler ran.
    {
        char buf[128];
        int n = std::snprintf(buf, sizeof(buf),
                              "\n[gc-stats] %s — printing GC statistics\n",
                              reason);
        if (n > 0) {
            ::write(STDERR_FILENO, buf, static_cast<size_t>(n));
        }
    }
    Elm::Allocator::instance().getCombinedStats().print();
    // Flush BOTH the C++ stream buffer and the underlying FILE* buffer.
    // print() writes via std::cout, which has its own buffer separate from
    // stdout's; without the explicit cout.flush(), an immediate
    // std::raise(sig) → SIG_DFL termination can drop everything past the
    // last sync point.
    std::cout.flush();
    std::fflush(stdout);
    std::fflush(stderr);
}

static void atexitPrintStats() {
    printGCStatsOnce("normal exit");
}

static void signalPrintStats(int sig) {
    // Restore the default handler so the re-raise produces the usual
    // termination effect (core dump for SIGSEGV/SIGABRT, exit for SIGTERM).
    std::signal(sig, SIG_DFL);
    const char *name = "signal";
    switch (sig) {
        case SIGABRT: name = "SIGABRT"; break;
        case SIGSEGV: name = "SIGSEGV"; break;
        case SIGBUS:  name = "SIGBUS";  break;
        case SIGFPE:  name = "SIGFPE";  break;
        case SIGILL:  name = "SIGILL";  break;
        case SIGINT:  name = "SIGINT";  break;
        case SIGTERM: name = "SIGTERM"; break;
        case SIGQUIT: name = "SIGQUIT"; break;
        case SIGPIPE: name = "SIGPIPE"; break;
    }
    printGCStatsOnce(name);
    std::raise(sig);
}

static void installStatsHandlers() {
    std::atexit(atexitPrintStats);

    struct sigaction sa{};
    sa.sa_handler = signalPrintStats;
    sigemptyset(&sa.sa_mask);
    // Don't set SA_RESETHAND; we restore SIG_DFL inside the handler.
    sa.sa_flags = SA_NODEFER;
    int signals[] = {
        SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL,
        SIGINT, SIGTERM, SIGQUIT, SIGPIPE
    };
    for (int s : signals) {
        sigaction(s, &sa, nullptr);
    }
}
#else
static void installStatsHandlers() {}
#endif

int main(int argc, char **argv) {
    // Disable stdio buffering so progress lines and (more importantly) the
    // GCStats summary printed by signal handlers reach the captured log
    // files even when the process is killed mid-print. Stdout in particular
    // is fully-buffered by default when not connected to a terminal.
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::setvbuf(stderr, nullptr, _IONBF, 0);

    installStatsHandlers();

    MainArgs args{argc, argv, 0};

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, ECO_DEFAULT_STACK_SIZE);

    pthread_t thread;
    if (pthread_create(&thread, &attr, eco_main_thread, &args) != 0) {
        // Fallback: run on main thread if thread creation fails.
        eco_main_thread(&args);
    } else {
        pthread_join(thread, nullptr);
    }

    pthread_attr_destroy(&attr);
    return args.result;
}
