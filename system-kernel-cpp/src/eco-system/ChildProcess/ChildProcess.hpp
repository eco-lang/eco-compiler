//===- ChildProcess.hpp - eco/system kernel module ChildProcess (internal) ===//
//
// A child process ends on its own schedule, and the program has to learn when it does: to give a `run` its result,
// to tell the Elm process that stands for a spawned child that the child has ended, and to stop keeping the program
// alive on the child's account. This header is what the ChildProcess files share for that: one table of jobs, the
// drains that move each job forward, the body of the `ChildProcess.run` kernel, and the decoders that copy a child's
// description out of the Elm heap. The `ChildProcess` effect manager, which starts spawned children, is
// ChildProcessManager.hpp.
//
// A *job* is the table entry for one child. A run job belongs to `ChildProcess.run`, which collects the child's
// output and completes its Task once the child has ended. A spawn job belongs to a child the effect manager started.
// A job's id is also the token under which the runtime's `Elm::Platform::WaitService` reports the child's exit, on
// lane `WaitLane::EcoSystem`, so one drain finds the job of every child that exits. A job is erased when it
// completes, and an event that arrives for an id with no job is ignored. A heap reset empties the table, as
// `Registry` describes.
//
// A job may have a *runDuration timer*, a limit in milliseconds on how long its child may run. If the timer expires
// before the child exits, the child is sent SIGTERM. A job is *killed* once this component has decided to end it
// early: for an expired timer, for a run whose output passed its limit, or for `Process.kill`. A killed run fails
// with exit code -1. On Windows no signal is ever sent, so killing a job changes only its result.
//
// Liveness holds are as runtime `platform/Liveness.hpp` defines them. A job whose `hold` is set keeps the program
// alive until the job completes, and the job releases that hold once, when it completes. An armed runDuration timer
// keeps one more hold, keyed by the timer's token, which the Scheduler releases when the timer fires, or
// `Elm::Platform::withdrawParkedTimer` when the job completes first.
//
// Everything declared here must be called on the eco thread, the thread that runs the Elm scheduler.
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

/// The state a run job shares with the thread that collects its child's output. Defined in ChildProcess.cpp.
struct RunCollector;

/// Which kind of child a job is for: `Run`, a child of `ChildProcess.run`, or `Spawn`, a child the `ChildProcess`
/// effect manager started.
enum class JobKind : uint8_t { Run, Spawn };

/// One child's entry in the job table: what is known of the child so far, and what completing its job needs.
///
/// The members marked "run only" or "spawn only" are left at their defaults for the other kind.
struct ChildJob {
    JobKind kind = JobKind::Run;
    int64_t pid = -1;

    bool exited = false;          ///< Set when the WaitService has reported the child's exit, or a failed wait.
    int rawStatus = 0;            ///< The raw wait status, meaningful once `exited` is set and `waitFailed` is not.
    bool waitFailed = false;      ///< The WaitService could not wait for the pid.
    HoldToken hold = kNoHold;     ///< The hold released when the job completes; `kNoHold` when there is none.
    /// The token of the parked resume the job completes: for a run, the run Task's; for a spawn, that of the Elm
    /// process standing for the child, 0 until that process parks.
    uint64_t resumeToken = 0;
    uint64_t timerToken = 0;      ///< The armed runDuration timer's token; 0 when there is none, or it has fired.
    /// The job is killed, as the file comment defines. A run whose `overflow` is set completes as killed whether or
    /// not this is set.
    bool killed = false;

    // Run only.
    std::shared_ptr<RunCollector> collector;
    bool outputDone = false;      ///< The output is in: the collector posted it, or no collector could start.
    bool overflow = false;        ///< A stream passed the output limit; `out` and `err` are cut to the limit.
    bool stopRequested = false;   ///< The collector has been told to stop reading.
    std::string out, err;         ///< The collected stdout and stderr; empty until `outputDone` is set.

    // Spawn only: the manager's router and the composed onExit tagger, as encoded words, 0 when unset.
    uint64_t routerEnc = 0;
    uint64_t onExitEnc = 0;

    /// Calls `f` on each encoded heap word the job holds, as `Registry` requires of an entry.
    template <typename F>
    void forEachWord(F&& f) {
        f(routerEnc);
        f(onExitEnc);
    }
};

