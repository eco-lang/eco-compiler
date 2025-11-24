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
#include <cstring>
#include <getopt.h>
#include <iostream>
#include <mutex>
#include <optional>
#include <random>
#include <thread>
#include <vector>

#include "GarbageCollector.hpp"
#include "GCStats.hpp"
#include "Heap.hpp"
#include "OldGenSpace.hpp"

using namespace Elm;

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
static size_t major_gc_threshold = 50 * 1024 * 1024; // Old gen size that triggers major GC (bytes).
static double reversal_probability = 0.5;            // Probability of reversing each field's list.

// ============================================================================
// Signal Handler
// ============================================================================

// Handles SIGINT and SIGTERM to initiate graceful shutdown.
static void signalHandler(int signum) {
    (void)signum;
    shutdown_requested.store(true);
    gc_condition.notify_all();
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
// Returns Nil if allocation fails.
static HPointer allocateInt(GarbageCollector& gc, i64 value) {
    void* obj = gc.allocate(sizeof(ElmInt), Tag_Int);
    if (!obj) {
        return createNil();
    }

    ElmInt* elm_int = static_cast<ElmInt*>(obj);
    elm_int->value = value;
    return toPointer(obj);
}

// Allocates a Cons cell with an unboxed integer as its head.
// The integer value is stored directly in the cell rather than as a pointer.
// Returns Nil if allocation fails.
static HPointer allocateConsInt(GarbageCollector& gc, i64 value, HPointer tail) {
    void* obj = gc.allocate(sizeof(Cons), Tag_Cons);
    if (!obj) {
        return createNil();
    }

    Cons* cons = static_cast<Cons*>(obj);
    cons->header.unboxed = 1;  // Mark head as unboxed integer.
    cons->head.i = value;
    cons->tail = tail;
    return toPointer(obj);
}

// Creates a linked list of integers [0, 1, 2, ..., size-1].
// Builds the list in reverse order since cons prepends to the front.
static HPointer createIntList(GarbageCollector& gc, size_t size) {
    HPointer list = createNil();

    for (size_t i = size; i > 0; i--) {
        list = allocateConsInt(gc, static_cast<i64>(i - 1), list);
    }

    return list;
}

// Reverses a list by allocating new Cons cells.
// This is a pure functional reverse: the original list is unchanged.
//
// Implementation note: Local pointers must be registered as roots because
// gc.allocate() may trigger a minor GC, which could relocate objects.
// Without root registration, list_root and acc_root could become dangling.
static HPointer reverseList(GarbageCollector& gc, HPointer list) {
    HPointer acc = createNil();

    // Register locals as roots so GC can update them if collection occurs.
    HPointer list_root = list;
    HPointer acc_root = acc;
    gc.getRootSet().addRoot(&list_root);
    gc.getRootSet().addRoot(&acc_root);

    while (list_root.constant != Const_Nil) {
        void* obj = fromPointer(list_root);
        if (!obj) {
            break;
        }

        Cons* cons = static_cast<Cons*>(obj);

        // Copy head value before allocation. The allocation may trigger GC,
        // which could relocate 'cons', making the pointer invalid.
        u64 unboxed_flag = cons->header.unboxed;
        Unboxable head_copy = cons->head;

        // Advance to next element before allocation for the same reason.
        list_root = cons->tail;

        // Allocate new cons cell with head prepended to accumulator.
        void* new_obj = gc.allocate(sizeof(Cons), Tag_Cons);
        if (!new_obj) {
            break;
        }

        Cons* new_cons = static_cast<Cons*>(new_obj);
        new_cons->header.unboxed = unboxed_flag;
        new_cons->head = head_copy;
        new_cons->tail = acc_root;

        acc_root = toPointer(new_obj);
    }

    gc.getRootSet().removeRoot(&acc_root);
    gc.getRootSet().removeRoot(&list_root);

    return acc_root;
}

// Allocates a Record with the given number of fields, all initialized to Nil.
// Records are variable-size objects with a header followed by field values.
static HPointer allocateRecord(GarbageCollector& gc, size_t num_fields) {
    size_t size = sizeof(Record) + num_fields * sizeof(Unboxable);
    void* obj = gc.allocate(size, Tag_Record);
    if (!obj) {
        return createNil();
    }

    Record* record = static_cast<Record*>(obj);
    record->header.size = static_cast<u32>(num_fields);
    record->unboxed = 0;  // All fields are boxed (pointers), not unboxed values.

    for (size_t i = 0; i < num_fields; i++) {
        record->values[i].p = createNil();
    }

    return toPointer(obj);
}

// Creates a new Record with one field updated (functional update).
// Returns the original record if allocation fails.
//
// This implements Elm's record update syntax: { record | field = value }.
// A new record is allocated with all fields copied except the updated one.
static HPointer updateRecordField(GarbageCollector& gc, HPointer record_ptr,
                                   size_t field_index, HPointer new_value) {
    void* old_obj = fromPointer(record_ptr);
    if (!old_obj) {
        return createNil();
    }

    Record* old_record = static_cast<Record*>(old_obj);
    size_t num_fields = old_record->header.size;

    size_t size = sizeof(Record) + num_fields * sizeof(Unboxable);
    void* new_obj = gc.allocate(size, Tag_Record);
    if (!new_obj) {
        return record_ptr;  // Return original on allocation failure.
    }

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

    return toPointer(new_obj);
}

// ============================================================================
// Collector Thread
// ============================================================================

// Background thread that runs major GC when requested by the program thread.
// Waits on gc_condition for requests, with a 100ms timeout to check shutdown.
static void collectorThreadFunc() {
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

    std::cout << "[Collector] Stopped" << std::endl;
}

// Signals the collector thread to run a major GC.
// Called by the program thread when old generation exceeds the threshold.
static void requestMajorGC() {
    std::cout << "[Program] MajorGC Requested" << std::endl;
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
static void programThreadFunc() {
    auto& gc = GarbageCollector::instance();
    gc.initThread();

    std::cout << "[Program] Started with " << model_num_fields
              << " fields, list size " << list_size
              << ", major GC threshold " << (major_gc_threshold / (1024 * 1024)) << " MB"
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
        model = updateRecordField(gc, model, i, list);
    }

    size_t iterations = 0;

    // Main loop: repeatedly reverse a randomly-selected list.
    while (!shutdown_requested.load()) {
        // Select a field using probabilistic strategy: test each field with
        // probability P, falling back to the last field if none selected.
        // This creates variable allocation patterns across fields.
        size_t field_index = 0;
        bool field_selected = false;

        void* model_obj = fromPointer(model);
        if (!model_obj) {
            break;
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

        // Create new model with the reversed list in the selected field.
        // The old model remains reachable until we update the root.
        HPointer new_model = updateRecordField(gc, model, field_index, reversed);

        // Atomically switch roots from old model to new model.
        // This mirrors how a real Elm runtime manages roots explicitly.
        gc.getRootSet().removeRoot(&model);
        model = new_model;
        gc.getRootSet().addRoot(&model);

        iterations++;

        // Trigger minor GC when nursery is 90% full to avoid overflow.
        if (gc.isNurseryNearFull(0.9f)) {
            gc.minorGC();
        }

        // Request major GC when old generation exceeds threshold.
        size_t old_gen_bytes = gc.getOldGen().getAllocatedBytes();
        if (old_gen_bytes >= major_gc_threshold) {
            requestMajorGC();
        }

        // Yield periodically to let the collector thread run.
        if (iterations % 1000 == 0) {
            std::this_thread::yield();
        }
    }

    // Clean up: unregister model root before thread exits.
    gc.getRootSet().removeRoot(&model);

    std::cout << "[Program] Stopped after " << iterations << " iterations" << std::endl;
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
              << "  -t, --threshold <bytes> Major GC threshold in MB (default: 50)\n"
              << "  -p, --probability <p>   Probability of reversing each list (default: 0.5)\n"
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
        {"help",       no_argument,       nullptr, 'h'},
        {nullptr,      0,                 nullptr, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "d:f:l:t:p:h", long_options, nullptr)) != -1) {
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
                major_gc_threshold = std::stoul(optarg) * 1024 * 1024;  // Convert MB to bytes.
                if (major_gc_threshold < 1024 * 1024) {
                    std::cerr << "Error: threshold must be >= 1 MB\n";
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

    std::cout << "=== Eco Runtime for Elm ===" << std::endl;

    // Install signal handlers for graceful shutdown on Ctrl+C or kill.
    signal(SIGINT, signalHandler);
    signal(SIGTERM, signalHandler);

    // Initialize the garbage collector with a 2GB heap reservation.
    // The old generation can grow up to ~1GB within this space.
    auto& gc = GarbageCollector::instance();
    gc.initialize(2ULL * 1024 * 1024 * 1024);  // 2GB heap
    gc.initThread();  // Main thread needs GC access too.

    std::cout << "GC initialized (memory pressure threshold: "
              << (major_gc_threshold / (1024 * 1024)) << " MB)" << std::endl;

    // Start the collector and program threads.
    std::thread collector_thread(collectorThreadFunc);
    std::thread program_thread(programThreadFunc);

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

    // Wait for both threads to exit cleanly.
    program_thread.join();
    collector_thread.join();

    // Print combined GC statistics if enabled at compile time.
#if ENABLE_GC_STATS
    GCStats combined = gc.getCombinedNurseryStats();
    combined.combine(gc.getMajorGCStats());
    combined.print();
#endif

    std::cout << "\nGoodbye!" << std::endl;
    return 0;
}
