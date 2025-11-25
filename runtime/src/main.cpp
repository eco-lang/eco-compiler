/**
 * Eco Runtime Demo Application.
 *
 * This program demonstrates the eco-runtime garbage collector by simulating
 * an Elm-like workload. It creates a "model" Record containing multiple lists,
 * then repeatedly reverses lists to generate allocation pressure. This mimics
 * how an Elm application's Model is updated each frame.
 *
 * The program runs two threads:
 *   - Program thread: Simulates Elm's update cycle by reversing lists.
 *   - Collector thread: Runs major GC when the old generation exceeds a threshold.
 *
 * Usage:
 *   ./ecor [options]
 *   ./ecor --duration 30s --fields 8 --list-size 500
 *   ./ecor -d 1m -f 16 -l 1000 -t 100
 *
 * The program runs until Ctrl+C or the specified duration elapses.
 */

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <execinfo.h>
#include <getopt.h>
#include <iostream>
#include <mutex>
#include <optional>
#include <random>
#include <stdexcept>
#include <thread>
#include <vector>

#include "GarbageCollector.hpp"
#include "GCStats.hpp"
#include "Heap.hpp"
#include "OldGenSpace.hpp"

using namespace Elm;

// ============================================================================
// Exception Types
// ============================================================================

// Thrown when heap allocation fails (out of memory).
class AllocationError : public std::runtime_error {
public:
    explicit AllocationError(const char* msg) : std::runtime_error(msg) {}
};

// Thrown when a heap pointer is unexpectedly null (indicates corruption).
class CorruptHeapError : public std::runtime_error {
public:
    explicit CorruptHeapError(const char* msg) : std::runtime_error(msg) {}
};

// Prints a stack trace to stderr for debugging.
static void printStackTrace() {
    constexpr int MAX_FRAMES = 64;
    void* callstack[MAX_FRAMES];
    int frames = backtrace(callstack, MAX_FRAMES);
    char** symbols = backtrace_symbols(callstack, frames);
    if (symbols) {
        std::cerr << "Stack trace:\n";
        for (int i = 0; i < frames; i++) {
            std::cerr << "  [" << i << "] " << symbols[i] << "\n";
        }
        free(symbols);
    }
}

// ============================================================================
// Global State
// ============================================================================

// Thread coordination flags.
static std::atomic<bool> shutdown_requested{false};  // Set by signal handler to stop all threads.
static std::atomic<bool> gc_requested{false};        // Set by program thread to request major GC.
static std::mutex gc_mutex;                          // Protects gc_condition waits.
static std::condition_variable gc_condition;         // Wakes collector thread on GC request or shutdown.

// Workload configuration (set via command-line arguments).
static size_t model_num_fields = 8;                  // Number of fields in the model Record.
static size_t list_size = 500;                       // Number of integers in each list.
static std::chrono::seconds duration{0};             // Run duration (0 = run until Ctrl+C).
static double major_gc_threshold = 0.9;              // Fraction of old gen that triggers major GC.
static double reversal_probability = 0.5;            // Probability of reversing each field's list.
static size_t num_program_threads = 1;               // Number of program threads to run.

// ============================================================================
// Signal Handlers
// ============================================================================

// Handles SIGINT and SIGTERM to initiate graceful shutdown.
static void shutdownHandler(int signum) {
    (void)signum;
    shutdown_requested.store(true);
    gc_condition.notify_all();
}

