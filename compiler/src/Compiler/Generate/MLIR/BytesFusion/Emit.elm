module Compiler.Generate.MLIR.BytesFusion.Emit exposing (ExprCompiler, emitFusedDecoder, emitFusedEncoder, CompileExprResult)

{-| Emit MLIR operations for fused byte encoding and decoding.

Takes Loop IR operations and emits bf dialect MLIR ops.

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


{-| Result of compiling an expression.
-}
type alias CompileExprResult =
    { ops : List MlirOp
    , resultVar : String
    , resultType : MlirType
    , ctx : Context
    }


{-| Type alias for expression compiler callback.
This allows Emit.elm to compile MonoExpr values without importing Expr.elm.
The callback takes a MonoExpr and Context, returns a CompileExprResult.
-}
type alias ExprCompiler =
    Mono.MonoExpr -> Context -> CompileExprResult


{-| State threaded through encoder emission.
Contains the current cursor SSA variable and accumulated ops.
-}
type alias EmitState =
    { ctx : Context
    , cursor : String -- Current cursor SSA variable
    , bufferVar : String -- The allocated ByteBuffer eco.value
    , ops : List MlirOp
    , compileExpr : ExprCompiler -- Callback to compile MonoExpr
    }


{-| The bf.cursor MLIR type.
-}
bfCursorType : MlirType
bfCursorType =
    NamedStruct "bf.cursor"


{-| Emit a complete fused encoder from Loop IR operations.
Takes an expression compiler callback to compile embedded MonoExpr values.
Returns the MLIR ops and the result variable name.
-}
emitFusedEncoder : ExprCompiler -> Context -> List Op -> ( List MlirOp, String, Context )
emitFusedEncoder compileExpr ctxIn ops =
    emitFusedEncoderTagged compileExpr { ctxIn | currentFuncName = ctxIn.currentFuncName ++ "/bf-enc" } ops


emitFusedEncoderTagged : ExprCompiler -> Context -> List Op -> ( List MlirOp, String, Context )
emitFusedEncoderTagged compileExpr ctx ops =
    let
        initialState =
            { ctx = ctx
            , cursor = ""
            , bufferVar = ""
            , ops = []
            , compileExpr = compileExpr
            }

        finalState =
            List.foldl emitOp initialState ops
    in
    ( List.reverse finalState.ops, finalState.bufferVar, finalState.ctx )


{-| Emit a single Loop IR operation.
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
            -- Buffer is already stored in state.bufferVar
            state


{-| Emit cursor initialization.
Allocates the buffer and creates initial cursor.
-}
emitInitCursor : WidthExpr -> EmitState -> EmitState
emitInitCursor widthExpr state =
    let
        -- Emit width computation
        ( widthOps, widthVar, ctx1 ) =
            emitWidthExpr state.compileExpr widthExpr state.ctx

        -- Generate buffer variable name
        ( bufferVar, ctx2 ) =
            Context.freshVar ctx1

        -- Add _operand_types for width (I32)
        allocAttrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr I32 ])

        -- Emit bf.alloc - returns eco.value (heap pointer to ByteBuffer)
        ( ctx3, allocOp ) =
            Ops.mlirOp ctx2 "bf.alloc"
                |> Ops.opBuilder.withOperands [ widthVar ]
                |> Ops.opBuilder.withResults [ ( bufferVar, Types.ecoValue ) ]
                |> Ops.opBuilder.withAttrs allocAttrs
                |> Ops.opBuilder.build

        -- Generate cursor variable name
        ( cursorVar, ctx4 ) =
            Context.freshVar ctx3

        -- Add _operand_types for eco.value buffer
        initAttrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr Types.ecoValue ])

        -- Emit bf.cursor.init - takes eco.value buffer
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


