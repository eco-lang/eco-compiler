//===- ChildProcessManager.cpp - The C++ effect manager of System.Process -===//
//
// plans/eco-system-library.md §3.6, Appendix C.0 / C.3 and Phase 5 step
// 5.2 ("spawn manager"). Layout: ChildProcessManager.hpp.
//
// For each `Spawn spec onInit onExit` command, in onEffects:
//   1. spawn the child per its connection (Integrated: inherit 0–2;
//      External: three pipes, handed to Elm as FdSink(stdin) and
//      FdSource(stdout, stderr) via the Stream C++ API; Ignored: /dev/null;
//      Detached: /dev/null plus a new session, and no pendingAsync);
//      register its job (router + onExit tagger, encoded, in the T5 job
//      table) and watch it (WaitService lane EcoSystem, runDuration timer);
//   2. create the Elm process that stands for the child:
//      rawSpawn(makeAsyncBinding<childBody>(jobId)). Its binding parks until
//      the child exits; its kill handle (T7) SIGTERMs the child and returns
//      false from the CancelFn, so the exit drain still decrements. The
//      rawSpawn result stays ROOTED until it is delivered (G13);
//   3. Scheduler::drain(), so the binding steps and installs its kill
//      handle before Elm can see the Process.Id (review R1.20);
//   4. onInit ( processId, Just ( stdinId, stdoutId, stderrId ) | Nothing );
//   5. sendToApp + drain() (G12).
//   6. On exit (ChildProcess.cpp completeSpawn): resume the Elm process, then
//      onExit ( exitCode, signal ) + sendToApp + drain().
// A spawn that fails still delivers onInit (a finished process; External
// gets stream ids 0, which read as closed and fail writes), then onExit
// ( -errno, 0 ), like gren's `error` event (node errno codes are negative).
//
// cmdMap composes both taggers (TimeEffectManager composition pattern).
// There are no subscriptions.
//
// Templates used: T6 (manager, rooted registration per G14), T7, T8, G13.
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

