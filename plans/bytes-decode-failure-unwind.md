# Bytes.Decode failure: unwind to `decode` instead of returning a marker

Status: implemented 2026-10-08.

## Problem

`Bytes.Decode.string` on the non-fused (kernel) path read past the requested
range on a truncated UTF-8 sequence — past the end of the buffer, or past the
end of a slice into its parent — and turned malformed UTF-8 into garbage. The
fused decoder (`bf.read.utf8` → `elm_utf8_decode`) was strict and never read
outside the range. Today `Decode.string` never fuses (the inliner expands
`D.decode`/`D.string` into kernel calls before bytes fusion runs), so every
program hit the kernel path.

Making the kernel strict (`Utf8::scan`, the same validator as
`elm_utf8_decode`) exposed an older crash: a failing kernel read returned the
`Nothing` constant where the decoder protocol expects a `(offset, value)`
tuple, and only `Elm_Kernel_Bytes_decode` checked for it. The stock elm/bytes
combinators (`map`, `map2`..`map5`, `andThen`'s first decoder, `loop`)
destructure that tuple immediately, so any failing read below a combinator —
out-of-bounds `unsignedInt8` inside `map2`, `D.fail` inside `map`, and now
invalid UTF-8 — was a SIGSEGV. elm/bytes' JS never sees this: `getUint8` throws
and `_Bytes_decode` catches.

## Target semantics (both decode paths)

`string n` succeeds only if the n bytes at the cursor lie inside the buffer and
are complete, valid UTF-8; it then advances exactly n. Any failing read or
`D.fail`, anywhere in the decoder, makes the whole `Bytes.Decode.decode`
`Nothing`. No byte outside `[offset, offset+n)` is ever read. Fused and
non-fused decoding give identical results (eco need not match JS's lenient
decoding of malformed input).

## Design

Mirror the JS throw/catch in C++:

- `BytesExports.cpp`: every primitive read and `decodeFailure` throws a private
  tag type `Elm::BytesDecodeFailure` instead of returning `Nothing`.
- `Elm_Kernel_Bytes_decode` is the catch point. Before applying the decoder it
  saves both kernel root-stack cursors (`ecoRootMark`) and the list-scratch
  size; on `BytesDecodeFailure` it restores them and returns `Nothing`. Nested
  decodes each catch their own failures, as in JS.
- `read_string` validates with `Utf8::scan` first (strict, identical to
  `elm_utf8_decode`), so its transcode only ever sees complete sequences.

The elm/bytes Elm source, the compiler and the fused path are unchanged.

## Why C++ exceptions work through compiled Elm frames

The GC already finds compiled-frame roots by unwinding the live stack
(`ThreadLocalHeap::collectStackRootsFromStackMap` via `StackUnwind`: libunwind
over `.eh_frame` on POSIX, `RtlVirtualUnwind` over `.pdata` on Win64) — the
same tables the C++ unwinder uses, so they must already be complete for JIT
and AOT code. Compiled frames have no landing pads; phase 2 passes through
them. Nothing marks generated functions `nounwind`.

## Runtime state across the skipped frames

| State | Handling |
|---|---|
| Compiled-frame roots (statepoint stack maps) | Nothing: found by walking the live stack at each GC; `StackMapRoots` is rebuilt per cycle. |
| Shadow-root frames | Only `@main` has them, which is above the catch point. |
| Kernel root stacks (range stack, which compiled code also pushes, and the single-slot stack) | **Required** restore in the catch: `eco_apply_closure_eval` uses a manual `ecoRootMark`/`ecoRootRelease` pair, and compiled code pushes range records, so a throw would otherwise leave records pointing into dead stack. `ecoRootRelease(saved)` in the catch. |
| List scratch stack (`eco_scratch_*`) | Restore the saved size in the catch with the existing `eco_scratch_abandon(mark)`; otherwise leaked entries stay GC roots. |
| CAF memo slots | No in-progress marker (slot stored on return only); a skipped evaluation just recomputes. |
| GC during unwinding | Impossible: no Elm allocation while unwinding. |

Frames that can sit between the catch and a throw: `Elm_Kernel_Bytes_decode`,
the closure-apply/PAP trampolines, compiled elm/bytes combinators (often
inlined into user code) and the read. User callbacks always return before the
next read, and elm/bytes never hands a decoder function to a kernel HOF.

## Platform notes

- Kernel and runtime C++ must be built with exceptions (clang default on
  POSIX; `/EHsc` from the win presets). No `noexcept` on the path.
- Windows `/EHsc` assumes `extern "C"` functions do not throw, and the only
  call inside the `try` is the `extern "C"` `eco_apply_closure_typed`; the
  catch could be optimised away. `BytesExports.cpp` is therefore compiled with
  `/EHs /EHc-` on Windows. Frames compiled with `/EHsc` that are skipped may
  not run their cleanups; the catch-side restores do not depend on them.
  (Not verifiable on Linux; covered by win-aot CI.)

## Tests

- `test/kernel/KernelExportsTest.cpp`: K8b goldens (strict; padded, unpadded
  and slice-shaped sources), K8d (kernel `read_string` agrees with
  `elm_utf8_decode`). Direct reads now report failure by throwing.
- `test/bf-codegen/bf_read_utf8_strict.mlir`: the fused lowering.
- `test/elm-bytes/src/DecodeStringStrict{Fused,Kernel}Test.elm`: 51-case table
  on both paths (the "Fused" file has no MLIR pins until string decodes fuse).
- `test/elm-bytes/src/DecodeFailureInCombinatorTest.elm`: failures under every
  combinator position, `D.fail`, nested decodes, GC pressure and many repeated
  failures, on the kernel path.

## Follow-ups

- `Decode.string` never fuses (inlining defeats the reifier): a performance
  issue, separate from this correctness fix.
- `eco_alloc_string_fast/slow` / `eco_init_string_at` lack the length-0 guard
  (only reachable from hand-written MLIR today).
