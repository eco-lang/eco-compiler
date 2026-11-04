//===- ChildProcessManager.cpp - The C++ effect manager of ChildProcess -===//
//
// Each `Spawn` is carried out in five steps, by `handleSpawn`, on the eco thread:
//   1. Start the child. For an External connection, wrap its three pipe ends in streams that own them. Insert a
//      spawn job in the `childJobs()` table, with the router and the onExit tagger as encoded words, and, unless
//      the connection is Detached, a Task hold. Ask for the child's exit to be reported, and arm its runDuration
//      timer if it has one.
//   2. Create the Elm process that stands for the child, running `childBody`, and keep it rooted until it has been
//      handed to onInit.
//   3. Run the scheduler, so that `childBody` parks and installs its kill handle before the program can see the
//      process's id and kill it.
//   4. Apply onInit and send the result to the program, then run the scheduler again.
//   5. If the child could not be started, apply onExit to `( -errno, 0 )` and send that too.
// The rest of a child's life belongs to its job: when the child exits, `ChildProcess.cpp` resumes the Elm process,
// sends the onExit message and releases the job's hold, if it has one.
//
//===----------------------------------------------------------------------===//

#include "eco-system/ChildProcess/ChildProcessManager.hpp"

#include "eco-system/ChildProcess/ChildProcess.hpp"
#include "eco-system/Stream/Stream.hpp"

#include <vector>

