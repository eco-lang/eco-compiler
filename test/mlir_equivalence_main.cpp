// mlir-equivalence — bootstrap-stage MLIR equivalence test runner.
//
// For each Elm E2E test source under test/<package>/src/*Test.elm:
//   1. Compile with Stage 2 compiler (eco-boot.js via node) to binary MLIR.
//   2. Compile with Stage 6 compiler (eco-compiler native ELF) to binary MLIR.
//   3. Compare the two binary MLIRs byte-for-byte.
//
// Each compile uses an isolated --builddir so caches never collide.
//
// Concurrency capped at 4 by default (override with MLIR_EQUIV_JOBS=<N>).
//
// Prerequisites: Stages 1..6 of guides/bootstrap.md must have been run; the
// runner checks for the existence of eco-boot.js + eco-boot-runner.js and
// eco-compiler and aborts with a clear diagnostic if either is missing.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_set>
#include <vector>

#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include "NodeBigStack.hpp"
#include "SpawnedChildren.hpp"

namespace fs = std::filesystem;

#ifndef REPO_ROOT
#define REPO_ROOT "/work"
#endif

// BUILD_DIR locates the per-package shadow directories materialized by
// test/CMakeLists.txt (elm.json + src symlink under ${CMAKE_BINARY_DIR}/test/<pkg>/).
// Test discovery walks <BUILD_DIR>/test/<pkg>/src for *.elm sources; per-test
// --builddir scratch and any eco-stuff/elm-stuff caches then land alongside.
#ifndef BUILD_DIR
#define BUILD_DIR "/work/build"
#endif