/// Returns the job table. It is created on first use and never destroyed.
Registry<ChildJob>& childJobs();

/// Registers, on the first call, the two drains that deliver children's exits and run output to their jobs; later
/// calls do nothing.
void ensureChildDrains();

/// Asks the WaitService to report the exit of job `jobId`'s child and, when `runDurationMs` is positive, arms the
/// job's runDuration timer for that many milliseconds. Watches nothing if there is no job `jobId`.
///
/// Calls `ensureChildDrains`. It may allocate on the Elm heap. It must be called at most once for a job.
void startJobWatch(int64_t jobId, int64_t runDurationMs);

/// Marks job `jobId` killed and sends its child SIGTERM. Does nothing if there is no such job or `waitDrain` has
/// already recorded the child's exit. On Windows it only marks the job.
void killJob(int64_t jobId);

/// Kills, as `killJob` does, the child of the spawn job whose resume token is `token`, if there is one, and
/// returns false.
///
/// It is the `CancelFn` of a spawned child's kill handle. Returning false leaves the hold to the job, which
/// releases it when it completes. It searches the whole table.
bool cancelSpawnByToken(uint64_t token);

/// Runs one `ChildProcess.run`: the `makeAsyncBinding` body that starts a child and completes the Task through
/// `resume` once the child has ended and its output has been collected. Returns the Task's kill handle, or `()`
/// when the Task has already completed.
///
/// `captured` is `( ( program, args ), ( shell, cwd ), ( env, ( maxBytes, runDurationMs ) ) )`, in which `shell`,
/// `cwd` and `env` are the tuples the decoders below take, and `maxBytes` and `runDurationMs` are Ints. The child
/// gets the null device as stdin, and pipes as stdout and stderr.
///
/// The Task fails with the RunErr kind 0 (the child could not be started), with the `errnoName` of the error as
/// its code, when the spawn fails. Otherwise it waits until the child's exit is seen and its output is in. It
/// succeeds with `( stdout, stderr )` as Bytes when the child exited with status 0 and the job was not killed.
/// Otherwise it fails with the RunErr kind 1 (the child ran and did not succeed), an empty code, the output
/// collected, and as exit code the child's exit status, or -1 if the child died of a signal, the job was killed or
/// the wait failed.
///
/// A positive `maxBytes` limits each of stdout and stderr: when either passes it, both are cut to `maxBytes` bytes
/// and the job is killed. A positive `runDurationMs` arms a runDuration timer. If it expires after the child has
/// exited but while the output is still open, as when a process the child started keeps the pipes open, the job is
/// killed without a signal and the collector is told to stop reading. Killing the Task kills the job, unless the
/// exit has already been seen, and the Task then never completes. The job holds the program alive until it completes.
///
/// On Windows the output is never collected, so stdout and stderr are always empty. A C++ exception fails the Task
/// with kind 0 and code "EIO", as `ECO_SYSTEM_ASYNC_GUARD` does for RunErr.
HPointer childProcessRunBody(HPointer captured, HPointer resume);

// Decoders shared with the effect manager. Each copies the Elm value it is given into `spec` and does not allocate
// on the Elm heap, so it leaves the caller's HPointers valid. The value must have the shape named; nothing checks it.

/// Returns whether `b` is the Elm `True` constant.
bool isElmTrue(HPointer b);
/// Sets `spec.shellKind` and `spec.customShell` from `shellTuple`, an Elm `( Int, String )`.
void decodeShell(HPointer shellTuple, SpawnSpec& spec);
/// Sets `spec.inheritCwd` and `spec.cwd` from `cwdTuple`, an Elm `( Bool, String )`.
void decodeCwd(HPointer cwdTuple, SpawnSpec& spec);
/// Sets `spec.envMode` from the Int of `envTuple`, an Elm `( Int, List ( String, String ) )`, and replaces
/// `spec.env` with its pairs.
void decodeEnv(HPointer envTuple, SpawnSpec& spec);
/// Sets `spec.program` and `spec.args` from `progTuple`, an Elm `( String, List String )`.
void decodeProgram(HPointer progTuple, SpawnSpec& spec);

} // namespace Eco::System

#endif // ECO_SYSTEM_CHILD_PROCESS_CHILD_PROCESS_HPP
