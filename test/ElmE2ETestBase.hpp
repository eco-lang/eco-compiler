#pragma once

#include "CheckPatterns.hpp"
#include "ChildStdin.hpp"
#include "TestPort.hpp"
#include "NodeBigStack.hpp"
#include "RegionNurseryGuard.hpp"
#include "IsolatedTestRunner.hpp"
#include "TestSuite.hpp"
#include "../runtime/src/codegen/EcoRunner.hpp"
#include "../runtime/src/allocator/GCStats.hpp"
#include "../runtime/src/allocator/Allocator.hpp"
#include "../runtime/src/allocator/RuntimeExports.h"
#include "../runtime/src/platform/PlatformRuntime.hpp"
#include "../runtime/src/platform/PortRuntime.hpp"

#include <algorithm>
#include <array>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <future>
#include <iomanip>
#include <iostream>
#include <memory>
#include <optional>
#include <regex>
#include <chrono>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#if !defined(_WIN32)
#include <sys/mman.h>
#include <unistd.h>
#endif

namespace ElmE2EBase {

// Test-harness flags for stress-elm programs (`Program StressFlags ...`).
// Serialized to JSON and decoded by the program's compiler-generated flags
// decoder — PlatformRuntime has no knowledge of this shape (Phase 5,
// plans/native-ports-and-embedding.md).
struct StressFlags {
    int64_t numLoops = 0;
    int64_t maxSize = 0;
    int64_t timeoutMs = 0;
    int64_t seed = 0;
    int64_t startMs = 0;
    bool    verbose = false;

    std::string toJson() const {
        char buf[256];
        std::snprintf(buf, sizeof(buf),
                      "{\"maxSize\":%lld,\"numLoops\":%lld,\"seed\":%lld,"
                      "\"startMs\":%lld,\"timeoutMs\":%lld,\"verbose\":%s}",
                      static_cast<long long>(maxSize),
                      static_cast<long long>(numLoops),
                      static_cast<long long>(seed),
                      static_cast<long long>(startMs),
                      static_cast<long long>(timeoutMs),
                      verbose ? "true" : "false");
        return std::string(buf);
    }
};

// ============================================================================
// Parallel Compilation Constants
// ============================================================================

inline size_t getMaxParallelCompilations() {
    unsigned int cores = std::thread::hardware_concurrency();
    return cores > 0 ? static_cast<size_t>(cores) : 4;
}

// ============================================================================
// Elm-Specific Shared Memory Extension
// ============================================================================

struct ElmSharedTestResult {
    bool completed;
    bool passed;
    char error[4096];
    char output[8192];

    // checkProcessOutput suites only (plans/eco-system-library.md Phase 1
    // step 8b). Written by the child when the Elm program ends, either
    // normally (eco_main returned; code = eco_get_exit_code()) or through
    // std::exit (atexit hook; the parent's WEXITSTATUS is authoritative).
    // `output` then holds the program's eco-thread output (Debug.log etc.).
    bool programExited;
    int  programExitCode;
    bool outputTruncated;

    uint64_t objects_allocated;
    uint64_t bytes_allocated;
    uint64_t minor_gc_count;
    uint64_t objects_survived;
    uint64_t objects_promoted;
    uint64_t bytes_freed;
    uint64_t total_minor_gc_time_ns;
    uint64_t min_minor_gc_time_ns;
    uint64_t max_minor_gc_time_ns;
    uint64_t minor_time_histogram[Elm::GCStats::HISTOGRAM_BUCKETS];
    uint64_t major_gc_count;
    uint64_t total_major_gc_time_ns;
    uint64_t min_major_gc_time_ns;
    uint64_t max_major_gc_time_ns;
    uint64_t major_time_histogram[Elm::GCStats::HISTOGRAM_BUCKETS];
    uint64_t buffers_allocated;
    uint64_t buffers_filled;
    uint64_t concurrent_marks_started;
    uint64_t mark_sweeps_completed;
    uint64_t incremental_mark_calls;
    uint64_t total_incremental_mark_work_units;
    uint64_t nursery_alloc_size_histogram[Elm::GCStats::NURSERY_ALLOC_BUCKETS];
    uint64_t oldgen_alloc_size_histogram[Elm::GCStats::OLDGEN_ALLOC_BUCKETS];

    // Old-gen page residency histogram. Cumulative across every major-GC
    // end snapshot in the child process; the parent merges it into the
    // run-wide accumulator so the final printout shows residency totals
    // for the entire test run. The garbage/free byte arrays carry the
    // four-way breakdown (live / free / garbage / unallocated-tail)
    // sampled before transitionToSweeping clears free lists.
    uint64_t residency_pages[Elm::GCStats::RESIDENCY_BUCKETS];
    uint64_t residency_page_bytes[Elm::GCStats::RESIDENCY_BUCKETS];
    uint64_t residency_live_bytes[Elm::GCStats::RESIDENCY_BUCKETS];
    uint64_t residency_garbage_bytes[Elm::GCStats::RESIDENCY_BUCKETS];
    uint64_t residency_free_bytes[Elm::GCStats::RESIDENCY_BUCKETS];
    uint64_t residency_pinned_pages;
    uint64_t residency_pinned_page_bytes;
    uint64_t residency_pinned_live_bytes;
    uint64_t residency_pinned_garbage_bytes;
    uint64_t residency_pinned_free_bytes;
    uint64_t residency_snapshots;
    Elm::IncrMarkStats im;   // threaded-gc-05a (POD)
    Elm::ParMarkStats pm;    // threaded-gc-05b (POD)
    Elm::ConcMarkStats cm;   // threaded-gc-05c (POD)
    Elm::ParMinorStats pmin; // threaded-gc-06 (POD)
    Elm::RegionTenureCounters rg;   // threaded-gc-07 (POD)