// makeAsyncBinding body; payload = the job id (a boxed Int). Parks until the
// child exits (completeSpawn resumes it); the kill handle SIGTERMs the child.
HPointer childBody(HPointer captured, HPointer resume) {
    uint64_t token = 0;
    bool counted = false;   // the job holds the child's count, not this task
    ECO_SYSTEM_ASYNC_GUARD(Never, resume, token, counted,
        int64_t jobId = static_cast<ElmInt*>(Allocator::instance().resolve(captured))->value;
        if (!childJobs().find(jobId)) {
            // Spawn failed, or the child is already gone: finish now.
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

struct SpawnCmd {
    SpawnSpec spec;
    int64_t runDurationMs = 0;
    int64_t connection = CONN_INTEGRATED;
};

// Copies the spec of a Spawn command out of the heap (G3; no allocation).
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

StdioMode stdioFor(int64_t connection) {
    switch (connection) {
        case CONN_EXTERNAL: return StdioMode::Pipes;
        case CONN_IGNORED:
        case CONN_DETACHED: return StdioMode::Null;
        default: return StdioMode::Inherit;
    }
}

// Steps 1–5 for one command. `router`, `onInit`, `onExit` are rooted by the
// caller and re-read through these references after every allocation.
void handleSpawn(HPointer& router, const SpawnCmd& cmd, HPointer& onInit, HPointer& onExit) {
#ifdef _WIN32
    // A Cmd is infallible: crash with a clear message (§1).
    ::Eco::Kernel::reportFatal("eco/system: System.Process.spawn is not supported on Windows yet");
#endif
    auto& s = Scheduler::instance();
    ensureChildDrains();
    const bool detached = cmd.connection == CONN_DETACHED;
    const bool external = cmd.connection == CONN_EXTERNAL;

    // 1. Spawn (POD) and register the job (encoded words only).
    SpawnedChild ch = spawnChild(cmd.spec, stdioFor(cmd.connection), detached);
    int64_t ids[3] = {0, 0, 0};
    int64_t jobId = 0;
    if (ch.err == 0) {
        if (external) {
            ids[0] = createFdSink(ch.stdinFd, /*owns=*/true);
            ids[1] = createFdSource(ch.stdoutFd, /*owns=*/true);
            ids[2] = createFdSource(ch.stderrFd, /*owns=*/true);
        }
        ChildJob job;
        job.kind = JobKind::Spawn;
        job.pid = ch.pid;
        job.routerEnc = enc(router);
        job.onExitEnc = enc(onExit);
        job.counted = !detached;   // Detached does not keep the program alive (E.4)
        jobId = childJobs().insert(std::move(job));
        if (!detached) s.incrementPendingAsync();
        startJobWatch(jobId, cmd.runDurationMs);   // may allocate (timer closure)
    }

    // 2. The Elm process for the child, rooted until delivered (G13).
    HPointer proc = alloc::listNil();
    HPointer streams = alloc::listNil();
    HPointer arg = alloc::listNil();
    HPointer msg = alloc::listNil();
    Elm::StackRootGuard g({&proc, &streams, &arg, &msg});
    proc = s.rawSpawn(makeAsyncBinding<childBody>(alloc::allocInt(jobId)));

    // 3. Step it, so the kill handle is installed before Elm sees the id.
    s.drain();

    // 4. onInit ( processId, Maybe ( stdinId, stdoutId, stderrId ) ).
    if (external) {
        streams = alloc::just(
            alloc::boxed(alloc::tuple3(alloc::unboxedInt(ids[0]), alloc::unboxedInt(ids[1]),
                                       alloc::unboxedInt(ids[2]), 0x15)),
            /*is_boxed=*/true);
    } else {
        streams = alloc::nothing();
    }
    arg = alloc::tuple2(alloc::boxed(proc), alloc::boxed(streams), 0);
    msg = Scheduler::callClosure1(onInit, arg);   // Elm call (G11)

    // 5. Deliver.
    PlatformRuntime::instance().sendToApp(router, msg);
    s.drain();

    if (ch.err != 0) {
        // No child: report the failure as an exit, as gren's `error` event.
        arg = alloc::tuple2(alloc::unboxedInt(-static_cast<int64_t>(ch.err)),
                            alloc::unboxedInt(0), 0x5);
        msg = Scheduler::callClosure1(onExit, arg);
        PlatformRuntime::instance().sendToApp(router, msg);
        s.drain();
    }
}

// --- Manager closures (C.0) ------------------------------------------------------

// init : Task Never ()  (a 0-arity thunk, forced by setupEffects)
void* initEval(void*[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

// onEffects : Router -> List (MyCmd msg) -> List (MySub msg) -> () -> Task Never ()
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
            if (cmd && cmd->ctor == CTOR_SPAWN) {   // no allocation in scope (G5)
                specHP = cmd->values[SPAWN_SPEC_FIELD].p;
                onInit = cmd->values[SPAWN_ON_INIT_FIELD].p;
                onExit = cmd->values[SPAWN_ON_EXIT_FIELD].p;
                isSpawn = true;
            }
        }
        if (isSpawn) {
            SpawnCmd sc;
            decodeSpawnSpec(specHP, sc);   // copy-out, no allocation
            handleSpawn(router, sc, onInit, onExit);
        }
        c.advance();
    }
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(alloc::unit())));
}

// onSelfMsg : Router -> Never -> () -> Task Never ()  (never sent)
void* onSelfMsgEval(void* args[]) {
    return reinterpret_cast<void*>(enc(Scheduler::instance().taskSucceed(dec(args[2]))));
}

// \x -> f (tagger x): args[0] = f, args[1] = tagger, args[2] = x.
void* composedTaggerEval(void* args[]) {
    HPointer f = dec(args[0]);
    HPointer tagger = dec(args[1]);
    HPointer x = dec(args[2]);
    HPointer inner = alloc::listNil();
    Elm::StackRootGuard g({&f, &tagger, &x, &inner});
    inner = Scheduler::callClosure1(tagger, x);         // Elm call (G11)
    return reinterpret_cast<void*>(enc(Scheduler::callClosure1(f, inner)));
}

// Allocates `\x -> f (tagger x)`; captures written right after allocation (G8).
HPointer compose(HPointer& f, HPointer& tagger) {
    HPointer cl = alloc::allocClosure(&composedTaggerEval, 3);
    void* p = Allocator::instance().resolve(cl);
    alloc::closureCapture(p, alloc::boxed(f), PK_Boxed);
    alloc::closureCapture(p, alloc::boxed(tagger), PK_Boxed);
    return cl;
}

// cmdMap : (a -> b) -> MyCmd a -> MyCmd b — compose both taggers.
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

// Allocates the manager closures in the rooted PortRuntime form (G14) and
// registers them under "System.Process". Commands only: no subMap.
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
    PlatformRuntime::instance().registerManager("System.Process", info);   // no allocation after encode
}

} // namespace

extern "C" uint64_t Eco_System_registerManager_System_Process() {
    ECO_KERNEL_GUARD(
        registerProcessManager();
        return enc(alloc::unit());
    )
}
