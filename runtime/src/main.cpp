/**
 * Eco Runtime Demo Application.
 *
 * This program demonstrates the eco-runtime garbage collector by simulating
 * an Elm-like workload. It creates a "model" Record containing multiple lists,
 * then repeatedly reverses lists to generate allocation pressure. This mimics
 * how an Elm application's Model is updated each frame.
 *
 * Each program thread has its own private heap space (nursery + old gen) and
 * runs independently without GC coordination with other threads. Each thread
 * triggers its own minor and major GC as needed.
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
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <execinfo.h>
#include <getopt.h>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <optional>
#include <random>
#include <stdexcept>
#include <thread>
#include <vector>

#include "Allocator.hpp"
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

// Shutdown flag - set by signal handler to stop all threads.
static std::atomic<bool> shutdown_requested{false};

// Thread-local Cons cell count - no synchronization needed since each thread
// only writes to its own counter.
static thread_local uint64_t tl_cons_count = 0;

// Vector to collect final counts from each thread after they finish.
// Protected by mutex since threads write their final counts concurrently.
static std::mutex cons_counts_mutex;
static std::vector<uint64_t> final_cons_counts;

// Workload configuration (set via command-line arguments).
static size_t model_num_fields = 8;                  // Number of fields in the model Record.
static size_t list_size = 500;                       // Number of integers in each list.
static std::chrono::seconds duration{0};             // Run duration (0 = run until Ctrl+C).
static double major_gc_threshold = 0.5;              // Fraction of old gen max that triggers major GC.
static size_t max_old_gen_bytes = 64 * 1024 * 1024;  // Max old gen size before major GC (64MB default).
static double reversal_probability = 0.5;            // Probability of reversing each field's list.
static size_t num_program_threads = 1;               // Number of program threads to run.
static bool use_hybrid_dfs = true;                   // Use hybrid DFS/BFS for improved heap locality.

// ============================================================================
// Signal Handlers
// ============================================================================

// Handles SIGINT and SIGTERM to initiate graceful shutdown.
static void shutdownHandler(int signum) {
    (void)signum;
    shutdown_requested.store(true);
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
static HPointer allocateInt(Allocator& alloc, i64 value) {
    void* obj = alloc.allocate(sizeof(ElmInt), Tag_Int);
    if (!obj) {
        throw AllocationError("Failed to allocate ElmInt");
    }

    ElmInt* elm_int = static_cast<ElmInt*>(obj);
    elm_int->value = value;
    return alloc.wrap(obj);
}

// Allocates a Cons cell with an unboxed integer as its head.
// The integer value is stored directly in the cell rather than as a pointer.
// Throws AllocationError if allocation fails.
static HPointer allocateConsInt(Allocator& alloc, i64 value, HPointer tail) {
    void* obj = alloc.allocate(sizeof(Cons), Tag_Cons);
    if (!obj) {
        throw AllocationError("Failed to allocate Cons cell");
    }

    Cons* cons = static_cast<Cons*>(obj);
    cons->header.unboxed = 1;  // Mark head as unboxed integer.
    cons->head.i = value;
    cons->tail = tail;
    return alloc.wrap(obj);
}

// Creates a linked list of integers [0, 1, 2, ..., size-1].
// Builds the list in reverse order since cons prepends to the front.
static HPointer createIntList(Allocator& alloc, size_t size) {
    HPointer list = createNil();

    // Register list as stack root so GC can update it during allocations.
    size_t root_point = alloc.getRootSet().stackRootPoint();
    alloc.getRootSet().pushStackRoot(&list);

    for (size_t i = size; i > 0; i--) {
        HPointer new_cons = allocateConsInt(alloc, static_cast<i64>(i - 1), list);
        alloc.getRootSet().replaceHead(new_cons);
        list = new_cons;
        ++tl_cons_count;
    }

    alloc.getRootSet().restoreStackRootPoint(root_point);
    return list;
}

// Reverses a list by allocating new Cons cells.
// This is a pure functional reverse: the original list is unchanged.
//
// Implementation note: The input list is already rooted through the model record.
// We only need to track acc as a stack root since it grows during allocation.
// Throws CorruptHeapError if list contains null pointer, AllocationError on OOM.
static HPointer reverseList(Allocator& alloc, HPointer list) {
    HPointer acc = createNil();

    // Track acc as a stack root - it will be updated via replaceHead as we build.
    size_t root_point = alloc.getRootSet().stackRootPoint();
    alloc.getRootSet().pushStackRoot(&acc);

    while (list.constant != Const_Nil) {
        void* obj = alloc.resolve(list);
        if (!obj) {
            alloc.getRootSet().restoreStackRootPoint(root_point);
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
        void* new_obj = alloc.allocate(sizeof(Cons), Tag_Cons);
        if (!new_obj) {
            alloc.getRootSet().restoreStackRootPoint(root_point);
            throw AllocationError("Failed to allocate Cons during list reversal");
        }

        Cons* new_cons = static_cast<Cons*>(new_obj);
        new_cons->header.unboxed = unboxed_flag;
        new_cons->head = head_copy;
        new_cons->tail = acc;

        // Update acc via replaceHead to track the new cons cell.
        alloc.getRootSet().replaceHead(alloc.wrap(new_obj));
        acc = alloc.wrap(new_obj);
        ++tl_cons_count;
    }

    alloc.getRootSet().restoreStackRootPoint(root_point);

    return acc;
}

// Allocates a Record with the given number of fields, all initialized to Nil.
// Records are variable-size objects with a header followed by field values.
// Throws AllocationError if allocation fails.
static HPointer allocateRecord(Allocator& alloc, size_t num_fields) {
    size_t size = sizeof(Record) + num_fields * sizeof(Unboxable);
    void* obj = alloc.allocate(size, Tag_Record);
    if (!obj) {
        throw AllocationError("Failed to allocate Record");
    }

    Record* record = static_cast<Record*>(obj);
    record->header.size = static_cast<u32>(num_fields);
    record->unboxed = 0;  // All fields are boxed (pointers), not unboxed values.

    for (size_t i = 0; i < num_fields; i++) {
        record->values[i].p = createNil();
    }

    return alloc.wrap(obj);
}

// Updates a root Record in place with one field changed (functional update).
// Precondition: record_ptr must already be registered as a root.
// The old record is unrooted and the new record becomes the root.
//
// This implements Elm's record update syntax: { record | field = value }.
// A new record is allocated with all fields copied except the updated one.
// Throws CorruptHeapError if record_ptr is null, AllocationError on OOM.
static void updateRootRecord(Allocator& alloc, HPointer& record_ptr,
                              size_t field_index, HPointer new_value) {
    void* old_obj = alloc.resolve(record_ptr);
    if (!old_obj) {
        throw CorruptHeapError("Record pointer is null in updateRootRecord");
    }

    Record* old_record = static_cast<Record*>(old_obj);
    size_t num_fields = old_record->header.size;

    size_t size = sizeof(Record) + num_fields * sizeof(Unboxable);
    void* new_obj = alloc.allocate(size, Tag_Record);
    if (!new_obj) {
        throw AllocationError("Failed to allocate Record in updateRootRecord");
    }

    // Re-derive old_record since GC may have relocated it during allocation.
    old_obj = alloc.resolve(record_ptr);
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
    alloc.getRootSet().removeRoot(&record_ptr);
    record_ptr = alloc.wrap(new_obj);
    alloc.getRootSet().addRoot(&record_ptr);
}

// ============================================================================
// Major GC Trigger
// ============================================================================

// Checks if major GC should be triggered based on old gen usage.
// Each thread calls this with its own allocator - no coordination needed.
static void checkAndRunMajorGC(Allocator& alloc) {
    size_t old_gen_bytes = alloc.getOldGenAllocatedBytes();
    size_t threshold_bytes = static_cast<size_t>(max_old_gen_bytes * major_gc_threshold);

    if (old_gen_bytes >= threshold_bytes) {
        alloc.majorGC();
    }
}

// ============================================================================
// Program Loop
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
// Each thread runs this loop with its own private heap space.
// GC (both minor and major) is triggered locally within each thread.
static void runProgramLoop(Allocator& alloc, int thread_id) {
    size_t iterations = 0;

    try {
        std::cout << "[Thread " << thread_id << "] Started with " << model_num_fields
                  << " fields, list size " << list_size
                  << ", major GC threshold " << (major_gc_threshold * 100) << "%"
                  << ", reversal probability " << reversal_probability << std::endl;

        // Random number generator for selecting which field to reverse.
        std::random_device rd;
        std::mt19937 gen(rd());
        std::uniform_real_distribution<double> prob_dist(0.0, 1.0);

        // Create initial model: a Record with model_num_fields fields.
        HPointer model = allocateRecord(alloc, model_num_fields);

        // The model must be registered as a root so GC can find and update it.
        alloc.getRootSet().addRoot(&model);

        // Initialize each field with a list of integers [0..list_size-1].
        for (size_t i = 0; i < model_num_fields; i++) {
            HPointer list = createIntList(alloc, list_size);
            updateRootRecord(alloc, model, i, list);
        }

        // Main loop: repeatedly reverse a randomly-selected list.
        while (!shutdown_requested.load()) {
            // Select a field using probabilistic strategy: test each field with
            // probability P, falling back to the last field if none selected.
            // This creates variable allocation patterns across fields.
            size_t field_index = 0;
            bool field_selected = false;

            void* model_obj = alloc.resolve(model);
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
            HPointer reversed = reverseList(alloc, current_list);

            // Update model with the reversed list in the selected field.
            // updateRootRecord handles root management internally.
            updateRootRecord(alloc, model, field_index, reversed);

            iterations++;

            // Trigger minor GC when nursery is 90% full to avoid overflow.
            if (alloc.isNurseryNearFull(0.9f)) {
                alloc.minorGC();
            }

            // Check and run major GC when old generation exceeds threshold.
            checkAndRunMajorGC(alloc);

            // Yield periodically.
            if (iterations % 1000 == 0) {
                std::this_thread::yield();
            }
        }

        // Clean up: unregister model root before exiting.
        alloc.getRootSet().removeRoot(&model);

    } catch (const std::exception& e) {
        std::cerr << "\n[Thread " << thread_id << "] FATAL ERROR: " << e.what() << "\n";
        printStackTrace();
        shutdown_requested.store(true);
    }

    // Save thread-local cons count to global vector for aggregation.
    {
        std::lock_guard<std::mutex> lock(cons_counts_mutex);
        final_cons_counts.push_back(tl_cons_count);
    }

    std::cout << "[Thread " << thread_id << "] Stopped after " << iterations << " iterations" << std::endl;
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
              << "      --dfs               Enable hybrid DFS/BFS for heap locality (default: on)\n"
              << "      --no-dfs            Disable hybrid DFS, use pure BFS (Cheney's algorithm)\n"
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
    // Option codes for long-only options (no short form).
    enum { OPT_DFS = 256, OPT_NO_DFS };

    static struct option long_options[] = {
        {"duration",   required_argument, nullptr, 'd'},
        {"fields",     required_argument, nullptr, 'f'},
        {"list-size",  required_argument, nullptr, 'l'},
        {"threshold",  required_argument, nullptr, 't'},
        {"probability",required_argument, nullptr, 'p'},
        {"threads",    required_argument, nullptr, 'n'},
        {"dfs",        no_argument,       nullptr, OPT_DFS},
        {"no-dfs",     no_argument,       nullptr, OPT_NO_DFS},
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
            case OPT_DFS:
                use_hybrid_dfs = true;
                break;
            case OPT_NO_DFS:
                use_hybrid_dfs = false;
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

// Thread function that initializes thread-local heap and runs the program loop.
// Note: We don't call cleanupThread() here so that getCombinedStats() can
// aggregate stats from all threads after they finish. The allocator destructor
// will clean up all thread heaps.
static void programThreadFunc(Allocator& alloc, int thread_id) {
    try {
        // Initialize this thread's heap space.
        alloc.initThread();

        // Run the program loop.
        runProgramLoop(alloc, thread_id);

        // Don't call cleanupThread() - let main() print stats first.
    } catch (const std::exception& e) {
        std::cerr << "\n[Thread " << thread_id << "] FATAL ERROR: " << e.what() << "\n";
        printStackTrace();
        shutdown_requested.store(true);
    }
}

// Entry point: initializes allocator and runs the program loop(s).
// Each thread has its own private heap space (nursery + old gen).
int main(int argc, char* argv[]) {
    if (!parseArgs(argc, argv)) {
        printUsage(argv[0]);
        return 1;
    }

    // Record program start time.
    auto program_start = std::chrono::steady_clock::now();

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

        // Initialize the allocator with a 2GB heap reservation.
        auto& alloc = Allocator::instance();
        HeapConfig config;
        config.max_heap_size = 2ULL * 1024 * 1024 * 1024;  // 2GB heap
        config.use_hybrid_dfs = use_hybrid_dfs;
        alloc.initialize(config);

        std::cout << "Allocator initialized with " << num_program_threads << " thread(s) "
                  << "(major GC threshold: " << (major_gc_threshold * 100) << "% of "
                  << (max_old_gen_bytes / (1024 * 1024)) << "MB, "
                  << "hybrid DFS: " << (use_hybrid_dfs ? "on" : "off") << ")" << std::endl;

        // Set up duration-based shutdown if specified.
        std::thread duration_thread;
        if (duration.count() > 0) {
            std::cout << "Running for " << duration.count() << " seconds..." << std::endl;
            duration_thread = std::thread([&]() {
                std::this_thread::sleep_for(duration);
                std::cout << "Duration elapsed, shutting down..." << std::endl;
                shutdown_requested.store(true);
            });
        } else {
            std::cout << "Running until Ctrl+C..." << std::endl;
        }

        // Reserve space for final cons counts from each thread.
        final_cons_counts.reserve(num_program_threads);

        // Create and start program threads.
        std::vector<std::thread> program_threads;
        program_threads.reserve(num_program_threads);

        for (size_t i = 0; i < num_program_threads; i++) {
            program_threads.emplace_back(programThreadFunc, std::ref(alloc), static_cast<int>(i));
        }

        // Wait for all program threads to finish.
        for (auto& t : program_threads) {
            t.join();
        }

        // Wait for duration thread if it was started.
        if (duration_thread.joinable()) {
            duration_thread.join();
        }

        // Record program end time.
        auto program_end = std::chrono::steady_clock::now();
        auto program_duration = std::chrono::duration_cast<std::chrono::milliseconds>(
            program_end - program_start);

        // Print combined GC statistics if enabled at compile time.
#if ENABLE_GC_STATS
        alloc.getCombinedStats().print();
#endif

        // Sum up Cons cell counts from all threads.
        uint64_t total_cons_cells = 0;
        for (uint64_t count : final_cons_counts) {
            total_cons_cells += count;
        }

        // Print throughput statistics.
        double duration_sec = program_duration.count() / 1000.0;
        double throughput = (duration_sec > 0) ? (total_cons_cells / duration_sec) : 0;

        std::cout << "\n=== Throughput Statistics ===" << std::endl;
        std::cout << "Cons cells created: " << total_cons_cells << std::endl;
        std::cout << "Program runtime: " << std::fixed << std::setprecision(2)
                  << duration_sec << " s" << std::endl;
        std::cout << "Throughput: " << std::fixed << std::setprecision(2)
                  << (throughput / 1e6) << " M cells/sec" << std::endl;

        std::cout << "\nGoodbye!" << std::endl;
        return 0;

    } catch (const std::exception& e) {
        std::cerr << "\n[Main] FATAL ERROR: " << e.what() << "\n";
        printStackTrace();
        return 1;
    }
}