namespace Eco::System {

namespace {

using namespace ChildProcessManager;

// --- The Elm process that stands for a spawned child ------------------------

// Runs the Elm process that stands for a spawned child: the `makeAsyncBinding` body whose `captured` is the job id,
// a boxed Int. It parks `resume` under a new token, records the token in the job, and returns a kill handle that
// kills the job as `cancelSpawnByToken` does. If there is no such job, as when the spawn failed, it completes at
// once with `()`. The parked token acquires no hold, since the job holds the program alive.
HPointer childBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(Never, resume, token, counted,
        int64_t jobId = static_cast<ElmInt*>(Allocator::instance().resolve(captured))->value;
        if (!childJobs().find(jobId)) {
            HPointer task = succeedUnit();
            Elm::StackRootGuard g(&task);
            Scheduler::callClosure1(resume, task);
            return alloc::unit();
        }
        token = Scheduler::instance().registerPendingResume(resume);
        childJobs().find(jobId)->resumeToken = token;
        return makeKillHandle(token, &cancelSpawnByToken);
    )
}

// --- Spawning ------------------------------------------------------------------

// A `Spawn` command's spec, copied out of the heap. `connection` is the connection kind as Elm sent it, normally
// one of the `CONN_*` values.
struct SpawnCmd {
    SpawnSpec spec;
    int64_t runDurationMs = 0;
    int64_t connection = CONN_INTEGRATED;
};

// Copies the spec `specHP` of a `Spawn` command into `out`. It does not allocate on the Elm heap.
void decodeSpawnSpec(HPointer specHP, SpawnCmd& out) {
    HPointer progHP, optsHP, tripleHP;
    {
        Tuple3* t = asTuple3(specHP);
        progHP = t->a.p;
        optsHP = t->b.p;
        tripleHP = t->c.p;
    }
    decodeProgram(progHP, out.spec);
    HPointer shellHP, cwdHP;
    {
        Tuple2* t = asTuple2(optsHP);
        shellHP = t->a.p;
        cwdHP = t->b.p;
    }
    decodeShell(shellHP, out.spec);
    decodeCwd(cwdHP, out.spec);
    HPointer envHP;
    {
        Tuple3* t = asTuple3(tripleHP);   // mask SPEC_TRIPLE_MASK
        envHP = t->a.p;
        out.runDurationMs = t->b.i;
        out.connection = t->c.i;
    }
    decodeEnv(envHP, out.spec);
}

// Returns how a child with connection kind `connection` has its stdin, stdout and stderr connected. An unknown kind
// is treated as Integrated.
StdioMode stdioFor(int64_t connection) {
    switch (connection) {
        case CONN_EXTERNAL: return StdioMode::Pipes;
        case CONN_IGNORED:
        case CONN_DETACHED: return StdioMode::Null;
        default: return StdioMode::Inherit;
    }
}

// Carries out one `Spawn` command, `cmd`, in the five steps the file comment lists. `router`, `onInit` and
// `onExit` must be rooted by the caller; they are read through the references after each allocation.
void handleSpawn(HPointer& router, const SpawnCmd& cmd, HPointer& onInit, HPointer& onExit) {
#ifdef _WIN32
    // A Cmd cannot fail, so an unsupported spawn ends the program.
    ::Eco::Kernel::reportFatal("eco/system: ChildProcess.spawn is not supported on Windows yet");
#endif
    auto& s = Scheduler::instance();
    ensureChildDrains();
    const bool detached = cmd.connection == CONN_DETACHED;
    const bool external = cmd.connection == CONN_EXTERNAL;

    // Step 1.
    SpawnedChild ch = spawnChild(cmd.spec, stdioFor(cmd.connection), detached);
    int64_t ids[3] = {0, 0, 0};
    int64_t jobId = 0;
    if (ch.err == 0) {
        if (external) {
            ids[0] = createFdSink(ch.stdinFd, /*owns=*/true, "pipe");
            ids[1] = createFdSource(ch.stdoutFd, /*owns=*/true, "pipe");
            ids[2] = createFdSource(ch.stderrFd, /*owns=*/true, "pipe");
        }
        ChildJob job;
        job.kind = JobKind::Spawn;
        job.pid = ch.pid;
        job.routerEnc = enc(router);
        job.onExitEnc = enc(onExit);
        if (!detached) job.hold = s.acquireHold(HoldKind::Task, "ChildProcess.spawn");
        jobId = childJobs().insert(std::move(job));
        startJobWatch(jobId, cmd.runDurationMs);   // may allocate (timer closure)
    }

    // Step 2.
    HPointer proc = alloc::listNil();
    HPointer streams = alloc::listNil();
    HPointer arg = alloc::listNil();
    HPointer msg = alloc::listNil();
    Elm::StackRootGuard g({&proc, &streams, &arg, &msg});
    proc = s.rawSpawn(makeAsyncBinding<childBody>(alloc::allocInt(jobId)));

    // Step 3.
    s.drain();

    // Step 4.
    if (external) {
        streams = alloc::just(
            alloc::boxed(alloc::tuple3(alloc::unboxedInt(ids[0]), alloc::unboxedInt(ids[1]),
                                       alloc::unboxedInt(ids[2]), 0x15)),
            /*is_boxed=*/true);
    } else {
        streams = alloc::nothing();
    }
    arg = alloc::tuple2(alloc::boxed(proc), alloc::boxed(streams), 0);
    msg = Scheduler::callClosure1(onInit, arg);   // Elm call; may allocate

    PlatformRuntime::instance().sendToApp(router, msg);
    s.drain();

    if (ch.err != 0) {
        // Step 5.
        arg = alloc::tuple2(alloc::unboxedInt(-static_cast<int64_t>(ch.err)),
                            alloc::unboxedInt(0), 0x5);
        msg = Scheduler::callClosure1(onExit, arg);
        PlatformRuntime::instance().sendToApp(router, msg);
        s.drain();
    }
}

// --- Manager closures ------------------------------------------------------------

// Returns the Task `Task.succeed ()`, which gives the manager's initial state `()`; `init : Task Never ()` as a
// closure of no arguments.
void* initEval(void*[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

// Carries out the `Spawn` commands in the list `args[1]` with the router `args[0]`, and returns
// `Task.succeed ()`. Commands with another constructor are skipped. The four arguments are those of
// `onEffects : Router -> List (MyCmd msg) -> List (MySub msg) -> () -> Task Never ()`; the last two are not read.
void* onEffectsEval(void* args[]) {
    HPointer router = dec(args[0]);
    HPointer cmds = dec(args[1]);
    HPointer specHP = alloc::listNil();
    HPointer onInit = alloc::listNil();
    HPointer onExit = alloc::listNil();
    Elm::StackRootGuard g({&router, &cmds, &specHP, &onInit, &onExit});

    alloc::RootedListCursor c(cmds);
    Unboxable head;
    u8 kind;
    while (c.read(head, kind)) {
        bool isSpawn = false;
        {
            Custom* cmd = static_cast<Custom*>(Allocator::instance().resolve(head.p));
            if (cmd && cmd->ctor == CTOR_SPAWN) {   // `cmd` is a raw pointer: nothing in this scope allocates.
                specHP = cmd->values[SPAWN_SPEC_FIELD].p;
                onInit = cmd->values[SPAWN_ON_INIT_FIELD].p;
                onExit = cmd->values[SPAWN_ON_EXIT_FIELD].p;
                isSpawn = true;
            }
        }
        if (isSpawn) {
            SpawnCmd sc;
            decodeSpawnSpec(specHP, sc);
            handleSpawn(router, sc, onInit, onExit);
        }
        c.advance();
    }
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

// Returns `Task.succeed state`, `state` being `args[2]`; `onSelfMsg : Router -> Never -> () -> Task Never ()`.
// The manager sends itself no messages.
void* onSelfMsgEval(void* args[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(dec(args[2]))));
}

// Returns `f (tagger x)`, given `f`, `tagger` and `x` as `args[0]`, `args[1]` and `args[2]`; the evaluator of the
// closures `compose` builds.
void* composedTaggerEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer tagger = dec(args[1]);
    HPointer x = dec(args[2]);
    HPointer inner = alloc::listNil();
    Elm::StackRootGuard g({&f, &tagger, &x, &inner});
    inner = Scheduler::callClosure1(tagger, x);         // Elm call; may allocate
    return reinterpret_cast<void*>(enc(Scheduler::callClosure1(f, inner)));
}

// Returns a new closure `\x -> f (tagger x)`. `f` and `tagger` must be rooted by the caller; they are read after
// the closure is allocated.
HPointer compose(HPointer& f, HPointer& tagger) {
    HPointer cl = alloc::allocClosure(&composedTaggerEval, 3);
    void* p = Allocator::instance().resolve(cl);
    alloc::closureCapture(p, alloc::boxed(f), PK_Boxed);
    alloc::closureCapture(p, alloc::boxed(tagger), PK_Boxed);
    return cl;
}

// Returns the `Spawn` command `args[1]` with `f`, `args[0]`, applied after both its onInit and onExit; a command
// with another constructor is returned as it is. `cmdMap : (a -> b) -> MyCmd a -> MyCmd b`.
void* cmdMapEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer cmd = dec(args[1]);
    HPointer spec = alloc::listNil();
    HPointer onInit = alloc::listNil();
    HPointer onExit = alloc::listNil();
    HPointer newInit = alloc::listNil();
    HPointer newExit = alloc::listNil();
    Elm::StackRootGuard g({&f, &cmd, &spec, &onInit, &onExit, &newInit, &newExit});
    {
        Custom* c = static_cast<Custom*>(Allocator::instance().resolve(cmd));
        if (!c || c->ctor != CTOR_SPAWN) return args[1];
        spec = c->values[SPAWN_SPEC_FIELD].p;
        onInit = c->values[SPAWN_ON_INIT_FIELD].p;
        onExit = c->values[SPAWN_ON_EXIT_FIELD].p;
    }
    newInit = compose(f, onInit);
    newExit = compose(f, onExit);
    std::vector<Unboxable> fields{alloc::boxed(spec), alloc::boxed(newInit), alloc::boxed(newExit)};
    return reinterpret_cast<void*>(enc(alloc::custom(CTOR_SPAWN, fields, 0)));
}

} // namespace

} // namespace Eco::System

