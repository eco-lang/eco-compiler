//===- SpawnTest.cpp - the spawn primitive (plans/spawn-not-fork.md) -------===//
//
// platform::spawnChild is the one way the runtime, the kernels and the test
// harnesses start a child process. These run in the process-isolated
// PlatformServices suite: S1 registers a pthread_atfork counter and forks,
// which must not leak into other tests.
//
// S1 pins the plan's premise (Phase 0 step 1): posix_spawn runs no
// pthread_atfork handler (HEAP_075's prepare stops the GC gangs and takes
// every runtime lock, so a fork-based spawn would pay that on every child),
// while fork() runs them (the positive control).
//
//===----------------------------------------------------------------------===//

#include "SpawnTest.hpp"
#include "../../runtime/src/platform/Spawn.hpp"
#include "../TestSuite.hpp"
#include "../allocator/TestHelpers.hpp"

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#if !defined(_WIN32)
#include <atomic>
#include <csignal>
#include <pthread.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

using namespace Elm::platform;

namespace {

#if !defined(_WIN32)

std::atomic<int> g_prepareCalls{0};
void countPrepare() { g_prepareCalls.fetch_add(1); }

SpawnSpec shell(const std::string& script) {
    SpawnSpec spec;
    spec.program = "/bin/sh";
    spec.args = {"-c", script};
    spec.shellKind = kShellNone;
    return spec;
}

std::string tempPath(const std::string& name) {
    return (std::filesystem::temp_directory_path() /
            ("eco-spawn-test-" + std::to_string(::getpid()) + "-" + name)).string();
}

std::string slurp(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

int exitOf(const SpawnSpec& spec, StdioMode mode = StdioMode::Null) {
    SpawnedChild c = spawnChild(spec, mode, false);
    TEST_ASSERT(c.err == 0 && c.pid > 0);
    ChildExit e = waitChild(c);
    TEST_ASSERT(e.exited);
    return e.code;
}

// S1: no atfork handler runs for posix_spawn; fork runs it (control).
void test_spawn_runs_no_atfork_handler() {
    TEST_ASSERT(pthread_atfork(countPrepare, nullptr, nullptr) == 0);
    const int before = g_prepareCalls.load();
    TEST_ASSERT(exitOf(shell("exit 0")) == 0);
    TEST_ASSERT(g_prepareCalls.load() == before);
    const pid_t pid = ::fork();   // the positive control: fork IS the subject here
    if (pid == 0) ::_exit(0);
    TEST_ASSERT(pid > 0);
    int st = 0;
    ::waitpid(pid, &st, 0);
    TEST_ASSERT(g_prepareCalls.load() == before + 1);
}

// S2: exit statuses come back unchanged.
void test_spawn_exit_codes() {
    TEST_ASSERT(exitOf(shell("exit 0")) == 0);
    TEST_ASSERT(exitOf(shell("exit 1")) == 1);
    TEST_ASSERT(exitOf(shell("exit 255")) == 255);
}

// S3: a program that does not exist fails the spawn itself (ENOENT): no child.
void test_spawn_missing_program_fails() {
    SpawnSpec spec;
    spec.program = "eco-spawn-test-no-such-program";
    spec.shellKind = kShellNone;
    SpawnedChild c = spawnChild(spec, StdioMode::Null, false);
    TEST_ASSERT(c.err == ENOENT);
    TEST_ASSERT(c.pid == -1);
}

// S4: ToFile sends stdout and stderr to one file; stdin is /dev/null.
void test_spawn_to_file_captures_both_streams() {
    SpawnSpec spec = shell("echo out; echo err 1>&2; read x || echo eof");
    spec.outputPath = tempPath("tofile");
    TEST_ASSERT(exitOf(spec, StdioMode::ToFile) == 0);
    const std::string text = slurp(spec.outputPath);
    std::filesystem::remove(spec.outputPath);
    TEST_ASSERT(text == "out\nerr\neof\n");
}

// S5: StdinPipe gives the parent the child's stdin.
void test_spawn_stdin_pipe() {
    SpawnSpec spec = shell("read x; exit ${#x}");
    SpawnedChild c = spawnChild(spec, StdioMode::StdinPipe, false);
    TEST_ASSERT(c.err == 0 && c.stdinFd >= 0 && c.stdoutFd < 0);
    TEST_ASSERT(::write(c.stdinFd, "hello\n", 6) == 6);
    ::close(c.stdinFd);
    ChildExit e = waitChild(c);
    TEST_ASSERT(e.exited && e.code == 5);
}

// S6: environment merge and replace.
void test_spawn_environment() {
    ::setenv("ECO_SPAWN_MARK", "1", 1);   // ours: inherited by Merge, absent under Replace
    SpawnSpec merged = shell("[ -n \"$ECO_SPAWN_MARK\" ] || exit 1; exit $ECO_SPAWN_T");
    merged.envMode = kEnvMerge;
    merged.env = {{"ECO_SPAWN_T", "7"}};
    TEST_ASSERT(exitOf(merged) == 7);
    SpawnSpec replaced = shell("[ -z \"$ECO_SPAWN_MARK\" ] || exit 1; exit $ECO_SPAWN_T");
    replaced.envMode = kEnvReplace;
    replaced.env = {{"ECO_SPAWN_T", "9"}};
    TEST_ASSERT(exitOf(replaced) == 9);
}

// S7: the working directory.
void test_spawn_cwd() {
    const auto dir = std::filesystem::canonical(std::filesystem::temp_directory_path());
    SpawnSpec spec = shell("pwd -P");
    spec.inheritCwd = false;
    spec.cwd = dir.string();
    spec.outputPath = tempPath("cwd");
    TEST_ASSERT(exitOf(spec, StdioMode::ToFile) == 0);
    const std::string text = slurp(spec.outputPath);
    std::filesystem::remove(spec.outputPath);
    TEST_ASSERT(text == dir.string() + "\n");
}

// S8: argv reaches the child unchanged (no shell re-splitting): spaces,
// quotes, backslashes, an empty argument, non-ASCII.
void test_spawn_argv_round_trip() {
    const std::vector<std::string> hostile = {"a b", "\"q\"", "back\\slash\\", "", "ünï ✓", "-c"};
    SpawnSpec spec;
    spec.program = "/bin/sh";
    spec.shellKind = kShellNone;
    spec.args = {"-c", "for a in \"$@\"; do printf '[%s]' \"$a\"; done", "sh"};
    spec.args.insert(spec.args.end(), hostile.begin(), hostile.end());
    spec.outputPath = tempPath("argv");
    TEST_ASSERT(exitOf(spec, StdioMode::ToFile) == 0);
    std::string expected;
    for (const auto& a : hostile) expected += "[" + a + "]";
    const std::string text = slurp(spec.outputPath);
    std::filesystem::remove(spec.outputPath);
    TEST_ASSERT(text == expected);
}

// S9: poll, kill and the signal outcome (the harnesses' timeout path).
void test_spawn_poll_and_kill() {
    SpawnedChild c = spawnChild(shell("exec sleep 30"), StdioMode::Null, false);
    TEST_ASSERT(c.err == 0);
    ChildExit e;
    TEST_ASSERT(pollChild(c, e) == ChildState::Running);
    killChild(c);
    e = waitChild(c);
    TEST_ASSERT(e.signaled && e.signal == SIGKILL);
    releaseChild(c);
}

#endif  // !_WIN32

}  // namespace

void registerSpawnTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite) {
#if !defined(_WIN32)
    suite.add(Testing::TestCase("spawn/S1 posix_spawn runs no atfork handler; fork does", test_spawn_runs_no_atfork_handler));
    suite.add(Testing::TestCase("spawn/S2 exit codes", test_spawn_exit_codes));
    suite.add(Testing::TestCase("spawn/S3 a missing program fails the spawn", test_spawn_missing_program_fails));
    suite.add(Testing::TestCase("spawn/S4 ToFile captures stdout and stderr", test_spawn_to_file_captures_both_streams));
    suite.add(Testing::TestCase("spawn/S5 stdin pipe", test_spawn_stdin_pipe));
    suite.add(Testing::TestCase("spawn/S6 environment merge and replace", test_spawn_environment));
    suite.add(Testing::TestCase("spawn/S7 working directory", test_spawn_cwd));
    suite.add(Testing::TestCase("spawn/S8 argv round trip", test_spawn_argv_round_trip));
    suite.add(Testing::TestCase("spawn/S9 poll and kill", test_spawn_poll_and_kill));
#else
    (void)suite;
#endif
}
