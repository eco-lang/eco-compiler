# Runtime Tests

The allocator, collector and platform services are tested in layers, each aimed at a class of bug the layer before it cannot see. Property tests build random heaps on the real allocator, with the nursery production uses, and check that collection preserves every reachable value. Standalone harnesses compile the real allocator under ThreadSanitizer, a tool that reports memory accesses from two threads with nothing ordering them. GenMC, a model checker for small C and C++ programs under weak memory ordering, checks the memory orders of the lock-free code on the real headers. Guard tests replay every recorded concurrency defect so that none can return unnoticed. The formal models are the specification all of these check the code against, and a hash check on the allocator sources warns when the code the models describe changes. The platform services, which are process-wide and start their own threads, are tested only in spawned child processes.

## Each tool sees what the last one misses

Every tool in this layer misses some class of bug, and the next tool is there to catch it. Ordinary tests check results but almost never produce a rare thread schedule. ThreadSanitizer finds unordered accesses under load, but it reasons only about the orderings it can observe on the test machine. The formal models explore every schedule, but they assume that all threads see memory writes in one global order, which real hardware does not promise. GenMC covers that gap, exploring every ordering the C++ memory model allows, but only for small pieces of code. The defect guards then replay each recorded fault, so a defect that one of the other tools found cannot return unnoticed.

| Layer | Catches | Misses |
|---|---|---|
| Property tests on generated heaps | Values lost, moved wrongly or corrupted by a collection; broken layout rules | Races between threads |
| ThreadSanitizer harnesses | Unordered accesses between threads on the real allocator | Bugs that need a weaker memory order than the test machine shows |
| GenMC drivers | Wrong memory orders in small lock-free protocols | Code too large or too loop-shaped for GenMC to run |
| Defect guards | The return of any recorded concurrency defect | Defects nobody has recorded |
| Platform tests | Scheduler, timer, process-wait and liveness logic | Collector behavior |

The layers are not independent. They all build the same allocator headers, and the hash check pins those headers to the formal models, so one change to the allocator touches every layer at once.

## Property tests on the real heap

Most runtime unit tests are properties: a stated fact that must hold for every input, tried on many generated inputs with the RapidCheck library. The typical property allocates a random graph of heap objects, makes it reachable from a root, runs minor or major collections, and compares a snapshot of the reachable graph before and after. Heap layout is a combinatorial space of object kinds, unboxed-field bitmaps and shapes, and hand-written cases cover little of it. The snapshot is the oracle for "the collector preserved the logical heap", so the tests check the heap layout rules directly, without a separate model of the heap.

These suites are compiled into the one test executable that also runs the codegen and whole-program tests. A test helper resets the single allocator object with a given heap configuration before each suite. A failed assertion throws, and the runner catches it, so one failure does not end the run. The address space is reserved once, on first use, with the default configuration, and every later configuration fits inside it, so results do not depend on the order or filter the tests run with.

The tests run the region nursery, which is the one production uses; the runtime also keeps a legacy semi-space nursery. The default way to initialize the allocator in a test gives the region nursery, and the legacy one is reachable only through a separately named helper. A single function builds the heap configuration from the environment for every test child, and a whole-program or JIT child refuses to run on any nursery but the region one unless the environment explicitly asks for legacy. This structure answers a specific failure: in-process unit tests can leave the legacy nursery in the allocator object, a child that inherits that object runs on it, and the whole-program run then tests a minor collector that no user runs. Making the shipped nursery the default and asserting it removes that failure.

Some heap rules are checked by assertions compiled into the runtime rather than by the tests themselves. A validate build adds detection of stale heap pointers, integrity walks after each collection, assertions on forwarding depth and audits of the old generation. These are too slow for production, so they are off there. The ThreadSanitizer harnesses and the full defect-guard run build with validation on, so a test that merely runs the collector there also runs every check the validate build contains.

## Every case in its own process