using namespace Eco::System;

namespace {

// Registers the manager's closures under "ChildProcess". The closures are rooted while they are allocated and
// encoded only after the last allocation. subMap is `[]`, since the manager has no subscriptions.
void registerProcessManager() {
    HPointer initCl = alloc::listNil();
    HPointer effCl = alloc::listNil();
    HPointer selfCl = alloc::listNil();
    HPointer cmdMapCl = alloc::listNil();
    HPointer subMapCl = alloc::listNil();
    Elm::StackRootGuard g({&initCl, &effCl, &selfCl, &cmdMapCl, &subMapCl});
    initCl = alloc::allocClosure(&initEval, 0);
    effCl = alloc::allocClosure(&onEffectsEval, 4);
    selfCl = alloc::allocClosure(&onSelfMsgEval, 3);
    cmdMapCl = alloc::allocClosure(&cmdMapEval, 2);
    PlatformRuntime::ManagerInfo info{enc(initCl), enc(effCl), enc(selfCl),
                                      enc(cmdMapCl), enc(subMapCl)};
    PlatformRuntime::instance().registerManager("ChildProcess", info);   // no allocation after encode
}

} // namespace

extern "C" uint64_t Eco_System_registerManager_ChildProcess() {
    ECO_KERNEL_GUARD(
        registerProcessManager();
        return enc(alloc::unit());
    )
}
