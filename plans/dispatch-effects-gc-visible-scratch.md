# Make dispatchEffects GC-safe via runtime-owned scratch state

## Problem

`PlatformRuntime::dispatchEffects(cmdBag, subBag)` currently stashes live
encoded `HPointer`s in unrooted C++ locals:

- `runtime/src/platform/PlatformRuntime.cpp:219` — the per-manager effects
  map is a stack `std::unordered_map<std::string,
  std::pair<std::vector<uint64_t>, std::vector<uint64_t>>>` built up by
  `gatherEffects`. The GC has no visibility into it.
- `runtime/src/platform/PlatformRuntime.cpp:202` — `enqueueEffects` copies the
  front `FxBatch` out of `effectsQueue_` into a stack local, then erases it
  from the queue before calling `dispatchEffects`. During that call, the
  two bag HPointers exist *only* in the `dispatchEffects` stack frame.
- `runtime/src/platform/PlatformRuntime.cpp:241-248` — the per-manager
  `cmdList`/`subList` are built with a manual `cons(boxed(decodeHP(*rit)),
  cmdList, true)` loop, with the accumulator unrooted and the remaining
  `rit` slots also unrooted.

Any GC triggered by `cons()`, `Scheduler::callClosure4`, or the drained Task
can evacuate those HPointers. The C++ locals keep the stale pre-evacuation
bits and `Allocator::resolve` then trips `hdr->tag < Tag_Forward` (or silently
reads a stale object).

## Goal

All HPointers that must survive across `gatherEffects`, `onEffects`, and
`drain()` are stored in GC-visible `PlatformRuntime` member fields. GC
visibility comes entirely from the existing external-root-scanner lambda
registered in the constructor (`PlatformRuntime.cpp:67-103`), which already
traces `effectsQueue_`, `managers_`, `managerStates_`, `sendToAppClosure_`,
and `modelStorage_`. We extend that scanner rather than adding a new one.

No public API changes (`enqueueEffects`, `sendToApp`, `setupEffects`,
`initWorker` signatures are unchanged).

## Plan

### 1. Extend `PlatformRuntime` state

File: `runtime/src/platform/PlatformRuntime.hpp`

Add, in the private section:

```cpp
struct PerManagerEffects {
    std::vector<uint64_t> cmdHPs;  // encoded HPointers (Cmd msg values)
    std::vector<uint64_t> subHPs;  // encoded HPointers (Sub msg values)
};

std::unordered_map<std::string, PerManagerEffects> effectsScratch_;
FxBatch activeBatch_{0, 0};
bool dispatchActive_ = false;
```

Change:

```cpp
// old
void dispatchEffects(HPointer cmdBag, HPointer subBag);
void gatherEffects(bool isCmd, HPointer bag,
                   std::unordered_map<std::string,
                       std::pair<std::vector<uint64_t>,
                                 std::vector<uint64_t>>>& effects,
                   HPointer taggers);

// new
void dispatchEffects();                  // reads activeBatch_
void gatherEffects(bool isCmd, HPointer bag,
                   std::unordered_map<std::string, PerManagerEffects>& effects,
                   HPointer taggers);
```

### 2. Extend the existing external root scanner

File: `runtime/src/platform/PlatformRuntime.cpp` (constructor lambda at
`PlatformRuntime.cpp:67-103`). After the existing
`effectsQueue_` loop, append:

```cpp
// Currently-dispatching batch + per-manager scratch, live only while
// dispatchEffects is on the stack.
if (dispatchActive_) {
    evacuate(activeBatch_.cmdBag);
    evacuate(activeBatch_.subBag);
    for (auto& [home, per] : effectsScratch_) {
        for (auto& enc : per.cmdHPs) evacuate(enc);
        for (auto& enc : per.subHPs) evacuate(enc);
    }
}
```

(No new `addExternalRootScanner` call is needed — the constructor already
registers exactly one.)

### 3. Restructure `enqueueEffects`

File: `runtime/src/platform/PlatformRuntime.cpp` (`enqueueEffects` at line
195).

Move the front `FxBatch` into `activeBatch_` *before* erasing it from the
queue, set `dispatchActive_` for the duration of the call, and clear the
scratch between batches:

```cpp
void PlatformRuntime::enqueueEffects(HPointer cmdBag, HPointer subBag) {
    effectsQueue_.push_back({encodeHP(cmdBag), encodeHP(subBag)});

    if (effectsActive_) return;
    effectsActive_ = true;

    while (!effectsQueue_.empty()) {
        activeBatch_ = effectsQueue_.front();
        effectsQueue_.erase(effectsQueue_.begin());

        dispatchActive_ = true;
        dispatchEffects();           // reads activeBatch_
        dispatchActive_ = false;

        effectsScratch_.clear();     // release per-batch scratch
        activeBatch_ = FxBatch{0, 0};
    }

    effectsActive_ = false;
}
```