    // Free-list size-class histogram. Cells parked on each per-class
    // free list at major-GC end, plus the aggregate `free_large_blocks_`
    // count/bytes; the parent merges these so the printout shows the
    // shape of unused old-gen bytes across the whole run.
    uint64_t freelist_cells_by_class[Elm::GCStats::FREELIST_CLASS_BUCKETS];
    uint64_t freelist_bytes_by_class[Elm::GCStats::FREELIST_CLASS_BUCKETS];
    uint64_t freelist_large_block_count;
    uint64_t freelist_large_block_bytes;
    uint64_t freelist_snapshots;
};

inline Elm::GCStats& getAccumulatedStats() {
    static Elm::GCStats accumulated;
    return accumulated;
}

inline void copyStatsToShared(ElmSharedTestResult* shared) {
#if ENABLE_GC_STATS
    Elm::GCStats stats = Elm::Allocator::instance().getCombinedStats();
    shared->objects_allocated = stats.objects_allocated;
    shared->bytes_allocated = stats.bytes_allocated;
    shared->minor_gc_count = stats.minor_gc_count;
    shared->objects_survived = stats.objects_survived;
    shared->objects_promoted = stats.objects_promoted;
    shared->bytes_freed = stats.bytes_freed;
    shared->total_minor_gc_time_ns = stats.total_minor_gc_time_ns;
    shared->min_minor_gc_time_ns = stats.min_minor_gc_time_ns;
    shared->max_minor_gc_time_ns = stats.max_minor_gc_time_ns;
    for (int i = 0; i < Elm::GCStats::HISTOGRAM_BUCKETS; i++) {
        shared->minor_time_histogram[i] = stats.minor_time_histogram[i];
    }
    shared->major_gc_count = stats.major_gc_count;
    shared->total_major_gc_time_ns = stats.total_major_gc_time_ns;
    shared->min_major_gc_time_ns = stats.min_major_gc_time_ns;
    shared->max_major_gc_time_ns = stats.max_major_gc_time_ns;
    for (int i = 0; i < Elm::GCStats::HISTOGRAM_BUCKETS; i++) {
        shared->major_time_histogram[i] = stats.major_time_histogram[i];
    }
    shared->buffers_allocated = stats.buffers_allocated;
    shared->buffers_filled = stats.buffers_filled;
    shared->concurrent_marks_started = stats.concurrent_marks_started;
    shared->mark_sweeps_completed = stats.mark_sweeps_completed;
    shared->incremental_mark_calls = stats.incremental_mark_calls;
    shared->total_incremental_mark_work_units = stats.total_incremental_mark_work_units;
    for (int i = 0; i < Elm::GCStats::NURSERY_ALLOC_BUCKETS; i++) {
        shared->nursery_alloc_size_histogram[i] = stats.nursery_alloc_size_histogram[i];
    }
    for (int i = 0; i < Elm::GCStats::OLDGEN_ALLOC_BUCKETS; i++) {
        shared->oldgen_alloc_size_histogram[i] = stats.oldgen_alloc_size_histogram[i];
    }
    for (int i = 0; i < Elm::GCStats::RESIDENCY_BUCKETS; i++) {
        shared->residency_pages[i]         = stats.residency_pages[i];
        shared->residency_page_bytes[i]    = stats.residency_page_bytes[i];
        shared->residency_live_bytes[i]    = stats.residency_live_bytes[i];
        shared->residency_garbage_bytes[i] = stats.residency_garbage_bytes[i];
        shared->residency_free_bytes[i]    = stats.residency_free_bytes[i];
    }
    shared->residency_pinned_pages         = stats.residency_pinned_pages;
    shared->residency_pinned_page_bytes    = stats.residency_pinned_page_bytes;
    shared->residency_pinned_live_bytes    = stats.residency_pinned_live_bytes;
    shared->residency_pinned_garbage_bytes = stats.residency_pinned_garbage_bytes;
    shared->residency_pinned_free_bytes    = stats.residency_pinned_free_bytes;
    shared->residency_snapshots            = stats.residency_snapshots;
    shared->im                             = stats.im;
    shared->pm                             = stats.pm;
    shared->cm                             = stats.cm;
    shared->pmin                           = stats.pmin;
    shared->rg                             = static_cast<const Elm::RegionTenureCounters&>(stats.rg);
    for (int i = 0; i < Elm::GCStats::FREELIST_CLASS_BUCKETS; i++) {
        shared->freelist_cells_by_class[i] = stats.freelist_cells_by_class[i];
        shared->freelist_bytes_by_class[i] = stats.freelist_bytes_by_class[i];
    }
    shared->freelist_large_block_count = stats.freelist_large_block_count;
    shared->freelist_large_block_bytes = stats.freelist_large_block_bytes;
    shared->freelist_snapshots         = stats.freelist_snapshots;
#endif
}

inline void accumulateFromShared(const ElmSharedTestResult* shared) {
    Elm::GCStats childStats;
    childStats.objects_allocated = shared->objects_allocated;
    childStats.bytes_allocated = shared->bytes_allocated;
    childStats.minor_gc_count = shared->minor_gc_count;
    childStats.objects_survived = shared->objects_survived;
    childStats.objects_promoted = shared->objects_promoted;
    childStats.bytes_freed = shared->bytes_freed;
    childStats.total_minor_gc_time_ns = shared->total_minor_gc_time_ns;
    childStats.min_minor_gc_time_ns = shared->min_minor_gc_time_ns;
    childStats.max_minor_gc_time_ns = shared->max_minor_gc_time_ns;
    for (int i = 0; i < Elm::GCStats::HISTOGRAM_BUCKETS; i++) {
        childStats.minor_time_histogram[i] = shared->minor_time_histogram[i];
    }
    childStats.major_gc_count = shared->major_gc_count;
    childStats.total_major_gc_time_ns = shared->total_major_gc_time_ns;
    childStats.min_major_gc_time_ns = shared->min_major_gc_time_ns;
    childStats.max_major_gc_time_ns = shared->max_major_gc_time_ns;
    for (int i = 0; i < Elm::GCStats::HISTOGRAM_BUCKETS; i++) {
        childStats.major_time_histogram[i] = shared->major_time_histogram[i];
    }
    childStats.buffers_allocated = shared->buffers_allocated;
    childStats.buffers_filled = shared->buffers_filled;
    childStats.concurrent_marks_started = shared->concurrent_marks_started;
    childStats.mark_sweeps_completed = shared->mark_sweeps_completed;
    childStats.incremental_mark_calls = shared->incremental_mark_calls;
    childStats.total_incremental_mark_work_units = shared->total_incremental_mark_work_units;
    for (int i = 0; i < Elm::GCStats::NURSERY_ALLOC_BUCKETS; i++) {
        childStats.nursery_alloc_size_histogram[i] = shared->nursery_alloc_size_histogram[i];
    }
    for (int i = 0; i < Elm::GCStats::OLDGEN_ALLOC_BUCKETS; i++) {
        childStats.oldgen_alloc_size_histogram[i] = shared->oldgen_alloc_size_histogram[i];
    }
    for (int i = 0; i < Elm::GCStats::RESIDENCY_BUCKETS; i++) {
        childStats.residency_pages[i]         = shared->residency_pages[i];
        childStats.residency_page_bytes[i]    = shared->residency_page_bytes[i];
        childStats.residency_live_bytes[i]    = shared->residency_live_bytes[i];
        childStats.residency_garbage_bytes[i] = shared->residency_garbage_bytes[i];
        childStats.residency_free_bytes[i]    = shared->residency_free_bytes[i];
    }
    childStats.residency_pinned_pages         = shared->residency_pinned_pages;
    childStats.residency_pinned_page_bytes    = shared->residency_pinned_page_bytes;
    childStats.residency_pinned_live_bytes    = shared->residency_pinned_live_bytes;
    childStats.residency_pinned_garbage_bytes = shared->residency_pinned_garbage_bytes;
    childStats.residency_pinned_free_bytes    = shared->residency_pinned_free_bytes;
    childStats.residency_snapshots            = shared->residency_snapshots;
    childStats.im                             = shared->im;
    childStats.pm                             = shared->pm;
    childStats.cm                             = shared->cm;
    childStats.pmin                           = shared->pmin;
    static_cast<Elm::RegionTenureCounters&>(childStats.rg) = shared->rg;
    for (int i = 0; i < Elm::GCStats::FREELIST_CLASS_BUCKETS; i++) {
        childStats.freelist_cells_by_class[i] = shared->freelist_cells_by_class[i];
        childStats.freelist_bytes_by_class[i] = shared->freelist_bytes_by_class[i];
    }
    childStats.freelist_large_block_count = shared->freelist_large_block_count;
    childStats.freelist_large_block_bytes = shared->freelist_large_block_bytes;
    childStats.freelist_snapshots         = shared->freelist_snapshots;

    getAccumulatedStats().combine(childStats);
}

// ============================================================================
// Helper Functions
// ============================================================================

inline std::pair<int, std::string> executeCommand(const std::string& cmd) {
    std::array<char, 4096> buffer;
    std::string result;

#if defined(_WIN32)
#  define _eco_popen  ::_popen
#  define _eco_pclose ::_pclose
#else
#  define _eco_popen  ::popen
#  define _eco_pclose ::pclose
#endif

    std::string fullCmd = cmd + " 2>&1";
    std::unique_ptr<FILE, decltype(&_eco_pclose)> pipe(_eco_popen(fullCmd.c_str(), "r"), _eco_pclose);

    if (!pipe) {
        throw std::runtime_error("popen() failed for command: " + cmd);
    }

    while (fgets(buffer.data(), buffer.size(), pipe.get()) != nullptr) {
        result += buffer.data();
    }

    int status = _eco_pclose(pipe.release());
#if defined(_WIN32)
    int exitCode = status;
#else
    int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
#endif
#undef _eco_popen
#undef _eco_pclose

    return {exitCode, result};
}

inline std::string readFile(const std::string& path) {
    std::ifstream file(path);
    if (!file.is_open()) {
        throw std::runtime_error("Cannot open file: " + path);
    }
    std::stringstream buffer;
    buffer << file.rdbuf();
    return buffer.str();
}

inline void printCompilerDiagnostics(const std::string& output) {
    std::istringstream stream(output);
    std::string line;
    while (std::getline(stream, line)) {
        if (line.rfind("Registry:", 0) == 0) {
            std::cout << "  " << line << std::endl;
        }
    }
}

// Gate A runs the JIT E2E suite through Stage 1's guida XHR compiler:
// `compiler/bin/index.js` wraps `guida.js` (the stock-Elm-compiled
// eco compiler) with `mock-xmlhttprequest` + `eco-io-handler.js` for IO.
// This avoids the Stage 2 kernel-IO code paths (which depend on adm-zip
// and other npm modules that don't resolve from the build tree).
inline std::string getGuidaPath() {
    std::vector<std::string> candidates = {
        "compiler/bin/index.js",
        "../compiler/bin/index.js",
        "../../compiler/bin/index.js",
    };

    for (const auto& path : candidates) {
        if (std::filesystem::exists(path)) {
            return std::filesystem::absolute(path).string();
        }
    }

    return "/work/compiler/bin/index.js";
}

inline std::string extractExpectedOutput(const std::string& content) {
    std::regex pattern(R"(Expected output:\s*\"([^\"]+)\")");
    std::smatch match;
    if (std::regex_search(content, match, pattern)) {
        return match[1].str();
    }
    return "";
}

// CHECK / CHECK-NOT machinery lives in /work/test/CheckPatterns.hpp.
// Elm uses `--` as the line-comment marker, so directives are
// `-- CHECK:` and `-- CHECK-NOT:` — the shared `extractCheckPatterns`
// is parameterised on the prefix strings to handle this.
using eco_test::CheckPattern;
using eco_test::trimCheckPattern;
using eco_test::patternMatches;
using eco_test::verifyPatterns;

inline std::vector<CheckPattern> extractCheckPatterns(const std::string& content) {
    return eco_test::extractCheckPatterns(content,
                                           "-- CHECK:",
                                           "-- CHECK-NOT:");
}

// `-- CHECK-MLIR:` / `-- CHECK-MLIR-NOT:` directives assert patterns
// against the textual MLIR produced by the compiler for the test's
// `.elm` source. Used by the bytes-fusion smoke tests to prove that
// specific `bf.*` / `scf.while` ops appear in the lowered MLIR — these
// are otherwise invisible to a JIT-output `-- CHECK:` directive
// because both the fused and the fall-back kernel path produce the
// same observable program output.
inline std::vector<CheckPattern> extractCheckMlirPatterns(const std::string& content) {
    return eco_test::extractCheckPatterns(content,
                                           "-- CHECK-MLIR:",
                                           "-- CHECK-MLIR-NOT:");
}

// Locate the `ecoc` MLIR-text dumper. The CHECK-MLIR machinery uses
// it to re-render the (bytecode) `.mlir` file as text so substring /
// regex CHECK directives can match. Mirrors `getGuidaPath`'s search
// strategy so the test binary works from any reasonable CWD inside
// the build tree.
inline std::string getEcocPath() {
    std::vector<std::string> candidates = {
        "runtime/src/codegen/ecoc",
        "../runtime/src/codegen/ecoc",
        "../../runtime/src/codegen/ecoc",
#ifdef BUILD_DIR
        std::string(BUILD_DIR) + "/runtime/src/codegen/ecoc",
#endif
    };

    for (const auto& path : candidates) {
        if (std::filesystem::exists(path)) {
            return std::filesystem::absolute(path).string();
        }
    }

    // Last-resort fallback: BUILD_DIR is a compile-time constant pointing at
    // CMAKE_BINARY_DIR. If the binary somehow got moved we still return a
    // best-effort absolute path so the error message is informative.
#ifdef BUILD_DIR
    return std::string(BUILD_DIR) + "/runtime/src/codegen/ecoc";
#else
    return "runtime/src/codegen/ecoc";
#endif
}

// Read the compiled `.mlir` (bytecode or text) back as a single text
// string for CHECK-MLIR matching. Bytecode is the default emit form,
// so we always pipe through `ecoc --emit=mlir` — text input is
// idempotent under that pass.
inline std::string readMlirAsText(const std::string& mlirPath) {
    std::string ecoc = getEcocPath();
    std::string cmd = "\"" + ecoc + "\" --emit=mlir \"" + mlirPath + "\"";
    auto [exitCode, output] = executeCommand(cmd);
    if (exitCode != 0) {
        throw std::runtime_error(
            "ecoc --emit=mlir failed for " + mlirPath +
            " (exit " + std::to_string(exitCode) + "): " + output.substr(0, 400));
    }
    return output;
}

// ============================================================================
// Parameterized Two-Phase Compilation
// ============================================================================

struct CompileResult {
    std::string elmPath;
    std::string mlirPath;
    bool success;
    std::string errorMessage;
};

inline bool needsRecompile(const std::string& elmPath, const std::string& mlirPath) {
    if (!std::filesystem::exists(mlirPath)) {
        return true;
    }
    auto elmTime = std::filesystem::last_write_time(elmPath);
    auto mlirTime = std::filesystem::last_write_time(mlirPath);
    return elmTime > mlirTime;
}

inline std::string getMlirPath(const std::string& testDir, const std::string& elmPath) {
    std::string filename = std::filesystem::path(elmPath).stem().string();
    return testDir + "/eco-stuff/mlir/" + filename + ".mlir";
}

inline void ensureMlirDirExists(const std::string& testDir) {
    std::string mlirDir = testDir + "/eco-stuff/mlir";
    std::filesystem::create_directories(mlirDir);
}

inline CompileResult compileElmToMlir(const std::string& testDir, const std::string& elmPath, const std::string& buildDir = "", const std::string& extraFlags = "") {
    CompileResult result;
    result.elmPath = elmPath;
    result.mlirPath = getMlirPath(testDir, elmPath);
    result.success = false;

    if (!needsRecompile(elmPath, result.mlirPath)) {
        result.success = true;
        return result;
    }

    std::string guidaPath = getGuidaPath();

    // Big stack (NodeBigStack.hpp): the Stage-1 JS compiler recurses deeply on very wide
    // programs and otherwise overflows, writing a truncated .mlir while still exiting 0.
    std::string compileCmd = "cd \"" + testDir + "\" && sh -c '" + kNodeBigStackScript + "' sh \"" + guidaPath +
                             "\" make \"" + elmPath + "\" --output=\"" + result.mlirPath + "\"" + getTextMlirFlag();
    if (!buildDir.empty()) {
        compileCmd += " --builddir=\"" + buildDir + "\"";
    }
    if (!extraFlags.empty()) {
        compileCmd += extraFlags;
    }

    auto [exitCode, output] = executeCommand(compileCmd);
    printCompilerDiagnostics(output);

    if (exitCode != 0) {
        std::filesystem::remove(result.mlirPath);

        std::ostringstream msg;
        msg << "Guida compilation failed (exit code " << exitCode << ")\n";
        msg << "Command: " << compileCmd << "\n";
        msg << "Output:\n" << output.substr(0, 1000);
        result.errorMessage = msg.str();
        return result;
    }

    if (!std::filesystem::exists(result.mlirPath)) {
        std::ostringstream msg;
        msg << "MLIR file not generated: " << result.mlirPath << "\n";
        msg << "Compiler output:\n" << output;
        result.errorMessage = msg.str();
        return result;
    }

    result.success = true;
    return result;
}

inline std::vector<CompileResult> compileAllElmTests(const std::string& testDir,
                                                       const std::string& suiteName,
                                                       const std::vector<std::string>& elmPaths,
                                                       const std::string& extraFlags = "") {
    std::vector<CompileResult> results;
    results.resize(elmPaths.size());

    ensureMlirDirExists(testDir);

    size_t total = elmPaths.size();
    size_t compiled = 0;
    size_t skipped = 0;
    size_t failed = 0;

    std::cout << "Compiling " << total << " " << suiteName << " tests (parallel with --builddir)..." << std::endl;

    std::vector<size_t> needsCompile;
    for (size_t i = 0; i < elmPaths.size(); i++) {
        const auto& elmPath = elmPaths[i];
        std::string mlirPath = getMlirPath(testDir, elmPath);

        if (!needsRecompile(elmPath, mlirPath)) {
            skipped++;
            CompileResult result;
            result.elmPath = elmPath;
            result.mlirPath = mlirPath;
            result.success = true;
            results[i] = result;
        } else {
            needsCompile.push_back(i);
        }
    }

    if (needsCompile.empty()) {
        std::cout << "  All " << skipped << " tests cached, nothing to compile" << std::endl;
        return results;
    }

    std::cout << "  " << skipped << " cached, " << needsCompile.size() << " to compile" << std::endl;

    if (!needsCompile.empty()) {
        size_t firstIdx = needsCompile[0];
        const auto& firstPath = elmPaths[firstIdx];
        std::string filename = std::filesystem::path(firstPath).stem().string();

        std::cout << "  [1/" << needsCompile.size() << "] " << filename << " (initial)" << std::flush;
        auto result = compileElmToMlir(testDir, firstPath, filename, extraFlags);
        results[firstIdx] = result;

        if (result.success) {
            std::cout << " ok" << std::endl;
            compiled++;
        } else {
            std::cout << " FAILED" << std::endl;
            failed++;
        }
    }

    if (needsCompile.size() > 1) {
        std::cout << "  Compiling remaining " << (needsCompile.size() - 1)
                  << " tests (max " << getMaxParallelCompilations() << " parallel)..." << std::endl;

        struct ActiveCompile {
            std::future<CompileResult> future;
            size_t resultIdx;
            std::string filename;
        };
        std::vector<ActiveCompile> active;

        size_t nextToStart = 1;
        size_t progressCount = 2;

        auto startNext = [&]() {
            if (nextToStart < needsCompile.size()) {
                size_t idx = needsCompile[nextToStart];
                const auto& elmPath = elmPaths[idx];
                std::string filename = std::filesystem::path(elmPath).stem().string();
                std::string td = testDir;
                std::string ef = extraFlags;

                active.push_back({
                    std::async(std::launch::async, [td, elmPath, filename, ef]() {
                        return compileElmToMlir(td, elmPath, filename, ef);
                    }),
                    idx,
                    filename
                });
                nextToStart++;
            }
        };

        while (active.size() < getMaxParallelCompilations() && nextToStart < needsCompile.size()) {
            startNext();
        }

        while (!active.empty()) {
            size_t completedIdx = 0;
            while (true) {
                for (size_t i = 0; i < active.size(); i++) {
                    if (active[i].future.wait_for(std::chrono::milliseconds(0)) == std::future_status::ready) {
                        completedIdx = i;
                        goto found;
                    }
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            }
            found:

            auto& done = active[completedIdx];
            auto result = done.future.get();
            results[done.resultIdx] = result;

            std::cout << "  [" << progressCount << "/" << needsCompile.size() << "] " << done.filename;
            if (result.success) {
                std::cout << " ok" << std::endl;
                compiled++;
            } else {
                std::cout << " FAILED" << std::endl;
                failed++;
            }
            progressCount++;

            active.erase(active.begin() + completedIdx);
            startNext();
        }
    }

    std::cout << "Compilation complete: " << compiled << " compiled, "
              << skipped << " cached, " << failed << " failed" << std::endl;

    return results;
}

// ============================================================================
// EcoRunner-based Test Execution
// ============================================================================

inline eco::EcoRunner& getRunner() {
    static thread_local eco::EcoRunner runner;
    return runner;
}

// Generic port-bounce for E2E port tests: payloads sent through the
// outgoing `echoOut` port are fed straight back into the incoming
// `echoIn` port (eco_port_send queues; the scheduler drains on the eco
// thread). Subscribing to a port that a given test never declares is
// harmless — the subscription sits on a placeholder registry entry.
inline void portEchoBounce(const char* json, void* /*user*/) {
    eco_port_send("echoIn", json);
}

inline void installPortEchoBounce() {
    static bool installed = false;
    if (!installed) {
        installed = true;
        eco_port_subscribe("echoOut", portEchoBounce, nullptr);
    }
}

// Extract a `-- FLAGS: {...}` directive from a test's Elm source: the JSON
// passed to the program's flags decoder for this run.
inline std::string extractFlagsDirective(const std::string& elmContent) {
    // The marker must start a line so prose mentioning the directive
    // (e.g. in a module doc comment) is not picked up.
    const std::string marker = "-- FLAGS:";
    size_t pos = 0;
    while (true) {
        pos = elmContent.find(marker, pos);
        if (pos == std::string::npos) return std::string();
        if (pos == 0 || elmContent[pos - 1] == '\n') break;
        pos += marker.size();
    }
    size_t start = pos + marker.size();
    size_t end = elmContent.find('\n', start);
    if (end == std::string::npos) end = elmContent.size();
    std::string json = elmContent.substr(start, end - start);
    // trim
    size_t b = json.find_first_not_of(" \t\r");
    size_t e = json.find_last_not_of(" \t\r");
    if (b == std::string::npos) return std::string();
    return json.substr(b, e - b + 1);
}

inline void runElmTestFromMlir(const std::string& mlirPath,
                               const std::string& elmPath,
                               const std::optional<ElmE2EBase::StressFlags>& flags = std::nullopt) {
    std::string elmContent = readFile(elmPath);
    auto checkPatterns = extractCheckPatterns(elmContent);
    auto checkMlirPatterns = extractCheckMlirPatterns(elmContent);
    std::string expectedOutput = extractExpectedOutput(elmContent);

    if (checkPatterns.empty() && !expectedOutput.empty()) {
        // Synthesise a positive CHECK from the legacy `expected output`
        // block so `verifyPatterns` can consume it uniformly.
        checkPatterns.push_back({expectedOutput, /*negated=*/false});
    }

    if (!std::filesystem::exists(mlirPath)) {
        throw std::runtime_error("MLIR file not found: " + mlirPath +
                                 " (should have been compiled in Phase 1)");
    }

    // CHECK-MLIR runs before JIT execution so an MLIR-shape regression
    // surfaces with a precise diagnostic instead of being lost behind
    // a runtime crash or a wrong-output failure.
    if (!checkMlirPatterns.empty()) {
        std::string mlirText = readMlirAsText(mlirPath);
        std::string error = verifyPatterns(mlirText, checkMlirPatterns);
        if (!error.empty()) {
            std::ostringstream msg;
            msg << "MLIR-shape check failed: " << error << "\n";
            msg << "MLIR file: " << mlirPath;
            throw std::runtime_error(msg.str());
        }
    }

    auto& runner = getRunner();
    runner.reset();
    eco_test::requireRegionNursery();

    // Flags reach the program as arbitrary JSON decoded by its
    // compiler-generated flags decoder (Phase 5). Sources, in priority
    // order: a `-- FLAGS: {...}` directive in the test source, then the
    // suite-level stress flags, else none.
    auto& platform = Elm::Platform::PlatformRuntime::instance();
    std::string flagsDirective = extractFlagsDirective(elmContent);
    if (!flagsDirective.empty()) {
        platform.setPendingFlagsJson(flagsDirective);
    } else if (flags.has_value()) {
        platform.setPendingFlagsJson(flags->toJson());
    } else {
        platform.clearPendingFlagsJson();
    }

    // Wire the generic echo bounce for port E2E tests (echoOut -> echoIn).
    installPortEchoBounce();

    auto result = runner.runFile(mlirPath);

    if (!result.success) {
        std::ostringstream msg;
        msg << "JIT execution failed: " << result.errorMessage << "\n";
        msg << "Output:\n" << result.output.substr(0, 500);
        throw std::runtime_error(msg.str());
    }

    if (!checkPatterns.empty()) {
        std::string error = verifyPatterns(result.output, checkPatterns);
        if (!error.empty()) {
            std::ostringstream msg;
            msg << error << "\n";
            msg << "Actual output:\n" << result.output.substr(0, 500);
            if (result.output.length() > 500) {
                msg << "\n... (truncated)";
            }
            throw std::runtime_error(msg.str());
        }
    }
}

// ============================================================================
// Process-output mode (checkProcessOutput suites, Phase 1 step 8b)
// ============================================================================
//
// The child does not verify CHECK patterns. It records the program's
// eco-thread output and exit into the shared block (both at a normal end and,
// through an atexit hook, when the program calls std::exit), and the parent
// verifies CHECK / CHECK-NOT / EXIT against shared->output + the fork-pipe
// text (raw fd 1/2 writes) after waitpid.

namespace detail {

struct ProcessOutputState {
    ElmSharedTestResult* shared = nullptr;
    // Leaked on purpose: std::exit destroys thread_locals (the runner's own
    // capture buffer included) before atexit handlers run.
    std::ostringstream* stream = nullptr;
};

inline ProcessOutputState& processOutputState() {
    static ProcessOutputState* st = new ProcessOutputState();
    return *st;
}

inline void publishProcessOutput(int exitCode) {
    auto& st = processOutputState();
    if (!st.shared || st.shared->programExited) return;
    std::string out = st.stream ? st.stream->str() : std::string();
    const size_t cap = sizeof(st.shared->output) - 1;
    if (out.size() > cap) {
        st.shared->outputTruncated = true;
        out.resize(cap);
    }
    std::memcpy(st.shared->output, out.data(), out.size());
    st.shared->output[out.size()] = '\0';
    st.shared->programExitCode = exitCode;
    st.shared->programExited = true;
}

inline void processOutputAtExit() {
    std::cout.flush();
    std::cerr.flush();
    std::fflush(nullptr);
    publishProcessOutput(eco_get_exit_code());
}

} // namespace detail

// Runs one program in the current (forked child) process for a
// checkProcessOutput suite. Throws on harness errors (missing MLIR,
// CHECK-MLIR mismatch, JIT failure); returns the program's exit code on a
// normal end. A program that calls std::exit never returns here.
inline int runElmProgramForProcessCheck(const std::string& mlirPath,
                                        const std::string& elmPath,
                                        ElmSharedTestResult* shared,
                                        const std::optional<ElmE2EBase::StressFlags>& flags) {
    std::string elmContent = readFile(elmPath);
    auto checkMlirPatterns = extractCheckMlirPatterns(elmContent);

    if (!std::filesystem::exists(mlirPath)) {
        throw std::runtime_error("MLIR file not found: " + mlirPath +
                                 " (should have been compiled in Phase 1)");
    }
    if (!checkMlirPatterns.empty()) {
        std::string mlirText = readMlirAsText(mlirPath);
        std::string error = verifyPatterns(mlirText, checkMlirPatterns);
        if (!error.empty()) {
            throw std::runtime_error("MLIR-shape check failed: " + error +
                                     "\nMLIR file: " + mlirPath);
        }
    }

    auto& runner = getRunner();
    runner.reset();
    eco_test::requireRegionNursery();
    // Capture into our own leaked stream instead of the runner's thread-local
    // buffer, so the atexit hook can still read it.
    eco::EcoRunner::Options opts = runner.getOptions();
    opts.captureOutput = false;
    runner.setOptions(opts);

    auto& platform = Elm::Platform::PlatformRuntime::instance();
    std::string flagsDirective = extractFlagsDirective(elmContent);
    if (!flagsDirective.empty()) {
        platform.setPendingFlagsJson(flagsDirective);
    } else if (flags.has_value()) {
        platform.setPendingFlagsJson(flags->toJson());
    } else {
        platform.clearPendingFlagsJson();
    }
    installPortEchoBounce();

    auto& st = detail::processOutputState();
    st.shared = shared;
    st.stream = new std::ostringstream();
    std::atexit(detail::processOutputAtExit);

    eco_set_output_stream(st.stream);
    auto result = runner.runFile(mlirPath);
    eco_set_output_stream(nullptr);

    if (!result.success) {
        throw std::runtime_error("JIT execution failed: " + result.errorMessage +
                                 "\nOutput:\n" + st.stream->str().substr(0, 500));
    }
    std::cout.flush();
    std::cerr.flush();
    std::fflush(nullptr);
    detail::publishProcessOutput(result.exitCode);
    return result.exitCode;
}

// Parent-side verdict for a checkProcessOutput child that exited (not
// signalled). Returns "" on pass, else the failure message. `combinedOut`
// receives shared->output + the fork-pipe text.
inline std::string verifyProcessOutcome(const std::string& elmPath,
                                        const ElmSharedTestResult* shared,
                                        const std::string& pipeOutput,
                                        int exitStatus,
                                        std::string& combinedOut) {
    combinedOut = std::string(shared->output) + pipeOutput;
    if (shared->completed && !shared->passed) {
        return shared->error;  // harness error in the child
    }
    if (!shared->programExited) {
        return "Program did not finish (process exit code " +
               std::to_string(exitStatus) + ")";
    }
    std::string elmContent = readFile(elmPath);
    auto checkPatterns = extractCheckPatterns(elmContent);
    std::string expectedOutput = extractExpectedOutput(elmContent);
    if (checkPatterns.empty() && !expectedOutput.empty()) {
        checkPatterns.push_back({expectedOutput, /*negated=*/false});
    }
    const int expectedExit = eco_test::extractExitDirective(elmContent).value_or(0);

    std::string error;
    if (!checkPatterns.empty()) {
        error = verifyPatterns(combinedOut, checkPatterns);
    }
    if (error.empty() && exitStatus != expectedExit) {
        error = "Exit code " + std::to_string(exitStatus) + ", expected " +
                std::to_string(expectedExit) + " (-- EXIT:)";
    }
    if (error.empty()) return "";

    std::ostringstream msg;
    msg << error << "\n";
    if (shared->outputTruncated) {
        msg << "(eco-thread output was truncated to " << (sizeof(shared->output) - 1)
            << " bytes)\n";
    }
    msg << "Actual output:\n" << combinedOut.substr(0, 500);
    if (combinedOut.length() > 500) msg << "\n... (truncated)";
    return msg.str();
}

// ============================================================================
// Parallel Test Execution with GCStats
// ============================================================================

inline IsolatedTestRunner::ParallelTestSummary runMlirTestsParallel(
    const std::vector<std::string>& mlirPaths,
    const std::vector<std::string>& elmPaths,
    const std::vector<std::string>& testNames,
    const std::optional<ElmE2EBase::StressFlags>& flags = std::nullopt,
    bool checkProcessOutput = false)
{
    using namespace IsolatedTestRunner;

    const size_t numTests = mlirPaths.size();
    if (numTests == 0) {
        return {};
    }

    // The child watchdog: TEST_TIMEOUT_SECONDS, or ECO_TEST_TIMEOUT_SECONDS
    // when set (slow trees such as ECO_HEAP_VALIDATE with gc-pressure configs
    // need more). A stress run given `--timeout T` lets its programs loop for
    // up to T (StressFlags.timeoutMs), so the watchdog allows T on top; a fixed
    // 60 s would kill every long-running scenario before its own deadline.
    int64_t baseTimeoutSeconds = TEST_TIMEOUT_SECONDS;
    if (const char* env = std::getenv("ECO_TEST_TIMEOUT_SECONDS")) {
        long long v = std::atoll(env);
        if (v > 0) baseTimeoutSeconds = v;
    }
    [[maybe_unused]] const int64_t childTimeoutSeconds =
        (flags.has_value() && flags->timeoutMs > 0)
            ? flags->timeoutMs / 1000 + baseTimeoutSeconds
            : baseTimeoutSeconds;

#if defined(_WIN32)
    // Windows v1: serial in-process Elm E2E runner. No fork sandboxing —
    // a crash in any Elm test kills the suite. Tests that depend on
    // crash isolation will need a CreateProcessW + named-pipe port.
    // checkProcessOutput is not honoured here (no fork, no exit status): the
    // CHECK patterns are matched in-process against the eco-thread output.
    (void)checkProcessOutput;
    ParallelTestSummary summary;
    for (size_t i = 0; i < numTests; i++) {
        std::string err;
        bool passed = true;
        try {
            runElmTestFromMlir(mlirPaths[i], elmPaths[i], flags);
        } catch (const std::exception& e) {
            err = e.what(); passed = false;
        } catch (...) {
            err = "non-std::exception thrown"; passed = false;
        }
        printTestResult(testNames[i], passed ? "" : err, passed, "");
        if (passed) summary.passCount++;
        else { summary.failCount++; summary.failedTests.push_back(testNames[i]); }
    }
    return summary;
}
#else
    ParallelTestSummary summary;

    struct ElmTestContext {
        size_t index;
        std::string mlirPath;
        std::string elmPath;
        std::string name;
        ElmSharedTestResult* shared;
        pid_t pid;
        int outputPipe[2];
        std::chrono::steady_clock::time_point startTime;
        IsolatedTestResult result;
        bool completed;
        std::string capturedOutput;
        // Process-output mode for this test: the suite's mode, or a test
        // with an `-- EXIT:` directive in any suite (an EcoSystem* stress
        // program that must end with System.exit because a listening
        // server keeps it alive; plans/eco-system-library.md Phase 7).
        bool processMode;
    };

    std::vector<ElmTestContext> contexts(numTests);
    for (size_t i = 0; i < numTests; i++) {
        contexts[i].index = i;
        contexts[i].mlirPath = mlirPaths[i];
        contexts[i].elmPath = elmPaths[i];
        contexts[i].name = testNames[i];
        contexts[i].shared = nullptr;
        contexts[i].pid = 0;
        contexts[i].completed = false;
        contexts[i].processMode = checkProcessOutput;
        if (!checkProcessOutput) {
            try {
                contexts[i].processMode =
                    eco_test::extractExitDirective(readFile(elmPaths[i])).has_value();
            } catch (...) {
                contexts[i].processMode = false;   // reported when the test runs
            }
        }
    }

    for (auto& ctx : contexts) {
        ctx.shared = static_cast<ElmSharedTestResult*>(mmap(
            nullptr,
            sizeof(ElmSharedTestResult),
            PROT_READ | PROT_WRITE,
            MAP_SHARED | MAP_ANONYMOUS,
            -1, 0
        ));

        if (ctx.shared == MAP_FAILED) {
            for (auto& c : contexts) {
                if (c.shared && c.shared != MAP_FAILED) {
                    munmap(c.shared, sizeof(ElmSharedTestResult));
                }
            }
            for (const auto& name : testNames) {
                printTestResult(name, "", false, "Failed to allocate shared memory");
                summary.failCount++;
                summary.failedTests.push_back(name);
            }
            return summary;
        }
        std::memset(ctx.shared, 0, sizeof(ElmSharedTestResult));
    }

    std::vector<pid_t> activeChildren;
    std::unordered_map<pid_t, size_t> pidToIndex;

    installSigintHandler(&activeChildren);

    size_t nextToFork = 0;
    size_t testsCompleted = 0;

    while (testsCompleted < numTests && !g_interrupted) {
        while (activeChildren.size() < MAX_PARALLEL_TESTS &&
               nextToFork < numTests &&
               !g_interrupted) {

            auto& ctx = contexts[nextToFork];

            if (pipe(ctx.outputPipe) < 0) {
                ctx.result.passed = false;
                ctx.result.crashed = false;
                ctx.result.error = "Pipe failed: " + std::string(strerror(errno));
                ctx.completed = true;
                testsCompleted++;
                nextToFork++;
                continue;
            }

            // Flush the parent's stdio buffers first: the child inherits them,
            // and a process-output child flushes them (fflush(nullptr) /
            // exit) into its output pipe, where the runner's own text would
            // reach the CHECK patterns.
            std::cout.flush();
            std::fflush(nullptr);
            // A free port for the child, as ECO_TEST_PORT (TestPort.hpp,
            // plans/eco-system-library.md Phase 7 step 7.4).
            const int testPort = eco_test::pickFreeTcpPort();
            pid_t pid = fork();

            if (pid < 0) {
                close(ctx.outputPipe[0]);
                close(ctx.outputPipe[1]);
                ctx.result.passed = false;
                ctx.result.crashed = false;
                ctx.result.error = "Fork failed: " + std::string(strerror(errno));
                ctx.completed = true;
                testsCompleted++;
            } else if (pid == 0) {
                close(ctx.outputPipe[0]);
                dup2(ctx.outputPipe[1], STDOUT_FILENO);
                dup2(ctx.outputPipe[1], STDERR_FILENO);
                close(ctx.outputPipe[1]);

                // A write to a closed pipe returns EPIPE instead of killing
                // the test child (review R1.15).
                std::signal(SIGPIPE, SIG_IGN);

                if (testPort > 0) {
                    ::setenv("ECO_TEST_PORT", std::to_string(testPort).c_str(), 1);
                }

                if (ctx.processMode) {
                    // stdin: /dev/null, or the `-- STDIN:` text (step 8c).
                    // The program's exit status becomes the child's.
                    int programExit = 1;
                    try {
                        std::string err = eco_test::redirectChildStdin(
                            eco_test::extractStdinDirective(readFile(ctx.elmPath)));
                        if (!err.empty()) throw std::runtime_error(err);
                        programExit = runElmProgramForProcessCheck(
                            ctx.mlirPath, ctx.elmPath, ctx.shared, flags);
                        ctx.shared->passed = true;
                        ctx.shared->completed = true;
                    } catch (const std::exception& e) {
                        ctx.shared->passed = false;
                        ctx.shared->completed = true;
                        std::strncpy(ctx.shared->error, e.what(), sizeof(ctx.shared->error) - 1);
                        ctx.shared->error[sizeof(ctx.shared->error) - 1] = '\0';
                    } catch (...) {
                        ctx.shared->passed = false;
                        ctx.shared->completed = true;
                        std::strncpy(ctx.shared->error, "Unknown exception", sizeof(ctx.shared->error) - 1);
                    }
                    copyStatsToShared(ctx.shared);
                    _exit(ctx.shared->passed ? programExit : 1);
                }

                try {
                    runElmTestFromMlir(ctx.mlirPath, ctx.elmPath, flags);
                    ctx.shared->passed = true;
                    ctx.shared->completed = true;
                } catch (const std::exception& e) {
                    ctx.shared->passed = false;
                    ctx.shared->completed = true;
                    std::strncpy(ctx.shared->error, e.what(), sizeof(ctx.shared->error) - 1);
                    ctx.shared->error[sizeof(ctx.shared->error) - 1] = '\0';
                } catch (...) {
                    ctx.shared->passed = false;
                    ctx.shared->completed = true;
                    std::strncpy(ctx.shared->error, "Unknown exception", sizeof(ctx.shared->error) - 1);
                }

                copyStatsToShared(ctx.shared);
                _exit(ctx.shared->passed ? 0 : 1);
            } else {
                close(ctx.outputPipe[1]);
                ctx.pid = pid;
                ctx.startTime = std::chrono::steady_clock::now();
                activeChildren.push_back(pid);
                pidToIndex[pid] = nextToFork;
            }

            nextToFork++;
        }

        if (activeChildren.empty()) {
            break;
        }

        int status;
        pid_t finished = waitpid(-1, &status, WNOHANG);

        if (finished > 0) {
            auto it = pidToIndex.find(finished);
            if (it != pidToIndex.end()) {
                size_t idx = it->second;
                auto& ctx = contexts[idx];

                activeChildren.erase(
                    std::remove(activeChildren.begin(), activeChildren.end(), finished),
                    activeChildren.end()
                );
                pidToIndex.erase(it);

                ctx.capturedOutput = readAllFromFd(ctx.outputPipe[0]);
                close(ctx.outputPipe[0]);

                if (WIFSIGNALED(status)) {
                    ctx.result.passed = false;
                    ctx.result.crashed = true;
                    ctx.result.signal = WTERMSIG(status);
                    ctx.result.error = "Test crashed: " + signalName(ctx.result.signal);
                } else if (WIFEXITED(status) && ctx.processMode) {
                    ctx.result.exitCode = WEXITSTATUS(status);
                    std::string combined;
                    std::string error;
                    try {
                        error = verifyProcessOutcome(ctx.elmPath, ctx.shared,
                                                     ctx.capturedOutput,
                                                     ctx.result.exitCode, combined);
                    } catch (const std::exception& e) {
                        error = e.what();
                    }
                    ctx.result.passed = error.empty();
                    ctx.result.crashed = !ctx.shared->completed && !ctx.shared->programExited;
                    ctx.result.error = error;
                    ctx.result.output = combined;
                    if (ctx.shared->completed) {
                        accumulateFromShared(ctx.shared);
                    }
                } else if (WIFEXITED(status)) {
                    ctx.result.exitCode = WEXITSTATUS(status);

                    if (ctx.shared->completed) {
                        ctx.result.passed = ctx.shared->passed;
                        ctx.result.crashed = false;
                        ctx.result.error = ctx.shared->error;
                        ctx.result.output = ctx.shared->output;

                        accumulateFromShared(ctx.shared);
                    } else {
                        ctx.result.passed = false;
                        ctx.result.crashed = true;
                        ctx.result.error = "Test exited unexpectedly (exit code " +
                                           std::to_string(ctx.result.exitCode) + ")";
                    }
                } else {
                    ctx.result.passed = false;
                    ctx.result.crashed = true;
                    ctx.result.error = "Unknown wait status";
                }

                printTestResult(ctx.name, ctx.capturedOutput,
                                ctx.result.passed, ctx.result.error);

                if (ctx.result.passed) {
                    summary.passCount++;
                } else {
                    summary.failCount++;
                    summary.failedTests.push_back(ctx.name);
                }

                ctx.completed = true;
                testsCompleted++;
            }
        } else if (finished == 0) {
            auto now = std::chrono::steady_clock::now();

            for (auto& ctx : contexts) {
                if (ctx.pid > 0 && !ctx.completed) {
                    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                        now - ctx.startTime).count();

                    if (elapsed >= childTimeoutSeconds) {
                        kill(ctx.pid, SIGKILL);

                        int status;
                        waitpid(ctx.pid, &status, 0);

                        ctx.capturedOutput = readAllFromFd(ctx.outputPipe[0]);
                        close(ctx.outputPipe[0]);

                        activeChildren.erase(
                            std::remove(activeChildren.begin(), activeChildren.end(), ctx.pid),
                            activeChildren.end()
                        );
                        pidToIndex.erase(ctx.pid);

                        ctx.result.passed = false;
                        ctx.result.crashed = true;
                        ctx.result.error = "Test timed out after " +
                                           std::to_string(childTimeoutSeconds) + " seconds";

                        printTestResult(ctx.name, ctx.capturedOutput,
                                        ctx.result.passed, ctx.result.error);

                        summary.failCount++;
                        summary.failedTests.push_back(ctx.name);

                        ctx.completed = true;
                        testsCompleted++;
                    }
                }
            }

            usleep(10000);
        } else if (finished == -1 && errno != ECHILD) {
            break;
        }
    }