Every isolated test case, and every whole-program test, runs as a freshly spawned child of the test executable and reports through a result record in a mapped file. A crash, a hang past the timeout or an early exit therefore fails one test, and the child inherits nothing of the parent's heap, collector threads or global objects. The suites that need this are the ones that start process-wide services or abort on purpose: the platform services and spawn tests, the crash tests, and the large-body and memory-pressure tests. They are built in one function, so a child can rebuild exactly the suite it was asked to run.

Children are spawned, not forked, because a fork copies a live multi-threaded process. Heap configuration, address reservation, stale collector threads and global objects all arrive in the child. A forked child inherits whatever nursery in-process unit tests left behind, and has to reset its way back to a clean state. A serial in-process fallback on Windows does not work either, because one crash ends the whole suite and nothing enforces a timeout. Spawning gives Windows the same parallel, timeout-killed isolation that POSIX has.

Tests whose subject is fork itself do call fork, because embedders may fork a process that runs Eco and the runtime keeps a contract for that case. They run only on POSIX systems.

## Platform services and liveness holds

The platform tests cover the scheduler and the process-wide services:

- the scheduler's quiescence hook, which runs when the program has nothing left to do, fires once per arming and never when Eco is embedded in a host;
- timers can be canceled;
- the wait service, which reaps finished child processes, reports each one's signal and exit code on the right lane;
- liveness holds behave as the rule below requires;
- the shared primitive for spawning processes works.

A liveness hold is a counted claim that keeps the program running while some work is outstanding, such as a sleep, an HTTP request or a timer; [scheduler-and-services.md](../runtime/scheduler-and-services.md) calls it a hold. The rule behind it cuts across every kernel: a program stays alive only while it waits for something. Every kernel site that waits on outstanding work takes a hold rather than keeping a counter by hand. The tests check that a hold is released once and a double release aborts, that holds can be parked and resumed, that holds from several host threads work together, and that canceling or killing the work drops its hold.

These tests never run in the runner process. The services are single process-wide objects with detached threads, and the wait service reaps with a call that collects any child of the process, which would steal the runner's own test children. Much of the coverage is POSIX-only, and Windows skips those cases rather than faking them.

## ThreadSanitizer on the real allocator

The heap-level harness compiles every allocator source file under ThreadSanitizer, with validation, statistics and assertions on. Only the stack-unwinding code is replaced by a stub, and the driver registers all its roots directly. The driver acts as a mutator in place of a compiled Elm program: it keeps an old object graph and a churning set of young, large and replaced values, and it forces a mark cycle regularly with background marking threads, so marking, promotion and helper work overlap. The default run covers each collector mode and passes only with the driver's pass line and zero ThreadSanitizer warnings.

The harness runs the real allocator because ThreadSanitizer finds data races, the class of undefined behavior in C++ that the formal models cannot express at all. A model of the allocator would show only races in the model, and the whole allocator links on its own with one stub, so the heap-level harness checks the production code itself. Smaller standalone harnesses cover fast stress runs on two pieces that include nothing from the allocator, the helper thread pool and the page-work code. They check:

- the helper pool's protocol;
- that an address range is free while it is being discarded and not free while it is being populated, over fake operations and over real memory-mapping calls;
- rapid sequences of mark episodes, background work and parallel minor forwarding.

ThreadSanitizer is built with g++ only, because the repository's clang has no ThreadSanitizer runtime. That toolchain fact is why these harnesses are standalone builds rather than targets of the main build.

### Deterministic arms

A deterministic arm forces one interleaving that is known to matter, so a race shows on every run instead of one run in a million. Two plain threads take turns, ordered only by relaxed atomic flags. A relaxed atomic guarantees nothing about ordering beyond its own value, so ThreadSanitizer derives no happens-before edge from it, happens-before being the relation it uses to decide that two accesses are ordered. A mutex or an acquire and release pair would add edges of their own and hide the very race the arm exists to show. With relaxed flags, the only ordering ThreadSanitizer sees is the runtime's own.