Key invariant: between the `erase` and the `dispatchActive_ = false`, the
two bag HPointers live only in `activeBatch_`, which the scanner visits.

### 4. Rewrite `dispatchEffects`

File: `runtime/src/platform/PlatformRuntime.cpp` (`dispatchEffects` at
line 210).

```cpp
void PlatformRuntime::dispatchEffects() {
    if (managers_.empty()) return;

    HPointer cmdBag = decodeHP(activeBatch_.cmdBag);
    HPointer subBag = decodeHP(activeBatch_.subBag);

    effectsScratch_.clear();
    for (auto& [home, _] : managers_) {
        effectsScratch_[home];   // default-constructs PerManagerEffects
    }

    HPointer nilTaggers = listNil();
    gatherEffects(true,  cmdBag, effectsScratch_, nilTaggers);
    gatherEffects(false, subBag, effectsScratch_, nilTaggers);

    auto& sched = Scheduler::instance();
    for (auto& [home, per] : effectsScratch_) {
        auto msIt = managerStates_.find(home);
        if (msIt == managerStates_.end()) continue;
        auto miIt = managers_.find(home);
        if (miIt == managers_.end()) continue;

        auto& ms = msIt->second;
        HPointer onEffectsFn = decodeHP(miIt->second.onEffects);
        if (alloc::isNil(onEffectsFn) || hpIsConstant(onEffectsFn)) continue;

        // Build cmd/sub Elm lists via the GC-safe helper.
        // See §5 for the uint64_t→HPointer bridge.
        HPointer cmdList = listFromEncoded(per.cmdHPs);
        HPointer subList = listFromEncoded(per.subHPs);

        // Re-resolve manager closures *after* list construction, in case
        // GC moved them; managers_/managerStates_ are both rooted.
        HPointer router = decodeHP(msIt->second.router);
        HPointer state  = decodeHP(msIt->second.state);
        HPointer fn     = decodeHP(miIt->second.onEffects);

        HPointer newStateTask = Scheduler::callClosure4(
            fn, router, cmdList, subList, state);

        HPointer effectProc = sched.rawSpawn(newStateTask);
        u32 procId = static_cast<u32>(
            static_cast<Process*>(resolveHP(effectProc))->id);
        sched.drain();

        HPointer latestProc = sched.latestProcessById(procId);
        void* procPtr = resolveHP(latestProc);
        if (procPtr) {
            Process* proc = static_cast<Process*>(procPtr);
            void* rootPtr = resolveHP(proc->root);
            if (rootPtr) {
                Task* rootTask = static_cast<Task*>(rootPtr);
                if (rootTask->ctor == Task_Succeed) {
                    ms.state = encodeHP(rootTask->value);
                }
            }
        }
    }
}
```

Notable change vs. current code: we drop the manual
`for (... rbegin .. rend) cmdList = cons(...)` loop (which is itself
unrooted and unsafe) in favor of `listFromPointers`, which pushes all
entries plus the accumulator as a stack root range (see
`allocator/HeapHelpers.hpp:505-519`).

### 5. uint64_t → HPointer conversion for `listFromPointers`

`listFromPointers` takes `const std::vector<HPointer>&`. Our scratch is
`std::vector<uint64_t>` (matches `FxBatch`, `ManagerState`, and every other
encoded-HPointer field in `PlatformRuntime`, and matches the
`EvacuateFn(uint64_t&)` signature).

`reinterpret_cast<std::vector<HPointer>*>(&vec_of_uint64)` is undefined
behavior — `std::vector<T>` is not type-punnable across `T`. Use a small
bridge that decodes into a temporary:

```cpp
// In PlatformRuntime.cpp (static helper, file-local).
static HPointer listFromEncoded(const std::vector<uint64_t>& encoded) {
    std::vector<HPointer> decoded;
    decoded.reserve(encoded.size());
    for (uint64_t e : encoded) decoded.push_back(decodeHP(e));
    return alloc::listFromPointers(decoded);
}
```

`push_back` into a `std::vector` is a host-allocator operation and never
runs the Elm GC, so the conversion loop is itself safe. `listFromPointers`
then roots both the result accumulator and the copy it takes internally.
Meanwhile `per.cmdHPs` stays rooted via the external scanner, so if GC
fires mid-build, both copies are evacuated consistently.

### 6. Refit `gatherEffects`

File: `runtime/src/platform/PlatformRuntime.cpp` (`gatherEffects` at
line 286). Replace the `it->second.first.push_back(...)` /
`it->second.second.push_back(...)` pair with:

