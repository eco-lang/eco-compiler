#pragma once

// plans/spawn-not-fork.md Phase 3: the test harnesses run every isolated test
// and every E2E program in a SPAWNED child process (platform::spawnChild:
// posix_spawn / CreateProcessW), never a forked one. A child starts from
// nothing: no allocator config, address reservation, GC threads or
// singletons inherited from the test process (the inherited-legacy-nursery
// defect of plans/region-nursery-everywhere.md was exactly that).
//
// Protocol. The parent runs `<self> --isolated-child <result> <kind> <args…>`
// with stdout + stderr redirected into a per-test output file:
//   * <result>: a file of the caller's result-record size, zero-filled by the
//     parent. The child maps it SHARED (mmap / CreateFileMapping), so what it
//     wrote before a crash, std::exit or _exit is there for the parent, as
//     the old MAP_SHARED|MAP_ANONYMOUS block was across fork.
//   * <kind> <args…>: dispatched by the binary's main (runIsolatedChild).
// The parent polls its children (pollChild), kills one at its timeout
// (killChild: SIGKILL, or its Job on Windows) and reads the output and
// result files when it ends.

#include "../runtime/src/platform/Spawn.hpp"
#include "TestSuite.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iterator>
#include <optional>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif
#endif

namespace eco_test {

constexpr const char* kChildFlag = "--isolated-child";
constexpr size_t kMaxParallelChildren = 8;

// This executable's own path, to spawn it again in child mode.
inline std::string selfExePath() {
#if defined(_WIN32)
    wchar_t buf[32768];
    const DWORD n = GetModuleFileNameW(nullptr, buf, static_cast<DWORD>(std::size(buf)));
    const int len = WideCharToMultiByte(CP_UTF8, 0, buf, static_cast<int>(n), nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<size_t>(len), '\0');
    WideCharToMultiByte(CP_UTF8, 0, buf, static_cast<int>(n), out.data(), len, nullptr, nullptr);
    return out;
#elif defined(__APPLE__)
    char buf[4096];
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) != 0) return std::string();
    return std::filesystem::weakly_canonical(buf).string();
#else
    std::error_code ec;
    auto p = std::filesystem::read_symlink("/proc/self/exe", ec);
    return ec ? std::string() : p.string();
#endif
}

inline int currentPid() {
#if defined(_WIN32)
    return static_cast<int>(GetCurrentProcessId());
#else
    return static_cast<int>(::getpid());
#endif
}