    if (g_interrupted) {
        for (pid_t pid : activeChildren) {
            kill(pid, SIGKILL);
            int status;
            waitpid(pid, &status, 0);
        }

        for (auto& ctx : contexts) {
            if (!ctx.completed) {
                if (ctx.pid > 0) {
                    ctx.capturedOutput = readAllFromFd(ctx.outputPipe[0]);
                    close(ctx.outputPipe[0]);
                }
                ctx.result.passed = false;
                ctx.result.crashed = true;
                ctx.result.error = "Test interrupted by user";

                printTestResult(ctx.name, ctx.capturedOutput,
                                ctx.result.passed, ctx.result.error);

                summary.failCount++;
                summary.failedTests.push_back(ctx.name);

                ctx.completed = true;
            }
        }
    }

    restoreSigintHandler();

    for (auto& ctx : contexts) {
        if (ctx.shared && ctx.shared != MAP_FAILED) {
            munmap(ctx.shared, sizeof(ElmSharedTestResult));
        }
    }

    return summary;
}
#endif  // !_WIN32

// ============================================================================
// Test Discovery
// ============================================================================

// A runnable test file declares a top-level `main`. Library/helper modules
// imported by tests (e.g. stress-elm/Gen.elm, stress-elm/Xorshift32.elm) have
// no `main` and must be skipped — otherwise the Elm compiler's "NO MAIN" error
// surfaces as a spurious test failure.
inline bool hasTopLevelMain(const std::filesystem::path& elmFile) {
    std::ifstream f(elmFile);
    if (!f) return false;
    std::string line;
    while (std::getline(f, line)) {
        if (line.size() >= 4 && line.compare(0, 4, "main") == 0) {
            char next = line[4];
            if (next == ' ' || next == '\t' || next == ':' || next == '=') {
                return true;
            }
        }
    }
    return false;
}

