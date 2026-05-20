// aot_e2e_main.cpp — AOT E2E test runner.
//
// For each Elm test source in the starter set (Step A) or the full corpus
// (Step B):
//   1. Compile `.elm` -> `.mlir` via Stage 3's eco-boot-2-runner.js
//      (the kernel-IO, fixed-point-verified JS compiler — same compiler
//      Stage 5 uses to produce eco-compiler.mlir).
//   2. Lower `.mlir` -> native ELF via eco-boot-native.
//   3. Run the ELF, capture stdout/stderr, verify against `-- CHECK:` /
//      `-- CHECK-NOT:` patterns in the test source.
//
// Outputs land under ${BUILD_DIR}/test/aot-e2e/<pkg>/ so they do not
// collide with the JIT E2E suite's outputs (which live at
// ${BUILD_DIR}/test/<pkg>/).
//
// Concurrency capped at 4 by default (override with AOT_E2E_JOBS=<N>).
//
// Prerequisites (CMake handles via DEPENDS):
//   - test/aot-e2e/<pkg>/ shadow tree (configure-time scaffold)
//   - build/compiler/build-kernel/bin/eco-boot-2.js + runner (Stage 3)
//   - build/runtime/src/codegen/eco-boot-native

#include "CheckPatterns.hpp"

#include <algorithm>
#include <atomic>
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
#include <sys/wait.h>
#include <unistd.h>

namespace fs = std::filesystem;

#ifndef REPO_ROOT
#define REPO_ROOT "/work"
#endif

#ifndef BUILD_DIR
#define BUILD_DIR "/work/build"
#endif

