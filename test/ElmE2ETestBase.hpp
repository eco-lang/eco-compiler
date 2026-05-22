#pragma once

#include "CheckPatterns.hpp"
#include "IsolatedTestRunner.hpp"
#include "TestSuite.hpp"
#include "../runtime/src/codegen/EcoRunner.hpp"
#include "../runtime/src/allocator/GCStats.hpp"
#include "../runtime/src/allocator/Allocator.hpp"
#include "../runtime/src/platform/PlatformRuntime.hpp"

#include <algorithm>
#include <array>
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
#include <sys/mman.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace ElmE2EBase {

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

    std::string fullCmd = cmd + " 2>&1";
    std::unique_ptr<FILE, decltype(&pclose)> pipe(popen(fullCmd.c_str(), "r"), pclose);

    if (!pipe) {
        throw std::runtime_error("popen() failed for command: " + cmd);
    }

    while (fgets(buffer.data(), buffer.size(), pipe.get()) != nullptr) {
        result += buffer.data();
    }

    int status = pclose(pipe.release());
    int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;

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

    std::string compileCmd = "cd \"" + testDir + "\" && node \"" + guidaPath +
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

inline void runElmTestFromMlir(const std::string& mlirPath,
                               const std::string& elmPath,
                               const std::optional<Elm::Platform::StressFlags>& flags = std::nullopt) {
    std::string elmContent = readFile(elmPath);
    auto checkPatterns = extractCheckPatterns(elmContent);
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

    auto& runner = getRunner();
    runner.reset();

    // Platform.worker reads the pending flags (if any) to build its
    // `flags` argument. Absent → Unit (default for non-stress tests).
    auto& platform = Elm::Platform::PlatformRuntime::instance();
    if (flags.has_value()) {
        platform.setPendingFlags(*flags);
    } else {
        platform.clearPendingFlags();
    }

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
// Parallel Test Execution with GCStats
// ============================================================================

inline IsolatedTestRunner::ParallelTestSummary runMlirTestsParallel(
    const std::vector<std::string>& mlirPaths,
    const std::vector<std::string>& elmPaths,
    const std::vector<std::string>& testNames,
    const std::optional<Elm::Platform::StressFlags>& flags = std::nullopt)
{
    using namespace IsolatedTestRunner;

    const size_t numTests = mlirPaths.size();
    if (numTests == 0) {
        return {};
    }

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

                    if (elapsed >= TEST_TIMEOUT_SECONDS) {
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
                                           std::to_string(TEST_TIMEOUT_SECONDS) + " seconds";

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
                             std::optional<Elm::Platform::StressFlags> stressFlags = std::nullopt)
        : name_(suiteName), testDir_(testDir), testPrefix_(testPrefix),
          extraCompileFlags_(extraCompileFlags),
          stressFlags_(stressFlags) {
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
            summary = runMlirTestsParallel(mlirPaths, elmPaths, testNames, flagsPerRun);
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
    std::optional<Elm::Platform::StressFlags> stressFlags_;
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
    std::optional<Elm::Platform::StressFlags> stressFlags = std::nullopt) {
    std::string testDir = findTestDir(dirName);

    if (!std::filesystem::exists(testDir) || !std::filesystem::is_directory(testDir)) {
        std::cerr << "Warning: Could not find test directory: " << testDir << std::endl;
    }

    return std::make_unique<ElmE2EParallelTestSuite>(
        testDir, suiteName, testPrefix, extraCompileFlags, stressFlags);
}

}  // namespace ElmE2EBase