{-| Emit width expression to MLIR.
Returns ops, result variable name, and updated context.
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
            -- Compile the string expression, then call bf.utf8_width
            let
                strResult =
                    compileExpr strExpr ctx

                ( resultVar, ctx2 ) =
                    Context.freshVar strResult.ctx

                -- Add _operand_types using actual expression result type
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
            -- Compile the bytes expression, then call bf.bytes_width
            let
                bytesResult =
                    compileExpr bytesExpr ctx

                ( resultVar, ctx2 ) =
                    Context.freshVar bytesResult.ctx

                -- Add _operand_types using actual expression result type
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
            -- Escape-hatch width: runtime call to elm_encoder_size via
            -- bf.encoder.width on an opaque encoder subtree.
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
            -- Compile countExpr (typically a List.length call, which
            -- monomorphises to i64), truncate to i32, multiply by the
            -- compile-time-known per-iteration body width.
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


{-| Convert endianness to MLIR enum attribute.
The BF dialect uses I32EnumAttr for endianness: LE=0, BE=1.
In MLIR generic format, enum attributes are written as typed i32 integers.
-}
endianToAttr : Endianness -> MlirAttr
endianToAttr endian =
    case endian of
        LE ->
            IntAttr (Just I32) 0

        BE ->
            IntAttr (Just I32) 1


{-| Coerce a value SSA to the primitive type a BF write op expects,
inserting an `eco.unbox` when the source is `!eco.value`. The integer
write ops (`bf.write.u8/u16/u32`) take `I64`; the float write ops
(`bf.write.f32/f64`) take `F64`. Bytes and UTF-8 writes accept any
type and skip this coercion entirely.

The bytes-fusion ELoop body sees its per-iteration head bound to the
list-head SSA at `!eco.value` (loop-carried values cross the
`scf.while` boundary as a single uniform type). When the body
references the head directly as the value of `bf.write.u8` etc., this
unbox satisfies the op's operand-type constraint.

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


{-| Emit bf.write.u8 operation.
-}
emitWriteU8 : Mono.MonoExpr -> EmitState -> EmitState
emitWriteU8 valueExpr state =
    let
        exprResult =
            state.compileExpr valueExpr state.ctx

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
        , ops = writeOp :: List.reverse unboxOps ++ List.reverse exprResult.ops ++ state.ops
    }


{-| Emit bf.write.u16 operation.
-}
emitWriteU16 : Endianness -> Mono.MonoExpr -> EmitState -> EmitState
emitWriteU16 endian valueExpr state =
    let
        exprResult =
            state.compileExpr valueExpr state.ctx

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
        , ops = writeOp :: List.reverse unboxOps ++ List.reverse exprResult.ops ++ state.ops
    }


{-| Emit bf.write.u32 operation.
-}
emitWriteU32 : Endianness -> Mono.MonoExpr -> EmitState -> EmitState
emitWriteU32 endian valueExpr state =
    let
        exprResult =
            state.compileExpr valueExpr state.ctx

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
        , ops = writeOp :: List.reverse unboxOps ++ List.reverse exprResult.ops ++ state.ops
    }


{-| Emit bf.write.f32 operation.
-}
emitWriteF32 : Endianness -> Mono.MonoExpr -> EmitState -> EmitState
emitWriteF32 endian valueExpr state =
    let
        exprResult =
            state.compileExpr valueExpr state.ctx

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
        , ops = writeOp :: List.reverse unboxOps ++ List.reverse exprResult.ops ++ state.ops
    }


{-| Emit bf.write.f64 operation.
-}
emitWriteF64 : Endianness -> Mono.MonoExpr -> EmitState -> EmitState
emitWriteF64 endian valueExpr state =
    let
        exprResult =
            state.compileExpr valueExpr state.ctx

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
        , ops = writeOp :: List.reverse unboxOps ++ List.reverse exprResult.ops ++ state.ops
    }


{-| Emit bf.write.bytes operation.
-}
emitWriteBytes : Mono.MonoExpr -> EmitState -> EmitState
emitWriteBytes bytesExpr state =
    let
        exprResult =
            state.compileExpr bytesExpr state.ctx

        ( newCursor, ctx2 ) =
            Context.freshVar exprResult.ctx

        -- Add _operand_types for cursor and bytes (using actual expression result type)
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
        , ops = writeOp :: (List.reverse exprResult.ops ++ state.ops)
    }


{-| Emit bf.write.encoder operation — the escape hatch for encoder
subtrees the reifier didn't recognise. Delegates to the runtime
walker via elm\_encoder\_write\_into; cursor advances by bytes-written.
-}
emitWriteOpaque : Mono.MonoExpr -> EmitState -> EmitState
emitWriteOpaque encoderExpr state =
    let
        exprResult =
            state.compileExpr encoderExpr state.ctx

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
        , ops = writeOp :: (List.reverse exprResult.ops ++ state.ops)
    }