inline std::vector<std::string> discoverTests(const std::string& testDir) {
    std::vector<std::string> tests;

    std::string srcDir = testDir + "/src";
    if (!std::filesystem::exists(srcDir) || !std::filesystem::is_directory(srcDir)) {
        return tests;
    }

    for (const auto& entry : std::filesystem::directory_iterator(srcDir)) {
        if (entry.is_regular_file() && entry.path().extension() == ".elm" &&
            hasTopLevelMain(entry.path())) {
            tests.push_back(entry.path().string());
        }
    }

    std::sort(tests.begin(), tests.end());
    return tests;
}

// ============================================================================
// Parameterized Test Suite
// ============================================================================

class ElmE2ETestEntry : public Testing::Test {
public:
    ElmE2ETestEntry(std::string name, std::string path)
        : name_(std::move(name)), path_(std::move(path)) {}

    void run() const override {}
    bool runWithResult() const override { return true; }
    const std::string& getName() const override { return name_; }
    const std::string& getPath() const { return path_; }
    size_t countTests() const override { return 1; }

    void collectTests(std::vector<const Testing::Test*>& out,
                      const std::string& pattern = "") const override {
        if (pattern.empty() || name_.find(pattern) != std::string::npos) {
            out.push_back(this);
        }
    }

private:
    std::string name_;
    std::string path_;
};