inline std::string readWholeFile(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

// A fresh directory for one parallel run's result and output files.
inline std::filesystem::path makeRunDir() {
    static std::atomic<int> counter{0};
    std::error_code ec;
    auto dir = std::filesystem::temp_directory_path(ec) /
               ("eco-test-" + std::to_string(currentPid()) + "-" + std::to_string(counter++));
    std::filesystem::remove_all(dir, ec);
    std::filesystem::create_directories(dir, ec);
    return dir;
}

// The child's view of its result file: `size` bytes mapped shared, kept for
// the life of the process.
inline void* mapResultFile(const std::string& path, size_t size) {
#if defined(_WIN32)
    const int wlen = MultiByteToWideChar(CP_UTF8, 0, path.data(), static_cast<int>(path.size()), nullptr, 0);
    std::wstring wpath(static_cast<size_t>(wlen), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, path.data(), static_cast<int>(path.size()), wpath.data(), wlen);
    HANDLE f = CreateFileW(wpath.c_str(), GENERIC_READ | GENERIC_WRITE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                           nullptr);
    if (f == INVALID_HANDLE_VALUE) return nullptr;
    HANDLE m = CreateFileMappingW(f, nullptr, PAGE_READWRITE, 0, static_cast<DWORD>(size), nullptr);
    CloseHandle(f);
    if (!m) return nullptr;
    return MapViewOfFile(m, FILE_MAP_WRITE, 0, 0, size);
#else
    int fd = ::open(path.c_str(), O_RDWR | O_CLOEXEC);
    if (fd < 0) return nullptr;
    void* p = ::mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    ::close(fd);
    return p == MAP_FAILED ? nullptr : p;
#endif
}

// Child side: the parent wrote nothing to the console we inherit, and a
// write to a closed pipe must return EPIPE instead of killing a test child.
inline void childProcessSetup() {
#if !defined(_WIN32)
    std::signal(SIGPIPE, SIG_IGN);
#endif
}

// How a spawned child ended, as the parent saw it.
struct ChildOutcome {
    bool timedOut = false;
    bool interrupted = false;
    bool spawnFailed = false;
    std::string spawnError;
    Elm::platform::ChildExit exit;
    std::string output;              // its stdout + stderr
    std::vector<char> result;        // its result file
};

// What the caller makes of an outcome.
struct ChildVerdict {
    bool passed = false;
    std::string error;
    std::string output;              // printed under the test name
};

struct SpawnedRunSummary {
    size_t passCount = 0;
    size_t failCount = 0;
    std::vector<std::string> failedTests;
};

inline std::string signalDescription(int sig) {
#if defined(_WIN32)
    char buf[64];
    std::snprintf(buf, sizeof(buf), "exception 0x%08X", static_cast<unsigned>(sig));
    return buf;
#else
    switch (sig) {
        case SIGSEGV: return "SIGSEGV (Segmentation fault)";
        case SIGABRT: return "SIGABRT (Aborted)";
        case SIGFPE:  return "SIGFPE (Floating point exception)";
        case SIGBUS:  return "SIGBUS (Bus error)";
        case SIGILL:  return "SIGILL (Illegal instruction)";
        case SIGKILL: return "SIGKILL (Killed)";
        case SIGTERM: return "SIGTERM (Terminated)";
        default:      return "Signal " + std::to_string(sig);
    }
#endif
}

inline void printChildResult(const std::string& name, const std::string& output, bool passed,
                             const std::string& error) {
    namespace Color = Testing::Color;
    std::ostringstream oss;
    oss << "- " << Color::bold() << name << Color::reset() << "\n";
    if (!output.empty()) {
        oss << Color::dim() << output << Color::reset();
        if (output.back() != '\n') oss << "\n";
    }
    if (passed) {
        oss << Color::bold() << Color::green() << "OK" << Color::reset() << "\n";
    } else {
        oss << Color::bold() << Color::red() << "FAILED" << Color::reset() << ": " << Color::red() << error
            << Color::reset() << "\n";
    }
    std::cout << oss.str() << std::flush;
}

// Ctrl+C: the parent stops starting children and kills the running ones.
// (On Windows each child is in a kill-on-close Job, so a parent that dies
// takes its children with it anyway.)
inline volatile std::sig_atomic_t g_childRunInterrupted = 0;
inline void childRunSigint(int) { g_childRunInterrupted = 1; }

struct ChildJob {
    std::vector<std::string> args;                                   // <kind> <args…>
    std::vector<std::pair<std::string, std::string>> env;            // added to ours
    int timeoutSeconds = 60;
};

// Runs every job in a spawned child, up to kMaxParallelChildren at once, and
// prints each test as it ends (completion order). `finish` turns an outcome
// into a verdict; it runs in the parent, in completion order.
inline SpawnedRunSummary runSpawnedChildren(
    const std::vector<std::string>& names, size_t resultSize,
    const std::function<ChildJob(size_t)>& makeJob,
    const std::function<ChildVerdict(size_t, const ChildOutcome&)>& finish) {
    SpawnedRunSummary summary;
    const size_t n = names.size();
    if (n == 0) return summary;

    const std::string self = selfExePath();
    const std::filesystem::path dir = makeRunDir();

    struct Running {
        size_t index;
        Elm::platform::SpawnedChild child;
        std::chrono::steady_clock::time_point start;
        int timeoutSeconds;
        std::string resultPath, outputPath;
    };
    std::vector<Running> running;

    auto report = [&](size_t idx, const ChildVerdict& v) {
        printChildResult(names[idx], v.output, v.passed, v.error);
        if (v.passed) {
            summary.passCount++;
        } else {
            summary.failCount++;
            summary.failedTests.push_back(names[idx]);
        }
    };
    auto collect = [&](Running& r, ChildOutcome& o) {
        o.output = readWholeFile(r.outputPath);
        std::string res = readWholeFile(r.resultPath);
        o.result.assign(res.begin(), res.end());
        o.result.resize(resultSize, 0);
        Elm::platform::releaseChild(r.child);
        report(r.index, finish(r.index, o));
        std::error_code ec;
        std::filesystem::remove(r.resultPath, ec);
        std::filesystem::remove(r.outputPath, ec);
    };

    g_childRunInterrupted = 0;
    auto oldSigint = std::signal(SIGINT, childRunSigint);

    size_t next = 0;
    while ((next < n || !running.empty()) && !g_childRunInterrupted) {
        while (running.size() < kMaxParallelChildren && next < n && !g_childRunInterrupted) {
            const size_t idx = next++;
            ChildJob job = makeJob(idx);
            Running r;
            r.index = idx;
            r.timeoutSeconds = job.timeoutSeconds;
            r.resultPath = (dir / (std::to_string(idx) + ".res")).string();
            r.outputPath = (dir / (std::to_string(idx) + ".out")).string();
            {
                std::ofstream res(r.resultPath, std::ios::binary | std::ios::trunc);
                std::vector<char> zeros(resultSize, 0);
                res.write(zeros.data(), static_cast<std::streamsize>(zeros.size()));
            }
            Elm::platform::SpawnSpec spec;
            spec.program = self;
            spec.shellKind = Elm::platform::kShellNone;
            spec.args = {kChildFlag, r.resultPath};
            spec.args.insert(spec.args.end(), job.args.begin(), job.args.end());
            spec.envMode = job.env.empty() ? Elm::platform::kEnvInherit : Elm::platform::kEnvMerge;
            spec.env = job.env;
            spec.outputPath = r.outputPath;
            spec.killTreeOnRelease = true;
            std::cout.flush();
            std::fflush(nullptr);
            r.child = Elm::platform::spawnChild(spec, Elm::platform::StdioMode::ToFile, /*newSession=*/false);
            if (r.child.err != 0) {
                ChildOutcome o;
                o.spawnFailed = true;
                o.spawnError = std::strerror(r.child.err);
                ChildVerdict v;
                v.error = "Spawn failed: " + o.spawnError;
                report(idx, v);
                continue;
            }
            r.start = std::chrono::steady_clock::now();
            running.push_back(std::move(r));
        }

        bool progressed = false;
        for (size_t i = 0; i < running.size();) {
            ChildOutcome o;
            const auto st = Elm::platform::pollChild(running[i].child, o.exit);
            if (st == Elm::platform::ChildState::Running) {
                const auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                    std::chrono::steady_clock::now() - running[i].start).count();
                if (elapsed < running[i].timeoutSeconds) {
                    ++i;
                    continue;
                }
                Elm::platform::killChild(running[i].child);
                o.exit = Elm::platform::waitChild(running[i].child);
                o.timedOut = true;
            }
            collect(running[i], o);
            running.erase(running.begin() + static_cast<std::ptrdiff_t>(i));
            progressed = true;
        }
        if (!progressed) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }

    if (g_childRunInterrupted) {
        for (auto& r : running) {
            Elm::platform::killChild(r.child);
            ChildOutcome o;
            o.exit = Elm::platform::waitChild(r.child);
            o.interrupted = true;
            collect(r, o);
        }
        for (; next < n; ++next) {
            ChildVerdict v;
            v.error = "Test interrupted by user";
            report(next, v);
        }
    }
    std::signal(SIGINT, oldSigint);
    std::error_code ec;
    std::filesystem::remove_all(dir, ec);
    return summary;
}

