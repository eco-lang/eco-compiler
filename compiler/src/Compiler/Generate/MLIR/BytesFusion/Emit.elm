module Compiler.Generate.MLIR.BytesFusion.Emit exposing
    ( ExprCompiler
    , emitFusedDecoder
    , emitFusedEncoder
    , emitOps
    )

{-| Emit MLIR operations for fused byte encoding and decoding.

Takes Loop IR operations and emits bf dialect MLIR ops.

-}

import Bitwise
import Compiler.AST.Monomorphized as Mono
import Compiler.Generate.MLIR.BytesFusion.LoopIR as IR exposing (DecoderOp(..), Endianness(..), Op(..), WidthExpr(..))
import Compiler.Generate.MLIR.Context as Context exposing (Context)
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Types as Types
import Dict
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))


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
emitFusedEncoder compileExpr ctx ops =
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


{-| Emit Loop IR operations to MLIR ops.
-}
emitOps : ExprCompiler -> Context -> List Op -> ( List MlirOp, Context )
emitOps exprCompiler ctx ops =
    let
        ( mlirOps, _, newCtx ) =
            emitFusedEncoder exprCompiler ctx ops
    in
    ( mlirOps, newCtx )


{-| Emit a single Loop IR operation.
-}
emitOp : Op -> EmitState -> EmitState
emitOp op state =
    case op of
        InitCursor cursorName widthExpr ->
            emitInitCursor cursorName widthExpr state

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

        ReturnBuffer ->
            -- Buffer is already stored in state.bufferVar
            state