class ElmE2EParallelTestSuite : public Testing::Test {
public:
    ElmE2EParallelTestSuite(const std::string& testDir,
                             const std::string& suiteName,
                             const std::string& testPrefix,
                             const std::string& extraCompileFlags = "",
                             std::optional<ElmE2EBase::StressFlags> stressFlags = std::nullopt,
                             bool checkProcessOutput = false)
        : name_(suiteName), testDir_(testDir), testPrefix_(testPrefix),
          extraCompileFlags_(extraCompileFlags),
          stressFlags_(stressFlags),
          checkProcessOutput_(checkProcessOutput) {
        auto testPaths = discoverTests(testDir);

        for (const auto& path : testPaths) {
            std::string filename = std::filesystem::path(path).filename().string();
            std::string testName = testPrefix + filename;
            testEntries_.push_back(std::make_unique<ElmE2ETestEntry>(testName, path));
        }
    }

    void run() const override {
        runWithResult();
    }

    bool runWithResult() const override {
        return runFiltered(Testing::CurrentFilter::get());
    }

    const std::string& getName() const override {
        return name_;
    }

    size_t countTests() const override {
        return testEntries_.size();
    }

    void collectTests(std::vector<const Testing::Test*>& out,
                      const std::string& pattern = "") const override {
        for (const auto& entry : testEntries_) {
            entry->collectTests(out, pattern);
        }
    }