```cpp
auto it = effects.find(home);
if (it != effects.end()) {
    if (isCmd) it->second.cmdHPs.push_back(encodeHP(taggedValue));
    else       it->second.subHPs.push_back(encodeHP(taggedValue));
}
```

The rest of `gatherEffects` (Fx_Leaf / Fx_Node / Fx_Map walking, tagger
list, recursion) is unchanged.

### 7. Update theory doc

File: `design_docs/theory/platform_scheduler_theory.md:190-205`.

Add a short paragraph on the rooting discipline: `effectsQueue_` is a GC
root always; `activeBatch_` + `effectsScratch_` become GC roots while
`dispatchActive_` is true; the external root scanner registered by
`PlatformRuntime` covers all of them. Note that `listFromPointers` is the
only supported way to build the per-manager Cmd/Sub lists.

### 8. Tests

- Re-run the existing stress test that previously trips
  `Allocator::resolve`'s `hdr->tag < Tag_Forward` assertion in the Task
  manager's `onEffects`; it should no longer crash.
- Add (or extend) a test that forces minor GC between `gatherEffects` and
  the per-manager `onEffects` call — e.g. an Elm program that allocates
  heavily inside a Task continuation while several `Cmd` batches are in
  flight. I'll check what already exists under
  `compiler/tests/` / `test/` for platform/effect-manager stress before
  writing anything new.
- Targeted unit test (C++ / gtest if that's the style here — needs
  confirmation) that constructs a `PlatformRuntime` with a dummy manager,
  forces `dispatchActive_ = true` with non-empty `effectsScratch_`, invokes
  GC, and asserts the encoded HPointers in `effectsScratch_` have been
  evacuated (tag is still valid).

### 9. Commit-message note

The diff also silently fixes a second latent GC bug: the manual
`cons(boxed(decodeHP(*rit)), cmdList, true)` loop at
`PlatformRuntime.cpp:241-248` runs with an unrooted accumulator and
unrooted un-consumed `*rit` slots. Minor GC during `cons` would lose
those references. Replacing the loop with `listFromPointers` (which
registers both the accumulator and each element as stack roots —
`allocator/HeapHelpers.hpp:510-517`) fixes that bug. Reviewers will not
see a standalone test for it, so call it out explicitly in the commit
body as "also fixes unrooted accumulator in per-manager list build".

## Resolved Decisions

All open items from the first round have been confirmed:

1. **Invariants.** No rule forbids the same logical value appearing in
   multiple GC roots. `EvacuateFn` is idempotent, so duplicate scanning
   (e.g. `modelStorage_` visited both as a JIT root and via our scanner,
   or a value that briefly appears in both `effectsQueue_` and
   `activeBatch_` — which our design avoids anyway by erasing before
   assigning) is safe.

2. **Re-entrant `enqueueEffects`.** `effectsActive_` already serializes
   dispatch; nested `enqueueEffects` calls during `dispatchEffects` land
   on `effectsQueue_` and are picked up by the outer `while` loop. The
   new design preserves this.

3. **Re-reading from rooted maps.** Keeping `router` / `state` /
   `onEffects` in the rooted `managerStates_` / `managers_` maps and
   re-reading via `decodeHP` on each use is the correct pattern. No
   `StackRootGuard` wrappers needed.

4. **Inline scanner lambda.** Leave it inline in the constructor —
   semantically equivalent to a member method, less churn.

5. **`erase(begin())`.** Correct for GC; O(n) is a perf concern, not a
   correctness one. Not in scope for this change; file as a follow-up
   if it shows up in profiles.

6. **Manual cons-loop bug.** Confirmed; call it out in the commit
   message as a second GC fix (see §9 above).

7. **C++ test harness.** Runtime-level tests exist (RapidCheck, heap
   snapshot validation, `ElmE2ETest.cpp`), but the exact CMake target
   name wasn't confirmed from context. **Before writing the targeted
   GC-stress test in step 8, do a quick `find runtime/test -name
   'CMakeLists.txt'` / `grep -r add_executable runtime/` to identify
   the existing test binary and wire the new case into it.** If no
   direct unit target exists, E2E coverage via an Elm stress program
   is acceptable on its own.

8. **Scratch capacity.** `effectsScratch_.clear()` is fine; revisiting
   to keep per-manager capacity is a perf follow-up only.

## Implementation order

1. Header changes (step 1) + scanner extension (step 2).
2. `enqueueEffects` restructuring (step 3).
3. `listFromEncoded` helper + `dispatchEffects` rewrite (steps 4-5).
4. `gatherEffects` map-type update (step 6).
5. Theory-doc update (step 7).
6. Identify C++ test target; add GC-stress coverage (step 8).
7. Full rebuild (`cmake --build build --target full`) + stress rerun.
