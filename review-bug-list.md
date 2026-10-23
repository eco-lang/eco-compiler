# Eco: bugs and potential bugs found while writing the program theory

These items were found between 2026-10-21 and 2026-10-23 while investigating and writing the program theory, which is now in `THEORY.md` and `design_docs/theory/`. The full evidence for each item, with file and line references, is in the theory workspace at `icm-agents/workspaces/program-theory-writer/theory/review/source-drift.md`, section 2. The `SD-n` numbers below refer to that list.

Nothing here has been fixed, and nothing was confirmed by running code. These are the statuses:

- **Confirmed**: the defect was traced in the source by reading the code.
- **Confirmed, latent**: the defect was traced in the source, but no current code path reaches it, or it sits behind a setting that is off by default.
- **Unconfirmed**: the defect was reported by an investigation note but not re-checked against the code. "First pass" means it came from the earlier, shallower investigation.

Severity is a judgment of the likely impact:
- **High**: wrong behavior in real programs, or a test that passes when it should fail.
- **Medium**: a missing check or a fragile coupling.
- **Low**: harmless today, or a comment or documentation fault.

## High

| SD | Area | Description | Status |
|---|---|---|---|
| 22 | Bytes fusion, GC | Fused `Bytes` encode and decode keep a cursor of raw pointers that the collector never relocates. Buffers under 8 KiB live in the nursery, and fused code allocates while the cursor is live. For example, `bf.read.bytes` allocates and then copies from the old pointer, and decode loops allocate list cells. A minor collection mid-decode leaves the cursor reading moved memory. Encoder fusion is on by default. | Confirmed (not reproduced) |
| 1 | Scheduler | Process ids are truncated to 16 bits, are never recycled, and key the scheduler's tables. A program with three effect managers wraps after about 22,000 updates. After that, self-messages can go to the wrong process and be dropped, `Process.kill` can run another process's kill handle, and finished processes stay rooted. | Confirmed (behavior after wrap not run) |
| 2 | Compiler config | When a project config has a `mono` section without an `engine` key, the decoder defaults to the old `subst` engine, but `Config.default` uses the solver. Setting only `mono.lss` or `mono.limits` therefore silently switches engines and loses lambda-set specialization. | Confirmed |
| 21 | Codegen tests | In subprocess mode the codegen test harness reads the compiler's exit code and never checks it (`runSubprocessTest`). A fixture whose patterns are all `CHECK-NOT` passes even when the compiler crashes or rejects the input. | Confirmed |
| 5 | Codegen tests | 14 fixtures in `test/codegen/` assert only through custom check prefixes (`// FWD:`, `// COLLAPSE:`). The harness reads only `// CHECK*` lines and only the first RUN line, so these fixtures check nothing and their second RUN lines never execute. | Unconfirmed (first pass) |

## Medium

| SD | Area | Description | Status |
|---|---|---|---|
| 4 | Dialect / lowering | The lowering reads tuple `unboxed_bitmap` and list `head_kind` directly into heap layout, and no verifier checks them. A wrong value from the front end corrupts the layout silently. | Confirmed |
| 6 | Dialect | In the default build nothing checks direct `eco.call` signatures. The verifier defers to a pass that runs only in validation builds and checks something else. A mismatch shows up only in LLVM. | Confirmed |
| 11 | HTTP service | One worker runs HTTP requests serially, so a slow request blocks every queued request behind it. | Confirmed |
| 8 | Tests vs verifier | The Elm-side checker accepts an `i1` result of `papExtend`, but the dialect verifier rejects it. The two checks disagree on the same rule. | Confirmed |
| 3 | Global optimization | Constant hoisting checks only direct `Debug` references, not ones reached through called functions, so it could reorder `Debug` output. | Confirmed, latent (hoisting off by default) |
| 23 | Bytes fusion | Fused decoding discards the validity flag of UTF-8 and bytes reads, so invalid UTF-8 would decode to `Just` instead of `Nothing`. | Unconfirmed, latent (`Decode.string` does not fuse today) |
| 24 | Closure lowering | The `_closure_kind` branch of `emitClosureCall` calls the evaluator descriptor's address as if it were code. Nothing sets that attribute today, but a comment calls the branch "NOT dead", inviting someone to revive it. | Unconfirmed, latent |
| 12 | MLIR generation | `generateTailCall` can still emit `eco.jump` to target 0 without any enclosing join point. Whether any program reaches it was not established. | Unconfirmed |
| 15 | JavaScript output | HTML source maps are likely off by 12 lines: `leadingLines` is documented as 2, but the page puts 14 lines before the script. | Unconfirmed (first pass) |
| 16 | Kernels | Kernel homes are keyed without their `Elm`/`Eco` package prefix, and `Elm.Kernel.File` and `Eco.Kernel.File` already share the name `File`. | Unconfirmed (first pass) |
| 17 | Elm kernel | `Utils_append` silently returns its first argument for argument pairs it doesn't recognize, on the polymorphic path. | Unconfirmed (first pass) |
| 18 | Front end / runtime | Constructor tag numbers in `Data/CtorTag.elm` must match `Heap.hpp` by hand, and nothing checks that they do. | Unconfirmed (first pass) |

