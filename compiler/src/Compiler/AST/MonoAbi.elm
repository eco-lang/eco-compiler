module Compiler.AST.MonoAbi exposing
    ( ecoValue, ecoInt, ecoFloat, ecoChar
    , monoTypeToAbi, isEcoValueType
    )

{-| The ABI type of a monomorphic value: the MLIR type it has at a boundary
between pieces of code, that is, as a function parameter or result, a closure
capture, or an operand of a partial application.

Int, Float, Char and a number type variable (`MVar _ CNumber`, which is `i64`)
are unboxed there, and everything else, Bool included, is `!eco.value`.

This module holds only that mapping and the four MLIR types it produces, so that
passes below the MLIR back end, such as the inliner's cost model in
`Compiler.GlobalOpt.KernelIntrinsics`, can use it without depending on
`Compiler.Generate`. `Compiler.Generate.MLIR.Types` exposes the same functions,
and describes the operand and heap rules that complete the picture.

@docs ecoValue, ecoInt, ecoFloat, ecoChar
@docs monoTypeToAbi, isEcoValueType

-}

import Compiler.AST.Monomorphized as Mono
import Mlir.Mlir exposing (MlirType(..))



-- ECO DIALECT TYPES


{-| The type of a boxed value, `!eco.value`: a reference to a heap object or
an embedded constant.
-}
ecoValue : MlirType
ecoValue =
    NamedStruct "eco.value"


{-| The type of an unboxed Int, a 64-bit integer.
-}
ecoInt : MlirType
ecoInt =
    I64


{-| The type of an unboxed Float, a 64-bit float.
-}
ecoFloat : MlirType
ecoFloat =
    F64


{-| The type of an unboxed Char, a 16-bit integer.
-}
ecoChar : MlirType
ecoChar =
    I16



-- ABI TYPE


{-| Returns the ABI type of a value of the given type: its MLIR type as a
function parameter or result, a closure capture, or an operand of a partial
application.

Int is `i64`, Float `f64`, Char `i16`, and a number type variable `i64`.
Every other type, Bool included, is `!eco.value`.

-}
monoTypeToAbi : Mono.MonoType -> MlirType
monoTypeToAbi monoType =
    case monoType of
        Mono.MInt ->
            ecoInt

        Mono.MFloat ->
            ecoFloat

        Mono.MChar ->
            ecoChar

        Mono.MVar _ Mono.CNumber ->
            I64

        _ ->
            ecoValue


{-| Returns whether the MLIR type is `!eco.value`.
-}
isEcoValueType : MlirType -> Bool
isEcoValueType ty =
    case ty of
        NamedStruct "eco.value" ->
            True

        _ ->
            False
