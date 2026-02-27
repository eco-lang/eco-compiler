//===- Process.cpp - Process kernel module implementation -----------------===//

#include "Process.hpp"
#include "KernelHelpers.hpp"
#include <cstdlib>
#include <string>
#include <unordered_map>
#include <vector>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

namespace Eco::Kernel::Process {

// Map from child PID to pipe fd (stdin write end) if applicable.
static std::unordered_map<int64_t, int> s_streamHandles;

uint64_t exit(int64_t code) {
    ::exit(static_cast<int>(code));
    // Never returns.
    return 0;
}

uint64_t spawn(uint64_t cmd, uint64_t args) {
    std::string cmdStr = toString(cmd);
    std::vector<std::string> argStrs = listToStringVector(args);

    // Build argv array for execvp.
    std::vector<char*> argv;
    argv.push_back(const_cast<char*>(cmdStr.c_str()));
    for (auto& a : argStrs) {
        argv.push_back(const_cast<char*>(a.c_str()));
    }
    argv.push_back(nullptr);

    pid_t pid = fork();
    if (pid < 0) {
        return taskFailString("fork failed");
    }
    if (pid == 0) {
        // Child process.
        execvp(argv[0], argv.data());
        ::_exit(127);
    }
    return taskSucceedInt(static_cast<int64_t>(pid));
}

uint64_t spawnProcess(uint64_t cmd, uint64_t args,
                      uint64_t stdin_, uint64_t stdout_, uint64_t stderr_) {
    std::string cmdStr = toString(cmd);
    std::vector<std::string> argStrs = listToStringVector(args);
    std::string stdinCfg = toString(stdin_);
    std::string stdoutCfg = toString(stdout_);
    std::string stderrCfg = toString(stderr_);

    int stdinPipe[2] = {-1, -1};
    bool pipeStdin = (stdinCfg == "pipe");
    if (pipeStdin) {
        if (pipe(stdinPipe) < 0) {
            return taskFailString("pipe failed");
        }
    }

    // Build argv.
    std::vector<char*> argv;
    argv.push_back(const_cast<char*>(cmdStr.c_str()));
    for (auto& a : argStrs) {
        argv.push_back(const_cast<char*>(a.c_str()));
    }
    argv.push_back(nullptr);

    pid_t pid = fork();
    if (pid < 0) {
        if (pipeStdin) {
            ::close(stdinPipe[0]);
            ::close(stdinPipe[1]);
        }
        return taskFailString("fork failed");
    }

    if (pid == 0) {
        // Child process.
        if (pipeStdin) {
            dup2(stdinPipe[0], STDIN_FILENO);
            ::close(stdinPipe[0]);
            ::close(stdinPipe[1]);
        }
        // stdout/stderr: "inherit" is the default (do nothing).
        execvp(argv[0], argv.data());
        ::_exit(127);
    }

    // Parent process.
    if (pipeStdin) {
        ::close(stdinPipe[0]); // Close read end in parent.
    }

    // Build result record: { stdinHandle : Maybe Int, processHandle : Int }
    // Layout (unboxed-first):
    //   Slot 0: processHandle (Int, unboxed)
    //   Slot 1: stdinHandle (Maybe Int, boxed)
    //   Bitmap: 0b01
    using namespace Elm::alloc;
    std::vector<Unboxable> fields(2);
    fields[0].i = static_cast<int64_t>(pid);

    if (pipeStdin) {
        int64_t handleId = stdinPipe[1];
        s_streamHandles[handleId] = stdinPipe[1];
        HPointer handleInt = allocInt(handleId);
        fields[1].p = just(boxed(handleInt), true);
    } else {
        fields[1].p = nothing();
    }

    HPointer rec = record(fields, 0b01);
    return taskSucceed(rec);
}

uint64_t wait(uint64_t handle) {
    int64_t pid = static_cast<int64_t>(handle);
    int status = 0;
    waitpid(static_cast<pid_t>(pid), &status, 0);
    int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : 1;
    return taskSucceedInt(exitCode);
}

} // namespace Eco::Kernel::Process
