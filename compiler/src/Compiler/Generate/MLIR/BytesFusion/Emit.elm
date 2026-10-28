module Compiler.Generate.MLIR.BytesFusion.Emit exposing (ExprCompiler, emitFusedDecoder, emitFusedEncoder, CompileExprResult)

{-| Turns a fused `elm/bytes` encoder or decoder, described in the operations
of `Compiler.Generate.MLIR.BytesFusion.LoopIR`, into MLIR, so that an encoder
writes straight into one buffer and a decoder reads straight from its input.
No encoder or decoder value is walked at run time, except for a subtree that
was not recognised.

The output is mostly operations of the `bf` dialect, whose central value is the
_cursor_ (`!bf.cursor`): a position in a buffer. Every `bf` read or write takes
a cursor and returns a new one, moved on by the bytes it covered, so the module
threads the current cursor's SSA name through everything it emits. Values that
the operations carry as `Mono.MonoExpr` are compiled by an `ExprCompiler`
supplied by the caller, which lets this module compile expressions without
importing the expression generator.

`emitFusedEncoder` emits the encoder: the buffer's total width in bytes as an
`i32`, a `bf.alloc` of that size, a cursor on it, then one `bf.write.*` per
write, and a list loop as an `scf.while` over the list's cons cells. Integer and
float writes take `i64` and `f64`, so a boxed `!eco.value` is unboxed first. A
subtree that was not recognised is written whole by `bf.write.encoder`. The
values of the top-level writes are compiled before `bf.alloc`, so that no
allocation they make happens while the cursor is live.

`emitFusedDecoder` emits the decoder, whose result is a `Maybe`. Each read is
guarded: a `bf.require` checks that its bytes are there, and an `scf.if` runs
the read and all the remaining operations in its then-branch and gives
`Nothing` in its else-branch, so the operations nest one level per read. A
UTF-8 read nests once more on its own validity result. The counted loop checks
all its bytes before the loop; the sentinel loop checks before each item. A
decoder that reaches its end gives `Just` its result value, by default the last
value produced.

@docs ExprCompiler, emitFusedDecoder, emitFusedEncoder, CompileExprResult

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.CtorTag as CtorTag
import Compiler.Generate.MLIR.BytesFusion.LoopIR as IR exposing (DecoderOp(..), Endianness(..), Op(..), WidthExpr(..))
import Compiler.Generate.MLIR.Context as Context exposing (Context)
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Types as Types
import Dict
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))
import Utils.Crash as Crash


{-| What an `ExprCompiler` gives back for one expression: the ops that compute
it, in order, the SSA name and type of its value, and the context after those
ops.
-}
type alias CompileExprResult =
    { ops : List MlirOp
    , resultVar : String
    , resultType : MlirType
    , ctx : Context
    }


{-| A function that compiles one expression in a context, supplied by the
caller of `emitFusedEncoder` or `emitFusedDecoder`.
-}
type alias ExprCompiler =
    Mono.MonoExpr -> Context -> CompileExprResult


{-| The state threaded through the emission of an encoder.

`ops` holds the ops emitted so far, most recent first. `hoisted` holds the
values compiled ahead of `bf.alloc` that writes have not yet taken, in op order.

-}
type alias EmitState =
    { ctx : Context
    , cursor : String -- SSA name of the current cursor
    , bufferVar : String -- SSA name of the buffer bf.alloc made
    , ops : List MlirOp
    , compileExpr : ExprCompiler
    , hoisted : List ( String, MlirType )
    }


{-| The MLIR type of a `bf` cursor.
-}
bfCursorType : MlirType
bfCursorType =
    NamedStruct "bf.cursor"


{-| Emits the encoder described by `ops`, compiling its values with
`compileExpr`. Returns the ops in order, the SSA name of the buffer it fills,
and the context after them.

The buffer is the one an `InitCursor` operation allocates, so `ops` must contain
one; without it the returned name is empty. The returned context's
`currentFuncName` has `/bf-enc` appended.

-}
emitFusedEncoder : ExprCompiler -> Context -> List Op -> ( List MlirOp, String, Context )
emitFusedEncoder compileExpr ctxIn ops =
    emitFusedEncoderTagged compileExpr { ctxIn | currentFuncName = ctxIn.currentFuncName ++ "/bf-enc" } ops


{-| Emits the encoder described by `ops`, as `emitFusedEncoder` does, without
changing the function name in the context.
-}
emitFusedEncoderTagged : ExprCompiler -> Context -> List Op -> ( List MlirOp, String, Context )
emitFusedEncoderTagged compileExpr ctx ops =
    let
        initialState =
            { ctx = ctx
            , cursor = ""
            , bufferVar = ""
            , ops = []
            , compileExpr = compileExpr
            , hoisted = []
            }

        finalState =
            List.foldl emitOp (hoistValues ops initialState) ops
    in
    ( List.reverse finalState.ops, finalState.bufferVar, finalState.ctx )


{-| Compiles the value of every top-level write, and the list each loop walks,
ahead of the rest of the encoder, in op order, and queues the results in
`hoisted` for `compileValue` to hand out. It does this only when `ops` starts
with `InitCursor`, and otherwise returns `state` unchanged.

A value expression may call a function that allocates, and an allocation while
the cursor is live is a garbage-collection point the later lowering has to work
around. Compiled first, the values leave the cursor's live range free of them.
Elm values are immutable, so compiling them earlier gives the same values. The
values written inside a loop's body are still compiled inside the loop.

-}
hoistValues : List Op -> EmitState -> EmitState
hoistValues ops state =
    case ops of
        (InitCursor _ _) :: rest ->
            let
                hoistOne op st =
                    case writtenValue op of
                        Just expr ->
                            let
                                r =
                                    st.compileExpr expr st.ctx
                            in
                            { st
                                | ctx = r.ctx
                                , ops = List.reverse r.ops ++ st.ops
                                , hoisted = ( r.resultVar, r.resultType ) :: st.hoisted
                            }

                        Nothing ->
                            st

                done =
                    List.foldl hoistOne state rest
            in
            { done | hoisted = List.reverse done.hoisted }

        _ ->
            state


{-| Returns the expression an encoder operation compiles for its value: what a
write writes, or the list a loop walks. `Nothing` for `InitCursor` and
`ReturnBuffer`.
-}
writtenValue : Op -> Maybe Mono.MonoExpr
writtenValue op =
    case op of
        WriteU8 _ e ->
            Just e

        WriteU16 _ _ e ->
            Just e

        WriteU32 _ _ e ->
            Just e

        WriteF32 _ _ e ->
            Just e

        WriteF64 _ _ e ->
            Just e

        WriteBytesCopy _ e ->
            Just e

        WriteUtf8 _ e ->
            Just e

        WriteOpaque _ e ->
            Just e

        WriteEachItem r ->
            Just r.iterExpr

        InitCursor _ _ ->
            Nothing

        ReturnBuffer ->
            Nothing


{-| Returns the value of a write, with the hoisted values left after it: the
next hoisted value when there is one, with no ops, and otherwise `valueExpr`
compiled here.

The hoisted value is taken by position, not matched against `valueExpr`, so the
writes must ask in the order `hoistValues` compiled them.

-}
compileValue : Mono.MonoExpr -> EmitState -> ( CompileExprResult, List ( String, MlirType ) )
compileValue valueExpr state =
    case state.hoisted of
        ( var, ty ) :: rest ->
            ( { ops = [], resultVar = var, resultType = ty, ctx = state.ctx }, rest )

        [] ->
            ( state.compileExpr valueExpr state.ctx, [] )


{-| Emits one encoder operation onto `state`. `ReturnBuffer` emits nothing,
since the buffer is already in `bufferVar`.
-}
emitOp : Op -> EmitState -> EmitState
emitOp op state =
    case op of
        InitCursor _ widthExpr ->
            emitInitCursor widthExpr state

        WriteU8 _ valueExpr ->
            emitWriteU8 valueExpr state

        WriteU16 _ endian valueExpr ->
            emitWriteU16 endian valueExpr state

        WriteU32 _ endian valueExpr ->
            emitWriteU32 endian valueExpr state

        WriteF32 _ endian valueExpr ->
            emitWriteF32 endian valueExpr state

        WriteF64 _ endian valueExpr ->
            emitWriteF64 endian valueExpr state

        WriteBytesCopy _ bytesExpr ->
            emitWriteBytes bytesExpr state

        WriteUtf8 _ stringExpr ->
            emitWriteUtf8 stringExpr state

        WriteEachItem r ->
            emitWriteEachItem r state

        WriteOpaque _ encoderExpr ->
            emitWriteOpaque encoderExpr state

        ReturnBuffer ->
            state


{-| Emits the computation of `widthExpr`, a `bf.alloc` of a buffer that many
bytes long, and a cursor at its start, which becomes the state's cursor and
buffer.
-}
emitInitCursor : WidthExpr -> EmitState -> EmitState
emitInitCursor widthExpr state =
    let
        ( widthOps, widthVar, ctx1 ) =
            emitWidthExpr state.compileExpr widthExpr state.ctx

        ( bufferVar, ctx2 ) =
            Context.freshVar ctx1

        allocAttrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr I32 ])

        ( ctx3, allocOp ) =
            Ops.mlirOp ctx2 "bf.alloc"
                |> Ops.opBuilder.withOperands [ widthVar ]
                |> Ops.opBuilder.withResults [ ( bufferVar, Types.ecoValue ) ]
                |> Ops.opBuilder.withAttrs allocAttrs
                |> Ops.opBuilder.build

        ( cursorVar, ctx4 ) =
            Context.freshVar ctx3

        initAttrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr Types.ecoValue ])

        ( ctx5, initOp ) =
            Ops.mlirOp ctx4 "bf.cursor.init"
                |> Ops.opBuilder.withOperands [ bufferVar ]
                |> Ops.opBuilder.withResults [ ( cursorVar, bfCursorType ) ]
                |> Ops.opBuilder.withAttrs initAttrs
                |> Ops.opBuilder.build
    in
    { state
        | ctx = ctx5
        , cursor = cursorVar
        , bufferVar = bufferVar
        , ops = initOp :: allocOp :: (List.reverse widthOps ++ state.ops)
    }


