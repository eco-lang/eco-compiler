### Refactoring Aims for Eco Monomorphization

Goal: evolve Eco’s monomorphization into a single, uniform, demand‑driven system that correctly handles **all** polymorphic code paths (top‑level, let‑bound, closures, kernels, accessors) with predictable recursion deferral and multi‑specialization.
#### 1. Central, Roc‑style Pending & Recursion‑Deferral Engine

- Introduce a **single** specialization engine with:
  - `specializationStack` to track active specializations and detect recursion.
  - `PendingMode = Finding | Making` to distinguish discovery vs realization phases.
  - A `Suspended` queue for work items that must be deferred due to recursive dependencies.
- Provide one public API (e.g. `enqueueOrSuspend`) for requesting a specialization:
  - If the callee is not on `specializationStack`, enqueue it for immediate or near‑term processing.
  - If it is on the stack, add it to `Suspended` and let a later pass realize it when the cycle can be safely closed.
This replaces ad‑hoc “try now vs wait” decisions with a single, well‑defined mechanism.
#### 2. Eliminate Local Ad‑Hoc Pending Mechanisms

- Remove or thin out scattered local “pending” concepts such as:
  - `PendingGlobal`, `PendingCall`, `PendingKernel`, `PendingAccessor`, `LocalFunArg`, etc.
- Route all such cases through the **central** specialization engine and its worklist.
  - Calls and arguments that previously created local pending entries now simply call `enqueueOrSuspend` with an appropriate specialization key.
- Keep any remaining local helpers strictly as thin adapters around the central engine (no independent queues, no separate deferral rules).
This ensures there is exactly one place in the compiler that decides *when* and *how* specialization happens.
#### 3. Uniform Callable Identity for All Functions and Closures

- Define a uniform notion of **callable identity** that covers:
  - Top‑level functions.
  - Let‑bound functions.
  - Lambdas / closures (including nested and local ones).
  - Special callable forms like accessors where applicable.
- Represent this as a `(Global, Maybe LambdaId)` or equivalent, and ensure:
  - Every closure in Mono has a stable `LambdaId`, unique per graph.
  - The specialization registry can “see” and index **all** callables, not just top‑level ones.
- Make all call sites refer to callables via this identity when constructing specialization keys.
This unifies “top‑level specialization” and “local/multi specialization” under the same identity model.
#### 4. Single Specialization Pipeline for Global and Local Multi‑Specialization

- Drive **all** multi‑specialization (global functions, let‑bound functions, closures) through:
  - a single specialization key type (e.g. `(callableIdentity, keyMonoType)` plus any lambda id),
  - the central worklist + pending engine,
  - and a single specialization pipeline that produces specialized nodes.
- Retain the “rename + nested `MonoLet` rewriting” behavior for let‑bound functions only as:
  - a **syntactic** layer on top of the registry results:
    - Once specializations exist in the registry, rebind names in the local scope to those specializations.
  - not as an independent specialization system with its own discovery and deferral rules.
This collapses the current dual world (global vs local specializers) into a single, coherent mechanism.
#### 5. Register Closures at Monomorphization Time

- During monomorphization, for each `MonoClosure` that survives:
  - Allocate or reuse a `LambdaId` and register it in the specialization registry, analogous to Roc’s `PartialProc`.
  - Record its polymorphic type and body in a structure that the specialization engine can use to produce monomorphic instances.
- Make all closure calls construct specialization keys that explicitly reference this callable identity:
  - `(Global, keyMonoType, Just lambdaId)` rather than relying on MLIR to rediscover which function body a closure corresponds to.
- Leave **ABI, staging, and call‑convention** decisions to GlobalOpt and later passes:
  - Monomorphization is responsible for “what functions and specializations exist and with what MonoTypes,”
  - not for how many entrypoints (fast/closure clones) or which physical calling convention they use.
This shifts closure “ownership” to monomorphization, simplifying MLIR generation and ensuring that every callable value participates in the same, complete specialization story.
---

Together, these changes aim to:
- Make monomorphization **uniform** across all code shapes.
- Provide a **complete** and predictable specialization story (including recursion and higher‑order patterns).
- Reduce complexity in later passes (GlobalOpt, MLIR) by giving them a clear, fully specialized set of callables to work from.

## Ordering

1. Add central pending engine to monomorphization:
  specializationStack, PendingMode = Finding|Making, Suspended queue,
  enqueueOrSuspend API, initially used only for existing global specializations.

2. Turn on real recursion deferral in that engine (use specializationStack + Suspended to avoid infinite specialization), still only for global/top‑level/kind‑of‑global work items.

3. Migrate existing pending cases onto the engine, one by one:

  PendingAccessor,
  PendingGlobal,
  PendingCall,
  PendingKernel, updating resolveProcessedArg/resolveProcessedArgs to be a thin wrapper over enqueueOrSuspend.

4. Tighten callable identity:

  Ensure every closure/lambda has a unique LambdaId,
  ensure WorkItem / SpecKey consistently use (Global, MonoType, Maybe LambdaId) for all callables,
  fix any places that still treat closures as anonymous.

5. Move let‑bound multi‑specialization onto the central engine:

  Re‑express LocalFunArg / localMulti in terms of specialization keys + worklist,
  keep rename + nested MonoLet rewriting as a thin layer over registry entries,
  delete or minimize bespoke local‑multi machinery.

6. Register closures at monomorphization time:

  For each surviving MonoClosure, allocate/use LambdaId and insert into the specialization registry,
  ensure all closure calls construct specialization keys using that identity,
  leave MLIR’s PendingLambda logic unchanged for now.

7. Switch MLIR generation to consume the MonoGraph/registry closure identities:

  emit func.func per specialization using SpecId/LambdaId,
  rely on monomorphization for closure ownership,
  then remove PendingLambda and old lambda‑hoisting/discovery code.