{-| Emit bf.write.utf8 operation.
-}
emitWriteUtf8 : Mono.MonoExpr -> EmitState -> EmitState
emitWriteUtf8 strExpr state =
    let
        exprResult =
            state.compileExpr strExpr state.ctx

        ( newCursor, ctx2 ) =
            Context.freshVar exprResult.ctx

        -- Add _operand_types for cursor and string (using actual expression result type)
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
        , ops = writeOp :: (List.reverse exprResult.ops ++ state.ops)
    }


{-| Emit a length-prefixed encoder loop as an scf.while over the source
list with loop-carried cursor + remaining list.

Pseudo-MLIR:

    %list_init = <compileExpr iterExpr>
    %loop:2 = scf.while (%cur = state.cursor, %lst = %list_init)
              : (!bf.cursor, !eco.value) -> (!bf.cursor, !eco.value) {
      // before region: condition is "list is Cons"
      %tag = eco.get_tag %lst
      %is_nil = arith.cmpi eq, %tag, c0_i32
      %is_cons = arith.xori %is_nil, true
      scf.condition (%is_cons) %cur, %lst : !bf.cursor, !eco.value
    } do {
    ^bb0(%cur, %lst):
      // after region
      %head = eco.project.list_head %lst
      %tail = eco.project.list_tail %lst
      // body ops emit bf.write.* threaded through %cur, producing %new_cur
      // with itemVar bound to %head
      scf.yield %new_cur, %tail : !bf.cursor, !eco.value
    }
    // %loop#0 is the final cursor; %loop#1 is the empty-list residue.

Mirrors the decoder loop's scf.while construction. Cursor threading
inside the body uses Context.addVarMapping to bind the user-visible
itemVar name to the per-iteration head SSA, so the body's MonoExpr
references resolve correctly through the standard compileExpr callback.

-}
emitWriteEachItem :
    { cursorName : String
    , itemVar : String
    , bodyOps : List Op
    , iterExpr : Mono.MonoExpr
    , itemByteWidth : Int
    }
    -> EmitState
    -> EmitState
emitWriteEachItem r state =
    let
        -- 1. Compile iterExpr to get the list SSA.
        iterResult =
            state.compileExpr r.iterExpr state.ctx

        ctx0 =
            iterResult.ctx

        -- 2. Generate fresh names for loop result vars and block args.
        ( whileCursorResult, ctx1 ) =
            Context.freshVar ctx0

        ( whileListResult, ctx2 ) =
            Context.freshVar ctx1

        ( beforeCursorArg, ctx3 ) =
            Context.freshVar ctx2

        ( beforeListArg, ctx4 ) =
            Context.freshVar ctx3

        -- 3. Build before region: tag check.
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

        -- Nil is an embedded empty constant; eco_get_tag returns CONSTANT_TAG
        -- for it (see D9), so the "is this list Nil?" check compares against
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

        -- arith.cmpi predicate=0 means eq
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

        -- 4. Build after region: project head, run body, project tail, yield.
        ( afterCursorArg, ctx16 ) =
            Context.freshVar ctx15

        ( afterListArg, ctx17 ) =
            Context.freshVar ctx16

        -- A WriteEachItem loop body only ever contains primitive number
        -- writes (buildLoopNode restricts it to EU8/EU16/EU32/EF32/EF64), so
        -- the per-iteration item is always an UNBOXED number: Int heads are
        -- i64, Float heads are f64. Projecting the head as `!eco.value` and
        -- then `eco.unbox`-ing it (resolve + load) is wrong for unboxed heads
        -- — the raw scalar word gets reinterpreted as an HPointer, and under
        -- the current representation an unboxed int like 7 has the ptr_ind bit
        -- set, so eco_resolve_hptr rejects it as an embedded constant. Project
        -- the head directly in its natural scalar type instead: the i64/f64
        -- `eco.project.list_head` lowering (eco_cons_head_i64/f64) reads the
        -- head correctly whether it is stored boxed or unboxed.
        headType =
            if List.all isFloatWrite r.bodyOps && not (List.isEmpty r.bodyOps) then
                F64

            else
                I64

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

        -- Bind itemVar -> headVar (in its natural scalar type) so body
        -- MonoExpr lookups resolve. Because the head is already the unboxed
        -- i64/f64, the write op's `ensureUnboxed` is a no-op (no stray
        -- eco.unbox / eco_resolve_hptr on a raw scalar word).
        ctxBody =
            Context.addVarMapping r.itemVar headVar headType ctx21

        -- Emit the body ops with afterCursorArg as the starting cursor,
        -- fresh `ops` accumulator (these belong inside the region, not the
        -- outer scope).
        bodyInitState =
            { state | ctx = ctxBody, cursor = afterCursorArg, ops = [] }

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

        -- 5. Build scf.while binding (whileCursorResult, whileListResult).
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
        , ops = whileOp :: (List.reverse iterResult.ops ++ state.ops)
    }


