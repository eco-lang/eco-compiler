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

static std::atomic<bool> shutdown_requested{false};
static std::atomic<bool> gc_requested{false};
static std::mutex gc_mutex;
static std::condition_variable gc_condition;

// Configuration.
static size_t model_num_fields = 8;       // Number of fields in the model Record.
static size_t list_size = 500;            // Elements per list.
static std::chrono::seconds duration{0};  // 0 = run forever until Ctrl+C.

// ============================================================================
// Signal Handler
// ============================================================================

static void signalHandler(int signum) {
    (void)signum;
    shutdown_requested.store(true);
    gc_condition.notify_all();
}

// ============================================================================
// Helper Functions
// ============================================================================

// Creates an HPointer representing Nil.
static HPointer createNil() {
    HPointer ptr;
    ptr.ptr = 0;
    ptr.constant = Const_Nil;
    ptr.padding = 0;
    return ptr;
}

// Allocates an ElmInt with the given value.
static HPointer allocateInt(GarbageCollector& gc, i64 value) {
    void* obj = gc.allocate(sizeof(ElmInt), Tag_Int);
    if (!obj) return createNil();

    ElmInt* elm_int = static_cast<ElmInt*>(obj);
    elm_int->value = value;
    return toPointer(obj);
}

// Allocates a Cons cell with unboxed integer head.
static HPointer allocateConsInt(GarbageCollector& gc, i64 value, HPointer tail) {
    void* obj = gc.allocate(sizeof(Cons), Tag_Cons);
    if (!obj) return createNil();

    Cons* cons = static_cast<Cons*>(obj);
    cons->header.unboxed = 1;  // Head is unboxed integer.
    cons->head.i = value;
    cons->tail = tail;
    return toPointer(obj);
}

// Creates a list of integers [0, 1, 2, ..., size-1].
static HPointer createIntList(GarbageCollector& gc, size_t size) {
    HPointer list = createNil();

    // Build in reverse order since cons prepends.
    for (size_t i = size; i > 0; i--) {
        list = allocateConsInt(gc, static_cast<i64>(i - 1), list);
    }

    return list;
}