{-| Emits the computation of a buffer width as an `i32`. Returns the ops, the
SSA name of the width, and the context after them.

The expressions inside the width are compiled here, independently of any
compilation of the same expressions for the writes.

-}
emitWidthExpr : ExprCompiler -> WidthExpr -> Context -> ( List MlirOp, String, Context )
emitWidthExpr compileExpr expr ctx =
    case expr of
        WConst n ->
            let
                ( varName, ctx1 ) =
                    Context.freshVar ctx

                ( ctx2, op ) =
                    Ops.mlirOp ctx1 "arith.constant"
                        |> Ops.opBuilder.withResults [ ( varName, I32 ) ]
                        |> Ops.opBuilder.withAttrs (Dict.singleton "value" (IntAttr (Just I32) n))
                        |> Ops.opBuilder.build
            in
            ( [ op ], varName, ctx2 )

        WAdd a b ->
            let
                ( aOps, aVar, ctx1 ) =
                    emitWidthExpr compileExpr a ctx

                ( bOps, bVar, ctx2 ) =
                    emitWidthExpr compileExpr b ctx1

                ( resultVar, ctx3 ) =
                    Context.freshVar ctx2

                ( ctx4, addOp ) =
                    Ops.mlirOp ctx3 "arith.addi"
                        |> Ops.opBuilder.withOperands [ aVar, bVar ]
                        |> Ops.opBuilder.withResults [ ( resultVar, I32 ) ]
                        |> Ops.opBuilder.build
            in
            ( aOps ++ bOps ++ [ addOp ], resultVar, ctx4 )

        WStringUtf8Width strExpr ->
            let
                strResult =
                    compileExpr strExpr ctx

                ( resultVar, ctx2 ) =
                    Context.freshVar strResult.ctx

                widthAttrs =
                    Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr strResult.resultType ])

                ( ctx3, widthOp ) =
                    Ops.mlirOp ctx2 "bf.utf8_width"
                        |> Ops.opBuilder.withOperands [ strResult.resultVar ]
                        |> Ops.opBuilder.withResults [ ( resultVar, I32 ) ]
                        |> Ops.opBuilder.withAttrs widthAttrs
                        |> Ops.opBuilder.build
            in
            ( strResult.ops ++ [ widthOp ], resultVar, ctx3 )

        WBytesWidth bytesExpr ->
            let
                bytesResult =
                    compileExpr bytesExpr ctx

                ( resultVar, ctx2 ) =
                    Context.freshVar bytesResult.ctx

                widthAttrs =
                    Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr bytesResult.resultType ])

                ( ctx3, widthOp ) =
                    Ops.mlirOp ctx2 "bf.bytes_width"
                        |> Ops.opBuilder.withOperands [ bytesResult.resultVar ]
                        |> Ops.opBuilder.withResults [ ( resultVar, I32 ) ]
                        |> Ops.opBuilder.withAttrs widthAttrs
                        |> Ops.opBuilder.build
            in
            ( bytesResult.ops ++ [ widthOp ], resultVar, ctx3 )

        WOpaqueWidth encoderExpr ->
            let
                exprResult =
                    compileExpr encoderExpr ctx

                ( resultVar, ctx2 ) =
                    Context.freshVar exprResult.ctx

                widthAttrs =
                    Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr exprResult.resultType ])

                ( ctx3, widthOp ) =
                    Ops.mlirOp ctx2 "bf.encoder.width"
                        |> Ops.opBuilder.withOperands [ exprResult.resultVar ]
                        |> Ops.opBuilder.withResults [ ( resultVar, I32 ) ]
                        |> Ops.opBuilder.withAttrs widthAttrs
                        |> Ops.opBuilder.build
            in
            ( exprResult.ops ++ [ widthOp ], resultVar, ctx3 )

        WListLengthMul countExpr constWidth ->
            -- The count is truncated to i32 as it stands, so it must compile to
            -- an unboxed integer, not an !eco.value.
            let
                countResult =
                    compileExpr countExpr ctx

                ( count32Var, ctx2 ) =
                    Context.freshVar countResult.ctx

                ( ctx3, trunciOp ) =
                    Ops.mlirOp ctx2 "arith.trunci"
                        |> Ops.opBuilder.withOperands [ countResult.resultVar ]
                        |> Ops.opBuilder.withResults [ ( count32Var, I32 ) ]
                        |> Ops.opBuilder.withAttrs
                            (Dict.singleton "_operand_types"
                                (ArrayAttr Nothing [ TypeAttr countResult.resultType ])
                            )
                        |> Ops.opBuilder.build

                ( constVar, ctx4 ) =
                    Context.freshVar ctx3

                ( ctx5, constOp ) =
                    Ops.mlirOp ctx4 "arith.constant"
                        |> Ops.opBuilder.withResults [ ( constVar, I32 ) ]
                        |> Ops.opBuilder.withAttrs (Dict.singleton "value" (IntAttr (Just I32) constWidth))
                        |> Ops.opBuilder.build

                ( mulVar, ctx6 ) =
                    Context.freshVar ctx5

                ( ctx7, mulOp ) =
                    Ops.mlirOp ctx6 "arith.muli"
                        |> Ops.opBuilder.withOperands [ count32Var, constVar ]
                        |> Ops.opBuilder.withResults [ ( mulVar, I32 ) ]
                        |> Ops.opBuilder.withAttrs
                            (Dict.singleton "_operand_types"
                                (ArrayAttr Nothing [ TypeAttr I32, TypeAttr I32 ])
                            )
                        |> Ops.opBuilder.build
            in
            ( countResult.ops ++ [ trunciOp, constOp, mulOp ], mulVar, ctx7 )


{-| Returns the `endianness` attribute of a `bf` read or write: the `i32` 0 for
little-endian and 1 for big-endian.
-}
endianToAttr : Endianness -> MlirAttr
endianToAttr endian =
    case endian of
        LE ->
            IntAttr (Just I32) 0

        BE ->
            IntAttr (Just I32) 1


{-| Returns `valueVar` as a value of `targetType`, with the ops that make it so:
an `eco.unbox` when `valueType` is `!eco.value` and `targetType` is not, and
otherwise `valueVar` itself with no ops.

The integer writes use it to get an `i64` and the float writes an `f64`. Bytes,
UTF-8 and opaque writes take their value as it is.

-}
ensureUnboxed : MlirType -> String -> MlirType -> Context -> ( String, List MlirOp, Context )
ensureUnboxed targetType valueVar valueType ctx =
    if Types.isEcoValueType valueType && not (Types.isEcoValueType targetType) then
        let
            ( unboxedVar, ctx1 ) =
                Context.freshVar ctx

            attrs =
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing [ TypeAttr Types.ecoValue ])

            ( ctx2, unboxOp ) =
                Ops.mlirOp ctx1 "eco.unbox"
                    |> Ops.opBuilder.withOperands [ valueVar ]
                    |> Ops.opBuilder.withResults [ ( unboxedVar, targetType ) ]
                    |> Ops.opBuilder.withAttrs attrs
                    |> Ops.opBuilder.build
        in
        ( unboxedVar, [ unboxOp ], ctx2 )

    else
        ( valueVar, [], ctx )