```cpp
// ... RELAXED atomics only: TSan derives
// no happens-before edge from a relaxed store/load pair, so ordering two
// threads with these leaves every unsynchronised access pair visible to it.
// Workers never print, assert or take a std::mutex (each would add an edge).
...
namespace det {
inline void waitFor(std::atomic<int>& s, int v) {
    while (s.load(std::memory_order_relaxed) < v) std::this_thread::yield();
}
inline void post(std::atomic<int>& s, int v) { s.store(v, std::memory_order_relaxed); }
// Exit codes of the deterministic arms (TSan turns a run with a report into 66).
constexpr int kClean = 0;
constexpr int kNotReached = 3;
}  // namespace det
```

Source: `test/gc-heap-tsan/DetHandshake.hpp`, trimmed.

The threads are forced into one interleaving without any synchronization, which is the opposite of what a test harness usually does. The workers do not even print or assert, since either could take a lock. The exit codes say what happened: 0 for a clean run, 3 when the arm never reached the interleaving it was built for, so it cannot pass by accident, and 66 when ThreadSanitizer reported a race.

The same sources also build trace harnesses, whose logs a model checker compares against the formal models. A trace build and a ThreadSanitizer build are never the same binary, because the trace's global sequence counter adds happens-before edges that would hide races ([concurrency-models.md](concurrency-models.md) describes trace validation).

The fork harness is not under ThreadSanitizer, because ThreadSanitizer does not support fork in a threaded process. It tests the fork contract with forks from the mutator, forks from host threads, and forks during the window in which the collector's helpers are closing down.

## GenMC on the real headers

GenMC is there because the formal models and ThreadSanitizer both miss one class of bug. The model checker for the formal models assumes sequential consistency, in which all threads see writes in one order. ThreadSanitizer ignores standalone fences, so it reports false races on the work-stealing deque that marking threads take work from. GenMC explores every execution of a small bounded program that RC11, a repaired form of the C11 memory model, allows. This matters most on ARM, where a relaxed atomic really can be seen out of order.

The drivers compile the real, unmodified allocator headers: the work-stealing deque, termination detection, the writers of mark bytes, block publication, and the claim and copy of forwarding. A separate copy of the headers written for GenMC could drift from the code, so none is kept. GenMC's own compile step cannot handle the C++ standard library headers, so the runner compiles each driver with an ordinary compiler and hands GenMC the LLVM IR.

Every row in the driver list states its expected outcome: a pass, a race on a named variable, or a named failed assertion.

```text
# name  file  options  expected
...
w1_deque                 w1_deque.cpp        -                                                   pass
w1_deque_2thieves        w1_deque.cpp        W1_THIEVES=2                                        pass
...
W1_NO_TAKE_FENCE         w1_deque.cpp        W1_THIEVES=2,mutate:W1_NO_TAKE_FENCE                assert:n == 1
# review R3: with ONE thief the last element is always CASed, so the missing fence cannot show
w1_no_take_fence_1thief  w1_deque.cpp        mutate:W1_NO_TAKE_FENCE                             pass
W1_RELAXED_PUBLISH       w1_deque.cpp        mutate:W1_RELAXED_PUBLISH                           race:payload | assert:n == 1
```

Source: `test/genmc/drivers.txt`, trimmed.

A row whose options include `mutate:` runs a deliberately weakened copy of the header and names the exact failure GenMC must find. The same weakening can be expected to pass under a smaller configuration, where it cannot show, and the reason is written beside the row.

Spin loops cannot run under GenMC, because a loop that waits for another thread has no bound. The drivers replace a spinning lock with one attempt under an assumption, and a waiting loop with a straight-line copy of one round. The pause, yield, sleep and spin-lock functions themselves therefore stay outside what GenMC checks.

## Every checker can fail

A check that cannot fail proves nothing, so every checker in this layer is shown to fail on broken code. A GenMC mutant is a small text edit to a copy of a header that weakens one memory order. Each edit must match its pattern exactly once, and GenMC must flag the result; a mutant that passes, or fails some other way, fails the whole check. The exactly-once rule keeps a mutant whose pattern stops matching from silently becoming the unmutated code. Guard tests assert their precondition and report "not reached" rather than pass when their scenario does not set up. A GenMC target run without GenMC installed fails loudly instead of skipping.