{-| True for the float primitive write ops. Used to decide whether a
`WriteEachItem` loop's per-iteration item head is an unboxed f64 (all body
writes are floats) or an unboxed i64 (the Int default). See `emitWriteEachItem`.
-}
isFloatWrite : Op -> Bool
isFloatWrite op =
    case op of
        WriteF32 _ _ _ ->
            True

        WriteF64 _ _ _ ->
            True

        _ ->
            False



-- ============================================================================
-- Decoder Emission (Phase 2)
-- ============================================================================


{-| State for decoder emission with nested scf.if fail-fast.
No okFlags accumulation - each read immediately branches on failure.
-}
type alias DecoderEmitState =
    { ctx : Context
    , cursor : String
    , bytesVar : String -- SSA variable holding the input bytes
    , decodedVars : List String -- Stack of decoded SSA variable names
    , compileExpr : ExprCompiler -- Callback to compile MonoExpr
    , varMapping : Dict.Dict String String -- placeholder var name → actual SSA var name
    , varTypes : Dict.Dict String MlirType -- SSA var name → type
    }


{-| Emit a complete fused decoder from Loop IR operations.
Takes the pre-compiled bytesVar (SSA value for the input bytes).
Returns (ops, resultVar, context) where resultVar contains Maybe a.

Uses nested scf.if for fail-fast bounds checking: each read is wrapped in
scf.if that returns Nothing immediately on bounds failure.

-}
emitFusedDecoder : ExprCompiler -> Context -> String -> List IR.DecoderOp -> ( List MlirOp, String, Context )
emitFusedDecoder compileExpr ctx bytesVar ops =
    let
        -- Initialize cursor from bytes
        ( cursorVar, ctx1 ) =
            Context.freshVar ctx

        -- Add _operand_types for bytes (eco.value)
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

        -- Filter out InitReadCursor since we handled it above
        remainingOps =
            List.filter (not << isInitReadCursor) ops

        -- Recursively emit nested scf.if structure
        ( resultOps, resultVar, finalCtx ) =
            emitDecoderOpsNested remainingOps initialState
    in
    ( initOp :: resultOps, resultVar, finalCtx )


{-| Check if op is InitReadCursor.
-}
isInitReadCursor : DecoderOp -> Bool
isInitReadCursor op =
    case op of
        InitReadCursor _ _ ->
            True

        _ ->
            False


{-| Recursively emit decoder ops with nested scf.if for fail-fast.

Each read operation emits:
%ok = bf.require(%cur, N)
%result = scf.if %ok -> !eco.value {
%value, %newCur = bf.read.\*(...)
// ... recursive call for remaining ops ...
scf.yield %innerResult
} else {
%nothing = call @elm\_maybe\_nothing()
scf.yield %nothing
}

Non-read ops (Apply, PushValue) are emitted directly without scf.if wrapping.

IMPORTANT: Each op carries a placeholder resultVarName that must be mapped to
the actual SSA variable created during emission. This mapping is stored in
state.varMapping and used by ReadBytesVar/ReadUtf8Var to look up length vars.

-}
emitDecoderOpsNested : List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitDecoderOpsNested ops state =
    case ops of
        [] ->
            -- Base case: return Just with the final decoded value
            emitJustResult state

        (InitReadCursor _ _) :: rest ->
            -- Skip - already handled in emitFusedDecoder
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
            -- Explicit return - look up actual SSA var from mapping
            case Dict.get resultPlaceholder state.varMapping of
                Just actualVar ->
                    emitJustResultWithVar actualVar state

                Nothing ->
                    -- Fallback: maybe it's already an SSA var or top of stack
                    case state.decodedVars of
                        topVar :: _ ->
                            emitJustResultWithVar topVar state

                        [] ->
                            emitJustResult state

        ReturnNothing :: _ ->
            -- Explicit failure - return Nothing
            emitNothingResult state