namespace {

// ANSI colors (only if stdout is a tty).
struct Color {
    bool enabled;
    const char* red() const     { return enabled ? "\033[31m" : ""; }
    const char* green() const   { return enabled ? "\033[32m" : ""; }
    const char* yellow() const  { return enabled ? "\033[33m" : ""; }
    const char* cyan() const    { return enabled ? "\033[36m" : ""; }
    const char* dim() const     { return enabled ? "\033[90m" : ""; }
    const char* bold() const    { return enabled ? "\033[1m"  : ""; }
    const char* reset() const   { return enabled ? "\033[0m"  : ""; }
};

Color g_color{ static_cast<bool>(isatty(fileno(stdout))) };

struct TestCase {
    std::string package_dir;   // absolute path to test package (cwd for compiler)
    std::string elm_file;      // absolute path to *.elm source
    std::string display_name;  // "<package>/<TestName>"
};

enum class Side { Stage2, Stage6 };
const char* side_name(Side s) { return s == Side::Stage2 ? "Stage2" : "Stage6"; }

struct ProcResult {
    int exit_code = -1;
    int term_signal = 0;
    std::string stderr_tail;
};

struct TestResult {
    std::string display_name;
    bool passed = false;
    std::string failure_reason;     // short one-line summary
    std::string failure_detail;     // multi-line diff or stderr excerpt
    std::string stage2_bin_path;    // binary MLIR (the compared artefact)
    std::string stage6_bin_path;
};

// ----------------------------------------------------------------------------
// Subprocess spawn with stderr capture.
// ----------------------------------------------------------------------------

// Spawn argv[0..n-1] with env (or current env if env_inherit), cwd, and write
// stdout+stderr to a single capture buffer (capped). Returns exit code.
ProcResult spawn_capture(const std::vector<std::string>& argv,
                          const std::vector<std::string>& extra_env,
                          const std::string& cwd,
                          std::size_t stderr_cap = 8192) {
    // plans/spawn-not-fork.md: spawned (posix_spawn / CreateProcessW), never forked.
    eco_test::CapturedRun run = eco_test::runCaptured(argv, extra_env, cwd);
    ProcResult r;
    r.exit_code = run.exitCode;
    r.term_signal = run.termSignal;
    if (run.output.size() > stderr_cap) {
        r.stderr_tail = "... (truncated) ...\n" + run.output.substr(run.output.size() - stderr_cap);
    } else {
        r.stderr_tail = std::move(run.output);
    }
    return r;
}

// ----------------------------------------------------------------------------
// Test case discovery.
// ----------------------------------------------------------------------------

const std::vector<std::string>& test_package_dirs() {
    static const std::vector<std::string> dirs = {
        BUILD_DIR "/test/elm",
        BUILD_DIR "/test/elm-core",
        BUILD_DIR "/test/elm-bytes",
        BUILD_DIR "/test/elm-http",
        BUILD_DIR "/test/elm-json",
        BUILD_DIR "/test/elm-parser",
        BUILD_DIR "/test/elm-regex",
        BUILD_DIR "/test/elm-time",
        BUILD_DIR "/test/elm-url",
        BUILD_DIR "/test/eco-kernel",
        BUILD_DIR "/test/stress-elm",
    };
    return dirs;
}

std::vector<TestCase> discover_tests() {
    std::vector<TestCase> cases;
    for (const auto& pkg : test_package_dirs()) {
        fs::path src = fs::path(pkg) / "src";
        if (!fs::is_directory(src)) continue;
        for (const auto& ent : fs::directory_iterator(src)) {
            if (!ent.is_regular_file()) continue;
            const fs::path& p = ent.path();
            if (p.extension() != ".elm") continue;
            std::string stem = p.stem().string();
            // stress-elm uses `*Stress.elm`, others use `*Test.elm`. Accept both.
            if (stem.size() < 4) continue;
            const bool is_test   = stem.rfind("Test")   == stem.size() - 4;
            const bool is_stress = stem.size() >= 6 && stem.rfind("Stress") == stem.size() - 6;
            if (!is_test && !is_stress) continue;

            TestCase tc;
            tc.package_dir  = pkg;
            tc.elm_file     = fs::absolute(p).string();
            tc.display_name = fs::path(pkg).filename().string() + "/" + stem;
            cases.push_back(std::move(tc));
        }
    }
    std::sort(cases.begin(), cases.end(), [](const TestCase& a, const TestCase& b) {
        return a.display_name < b.display_name;
    });
    return cases;
}

// ----------------------------------------------------------------------------
// Per-test driver.
// ----------------------------------------------------------------------------

const char* ECO_BOOT_JS     = BUILD_DIR  "/compiler/build-kernel/bin/eco-boot.js";
const char* ECO_BOOT_RUNNER = BUILD_DIR  "/compiler/build-kernel/bin/eco-boot-runner.js";
const char* ECO_COMPILER    = BUILD_DIR  "/compiler/build-kernel/bin/eco-compiler";
const char* ECO_KERNEL_DIR  = REPO_ROOT "/eco-kernel-cpp";

bool preflight() {
    bool ok = true;
    auto check = [&](const char* path) {
        if (!fs::is_regular_file(path)) {
            std::cerr << g_color.red() << "[mlir-equivalence] missing: " << path << g_color.reset() << "\n";
            ok = false;
        }
    };
    check(ECO_BOOT_JS);
    check(ECO_BOOT_RUNNER);
    check(ECO_COMPILER);
    if (!ok) {
        std::cerr << "Run guides/bootstrap.md stages 1..6 first.\n";
    }
    return ok;
}

// builddir_name returns a single-component directory name (no slashes) that
// the eco compiler accepts for the --builddir flag. The compiler creates
// `<cwd>/eco-stuff/<version>/<name>/` for cache storage (d.dat/i.dat and the
// per-module .eci/.ecot); we keep one name per (test, stage) pair so
// concurrent compiles, and the JS and native compilers, don't share caches.
std::string builddir_name(const std::string& test_stem, Side side) {
    return "mlir_eq_" + test_stem + (side == Side::Stage2 ? "_s2" : "_s6");
}

// Run one compile invocation. Output is MLIR bytecode (binary).
ProcResult run_stage(Side side,
                     const TestCase& tc,
                     const std::string& builddir,
                     const std::string& mlir_out) {
    std::vector<std::string> argv;
    auto push_common = [&](std::vector<std::string>& a) {
        a.emplace_back("make");
        a.emplace_back("--optimize");
        a.emplace_back(std::string("--builddir=") + builddir);
        a.emplace_back("--kernel-package");
        a.emplace_back("eco/compiler");
        a.emplace_back(std::string("--local-package=eco/kernel=") + ECO_KERNEL_DIR);
        a.emplace_back(std::string("--output=") + mlir_out);
        a.emplace_back(tc.elm_file);
    };

    if (side == Side::Stage2) {
        // Big stack (NodeBigStack.hpp), as in the E2E and AOT runners: the widest pins
        // (arity 2047) overflow node's default stack.
        argv = {"sh", "-c", kNodeBigStackScript, "sh", ECO_BOOT_RUNNER};
    } else {
        argv = {ECO_COMPILER};
    }
    push_common(argv);

    std::vector<std::string> env = {
        "NODE_OPTIONS=--max-old-space-size=12000",
    };
    return spawn_capture(argv, env, tc.package_dir);
}

// Read a file into a string; returns std::nullopt on error.
std::optional<std::string> slurp(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f.is_open()) return std::nullopt;
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

// Short summary of a binary-mode mismatch — bytecode is opaque, so we just
// report sizes and the first differing offset.
std::string short_binary_diff(const std::string& a, const std::string& b) {
    std::ostringstream os;
    os << "stage2 bytes: " << a.size() << ", stage6 bytes: " << b.size() << "\n";
    std::size_t n = std::min(a.size(), b.size());
    std::size_t i = 0;
    for (; i < n; ++i) {
        if (a[i] != b[i]) break;
    }
    if (i < n) {
        os << "first differing byte at offset " << i
           << " (stage2=0x" << std::hex << (static_cast<unsigned>(a[i]) & 0xff)
           << " stage6=0x"   << (static_cast<unsigned>(b[i]) & 0xff) << std::dec << ")\n";
    } else if (a.size() != b.size()) {
        os << "files agree on first " << n << " bytes but differ in length\n";
    }
    return os.str();
}

TestResult run_one(const TestCase& tc, const std::string& out_root) {
    TestResult r;
    r.display_name = tc.display_name;

    fs::path pkg_name = fs::path(tc.package_dir).filename();
    fs::path stem     = fs::path(tc.elm_file).stem();
    fs::path test_root = fs::path(out_root) / pkg_name / stem.string();
    fs::create_directories(test_root);

    // Binary (bytecode) outputs use the `.mlir` extension — the compiler's
    // parseOutput accepts only that suffix and emits bytecode by default.
    r.stage2_bin_path = (test_root / "stage2.bin.mlir").string();
    r.stage6_bin_path = (test_root / "stage6.bin.mlir").string();

    // Wipe any prior outputs.
    std::error_code ignore;
    fs::remove(r.stage2_bin_path, ignore);
    fs::remove(r.stage6_bin_path, ignore);

    const std::string s2_bd = builddir_name(stem.string(), Side::Stage2);
    const std::string s6_bd = builddir_name(stem.string(), Side::Stage6);

    // ---- Stage 2 ----
    ProcResult p2 = run_stage(Side::Stage2, tc, s2_bd, r.stage2_bin_path);
    if (p2.exit_code != 0 || !fs::is_regular_file(r.stage2_bin_path)) {
        r.passed = false;
        r.failure_reason = std::string("Stage2 compile failed (exit ") + std::to_string(p2.exit_code) + ")";
        r.failure_detail = p2.stderr_tail;
        return r;
    }

    // ---- Stage 6 ----
    ProcResult p6 = run_stage(Side::Stage6, tc, s6_bd, r.stage6_bin_path);
    if (p6.exit_code != 0 || !fs::is_regular_file(r.stage6_bin_path)) {
        r.passed = false;
        r.failure_reason = std::string("Stage6 compile failed (exit ") + std::to_string(p6.exit_code) + ")";
        r.failure_detail = p6.stderr_tail;
        return r;
    }

    // ---- Binary equivalence check ----
    auto a = slurp(r.stage2_bin_path);
    auto b = slurp(r.stage6_bin_path);
    if (!a || !b) {
        r.passed = false;
        r.failure_reason = "Failed to read output MLIR";
        return r;
    }
    if (*a == *b) {
        r.passed = true;
        return r;
    }
    r.passed = false;
    r.failure_reason = "Binary MLIR mismatch (stage2 != stage6)";
    r.failure_detail = short_binary_diff(*a, *b);
    return r;
}

// ----------------------------------------------------------------------------
// Driver.
// ----------------------------------------------------------------------------

struct Args {
    std::string filter;
    int jobs = 4;
    bool help = false;
    bool list = false;
};

Args parse_args(int argc, char** argv) {
    Args a;
    for (int i = 1; i < argc; ++i) {
        std::string s = argv[i];
        if (s == "--help" || s == "-h") {
            a.help = true;
        } else if (s == "--list") {
            a.list = true;
        } else if (s == "--filter" && i + 1 < argc) {
            a.filter = argv[++i];
        } else if (s.rfind("--filter=", 0) == 0) {
            a.filter = s.substr(9);
        } else if (s == "--jobs" && i + 1 < argc) {
            a.jobs = std::atoi(argv[++i]);
        } else if (s.rfind("--jobs=", 0) == 0) {
            a.jobs = std::atoi(s.c_str() + 7);
        } else {
            std::cerr << "Unknown arg: " << s << "\n";
            a.help = true;
        }
    }
    if (const char* env = std::getenv("MLIR_EQUIV_JOBS")) {
        int v = std::atoi(env);
        if (v > 0) a.jobs = v;
    }
    if (a.jobs < 1) a.jobs = 1;
    if (a.jobs > 16) a.jobs = 16;
    return a;
}

void print_help(const char* prog) {
    std::cout
        << "Usage: " << prog << " [--filter <pat>] [--jobs <N>] [--list]\n"
        << "\n"
        << "Compares Stage 2 (eco-boot.js) and Stage 6 (eco-compiler) MLIR\n"
        << "output for every Elm E2E test source. PASS if byte-identical.\n"
        << "\n"
        << "  --filter <pat>   Only run tests whose display name contains <pat>.\n"
        << "  --jobs <N>       Concurrent tests (default 4). Override via MLIR_EQUIV_JOBS.\n"
        << "  --list           List discovered tests and exit.\n"
        << "  --help           Show this message.\n";
}

}  // namespace