// Handles fatal signals (SIGSEGV, SIGABRT, SIGBUS, SIGFPE) by printing a stack trace.
// Uses addr2line to get source file and line numbers.
static void fatalSignalHandler(int sig) {
    constexpr int MAX_FRAMES = 64;
    void* callstack[MAX_FRAMES];

    size_t frames = backtrace(callstack, MAX_FRAMES);
    char** symbols = backtrace_symbols(callstack, frames);

    // Print signal info.
    const char* sig_name =
        sig == SIGSEGV ? "SIGSEGV" :
        sig == SIGABRT ? "SIGABRT" :
        sig == SIGBUS  ? "SIGBUS" :
        sig == SIGFPE  ? "SIGFPE" : "UNKNOWN";

    fprintf(stderr, "\n=== FATAL SIGNAL ===\n");
    fprintf(stderr, "Signal: %d (%s)\n", sig, sig_name);
    fprintf(stderr, "Stack trace:\n");

    // Get the executable path for addr2line.
    char exe_path[1024];
    ssize_t len = readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1);
    if (len != -1) {
        exe_path[len] = '\0';
    } else {
        exe_path[0] = '\0';
    }

    for (size_t i = 0; i < frames; i++) {
        const char* symbol = symbols ? symbols[i] : "???";

        // Extract the binary offset from symbol string.
        // Format: "./build/ecor(+0x308a6) [0x5564e291e8a6]" or
        //         "./build/ecor(_ZN3Elm...+0x1c4) [0x...]"
        // We need the offset (after '+') for addr2line due to ASLR.
        char addr_str[64] = {0};
        const char* plus = strchr(symbol, '+');
        const char* paren_close = strchr(symbol, ')');
        if (plus && paren_close && plus < paren_close) {
            size_t len = paren_close - plus - 1;
            if (len < sizeof(addr_str)) {
                strncpy(addr_str, plus + 1, len);
                addr_str[len] = '\0';
            }
        }

        // Try to get source location using addr2line.
        char func_name[512] = {0};
        char location[512] = {0};
        bool got_location = false;

        if (exe_path[0] != '\0' && addr_str[0] != '\0') {
            char cmd[2048];
            snprintf(cmd, sizeof(cmd), "addr2line -f -C -e %s %s 2>/dev/null", exe_path, addr_str);

            FILE* pipe = popen(cmd, "r");
            if (pipe) {
                if (fgets(func_name, sizeof(func_name), pipe) &&
                    fgets(location, sizeof(location), pipe)) {
                    // Remove newlines.
                    func_name[strcspn(func_name, "\n")] = '\0';
                    location[strcspn(location, "\n")] = '\0';

                    // Check if we got useful info.
                    if (strcmp(func_name, "??") != 0 && strstr(location, "??") == nullptr) {
                        got_location = true;
                    }
                }
                pclose(pipe);
            }
        }

        // Print frame with source location if available.
        if (got_location) {
            fprintf(stderr, "  [%2zu] %s\n", i, func_name);
            fprintf(stderr, "       at %s\n", location);
        } else {
            fprintf(stderr, "  [%2zu] %s\n", i, symbol);
        }
    }

    if (symbols) {
        free(symbols);
    }

    // Re-raise signal with default handler to get proper exit code.
    signal(sig, SIG_DFL);
    raise(sig);
}

// ============================================================================
// Helper Functions
// ============================================================================

// Returns an HPointer representing the Nil constant (empty list).
static HPointer createNil() {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = Const_Nil;
    ptr.padding = 0;
    return ptr;
}

// Allocates an ElmInt on the heap with the given value.
// Throws AllocationError if allocation fails.
static HPointer allocateInt(GarbageCollector& gc, i64 value) {
    void* obj = gc.allocate(sizeof(ElmInt), Tag_Int);
    if (!obj) {
        throw AllocationError("Failed to allocate ElmInt");
    }

    ElmInt* elm_int = static_cast<ElmInt*>(obj);
    elm_int->value = value;
    return gc.wrap(obj);
}

// Allocates a Cons cell with an unboxed integer as its head.
// The integer value is stored directly in the cell rather than as a pointer.
// Throws AllocationError if allocation fails.
static HPointer allocateConsInt(GarbageCollector& gc, i64 value, HPointer tail) {
    void* obj = gc.allocate(sizeof(Cons), Tag_Cons);
    if (!obj) {
        throw AllocationError("Failed to allocate Cons cell");
    }

    Cons* cons = static_cast<Cons*>(obj);
    cons->header.unboxed = 1;  // Mark head as unboxed integer.
    cons->head.i = value;
    cons->tail = tail;
    return gc.wrap(obj);
}

// Creates a linked list of integers [0, 1, 2, ..., size-1].
// Builds the list in reverse order since cons prepends to the front.
static HPointer createIntList(GarbageCollector& gc, size_t size) {
    HPointer list = createNil();

    // Register list as stack root so GC can update it during allocations.
    size_t root_point = gc.getRootSet().stackRootPoint();
    gc.getRootSet().pushStackRoot(&list);

    for (size_t i = size; i > 0; i--) {
        HPointer new_cons = allocateConsInt(gc, static_cast<i64>(i - 1), list);
        gc.getRootSet().replaceHead(new_cons);
        list = new_cons;
    }

    gc.getRootSet().restoreStackRootPoint(root_point);
    return list;
}