// The common verdict for a result record with `completed`, `passed` and
// `error[]` fields (IsolatedTestRunner::SharedTestResult, ElmSharedTestResult).
template <class Record>
Record resultRecord(const ChildOutcome& o) {
    Record rec{};
    std::memcpy(static_cast<void*>(&rec), o.result.data(), std::min(sizeof(Record), o.result.size()));
    return rec;
}

template <class Record>
ChildVerdict defaultVerdict(const ChildOutcome& o, int timeoutSeconds) {
    ChildVerdict v;
    v.output = o.output;
    if (o.interrupted) {
        v.error = "Test interrupted by user";
    } else if (o.timedOut) {
        v.error = "Test timed out after " + std::to_string(timeoutSeconds) + " seconds";
    } else if (o.exit.signaled) {
        v.error = "Test crashed: " + signalDescription(o.exit.signal);
    } else {
        const Record rec = resultRecord<Record>(o);
        if (!rec.completed) {
            v.error = "Test exited unexpectedly (exit code " + std::to_string(o.exit.code) + ")";
        } else {
            v.passed = rec.passed;
            if (!rec.passed) v.error = std::string(rec.error, strnlen(rec.error, sizeof(rec.error)));
        }
    }
    return v;
}

// Child side: maps the result record and runs `body`, recording whether it
// threw. Returns the child's exit status.
template <class Record>
int runChildBody(const std::string& resultPath, const std::function<void()>& body) {
    childProcessSetup();
    auto* rec = static_cast<Record*>(mapResultFile(resultPath, sizeof(Record)));
    if (!rec) {
        std::cerr << "isolated child: cannot map result file " << resultPath << std::endl;
        return 2;
    }
    try {
        body();
        rec->passed = true;
        rec->completed = true;
    } catch (const std::exception& e) {
        rec->passed = false;
        rec->completed = true;
        std::strncpy(rec->error, e.what(), sizeof(rec->error) - 1);
        rec->error[sizeof(rec->error) - 1] = '\0';
    } catch (...) {
        rec->passed = false;
        rec->completed = true;
        std::strncpy(rec->error, "Unknown exception", sizeof(rec->error) - 1);
    }
    std::cout.flush();
    std::fflush(nullptr);
    return rec->passed ? 0 : 1;
}

