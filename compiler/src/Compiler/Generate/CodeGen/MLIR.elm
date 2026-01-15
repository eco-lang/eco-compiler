module Compiler.Generate.CodeGen.MLIR exposing (backend)

{-| MLIR code generation backend for the Monomorphized IR.

This module re-exports the backend from Compiler.Generate.MLIR.Backend.
The actual implementation is split across multiple modules in
Compiler.Generate.MLIR.\*.

-}

import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.MLIR.Backend as Backend


{-| The MLIR backend that generates MLIR code from fully monomorphized IR with all polymorphism resolved.
-}
backend : CodeGen.MonoCodeGen
backend =
    Backend.backend