{-| Emits a `bf.write.u8` of the value of `valueExpr`, unboxed to `i64`
where it is boxed, and moves the cursor past it.
-}
emitWriteU8 : Mono.MonoExpr -> EmitState -> EmitState
emitWriteU8 valueExpr state =
    let
        ( exprResult, hoisted ) =
            compileValue valueExpr state

        ( valueVar, unboxOps, ctxU ) =
            ensureUnboxed I64 exprResult.resultVar exprResult.resultType exprResult.ctx

        ( newCursor, ctx2 ) =
            Context.freshVar ctxU

        writeAttrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr I64 ])

        ( ctx3, writeOp ) =
            Ops.mlirOp ctx2 "bf.write.u8"
                |> Ops.opBuilder.withOperands [ state.cursor, valueVar ]
                |> Ops.opBuilder.withResults [ ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.withAttrs writeAttrs
                |> Ops.opBuilder.build
    in
    { state
        | ctx = ctx3
        , cursor = newCursor
        , hoisted = hoisted
        , ops = writeOp :: List.reverse unboxOps ++ List.reverse exprResult.ops ++ state.ops
    }


{-| Emits a `bf.write.u16` of the value of `valueExpr` in the byte order `endian`, unboxed to `i64`
where it is boxed, and moves the cursor past it.
-}
emitWriteU16 : Endianness -> Mono.MonoExpr -> EmitState -> EmitState
emitWriteU16 endian valueExpr state =
    let
        ( exprResult, hoisted ) =
            compileValue valueExpr state

        ( valueVar, unboxOps, ctxU ) =
            ensureUnboxed I64 exprResult.resultVar exprResult.resultType exprResult.ctx

        ( newCursor, ctx2 ) =
            Context.freshVar ctxU

        writeAttrs =
            Dict.fromList
                [ ( "endianness", endianToAttr endian )
                , ( "_operand_types", ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr I64 ] )
                ]

        ( ctx3, writeOp ) =
            Ops.mlirOp ctx2 "bf.write.u16"
                |> Ops.opBuilder.withOperands [ state.cursor, valueVar ]
                |> Ops.opBuilder.withResults [ ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.withAttrs writeAttrs
                |> Ops.opBuilder.build
    in
    { state
        | ctx = ctx3
        , cursor = newCursor
        , hoisted = hoisted
        , ops = writeOp :: List.reverse unboxOps ++ List.reverse exprResult.ops ++ state.ops
    }


{-| Emits a `bf.write.u32` of the value of `valueExpr` in the byte order `endian`, unboxed to `i64`
where it is boxed, and moves the cursor past it.
-}
emitWriteU32 : Endianness -> Mono.MonoExpr -> EmitState -> EmitState
emitWriteU32 endian valueExpr state =
    let
        ( exprResult, hoisted ) =
            compileValue valueExpr state

        ( valueVar, unboxOps, ctxU ) =
            ensureUnboxed I64 exprResult.resultVar exprResult.resultType exprResult.ctx

        ( newCursor, ctx2 ) =
            Context.freshVar ctxU

        writeAttrs =
            Dict.fromList
                [ ( "endianness", endianToAttr endian )
                , ( "_operand_types", ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr I64 ] )
                ]

        ( ctx3, writeOp ) =
            Ops.mlirOp ctx2 "bf.write.u32"
                |> Ops.opBuilder.withOperands [ state.cursor, valueVar ]
                |> Ops.opBuilder.withResults [ ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.withAttrs writeAttrs
                |> Ops.opBuilder.build
    in
    { state
        | ctx = ctx3
        , cursor = newCursor
        , hoisted = hoisted
        , ops = writeOp :: List.reverse unboxOps ++ List.reverse exprResult.ops ++ state.ops
    }


{-| Emits a `bf.write.f32` of the value of `valueExpr` in the byte order `endian`, unboxed to `f64`
where it is boxed, and moves the cursor past it.
-}
emitWriteF32 : Endianness -> Mono.MonoExpr -> EmitState -> EmitState
emitWriteF32 endian valueExpr state =
    let
        ( exprResult, hoisted ) =
            compileValue valueExpr state

        ( valueVar, unboxOps, ctxU ) =
            ensureUnboxed F64 exprResult.resultVar exprResult.resultType exprResult.ctx

        ( newCursor, ctx2 ) =
            Context.freshVar ctxU

        writeAttrs =
            Dict.fromList
                [ ( "endianness", endianToAttr endian )
                , ( "_operand_types", ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr F64 ] )
                ]

        ( ctx3, writeOp ) =
            Ops.mlirOp ctx2 "bf.write.f32"
                |> Ops.opBuilder.withOperands [ state.cursor, valueVar ]
                |> Ops.opBuilder.withResults [ ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.withAttrs writeAttrs
                |> Ops.opBuilder.build
    in
    { state
        | ctx = ctx3
        , cursor = newCursor
        , hoisted = hoisted
        , ops = writeOp :: List.reverse unboxOps ++ List.reverse exprResult.ops ++ state.ops
    }


{-| Emits a `bf.write.f64` of the value of `valueExpr` in the byte order `endian`, unboxed to `f64`
where it is boxed, and moves the cursor past it.
-}
emitWriteF64 : Endianness -> Mono.MonoExpr -> EmitState -> EmitState
emitWriteF64 endian valueExpr state =
    let
        ( exprResult, hoisted ) =
            compileValue valueExpr state

        ( valueVar, unboxOps, ctxU ) =
            ensureUnboxed F64 exprResult.resultVar exprResult.resultType exprResult.ctx

        ( newCursor, ctx2 ) =
            Context.freshVar ctxU

        writeAttrs =
            Dict.fromList
                [ ( "endianness", endianToAttr endian )
                , ( "_operand_types", ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr F64 ] )
                ]

        ( ctx3, writeOp ) =
            Ops.mlirOp ctx2 "bf.write.f64"
                |> Ops.opBuilder.withOperands [ state.cursor, valueVar ]
                |> Ops.opBuilder.withResults [ ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.withAttrs writeAttrs
                |> Ops.opBuilder.build
    in
    { state
        | ctx = ctx3
        , cursor = newCursor
        , hoisted = hoisted
        , ops = writeOp :: List.reverse unboxOps ++ List.reverse exprResult.ops ++ state.ops
    }


{-| Emits a `bf.write.bytes` copying the bytes value of `bytesExpr` into the
buffer, and moves the cursor past it.
-}
emitWriteBytes : Mono.MonoExpr -> EmitState -> EmitState
emitWriteBytes bytesExpr state =
    let
        ( exprResult, hoisted ) =
            compileValue bytesExpr state

        ( newCursor, ctx2 ) =
            Context.freshVar exprResult.ctx

        writeAttrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr exprResult.resultType ])

        ( ctx3, writeOp ) =
            Ops.mlirOp ctx2 "bf.write.bytes"
                |> Ops.opBuilder.withOperands [ state.cursor, exprResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.withAttrs writeAttrs
                |> Ops.opBuilder.build
    in
    { state
        | ctx = ctx3
        , cursor = newCursor
        , hoisted = hoisted
        , ops = writeOp :: (List.reverse exprResult.ops ++ state.ops)
    }


{-| Emits a `bf.write.encoder` that writes the encoder value of `encoderExpr`
into the buffer whole, for a part of an encoder that was not recognised, and
moves the cursor past what it wrote.
-}
emitWriteOpaque : Mono.MonoExpr -> EmitState -> EmitState
emitWriteOpaque encoderExpr state =
    let
        ( exprResult, hoisted ) =
            compileValue encoderExpr state

        ( newCursor, ctx2 ) =
            Context.freshVar exprResult.ctx

        writeAttrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr exprResult.resultType ])

        ( ctx3, writeOp ) =
            Ops.mlirOp ctx2 "bf.write.encoder"
                |> Ops.opBuilder.withOperands [ state.cursor, exprResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.withAttrs writeAttrs
                |> Ops.opBuilder.build
    in
    { state
        | ctx = ctx3
        , cursor = newCursor
        , hoisted = hoisted
        , ops = writeOp :: (List.reverse exprResult.ops ++ state.ops)
    }


{-| Emits a `bf.write.utf8` of the string value of `strExpr`, and moves the
cursor past it.
-}
emitWriteUtf8 : Mono.MonoExpr -> EmitState -> EmitState
emitWriteUtf8 strExpr state =
    let
        ( exprResult, hoisted ) =
            compileValue strExpr state

        ( newCursor, ctx2 ) =
            Context.freshVar exprResult.ctx

        writeAttrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr exprResult.resultType ])

        ( ctx3, writeOp ) =
            Ops.mlirOp ctx2 "bf.write.utf8"
                |> Ops.opBuilder.withOperands [ state.cursor, exprResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.withAttrs writeAttrs
                |> Ops.opBuilder.build
    in
    { state
        | ctx = ctx3
        , cursor = newCursor
        , hoisted = hoisted
        , ops = writeOp :: (List.reverse exprResult.ops ++ state.ops)
    }


{-| Emits a loop that runs the body operations once for each item of the list
`iterExpr` produces, in list order, and leaves the cursor after the last item.

The loop is an `scf.while` carrying the cursor and the rest of the list. Its
condition is that the list is not empty, tested by comparing the list's tag with
`CtorTag.constantTag`, since the empty list is an embedded constant. Its body
projects the head and the tail, binds `itemVar` to the head so that the body's
expressions can refer to the item, emits the body operations with their own
cursor, and passes on the new cursor and the tail.

The head is projected at the item type's ABI type: `i64` for an `Int`, `f64`
for a `Float`, `i32` for a `Char`, and `!eco.value` for anything else.

    %list = <iterExpr>
    %cur_end, %rest = scf.while (%cur = <cursor>, %lst = %list) {
      %is_cons = <tag of %lst is not the constant tag>
      scf.condition (%is_cons) %cur, %lst
    } do {
    ^bb0(%cur, %lst):
      %head = eco.project.list_head %lst
      %tail = eco.project.list_tail %lst
      <body writes from %cur to %new_cur, with itemVar bound to %head>
      scf.yield %new_cur, %tail
    }

-}
emitWriteEachItem :
    { cursorName : String
    , itemVar : String
    , itemType : Mono.MonoType
    , bodyOps : List Op
    , iterExpr : Mono.MonoExpr
    , itemByteWidth : Int
    }
    -> EmitState
    -> EmitState
emitWriteEachItem r state =
    let
        ( iterResult, hoisted ) =
            compileValue r.iterExpr state

        ctx0 =
            iterResult.ctx

        ( whileCursorResult, ctx1 ) =
            Context.freshVar ctx0

        ( whileListResult, ctx2 ) =
            Context.freshVar ctx1

        ( beforeCursorArg, ctx3 ) =
            Context.freshVar ctx2

        ( beforeListArg, ctx4 ) =
            Context.freshVar ctx3

        ( tagVar, ctx5 ) =
            Context.freshVar ctx4

        ( ctx6, tagOp ) =
            Ops.mlirOp ctx5 "eco.get_tag"
                |> Ops.opBuilder.withOperands [ beforeListArg ]
                |> Ops.opBuilder.withResults [ ( tagVar, I32 ) ]
                |> Ops.opBuilder.withAttrs
                    (Dict.singleton "_operand_types"
                        (ArrayAttr Nothing [ TypeAttr Types.ecoValue ])
                    )
                |> Ops.opBuilder.build

        -- The empty list is an embedded constant, whose tag reads as
        -- CtorTag.constantTag, not 0.
        ( nilTagVar, ctx7 ) =
            Context.freshVar ctx6

        ( ctx8, nilTagOp ) =
            Ops.mlirOp ctx7 "arith.constant"
                |> Ops.opBuilder.withResults [ ( nilTagVar, I32 ) ]
                |> Ops.opBuilder.withAttrs (Dict.singleton "value" (IntAttr (Just I32) CtorTag.constantTag))
                |> Ops.opBuilder.build

        ( isNilVar, ctx9 ) =
            Context.freshVar ctx8

        -- Predicate 0 is eq.
        ( ctx10, cmpEqOp ) =
            Ops.mlirOp ctx9 "arith.cmpi"
                |> Ops.opBuilder.withOperands [ tagVar, nilTagVar ]
                |> Ops.opBuilder.withResults [ ( isNilVar, I1 ) ]
                |> Ops.opBuilder.withAttrs
                    (Dict.fromList
                        [ ( "predicate", IntAttr Nothing 0 )
                        , ( "_operand_types", ArrayAttr Nothing [ TypeAttr I32, TypeAttr I32 ] )
                        ]
                    )
                |> Ops.opBuilder.build

        ( trueVar, ctx11 ) =
            Context.freshVar ctx10

        ( ctx12, trueOp ) =
            Ops.mlirOp ctx11 "arith.constant"
                |> Ops.opBuilder.withResults [ ( trueVar, I1 ) ]
                |> Ops.opBuilder.withAttrs (Dict.singleton "value" (IntAttr (Just I1) 1))
                |> Ops.opBuilder.build

        ( isConsVar, ctx13 ) =
            Context.freshVar ctx12

        ( ctx14, xoriOp ) =
            Ops.mlirOp ctx13 "arith.xori"
                |> Ops.opBuilder.withOperands [ isNilVar, trueVar ]
                |> Ops.opBuilder.withResults [ ( isConsVar, I1 ) ]
                |> Ops.opBuilder.withAttrs
                    (Dict.singleton "_operand_types"
                        (ArrayAttr Nothing [ TypeAttr I1, TypeAttr I1 ])
                    )
                |> Ops.opBuilder.build

        ( ctx15, conditionOp ) =
            Ops.scfCondition ctx14
                isConsVar
                [ ( beforeCursorArg, bfCursorType )
                , ( beforeListArg, Types.ecoValue )
                ]

        beforeRegion =
            Ops.mkRegion
                [ ( beforeCursorArg, bfCursorType )
                , ( beforeListArg, Types.ecoValue )
                ]
                [ tagOp, nilTagOp, cmpEqOp, trueOp, xoriOp ]
                conditionOp

        ( afterCursorArg, ctx16 ) =
            Context.freshVar ctx15

        ( afterListArg, ctx17 ) =
            Context.freshVar ctx16

        -- An Int or Float head is projected unboxed, never as !eco.value and
        -- then unboxed: the head may be stored unboxed, and unboxing would
        -- read that raw word as a heap pointer.
        headType =
            Types.monoTypeToAbi r.itemType

        ( headVar, ctx18 ) =
            Context.freshVar ctx17

        ( ctx19, headOp ) =
            Ops.mlirOp ctx18 "eco.project.list_head"
                |> Ops.opBuilder.withOperands [ afterListArg ]
                |> Ops.opBuilder.withResults [ ( headVar, headType ) ]
                |> Ops.opBuilder.withAttrs
                    (Dict.singleton "_operand_types"
                        (ArrayAttr Nothing [ TypeAttr Types.ecoValue ])
                    )
                |> Ops.opBuilder.build

        ( tailVar, ctx20 ) =
            Context.freshVar ctx19

        ( ctx21, tailOp ) =
            Ops.mlirOp ctx20 "eco.project.list_tail"
                |> Ops.opBuilder.withOperands [ afterListArg ]
                |> Ops.opBuilder.withResults [ ( tailVar, Types.ecoValue ) ]
                |> Ops.opBuilder.withAttrs
                    (Dict.singleton "_operand_types"
                        (ArrayAttr Nothing [ TypeAttr Types.ecoValue ])
                    )
                |> Ops.opBuilder.build

        ctxBody =
            Context.addVarMapping r.itemVar headVar headType ctx21

        -- The body's ops go inside the region, and its values are compiled
        -- there, not taken from the hoisted ones.
        bodyInitState =
            { state | ctx = ctxBody, cursor = afterCursorArg, ops = [], hoisted = [] }

        finalBodyState =
            List.foldl emitOp bodyInitState r.bodyOps

        newCursorVar =
            finalBodyState.cursor

        ( ctx23, yieldOp ) =
            Ops.mlirOp finalBodyState.ctx "scf.yield"
                |> Ops.opBuilder.withOperands [ newCursorVar, tailVar ]
                |> Ops.opBuilder.withAttrs
                    (Dict.singleton "_operand_types"
                        (ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr Types.ecoValue ])
                    )
                |> Ops.opBuilder.build

        afterRegion =
            Ops.mkRegion
                [ ( afterCursorArg, bfCursorType )
                , ( afterListArg, Types.ecoValue )
                ]
                ([ headOp, tailOp ] ++ List.reverse finalBodyState.ops)
                yieldOp

        ( ctx24, whileOp ) =
            Ops.scfWhile ctx23
                [ ( whileCursorResult, state.cursor, bfCursorType )
                , ( whileListResult, iterResult.resultVar, Types.ecoValue )
                ]
                beforeRegion
                afterRegion
    in
    { state
        | ctx = ctx24
        , cursor = whileCursorResult
        , hoisted = hoisted
        , ops = whileOp :: (List.reverse iterResult.ops ++ state.ops)
    }


-- ============================================================================
-- Decoder Emission
-- ============================================================================