namespace {

// ----------------------------------------------------------------------------
// Tiny terminal colour helper.
// ----------------------------------------------------------------------------

struct Color {
    bool enabled;
    const char* red()    const { return enabled ? "\033[31m" : ""; }
    const char* green()  const { return enabled ? "\033[32m" : ""; }
    const char* yellow() const { return enabled ? "\033[33m" : ""; }
    const char* cyan()   const { return enabled ? "\033[36m" : ""; }
    const char* dim()    const { return enabled ? "\033[90m" : ""; }
    const char* bold()   const { return enabled ? "\033[1m"  : ""; }
    const char* reset()  const { return enabled ? "\033[0m"  : ""; }
};

Color g_color{ static_cast<bool>(isatty(fileno(stdout))) };

// ----------------------------------------------------------------------------
// Toolchain paths.
// ----------------------------------------------------------------------------

const char* ECO_BOOT_2_RUNNER = BUILD_DIR "/compiler/build-kernel/bin/eco-boot-2-runner.js";
const char* ECO_BOOT_NATIVE   = BUILD_DIR "/runtime/src/codegen/eco-boot-native";
const char* ECO_KERNEL_DIR    = REPO_ROOT "/eco-kernel-cpp";

bool preflight() {
    bool ok = true;
    auto check = [&](const char* path) {
        if (!fs::exists(path)) {
            std::cerr << g_color.red() << "[aot-e2e] missing: " << path
                      << g_color.reset() << "\n";
            ok = false;
        }
    };
    check(ECO_BOOT_2_RUNNER);
    check(ECO_BOOT_NATIVE);
    if (!ok) {
        std::cerr << "Build the eco-boot-2 and eco-boot-native targets first "
                     "(or run guides/bootstrap.md Stages 1..4).\n";
    }
    return ok;
}

// ----------------------------------------------------------------------------
// Per-test descriptor.
// ----------------------------------------------------------------------------

struct TestCase {
    std::string package_name;  // e.g. "elm"
    std::string stem;          // e.g. "AddTest"
    std::string elm_file;      // absolute path to source .elm
    std::string aot_shadow;    // absolute path to AOT shadow dir (cwd for compile)
    std::string display_name;  // "<pkg>/<stem>"
};

// Packages contributing E2E test sources. Matches the JIT runner's
// ELM_TEST_PACKAGES minus `stress-elm` (those are large, long-running, and
// covered by the separate `stress-test` binary).
const std::vector<std::string>& aot_test_packages() {
    static const std::vector<std::string> pkgs = {
        "elm", "elm-bytes", "eco-kernel", "elm-core", "elm-http",
        "elm-json", "elm-parser", "elm-regex", "elm-time", "elm-url",
    };
    return pkgs;
}

// A runnable test file declares a top-level `main`. Library/helper modules
// imported by tests have no `main` and must be skipped — otherwise the Elm
// compiler reports "NO MAIN" as a spurious test failure. Mirrors
// ElmE2ETestBase::hasTopLevelMain.
bool has_top_level_main(const fs::path& elm_file) {
    std::ifstream f(elm_file);
    if (!f) return false;
    std::string line;
    while (std::getline(f, line)) {
        if (line.size() >= 4 && line.compare(0, 4, "main") == 0) {
            char next = line[4];
            if (next == ' ' || next == '\t' || next == ':' || next == '=')
                return true;
        }
    }
    return false;
}

std::vector<TestCase> discover_all() {
    std::vector<TestCase> cases;
    for (const std::string& pkg : aot_test_packages()) {
        fs::path src = fs::path(REPO_ROOT) / "test" / pkg / "src";
        std::error_code ec;
        if (!fs::is_directory(src, ec)) continue;
        for (const auto& ent : fs::directory_iterator(src, ec)) {
            if (!ent.is_regular_file()) continue;
            const fs::path& p = ent.path();
            if (p.extension() != ".elm") continue;
            const std::string stem = p.stem().string();
            // Accept only *Test.elm sources (matches the JIT E2E convention).
            if (stem.size() < 4 || stem.rfind("Test") != stem.size() - 4)
                continue;
            if (!has_top_level_main(p)) continue;

            TestCase tc;
            tc.package_name = pkg;
            tc.stem         = stem;
            tc.elm_file     = fs::absolute(p).string();
            tc.aot_shadow   = std::string(BUILD_DIR "/test/aot-e2e/") + pkg;
            tc.display_name = pkg + "/" + stem;
            cases.push_back(std::move(tc));
        }
    }
    std::sort(cases.begin(), cases.end(),
              [](const TestCase& a, const TestCase& b) {
                  return a.display_name < b.display_name;
              });
    return cases;
}

// ----------------------------------------------------------------------------
// Subprocess spawn with combined stdout/stderr capture.
//
// Returns exit code, terminating signal (if any), and the captured output
// (truncated to `cap` bytes if it overflows).
// ----------------------------------------------------------------------------

struct ProcResult {
    int exit_code = -1;
    int term_signal = 0;
    std::string output;        // stdout + stderr merged
    bool truncated = false;
};

ProcResult spawn_capture(const std::vector<std::string>& argv,
                          const std::vector<std::string>& extra_env,
                          const std::string& cwd,
                          std::size_t cap = 64 * 1024) {
    ProcResult r;

    int pipefd[2];
    if (pipe(pipefd) < 0) {
        r.output = "pipe() failed";
        return r;
    }

    pid_t pid = fork();
    if (pid < 0) {
        ::close(pipefd[0]);
        ::close(pipefd[1]);
        r.output = "fork() failed";
        return r;
    }

    if (pid == 0) {
        // Child.
        ::close(pipefd[0]);
        if (dup2(pipefd[1], STDOUT_FILENO) < 0) _exit(127);
        if (dup2(pipefd[1], STDERR_FILENO) < 0) _exit(127);
        ::close(pipefd[1]);

        if (!cwd.empty() && chdir(cwd.c_str()) != 0) {
            ::fprintf(stderr, "chdir(%s) failed: %s\n",
                      cwd.c_str(), strerror(errno));
            _exit(127);
        }

        for (const auto& e : extra_env) {
            ::putenv(const_cast<char*>(e.c_str()));
        }

        std::vector<char*> c_argv;
        c_argv.reserve(argv.size() + 1);
        for (auto& a : argv) c_argv.push_back(const_cast<char*>(a.c_str()));
        c_argv.push_back(nullptr);

        execvp(c_argv[0], c_argv.data());
        ::fprintf(stderr, "execvp(%s) failed: %s\n",
                  c_argv[0], strerror(errno));
        _exit(127);
    }

    // Parent.
    ::close(pipefd[1]);
    std::string buf;
    buf.reserve(8192);
    char tmp[4096];
    ssize_t n;
    while ((n = read(pipefd[0], tmp, sizeof(tmp))) > 0) {
        if (buf.size() + static_cast<std::size_t>(n) <= cap) {
            buf.append(tmp, static_cast<std::size_t>(n));
        } else if (buf.size() < cap) {
            buf.append(tmp, cap - buf.size());
            r.truncated = true;
        } else {
            r.truncated = true;
        }
    }
    ::close(pipefd[0]);

    int wstatus = 0;
    waitpid(pid, &wstatus, 0);
    if (WIFEXITED(wstatus)) {
        r.exit_code = WEXITSTATUS(wstatus);
    } else if (WIFSIGNALED(wstatus)) {
        r.term_signal = WTERMSIG(wstatus);
        r.exit_code = 128 + r.term_signal;
    }
    r.output = std::move(buf);
    return r;
}

// ----------------------------------------------------------------------------
// Per-test driver.
// ----------------------------------------------------------------------------

struct TestResult {
    std::string display_name;
    bool passed = false;
    std::string failure_reason;
    std::string failure_detail;
};

std::optional<std::string> slurp(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f.is_open()) return std::nullopt;
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

std::string truncated_tail(const std::string& s, std::size_t cap = 4096) {
    if (s.size() <= cap) return s;
    return "... (truncated) ...\n" + s.substr(s.size() - cap);
}

ProcResult compile_to_mlir(const TestCase& tc, const std::string& mlir_out) {
    // Per-test builddir name (under <pkg>/eco-stuff/<name>/) so concurrent
    // compiles don't share caches.
    const std::string builddir = "aot_e2e_" + tc.stem;

    std::vector<std::string> argv = {
        "node",
        "--stack-size=65536",
        ECO_BOOT_2_RUNNER,
        "make",
        "--optimize",
        std::string("--builddir=") + builddir,
        "--kernel-package", "eco/compiler",
        std::string("--local-package=eco/kernel=") + ECO_KERNEL_DIR,
        std::string("--output=") + mlir_out,
        tc.elm_file,
    };
    std::vector<std::string> env = {
        "NODE_OPTIONS=--max-old-space-size=12000",
    };
    return spawn_capture(argv, env, tc.aot_shadow);
}

ProcResult lower_to_elf(const std::string& mlir_in, const std::string& elf_out,
                        const std::string& cwd) {
    std::vector<std::string> argv = {
        ECO_BOOT_NATIVE,
        mlir_in,
        "-o", elf_out,
    };
    return spawn_capture(argv, {}, cwd);
}

ProcResult run_elf(const std::string& elf_path, const std::string& cwd) {
    std::vector<std::string> argv = { elf_path };
    return spawn_capture(argv, {}, cwd);
}

TestResult run_one(const TestCase& tc) {
    TestResult r;
    r.display_name = tc.display_name;

    // Per-test output paths inside the AOT shadow.
    fs::path mlir_dir = fs::path(tc.aot_shadow) / "eco-stuff" / "mlir";
    fs::path bin_dir  = fs::path(tc.aot_shadow) / "aot-bin";
    fs::path run_dir  = fs::path(tc.aot_shadow) / "run-out";
    fs::create_directories(mlir_dir);
    fs::create_directories(bin_dir);
    fs::create_directories(run_dir);

    const std::string mlir_out = (mlir_dir / (tc.stem + ".mlir")).string();
    const std::string elf_out  = (bin_dir / tc.stem).string();
    const std::string out_log  = (run_dir / (tc.stem + ".out")).string();

    // Wipe any prior outputs.
    std::error_code ignore;
    fs::remove(mlir_out, ignore);
    fs::remove(elf_out, ignore);
    fs::remove(out_log, ignore);

    // 1. Elm -> MLIR via eco-boot-2-runner.js.
    {
        ProcResult p = compile_to_mlir(tc, mlir_out);
        if (p.exit_code != 0 || !fs::is_regular_file(mlir_out)) {
            r.failure_reason = "Elm->MLIR failed (exit " + std::to_string(p.exit_code) + ")";
            r.failure_detail = truncated_tail(p.output);
            return r;
        }
    }

    // 2. MLIR -> ELF via eco-boot-native.
    {
        ProcResult p = lower_to_elf(mlir_out, elf_out, tc.aot_shadow);
        if (p.exit_code != 0 || !fs::is_regular_file(elf_out)) {
            r.failure_reason = "MLIR->ELF failed (exit " + std::to_string(p.exit_code) + ")";
            r.failure_detail = truncated_tail(p.output);
            return r;
        }
    }

    // 3. Run the ELF and capture stdout/stderr.
    //
    // Exit code is NOT used as a pass/fail oracle. Many Elm test programs
    // return UI values (e.g. `Html.text "hello"`) from main and have no
    // meaningful exit-status semantics — they "succeed" by producing the
    // expected stdout. Only signal termination (SIGSEGV, SIGABRT, etc.) is
    // an unconditional fail; everything else defers to the CHECK-pattern
    // oracle below.
    std::string elf_output;
    int elf_exit = 0;
    {
        ProcResult p = run_elf(elf_out, tc.aot_shadow);
        elf_output = p.output;
        elf_exit = p.exit_code;
        std::ofstream(out_log) << elf_output;
        if (p.term_signal != 0) {
            r.failure_reason = "ELF crashed (signal " +
                               std::to_string(p.term_signal) + ")";
            r.failure_detail = truncated_tail(elf_output);
            return r;
        }
    }

    // 4. Verify CHECK patterns against the captured output.
    auto src = slurp(tc.elm_file);
    if (!src) {
        r.failure_reason = "Failed to read source file " + tc.elm_file;
        return r;
    }
    auto patterns = eco_test::extractCheckPatterns(
        *src, "-- CHECK:", "-- CHECK-NOT:");
    if (patterns.empty()) {
        // No directives — treat the run as informational pass (matches the
        // mlir-equivalence policy of "compile succeeds = pass" when there's
        // no further oracle).
        r.passed = true;
        return r;
    }
    std::string err = eco_test::verifyPatterns(elf_output, patterns);
    if (!err.empty()) {
        r.failure_reason = err;
        std::ostringstream d;
        d << "ELF exited with status " << elf_exit << "\n"
          << "Captured ELF output:\n" << truncated_tail(elf_output);
        r.failure_detail = d.str();
        return r;
    }
    r.passed = true;
    return r;
}

// ----------------------------------------------------------------------------
// Driver: arg parsing, parallel execution, summary print.
// ----------------------------------------------------------------------------

struct Args {
    std::string filter;
    int jobs = 0;  // 0 = not set; resolved to hardware_concurrency in parse_args
    bool help = false;
    bool list = false;
};

// Default parallelism: system cores when known, else 4. Mirrors
// ElmE2ETestBase::getMaxParallelCompilations so both E2E suites scale
// identically out of the box.
int default_jobs() {
    unsigned int cores = std::thread::hardware_concurrency();
    return cores > 0 ? static_cast<int>(cores) : 4;
}

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
    if (const char* env = std::getenv("AOT_E2E_JOBS")) {
        int v = std::atoi(env);
        if (v > 0) a.jobs = v;
    }
    if (a.jobs <= 0) a.jobs = default_jobs();
    if (a.jobs < 1) a.jobs = 1;
    if (a.jobs > 16) a.jobs = 16;
    return a;
}