// Reverses a list by allocating new Cons cells.
// This is a pure functional reverse: the original list is unchanged.
//
// Implementation note: The input list is already rooted through the model record.
// We only need to track acc as a stack root since it grows during allocation.
// Throws CorruptHeapError if list contains null pointer, AllocationError on OOM.
static HPointer reverseList(GarbageCollector& gc, HPointer list) {
    HPointer acc = createNil();

    // Track acc as a stack root - it will be updated via replaceHead as we build.
    size_t root_point = gc.getRootSet().stackRootPoint();
    gc.getRootSet().pushStackRoot(&acc);

    while (list.constant != Const_Nil) {
        void* obj = gc.resolve(list);
        if (!obj) {
            gc.getRootSet().restoreStackRootPoint(root_point);
            throw CorruptHeapError("Null pointer encountered during list reversal");
        }

        Cons* cons = static_cast<Cons*>(obj);

        // Copy head value before allocation. The allocation may trigger GC,
        // which could relocate 'cons', making the pointer invalid.
        u64 unboxed_flag = cons->header.unboxed;
        Unboxable head_copy = cons->head;

        // Advance to next element before allocation for the same reason.
        list = cons->tail;

        // Allocate new cons cell with head prepended to accumulator.
        void* new_obj = gc.allocate(sizeof(Cons), Tag_Cons);
        if (!new_obj) {
            gc.getRootSet().restoreStackRootPoint(root_point);
            throw AllocationError("Failed to allocate Cons during list reversal");
        }

        Cons* new_cons = static_cast<Cons*>(new_obj);
        new_cons->header.unboxed = unboxed_flag;
        new_cons->head = head_copy;
        new_cons->tail = acc;

        // Update acc via replaceHead to track the new cons cell.
        gc.getRootSet().replaceHead(gc.wrap(new_obj));
        acc = gc.wrap(new_obj);
    }

    gc.getRootSet().restoreStackRootPoint(root_point);

    return acc;
}

// Allocates a Record with the given number of fields, all initialized to Nil.
// Records are variable-size objects with a header followed by field values.
// Throws AllocationError if allocation fails.
static HPointer allocateRecord(GarbageCollector& gc, size_t num_fields) {
    size_t size = sizeof(Record) + num_fields * sizeof(Unboxable);
    void* obj = gc.allocate(size, Tag_Record);
    if (!obj) {
        throw AllocationError("Failed to allocate Record");
    }

    Record* record = static_cast<Record*>(obj);
    record->header.size = static_cast<u32>(num_fields);
    record->unboxed = 0;  // All fields are boxed (pointers), not unboxed values.

    for (size_t i = 0; i < num_fields; i++) {
        record->values[i].p = createNil();
    }

    return gc.wrap(obj);
}

// Updates a root Record in place with one field changed (functional update).
// Precondition: record_ptr must already be registered as a root.
// The old record is unrooted and the new record becomes the root.
//
// This implements Elm's record update syntax: { record | field = value }.
// A new record is allocated with all fields copied except the updated one.
// Throws CorruptHeapError if record_ptr is null, AllocationError on OOM.
static void updateRootRecord(GarbageCollector& gc, HPointer& record_ptr,
                              size_t field_index, HPointer new_value) {
    void* old_obj = gc.resolve(record_ptr);
    if (!old_obj) {
        throw CorruptHeapError("Record pointer is null in updateRootRecord");
    }

    Record* old_record = static_cast<Record*>(old_obj);
    size_t num_fields = old_record->header.size;

    size_t size = sizeof(Record) + num_fields * sizeof(Unboxable);
    void* new_obj = gc.allocate(size, Tag_Record);
    if (!new_obj) {
        throw AllocationError("Failed to allocate Record in updateRootRecord");
    }

    // Re-derive old_record since GC may have relocated it during allocation.
    old_obj = gc.resolve(record_ptr);
    old_record = static_cast<Record*>(old_obj);

    Record* new_record = static_cast<Record*>(new_obj);
    new_record->header.size = static_cast<u32>(num_fields);
    new_record->unboxed = old_record->unboxed;

    // Copy all fields, substituting the new value at field_index.
    for (size_t i = 0; i < num_fields; i++) {
        if (i == field_index) {
            new_record->values[i].p = new_value;
        } else {
            new_record->values[i] = old_record->values[i];
        }
    }

    // Replace old record root with new record root.
    gc.getRootSet().removeRoot(&record_ptr);
    record_ptr = gc.wrap(new_obj);
    gc.getRootSet().addRoot(&record_ptr);
}

