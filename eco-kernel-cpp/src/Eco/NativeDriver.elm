module Eco.NativeDriver exposing
    ( lowerAndLink
    , lowerAndLinkBytes
    )

{-| In-process MLIR lowering and native linking.

These functions are only meaningful when called from the unified `eco`
binary, which statically links the `EcoNativeDriverStatic` library that
provides the actual MLIR → ELF pipeline. Other front-end builds (Stage 1
guida.js, Stages 2–4 eco-boot*.js, eco-compiler) link only a stub that
returns a Task failure if these are invoked. The bootstrap stages never
reach the call site, so the stubs stay unexercised.


# Lowering

@docs lowerAndLink, lowerAndLinkBytes

-}

import Bytes exposing (Bytes)
import Eco.Kernel.NativeDriver
import Task exposing (Task)


{-| Lower the MLIR text at `mlirPath` to an ELF executable at `outputPath`.

`rootModule` is the program's root module name (e.g. "Top"). It is baked
into the output as the `__eco_root_module` symbol so the N-API addon
exposes the app at `Elm.<RootModule>` — the same path host JS uses with
the JS target. Pass "" to omit the symbol (the addon falls back to "Main").

Runs the full pipeline in-process: parse MLIR, run the Eco → LLVM pass
pipeline, translate to LLVM IR, run RS4GC + opt + object emission, then
link via the system `ld` with the runtime and kernel static libraries
baked into the binary.

Fails with a `String` error message if any pipeline stage returns
nonzero. The most common failure is the "native driver unavailable"
case (rc=-1) — returned when this binary doesn't link
EcoNativeDriverStatic and only the weak stub of
`eco_native_lower_and_link` is present (e.g. eco-compiler, or any
AOT-compiled user program produced by `eco`).
-}
lowerAndLink : String -> String -> String -> Task String ()
lowerAndLink mlirPath outputPath rootModule =
    Eco.Kernel.NativeDriver.lowerAndLink mlirPath outputPath rootModule


{-| In-memory MLIR variant: lower MLIR text bytes directly to an ELF at
`outputPath` without a temp `.mlir` file on disk. Used by Phase 2 of the
single-binary plan.

Same failure semantics as `lowerAndLink` — fails with a `String` error
message on any pipeline-stage failure.
-}
lowerAndLinkBytes : Bytes -> String -> Task String ()
lowerAndLinkBytes bytes outputPath =
    Eco.Kernel.NativeDriver.lowerAndLinkBytes bytes outputPath
