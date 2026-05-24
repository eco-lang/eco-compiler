module Compiler.Generate.MLIR.BytesFusion.LoopIR exposing
    ( Endianness(..), WidthExpr(..), Op(..), DecoderOp(..)
    , simplifyWidth
    )

{-| Loop IR for fused byte encoding and decoding.

Values are represented as MonoExpr to preserve the original AST
structure for later MLIR emission.


# Types

@docs Endianness, WidthExpr, Op, DecoderOp


# Width Utilities

@docs simplifyWidth

-}

import Compiler.AST.Monomorphized as Mono


{-| Byte order for multi-byte reads and writes.
-}
type Endianness
    = LE
    | BE


{-| Expression for computing buffer width.

`WListLengthMul countExpr constWidth` evaluates `countExpr` (which must
produce an i64 — typically a `List.length` MonoExpr) and multiplies by the
constant `constWidth`. Used to pre-size the buffer for an encoder loop
whose body has a known constant per-iteration byte width.

-}
type WidthExpr
    = WConst Int
    | WAdd WidthExpr WidthExpr
    | WStringUtf8Width Mono.MonoExpr -- Runtime: elm_utf8_width
    | WBytesWidth Mono.MonoExpr -- Runtime: elm_bytebuffer_len
    | WListLengthMul Mono.MonoExpr Int -- count expr (i64) * constant byte width


{-| Loop IR operations for encoding.
Values are MonoExpr (not yet lowered to MLIR SSA).
-}
type Op
    = InitCursor String WidthExpr -- cursorName, totalWidth (allocate buffer)
    | WriteU8 String Mono.MonoExpr -- cursorName, value expression
    | WriteU16 String Endianness Mono.MonoExpr
    | WriteU32 String Endianness Mono.MonoExpr
    | WriteF32 String Endianness Mono.MonoExpr
    | WriteF64 String Endianness Mono.MonoExpr
    | WriteBytesCopy String Mono.MonoExpr -- cursorName, bytes expression
    | WriteUtf8 String Mono.MonoExpr -- cursorName, string expression
      -- Loop op for length-prefixed dynamic encoder lists. The reifier
      -- produces these from `cons :: List.map mapFn xs` shapes; the emit
      -- lowers to an scf.while over the source list with loop-carried
      -- cursor, running bodyOps once per element with itemVar bound to the
      -- current cons head. itemByteWidth is the constant per-iteration
      -- output byte width (sum of every body op's constant width) — the
      -- pre-allocation accounts for this as `count * itemByteWidth`.
    | WriteEachItem
        { cursorName : String
        , itemVar : String
        , bodyOps : List Op
        , iterExpr : Mono.MonoExpr
        , itemByteWidth : Int
        }
    | ReturnBuffer -- Return the allocated buffer


{-| Loop IR operations for decoding.

Each primitive read produces an Elm-level value (Int as i64, Float as f64).
The emitter is responsible for inserting bf.require and scf.if fail-fast
control flow around each read.

Bounds checking is handled via nested scf.if in the emitter, not via explicit
Require/BranchOnFail ops. This removes the need for CF block jumps and makes
control flow explicit.

-}
type DecoderOp
    = InitReadCursor String Mono.MonoExpr -- cursorName, bytes expression
      -- Primitive fixed-size reads:
    | ReadU8 String String -- cursorName, resultVarName
    | ReadI8 String String -- cursorName, resultVarName (signed)
    | ReadU16 String Endianness String
    | ReadI16 String Endianness String
    | ReadU32 String Endianness String
    | ReadI32 String Endianness String
    | ReadF32 String Endianness String
    | ReadF64 String Endianness String
      -- Variable-length reads (length from Elm expr):
    | ReadBytes String Mono.MonoExpr String -- cursorName, length expr, resultVarName
    | ReadUtf8 String Mono.MonoExpr String -- cursorName, length expr, resultVarName
      -- Variable-length reads (length from previously decoded var - for andThen):
    | ReadBytesVar String String String -- cursorName, lengthVarName, resultVarName
    | ReadUtf8Var String String String -- cursorName, lengthVarName, resultVarName
      -- Function application: REQUIRED for map/map2/etc
    | Apply1 Mono.MonoExpr String String -- fnExpr, argVar, resultVar
    | Apply2 Mono.MonoExpr String String String -- fnExpr, arg1Var, arg2Var, resultVar
    | Apply3 Mono.MonoExpr String String String String
    | Apply4 Mono.MonoExpr String String String String String
    | Apply5 Mono.MonoExpr String String String String String String
      -- Constant value (for Decode.succeed):
    | PushValue Mono.MonoExpr String -- valueExpr, resultVar - push without reading
      -- Loop for decoding lists (Phase 4):
    | LoopDecodeList String String (List DecoderOp) String
      -- countVarName, cursorName, itemOps, resultVarName
      -- Emits scf.while that decodes count items into a list
      -- itemOps should decode a single item
    | LoopSentinelDecodeList Int String (List DecoderOp) String
      -- sentinel, cursorName, itemOps, resultVarName
      -- Emits scf.while that reads items until sentinel is found
      -- The first op in itemOps should be the read that produces the sentinel check value
      -- Final result:
    | ReturnJust String -- Return Just resultVar
    | ReturnNothing -- Return Nothing (fail path)


{-| Simplify width expression by folding constants.
-}
simplifyWidth : WidthExpr -> WidthExpr
simplifyWidth expr =
    case expr of
        WAdd (WConst a) (WConst b) ->
            WConst (a + b)

        WAdd a b ->
            let
                a_ =
                    simplifyWidth a

                b_ =
                    simplifyWidth b
            in
            case ( a_, b_ ) of
                ( WConst 0, _ ) ->
                    b_

                ( _, WConst 0 ) ->
                    a_

                ( WConst x, WConst y ) ->
                    WConst (x + y)

                _ ->
                    WAdd a_ b_

        _ ->
            expr