// ============================================================================
// Collector Thread
// ============================================================================

// Background thread that runs major GC when requested by the program thread.
// Waits on gc_condition for requests, with a 100ms timeout to check shutdown.
static void collectorThreadFunc() {
    try {
        auto& gc = GarbageCollector::instance();
        gc.initThread();

        std::cout << "[Collector] Started" << std::endl;

        while (!shutdown_requested.load()) {
            // Wait for GC request, shutdown signal, or 100ms timeout.
            {
                std::unique_lock<std::mutex> lock(gc_mutex);
                gc_condition.wait_for(lock, std::chrono::milliseconds(100), []() {
                    return gc_requested.load() || shutdown_requested.load();
                });
            }

            if (shutdown_requested.load()) {
                break;
            }

            if (gc_requested.load()) {
                gc_requested.store(false);
                std::cout << "MajorGC Started" << std::endl;
                gc.majorGC();
            }
        }
    } catch (const std::exception& e) {
        std::cerr << "\n[Collector] FATAL ERROR: " << e.what() << "\n";
        printStackTrace();
        shutdown_requested.store(true);
        gc_condition.notify_all();
    }

    std::cout << "[Collector] Stopped" << std::endl;
}

// Signals the collector thread to run a major GC.
// Called by the program thread when old generation exceeds the threshold.
static void requestMajorGC() {
    gc_requested.store(true);
    gc_condition.notify_all();
}

// ============================================================================
// Program Thread
// ============================================================================

// Simulates an Elm application's update cycle.
//
// Creates a model (Record) containing multiple lists, then repeatedly selects
// a random field and reverses its list. This pattern mimics how Elm apps
// continuously allocate new data structures as the Model is updated.
//
// The workload generates significant allocation pressure:
//   - Each list reversal allocates N new Cons cells.
//   - Each model update allocates a new Record.
//   - Old objects become garbage after each iteration.
//
// thread_id: Identifies this thread in log output (0-based).
static void programThreadFunc(size_t thread_id) {
    size_t iterations = 0;

    try {
        auto& gc = GarbageCollector::instance();
        gc.initThread();

        std::cout << "[Program " << thread_id << "] Started with " << model_num_fields
                  << " fields, list size " << list_size
                  << ", major GC threshold " << (major_gc_threshold * 100) << "%"
                  << ", reversal probability " << reversal_probability << std::endl;

        // Random number generator for selecting which field to reverse.
        std::random_device rd;
        std::mt19937 gen(rd());
        std::uniform_real_distribution<double> prob_dist(0.0, 1.0);

        // Create initial model: a Record with model_num_fields fields.
        HPointer model = allocateRecord(gc, model_num_fields);

        // The model must be registered as a root so GC can find and update it.
        gc.getRootSet().addRoot(&model);

        // Initialize each field with a list of integers [0..list_size-1].
        for (size_t i = 0; i < model_num_fields; i++) {
            HPointer list = createIntList(gc, list_size);
            updateRootRecord(gc, model, i, list);
        }

        // Main loop: repeatedly reverse a randomly-selected list.
        while (!shutdown_requested.load()) {
            // Select a field using probabilistic strategy: test each field with
            // probability P, falling back to the last field if none selected.
            // This creates variable allocation patterns across fields.
            size_t field_index = 0;
            bool field_selected = false;

            void* model_obj = gc.resolve(model);
            if (!model_obj) {
                throw CorruptHeapError("Model pointer became null during main loop");
            }
            Record* record = static_cast<Record*>(model_obj);

            // Test each field except the last with probability reversal_probability.
            for (field_index = 0; field_index < model_num_fields - 1; field_index++) {
                if (prob_dist(gen) < reversal_probability) {
                    field_selected = true;
                    break;
                }
            }

            // Guarantee at least one field is reversed per iteration.
            if (!field_selected) {
                field_index = model_num_fields - 1;
            }

            // Extract the list from the selected field and reverse it.
            HPointer current_list = record->values[field_index].p;
            HPointer reversed = reverseList(gc, current_list);

            // Update model with the reversed list in the selected field.
            // updateRootRecord handles root management internally.
            updateRootRecord(gc, model, field_index, reversed);

            iterations++;

            // Trigger minor GC when nursery is 90% full to avoid overflow.
            if (gc.isNurseryNearFull(0.9f)) {
                gc.minorGC();
            }

            // Request major GC when old generation exceeds threshold.
            size_t old_gen_bytes = gc.getOldGen().getAllocatedBytes();
            size_t old_gen_max = gc.getOldGen().getMaxSize();
            if (old_gen_bytes >= static_cast<size_t>(old_gen_max * major_gc_threshold)) {
                requestMajorGC();
            }

            // Yield periodically to let the collector thread run.
            if (iterations % 1000 == 0) {
                std::this_thread::yield();
            }
        }

        // Clean up: unregister model root before thread exits.
        gc.getRootSet().removeRoot(&model);

    } catch (const std::exception& e) {
        std::cerr << "\n[Program " << thread_id << "] FATAL ERROR: " << e.what() << "\n";
        printStackTrace();
        shutdown_requested.store(true);
        gc_condition.notify_all();
    }

    std::cout << "[Program " << thread_id << "] Stopped after " << iterations << " iterations" << std::endl;
}