{-| Emit a fixed-size read with nested scf.if fail-fast pattern.
The placeholderVar is the name from the IR op that must be mapped to the actual SSA var.
-}
emitReadWithNestedScfIf : Int -> String -> Maybe Endianness -> MlirType -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitReadWithNestedScfIf byteCount readOpName maybeEndian resultType placeholderVar restOps state =
    let
        -- 1. Create constant for byte count
        ( bytesConstVar, ctx0 ) =
            Context.freshVar state.ctx

        ( ctx0b, bytesConstOp ) =
            Ops.mlirOp ctx0 "arith.constant"
                |> Ops.opBuilder.withResults [ ( bytesConstVar, I32 ) ]
                |> Ops.opBuilder.withAttrs (Dict.singleton "value" (IntAttr (Just I32) byteCount))
                |> Ops.opBuilder.build

        -- 2. bf.require check (takes cursor and bytes operands)
        ( okVar, ctx1 ) =
            Context.freshVar ctx0b

        -- Add _operand_types for cursor and byte count
        requireAttrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr bfCursorType, TypeAttr I32 ])

        ( ctx2, requireOp ) =
            Ops.mlirOp ctx1 "bf.require"
                |> Ops.opBuilder.withOperands [ state.cursor, bytesConstVar ]
                |> Ops.opBuilder.withResults [ ( okVar, I1 ) ]
                |> Ops.opBuilder.withAttrs requireAttrs
                |> Ops.opBuilder.build

        -- 2. Build the "then" block: do the read and continue recursively
        ( valueVar, ctx3 ) =
            Context.freshVar ctx2

        ( newCursor, ctx4 ) =
            Context.freshVar ctx3

        -- Always include _operand_types for the cursor input
        -- Use "endianness" to match BFOps.td definition
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

        -- Update state for recursive call - add mapping from placeholder to actual SSA var
        updatedState =
            { state
                | ctx = ctx5
                , cursor = newCursor
                , decodedVars = valueVar :: state.decodedVars
                , varMapping = Dict.insert placeholderVar valueVar state.varMapping
                , varTypes = Dict.insert valueVar resultType state.varTypes
            }

        -- Recursively emit remaining ops
        ( thenBodyOps, thenResultVar, ctx6 ) =
            emitDecoderOpsNested restOps updatedState

        -- Yield the result from the then block
        ( ctx7, thenYieldOp ) =
            Ops.mlirOp ctx6 "scf.yield"
                |> Ops.opBuilder.withOperands [ thenResultVar ]
                |> Ops.opBuilder.build

        thenRegion =
            Ops.mkRegion [] (readOp :: thenBodyOps) thenYieldOp

        -- 3. Build the "else" block: return Nothing
        ( nothingVar, ctx8 ) =
            Context.freshVar ctx7

        -- Use eco.constant Nothing (embedded constant, matches non-fused path)
        ( ctx9, nothingOp ) =
            Ops.ecoConstantNothing ctx8 nothingVar

        ( ctx10, elseYieldOp ) =
            Ops.mlirOp ctx9 "scf.yield"
                |> Ops.opBuilder.withOperands [ nothingVar ]
                |> Ops.opBuilder.build

        elseRegion =
            Ops.mkRegion [] [ nothingOp ] elseYieldOp

        -- 4. Build the scf.if
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


{-| Emit ReadBytes with nested scf.if pattern.
-}
emitReadBytesNested : Mono.MonoExpr -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitReadBytesNested lenExpr placeholderVar restOps state =
    let
        lenResult =
            state.compileExpr lenExpr state.ctx

        -- Truncate i64 length to i32 for bf ops
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


{-| Emit ReadUtf8 with nested scf.if pattern.
-}
emitReadUtf8Nested : Mono.MonoExpr -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitReadUtf8Nested lenExpr placeholderVar restOps state =
    let
        lenResult =
            state.compileExpr lenExpr state.ctx

        -- Truncate i64 length to i32 for bf ops
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