{-| Emit cursor initialization.
Allocates the buffer and creates initial cursor.
-}
emitInitCursor : String -> WidthExpr -> EmitState -> EmitState
emitInitCursor _ widthExpr state =
    let
        -- Emit width computation
        ( widthOps, widthVar, ctx1 ) =
            emitWidthExpr state.compileExpr widthExpr state.ctx

        -- Generate buffer variable name
        ( bufferVar, ctx2 ) =
            Context.freshVar ctx1

        -- Emit bf.alloc
        ( ctx3, allocOp ) =
            Ops.mlirOp ctx2 "bf.alloc"
                |> Ops.opBuilder.withOperands [ widthVar ]
                |> Ops.opBuilder.withResults [ ( bufferVar, Types.ecoValue ) ]
                |> Ops.opBuilder.build

        -- Generate cursor variable name
        ( cursorVar, ctx4 ) =
            Context.freshVar ctx3

        -- Emit bf.cursor.init
        ( ctx5, initOp ) =
            Ops.mlirOp ctx4 "bf.cursor.init"
                |> Ops.opBuilder.withOperands [ bufferVar ]
                |> Ops.opBuilder.withResults [ ( cursorVar, bfCursorType ) ]
                |> Ops.opBuilder.build
    in
    { state
        | ctx = ctx5
        , cursor = cursorVar
        , bufferVar = bufferVar
        , ops = initOp :: allocOp :: (widthOps ++ state.ops)
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

                ( ctx3, widthOp ) =
                    Ops.mlirOp ctx2 "bf.utf8_width"
                        |> Ops.opBuilder.withOperands [ strResult.resultVar ]
                        |> Ops.opBuilder.withResults [ ( resultVar, I32 ) ]
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

                ( ctx3, widthOp ) =
                    Ops.mlirOp ctx2 "bf.bytes_width"
                        |> Ops.opBuilder.withOperands [ bytesResult.resultVar ]
                        |> Ops.opBuilder.withResults [ ( resultVar, I32 ) ]
                        |> Ops.opBuilder.build
            in
            ( bytesResult.ops ++ [ widthOp ], resultVar, ctx3 )


{-| Convert endianness to attribute string.
-}
endianToAttr : Endianness -> MlirAttr
endianToAttr endian =
    case endian of
        LE ->
            StringAttr "le"

        BE ->
            StringAttr "be"


{-| Emit bf.write.u8 operation.
-}
emitWriteU8 valueExpr state =
    let
        exprResult =
            state.compileExpr valueExpr state.ctx

        ( newCursor, ctx2 ) =
            Context.freshVar exprResult.ctx

        ( ctx3, writeOp ) =
            Ops.mlirOp ctx2 "bf.write.u8"
                |> Ops.opBuilder.withOperands [ state.cursor, exprResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.build
    in
    { state
        | ctx = ctx3
        , cursor = newCursor
        , ops = writeOp :: (exprResult.ops ++ state.ops)
    }


{-| Emit bf.write.u16 operation.
-}
emitWriteU16 : Endianness -> Mono.MonoExpr -> EmitState -> EmitState
emitWriteU16 endian valueExpr state =
    let
        exprResult =
            state.compileExpr valueExpr state.ctx

        ( newCursor, ctx2 ) =
            Context.freshVar exprResult.ctx

        ( ctx3, writeOp ) =
            Ops.mlirOp ctx2 "bf.write.u16"
                |> Ops.opBuilder.withOperands [ state.cursor, exprResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.withAttrs (Dict.singleton "endianness" (endianToAttr endian))
                |> Ops.opBuilder.build
    in
    { state
        | ctx = ctx3
        , cursor = newCursor
        , ops = writeOp :: (exprResult.ops ++ state.ops)
    }


{-| Emit bf.write.u32 operation.
-}
emitWriteU32 : Endianness -> Mono.MonoExpr -> EmitState -> EmitState
emitWriteU32 endian valueExpr state =
    let
        exprResult =
            state.compileExpr valueExpr state.ctx

        ( newCursor, ctx2 ) =
            Context.freshVar exprResult.ctx

        ( ctx3, writeOp ) =
            Ops.mlirOp ctx2 "bf.write.u32"
                |> Ops.opBuilder.withOperands [ state.cursor, exprResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.withAttrs (Dict.singleton "endianness" (endianToAttr endian))
                |> Ops.opBuilder.build
    in
    { state
        | ctx = ctx3
        , cursor = newCursor
        , ops = writeOp :: (exprResult.ops ++ state.ops)
    }


{-| Emit bf.write.f32 operation.
-}
emitWriteF32 : Endianness -> Mono.MonoExpr -> EmitState -> EmitState
emitWriteF32 endian valueExpr state =
    let
        exprResult =
            state.compileExpr valueExpr state.ctx

        ( newCursor, ctx2 ) =
            Context.freshVar exprResult.ctx

        ( ctx3, writeOp ) =
            Ops.mlirOp ctx2 "bf.write.f32"
                |> Ops.opBuilder.withOperands [ state.cursor, exprResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.withAttrs (Dict.singleton "endianness" (endianToAttr endian))
                |> Ops.opBuilder.build
    in
    { state
        | ctx = ctx3
        , cursor = newCursor
        , ops = writeOp :: (exprResult.ops ++ state.ops)
    }


{-| Emit bf.write.f64 operation.
-}
emitWriteF64 : Endianness -> Mono.MonoExpr -> EmitState -> EmitState
emitWriteF64 endian valueExpr state =
    let
        exprResult =
            state.compileExpr valueExpr state.ctx

        ( newCursor, ctx2 ) =
            Context.freshVar exprResult.ctx

        ( ctx3, writeOp ) =
            Ops.mlirOp ctx2 "bf.write.f64"
                |> Ops.opBuilder.withOperands [ state.cursor, exprResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.withAttrs (Dict.singleton "endianness" (endianToAttr endian))
                |> Ops.opBuilder.build
    in
    { state
        | ctx = ctx3
        , cursor = newCursor
        , ops = writeOp :: (exprResult.ops ++ state.ops)
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

        ( ctx3, writeOp ) =
            Ops.mlirOp ctx2 "bf.write.bytes"
                |> Ops.opBuilder.withOperands [ state.cursor, exprResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.build
    in
    { state
        | ctx = ctx3
        , cursor = newCursor
        , ops = writeOp :: (exprResult.ops ++ state.ops)
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

        ( ctx3, writeOp ) =
            Ops.mlirOp ctx2 "bf.write.utf8"
                |> Ops.opBuilder.withOperands [ state.cursor, exprResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.build
    in
    { state
        | ctx = ctx3
        , cursor = newCursor
        , ops = writeOp :: (exprResult.ops ++ state.ops)
    }



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
    }



{-| Result of emitting item decoder ops in a loop body.
Contains ops, result variable, updated cursor, and context.
-}
type alias ItemDecoderResult =
    { ops : List MlirOp
    , resultVar : String
    , newCursor : String
    , ctx : Context
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

        ( ctx2, initOp ) =
            Ops.mlirOp ctx1 "bf.decoder.cursor.init"
                |> Ops.opBuilder.withOperands [ bytesVar ]
                |> Ops.opBuilder.withResults [ ( cursorVar, bfCursorType ) ]
                |> Ops.opBuilder.build

        initialState =
            { ctx = ctx2
            , cursor = cursorVar
            , bytesVar = bytesVar
            , decodedVars = []
            , compileExpr = compileExpr
            , varMapping = Dict.empty
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
    %value, %newCur = bf.read.*(...)
    // ... recursive call for remaining ops ...
    scf.yield %innerResult
  } else {
    %nothing = call @elm_maybe_nothing()
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
            emitApplyNested 1 fnExpr [ argPlaceholder ] resultPlaceholder rest state

        (Apply2 fnExpr arg1 arg2 resultPlaceholder) :: rest ->
            emitApplyNested 2 fnExpr [ arg1, arg2 ] resultPlaceholder rest state

        (Apply3 fnExpr arg1 arg2 arg3 resultPlaceholder) :: rest ->
            emitApplyNested 3 fnExpr [ arg1, arg2, arg3 ] resultPlaceholder rest state

        (Apply4 fnExpr arg1 arg2 arg3 arg4 resultPlaceholder) :: rest ->
            emitApplyNested 4 fnExpr [ arg1, arg2, arg3, arg4 ] resultPlaceholder rest state

        (Apply5 fnExpr arg1 arg2 arg3 arg4 arg5 resultPlaceholder) :: rest ->
            emitApplyNested 5 fnExpr [ arg1, arg2, arg3, arg4, arg5 ] resultPlaceholder rest state

        (PushValue valueExpr placeholderVar) :: rest ->
            emitPushValueNested valueExpr placeholderVar rest state

        (LoopDecodeList countVarName _ itemOps resultPlaceholder) :: rest ->
            emitLoopDecodeListNested countVarName itemOps resultPlaceholder rest state

        (LoopSentinelDecodeList sentinel _ itemOps resultPlaceholder) :: rest ->
            emitLoopSentinelDecodeListNested sentinel itemOps resultPlaceholder rest state

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

        ( ctx2, requireOp ) =
            Ops.mlirOp ctx1 "bf.require"
                |> Ops.opBuilder.withOperands [ state.cursor, bytesConstVar ]
                |> Ops.opBuilder.withResults [ ( okVar, I1 ) ]
                |> Ops.opBuilder.build

        -- 2. Build the "then" block: do the read and continue recursively
        ( valueVar, ctx3 ) =
            Context.freshVar ctx2

        ( newCursor, ctx4 ) =
            Context.freshVar ctx3

        endianAttrs =
            case maybeEndian of
                Just endian ->
                    Dict.singleton "endian" (endianToAttr endian)

                Nothing ->
                    Dict.empty

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

        ( ctx9, nothingOp ) =
            Ops.mlirOp ctx8 "eco.nothing"
                |> Ops.opBuilder.withResults [ ( nothingVar, Types.ecoValue ) ]
                |> Ops.opBuilder.build

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
        -- Compile the length expression
        lenResult =
            state.compileExpr lenExpr state.ctx

        -- bf.require with dynamic length
        ( okVar, ctx1 ) =
            Context.freshVar lenResult.ctx

        ( ctx2, requireOp ) =
            Ops.mlirOp ctx1 "bf.require"
                |> Ops.opBuilder.withOperands [ state.cursor, lenResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( okVar, I1 ) ]
                |> Ops.opBuilder.build

        -- Build then block: read bytes and continue
        ( bytesVar, ctx3 ) =
            Context.freshVar ctx2

        ( newCursor, ctx4 ) =
            Context.freshVar ctx3

        ( ctx5, readOp ) =
            Ops.mlirOp ctx4 "bf.read.bytes"
                |> Ops.opBuilder.withOperands [ state.cursor, lenResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( bytesVar, Types.ecoValue ), ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.build

        updatedState =
            { state
                | ctx = ctx5
                , cursor = newCursor
                , decodedVars = bytesVar :: state.decodedVars
                , varMapping = Dict.insert placeholderVar bytesVar state.varMapping
            }

        ( thenBodyOps, thenResultVar, ctx6 ) =
            emitDecoderOpsNested restOps updatedState

        ( ctx7, thenYieldOp ) =
            Ops.mlirOp ctx6 "scf.yield"
                |> Ops.opBuilder.withOperands [ thenResultVar ]
                |> Ops.opBuilder.build

        thenRegion =
            Ops.mkRegion [] (readOp :: thenBodyOps) thenYieldOp

        -- Else block: Nothing
        ( nothingVar, ctx8 ) =
            Context.freshVar ctx7

        ( ctx9, nothingOp ) =
            Ops.mlirOp ctx8 "eco.nothing"
                |> Ops.opBuilder.withResults [ ( nothingVar, Types.ecoValue ) ]
                |> Ops.opBuilder.build

        ( ctx10, elseYieldOp ) =
            Ops.mlirOp ctx9 "scf.yield"
                |> Ops.opBuilder.withOperands [ nothingVar ]
                |> Ops.opBuilder.build

        elseRegion =
            Ops.mkRegion [] [ nothingOp ] elseYieldOp

        -- scf.if
        ( ifResultVar, ctx11 ) =
            Context.freshVar ctx10

        ( ctx12, ifOp ) =
            Ops.mlirOp ctx11 "scf.if"
                |> Ops.opBuilder.withOperands [ okVar ]
                |> Ops.opBuilder.withResults [ ( ifResultVar, Types.ecoValue ) ]
                |> Ops.opBuilder.withRegions [ thenRegion, elseRegion ]
                |> Ops.opBuilder.build
    in
    ( lenResult.ops ++ [ requireOp, ifOp ], ifResultVar, ctx12 )


{-| Emit ReadUtf8 with nested scf.if pattern.
-}
emitReadUtf8Nested : Mono.MonoExpr -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitReadUtf8Nested lenExpr placeholderVar restOps state =
    let
        lenResult =
            state.compileExpr lenExpr state.ctx

        ( okVar, ctx1 ) =
            Context.freshVar lenResult.ctx

        ( ctx2, requireOp ) =
            Ops.mlirOp ctx1 "bf.require"
                |> Ops.opBuilder.withOperands [ state.cursor, lenResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( okVar, I1 ) ]
                |> Ops.opBuilder.build

        ( stringVar, ctx3 ) =
            Context.freshVar ctx2

        ( newCursor, ctx4 ) =
            Context.freshVar ctx3

        ( ctx5, readOp ) =
            Ops.mlirOp ctx4 "bf.read.utf8"
                |> Ops.opBuilder.withOperands [ state.cursor, lenResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( stringVar, Types.ecoValue ), ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.build

        updatedState =
            { state
                | ctx = ctx5
                , cursor = newCursor
                , decodedVars = stringVar :: state.decodedVars
                , varMapping = Dict.insert placeholderVar stringVar state.varMapping
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
            Ops.mlirOp ctx8 "eco.nothing"
                |> Ops.opBuilder.withResults [ ( nothingVar, Types.ecoValue ) ]
                |> Ops.opBuilder.build

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
    ( lenResult.ops ++ [ requireOp, ifOp ], ifResultVar, ctx12 )


{-| Emit ReadBytesVar with nested scf.if pattern (length from previously decoded SSA var).
Looks up the lenPlaceholderVar in varMapping to get the actual SSA variable.
-}
emitReadBytesVarNested : String -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitReadBytesVarNested lenPlaceholderVar resultPlaceholderVar restOps state =
    let
        -- Look up the actual SSA variable for the length
        actualLenVar =
            Dict.get lenPlaceholderVar state.varMapping
                |> Maybe.withDefault lenPlaceholderVar

        ( okVar, ctx1 ) =
            Context.freshVar state.ctx

        ( ctx2, requireOp ) =
            Ops.mlirOp ctx1 "bf.require"
                |> Ops.opBuilder.withOperands [ state.cursor, actualLenVar ]
                |> Ops.opBuilder.withResults [ ( okVar, I1 ) ]
                |> Ops.opBuilder.build

        ( bytesVar, ctx3 ) =
            Context.freshVar ctx2

        ( newCursor, ctx4 ) =
            Context.freshVar ctx3

        ( ctx5, readOp ) =
            Ops.mlirOp ctx4 "bf.read.bytes"
                |> Ops.opBuilder.withOperands [ state.cursor, actualLenVar ]
                |> Ops.opBuilder.withResults [ ( bytesVar, Types.ecoValue ), ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.build

        updatedState =
            { state
                | ctx = ctx5
                , cursor = newCursor
                , decodedVars = bytesVar :: state.decodedVars
                , varMapping = Dict.insert resultPlaceholderVar bytesVar state.varMapping
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
            Ops.mlirOp ctx8 "eco.nothing"
                |> Ops.opBuilder.withResults [ ( nothingVar, Types.ecoValue ) ]
                |> Ops.opBuilder.build

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
    ( [ requireOp, ifOp ], ifResultVar, ctx12 )


{-| Emit ReadUtf8Var with nested scf.if pattern (length from previously decoded SSA var).
Looks up the lenPlaceholderVar in varMapping to get the actual SSA variable.
-}
emitReadUtf8VarNested : String -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitReadUtf8VarNested lenPlaceholderVar resultPlaceholderVar restOps state =
    let
        -- Look up the actual SSA variable for the length
        actualLenVar =
            Dict.get lenPlaceholderVar state.varMapping
                |> Maybe.withDefault lenPlaceholderVar

        ( okVar, ctx1 ) =
            Context.freshVar state.ctx

        ( ctx2, requireOp ) =
            Ops.mlirOp ctx1 "bf.require"
                |> Ops.opBuilder.withOperands [ state.cursor, actualLenVar ]
                |> Ops.opBuilder.withResults [ ( okVar, I1 ) ]
                |> Ops.opBuilder.build

        ( stringVar, ctx3 ) =
            Context.freshVar ctx2

        ( newCursor, ctx4 ) =
            Context.freshVar ctx3

        ( ctx5, readOp ) =
            Ops.mlirOp ctx4 "bf.read.utf8"
                |> Ops.opBuilder.withOperands [ state.cursor, actualLenVar ]
                |> Ops.opBuilder.withResults [ ( stringVar, Types.ecoValue ), ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.build

        updatedState =
            { state
                | ctx = ctx5
                , cursor = newCursor
                , decodedVars = stringVar :: state.decodedVars
                , varMapping = Dict.insert resultPlaceholderVar stringVar state.varMapping
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
            Ops.mlirOp ctx8 "eco.nothing"
                |> Ops.opBuilder.withResults [ ( nothingVar, Types.ecoValue ) ]
                |> Ops.opBuilder.build

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
    ( [ requireOp, ifOp ], ifResultVar, ctx12 )


{-| Emit Apply with nested continuation.
Apply operations don't do bounds checks, so no scf.if needed.
Looks up arg placeholder vars in varMapping to get actual SSA variables.
-}
emitApplyNested : Int -> Mono.MonoExpr -> List String -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitApplyNested _ fnExpr argPlaceholders resultPlaceholder restOps state =
    let
        -- Compile function expression
        fnResult =
            state.compileExpr fnExpr state.ctx

        -- Look up actual SSA variables for args
        actualArgVars =
            List.map
                (\placeholder ->
                    Dict.get placeholder state.varMapping
                        |> Maybe.withDefault placeholder
                )
                argPlaceholders

        -- Build eco.papExtend call
        ( resVar, ctx1 ) =
            Context.freshVar fnResult.ctx

        -- All decoded values are boxed eco.value
        allOperandNames =
            fnResult.resultVar :: actualArgVars

        -- Use function result type for first operand, eco.value for args
        allOperandTypes =
            fnResult.resultType :: List.repeat (List.length actualArgVars) Types.ecoValue

        -- Remaining arity is 0 since we're fully applying
        papExtendAttrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr allOperandTypes) )
                , ( "remaining_arity", IntAttr Nothing 0 )
                , ( "newargs_unboxed_bitmap", IntAttr Nothing 0 )
                ]

        ( ctx2, papExtendOp ) =
            Ops.mlirOp ctx1 "eco.papExtend"
                |> Ops.opBuilder.withOperands allOperandNames
                |> Ops.opBuilder.withResults [ ( resVar, Types.ecoValue ) ]
                |> Ops.opBuilder.withAttrs papExtendAttrs
                |> Ops.opBuilder.build

        updatedState =
            { state
                | ctx = ctx2
                , decodedVars = resVar :: state.decodedVars
                , varMapping = Dict.insert resultPlaceholder resVar state.varMapping
            }

        ( restBodyOps, resultVar, finalCtx ) =
            emitDecoderOpsNested restOps updatedState
    in
    ( fnResult.ops ++ [ papExtendOp ] ++ restBodyOps, resultVar, finalCtx )


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

                ( ctx4, justOp ) =
                    Ops.mlirOp ctx3 "eco.just"
                        |> Ops.opBuilder.withOperands [ unitVar ]
                        |> Ops.opBuilder.withResults [ ( justVar, Types.ecoValue ) ]
                        |> Ops.opBuilder.build
            in
            ( [ unitOp, justOp ], justVar, ctx4 )


{-| Emit Just with a specific variable.
-}
emitJustResultWithVar : String -> DecoderEmitState -> ( List MlirOp, String, Context )
emitJustResultWithVar varName state =
    let
        ( justVar, ctx1 ) =
            Context.freshVar state.ctx

        ( ctx2, justOp ) =
            Ops.mlirOp ctx1 "eco.just"
                |> Ops.opBuilder.withOperands [ varName ]
                |> Ops.opBuilder.withResults [ ( justVar, Types.ecoValue ) ]
                |> Ops.opBuilder.build
    in
    ( [ justOp ], justVar, ctx2 )


{-| Emit Nothing result (failure case).
-}
emitNothingResult : DecoderEmitState -> ( List MlirOp, String, Context )
emitNothingResult state =
    let
        ( nothingVar, ctx1 ) =
            Context.freshVar state.ctx

        ( ctx2, nothingOp ) =
            Ops.mlirOp ctx1 "eco.nothing"
                |> Ops.opBuilder.withResults [ ( nothingVar, Types.ecoValue ) ]
                |> Ops.opBuilder.build
    in
    ( [ nothingOp ], nothingVar, ctx2 )



{-| Emit a count-based decode loop using scf.while.

Loop structure:
- Loop variables: (counter: i64, cursor: bf.cursor, accumulator: eco.value)
- Before region: check counter > 0, emit scf.condition
- After region: decode item, decrement counter, cons to accumulator, yield

-}
emitLoopDecodeListNested : String -> List DecoderOp -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitLoopDecodeListNested countVarName itemOps resultPlaceholder restOps state =
    let
        -- Parse countVarName: either "const:N" or an SSA variable name
        ( countInitOps, countVar, ctxAfterCount ) =
            if String.startsWith "const:" countVarName then
                -- It's a constant - extract the number and create arith.constant
                let
                    countVal =
                        String.dropLeft 6 countVarName
                            |> String.toInt
                            |> Maybe.withDefault 0

                    ( cVar, ctxConst1 ) =
                        Context.freshVar state.ctx

                    ( ctxConst2, constOp ) =
                        Ops.mlirOp ctxConst1 "arith.constant"
                            |> Ops.opBuilder.withResults [ ( cVar, I64 ) ]
                            |> Ops.opBuilder.withAttrs (Dict.singleton "value" (IntAttr (Just I64) countVal))
                            |> Ops.opBuilder.build
                in
                ( [ constOp ], cVar, ctxConst2 )

            else
                -- It's an SSA variable - look up in varMapping
                let
                    actualVar =
                        Dict.get countVarName state.varMapping
                            |> Maybe.withDefault countVarName
                in
                ( [], actualVar, state.ctx )

        -- Create initial empty list (eco.nil)
        ( initListVar, ctx1 ) =
            Context.freshVar ctxAfterCount

        ( ctx2, nilOp ) =
            Ops.mlirOp ctx1 "eco.nil"
                |> Ops.opBuilder.withResults [ ( initListVar, Types.ecoValue ) ]
                |> Ops.opBuilder.build

        -- Create zero constant for comparison
        ( zeroVar, ctx3 ) =
            Context.freshVar ctx2

        ( ctx4, zeroOp ) =
            Ops.mlirOp ctx3 "arith.constant"
                |> Ops.opBuilder.withResults [ ( zeroVar, I64 ) ]
                |> Ops.opBuilder.withAttrs (Dict.singleton "value" (IntAttr (Just I64) 0))
                |> Ops.opBuilder.build

        -- Build the before region: check counter > 0
        -- Block args: (counter: i64, cursor: bf.cursor, acc: eco.value)
        ( beforeCounterArg, ctx5 ) =
            Context.freshVar ctx4

        ( beforeCursorArg, ctx6 ) =
            Context.freshVar ctx5

        ( beforeAccArg, ctx7 ) =
            Context.freshVar ctx6

        -- Compare: counter > 0
        ( condVar, ctx8 ) =
            Context.freshVar ctx7

        ( ctx9, cmpOp ) =
            Ops.mlirOp ctx8 "arith.cmpi"
                |> Ops.opBuilder.withOperands [ beforeCounterArg, zeroVar ]
                |> Ops.opBuilder.withResults [ ( condVar, I1 ) ]
                |> Ops.opBuilder.withAttrs (Dict.singleton "predicate" (IntAttr Nothing 4))
                |> Ops.opBuilder.build

        -- sgt = 4 in arith.CmpIPredicate
        -- scf.condition with carry values
        ( ctx10, conditionOp ) =
            Ops.scfCondition ctx9
                condVar
                [ ( beforeCounterArg, I64 )
                , ( beforeCursorArg, bfCursorType )
                , ( beforeAccArg, Types.ecoValue )
                ]

        beforeRegion =
            Ops.mkRegion
                [ ( beforeCounterArg, I64 )
                , ( beforeCursorArg, bfCursorType )
                , ( beforeAccArg, Types.ecoValue )
                ]
                [ cmpOp ]
                conditionOp

        -- Build the after region: decode item, decrement, cons, yield
        -- Block args: (counter: i64, cursor: bf.cursor, acc: eco.value)
        ( afterCounterArg, ctx11 ) =
            Context.freshVar ctx10

        ( afterCursorArg, ctx12 ) =
            Context.freshVar ctx11

        ( afterAccArg, ctx13 ) =
            Context.freshVar ctx12

        -- Create a fresh state for emitting item decoder ops
        itemState =
            { state
                | ctx = ctx13
                , cursor = afterCursorArg
                , decodedVars = []
                , varMapping = state.varMapping
            }

        -- Emit item decoder ops - now returns ItemDecoderResult record
        itemResult =
            emitItemDecoderOps itemOps itemState

        -- Decrement counter
        ( oneVar, ctx15 ) =
            Context.freshVar itemResult.ctx

        ( ctx16, oneOp ) =
            Ops.mlirOp ctx15 "arith.constant"
                |> Ops.opBuilder.withResults [ ( oneVar, I64 ) ]
                |> Ops.opBuilder.withAttrs (Dict.singleton "value" (IntAttr (Just I64) 1))
                |> Ops.opBuilder.build

        ( newCounterVar, ctx17 ) =
            Context.freshVar ctx16

        ( ctx18, subOp ) =
            Ops.mlirOp ctx17 "arith.subi"
                |> Ops.opBuilder.withOperands [ afterCounterArg, oneVar ]
                |> Ops.opBuilder.withResults [ ( newCounterVar, I64 ) ]
                |> Ops.opBuilder.build

        -- Cons item to accumulator
        ( newAccVar, ctx19 ) =
            Context.freshVar ctx18

        ( ctx20, consOp ) =
            Ops.mlirOp ctx19 "eco.cons"
                |> Ops.opBuilder.withOperands [ itemResult.resultVar, afterAccArg ]
                |> Ops.opBuilder.withResults [ ( newAccVar, Types.ecoValue ) ]
                |> Ops.opBuilder.build

        -- Use the cursor returned from item decoder ops (properly threaded now!)
        newCursorVar =
            itemResult.newCursor

        -- Yield new loop values
        ( ctx21, yieldOp ) =
            Ops.mlirOp ctx20 "scf.yield"
                |> Ops.opBuilder.withOperands [ newCounterVar, newCursorVar, newAccVar ]
                |> Ops.opBuilder.build

        afterRegion =
            Ops.mkRegion
                [ ( afterCounterArg, I64 )
                , ( afterCursorArg, bfCursorType )
                , ( afterAccArg, Types.ecoValue )
                ]
                (itemResult.ops ++ [ oneOp, subOp, consOp ])
                yieldOp

        -- Build the scf.while
        ( whileCounterResult, ctx22 ) =
            Context.freshVar ctx21

        ( whileCursorResult, ctx23 ) =
            Context.freshVar ctx22

        ( whileAccResult, ctx24 ) =
            Context.freshVar ctx23

        ( ctx25, whileOp ) =
            Ops.scfWhile ctx24
                [ ( whileCounterResult, countVar, I64 )
                , ( whileCursorResult, state.cursor, bfCursorType )
                , ( whileAccResult, initListVar, Types.ecoValue )
                ]
                beforeRegion
                afterRegion

        -- Reverse the accumulated list (it was built in reverse order via cons)
        ( reversedListVar, ctx26 ) =
            Context.freshVar ctx25

        ( ctx27, reverseOp ) =
            Ops.mlirOp ctx26 "func.call"
                |> Ops.opBuilder.withOperands [ whileAccResult ]
                |> Ops.opBuilder.withResults [ ( reversedListVar, Types.ecoValue ) ]
                |> Ops.opBuilder.withAttrs
                    (Dict.fromList
                        [ ( "callee", SymbolRefAttr "elm_list_reverse" )
                        , ( "_operand_types", ArrayAttr Nothing [ TypeAttr Types.ecoValue ] )
                        ]
                    )
                |> Ops.opBuilder.build

        -- Update state with reversed loop result
        updatedState =
            { state
                | ctx = ctx27
                , cursor = whileCursorResult
                , decodedVars = reversedListVar :: state.decodedVars
                , varMapping = Dict.insert resultPlaceholder reversedListVar state.varMapping
            }

        -- Continue with remaining ops
        ( restBodyOps, resultVar, finalCtx ) =
            emitDecoderOpsNested restOps updatedState
    in
    ( countInitOps ++ [ nilOp, zeroOp, whileOp, reverseOp ] ++ restBodyOps, resultVar, finalCtx )


{-| Emit sentinel-terminated loop decode (e.g., null-terminated list).

This generates an scf.while that:
1. Reads a value
2. Checks if it equals sentinel
3. If not sentinel, conses to accumulator and continues
4. If sentinel, exits loop
5. Reverses the accumulated list
-}
emitLoopSentinelDecodeListNested : Int -> List DecoderOp -> String -> List DecoderOp -> DecoderEmitState -> ( List MlirOp, String, Context )
emitLoopSentinelDecodeListNested sentinel itemOps resultPlaceholder restOps state =
    let
        -- Create initial empty list (eco.nil)
        ( initListVar, ctx1 ) =
            Context.freshVar state.ctx

        ( ctx2, nilOp ) =
            Ops.mlirOp ctx1 "eco.nil"
                |> Ops.opBuilder.withResults [ ( initListVar, Types.ecoValue ) ]
                |> Ops.opBuilder.build

        -- Create sentinel constant for comparison
        ( sentinelVar, ctx3 ) =
            Context.freshVar ctx2

        ( ctx4, sentinelOp ) =
            Ops.mlirOp ctx3 "arith.constant"
                |> Ops.opBuilder.withResults [ ( sentinelVar, I64 ) ]
                |> Ops.opBuilder.withAttrs (Dict.singleton "value" (IntAttr (Just I64) sentinel))
                |> Ops.opBuilder.build

        -- Build the before region: read value, check if == sentinel
        -- Block args: (cursor: bf.cursor, acc: eco.value)
        ( beforeCursorArg, ctx5 ) =
            Context.freshVar ctx4

        ( beforeAccArg, ctx6 ) =
            Context.freshVar ctx5

        -- Emit item decoder ops in before region to get the value
        beforeItemState =
            { state
                | ctx = ctx6
                , cursor = beforeCursorArg
                , decodedVars = []
                , varMapping = state.varMapping
            }

        beforeItemResult =
            emitItemDecoderOps itemOps beforeItemState

        -- Compare: value != sentinel (we continue while NOT sentinel)
        ( condVar, ctx7 ) =
            Context.freshVar beforeItemResult.ctx

        ( ctx8, cmpOp ) =
            Ops.mlirOp ctx7 "arith.cmpi"
                |> Ops.opBuilder.withOperands [ beforeItemResult.resultVar, sentinelVar ]
                |> Ops.opBuilder.withResults [ ( condVar, I1 ) ]
                |> Ops.opBuilder.withAttrs (Dict.singleton "predicate" (IntAttr Nothing 1))
                |> Ops.opBuilder.build

        -- ne = 1 in arith.CmpIPredicate (not equal)
        -- scf.condition with carry values: (cursor, acc, value)
        -- We carry the read value so we don't have to read again in the after region
        ( ctx9, conditionOp ) =
            Ops.scfCondition ctx8
                condVar
                [ ( beforeItemResult.newCursor, bfCursorType )
                , ( beforeAccArg, Types.ecoValue )
                , ( beforeItemResult.resultVar, Types.ecoValue )
                ]

        beforeRegion =
            Ops.mkRegion
                [ ( beforeCursorArg, bfCursorType )
                , ( beforeAccArg, Types.ecoValue )
                ]
                (beforeItemResult.ops ++ [ cmpOp ])
                conditionOp

        -- Build the after region: cons value to acc, yield
        -- Block args: (cursor: bf.cursor, acc: eco.value, value: eco.value)
        ( afterCursorArg, ctx10 ) =
            Context.freshVar ctx9

        ( afterAccArg, ctx11 ) =
            Context.freshVar ctx10

        ( afterValueArg, ctx12 ) =
            Context.freshVar ctx11

        -- Cons value to accumulator
        ( newAccVar, ctx13 ) =
            Context.freshVar ctx12

        ( ctx14, consOp ) =
            Ops.mlirOp ctx13 "eco.cons"
                |> Ops.opBuilder.withOperands [ afterValueArg, afterAccArg ]
                |> Ops.opBuilder.withResults [ ( newAccVar, Types.ecoValue ) ]
                |> Ops.opBuilder.build

        -- Yield new cursor and acc (value is not yielded, it was consumed)
        ( ctx15, yieldOp ) =
            Ops.mlirOp ctx14 "scf.yield"
                |> Ops.opBuilder.withOperands [ afterCursorArg, newAccVar ]
                |> Ops.opBuilder.build

        afterRegion =
            Ops.mkRegion
                [ ( afterCursorArg, bfCursorType )
                , ( afterAccArg, Types.ecoValue )
                , ( afterValueArg, Types.ecoValue )
                ]
                [ consOp ]
                yieldOp

        -- Build the scf.while
        ( whileCursorResult, ctx16 ) =
            Context.freshVar ctx15

        ( whileAccResult, ctx17 ) =
            Context.freshVar ctx16

        ( ctx18, whileOp ) =
            Ops.scfWhile ctx17
                [ ( whileCursorResult, state.cursor, bfCursorType )
                , ( whileAccResult, initListVar, Types.ecoValue )
                ]
                beforeRegion
                afterRegion

        -- Reverse the accumulated list
        ( reversedListVar, ctx19 ) =
            Context.freshVar ctx18

        ( ctx20, reverseOp ) =
            Ops.mlirOp ctx19 "func.call"
                |> Ops.opBuilder.withOperands [ whileAccResult ]
                |> Ops.opBuilder.withResults [ ( reversedListVar, Types.ecoValue ) ]
                |> Ops.opBuilder.withAttrs
                    (Dict.fromList
                        [ ( "callee", SymbolRefAttr "elm_list_reverse" )
                        , ( "_operand_types", ArrayAttr Nothing [ TypeAttr Types.ecoValue ] )
                        ]
                    )
                |> Ops.opBuilder.build

        -- Update state with reversed loop result
        updatedState =
            { state
                | ctx = ctx20
                , cursor = whileCursorResult
                , decodedVars = reversedListVar :: state.decodedVars
                , varMapping = Dict.insert resultPlaceholder reversedListVar state.varMapping
            }

        -- Continue with remaining ops
        ( restBodyOps, resultVar, finalCtx ) =
            emitDecoderOpsNested restOps updatedState
    in
    ( [ nilOp, sentinelOp, whileOp, reverseOp ] ++ restBodyOps, resultVar, finalCtx )


{-| Emit item decoder ops for loop body.
This is a simplified version that doesn't handle nested scf.if properly yet.
For now, it assumes single non-failing reads.
-}
emitItemDecoderOps : List DecoderOp -> DecoderEmitState -> ItemDecoderResult
emitItemDecoderOps ops state =
    case ops of
        [] ->
            -- No ops - return unit with unchanged cursor
            let
                ( unitVar, ctx1 ) =
                    Context.freshVar state.ctx

                ( ctx2, unitOp ) =
                    Ops.mlirOp ctx1 "eco.unit"
                        |> Ops.opBuilder.withResults [ ( unitVar, Types.ecoValue ) ]
                        |> Ops.opBuilder.build
            in
            { ops = [ unitOp ]
            , resultVar = unitVar
            , newCursor = state.cursor
            , ctx = ctx2
            }

        -- Single primitive reads
        [ ReadU8 _ placeholderVar ] ->
            emitSimpleRead 1 "bf.read.u8" Nothing I64 placeholderVar state

        [ ReadI8 _ placeholderVar ] ->
            emitSimpleRead 1 "bf.read.i8" Nothing I64 placeholderVar state

        [ ReadU16 _ endian placeholderVar ] ->
            emitSimpleRead 2 "bf.read.u16" (Just endian) I64 placeholderVar state

        [ ReadI16 _ endian placeholderVar ] ->
            emitSimpleRead 2 "bf.read.i16" (Just endian) I64 placeholderVar state

        [ ReadU32 _ endian placeholderVar ] ->
            emitSimpleRead 4 "bf.read.u32" (Just endian) I64 placeholderVar state

        [ ReadI32 _ endian placeholderVar ] ->
            emitSimpleRead 4 "bf.read.i32" (Just endian) I64 placeholderVar state

        [ ReadF32 _ endian placeholderVar ] ->
            emitSimpleRead 4 "bf.read.f32" (Just endian) F64 placeholderVar state

        [ ReadF64 _ endian placeholderVar ] ->
            emitSimpleRead 8 "bf.read.f64" (Just endian) F64 placeholderVar state

        -- Read + Apply1 (map pattern): decode item, then apply function
        [ ReadU8 _ readPlaceholder, Apply1 fnExpr argPlaceholder resultPlaceholder ] ->
            emitReadThenApply1 1 "bf.read.u8" Nothing I64 fnExpr argPlaceholder resultPlaceholder state

        [ ReadU16 _ endian readPlaceholder, Apply1 fnExpr argPlaceholder resultPlaceholder ] ->
            emitReadThenApply1 2 "bf.read.u16" (Just endian) I64 fnExpr argPlaceholder resultPlaceholder state

        [ ReadU32 _ endian readPlaceholder, Apply1 fnExpr argPlaceholder resultPlaceholder ] ->
            emitReadThenApply1 4 "bf.read.u32" (Just endian) I64 fnExpr argPlaceholder resultPlaceholder state

        [ ReadI32 _ endian readPlaceholder, Apply1 fnExpr argPlaceholder resultPlaceholder ] ->
            emitReadThenApply1 4 "bf.read.i32" (Just endian) I64 fnExpr argPlaceholder resultPlaceholder state

        [ ReadF32 _ endian readPlaceholder, Apply1 fnExpr argPlaceholder resultPlaceholder ] ->
            emitReadThenApply1 4 "bf.read.f32" (Just endian) F64 fnExpr argPlaceholder resultPlaceholder state

        [ ReadF64 _ endian readPlaceholder, Apply1 fnExpr argPlaceholder resultPlaceholder ] ->
            emitReadThenApply1 8 "bf.read.f64" (Just endian) F64 fnExpr argPlaceholder resultPlaceholder state

        -- Two reads + Apply2 (map2 pattern)
        [ read1, read2, Apply2 fnExpr arg1Placeholder arg2Placeholder resultPlaceholder ] ->
            emitTwoReadsThenApply2 read1 read2 fnExpr resultPlaceholder state

        _ ->
            -- Unhandled pattern - emit sequential ops with cursor threading
            emitItemOpsSequentially ops state


{-| Emit a simple read without nested scf.if (for use inside loop body).
Assumes bounds have already been checked or will be checked at higher level.
-}
emitSimpleRead : Int -> String -> Maybe Endianness -> MlirType -> String -> DecoderEmitState -> ItemDecoderResult
emitSimpleRead byteCount readOpName maybeEndian resultType placeholderVar state =
    let
        ( valueVar, ctx1 ) =
            Context.freshVar state.ctx

        ( newCursor, ctx2 ) =
            Context.freshVar ctx1

        endianAttrs =
            case maybeEndian of
                Just endian ->
                    Dict.singleton "endian" (endianToAttr endian)

                Nothing ->
                    Dict.empty

        ( ctx3, readOp ) =
            Ops.mlirOp ctx2 readOpName
                |> Ops.opBuilder.withOperands [ state.cursor ]
                |> Ops.opBuilder.withAttrs endianAttrs
                |> Ops.opBuilder.withResults [ ( valueVar, resultType ), ( newCursor, bfCursorType ) ]
                |> Ops.opBuilder.build

        -- Box the value into eco.value
        ( boxedVar, ctx4 ) =
            Context.freshVar ctx3

        boxOpName =
            case resultType of
                I64 ->
                    "eco.box.i64"

                F64 ->
                    "eco.box.f64"

                _ ->
                    "eco.box.i64"

        ( ctx5, boxOp ) =
            Ops.mlirOp ctx4 boxOpName
                |> Ops.opBuilder.withOperands [ valueVar ]
                |> Ops.opBuilder.withResults [ ( boxedVar, Types.ecoValue ) ]
                |> Ops.opBuilder.build
    in
    { ops = [ readOp, boxOp ]
    , resultVar = boxedVar
    , newCursor = newCursor
    , ctx = ctx5
    }



{-| Emit read + Apply1 pattern (map) for loop item.
Returns (ops, resultVar, newCursor, ctx).
-}
emitReadThenApply1 : Int -> String -> Maybe Endianness -> MlirType -> Mono.MonoExpr -> String -> String -> DecoderEmitState -> ItemDecoderResult
emitReadThenApply1 byteCount readOpName maybeEndian resultType fnExpr argPlaceholder resultPlaceholder state =
    let
        -- First emit the read
        readResult =
            emitSimpleRead byteCount readOpName maybeEndian resultType argPlaceholder state

        -- Compile the function expression
        fnResult =
            state.compileExpr fnExpr readResult.ctx

        -- Apply the function to the read result
        ( resVar, ctx2 ) =
            Context.freshVar fnResult.ctx

        papExtendAttrs =
            Dict.fromList
                [ ( "n_args", IntAttr Nothing 1 )
                , ( "_operand_types"
                  , ArrayAttr Nothing
                        [ TypeAttr Types.ecoValue -- fn
                        , TypeAttr Types.ecoValue -- arg
                        ]
                  )
                ]

        ( ctx3, applyOp ) =
            Ops.mlirOp ctx2 "eco.pap_extend"
                |> Ops.opBuilder.withOperands [ fnResult.resultVar, readResult.resultVar ]
                |> Ops.opBuilder.withResults [ ( resVar, Types.ecoValue ) ]
                |> Ops.opBuilder.withAttrs papExtendAttrs
                |> Ops.opBuilder.build
    in
    { ops = readResult.ops ++ fnResult.ops ++ [ applyOp ]
    , resultVar = resVar
    , newCursor = readResult.newCursor
    , ctx = ctx3
    }


{-| Emit two reads + Apply2 pattern (map2) for loop item.
Returns (ops, resultVar, newCursor, ctx).
-}
emitTwoReadsThenApply2 : DecoderOp -> DecoderOp -> Mono.MonoExpr -> String -> DecoderEmitState -> ItemDecoderResult
emitTwoReadsThenApply2 read1 read2 fnExpr resultPlaceholder state =
    let
        -- Emit first read
        read1Result =
            emitSingleReadOp read1 state

        -- Emit second read with updated cursor
        state2 =
            { state | ctx = read1Result.ctx, cursor = read1Result.newCursor }

        read2Result =
            emitSingleReadOp read2 state2

        -- Compile the function expression
        fnResult =
            state.compileExpr fnExpr read2Result.ctx

        -- Apply the function to both results
        ( resVar, ctx3 ) =
            Context.freshVar fnResult.ctx

        papExtendAttrs =
            Dict.fromList
                [ ( "n_args", IntAttr Nothing 2 )
                , ( "_operand_types"
                  , ArrayAttr Nothing
                        [ TypeAttr Types.ecoValue -- fn
                        , TypeAttr Types.ecoValue -- arg1
                        , TypeAttr Types.ecoValue -- arg2
                        ]
                  )
                ]

        ( ctx4, applyOp ) =
            Ops.mlirOp ctx3 "eco.pap_extend"
                |> Ops.opBuilder.withOperands [ fnResult.resultVar, read1Result.resultVar, read2Result.resultVar ]
                |> Ops.opBuilder.withResults [ ( resVar, Types.ecoValue ) ]
                |> Ops.opBuilder.withAttrs papExtendAttrs
                |> Ops.opBuilder.build
    in
    { ops = read1Result.ops ++ read2Result.ops ++ fnResult.ops ++ [ applyOp ]
    , resultVar = resVar
    , newCursor = read2Result.newCursor
    , ctx = ctx4
    }


{-| Emit a single read op, returns (ops, resultVar, newCursor, ctx).
Helper for multi-read patterns.
-}
emitSingleReadOp : DecoderOp -> DecoderEmitState -> ItemDecoderResult
emitSingleReadOp op state =
    case op of
        ReadU8 _ placeholderVar ->
            emitSimpleRead 1 "bf.read.u8" Nothing I64 placeholderVar state

        ReadI8 _ placeholderVar ->
            emitSimpleRead 1 "bf.read.i8" Nothing I64 placeholderVar state

        ReadU16 _ endian placeholderVar ->
            emitSimpleRead 2 "bf.read.u16" (Just endian) I64 placeholderVar state

        ReadI16 _ endian placeholderVar ->
            emitSimpleRead 2 "bf.read.i16" (Just endian) I64 placeholderVar state

        ReadU32 _ endian placeholderVar ->
            emitSimpleRead 4 "bf.read.u32" (Just endian) I64 placeholderVar state

        ReadI32 _ endian placeholderVar ->
            emitSimpleRead 4 "bf.read.i32" (Just endian) I64 placeholderVar state

        ReadF32 _ endian placeholderVar ->
            emitSimpleRead 4 "bf.read.f32" (Just endian) F64 placeholderVar state

        ReadF64 _ endian placeholderVar ->
            emitSimpleRead 8 "bf.read.f64" (Just endian) F64 placeholderVar state

        _ ->
            -- Unsupported op - return unit with unchanged cursor
            let
                ( unitVar, ctx1 ) =
                    Context.freshVar state.ctx

                ( ctx2, unitOp ) =
                    Ops.mlirOp ctx1 "eco.unit"
                        |> Ops.opBuilder.withResults [ ( unitVar, Types.ecoValue ) ]
                        |> Ops.opBuilder.build
            in
            { ops = [ unitOp ]
            , resultVar = unitVar
            , newCursor = state.cursor
            , ctx = ctx2
            }


{-| Emit item ops sequentially with cursor threading.
Fallback for complex patterns not handled by specific cases.
-}
emitItemOpsSequentially : List DecoderOp -> DecoderEmitState -> ItemDecoderResult
emitItemOpsSequentially ops state =
    case ops of
        [] ->
            -- Return unit with unchanged cursor
            let
                ( unitVar, ctx1 ) =
                    Context.freshVar state.ctx

                ( ctx2, unitOp ) =
                    Ops.mlirOp ctx1 "eco.unit"
                        |> Ops.opBuilder.withResults [ ( unitVar, Types.ecoValue ) ]
                        |> Ops.opBuilder.build
            in
            { ops = [ unitOp ]
            , resultVar = unitVar
            , newCursor = state.cursor
            , ctx = ctx2
            }

        [ singleOp ] ->
            -- Single op - dispatch to appropriate handler
            emitSingleReadOp singleOp state

        firstOp :: restOps ->
            -- Emit first op, then recurse with updated cursor
            let
                firstResult =
                    emitSingleReadOp firstOp state

                newState =
                    { state | ctx = firstResult.ctx, cursor = firstResult.newCursor }

                restResult =
                    emitItemOpsSequentially restOps newState
            in
            -- Return the last result var
            { ops = firstResult.ops ++ restResult.ops
            , resultVar = restResult.resultVar
            , newCursor = restResult.newCursor
            , ctx = restResult.ctx
            }