// ============================================================================
// Command Line Parsing
// ============================================================================

// Prints usage information to stdout.
static void printUsage(const char* prog) {
    std::cout << "Usage: " << prog << " [options]\n"
              << "\n"
              << "Options:\n"
              << "  -d, --duration <time>   Run for specified duration (e.g., 30s, 5m, 1h)\n"
              << "  -f, --fields <n>        Number of fields in model record (default: 8)\n"
              << "  -l, --list-size <n>     Size of each list (default: 500)\n"
              << "  -t, --threshold <frac>  Major GC threshold as fraction of heap (default: 0.9)\n"
              << "  -p, --probability <p>   Probability of reversing each list (default: 0.5)\n"
              << "  -n, --threads <n>       Number of program threads (default: 1)\n"
              << "  -h, --help              Show this help message\n"
              << "\n"
              << "Press Ctrl+C to stop.\n";
}

// Parses a duration string like "30s", "5m", or "1h" into seconds.
// Returns nullopt on parse error.
static std::optional<std::chrono::seconds> parseDuration(const std::string& str) {
    if (str.empty()) {
        return std::nullopt;
    }

    // Find where digits end and unit begins.
    size_t i = 0;
    while (i < str.length() && std::isdigit(str[i])) {
        i++;
    }

    if (i == 0 || i == str.length()) {
        std::cerr << "Error: Invalid duration format. Expected: <number><unit> (e.g., 30s, 5m, 1h)\n";
        return std::nullopt;
    }

    long long value = std::stoll(str.substr(0, i));
    std::string unit = str.substr(i);

    if (unit == "s" || unit == "sec") {
        return std::chrono::seconds(value);
    } else if (unit == "m" || unit == "min") {
        return std::chrono::seconds(value * 60);
    } else if (unit == "h" || unit == "hr") {
        return std::chrono::seconds(value * 3600);
    } else {
        std::cerr << "Error: Unknown time unit '" << unit << "'. Valid: s, m, h\n";
        return std::nullopt;
    }
}