{-| The state threaded through the emission of a decoder, down through its
nested `scf.if` operations.

`decodedVars` holds the SSA names of the values produced so far, most recent
first; the head is what the decoder gives when it reaches its end.
`varMapping` maps each placeholder named in the operations to the SSA name of
the value produced for it, and `varTypes` gives the MLIR type of those SSA
names.

-}
type alias DecoderEmitState =
    { ctx : Context
    , cursor : String
    , bytesVar : String
    , decodedVars : List String
    , compileExpr : ExprCompiler
    , varMapping : Dict.Dict String String
    , varTypes : Dict.Dict String MlirType
    }


{-| Emits the decoder described by `ops`, reading the bytes value whose SSA name
is `bytesVar` and compiling its expressions with `compileExpr`. Returns the ops
in order, the SSA name of the decoder's `Maybe` result, and the context after
them.

The result is `Nothing` when a read finds too few bytes left, when a UTF-8 read
finds invalid UTF-8, when a decoding loop runs out of input, when a counted
loop's total byte count does not fit in 32 bits, or when the operations end in
`ReturnNothing`. Otherwise it is `Just` the value of the
`ReturnJust` placeholder, or `Just` the last value produced when the operations
end without one, or `Just ()` when they produce none. An `Int`, `Float` or
`Char` result is stored unboxed in the `Just`.

-}
emitFusedDecoder : ExprCompiler -> Context -> String -> List IR.DecoderOp -> ( List MlirOp, String, Context )
emitFusedDecoder compileExpr ctx bytesVar ops =
    let
        ( cursorVar, ctx1 ) =
            Context.freshVar ctx

        initAttrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr Types.ecoValue ])

        ( ctx2, initOp ) =
            Ops.mlirOp ctx1 "bf.decoder.cursor.init"
                |> Ops.opBuilder.withOperands [ bytesVar ]
                |> Ops.opBuilder.withResults [ ( cursorVar, bfCursorType ) ]
                |> Ops.opBuilder.withAttrs initAttrs
                |> Ops.opBuilder.build

        initialState =
            { ctx = ctx2
            , cursor = cursorVar
            , bytesVar = bytesVar
            , decodedVars = []
            , compileExpr = compileExpr
            , varMapping = Dict.empty
            , varTypes = Dict.empty
            }

        remainingOps =
            List.filter (not << isInitReadCursor) ops

        ( resultOps, resultVar, finalCtx ) =
            emitDecoderOpsNested remainingOps initialState
    in
    ( initOp :: resultOps, resultVar, finalCtx )


{-| Returns whether a decoder operation is `InitReadCursor`.
-}
isInitReadCursor : DecoderOp -> Bool
isInitReadCursor op =
    case op of
        InitReadCursor _ _ ->
            True

        _ ->
            False


{-| Emits the decoder operations `ops` from `state`. Returns the ops, the SSA
name of the `Maybe` result, and the context after them.

A read emits a `bf.require` of its bytes and an `scf.if` on the result. The
then-branch holds the read and everything emitted for the operations after it;
the else-branch gives the embedded `Nothing` constant.

    %ok = bf.require %cur, <width>
    %result = scf.if %ok -> !eco.value {
      %value, %next = bf.read.<kind> %cur
      <the remaining operations, from %next>
      scf.yield %rest
    } else {
      %nothing = <Nothing>
      scf.yield %nothing
    }

`Apply*` and `PushValue` operations emit their ops in line, with no check. Each
operation's value is recorded against its placeholder in `varMapping`, which is
how a later operation, such as a read whose length is an earlier value, finds it.

`ReturnJust` ends the decoder with `Just` its placeholder's value; a placeholder
with no value falls back to the last value produced. Operations after a
`ReturnJust` or `ReturnNothing` are ignored.

-}
emitDecoderOpsNested : List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitDecoderOpsNested ops state =
    case ops of
        [] ->
            emitJustResult state

        (InitReadCursor _ _) :: rest ->
            emitDecoderOpsNested rest state

        (ReadU8 _ placeholderVar) :: rest ->
            emitReadWithNestedScfIf 1 "bf.read.u8" Nothing I64 placeholderVar rest state

        (ReadI8 _ placeholderVar) :: rest ->
            emitReadWithNestedScfIf 1 "bf.read.i8" Nothing I64 placeholderVar rest state

        (ReadU16 _ endian placeholderVar) :: rest ->
            emitReadWithNestedScfIf 2 "bf.read.u16" (Just endian) I64 placeholderVar rest state

        (ReadI16 _ endian placeholderVar) :: rest ->
            emitReadWithNestedScfIf 2 "bf.read.i16" (Just endian) I64 placeholderVar rest state

        (ReadU32 _ endian placeholderVar) :: rest ->
            emitReadWithNestedScfIf 4 "bf.read.u32" (Just endian) I64 placeholderVar rest state

        (ReadI32 _ endian placeholderVar) :: rest ->
            emitReadWithNestedScfIf 4 "bf.read.i32" (Just endian) I64 placeholderVar rest state

        (ReadF32 _ endian placeholderVar) :: rest ->
            emitReadWithNestedScfIf 4 "bf.read.f32" (Just endian) F64 placeholderVar rest state

        (ReadF64 _ endian placeholderVar) :: rest ->
            emitReadWithNestedScfIf 8 "bf.read.f64" (Just endian) F64 placeholderVar rest state

        (ReadBytes _ lenExpr placeholderVar) :: rest ->
            emitReadBytesNested lenExpr placeholderVar rest state

        (ReadUtf8 _ lenExpr placeholderVar) :: rest ->
            emitReadUtf8Nested lenExpr placeholderVar rest state

        (ReadBytesVar _ lenPlaceholderVar resultPlaceholderVar) :: rest ->
            emitReadBytesVarNested lenPlaceholderVar resultPlaceholderVar rest state

        (ReadUtf8Var _ lenPlaceholderVar resultPlaceholderVar) :: rest ->
            emitReadUtf8VarNested lenPlaceholderVar resultPlaceholderVar rest state

        (Apply1 fnExpr argPlaceholder resultPlaceholder) :: rest ->
            emitApplyNested fnExpr [ argPlaceholder ] resultPlaceholder rest state

        (Apply2 fnExpr arg1 arg2 resultPlaceholder) :: rest ->
            emitApplyNested fnExpr [ arg1, arg2 ] resultPlaceholder rest state

        (Apply3 fnExpr arg1 arg2 arg3 resultPlaceholder) :: rest ->
            emitApplyNested fnExpr [ arg1, arg2, arg3 ] resultPlaceholder rest state

        (Apply4 fnExpr arg1 arg2 arg3 arg4 resultPlaceholder) :: rest ->
            emitApplyNested fnExpr [ arg1, arg2, arg3, arg4 ] resultPlaceholder rest state

        (Apply5 fnExpr arg1 arg2 arg3 arg4 arg5 resultPlaceholder) :: rest ->
            emitApplyNested fnExpr [ arg1, arg2, arg3, arg4, arg5 ] resultPlaceholder rest state

        (PushValue valueExpr placeholderVar) :: rest ->
            emitPushValueNested valueExpr placeholderVar rest state

        (LoopDecodeList count _ itemOps order resultPlaceholder) :: rest ->
            emitLoopDecodeListNested count itemOps order resultPlaceholder rest state

        (LoopSentinelDecodeList sentinel _ itemOps order resultPlaceholder) :: rest ->
            emitLoopSentinelDecodeListNested sentinel itemOps order resultPlaceholder rest state

        (ReturnJust resultPlaceholder) :: _ ->
            case Dict.get resultPlaceholder state.varMapping of
                Just actualVar ->
                    emitJustResultWithVar actualVar state

                Nothing ->
                    case state.decodedVars of
                        topVar :: _ ->
                            emitJustResultWithVar topVar state

                        [] ->
                            emitJustResult state

        ReturnNothing :: _ ->
            emitNothingResult state


{-| Emits a read of `byteCount` bytes by the op `readOpName`, guarded by a
`bf.require`, with the remaining operations `restOps` nested in the guard's
then-branch. The value read, of type `resultType`, is bound to `placeholderVar`.
-}
emitReadWithNestedScfIf : Int -> String -> Maybe Endianness -> MlirType -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitReadWithNestedScfIf byteCount readOpName maybeEndian resultType placeholderVar restOps state =
    let
        ( bytesConstVar, ctx0 ) =
            Context.freshVar state.ctx

        ( ctx0b, bytesConstOp ) =
            Ops.mlirOp ctx0 "arith.constant"
                |> Ops.opBuilder.withResults [ ( bytesConstVar, I32 ) ]
                |> Ops.opBuilder.withAttrs (Dict.singleton "value" (IntAttr (Just I32) byteCount))
                |> Ops.opBuilder.build

        ( okVar, ctx1 ) =
            Context.freshVar ctx0b

        requireAttrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr I32 ])

        ( ctx2, requireOp ) =
            Ops.mlirOp ctx1 "bf.require"
                |> Ops.opBuilder.withOperands [ state.cursor, bytesConstVar ]
                |> Ops.opBuilder.withResults [ ( okVar, I1 ) ]
                |> Ops.opBuilder.withAttrs requireAttrs
                |> Ops.opBuilder.build

        ( valueVar, ctx3 ) =
            Context.freshVar ctx2

        ( newCursor, ctx4 ) =
            Context.freshVar ctx3

        endianAttrs =
            let
                baseAttrs =
                    Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr bfCursorType ])
            in
            case maybeEndian of
                Just endian ->
                    Dict.insert "endianness" (endianToAttr endian) baseAttrs

                Nothing ->
                    baseAttrs

        ( ctx5, readOp ) =
            Ops.mlirOp ctx4 readOpName
                |> Ops.opBuilder.withOperands [ state.cursor ]
                |> Ops.opBuilder.withAttrs endianAttrs
                |> Ops.opBuilder.withResults [ ( valueVar, resultType ), ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.build

        updatedState =
            { state
                | ctx = ctx5
                , cursor = newCursor
                , decodedVars = valueVar :: state.decodedVars
                , varMapping = Dict.insert placeholderVar valueVar state.varMapping
                , varTypes = Dict.insert valueVar resultType state.varTypes
            }

        ( thenBodyOps, thenResultVar, ctx6 ) =
            emitDecoderOpsNested restOps updatedState

        ( ctx7, thenYieldOp ) =
            Ops.mlirOp ctx6 "scf.yield"
                |> Ops.opBuilder.withOperands [ thenResultVar ]
                |> Ops.opBuilder.build

        thenRegion =
            Ops.mkRegion [] (readOp :: thenBodyOps) thenYieldOp

        ( nothingVar, ctx8 ) =
            Context.freshVar ctx7

        ( ctx9, nothingOp ) =
            Ops.ecoConstantNothing ctx8 nothingVar

        ( ctx10, elseYieldOp ) =
            Ops.mlirOp ctx9 "scf.yield"
                |> Ops.opBuilder.withOperands [ nothingVar ]
                |> Ops.opBuilder.build

        elseRegion =
            Ops.mkRegion [] [ nothingOp ] elseYieldOp

        ( ifResultVar, ctx11 ) =
            Context.freshVar ctx10

        ( ctx12, ifOp ) =
            Ops.mlirOp ctx11 "scf.if"
                |> Ops.opBuilder.withOperands [ okVar ]
                |> Ops.opBuilder.withResults [ ( ifResultVar, Types.ecoValue ) ]
                |> Ops.opBuilder.withRegions [ thenRegion, elseRegion ]
                |> Ops.opBuilder.build
    in
    ( [ bytesConstOp, requireOp, ifOp ], ifResultVar, ctx12 )


{-| Emits a read of a bytes value whose length is the value of `lenExpr`,
truncated to `i32`, guarded by a `bf.require` of that length, with the
remaining operations nested in the guard's then-branch. The bytes read are
bound to `placeholderVar`.
-}
emitReadBytesNested : Mono.MonoExpr -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitReadBytesNested lenExpr placeholderVar restOps state =
    let
        lenResult =
            state.compileExpr lenExpr state.ctx

        ( lenI32Var, ctxTrunc0 ) =
            Context.freshVar lenResult.ctx

        truncAttrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr lenResult.resultType ])

        ( ctxTrunc1, truncOp ) =
            Ops.mlirOp ctxTrunc0 "arith.trunci"
                |> Ops.opBuilder.withOperands [ lenResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( lenI32Var, I32 ) ]
                |> Ops.opBuilder.withAttrs truncAttrs
                |> Ops.opBuilder.build

        ( okVar, ctx1 ) =
            Context.freshVar ctxTrunc1

        requireAttrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr I32 ])

        ( ctx2, requireOp ) =
            Ops.mlirOp ctx1 "bf.require"
                |> Ops.opBuilder.withOperands [ state.cursor, lenI32Var ]
                |> Ops.opBuilder.withResults [ ( okVar, I1 ) ]
                |> Ops.opBuilder.withAttrs requireAttrs
                |> Ops.opBuilder.build

        ( bytesVar, ctx3 ) =
            Context.freshVar ctx2

        ( newCursor, ctx4 ) =
            Context.freshVar ctx3

        ( readOkVar, ctx4b ) =
            Context.freshVar ctx4

        readAttrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr I32 ])

        ( ctx5, readOp ) =
            Ops.mlirOp ctx4b "bf.read.bytes"
                |> Ops.opBuilder.withOperands [ state.cursor, lenI32Var ]
                |> Ops.opBuilder.withAttrs readAttrs
                |> Ops.opBuilder.withResults [ ( bytesVar, Types.ecoValue ), ( newCursor, bfCursorType ), ( readOkVar, I1 ) ]
                |> Ops.opBuilder.build

        updatedState =
            { state
                | ctx = ctx5
                , cursor = newCursor
                , decodedVars = bytesVar :: state.decodedVars
                , varMapping = Dict.insert placeholderVar bytesVar state.varMapping
                , varTypes = Dict.insert bytesVar Types.ecoValue state.varTypes
            }

        ( thenBodyOps, thenResultVar, ctx6 ) =
            emitDecoderOpsNested restOps updatedState

        ( ctx7, thenYieldOp ) =
            Ops.mlirOp ctx6 "scf.yield"
                |> Ops.opBuilder.withOperands [ thenResultVar ]
                |> Ops.opBuilder.build

        thenRegion =
            Ops.mkRegion [] (readOp :: thenBodyOps) thenYieldOp

        ( nothingVar, ctx8 ) =
            Context.freshVar ctx7

        ( ctx9, nothingOp ) =
            Ops.ecoConstantNothing ctx8 nothingVar

        ( ctx10, elseYieldOp ) =
            Ops.mlirOp ctx9 "scf.yield"
                |> Ops.opBuilder.withOperands [ nothingVar ]
                |> Ops.opBuilder.build

        elseRegion =
            Ops.mkRegion [] [ nothingOp ] elseYieldOp

        ( ifResultVar, ctx11 ) =
            Context.freshVar ctx10

        ( ctx12, ifOp ) =
            Ops.mlirOp ctx11 "scf.if"
                |> Ops.opBuilder.withOperands [ okVar ]
                |> Ops.opBuilder.withResults [ ( ifResultVar, Types.ecoValue ) ]
                |> Ops.opBuilder.withRegions [ thenRegion, elseRegion ]
                |> Ops.opBuilder.build
    in
    ( lenResult.ops ++ [ truncOp, requireOp, ifOp ], ifResultVar, ctx12 )