    bool runFiltered(const std::string& filter) const {
        std::vector<std::string> pathsToRun;
        std::vector<std::string> namesToRun;

        for (const auto& entry : testEntries_) {
            const std::string& name = entry->getName();
            if (filter.empty() || name.find(filter) != std::string::npos) {
                pathsToRun.push_back(
                    static_cast<const ElmE2ETestEntry*>(entry.get())->getPath());
                namesToRun.push_back(name);
            }
        }

        if (pathsToRun.empty()) {
            lastPassCount_ = 0;
            lastFailCount_ = 0;
            lastFailedTests_.clear();
            return true;
        }

        lastPassCount_ = 0;
        lastFailCount_ = 0;
        lastFailedTests_.clear();

        // PHASE 1: Compile all Elm files to MLIR
        auto compileResults = compileAllElmTests(testDir_, name_, pathsToRun, extraCompileFlags_);

        std::vector<std::string> mlirPaths;
        std::vector<std::string> elmPaths;
        std::vector<std::string> testNames;
        size_t compileFailed = 0;

        for (size_t i = 0; i < compileResults.size(); i++) {
            const auto& result = compileResults[i];
            if (result.success) {
                mlirPaths.push_back(result.mlirPath);
                elmPaths.push_back(result.elmPath);
                testNames.push_back(namesToRun[i]);
            } else {
                IsolatedTestRunner::printTestResult(namesToRun[i], "",
                    false, result.errorMessage);
                lastFailedTests_.push_back(namesToRun[i]);
                compileFailed++;
            }
        }

        // PHASE 2: Run MLIR tests in parallel
        std::cout << "\nRunning " << mlirPaths.size() << " MLIR tests in parallel...\n";

        IsolatedTestRunner::ParallelTestSummary summary;
        if (!mlirPaths.empty()) {
            // Refresh startMs per-run so each fork sees a near-current zero
            // point for wall-clock timeouts.
            auto flagsPerRun = stressFlags_;
            if (flagsPerRun.has_value()) {
                flagsPerRun->startMs = static_cast<int64_t>(
                    std::chrono::duration_cast<std::chrono::milliseconds>(
                        std::chrono::system_clock::now().time_since_epoch()).count());
            }
            summary = runMlirTestsParallel(mlirPaths, elmPaths, testNames, flagsPerRun,
                                           checkProcessOutput_);
        }

        lastPassCount_ = summary.passCount;
        lastFailCount_ = summary.failCount + compileFailed;
        lastFailedTests_.insert(lastFailedTests_.end(),
            summary.failedTests.begin(), summary.failedTests.end());

        return lastFailCount_ == 0;
    }

