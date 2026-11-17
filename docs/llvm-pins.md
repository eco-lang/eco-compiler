# LLVM and MAX pin log

Each move of the pins in [`deps/versions.env`](../deps/versions.env), newest first: what moved, and
what eco's code needed for it. The next port starts from the last one's notes. How to move a pin:
`plans/llvm-24-upgrade.md` §9, or in short:

```bash
scripts/deps.sh max <version>        # MAX, and LLVM to MAX's own pin (LLVM_FOLLOWS=max)
# LLVM unchanged: push; CI re-syncs MAX. LLVM moved: the llvm-build workflow builds it (hours),
# then local-dev/build-images.sh, fix the API breaks below, set LLVM_DESCRIBE, and:
test/scripts/upgrade-gates.sh        # the Linux gates; mac-aot and win-aot cover the rest
```

## 2026-11 — MAX 26.7.0, llvm-project 8d4fc8f1d17e (24.0.0git), from LLVM 21.1.8

The first pin by commit: eco moved from the 21.1.8 release to the commit MAX 26.7.0 pins
(`bazel/public-patches/llvm_source.bzl` at `max/v26.7.0`, 2026-10-09), so that eco and MAX share one
LLVM/MLIR. About 15 months of LLVM trunk; Modular's own patches on that commit (AMDGPU/NVPTX
codegen, lldb) are not applied.

API changes eco's code needed (`runtime/src/codegen`):

1. **Strict properties in assembly formats.** ODS now refuses inherent attributes printed through
   `attr-dict`. First worked around with `useStrictPropertiesInAssemblyFormat = 0` (deprecated);
   then 14 ops' formats gained `prop-dict` (`dbg`, `type_table`, `construct.{list,tuple2,tuple3,
   record,custom}`, `list.map`, `allocate`, `allocate_string`, `allocate_closure`, `make.custom`,
   `make.closure`, `to_heap`). Their custom syntax now writes inherent attributes as
   `<{tag = 5 : i64, ...}>` before the `{...}` of discardable ones; 210 fixture lines in
   `test/` moved with them. Bytecode and generic form, which the compiler emits, are unchanged.
2. **`eco.global`** needs the `Symbol` trait's `sym_name` and visibility accessors declared.
3. **Pass mix-ins.** A pass is `RequiredPassInfoMixin` or `OptionalPassInfoMixin`;
   `StripEcoCastBarriers` must be Required.
4. **`PassInstrumentation`** callbacks take an `IRUnitRef` instead of `llvm::Any`.
5. **`BranchInst` → `CondBrInst`** for conditional branches, condition first.
6. **`TargetRegistry::lookupTarget`** takes a `Triple`, not a string.
7. **ORC JIT:** `ObjectLinkingLayerCreator` takes a `JITLinkMemoryManager &`.
8. **`llvm::make_scope_exit` → `llvm::scope_exit`.**

Then, so no deprecated API waits to break a later move: all 1,139 `b.create<Op>(...)` calls
became `Op::create(b, ...)` (mechanical; no deprecation warnings left).

Gates (Linux glibc, 2026-11-10): bootstrap with both fixed points, `full` 3091/3091, JS 265,
node-addon, driver CLI. Again on 2026-11-17, after both migrations and with MAX: `full`
3091/3091, JS 265, node-addon, driver CLI, the MAX smoke test (15/15), elm-tests 21,510,
bootstrap with both fixed points, and AOT E2E (no failures beyond the known two). Stage 7a's apparent 2x allocation was a cold build against a warm
reference, not LLVM.