{-| Emit ReadBytesVar with nested scf.if pattern (length from previously decoded SSA var).
Looks up the lenPlaceholderVar in varMapping to get the actual SSA variable.
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

        -- Truncate to i32 for bf ops
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


{-| Emit ReadUtf8Var with nested scf.if pattern (length from previously decoded SSA var).
Looks up the lenPlaceholderVar in varMapping to get the actual SSA variable.
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

        -- Truncate to i32 for bf ops
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


{-| Emit Apply with nested continuation.
Apply operations don't do bounds checks, so no scf.if needed.
Looks up arg placeholder vars in varMapping to get actual SSA variables.
-}
emitApplyNested : Mono.MonoExpr -> List String -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitApplyNested fnExpr argPlaceholders resultPlaceholder restOps state =
    let
        -- Compile function expression
        fnResult =
            state.compileExpr fnExpr state.ctx

        -- Look up actual SSA variables and their types for args
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

        -- Determine the result type for a saturated call by examining the function's MonoType
        saturatedResultType =
            fnExprReturnType fnExpr (List.length argPlaceholders)

        -- Build eco.papExtend call
        ( resVar, ctx1 ) =
            Context.freshVar fnResult.ctx

        allOperandNames =
            fnResult.resultVar :: actualArgVars

        -- Use function result type for first operand, actual types for args
        allOperandTypes =
            fnResult.resultType :: actualArgTypes

        papExtendAttrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr allOperandTypes) )
                , ( "remaining_arity", IntAttr Nothing (List.length argPlaceholders) )
                , ( "slot_kinds", Ops.slotKindsAttr actualArgTypes ) -- one kind per newarg (S.5)
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


{-| Extract the return type of a function expression when applied to N arguments.
Examines the MonoType annotation of the function expression.
-}
fnExprReturnType : Mono.MonoExpr -> Int -> MlirType
fnExprReturnType fnExpr nArgs =
    let
        fnType =
            monoExprType fnExpr
    in
    Types.monoTypeToAbi (uncurryReturnType fnType nArgs)