## Low

| SD | Area | Description | Status |
|---|---|---|---|
| 26 | Strings, equality | Only one comparison path treats the empty constant as equal to a zero-length heap string, as REP_CONSTANT_003 says. Every other path treats them as different. This is harmless while no code builds a zero-length string. | Confirmed |
| 25 | Debug type table | The type-table lowering has no case for kind 6 (Polymorphic) and writes zero bytes for its constraint. This is harmless because the printer ignores that field. | Unconfirmed |
| 7 | Dialect | The typed `papExtend` argument check gives up silently unless it can trace the closure back to its creation. | Confirmed |
| 13 | Lowering | Invariant CGEN_072 names two different producers of the "cannot collect" attribute. Which one runs in every mode was not checked. | Unconfirmed |
| 10 | Global optimization | Borrow inference is not the last step, contrary to its design note. This is harmless because the pass does not change the graph. | Confirmed |
| 9 | MLIR text output | The debug text form of MLIR is lossy: it drops source locations, prints NaN and infinities as nothing, rounds some floats and drops some escapes. The default bytecode output is unaffected. | Confirmed |
| 20 | Dialect | The six reference-counting placeholder operations are reported as errors rather than eliminated. Nothing emits them, and their fixture is marked XFAIL. | Confirmed |
| 14 | Monomorphization | Comments in `Engine.elm` treat 32 record fields as a hard cap, but records allow 2047 fields. Only the comments are wrong. | Confirmed (comments only) |
| 19 | Kernel exports | Comments in eco-kernel's `KernelExports.h` give raw return types for functions that return Tasks. | Unconfirmed (first pass) |
| 27 | Comments, invariants | Several comments and one invariant are stale:<br>• `Export::toPtr` comments say literals live in read-only data; they are interned in a permanent space.<br>• `Expr.elm` comments say all generic-call primitives are boxed; only Bool is.<br>• CGEN_059 names the wrong runtime entry point. | Confirmed |

## Test gaps that could hide bugs

These come from section 7 of the same file. They are gaps in coverage, not defects themselves.

- **Process-id wrap:** no test covers it (see SD-1).
- **Byte-fusion GC stress test:** it assumes a heap configuration that no harness sets, so it does not test what it claims (see SD-22).
- **Byte-fusion test harness:** it lacks the eco harness's region-nursery requirement and its routing of expected crashes.
- **CI coverage:** CI does not run ThreadSanitizer, the GenMC or TLA+ model checks, or the register-guard checks. The TLA+ canary only warns unless `ECO_TLA_CANARY_STRICT` is set, and no preset sets it.
- **Invariants marked tested:** MONO_019 and XPHASE_011 are marked tested, but their checkers were deleted. TOPT_004 (type preservation) is not enforced.
- **`CHECK-DAG`:** it adds no ordering meaning in the codegen harness.
- **New end-to-end package directories:** they must be registered in two places, or they silently never run.
- **Windows:** the stress, AOT and equivalence runners are not built there.