    bool hasDetailedResults() const override { return true; }
    size_t getLastPassCount() const override { return lastPassCount_; }
    size_t getLastFailCount() const override { return lastFailCount_; }
    const std::vector<std::string>& getLastFailedTests() const override { return lastFailedTests_; }

private:
    std::string name_;
    std::string testDir_;
    std::string testPrefix_;
    std::string extraCompileFlags_;
    std::optional<ElmE2EBase::StressFlags> stressFlags_;
    // Phase 1 step 8b: CHECK sees eco-thread output + raw fd 1/2 output and is
    // verified by the parent; EXIT is enforced; stdin is /dev/null or STDIN.
    bool checkProcessOutput_ = false;
    std::vector<std::unique_ptr<ElmE2ETestEntry>> testEntries_;

    mutable size_t lastPassCount_ = 0;
    mutable size_t lastFailCount_ = 0;
    mutable std::vector<std::string> lastFailedTests_;
};

// ============================================================================
// Factory Function
// ============================================================================

// BUILD_DIR is plumbed in via target_compile_definitions in test/CMakeLists.txt
// and resolves to ${CMAKE_BINARY_DIR}. The per-package shadow under
// ${BUILD_DIR}/test/<dirName>/ holds the elm.json the compiler walks up to
// find, so eco-stuff/ and elm-stuff/ land inside the build tree.
#ifndef BUILD_DIR
#define BUILD_DIR "/work/build"
#endif