{-| Emits a read of a UTF-8 string whose length in bytes is the value of
`lenExpr`, truncated to `i32`, and binds the string to `placeholderVar`. A
`bf.require` of that length guards the read, and the read's own result saying
the bytes are valid UTF-8 guards the remaining operations; either failing gives
`Nothing`.
-}
emitReadUtf8Nested : Mono.MonoExpr -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitReadUtf8Nested lenExpr placeholderVar restOps state =
    let
        lenResult =
            state.compileExpr lenExpr state.ctx

        ( lenI32Var, ctxTrunc0 ) =
            Context.freshVar lenResult.ctx

        truncAttrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr lenResult.resultType ])

        ( ctxTrunc1, truncOp ) =
            Ops.mlirOp ctxTrunc0 "arith.trunci"
                |> Ops.opBuilder.withOperands [ lenResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( lenI32Var, I32 ) ]
                |> Ops.opBuilder.withAttrs truncAttrs
                |> Ops.opBuilder.build

        ( okVar, ctx1 ) =
            Context.freshVar ctxTrunc1

        requireAttrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr I32 ])

        ( ctx2, requireOp ) =
            Ops.mlirOp ctx1 "bf.require"
                |> Ops.opBuilder.withOperands [ state.cursor, lenI32Var ]
                |> Ops.opBuilder.withResults [ ( okVar, I1 ) ]
                |> Ops.opBuilder.withAttrs requireAttrs
                |> Ops.opBuilder.build

        ( stringVar, ctx3 ) =
            Context.freshVar ctx2

        ( newCursor, ctx4 ) =
            Context.freshVar ctx3

        ( readOkVar, ctx4b ) =
            Context.freshVar ctx4

        readAttrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr I32 ])

        ( ctx5, readOp ) =
            Ops.mlirOp ctx4b "bf.read.utf8"
                |> Ops.opBuilder.withOperands [ state.cursor, lenI32Var ]
                |> Ops.opBuilder.withAttrs readAttrs
                |> Ops.opBuilder.withResults [ ( stringVar, Types.ecoValue ), ( newCursor, bfCursorType ), ( readOkVar, I1 ) ]
                |> Ops.opBuilder.build

        updatedState =
            { state
                | ctx = ctx5
                , cursor = newCursor
                , decodedVars = stringVar :: state.decodedVars
                , varMapping = Dict.insert placeholderVar stringVar state.varMapping
                , varTypes = Dict.insert stringVar Types.ecoValue state.varTypes
            }

        ( validIfOp, validIfVar, ctx6 ) =
            emitIfElseNothing readOkVar (emitDecoderOpsNested restOps updatedState)

        ( ctx7, thenYieldOp ) =
            Ops.mlirOp ctx6 "scf.yield"
                |> Ops.opBuilder.withOperands [ validIfVar ]
                |> Ops.opBuilder.build

        thenRegion =
            Ops.mkRegion [] [ readOp, validIfOp ] thenYieldOp

        ( nothingVar, ctx8 ) =
            Context.freshVar ctx7

        ( ctx9, nothingOp ) =
            Ops.ecoConstantNothing ctx8 nothingVar

        ( ctx10, elseYieldOp ) =
            Ops.mlirOp ctx9 "scf.yield"
                |> Ops.opBuilder.withOperands [ nothingVar ]
                |> Ops.opBuilder.build

        elseRegion =
            Ops.mkRegion [] [ nothingOp ] elseYieldOp

        ( ifResultVar, ctx11 ) =
            Context.freshVar ctx10

        ( ctx12, ifOp ) =
            Ops.mlirOp ctx11 "scf.if"
                |> Ops.opBuilder.withOperands [ okVar ]
                |> Ops.opBuilder.withResults [ ( ifResultVar, Types.ecoValue ) ]
                |> Ops.opBuilder.withRegions [ thenRegion, elseRegion ]
                |> Ops.opBuilder.build
    in
    ( lenResult.ops ++ [ truncOp, requireOp, ifOp ], ifResultVar, ctx12 )


{-| Emits a read of a bytes value whose length is the earlier value bound to
`lenPlaceholderVar`, as `emitReadBytesNested` does for a length expression, and
binds the bytes to `resultPlaceholderVar`. A placeholder with no value is used
as an SSA name itself, and a value of unknown type is taken to be an `i64`.
-}
emitReadBytesVarNested : String -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitReadBytesVarNested lenPlaceholderVar resultPlaceholderVar restOps state =
    let
        actualLenVar =
            Dict.get lenPlaceholderVar state.varMapping
                |> Maybe.withDefault lenPlaceholderVar

        lenType =
            Dict.get actualLenVar state.varTypes
                |> Maybe.withDefault I64

        ( lenI32Var, ctxTrunc0 ) =
            Context.freshVar state.ctx

        truncAttrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr lenType ])

        ( ctxTrunc1, truncOp ) =
            Ops.mlirOp ctxTrunc0 "arith.trunci"
                |> Ops.opBuilder.withOperands [ actualLenVar ]
                |> Ops.opBuilder.withResults [ ( lenI32Var, I32 ) ]
                |> Ops.opBuilder.withAttrs truncAttrs
                |> Ops.opBuilder.build

        ( okVar, ctx1 ) =
            Context.freshVar ctxTrunc1

        requireAttrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr I32 ])

        ( ctx2, requireOp ) =
            Ops.mlirOp ctx1 "bf.require"
                |> Ops.opBuilder.withOperands [ state.cursor, lenI32Var ]
                |> Ops.opBuilder.withResults [ ( okVar, I1 ) ]
                |> Ops.opBuilder.withAttrs requireAttrs
                |> Ops.opBuilder.build

        ( bytesVar, ctx3 ) =
            Context.freshVar ctx2

        ( newCursor, ctx4 ) =
            Context.freshVar ctx3

        ( readOkVar, ctx4b ) =
            Context.freshVar ctx4

        readAttrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr I32 ])

        ( ctx5, readOp ) =
            Ops.mlirOp ctx4b "bf.read.bytes"
                |> Ops.opBuilder.withOperands [ state.cursor, lenI32Var ]
                |> Ops.opBuilder.withAttrs readAttrs
                |> Ops.opBuilder.withResults [ ( bytesVar, Types.ecoValue ), ( newCursor, bfCursorType ), ( readOkVar, I1 ) ]
                |> Ops.opBuilder.build

        updatedState =
            { state
                | ctx = ctx5
                , cursor = newCursor
                , decodedVars = bytesVar :: state.decodedVars
                , varMapping = Dict.insert resultPlaceholderVar bytesVar state.varMapping
                , varTypes = Dict.insert bytesVar Types.ecoValue state.varTypes
            }

        ( thenBodyOps, thenResultVar, ctx6 ) =
            emitDecoderOpsNested restOps updatedState

        ( ctx7, thenYieldOp ) =
            Ops.mlirOp ctx6 "scf.yield"
                |> Ops.opBuilder.withOperands [ thenResultVar ]
                |> Ops.opBuilder.build

        thenRegion =
            Ops.mkRegion [] (readOp :: thenBodyOps) thenYieldOp

        ( nothingVar, ctx8 ) =
            Context.freshVar ctx7

        ( ctx9, nothingOp ) =
            Ops.ecoConstantNothing ctx8 nothingVar

        ( ctx10, elseYieldOp ) =
            Ops.mlirOp ctx9 "scf.yield"
                |> Ops.opBuilder.withOperands [ nothingVar ]
                |> Ops.opBuilder.build

        elseRegion =
            Ops.mkRegion [] [ nothingOp ] elseYieldOp

        ( ifResultVar, ctx11 ) =
            Context.freshVar ctx10

        ( ctx12, ifOp ) =
            Ops.mlirOp ctx11 "scf.if"
                |> Ops.opBuilder.withOperands [ okVar ]
                |> Ops.opBuilder.withResults [ ( ifResultVar, Types.ecoValue ) ]
                |> Ops.opBuilder.withRegions [ thenRegion, elseRegion ]
                |> Ops.opBuilder.build
    in
    ( [ truncOp, requireOp, ifOp ], ifResultVar, ctx12 )


