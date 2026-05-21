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

Runs the full pipeline in-process: parse MLIR, run the Eco → LLVM pass
pipeline, translate to LLVM IR, run RS4GC + opt + object emission, then
link via `clang++` with the runtime and kernel static libraries baked
into the binary.
-}
lowerAndLink : String -> String -> Task Never ()
lowerAndLink mlirPath outputPath =
    Eco.Kernel.NativeDriver.lowerAndLink mlirPath outputPath


{-| In-memory MLIR variant: lower MLIR text bytes directly to an ELF at
`outputPath` without a temp `.mlir` file on disk. Used by Phase 2 of the
single-binary plan.
-}
lowerAndLinkBytes : Bytes -> String -> Task Never ()
lowerAndLinkBytes bytes outputPath =
    Eco.Kernel.NativeDriver.lowerAndLinkBytes bytes outputPath