// A program run to completion with its stdout + stderr captured (the AOT and
// MLIR-equivalence runners): spawned, never forked. `extraEnv` holds
// "KEY=VALUE" strings added to ours; `cwd` empty = ours; `stdinText` absent =
// the null device. A program that cannot be started reports exit 127 and the
// reason in `output`, as an execvp failure in a forked child did.
struct CapturedRun {
    int exitCode = -1;
    int termSignal = 0;
    std::string output;
};

inline CapturedRun runCaptured(const std::vector<std::string>& argv,
                               const std::vector<std::string>& extraEnv,
                               const std::string& cwd,
                               const std::optional<std::string>& stdinText = std::nullopt) {
    CapturedRun r;
    if (argv.empty()) {
        r.output = "no program";
        return r;
    }
    const std::filesystem::path dir = makeRunDir();
    Elm::platform::SpawnSpec spec;
    spec.program = argv[0];
    spec.args.assign(argv.begin() + 1, argv.end());
    spec.shellKind = Elm::platform::kShellNone;
    for (const auto& kv : extraEnv) {
        const size_t eq = kv.find('=');
        if (eq != std::string::npos) spec.env.push_back({kv.substr(0, eq), kv.substr(eq + 1)});
    }
    spec.envMode = spec.env.empty() ? Elm::platform::kEnvInherit : Elm::platform::kEnvMerge;
    spec.inheritCwd = cwd.empty();
    spec.cwd = cwd;
    spec.outputPath = (dir / "out").string();
    if (stdinText.has_value()) {
        spec.inputPath = (dir / "in").string();
        std::ofstream in(spec.inputPath, std::ios::binary);
        in << *stdinText;
    }
    spec.killTreeOnRelease = true;
    Elm::platform::SpawnedChild child =
        Elm::platform::spawnChild(spec, Elm::platform::StdioMode::ToFile, /*newSession=*/false);
    if (child.err != 0) {
        r.exitCode = 127;
        r.output = "spawn(" + argv[0] + ") failed: " + std::strerror(child.err) + "\n";
    } else {
        const Elm::platform::ChildExit e = Elm::platform::waitChild(child);
        Elm::platform::releaseChild(child);
        if (e.signaled) {
            r.termSignal = e.signal;
            r.exitCode = 128 + e.signal;
        } else {
            r.exitCode = e.code;
        }
        r.output = readWholeFile(spec.outputPath);
    }
    std::error_code ec;
    std::filesystem::remove_all(dir, ec);
    return r;
}

} // namespace eco_test
