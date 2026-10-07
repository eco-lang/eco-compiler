//===- ChildProcess.hpp - eco/system kernel module ChildProcess (internal) ===//
//
// plans/eco-system-library.md Appendix B.4, C.3, E.4 and Phase 5 step 5.2.
// Shared by ChildProcess.cpp (the `run` kernel, the job table and its
// drains), ChildProcessExports.cpp (the C export) and
// ChildProcessManager.cpp (the `System.Process` effect manager, `spawn`).
//
// Every child, run or spawned, is a JOB in one main-thread T5 registry. The
// job id is the WaitService token (lane WaitLane::EcoSystem), so the single
// EcoSystem-lane drain finds the job of every reaped child.
//
// pendingAsync (keep-alive rule, §3.4): a running non-detached child holds
// one count (`counted`), released exactly once when its exit is processed;
// an armed runDuration timer holds one more, released by the Scheduler when
// it fires or by us when TimerService::cancel removes it (T7 rule).
//
// Templates used: T5 (job table), T7 (kill handles), T2-style drains.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CHILD_PROCESS_CHILD_PROCESS_HPP
#define ECO_SYSTEM_CHILD_PROCESS_CHILD_PROCESS_HPP

#include "eco-system/ChildProcess/Spawn.hpp"
#include "eco-system/Core/Core.hpp"
#include "eco-system/Core/Registry.hpp"

#include <cstdint>
#include <memory>
#include <string>

namespace Eco::System {

struct RunCollector;   // ChildProcess.cpp

enum class JobKind : uint8_t { Run, Spawn };

struct ChildJob {
    JobKind kind = JobKind::Run;
    int64_t pid = -1;

    bool exited = false;          // its exit was popped from the WaitService
    int rawStatus = 0;            // raw waitpid status (valid when exited)
    bool counted = false;         // holds one pendingAsync for the child
    uint64_t resumeToken = 0;     // run: the task's; spawn: the child binding's
    uint64_t timerToken = 0;      // armed runDuration timer, 0 when none / fired
    bool killed = false;          // we sent SIGTERM (timeout, overflow, Process.kill)

    // Run only.
    std::shared_ptr<RunCollector> collector;
    bool outputDone = false;      // the collector posted its final output
    bool overflow = false;        // maxBytes exceeded (E.4)
    bool stopRequested = false;   // the collector was told to stop reading
    std::string out, err;

    // Spawn only: the manager's router and the composed onExit tagger.
    uint64_t routerEnc = 0;
    uint64_t onExitEnc = 0;

    template <typename F>
    void forEachWord(F&& f) {
        f(routerEnc);
        f(onExitEnc);
    }
};

// The job table (main thread only).
Registry<ChildJob>& childJobs();

// Registers the ChildProcess drains (WaitService EcoSystem lane, run
// output) with the eco/system async source. Idempotent; main thread.
void ensureChildDrains();

// Submits job `jobId`'s pid to the WaitService and, when `runDurationMs`
// > 0, arms its runDuration timer. Main thread.
void startJobWatch(int64_t jobId, int64_t runDurationMs);

// Sends SIGTERM to job `jobId`'s child unless its exit was already seen
// (so a recycled pid is never signalled by us), and marks it killed.
void killJob(int64_t jobId);

// Kill-handle cancel function of spawned children (T7): SIGTERMs the child
// owning resume token `token`; returns false (the exit drain decrements).
bool cancelSpawnByToken(uint64_t token);

// `run` (B.4) — the makeAsyncBinding body bound by ChildProcessExports.cpp.
// Payload: tuple3( (program, args), (shell, cwd), (env, (maxBytes,
// runDurationMs)) ), all boxed.
HPointer childProcessRunBody(HPointer captured, HPointer resume);

// Copy-out helpers shared with the manager (G3; no allocation).
bool isElmTrue(HPointer b);
void decodeShell(HPointer shellTuple, SpawnSpec& spec);   // ( Int, String )
void decodeCwd(HPointer cwdTuple, SpawnSpec& spec);       // ( Bool, String )
void decodeEnv(HPointer envTuple, SpawnSpec& spec);       // ( Int, List ( String, String ) )
void decodeProgram(HPointer progTuple, SpawnSpec& spec);  // ( String, List String )

} // namespace Eco::System

#endif // ECO_SYSTEM_CHILD_PROCESS_CHILD_PROCESS_HPP