Concurrency defects found in the collector are recorded in a register, and each entry gets a guard test that fails on the faulty code. While the defect is open, its guard is an expected failure. Once it is fixed, the guard becomes a regression guard, and the faulty shape of the code is kept as a model variant or a GenMC mutant. An expected failure that starts passing fails the run, so a defect cannot disappear unnoticed either. Each guard is checked by reverting its fix and watching it fail.

Two kinds of register entry keep a guard with no live defect behind it. A second live mutator in one process is a won't-fix. The runtime aborts when a second mutator starts, and only a test-only opt-in in the allocator lifts that abort, so the race exists only in test harnesses; its arms stay as rows recorded as won't-fix. A race in sweeping young large objects is retired, because those objects live in large-object blocks that are never swept; its arm stays as a row that records the route as unreachable rather than being deleted.

## What runs when

The heavy tiers are opt-in. The full guard run forks, aborts by design and runs for minutes, GenMC needs an extra container image layer, and ThreadSanitizer needs g++. So GenMC, the full guard run and the ThreadSanitizer builds stay out of the everyday `check` and `full` targets and out of continuous integration. The unit guards are the exception: they are linked into the main test executable, so every `check`, `full` and continuous integration run includes them.

The hash check, called the canary, is what ties the opt-in tiers to the code. It runs in every build and compares hashes of the allocator files that the formal models and GenMC drivers describe, including the driver list itself, against recorded pins. A mismatch warns by default, and a build setting makes it fail the build. Either way it names the models to re-audit. Because the canary pins the drivers, an edit to a pinned header raises it even when nobody ran GenMC: the checker is opt-in, but its pinning is not.

## Outside the heap

Two checks cover runtime code outside the collector, and both run in the smoke stage of the static-build container. The runtime replaces the C library's memory copy, move, set and compare functions, and a wrong size or alignment there would corrupt everything silently. A checker therefore compares them with plain byte-by-byte versions at every size up to a kilobyte and many misalignments, with guard bytes around each buffer, linked ahead of the C library. Small C and Node hosts exercise the embedding interface in the same stage.

## Tests and the heap rules

An uncited heap rule is not necessarily untested. Citing a rule's number in a test is a convention, not a requirement, and fewer than half of the heap rules are cited anywhere in these directories. Several uncited rules are tested under another name, such as those for chunked lists, so read an uncited rule as unchecked only after looking. The tests cover heap rules from object kind words and the nursery's regions to incremental, parallel and concurrent marking.

One rule covers the collector's determinism: its decisions never depend on how far its helper threads have got. Tests compare counters across helper modes, and jitter settings perturb the helpers' schedule to show that the counters still agree.

## Examples of changes that fit the theory
A change fits when it adds a check at the layer that can see its bug, runs it on the shipped configuration, and shows that the check can fail.

- An added heap object kind or layout rule gets a generator and a survival property of the existing shape (allocate, root, collect minor and major, compare snapshots), runs on the default region nursery, and cites the rule.
- An added collector mode or setting gets a unit suite, a scenario in the ThreadSanitizer driver so races in it are visible, and an environment route through the one function that builds test configurations.
- A found concurrency defect gets a deterministic arm with two threads ordered by relaxed flags, a reached check and an expected-failure row, plus a unit guard. When it is fixed, the row flips, the faulty shape becomes a mutant, and the guard is revert-checked.
- A change to a lock-free protocol or a memory order gets a GenMC driver over the real header, with a mutant for each order it relies on, and the file joins the canary's pins.
- An added platform service or kernel hold gets a case in an isolated suite, marked POSIX-only where it is, that checks cancel and kill release the hold.
- A test that must run in its own process is registered with the isolated suites, not the in-process ones.

## Examples of changes that would break the theory
A change breaks the theory when it makes a check quieter without making the code more correct.