// Parses command-line arguments and sets global configuration variables.
// Returns false on error.
static bool parseArgs(int argc, char* argv[]) {
    static struct option long_options[] = {
        {"duration",   required_argument, nullptr, 'd'},
        {"fields",     required_argument, nullptr, 'f'},
        {"list-size",  required_argument, nullptr, 'l'},
        {"threshold",  required_argument, nullptr, 't'},
        {"probability",required_argument, nullptr, 'p'},
        {"threads",    required_argument, nullptr, 'n'},
        {"help",       no_argument,       nullptr, 'h'},
        {nullptr,      0,                 nullptr, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "d:f:l:t:p:n:h", long_options, nullptr)) != -1) {
        switch (opt) {
            case 'd': {
                auto dur = parseDuration(optarg);
                if (!dur.has_value()) return false;
                duration = dur.value();
                break;
            }
            case 'f':
                model_num_fields = std::stoul(optarg);
                if (model_num_fields < 1) {
                    std::cerr << "Error: fields must be >= 1\n";
                    return false;
                }
                break;
            case 'l':
                list_size = std::stoul(optarg);
                if (list_size < 1) {
                    std::cerr << "Error: list-size must be >= 1\n";
                    return false;
                }
                break;
            case 't':
                major_gc_threshold = std::stod(optarg);
                if (major_gc_threshold <= 0.0 || major_gc_threshold > 1.0) {
                    std::cerr << "Error: threshold must be between 0.0 and 1.0\n";
                    return false;
                }
                break;
            case 'p':
                reversal_probability = std::stod(optarg);
                if (reversal_probability < 0.0 || reversal_probability > 1.0) {
                    std::cerr << "Error: probability must be between 0.0 and 1.0\n";
                    return false;
                }
                break;
            case 'n':
                num_program_threads = std::stoul(optarg);
                if (num_program_threads < 1) {
                    std::cerr << "Error: threads must be >= 1\n";
                    return false;
                }
                break;
            case 'h':
                printUsage(argv[0]);
                exit(0);
            default:
                return false;
        }
    }

    return true;
}

// ============================================================================
// Main
// ============================================================================

// Entry point: initializes GC, starts worker threads, and waits for shutdown.
int main(int argc, char* argv[]) {
    if (!parseArgs(argc, argv)) {
        printUsage(argv[0]);
        return 1;
    }

    try {
        std::cout << "=== Eco Runtime for Elm ===" << std::endl;

        // Install signal handlers for graceful shutdown on Ctrl+C or kill.
        signal(SIGINT, shutdownHandler);
        signal(SIGTERM, shutdownHandler);

        // Install signal handlers for fatal signals to get stack traces.
        signal(SIGSEGV, fatalSignalHandler);
        signal(SIGABRT, fatalSignalHandler);
        signal(SIGBUS, fatalSignalHandler);
        signal(SIGFPE, fatalSignalHandler);

        // Initialize the garbage collector with a 2GB heap reservation.
        // The old generation can grow up to ~1GB within this space.
        auto& gc = GarbageCollector::instance();
        GCConfig config;
        config.max_heap_size = 2ULL * 1024 * 1024 * 1024;  // 2GB heap
        gc.initialize(config);
        gc.initThread();  // Main thread needs GC access too.

        std::cout << "GC initialized (memory pressure threshold: "
                  << (major_gc_threshold * 100) << "%)" << std::endl;

        // Start the collector thread.
        std::thread collector_thread(collectorThreadFunc);

        // Start the program threads.
        std::vector<std::thread> program_threads;
        program_threads.reserve(num_program_threads);
        for (size_t i = 0; i < num_program_threads; i++) {
            program_threads.emplace_back(programThreadFunc, i);
        }

        std::cout << "Started " << num_program_threads << " program thread(s)" << std::endl;

        // Main thread monitors for shutdown: either duration elapsed or signal.
        if (duration.count() > 0) {
            std::cout << "Running for " << duration.count() << " seconds..." << std::endl;
            auto start = std::chrono::steady_clock::now();

            while (!shutdown_requested.load()) {
                auto elapsed = std::chrono::steady_clock::now() - start;
                if (elapsed >= duration) {
                    std::cout << "Duration elapsed, shutting down..." << std::endl;
                    shutdown_requested.store(true);
                    gc_condition.notify_all();
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
        } else {
            std::cout << "Running until Ctrl+C..." << std::endl;
            while (!shutdown_requested.load()) {
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
        }

        // Signal shutdown to unblock any threads waiting on memory pressure.
        gc.signalShutdown();

        std::cout << "Waiting for threads to finish..." << std::endl;

        // Wait for all threads to exit cleanly.
        for (auto& t : program_threads) {
            t.join();
        }
        collector_thread.join();

        // Print combined GC statistics if enabled at compile time.
#if ENABLE_GC_STATS
        GCStats combined = gc.getCombinedNurseryStats();
        combined.combine(gc.getMajorGCStats());
        combined.print();
#endif

        std::cout << "\nGoodbye!" << std::endl;
        return 0;

    } catch (const std::exception& e) {
        std::cerr << "\n[Main] FATAL ERROR: " << e.what() << "\n";
        printStackTrace();
        return 1;
    }
}