void print_help(const char* prog) {
    std::cout
        << "Usage: " << prog << " [--filter <pat>] [--jobs <N>] [--list]\n"
        << "\n"
        << "Compiles each Elm E2E test via Stage 3's eco-boot-2.js, lowers to\n"
        << "native ELF via eco-boot-native, runs the binary, and verifies its\n"
        << "stdout against `-- CHECK:` / `-- CHECK-NOT:` patterns.\n"
        << "\n"
        << "  --filter <pat>  Only run tests whose display name contains <pat>.\n"
        << "  --jobs <N>      Concurrent tests (default: number of system cores).\n"
        << "                  Override via AOT_E2E_JOBS or this flag.\n"
        << "  --list          List discovered tests and exit.\n"
        << "  --help          Show this message.\n";
}

}  // namespace

int main(int argc, char** argv) {
    Args args = parse_args(argc, argv);
    if (args.help) { print_help(argv[0]); return 0; }
    if (!preflight()) return 2;

    std::vector<TestCase> cases = discover_all();
    if (!args.filter.empty()) {
        std::vector<TestCase> filtered;
        for (auto& c : cases) {
            if (c.display_name.find(args.filter) != std::string::npos)
                filtered.push_back(std::move(c));
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

    // Pre-clean per-test builddirs from prior runs in each touched AOT shadow.
    // Without this, a stale `<pkg>/eco-stuff/aot_e2e_<stem>/` directory from a
    // prior compiler version may contain incompatible cache files.
    {
        std::unordered_set<std::string> seen;
        for (const auto& c : cases) {
            if (!seen.insert(c.aot_shadow).second) continue;
            fs::path eco_stuff = fs::path(c.aot_shadow) / "eco-stuff";
            std::error_code ec;
            if (fs::is_directory(eco_stuff, ec)) {
                for (auto& ent : fs::directory_iterator(eco_stuff, ec)) {
                    if (!ent.is_directory()) continue;
                    const std::string nm = ent.path().filename().string();
                    if (nm == "1.0.0" || nm.rfind("aot_e2e_", 0) == 0) {
                        fs::remove_all(ent.path(), ec);
                    }
                }
            }
        }
    }

    // Two-phase execution mirroring mlir-equivalence: a serial warm-up of one
    // test per package primes the shared `<pkg>/eco-stuff/1.0.0/` artifact
    // cache, then the rest run in parallel. Without this, concurrent compiles
    // in the same package can race to populate the cache and surface
    // "CORRUPT CACHE" diagnostics.
    std::vector<TestCase> warmup;
    std::vector<TestCase> rest;
    {
        std::unordered_set<std::string> seen;
        for (auto& c : cases) {
            if (seen.insert(c.aot_shadow).second) {
                warmup.push_back(c);
            } else {
                rest.push_back(c);
            }
        }
    }

    std::vector<TestResult> results;
    results.reserve(cases.size());
    std::mutex results_mu;

    auto emit = [&](const TestResult& r) {
        std::lock_guard<std::mutex> lk(results_mu);
        if (r.passed) {
            std::cout << g_color.green() << "PASS" << g_color.reset()
                      << "  " << r.display_name << "\n";
        } else {
            std::cout << g_color.red()   << "FAIL" << g_color.reset()
                      << "  " << r.display_name
                      << g_color.dim() << "  (" << r.failure_reason << ")"
                      << g_color.reset() << "\n";
            if (!r.failure_detail.empty()) {
                std::cout << g_color.dim() << r.failure_detail
                          << g_color.reset() << "\n";
            }
        }
        std::cout.flush();
        results.push_back(r);
    };

    std::cout << g_color.bold() << "[aot-e2e] running " << cases.size()
              << " tests (jobs=" << args.jobs << ")\n" << g_color.reset();

    for (const auto& tc : warmup) emit(run_one(tc));

    if (!rest.empty()) {
        std::vector<std::thread> workers;
        std::atomic<std::size_t> next{0};
        for (int t = 0; t < args.jobs; ++t) {
            workers.emplace_back([&]() {
                for (;;) {
                    std::size_t i = next.fetch_add(1);
                    if (i >= rest.size()) return;
                    emit(run_one(rest[i]));
                }
            });
        }
        for (auto& w : workers) w.join();
    }

    std::size_t passed = 0, failed = 0;
    for (const auto& r : results) (r.passed ? passed : failed)++;

    std::cout << "\n"
              << g_color.bold() << "=== AOT E2E Summary ===\n" << g_color.reset()
              << "Tests run:    " << results.size() << "\n"
              << "Tests passed: " << g_color.green() << passed << g_color.reset() << "\n"
              << "Tests failed: " << (failed ? g_color.red() : g_color.dim())
              << failed << g_color.reset() << "\n"
              << "\nResult: " << (failed == 0 ? g_color.green() : g_color.red())
              << (failed == 0 ? "PASSED" : "FAILED") << g_color.reset() << "\n";

    return failed == 0 ? 0 : 1;
}