- Switching a test, or the whole run, to the legacy nursery to make it pass. The run then tests a collector users never run; use the legacy helper only where the legacy nursery is the subject, or fix the region path.
- Ordering a deterministic arm with a mutex or acquire and release to stop flakiness. That removes the race under test; keep the relaxed flags, or move the check to GenMC.
- Silencing a ThreadSanitizer report with a suppression or a compiler flag. The race stays in the code; make the access atomic or ordered instead.
- Updating a canary hash to quiet the build. The hash exists to force a re-audit; re-audit the models it names and record the verdicts first.
- Letting a guard pass vacuously, by not asserting its precondition or by allowing a mutant to pass. Such a guard proves nothing; assert the precondition and require the flag.
- Running the platform services in the runner process, or adding a forked child to the harness. Either brings back inherited state and stolen children; spawning is the one path, and direct fork is only for tests whose subject is fork.
- Putting a workaround into allocator code that only ThreadSanitizer needs. Production then carries code it does not need; change the driver or stub the harness instead.
- Skipping the opt-in tiers for collector concurrency work. The everyday targets cannot see those bugs, so any allocator change that touches atomics, locks, fork hooks or helper jobs runs GenMC, the guards and the default ThreadSanitizer run.

## References

Parent: [verification.md](verification.md). Related: [concurrency-models.md](concurrency-models.md) for the formal models and the canary.

- `test/main.cpp`: suite registration, `buildIsolatedSuites`, isolated-child dispatch, flags (`--filter`, `--list`, `--seed`).
- `test/allocator/TestHelpers.cpp`, `test/allocator/TestHelpers.hpp`: `initAllocator`, `initLegacyAllocator`, `environmentConfig`.
- `test/allocator/HeapGenerators.cpp`, `test/allocator/HeapSnapshot.hpp`, `test/allocator/HeapHelpersTest.cpp`, `test/allocator/AllocatorTest.cpp`: generators, the graph oracle and example properties.
- `test/allocator/ConcurrencyRegisterTest.cpp`: the defect guards (`runXfailGuard`, `runFixedGuard`).
- `test/allocator/ChunkedListTest.cpp`: rules tested without citing their numbers.
- `test/IsolatedTestRunner.hpp`, `test/SpawnedChildren.hpp`, `test/RegionNurseryGuard.hpp`: spawned children and the nursery check.
- `test/platform/PlatformServicesTest.cpp`, `test/platform/SpawnTest.cpp`: platform and liveness-hold tests. Comments in `test/platform/PlatformServicesTest.hpp` and `test/main.cpp` call the isolated suites fork-based; the code spawns.
- `test/gc-heap-tsan/README.md`, `heap_driver.cpp`, `DetHandshake.hpp`, `fork_harness.cpp`, `fork_arms.txt`, `run_fork_arms.py`: heap-level ThreadSanitizer, deterministic arms, the fork harness and trace builds (`ECO_TLA_TRACE`). Where the README and `fork_arms.txt` disagree on an arm's status, `fork_arms.txt` is right.
- `test/gc-helper-tsan/README.md`: helper-pool and page-work harnesses.
- `test/genmc/AUDIT.md`, `drivers.txt`, `wdriver.hpp`, `mutate.sh`, `run_drivers.py`: GenMC drivers and mutants; target `genmc-check`; `docker/eco-dev-genmc.Dockerfile`. The row count and canary status in the header of `AUDIT.md` are out of date.
- `test/scripts/run_register_guards.sh`: target `register-guards`.
- `test/memfuncs/memfuncs_check.c`, `test/embed/`, `docker/static-build.Dockerfile`: the memory-function checker and the embedding hosts.
- `test/win32/getopt.h`: argument parsing for the test executable on Windows.
- `CMakeLists.txt`: `ECO_HEAP_VALIDATE`, `tla-canary` (strict mode `ECO_TLA_CANARY_STRICT`), `register-guards`.
- `test/tla/README.md`: the formal models and the canary.
- `docs/testing.md` does not describe the ThreadSanitizer, GenMC or guard tiers; the READMEs under `test/` do.
- `design_docs/invariants.csv`: the heap rules (HEAP_*), HEAP_082 (tests run the region nursery), HEAP_007 and HEAP_075 (fork contract and one mutator), HEAP_080 (young large objects are never swept), SYS_008 (spawned test children), GC_DET_001 (determinism), LIVE_* (liveness holds).
- `test/tla/README.md` "The canary": the canary rule (investigate the named model before touching a canary hash).