inline std::string findTestDir(const std::string& dirName) {
    return std::string(BUILD_DIR) + "/test/" + dirName;
}

inline std::unique_ptr<ElmE2EParallelTestSuite> buildTestSuite(
    const std::string& dirName,
    const std::string& suiteName,
    const std::string& testPrefix,
    const std::string& extraCompileFlags = "",
    std::optional<ElmE2EBase::StressFlags> stressFlags = std::nullopt,
    bool checkProcessOutput = false) {
#if defined(_WIN32)
    // Windows v1: the Elm → MLIR → JIT pipeline trips the same
    // Allocator::resolve "Pointer above heap end" assertion the codegen
    // suite hits (see test/main.cpp's `_WIN32` gate). The Elm suites all
    // share that JIT path, so point them at a non-existent directory; the
    // parallel suite finds zero .mlir files and reports a zero-test pass.
    // Re-enabling these once the Win64 HPtr-return ABI issue is fixed is
    // W5 follow-up.
    (void)dirName;
    return std::make_unique<ElmE2EParallelTestSuite>(
        "win-skipped/" + dirName,
        suiteName + " (skipped on Windows v1)",
        testPrefix, extraCompileFlags, stressFlags, checkProcessOutput);
#else
    std::string testDir = findTestDir(dirName);

    if (!std::filesystem::exists(testDir) || !std::filesystem::is_directory(testDir)) {
        std::cerr << "Warning: Could not find test directory: " << testDir << std::endl;
    }

    return std::make_unique<ElmE2EParallelTestSuite>(
        testDir, suiteName, testPrefix, extraCompileFlags, stressFlags,
        checkProcessOutput);
#endif
}

}  // namespace ElmE2EBase