{-| Emits a read of a UTF-8 string whose length in bytes is the earlier value
bound to `lenPlaceholderVar`, as `emitReadUtf8Nested` does for a length
expression, and binds the string to `resultPlaceholderVar`. A placeholder with
no value is used as an SSA name itself, and a value of unknown type is taken to
be an `i64`.
-}
emitReadUtf8VarNested : String -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitReadUtf8VarNested lenPlaceholderVar resultPlaceholderVar restOps state =
    let
        actualLenVar =
            Dict.get lenPlaceholderVar state.varMapping
                |> Maybe.withDefault lenPlaceholderVar

        lenType =
            Dict.get actualLenVar state.varTypes
                |> Maybe.withDefault I64

        ( lenI32Var, ctxTrunc0 ) =
            Context.freshVar state.ctx

        truncAttrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr lenType ])

        ( ctxTrunc1, truncOp ) =
            Ops.mlirOp ctxTrunc0 "arith.trunci"
                |> Ops.opBuilder.withOperands [ actualLenVar ]
                |> Ops.opBuilder.withResults [ ( lenI32Var, I32 ) ]
                |> Ops.opBuilder.withAttrs truncAttrs
                |> Ops.opBuilder.build

        ( okVar, ctx1 ) =
            Context.freshVar ctxTrunc1

        requireAttrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr I32 ])

        ( ctx2, requireOp ) =
            Ops.mlirOp ctx1 "bf.require"
                |> Ops.opBuilder.withOperands [ state.cursor, lenI32Var ]
                |> Ops.opBuilder.withResults [ ( okVar, I1 ) ]
                |> Ops.opBuilder.withAttrs requireAttrs
                |> Ops.opBuilder.build

        ( stringVar, ctx3 ) =
            Context.freshVar ctx2

        ( newCursor, ctx4 ) =
            Context.freshVar ctx3

        ( readOkVar, ctx4b ) =
            Context.freshVar ctx4

        readAttrs =
            Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr I32 ])

        ( ctx5, readOp ) =
            Ops.mlirOp ctx4b "bf.read.utf8"
                |> Ops.opBuilder.withOperands [ state.cursor, lenI32Var ]
                |> Ops.opBuilder.withAttrs readAttrs
                |> Ops.opBuilder.withResults [ ( stringVar, Types.ecoValue ), ( newCursor, bfCursorType ), ( readOkVar, I1 ) ]
                |> Ops.opBuilder.build

        updatedState =
            { state
                | ctx = ctx5
                , cursor = newCursor
                , decodedVars = stringVar :: state.decodedVars
                , varMapping = Dict.insert resultPlaceholderVar stringVar state.varMapping
                , varTypes = Dict.insert stringVar Types.ecoValue state.varTypes
            }

        ( validIfOp, validIfVar, ctx6 ) =
            emitIfElseNothing readOkVar (emitDecoderOpsNested restOps updatedState)

        ( ctx7, thenYieldOp ) =
            Ops.mlirOp ctx6 "scf.yield"
                |> Ops.opBuilder.withOperands [ validIfVar ]
                |> Ops.opBuilder.build

        thenRegion =
            Ops.mkRegion [] [ readOp, validIfOp ] thenYieldOp

        ( nothingVar, ctx8 ) =
            Context.freshVar ctx7

        ( ctx9, nothingOp ) =
            Ops.ecoConstantNothing ctx8 nothingVar

        ( ctx10, elseYieldOp ) =
            Ops.mlirOp ctx9 "scf.yield"
                |> Ops.opBuilder.withOperands [ nothingVar ]
                |> Ops.opBuilder.build

        elseRegion =
            Ops.mkRegion [] [ nothingOp ] elseYieldOp

        ( ifResultVar, ctx11 ) =
            Context.freshVar ctx10

        ( ctx12, ifOp ) =
            Ops.mlirOp ctx11 "scf.if"
                |> Ops.opBuilder.withOperands [ okVar ]
                |> Ops.opBuilder.withResults [ ( ifResultVar, Types.ecoValue ) ]
                |> Ops.opBuilder.withRegions [ thenRegion, elseRegion ]
                |> Ops.opBuilder.build
    in
    ( [ truncOp, requireOp, ifOp ], ifResultVar, ctx12 )


{-| Emits an `eco.papExtend` that applies the function `fnExpr` compiles to to
the values bound to `argPlaceholders`, binds the result to `resultPlaceholder`,
and emits the remaining operations after it.

The result's type is taken from `fnExpr`'s type after as many arguments as are
given. An argument placeholder with no value is used as an SSA name itself, and
one of unknown type is taken to be an `!eco.value`.

-}
emitApplyNested : Mono.MonoExpr -> List String -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitApplyNested fnExpr argPlaceholders resultPlaceholder restOps state =
    let
        fnResult =
            state.compileExpr fnExpr state.ctx

        actualArgVarsAndTypes =
            List.map
                (\placeholder ->
                    let
                        var =
                            Dict.get placeholder state.varMapping
                                |> Maybe.withDefault placeholder

                        ty =
                            Dict.get var state.varTypes
                                |> Maybe.withDefault Types.ecoValue
                    in
                    ( var, ty )
                )
                argPlaceholders

        actualArgVars =
            List.map Tuple.first actualArgVarsAndTypes

        actualArgTypes =
            List.map Tuple.second actualArgVarsAndTypes

        saturatedResultType =
            fnExprReturnType fnExpr (List.length argPlaceholders)

        ( resVar, ctx1 ) =
            Context.freshVar fnResult.ctx

        allOperandNames =
            fnResult.resultVar :: actualArgVars

        allOperandTypes =
            fnResult.resultType :: actualArgTypes

        papExtendAttrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr allOperandTypes) )
                , ( "remaining_arity", IntAttr Nothing (List.length argPlaceholders) )
                , ( "slot_kinds", Ops.slotKindsAttr actualArgTypes )
                ]

        ( ctx2, papExtendOp ) =
            Ops.mlirOp ctx1 "eco.papExtend"
                |> Ops.opBuilder.withOperands allOperandNames
                |> Ops.opBuilder.withResults [ ( resVar, saturatedResultType ) ]
                |> Ops.opBuilder.withAttrs papExtendAttrs
                |> Ops.opBuilder.build

        updatedState =
            { state
                | ctx = ctx2
                , decodedVars = resVar :: state.decodedVars
                , varMapping = Dict.insert resultPlaceholder resVar state.varMapping
                , varTypes = Dict.insert resVar saturatedResultType state.varTypes
            }

        ( restBodyOps, resultVar, finalCtx ) =
            emitDecoderOpsNested restOps updatedState
    in
    ( fnResult.ops ++ [ papExtendOp ] ++ restBodyOps, resultVar, finalCtx )


{-| Returns the ABI type of what `fnExpr` returns once applied to `nArgs`
arguments, from the type recorded on the expression.
-}
fnExprReturnType : Mono.MonoExpr -> Int -> MlirType
fnExprReturnType fnExpr nArgs =
    let
        fnType =
            monoExprType fnExpr
    in
    Types.monoTypeToAbi (uncurryReturnType fnType nArgs)


{-| Returns the type left after a function of type `monoType` consumes
`remainingArgs` arguments, stepping through nested function types as many
parameters at a time as each has. A type that is not a function is returned as
it is, even with arguments left over.
-}
uncurryReturnType : Mono.MonoType -> Int -> Mono.MonoType
uncurryReturnType monoType remainingArgs =
    if remainingArgs <= 0 then
        monoType

    else
        case monoType of
            Mono.MFunction _ _ params returnType ->
                let
                    consumed =
                        min (List.length params) remainingArgs
                in
                uncurryReturnType returnType (remainingArgs - consumed)

            _ ->
                monoType


{-| Returns the type recorded on an expression, `MUnit` for the unit value.
-}
monoExprType : Mono.MonoExpr -> Mono.MonoType
monoExprType expr =
    case expr of
        Mono.MonoLiteral _ ty ->
            ty

        Mono.MonoVarLocal _ ty ->
            ty

        Mono.MonoVarGlobal _ _ ty ->
            ty

        Mono.MonoVarKernel _ _ _ _ ty ->
            ty

        Mono.MonoList _ _ ty ->
            ty

        Mono.MonoClosure _ _ ty ->
            ty

        Mono.MonoCall _ _ _ ty _ ->
            ty

        Mono.MonoTailCall _ _ ty ->
            ty

        Mono.MonoIf _ _ ty ->
            ty

        Mono.MonoLet _ _ ty ->
            ty

        Mono.MonoDestruct _ _ ty ->
            ty

        Mono.MonoCase _ _ _ _ ty ->
            ty

        Mono.MonoRecordCreate _ ty ->
            ty

        Mono.MonoRecordAccess _ _ ty ->
            ty

        Mono.MonoRecordUpdate _ _ ty ->
            ty

        Mono.MonoTupleCreate _ _ ty ->
            ty

        Mono.MonoUnit ->
            Mono.MUnit

        Mono.MonoAccessorValue _ _ t ->
            t


{-| Emits the value of `valueExpr`, binds it to `placeholderVar`, and emits the
remaining operations after it.
-}
emitPushValueNested : Mono.MonoExpr -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitPushValueNested valueExpr placeholderVar restOps state =
    let
        exprResult =
            state.compileExpr valueExpr state.ctx

        updatedState =
            { state
                | ctx = exprResult.ctx
                , decodedVars = exprResult.resultVar :: state.decodedVars
                , varMapping = Dict.insert placeholderVar exprResult.resultVar state.varMapping
                , varTypes = Dict.insert exprResult.resultVar exprResult.resultType state.varTypes
            }

        ( restBodyOps, resultVar, finalCtx ) =
            emitDecoderOpsNested restOps updatedState
    in
    ( exprResult.ops ++ restBodyOps, resultVar, finalCtx )


{-| Emits `Just` the last value produced, or `Just ()` when there is none.
-}
emitJustResult : DecoderEmitState -> ( List MlirOp, String, Context )
emitJustResult state =
    case state.decodedVars of
        resultVar :: _ ->
            emitJustResultWithVar resultVar state

        [] ->
            let
                ( unitVar, ctx1 ) =
                    Context.freshVar state.ctx

                ( ctx2, unitOp ) =
                    Ops.mlirOp ctx1 "eco.unit"
                        |> Ops.opBuilder.withResults [ ( unitVar, Types.ecoValue ) ]
                        |> Ops.opBuilder.build

                ( justVar, ctx3 ) =
                    Context.freshVar ctx2

                ( ctx4, justOp ) =
                    Ops.ecoConstructCustom ctx3 justVar 0 1 [ 0 ] [ ( unitVar, Types.ecoValue ) ] (Just "Just")
            in
            ( [ unitOp, justOp ], justVar, ctx4 )


{-| Emits `Just` the value `varName`. A value whose recorded type is `i64`,
`f64` or `i32` is stored unboxed, with that type's slot kind; anything else,
including a value of unknown type, is stored as an `!eco.value`.
-}
emitJustResultWithVar : String -> DecoderEmitState -> ( List MlirOp, String, Context )
emitJustResultWithVar varName state =
    let
        varType =
            Dict.get varName state.varTypes
                |> Maybe.withDefault Types.ecoValue
    in
    if Types.isUnboxable varType then
        let
            ( justVar, ctx1 ) =
                Context.freshVar state.ctx

            ( ctx2, justOp ) =
                Ops.ecoConstructCustom ctx1 justVar 0 1 [ Types.mlirTypeToKind varType ] [ ( varName, varType ) ] (Just "Just")
        in
        ( [ justOp ], justVar, ctx2 )

    else
        let
            ( justVar, ctx1 ) =
                Context.freshVar state.ctx

            ( ctx2, justOp ) =
                Ops.ecoConstructCustom ctx1 justVar 0 1 [ 0 ] [ ( varName, Types.ecoValue ) ] (Just "Just")
        in
        ( [ justOp ], justVar, ctx2 )


