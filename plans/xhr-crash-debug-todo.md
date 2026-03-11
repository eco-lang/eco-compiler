# Plan: XHR Eco.Crash via Debug.todo (no --optimize for Stage 1)

## Problem

Stage 2 (`build-self.sh`) fails because `guida.js` (the Stage 1 XHR compiler) cannot
resolve `Eco.Crash` when compiling from `build-kernel/`. The kernel variant of `Eco.Crash`
(in `eco-kernel-cpp`) imports `Eco.Kernel.Crash`, which is a kernel JS module that the
XHR-based guida.js cannot handle.

The current XHR variant (`src-xhr/Eco/Crash.elm`) uses a self-recursive hack
(`crash str = crash str`) that compiles under `--optimize`, then `replacements.js`
patches the compiled JS to actually crash. This is fragile and unnecessary.

## Approach

Use `Debug.todo` for the XHR crash implementation. This is the natural Elm way to express
"crash with a message" and eliminates the need for JS patching. The trade-off is that
Stage 1 cannot use `--optimize` (which forbids `Debug.todo`). Only Stages 2+ (kernel
builds, which use `Eco.Kernel.Crash` instead) use `--optimize`.

## Changes

### 1. Edit `compiler/src-xhr/Eco/Crash.elm` — use Debug.todo

Replace the self-recursive implementation with `Debug.todo`:

```elm
module Eco.Crash exposing (crash)

{-| Crash function for unrecoverable compiler errors (XHR variant).

Uses Debug.todo, so this module is only usable in non-optimized builds.
The kernel variant (eco-kernel-cpp) uses Eco.Kernel.Crash and supports --optimize.

@docs crash

-}


{-| Crash the program with an error message. Never returns.
-}
crash : String -> a
crash str =
    Debug.todo str
```

### 2. Edit `compiler/scripts/build.sh` — remove --optimize from Stage 1

Change line 30 from:
```bash
$ELM make --optimize --output=$js $elm_entry
```
to:
```bash
$ELM make --output=$js $elm_entry
```

Stage 1 uses the stock Elm compiler which cannot build `Debug.todo` with `--optimize`.
Stages 2+ use the kernel `Eco.Crash` (no `Debug.todo`) and keep `--optimize`.

### 3. Edit `compiler/scripts/replacements.js` — remove crash JS patch

Remove the `Eco$Crash$crash` self-recursive loop replacement (lines 10–27). With
`Debug.todo`, the stock Elm compiler already emits a proper crash with a readable error
message and stack trace — no JS patching needed.

Keep the other two replacements (`_Bytes_read_string` and `_Json_encodeNull`).

### 4. Edit `compiler/CMakeLists.txt` — remove --optimize from Stage 1

Change the Step 1 command (line 48) from:
```cmake
COMMAND ${ELM_EXECUTABLE} make --optimize --output=${COMPILER_OUTPUT} ${ELM_ENTRY}
```
to:
```cmake
COMMAND ${ELM_EXECUTABLE} make --output=${COMPILER_OUTPUT} ${ELM_ENTRY}
```

Stages 2 and 3 keep `--optimize` (they use the kernel `Eco.Crash`).

### 5. Edit `bootstrap.md` — update Stage 1 docs and optimize notes

- Stage 1 command: remove `--optimize` flag
- Add a note explaining that Stage 1 builds without `--optimize` because the XHR
  `Eco.Crash` uses `Debug.todo`, and `--optimize` is only used from Stage 2 onward
  where the kernel `Eco.Crash` (via `Eco.Kernel.Crash`) replaces `Debug.todo`.
- Update the "All stages in sequence" section accordingly.
- Update the note "All stages use `--optimize`" to say only Stages 2+ use it.

## Files Modified

| File | Action |
|------|--------|
| `compiler/src-xhr/Eco/Crash.elm` | **Edit** — replace self-recursion with `Debug.todo` |
| `compiler/scripts/build.sh` | **Edit** — remove `--optimize` from Stage 1 |
| `compiler/scripts/replacements.js` | **Edit** — remove crash JS patch |
| `compiler/CMakeLists.txt` | **Edit** — remove `--optimize` from Stage 1 command |
| `bootstrap.md` | **Edit** — document that only Stages 2+ use `--optimize` |

## Files NOT Modified

- `compiler/scripts/build-self.sh` — already uses `--optimize` with kernel build; no change needed.
- `compiler/scripts/build-verify.sh` — already uses `--optimize` with kernel build; no change needed.
- `eco-kernel-cpp/src/Eco/Crash.elm` — already exists and uses `Eco.Kernel.Crash`; no change needed.
- `eco-kernel-cpp/elm.json` — already exposes `Eco.Crash`; no change needed.
- `compiler/src/Utils/Crash.elm` — already delegates to `Eco.Crash`; no change needed.

## Testing

1. Run Stage 1: `cd /work/compiler && ./scripts/build.sh bin` — should succeed without `--optimize`
2. Run Stage 2: `cd /work/compiler && ./scripts/build-self.sh bin` — should succeed with `--optimize`
3. Run Stages 3+4: `cd /work/compiler && ./scripts/build-verify.sh` — fixed-point check passes
4. Run Stage 5: MLIR output from eco-boot-2 — should succeed with `--optimize`
5. Front-end tests: `cd /work/compiler && npx elm-test-rs --project build-xhr --fuzz 1`
6. CMake full rebuild: `cmake --build build --target full`