// Reverses a list (allocates new cons cells).
static HPointer reverseList(GarbageCollector& gc, HPointer list) {
    HPointer acc = createNil();

    // Register locals as roots so GC can update them if triggered.
    HPointer list_root = list;
    HPointer acc_root = acc;
    gc.getRootSet().addRoot(&list_root);
    gc.getRootSet().addRoot(&acc_root);

    while (list_root.constant != Const_Nil) {
        void* obj = fromPointer(list_root);
        if (!obj) break;

        Cons* cons = static_cast<Cons*>(obj);

        // Save head value before allocation (which might trigger GC).
        u64 unboxed_flag = cons->header.unboxed;
        Unboxable head_copy = cons->head;

        // Advance to next element before allocation.
        list_root = cons->tail;

        // Create new cons cell.
        void* new_obj = gc.allocate(sizeof(Cons), Tag_Cons);
        if (!new_obj) break;

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

// Allocates a Record with the given number of fields.
// All fields are initialized to Nil.
static HPointer allocateRecord(GarbageCollector& gc, size_t num_fields) {
    size_t size = sizeof(Record) + num_fields * sizeof(Unboxable);
    void* obj = gc.allocate(size, Tag_Record);
    if (!obj) return createNil();

    Record* record = static_cast<Record*>(obj);
    record->header.size = static_cast<u32>(num_fields);
    record->unboxed = 0;  // All fields are boxed (pointers).

    // Initialize all fields to Nil.
    for (size_t i = 0; i < num_fields; i++) {
        record->values[i].p = createNil();
    }

    return toPointer(obj);
}

// Creates a new Record with one field replaced.
static HPointer updateRecordField(GarbageCollector& gc, HPointer record_ptr,
                                   size_t field_index, HPointer new_value) {
    void* old_obj = fromPointer(record_ptr);
    if (!old_obj) return createNil();

    Record* old_record = static_cast<Record*>(old_obj);
    size_t num_fields = old_record->header.size;

    // Allocate new record.
    size_t size = sizeof(Record) + num_fields * sizeof(Unboxable);
    void* new_obj = gc.allocate(size, Tag_Record);
    if (!new_obj) return record_ptr;  // Return old on failure.

    Record* new_record = static_cast<Record*>(new_obj);
    new_record->header.size = static_cast<u32>(num_fields);
    new_record->unboxed = old_record->unboxed;

    // Copy all fields, replacing the specified one.
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

static void collectorThreadFunc() {
    auto& gc = GarbageCollector::instance();
    gc.initThread();

    std::cout << "[Collector] Started" << std::endl;

    while (!shutdown_requested.load()) {
        // Wait for GC request or timeout.
        {
            std::unique_lock<std::mutex> lock(gc_mutex);
            gc_condition.wait_for(lock, std::chrono::milliseconds(100), []() {
                return gc_requested.load() || shutdown_requested.load();
            });
        }

        if (shutdown_requested.load()) break;

        // Check if GC is needed.
        if (gc_requested.load()) {
            gc_requested.store(false);

            // Run major GC.
            gc.majorGC();
        }
    }

    std::cout << "[Collector] Stopped" << std::endl;
}

// Requests the collector thread to run a major GC.
static void requestMajorGC() {
    gc_requested.store(true);
    gc_condition.notify_one();
}

// ============================================================================
// Program Thread
// ============================================================================

static void programThreadFunc() {
    auto& gc = GarbageCollector::instance();
    gc.initThread();

    std::cout << "[Program] Started with " << model_num_fields
              << " fields, list size " << list_size << std::endl;

    // Random number generator for selecting fields.
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<size_t> field_dist(0, model_num_fields - 1);

    // Create initial model with lists in each field.
    HPointer model = allocateRecord(gc, model_num_fields);

    // Register model as root.
    gc.getRootSet().addRoot(&model);

    // Initialize each field with a list.
    for (size_t i = 0; i < model_num_fields; i++) {
        HPointer list = createIntList(gc, list_size);
        model = updateRecordField(gc, model, i, list);
    }

    size_t iterations = 0;
    size_t gc_trigger_interval = 100;  // Request GC every N iterations.

    while (!shutdown_requested.load()) {
        // Pick a random field to update.
        size_t field_index = field_dist(gen);

        // Get the current list from that field.
        void* model_obj = fromPointer(model);
        if (!model_obj) break;

        Record* record = static_cast<Record*>(model_obj);
        HPointer current_list = record->values[field_index].p;

        // Reverse the list (creates new cons cells).
        HPointer reversed = reverseList(gc, current_list);

        // Create new model with updated field.
        // Note: model is still a root, so old model stays alive until we update.
        HPointer new_model = updateRecordField(gc, model, field_index, reversed);

        // Update root to point to new model.
        // Old model (and unreferenced lists) become garbage.
        model = new_model;

        iterations++;

        // Trigger minor GC occasionally.
        if (iterations % 10 == 0) {
            gc.minorGC();
        }

        // Request major GC periodically.
        if (iterations % gc_trigger_interval == 0) {
            requestMajorGC();
        }

        // Brief yield to allow collector thread to run.
        if (iterations % 1000 == 0) {
            std::this_thread::yield();
        }
    }

    // Unregister root before exit.
    gc.getRootSet().removeRoot(&model);

    std::cout << "[Program] Stopped after " << iterations << " iterations" << std::endl;
}

// ============================================================================
// Command Line Parsing
// ============================================================================

static void printUsage(const char* prog) {
    std::cout << "Usage: " << prog << " [options]\n"
              << "\n"
              << "Options:\n"
              << "  -d, --duration <time>   Run for specified duration (e.g., 30s, 5m, 1h)\n"
              << "  -f, --fields <n>        Number of fields in model record (default: 8)\n"
              << "  -l, --list-size <n>     Size of each list (default: 500)\n"
              << "  -h, --help              Show this help message\n"
              << "\n"
              << "Press Ctrl+C to stop.\n";
}

static std::optional<std::chrono::seconds> parseDuration(const std::string& str) {
    if (str.empty()) return std::nullopt;

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

static bool parseArgs(int argc, char* argv[]) {
    static struct option long_options[] = {
        {"duration",   required_argument, nullptr, 'd'},
        {"fields",     required_argument, nullptr, 'f'},
        {"list-size",  required_argument, nullptr, 'l'},
        {"help",       no_argument,       nullptr, 'h'},
        {nullptr,      0,                 nullptr, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "d:f:l:h", long_options, nullptr)) != -1) {
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

int main(int argc, char* argv[]) {
    if (!parseArgs(argc, argv)) {
        printUsage(argv[0]);
        return 1;
    }

    std::cout << "=== Eco Runtime for Elm ===" << std::endl;

    // Install signal handler.
    signal(SIGINT, signalHandler);
    signal(SIGTERM, signalHandler);

    // Initialize GC.
    auto& gc = GarbageCollector::instance();
    gc.initialize();
    gc.initThread();  // Main thread needs GC access too.

    std::cout << "GC initialized" << std::endl;

    // Start threads.
    std::thread collector_thread(collectorThreadFunc);
    std::thread program_thread(programThreadFunc);

    // Wait for duration or Ctrl+C.
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

    std::cout << "Waiting for threads to finish..." << std::endl;

    // Join threads.
    program_thread.join();
    collector_thread.join();

    // Print GC stats.
#if ENABLE_GC_STATS
    // Combine stats from all nurseries and major GC.
    GCStats combined = gc.getCombinedNurseryStats();
    combined.combine(gc.getMajorGCStats());
    combined.print();
#endif

    std::cout << "\nGoodbye!" << std::endl;
    return 0;
}