{-| Emits the embedded `Nothing` constant.
-}
emitNothingResult : DecoderEmitState -> ( List MlirOp, String, Context )
emitNothingResult state =
    let
        ( nothingVar, ctx1 ) =
            Context.freshVar state.ctx

        ( ctx2, nothingOp ) =
            Ops.ecoConstantNothing ctx1 nothingVar
    in
    ( [ nothingOp ], nothingVar, ctx2 )


{-| A fixed-width read: the `bf.read.*` op that does it, its byte order, its
width in bytes, and the type of the value it produces.
-}
type alias FixedRead =
    { opName : String
    , endian : Maybe Endianness
    , width : Int
    , valueType : MlirType
    }


{-| Returns the fixed-width read that a decoding loop's item operations consist
of, or `Nothing` when they are anything other than a single fixed-width read.
Integer reads produce an `i64` and float reads an `f64`.
-}
fixedReadOf : List DecoderOp -> Maybe FixedRead
fixedReadOf itemOps =
    case itemOps of
        [ ReadU8 _ _ ] ->
            Just { opName = "bf.read.u8", endian = Nothing, width = 1, valueType = I64 }

        [ ReadI8 _ _ ] ->
            Just { opName = "bf.read.i8", endian = Nothing, width = 1, valueType = I64 }

        [ ReadU16 _ endian _ ] ->
            Just { opName = "bf.read.u16", endian = Just endian, width = 2, valueType = I64 }

        [ ReadI16 _ endian _ ] ->
            Just { opName = "bf.read.i16", endian = Just endian, width = 2, valueType = I64 }

        [ ReadU32 _ endian _ ] ->
            Just { opName = "bf.read.u32", endian = Just endian, width = 4, valueType = I64 }

        [ ReadI32 _ endian _ ] ->
            Just { opName = "bf.read.i32", endian = Just endian, width = 4, valueType = I64 }

        [ ReadF32 _ endian _ ] ->
            Just { opName = "bf.read.f32", endian = Just endian, width = 4, valueType = F64 }

        [ ReadF64 _ endian _ ] ->
            Just { opName = "bf.read.f64", endian = Just endian, width = 8, valueType = F64 }

        _ ->
            Nothing


{-| Emits `read` at `cursor` with no bounds check. Returns the ops, the value
and the new cursor. The caller must already have checked that `read.width` bytes
are there.
-}
emitFixedRead : FixedRead -> String -> Context -> ( List MlirOp, ( String, String ), Context )
emitFixedRead read cursor ctx0 =
    let
        ( valueVar, ctx1 ) =
            Context.freshVar ctx0

        ( newCursor, ctx2 ) =
            Context.freshVar ctx1

        baseAttrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr bfCursorType ])

        attrs =
            case read.endian of
                Just endian ->
                    Dict.insert "endianness" (endianToAttr endian) baseAttrs

                Nothing ->
                    baseAttrs

        ( ctx3, readOp ) =
            Ops.mlirOp ctx2 read.opName
                |> Ops.opBuilder.withOperands [ cursor ]
                |> Ops.opBuilder.withAttrs attrs
                |> Ops.opBuilder.withResults [ ( valueVar, read.valueType ), ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.build
    in
    ( [ readOp ], ( valueVar, newCursor ), ctx3 )


{-| Emits an `i64` constant. Returns the op and its SSA name.
-}
emitI64Const : Int -> Context -> ( MlirOp, String, Context )
emitI64Const value ctx0 =
    let
        ( var, ctx1 ) =
            Context.freshVar ctx0

        ( ctx2, op ) =
            Ops.arithConstantInt ctx1 var value
    in
    ( op, var, ctx2 )


{-| Emits the binary `arith` op `opName` on `lhs` and `rhs`, both of type
`operandType`, with a result of type `resultType`. Returns the op and its
result.
-}
emitArith : String -> MlirType -> MlirType -> String -> String -> Context -> ( MlirOp, String, Context )
emitArith opName operandType resultType lhs rhs ctx0 =
    let
        ( var, ctx1 ) =
            Context.freshVar ctx0

        ( ctx2, op ) =
            Ops.mlirOp ctx1 opName
                |> Ops.opBuilder.withOperands [ lhs, rhs ]
                |> Ops.opBuilder.withResults [ ( var, resultType ) ]
                |> Ops.opBuilder.withAttrs
                    (Dict.singleton "_operand_types"
                        (ArrayAttr Nothing [ TypeAttr operandType, TypeAttr operandType ])
                    )
                |> Ops.opBuilder.build
    in
    ( op, var, ctx2 )


{-| Emits the cons cell `head :: tail`, with the head stored unboxed under its
type's slot kind. Returns the op and the new list.
-}
emitConsUnboxed : ( String, MlirType ) -> String -> Context -> ( MlirOp, String, Context )
emitConsUnboxed head tail ctx0 =
    let
        ( var, ctx1 ) =
            Context.freshVar ctx0

        ( ctx2, op ) =
            Ops.ecoConstructList ctx1 var head ( tail, Types.ecoValue ) True
    in
    ( op, var, ctx2 )


{-| Emits a call to the `List.reverse` kernel on `list`. Returns the ops and
the reversed list.
-}
emitReverseList : String -> Context -> ( List MlirOp, String, Context )
emitReverseList list ctx0 =
    let
        ( reversed, ctx1 ) =
            Context.freshVar ctx0

        ( ctx2, callOp ) =
            Ops.ecoCallNamed ctx1 reversed "Elm_Kernel_List_reverse" [ ( list, Types.ecoValue ) ] Types.ecoValue
    in
    ( [ callOp ], reversed, ctx2 )


{-| Emits the empty list constant. Returns the op and its SSA name.
-}
emitEmptyList : Context -> ( MlirOp, String, Context )
emitEmptyList ctx0 =
    let
        ( var, ctx1 ) =
            Context.freshVar ctx0

        ( ctx2, op ) =
            Ops.ecoConstantNil ctx1 var
    in
    ( op, var, ctx2 )


{-| Finishes a decoding loop whose accumulated list (items consed, so in reverse
read order) is `acc` and whose cursor is `cursor`: puts the list in `order`,
binds it to `resultPlaceholder` and emits the remaining operations. Returns the
ops and the result of the remaining operations.
-}
emitLoopResultThenRest : IR.ListOrder -> String -> String -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitLoopResultThenRest order acc cursor resultPlaceholder restOps state =
    let
        ( reverseOps, listVar, ctx1 ) =
            case order of
                IR.ReverseReadOrder ->
                    ( [], acc, state.ctx )

                IR.InReadOrder ->
                    emitReverseList acc state.ctx

        updatedState =
            { state
                | ctx = ctx1
                , cursor = cursor
                , decodedVars = listVar :: state.decodedVars
                , varMapping = Dict.insert resultPlaceholder listVar state.varMapping
                , varTypes = Dict.insert listVar Types.ecoValue state.varTypes
            }

        ( restOpsEmitted, resultVar, ctx2 ) =
            emitDecoderOpsNested restOps updatedState
    in
    ( reverseOps ++ restOpsEmitted, resultVar, ctx2 )


{-| Emits `scf.if %ok` whose then-branch is `thenBody` (its ops and result) and
whose else-branch is `Nothing`. Returns the op and its result.
-}
emitIfElseNothing : String -> ( List MlirOp, String, Context ) -> ( MlirOp, String, Context )
emitIfElseNothing okVar ( thenOps, thenResult, ctx0 ) =
    let
        ( ctx1, thenYield ) =
            Ops.scfYieldMany ctx0 [ ( thenResult, Types.ecoValue ) ]

        ( nothingVar, ctx2 ) =
            Context.freshVar ctx1

        ( ctx3, nothingOp ) =
            Ops.ecoConstantNothing ctx2 nothingVar

        ( ctx4, elseYield ) =
            Ops.scfYieldMany ctx3 [ ( nothingVar, Types.ecoValue ) ]

        ( ifVar, ctx5 ) =
            Context.freshVar ctx4

        ( ctx6, ifOp ) =
            Ops.mlirOp ctx5 "scf.if"
                |> Ops.opBuilder.withOperands [ okVar ]
                |> Ops.opBuilder.withResults [ ( ifVar, Types.ecoValue ) ]
                |> Ops.opBuilder.withRegions
                    [ Ops.mkRegion [] thenOps thenYield
                    , Ops.mkRegion [] [ nothingOp ] elseYield
                    ]
                |> Ops.opBuilder.build
    in
    ( ifOp, ifVar, ctx6 )


{-| Emits a loop that decodes `count` items, each one fixed-width read, binds
the list of them in `order` to `resultPlaceholder`, and emits the remaining
operations after it.

A negative count is taken as zero. The bytes of all the items are checked once,
before the loop: a `bf.require` of the count times the item width, together with
a check that the product fits in 32 bits. When the check fails the decoder gives
`Nothing`; otherwise the reads inside the loop need no check of their own. The
loop is an `scf.while` over a counter, the cursor and the list so far, which
reads an item and conses it until the counter reaches zero.

It crashes the compiler when the item operations are not one fixed-width read.

-}
emitLoopDecodeListNested : IR.LoopCount -> List DecoderOp -> IR.ListOrder -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitLoopDecodeListNested count itemOps order resultPlaceholder restOps state =
    case fixedReadOf itemOps of
        Nothing ->
            Crash.crash "BytesFusion.Emit: LoopDecodeList item is not one fixed-width read (Reify must not produce this)"

        Just read ->
            let
                ( countOps, countVar, ctx1 ) =
                    emitLoopCount count state

                ( zeroOp, zeroVar, ctx2 ) =
                    emitI64Const 0 ctx1

                ( clampOp, clampedVar, ctx3 ) =
                    emitArith "arith.maxsi" I64 I64 countVar zeroVar ctx2

                ( limitOp, limitVar, ctx4 ) =
                    emitI64Const (2147483647 // read.width) ctx3

                ( fitsVar, ctx5 ) =
                    Context.freshVar ctx4

                ( ctx6, fitsOp ) =
                    Ops.arithCmpI ctx5 "sle" fitsVar ( clampedVar, I64 ) ( limitVar, I64 )

                ( widthOp, widthVar, ctx7 ) =
                    emitI64Const read.width ctx6

                ( totalOp, totalVar, ctx8 ) =
                    emitArith "arith.muli" I64 I64 clampedVar widthVar ctx7

                ( total32Var, ctx9 ) =
                    Context.freshVar ctx8

                ( ctx10, truncOp ) =
                    Ops.mlirOp ctx9 "arith.trunci"
                        |> Ops.opBuilder.withOperands [ totalVar ]
                        |> Ops.opBuilder.withResults [ ( total32Var, I32 ) ]
                        |> Ops.opBuilder.withAttrs
                            (Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr I64 ]))
                        |> Ops.opBuilder.build

                ( requireVar, ctx11 ) =
                    Context.freshVar ctx10

                ( ctx12, requireOp ) =
                    Ops.mlirOp ctx11 "bf.require"
                        |> Ops.opBuilder.withOperands [ state.cursor, total32Var ]
                        |> Ops.opBuilder.withResults [ ( requireVar, I1 ) ]
                        |> Ops.opBuilder.withAttrs
                            (Dict.singleton "_operand_types"
                                (ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr I32 ])
                            )
                        |> Ops.opBuilder.build

                ( okOp, okVar, ctx13 ) =
                    emitArith "arith.andi" I1 I1 fitsVar requireVar ctx12

                -- The loop goes inside the then-branch of the check.
                ( nilOp, nilVar, ctx14 ) =
                    emitEmptyList ctx13

                ( beforeCounter, ctx15 ) =
                    Context.freshVar ctx14

                ( beforeCursor, ctx16 ) =
                    Context.freshVar ctx15

                ( beforeAcc, ctx17 ) =
                    Context.freshVar ctx16

                ( moreVar, ctx18 ) =
                    Context.freshVar ctx17

                ( ctx19, moreOp ) =
                    Ops.arithCmpI ctx18 "sgt" moreVar ( beforeCounter, I64 ) ( zeroVar, I64 )

                loopTypes =
                    [ I64, bfCursorType, Types.ecoValue ]

                ( ctx20, conditionOp ) =
                    Ops.scfCondition ctx19 moreVar (List.map2 Tuple.pair [ beforeCounter, beforeCursor, beforeAcc ] loopTypes)

                beforeRegion =
                    Ops.mkRegion (List.map2 Tuple.pair [ beforeCounter, beforeCursor, beforeAcc ] loopTypes)
                        [ moreOp ]
                        conditionOp

                ( afterCounter, ctx21 ) =
                    Context.freshVar ctx20

                ( afterCursor, ctx22 ) =
                    Context.freshVar ctx21

                ( afterAcc, ctx23 ) =
                    Context.freshVar ctx22

                ( readOps, ( valueVar, nextCursor ), ctx24 ) =
                    emitFixedRead read afterCursor ctx23

                ( oneOp, oneVar, ctx25 ) =
                    emitI64Const 1 ctx24

                ( decOp, nextCounter, ctx26 ) =
                    emitArith "arith.subi" I64 I64 afterCounter oneVar ctx25

                ( consOp, nextAcc, ctx27 ) =
                    emitConsUnboxed ( valueVar, read.valueType ) afterAcc ctx26

                ( ctx28, yieldOp ) =
                    Ops.scfYieldMany ctx27 (List.map2 Tuple.pair [ nextCounter, nextCursor, nextAcc ] loopTypes)

                afterRegion =
                    Ops.mkRegion (List.map2 Tuple.pair [ afterCounter, afterCursor, afterAcc ] loopTypes)
                        (readOps ++ [ oneOp, decOp, consOp ])
                        yieldOp

                ( whileCounter, ctx29 ) =
                    Context.freshVar ctx28

                ( whileCursor, ctx30 ) =
                    Context.freshVar ctx29

                ( whileAcc, ctx31 ) =
                    Context.freshVar ctx30

                ( ctx32, whileOp ) =
                    Ops.scfWhile ctx31
                        [ ( whileCounter, clampedVar, I64 )
                        , ( whileCursor, state.cursor, bfCursorType )
                        , ( whileAcc, nilVar, Types.ecoValue )
                        ]
                        beforeRegion
                        afterRegion

                ( restOps_, restResult, ctx33 ) =
                    emitLoopResultThenRest order whileAcc whileCursor resultPlaceholder restOps { state | ctx = ctx32 }

                ( ifOp, ifVar, ctx34 ) =
                    emitIfElseNothing okVar ( [ nilOp, whileOp ] ++ restOps_, restResult, ctx33 )
            in
            ( countOps
                ++ [ zeroOp, clampOp, limitOp, fitsOp, widthOp, totalOp, truncOp, requireOp, okOp, ifOp ]
            , ifVar
            , ctx34
            )