{-| Unwrap curried Mono.mFunction types to find the final return type after consuming N args.
E.g. MFunction [MInt] (MFunction [MInt] MInt) with nArgs=2 -> MInt
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
                -- Not a function type but still have args to consume - shouldn't happen
                monoType


{-| Extract the MonoType from a MonoExpr.
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


{-| Emit PushValue with nested continuation.
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


{-| Emit Just with the top decoded value (base case).
-}
emitJustResult : DecoderEmitState -> ( List MlirOp, String, Context )
emitJustResult state =
    case state.decodedVars of
        resultVar :: _ ->
            emitJustResultWithVar resultVar state

        [] ->
            -- No decoded values - return unit wrapped in Just
            let
                ( unitVar, ctx1 ) =
                    Context.freshVar state.ctx

                ( ctx2, unitOp ) =
                    Ops.mlirOp ctx1 "eco.unit"
                        |> Ops.opBuilder.withResults [ ( unitVar, Types.ecoValue ) ]
                        |> Ops.opBuilder.build

                ( justVar, ctx3 ) =
                    Context.freshVar ctx2

                -- Use eco.construct.custom with constructor "Just", tag 0, size 1.
                -- No safepoint hint was emitted at this site previously; preserve
                -- behavior. EcoGCPrepare's liveness query at the construct op
                -- still picks up roots from the surrounding SSA scope.
                ( ctx4, justOp ) =
                    Ops.ecoConstructCustom ctx3 [] justVar 0 1 [ 0 ] [ ( unitVar, Types.ecoValue ) ] (Just "Just")
            in
            ( [ unitOp, justOp ], justVar, ctx4 )


{-| Emit Just with a specific variable.
Primitive types are stored unboxed (slot kind 1..3) to match type registry expectations.
Non-primitives are stored as eco.value (slot kind 0).
-}
emitJustResultWithVar : String -> DecoderEmitState -> ( List MlirOp, String, Context )
emitJustResultWithVar varName state =
    let
        -- Look up the type of the variable
        varType =
            Dict.get varName state.varTypes
                |> Maybe.withDefault Types.ecoValue
    in
    if Types.isUnboxable varType then
        -- Primitive types are stored unboxed in Just (matches type registry expectations).
        -- Slot 0's kind is derived from varType.
        let
            ( justVar, ctx1 ) =
                Context.freshVar state.ctx

            ( ctx2, justOp ) =
                Ops.ecoConstructCustom ctx1 [] justVar 0 1 [ Types.mlirTypeToKind varType ] [ ( varName, varType ) ] (Just "Just")
        in
        ( [ justOp ], justVar, ctx2 )

    else
        -- Non-primitives are stored boxed (eco.value)
        let
            ( justVar, ctx1 ) =
                Context.freshVar state.ctx

            -- Use eco.construct.custom with constructor "Just", tag 0, size 1, slot kind 0
            ( ctx2, justOp ) =
                Ops.ecoConstructCustom ctx1 [] justVar 0 1 [ 0 ] [ ( varName, Types.ecoValue ) ] (Just "Just")
        in
        ( [ justOp ], justVar, ctx2 )


{-| Emit Nothing result (failure case).
-}
emitNothingResult : DecoderEmitState -> ( List MlirOp, String, Context )
emitNothingResult state =
    let
        ( nothingVar, ctx1 ) =
            Context.freshVar state.ctx

        -- Use eco.constant Nothing (embedded constant, matches non-fused path)
        ( ctx2, nothingOp ) =
            Ops.ecoConstantNothing ctx1 nothingVar
    in
    ( [ nothingOp ], nothingVar, ctx2 )


{-| The single fixed-width read a decoding loop's item operations must be: the
`bf.read.*` op, its byte order, its width in bytes and the type of the value it
produces (`i64` for integers, `f64` for floats). `Nothing` for anything else.
-}
type alias FixedRead =
    { opName : String
    , endian : Maybe Endianness
    , width : Int
    , valueType : MlirType
    }


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


{-| Emits `read` at `cursor`, returning the ops, the value and the new cursor.
The caller must already have checked that `read.width` bytes are there
(BFOPS\_012).
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


{-| Emits an `i64` constant.
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


{-| Emits a binary `arith` op on two operands of type `operandType`.
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


{-| Emits `value :: tail` with the value stored unboxed (an `Int` or `Float`
item, REP rules: only Int, Float and Char are unboxed in heap fields).
-}
emitConsUnboxed : ( String, MlirType ) -> String -> Context -> ( MlirOp, String, Context )
emitConsUnboxed head tail ctx0 =
    let
        ( var, ctx1 ) =
            Context.freshVar ctx0

        ( ctx2, op ) =
            Ops.ecoConstructList ctx1 [] var head ( tail, Types.ecoValue ) True
    in
    ( op, var, ctx2 )


{-| Emits the reversal of `list` with the `List.reverse` kernel, keeping the
fused decoder to one loop (BFOPS\_035). Returns the ops and the reversed list.
-}
emitReverseList : String -> Context -> ( List MlirOp, String, Context )
emitReverseList list ctx0 =
    let
        ( reversed, ctx1 ) =
            Context.freshVar ctx0

        ( ctx2, callOp ) =
            Ops.ecoCallNamed ctx1 [] reversed "Elm_Kernel_List_reverse" [ ( list, Types.ecoValue ) ] Types.ecoValue
    in
    ( [ callOp ], reversed, ctx2 )


{-| Emits the empty list.
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


{-| Emit a count-based decode loop (`LoopDecodeList`).

The count is clamped at zero, and the bytes of every item are checked once
before the loop (`bf.require` of count \* width, with the product checked to fit
in 32 bits), so the reads inside the loop are all covered by that check
(BFOPS\_012); when they are not all there the decoder gives `Nothing`, as the
loop would when a read fails. Then an `scf.while` over (counter, cursor,
accumulator) reads an item and conses it until the counter reaches zero.

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

                -- The loop, inside the then-branch.
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


{-| Emits the count of a `LoopDecodeList` as an `i64`.
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


{-| Emit a sentinel-terminated decode loop (`LoopSentinelDecodeList`).

An `scf.while` over (cursor, accumulator, found). The before region continues
while the sentinel has not been found and `bf.require` shows the next item's
bytes are there, so the read in the after region only runs once that check has
passed (BFOPS\_012). The after region reads the item; the sentinel sets found
(consumed, not put in the list), any other item is consed. When the loop
stops, found tells the two cases apart: the sentinel was read, or input ran out
before one and the decoder gives `Nothing`.

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

                -- Before region: continue while not found and the item fits.
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

                -- After region: read the item; the sentinel sets found, any
                -- other item is consed.
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