int main(int argc, char** argv) {
    Args args = parse_args(argc, argv);
    if (args.help) { print_help(argv[0]); return 0; }

    if (!preflight()) return 2;

    std::vector<TestCase> cases = discover_tests();
    if (!args.filter.empty()) {
        std::vector<TestCase> filtered;
        for (auto& c : cases) {
            if (c.display_name.find(args.filter) != std::string::npos) {
                filtered.push_back(std::move(c));
            }
        }
        cases = std::move(filtered);
    }

    if (args.list) {
        for (auto& c : cases) std::cout << c.display_name << "\n";
        std::cout << "\n" << cases.size() << " tests\n";
        return 0;
    }

    if (cases.empty()) {
        std::cerr << "no tests matched filter \"" << args.filter << "\"\n";
        return 1;
    }

    fs::path out_root = fs::path(REPO_ROOT) / "build" / "test" / "mlir-equivalence-out";
    fs::create_directories(out_root);

    // Pre-cleanup: wipe every compiler-version dir `<pkg>/eco-stuff/<version>/`
    // (it holds the per-test builddirs `<version>/mlir_eq_*`). Leftovers from a
    // previous run can be incompatible with the current compilers (stale .ecot)
    // or partially written, and surface as `CORRUPT CACHE`. The old check named
    // `1.0.0` and `eco-stuff/mlir_eq_*`, neither of which exists.
    {
        std::unordered_set<std::string> seen;
        for (const auto& c : cases) {
            if (!seen.insert(c.package_dir).second) continue;
            fs::path eco_stuff = fs::path(c.package_dir) / "eco-stuff";
            std::error_code ec;
            if (fs::is_directory(eco_stuff, ec)) {
                for (auto& ent : fs::directory_iterator(eco_stuff, ec)) {
                    if (!ent.is_directory()) continue;
                    const std::string nm = ent.path().filename().string();
                    if (nm != "mlir") {
                        fs::remove_all(ent.path(), ec);
                    }
                }
            }
        }
    }

    // Split the test set into a warm-up batch (one test per package, runs
    // serially) and the remainder (runs in parallel). The warm-up primes the
    // shared `~/.eco` package caches (elm/core etc. and the local eco/kernel
    // typed artifacts), so the parallel phase only reads them; per-module
    // artifacts live in each test's own builddir. This mirrors
    // `ElmE2ETestBase.hpp::compileAllElmTests`.
    std::vector<std::size_t> warmup_indices;
    std::vector<std::size_t> rest_indices;
    {
        std::unordered_set<std::string> seen_packages;
        for (std::size_t i = 0; i < cases.size(); ++i) {
            if (seen_packages.insert(cases[i].package_dir).second) {
                warmup_indices.push_back(i);
            } else {
                rest_indices.push_back(i);
            }
        }
    }

    std::cout << "mlir-equivalence: " << cases.size() << " tests"
              << " (" << warmup_indices.size() << " warm-up, "
              << rest_indices.size() << " parallel @ " << args.jobs << ")\n"
              << std::flush;

    std::mutex mtx;
    std::vector<TestResult> results;
    results.reserve(cases.size());
    std::size_t completed = 0;
    const auto t0 = std::chrono::steady_clock::now();

    auto report = [&](const TestResult& done) {
        std::unique_lock lk(mtx);
        ++completed;
        std::cout << "[" << completed << "/" << cases.size() << "] "
                  << done.display_name << " "
                  << (done.passed
                          ? std::string(g_color.green()) + "ok" + g_color.reset()
                          : std::string(g_color.red())   + "FAIL" + g_color.reset());
        if (!done.passed) std::cout << " — " << done.failure_reason;
        std::cout << "\n" << std::flush;
    };

    // Phase 1: warm-up (serial, one test per package).
    for (std::size_t idx : warmup_indices) {
        TestResult r = run_one(cases[idx], out_root.string());
        report(r);
        results.push_back(std::move(r));
    }

    // Phase 2: parallel over the remainder.
    std::size_t next_idx = 0;
    auto worker = [&]() {
        while (true) {
            std::size_t which;
            {
                std::unique_lock lk(mtx);
                if (next_idx >= rest_indices.size()) return;
                which = rest_indices[next_idx++];
            }
            TestResult r = run_one(cases[which], out_root.string());
            report(r);
            {
                std::unique_lock lk(mtx);
                results.push_back(std::move(r));
            }
        }
    };

    int n_workers = std::min<int>(args.jobs, static_cast<int>(rest_indices.size()));
    std::vector<std::thread> ts;
    ts.reserve(n_workers);
    for (int i = 0; i < n_workers; ++i) ts.emplace_back(worker);
    for (auto& t : ts) t.join();

    std::sort(results.begin(), results.end(),
              [](const TestResult& a, const TestResult& b) {
                  return a.display_name < b.display_name;
              });

    std::size_t pass = 0, fail = 0;
    for (auto& r : results) (r.passed ? ++pass : ++fail);

    std::cout << "\n=== Summary ===\n"
              << "Tests run:    " << results.size() << "\n"
              << "Tests passed: " << g_color.green() << pass  << g_color.reset() << "\n"
              << "Tests failed: " << (fail ? g_color.red() : g_color.dim()) << fail << g_color.reset() << "\n";

    if (fail) {
        std::cout << "\nFailures:\n";
        for (auto& r : results) {
            if (r.passed) continue;
            std::cout << "  " << r.display_name << " — " << r.failure_reason << "\n";
            if (!r.failure_detail.empty()) {
                std::istringstream iss(r.failure_detail);
                std::string line;
                int n = 0;
                while (std::getline(iss, line) && n++ < 30) {
                    std::cout << "    " << g_color.dim() << line << g_color.reset() << "\n";
                }
                if (std::getline(iss, line)) std::cout << "    ...\n";
            }
            std::cout << "    stage2 bin: " << r.stage2_bin_path << "\n";
            std::cout << "    stage6 bin: " << r.stage6_bin_path << "\n";
        }
    }

    const auto t1 = std::chrono::steady_clock::now();
    std::cout << "\nElapsed: "
              << std::chrono::duration_cast<std::chrono::seconds>(t1 - t0).count()
              << " s\n"
              << "Result: " << (fail ? "FAILED" : "PASSED") << "\n";
    return fail ? 1 : 0;
}