{-| Emits the count of a `LoopDecodeList` as an `i64`. A count expression
whose value is not already an `i64` is unboxed.

It crashes the compiler when the count is a placeholder with no value.

-}
emitLoopCount : IR.LoopCount -> DecoderEmitState -> ( List MlirOp, String, Context )
emitLoopCount count state =
    case count of
        IR.CountLiteral n ->
            let
                ( op, var, ctx1 ) =
                    emitI64Const n state.ctx
            in
            ( [ op ], var, ctx1 )

        IR.CountPlaceholder placeholder ->
            case Dict.get placeholder state.varMapping of
                Just var ->
                    ( [], var, state.ctx )

                Nothing ->
                    Crash.crash ("BytesFusion.Emit: loop count placeholder " ++ placeholder ++ " has no value")

        IR.CountExpression expr ->
            let
                result =
                    state.compileExpr expr state.ctx
            in
            if result.resultType == I64 then
                ( result.ops, result.resultVar, result.ctx )

            else
                let
                    ( unboxedVar, ctx1 ) =
                        Context.freshVar result.ctx

                    ( ctx2, unboxOp ) =
                        Ops.mlirOp ctx1 "eco.unbox"
                            |> Ops.opBuilder.withOperands [ result.resultVar ]
                            |> Ops.opBuilder.withResults [ ( unboxedVar, I64 ) ]
                            |> Ops.opBuilder.withAttrs
                                (Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr result.resultType ]))
                            |> Ops.opBuilder.build
                in
                ( result.ops ++ [ unboxOp ], unboxedVar, ctx2 )


{-| Emits a loop that decodes items, each one fixed-width read, until one
equals `sentinel`, binds the list of the items before it in `order` to
`resultPlaceholder`, and emits the remaining operations after it.

The loop is an `scf.while` over the cursor, the list so far, and whether the
sentinel has been found. It continues while the sentinel has not been found and
a `bf.require` shows the next item's bytes are there, so every read is checked.
An item equal to the sentinel is consumed and sets the flag, and any other item
is consed. When the loop stops without the sentinel, because the input ran out,
the decoder gives `Nothing`.

The comparison with the sentinel is an integer comparison on the value read.
It crashes the compiler when the item operations are not one fixed-width read.

-}
emitLoopSentinelDecodeListNested : Int -> List DecoderOp -> IR.ListOrder -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitLoopSentinelDecodeListNested sentinel itemOps order resultPlaceholder restOps state =
    case fixedReadOf itemOps of
        Nothing ->
            Crash.crash "BytesFusion.Emit: LoopSentinelDecodeList item is not one fixed-width read (Reify must not produce this)"

        Just read ->
            let
                ( nilOp, nilVar, ctx1 ) =
                    emitEmptyList state.ctx

                ( sentinelOp, sentinelVar, ctx2 ) =
                    emitI64Const sentinel ctx1

                ( falseVar, ctx3 ) =
                    Context.freshVar ctx2

                ( ctx4, falseOp ) =
                    Ops.arithConstantBool ctx3 falseVar False

                ( trueVar, ctx5 ) =
                    Context.freshVar ctx4

                ( ctx6, trueOp ) =
                    Ops.arithConstantBool ctx5 trueVar True

                ( widthVar, ctx7 ) =
                    Context.freshVar ctx6

                ( ctx8, widthOp ) =
                    Ops.arithConstantInt32 ctx7 widthVar read.width

                loopTypes =
                    [ bfCursorType, Types.ecoValue, I1 ]

                ( beforeCursor, ctx9 ) =
                    Context.freshVar ctx8

                ( beforeAcc, ctx10 ) =
                    Context.freshVar ctx9

                ( beforeFound, ctx11 ) =
                    Context.freshVar ctx10

                ( requireVar, ctx12 ) =
                    Context.freshVar ctx11

                ( ctx13, requireOp ) =
                    Ops.mlirOp ctx12 "bf.require"
                        |> Ops.opBuilder.withOperands [ beforeCursor, widthVar ]
                        |> Ops.opBuilder.withResults [ ( requireVar, I1 ) ]
                        |> Ops.opBuilder.withAttrs
                            (Dict.singleton "_operand_types"
                                (ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr I32 ])
                            )
                        |> Ops.opBuilder.build

                ( notFoundOp, notFoundVar, ctx14 ) =
                    emitArith "arith.xori" I1 I1 beforeFound trueVar ctx13

                ( continueOp, continueVar, ctx15 ) =
                    emitArith "arith.andi" I1 I1 notFoundVar requireVar ctx14

                ( ctx16, conditionOp ) =
                    Ops.scfCondition ctx15 continueVar (List.map2 Tuple.pair [ beforeCursor, beforeAcc, beforeFound ] loopTypes)

                beforeRegion =
                    Ops.mkRegion (List.map2 Tuple.pair [ beforeCursor, beforeAcc, beforeFound ] loopTypes)
                        [ requireOp, notFoundOp, continueOp ]
                        conditionOp

                ( afterCursor, ctx17 ) =
                    Context.freshVar ctx16

                ( afterAcc, ctx18 ) =
                    Context.freshVar ctx17

                ( afterFound, ctx19 ) =
                    Context.freshVar ctx18

                ( readOps, ( valueVar, nextCursor ), ctx20 ) =
                    emitFixedRead read afterCursor ctx19

                ( isSentinelVar, ctx21 ) =
                    Context.freshVar ctx20

                ( ctx22, isSentinelOp ) =
                    Ops.arithCmpI ctx21 "eq" isSentinelVar ( valueVar, I64 ) ( sentinelVar, I64 )

                ( ctx23, keepYield ) =
                    Ops.scfYieldMany ctx22 [ ( afterAcc, Types.ecoValue ) ]

                ( consOp, consVar, ctx24 ) =
                    emitConsUnboxed ( valueVar, read.valueType ) afterAcc ctx23

                ( ctx25, consYield ) =
                    Ops.scfYieldMany ctx24 [ ( consVar, Types.ecoValue ) ]

                ( nextAcc, ctx26 ) =
                    Context.freshVar ctx25

                ( ctx27, accIfOp ) =
                    Ops.mlirOp ctx26 "scf.if"
                        |> Ops.opBuilder.withOperands [ isSentinelVar ]
                        |> Ops.opBuilder.withResults [ ( nextAcc, Types.ecoValue ) ]
                        |> Ops.opBuilder.withRegions
                            [ Ops.mkRegion [] [] keepYield
                            , Ops.mkRegion [] [ consOp ] consYield
                            ]
                        |> Ops.opBuilder.build

                ( ctx28, yieldOp ) =
                    Ops.scfYieldMany ctx27 (List.map2 Tuple.pair [ nextCursor, nextAcc, isSentinelVar ] loopTypes)

                afterRegion =
                    Ops.mkRegion (List.map2 Tuple.pair [ afterCursor, afterAcc, afterFound ] loopTypes)
                        (readOps ++ [ isSentinelOp, accIfOp ])
                        yieldOp

                ( whileCursor, ctx29 ) =
                    Context.freshVar ctx28

                ( whileAcc, ctx30 ) =
                    Context.freshVar ctx29

                ( whileFound, ctx31 ) =
                    Context.freshVar ctx30

                ( ctx32, whileOp ) =
                    Ops.scfWhile ctx31
                        [ ( whileCursor, state.cursor, bfCursorType )
                        , ( whileAcc, nilVar, Types.ecoValue )
                        , ( whileFound, falseVar, I1 )
                        ]
                        beforeRegion
                        afterRegion

                ( restOps_, restResult, ctx33 ) =
                    emitLoopResultThenRest order whileAcc whileCursor resultPlaceholder restOps { state | ctx = ctx32 }

                ( ifOp, ifVar, ctx34 ) =
                    emitIfElseNothing whileFound ( restOps_, restResult, ctx33 )
            in
            ( [ nilOp, sentinelOp, falseOp, trueOp, widthOp, whileOp, ifOp ], ifVar, ctx34 )
