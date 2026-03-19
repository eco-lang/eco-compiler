module Compiler.Generate.MLIR.Expr exposing
    ( ExprResult
    , generateExpr
    , coerceResultToType, boxArgsWithMlirTypes
    , createDummyValue
    , collectLetBoundNames, addPlaceholderMappings
    )

{-| Expression generation for the MLIR backend.

This module handles generation of MLIR code for all Elm expressions.


# Result Type

@docs ExprResult


# Expression Generation

@docs generateExpr


# Data Structure Generation


# Boxing and Coercion

@docs coerceResultToType, boxArgsWithMlirTypes


# Utilities

@docs createDummyValue


# Let-binding Helpers

@docs collectLetBoundNames, addPlaceholderMappings

-}

import Array exposing (Array)
import Bitwise
import Compiler.AST.DecisionTree.Test as Test
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Elm.Package as Pkg
import Compiler.Generate.MLIR.BytesFusion.Emit as BFEmit
import Compiler.Generate.MLIR.BytesFusion.Reify as BFReify
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Intrinsics as Intrinsics
import Compiler.Generate.MLIR.Names as Names
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Patterns as Patterns
import Compiler.Generate.MLIR.Types as Types
import Compiler.LocalOpt.Typed.DecisionTree as DT
import Compiler.Monomorphize.Closure as Closure
import Compiler.Monomorphize.Registry as Registry
import Data.Map as EveryDict
import Data.Set as EverySet
import Dict
import Hex
import List.Extra as ListX
import Mlir.Mlir exposing (MlirAttr(..), MlirBlock, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import Set
import System.TypeCheck.IO as IO
import Utils.Crash exposing (crash)



-- ====== EXPRESSION RESULT ======


{-| Result of generating MLIR code for an expression.
-}
type alias ExprResult =
    { ops : List MlirOp
    , resultVar : String
    , resultType : MlirType
    , ctx : Ctx.Context
    , isTerminated : Bool -- True if ops end with a terminator (eco.case, eco.jump)
    }


{-| Create an empty expression result with no ops.
-}
emptyResult : Ctx.Context -> String -> MlirType -> ExprResult
emptyResult ctx var ty =
    { ops = [], resultVar = var, resultType = ty, ctx = ctx, isTerminated = False }


{-| Rename an SSA variable in a list of MlirOps, recursing into nested regions.

Replaces all occurrences of `fromVar` with `toVar` in:

  - op.id (the result SSA name)
  - op.operands (input SSA names)
  - Nested regions, blocks, body ops and terminators (recursive)

Block arguments are NOT renamed because they define new SSA bindings in their
own scope, distinct from the enclosing let-binding scope.

This is used by generateLet to force the result SSA id to match a pre-installed
placeholder (e.g., "%helper") so that mutually recursive closures can safely
capture each other via currentLetSiblings.

-}
renameSsaVarInOps : String -> String -> List MlirOp -> List MlirOp
renameSsaVarInOps fromVar toVar ops =
    let
        renameVar : String -> String
        renameVar v =
            if v == fromVar then
                toVar

            else
                v

        renameOp : MlirOp -> MlirOp
        renameOp op =
            { op
                | id = renameVar op.id
                , operands = List.map renameVar op.operands
                , results = List.map (\( n, t ) -> ( renameVar n, t )) op.results
                , regions = List.map (renameSsaVarInRegion fromVar toVar) op.regions
            }
    in
    List.map renameOp ops


renameSsaVarInRegion : String -> String -> MlirRegion -> MlirRegion
renameSsaVarInRegion fromVar toVar (MlirRegion r) =
    MlirRegion
        { entry = renameSsaVarInBlock fromVar toVar r.entry
        , blocks = OrderedDict.map (\_ block -> renameSsaVarInBlock fromVar toVar block) r.blocks
        }


renameSsaVarInBlock : String -> String -> MlirBlock -> MlirBlock
renameSsaVarInBlock fromVar toVar block =
    { block
        | body = renameSsaVarInOps fromVar toVar block.body
        , terminator = renameSsaVarInSingleOp fromVar toVar block.terminator
    }


renameSsaVarInSingleOp : String -> String -> MlirOp -> MlirOp
renameSsaVarInSingleOp fromVar toVar op =
    let
        renameVar : String -> String
        renameVar v =
            if v == fromVar then
                toVar

            else
                v
    in
    { op
        | id = renameVar op.id
        , operands = List.map renameVar op.operands
        , results = List.map (\( n, t ) -> ( renameVar n, t )) op.results
        , regions = List.map (renameSsaVarInRegion fromVar toVar) op.regions
    }


{-| Force an ExprResult to use a specific SSA id as its resultVar.

If the expression's resultVar already matches `desiredVar`, this is a no-op.
Otherwise it renames all uses/defs of the old resultVar to `desiredVar` throughout
the ops (including nested regions), and updates resultVar accordingly.

Used by generateLet to ensure that let-bound names in a recursive group define
the same SSA var that closures captured via currentLetSiblings' placeholders.

-}
forceResultVar : String -> ExprResult -> ExprResult
forceResultVar desiredVar exprResult =
    if exprResult.resultVar == desiredVar then
        exprResult

    else
        let
            renamedOps =
                renameSsaVarInOps exprResult.resultVar desiredVar exprResult.ops
        in
        { exprResult
            | ops = renamedOps
            , resultVar = desiredVar
        }


isVarDefinedInOps : String -> List MlirOp -> Bool
isVarDefinedInOps var ops =
    List.any (\op -> List.any (\( name, _ ) -> name == var) op.results) ops


fixSelfCaptures : String -> String -> Ctx.Context -> ExprResult -> ( ExprResult, Ctx.Context )
fixSelfCaptures placeholderVar unitVar ctx result =
    let
        fixOp : MlirOp -> MlirOp
        fixOp op =
            if op.name == "eco.papCreate" && List.member placeholderVar op.operands then
                let
                    selfIndices =
                        List.indexedMap
                            (\i v ->
                                if v == placeholderVar then
                                    Just i

                                else
                                    Nothing
                            )
                            op.operands
                            |> List.filterMap identity

                    newOperands =
                        List.map
                            (\v ->
                                if v == placeholderVar then
                                    unitVar

                                else
                                    v
                            )
                            op.operands

                    selfCaptureAttr =
                        Dict.singleton "self_capture_indices"
                            (ArrayAttr (Just I64)
                                (List.map (\i -> IntAttr Nothing i) selfIndices)
                            )
                in
                { op
                    | operands = newOperands
                    , attrs = Dict.union selfCaptureAttr op.attrs
                }

            else
                op
    in
    ( { result | ops = List.map fixOp result.ops }, ctx )


hasSelfCapture : String -> List MlirOp -> Bool
hasSelfCapture placeholderVar ops =
    List.any
        (\op -> op.name == "eco.papCreate" && List.member placeholderVar op.operands)
        ops



-- ====== HELPER FUNCTIONS ======


specIdToFuncName : Mono.SpecializationRegistry -> Mono.SpecId -> String
specIdToFuncName registry specId =
    case Registry.lookupSpecKey specId registry of
        Just ( Mono.Global home name, _, _ ) ->
            Names.canonicalToMLIRName home ++ "_" ++ Names.sanitizeName name ++ "_$_" ++ String.fromInt specId

        Just ( Mono.Accessor fieldName, _, _ ) ->
            "accessor_" ++ Names.sanitizeName fieldName ++ "_$_" ++ String.fromInt specId

        Nothing ->
            "unknown_$_" ++ String.fromInt specId


{-| Create a dummy value of the given MLIR type. Used when a value of a
specific type is needed but the actual value is irrelevant (e.g., unreachable code paths).
-}
createDummyValue : Ctx.Context -> MlirType -> ( List MlirOp, String, Ctx.Context )
createDummyValue ctx mlirType =
    let
        ( resultVar, ctx1 ) =
            Ctx.freshVar ctx
    in
    case mlirType of
        I64 ->
            let
                ( ctx2, op ) =
                    Ops.arithConstantInt ctx1 resultVar 0
            in
            ( [ op ], resultVar, ctx2 )

        F64 ->
            let
                ( ctx2, op ) =
                    Ops.arithConstantFloat ctx1 resultVar 0.0
            in
            ( [ op ], resultVar, ctx2 )

        I1 ->
            let
                ( ctx2, op ) =
                    Ops.arithConstantBool ctx1 resultVar False
            in
            ( [ op ], resultVar, ctx2 )

        I16 ->
            let
                ( ctx2, op ) =
                    Ops.arithConstantChar ctx1 resultVar 0
            in
            ( [ op ], resultVar, ctx2 )

        _ ->
            -- For Types.ecoValue and other types, return Unit
            let
                ( ctx2, op ) =
                    Ops.ecoConstantUnit ctx1 resultVar
            in
            ( [ op ], resultVar, ctx2 )



-- ====== GENERATE EXPRESSION ======


{-| Generate MLIR code for a monomorphic expression.
-}
generateExpr : Ctx.Context -> Mono.MonoExpr -> ExprResult
generateExpr ctx expr =
    case expr of
        Mono.MonoLiteral lit _ ->
            generateLiteral ctx lit

        Mono.MonoVarLocal name _ ->
            let
                ( varName, varType ) =
                    Ctx.lookupVar ctx name
            in
            emptyResult ctx varName varType

        Mono.MonoVarGlobal _ specId monoType ->
            generateVarGlobal ctx specId monoType

        Mono.MonoVarKernel _ home name monoType ->
            generateVarKernel ctx home name monoType

        Mono.MonoList _ items listType ->
            generateList ctx items listType

        Mono.MonoClosure closureInfo body monoType ->
            generateClosure ctx closureInfo body monoType

        Mono.MonoCall _ func args resultType callInfo ->
            generateCall ctx func args resultType callInfo

        Mono.MonoTailCall name args _ ->
            generateTailCall ctx name args

        Mono.MonoIf branches final _ ->
            generateIf ctx branches final

        Mono.MonoLet def body _ ->
            case tryInlinedDecodeFusion ctx def body of
                Just result ->
                    result

                Nothing ->
                    generateLet ctx def body

        Mono.MonoDestruct destructor body destType ->
            generateDestruct ctx destructor body destType

        Mono.MonoCase scrutinee1 scrutinee2 decider jumps resultType ->
            generateCase ctx scrutinee1 scrutinee2 decider jumps resultType

        Mono.MonoRecordCreate namedFields monoType ->
            let
                layout =
                    Types.computeRecordLayout (getRecordFields monoType)

                -- Reorder fields according to layout order
                orderedExprs =
                    List.map
                        (\fieldInfo ->
                            ListX.find (\( n, _ ) -> n == fieldInfo.name) namedFields
                                |> Maybe.map Tuple.second
                                |> Maybe.withDefault Mono.MonoUnit
                        )
                        layout.fields
            in
            generateRecordCreate ctx orderedExprs layout monoType

        Mono.MonoRecordAccess record fieldName fieldType ->
            let
                recordType =
                    Mono.typeOf record

                layout =
                    Types.computeRecordLayout (getRecordFields recordType)

                fieldInfo =
                    ListX.find (\fi -> fi.name == fieldName) layout.fields
                        |> Maybe.withDefault { name = fieldName, index = 0, monoType = fieldType, isUnboxed = False }
            in
            generateRecordAccess ctx record fieldName fieldInfo.index fieldInfo.isUnboxed fieldType

        Mono.MonoRecordUpdate record namedUpdates monoType ->
            let
                layout =
                    Types.computeRecordLayout (getRecordFields monoType)

                -- Convert named updates to indexed updates
                indexedUpdates =
                    List.filterMap
                        (\( name, updateExpr ) ->
                            ListX.find (\fi -> fi.name == name) layout.fields
                                |> Maybe.map (\fi -> ( fi.index, updateExpr ))
                        )
                        namedUpdates
            in
            generateRecordUpdate ctx record indexedUpdates layout monoType

        Mono.MonoTupleCreate _ elements monoType ->
            let
                layout =
                    Types.computeTupleLayout (getTupleElements monoType)
            in
            generateTupleCreate ctx elements layout monoType

        Mono.MonoUnit ->
            generateUnit ctx



-- ====== LITERAL GENERATION ======


generateLiteral : Ctx.Context -> Mono.Literal -> ExprResult
generateLiteral ctx lit =
    case lit of
        Mono.LBool value ->
            let
                ( var, ctx1 ) =
                    Ctx.freshVar ctx

                ( ctx2, op ) =
                    Ops.arithConstantBool ctx1 var value
            in
            { ops = [ op ]
            , resultVar = var
            , resultType = Types.monoTypeToOperand Mono.MBool
            , ctx = ctx2
            , isTerminated = False
            }

        Mono.LInt value ->
            let
                ( var, ctx1 ) =
                    Ctx.freshVar ctx

                ( ctx2, op ) =
                    Ops.arithConstantInt ctx1 var value
            in
            { ops = [ op ]
            , resultVar = var
            , resultType = Types.ecoInt
            , ctx = ctx2
            , isTerminated = False
            }

        Mono.LFloat value ->
            let
                ( var, ctx1 ) =
                    Ctx.freshVar ctx

                ( ctx2, op ) =
                    Ops.arithConstantFloat ctx1 var value
            in
            { ops = [ op ]
            , resultVar = var
            , resultType = Types.ecoFloat
            , ctx = ctx2
            , isTerminated = False
            }

        Mono.LChar value ->
            let
                ( var, ctx1 ) =
                    Ctx.freshVar ctx

                codepoint : Int
                codepoint =
                    decodeCharLiteral value

                ( ctx2, op ) =
                    Ops.arithConstantChar ctx1 var codepoint
            in
            { ops = [ op ]
            , resultVar = var
            , resultType = Types.ecoChar
            , ctx = ctx2
            , isTerminated = False
            }

        Mono.LStr value ->
            let
                ( var, ctx1 ) =
                    Ctx.freshVar ctx

                -- Empty strings must use eco.constant EmptyString (invariant: never heap-allocated)
                ( ctx2, op ) =
                    if value == "" then
                        Ops.ecoConstantEmptyString ctx1 var

                    else
                        Ops.ecoStringLiteral ctx1 var value
            in
            { ops = [ op ]
            , resultVar = var
            , resultType = Types.ecoValue
            , ctx = ctx2
            , isTerminated = False
            }



-- ====== VARIABLE GENERATION ======


generateVarGlobal : Ctx.Context -> Mono.SpecId -> Mono.MonoType -> ExprResult
generateVarGlobal ctx specId monoType =
    let
        ( var, ctx1 ) =
            Ctx.freshVar ctx

        funcName : String
        funcName =
            specIdToFuncName ctx.registry specId

        -- Use the signature table to determine arity, not just monoType.
        -- This is more reliable because monoType might be a type variable (MVar)
        -- even though the underlying function has parameters.
        maybeSig : Maybe Ctx.FuncSignature
        maybeSig =
            Dict.get specId ctx.signatures
    in
    case maybeSig of
        Just sig ->
            let
                arity : Int
                arity =
                    List.length sig.paramTypes
            in
            if arity == 0 then
                -- Zero-arity function (thunk): call directly instead of creating a PAP.
                -- papCreate requires arity > 0 (num_captured < arity invariant).
                let
                    resultMlirType =
                        Types.monoTypeToAbi sig.returnType

                    ( ctx2, callOp ) =
                        Ops.ecoCallNamed ctx1 var funcName [] resultMlirType
                in
                { ops = [ callOp ]
                , resultVar = var
                , resultType = resultMlirType
                , ctx = ctx2
                , isTerminated = False
                }

            else
                -- Function-typed global with arity > 0: create a closure (papCreate) with no captures
                -- With typed closure ABI, we use the actual function name directly (no wrapper needed)
                let
                    attrs =
                        Dict.fromList
                            [ ( "function", SymbolRefAttr funcName )
                            , ( "arity", IntAttr Nothing arity )
                            , ( "num_captured", IntAttr Nothing 0 )
                            , ( "unboxed_bitmap", IntAttr Nothing 0 ) -- No captures, so bitmap is 0
                            ]

                    ( ctx2, papOp ) =
                        Ops.mlirOp ctx1 "eco.papCreate"
                            |> Ops.opBuilder.withResults [ ( var, Types.ecoValue ) ]
                            |> Ops.opBuilder.withAttrs attrs
                            |> Ops.opBuilder.build
                in
                { ops = [ papOp ]
                , resultVar = var
                , resultType = Types.ecoValue
                , ctx = ctx2
                , isTerminated = False
                }

        Nothing ->
            -- No signature found - fall back to monoType-based logic
            -- This should only happen for constants, not functions.
            case monoType of
                Mono.MFunction _ _ ->
                    Utils.Crash.crash
                        ("generateVarGlobal: missing FuncSignature for function-typed global "
                            ++ specIdToFuncName ctx.registry specId
                        )

                _ ->
                    -- Non-function type: call the function directly (e.g., zero-arg constructors)
                    let
                        resultMlirType =
                            Types.monoTypeToAbi monoType

                        ( ctx2, callOp ) =
                            Ops.ecoCallNamed ctx1 var funcName [] resultMlirType
                    in
                    { ops = [ callOp ]
                    , resultVar = var
                    , resultType = resultMlirType
                    , ctx = ctx2
                    , isTerminated = False
                    }


generateVarKernel : Ctx.Context -> Name.Name -> Name.Name -> Mono.MonoType -> ExprResult
generateVarKernel ctx home name monoType =
    let
        ( var, ctx1 ) =
            Ctx.freshVar ctx

        kernelName : String
        kernelName =
            "Elm_Kernel_" ++ home ++ "_" ++ name
    in
    -- Check for intrinsic constants (pi, e)
    case Intrinsics.kernelIntrinsic home name [] monoType of
        Just (Intrinsics.ConstantFloat { value }) ->
            let
                ( ctx2, floatOp ) =
                    Ops.arithConstantFloat ctx1 var value
            in
            { ops = [ floatOp ]
            , resultVar = var
            , resultType = Types.ecoFloat
            , ctx = ctx2
            , isTerminated = False
            }

        Just _ ->
            -- Other intrinsic matched with zero args - but check if it's function-typed
            case monoType of
                Mono.MFunction _ _ ->
                    -- Kernels use total ABI arity (flattened), not stage arity
                    let
                        arity : Int
                        arity =
                            Types.countTotalArity monoType
                    in
                    if arity == 0 then
                        -- Zero-arity function (thunk): call directly
                        let
                            resultMlirType =
                                Types.monoTypeToAbi monoType

                            ( ctx2, callOp ) =
                                Ops.ecoCallNamed ctx1 var kernelName [] resultMlirType
                        in
                        { ops = [ callOp ]
                        , resultVar = var
                        , resultType = resultMlirType
                        , ctx = ctx2
                        , isTerminated = False
                        }

                    else
                        -- Function-typed kernel with arity > 0: create a closure (papCreate)
                        -- Register kernel call so func.func declaration is emitted,
                        -- enabling the closure wrapper to know parameter types.
                        let
                            ( paramTypes, resultType ) =
                                Types.flattenFunctionType monoType

                            ctxWithKernel =
                                Ctx.registerKernelCall ctx1 kernelName paramTypes resultType

                            attrs =
                                Dict.fromList
                                    [ ( "function", SymbolRefAttr kernelName )
                                    , ( "arity", IntAttr Nothing arity )
                                    , ( "num_captured", IntAttr Nothing 0 )
                                    ]

                            ( ctx2, papOp ) =
                                Ops.mlirOp ctxWithKernel "eco.papCreate"
                                    |> Ops.opBuilder.withResults [ ( var, Types.ecoValue ) ]
                                    |> Ops.opBuilder.withAttrs attrs
                                    |> Ops.opBuilder.build
                        in
                        { ops = [ papOp ]
                        , resultVar = var
                        , resultType = Types.ecoValue
                        , ctx = ctx2
                        , isTerminated = False
                        }

                _ ->
                    -- Non-function type: call directly
                    let
                        resultMlirType =
                            Types.monoTypeToAbi monoType

                        ( ctx2, callOp ) =
                            Ops.ecoCallNamed ctx1 var kernelName [] resultMlirType
                    in
                    { ops = [ callOp ]
                    , resultVar = var
                    , resultType = resultMlirType
                    , ctx = ctx2
                    , isTerminated = False
                    }

        Nothing ->
            -- No intrinsic match - check if this is a function type
            case monoType of
                Mono.MFunction _ _ ->
                    -- Kernels use total ABI arity (flattened), not stage arity
                    let
                        arity : Int
                        arity =
                            Types.countTotalArity monoType
                    in
                    if arity == 0 then
                        -- Zero-arity function (thunk): call directly
                        let
                            resultMlirType =
                                Types.monoTypeToAbi monoType

                            ( ctx2, callOp ) =
                                Ops.ecoCallNamed ctx1 var kernelName [] resultMlirType
                        in
                        { ops = [ callOp ]
                        , resultVar = var
                        , resultType = resultMlirType
                        , ctx = ctx2
                        , isTerminated = False
                        }

                    else
                        -- Function-typed kernel with arity > 0: create a closure (papCreate)
                        -- Register kernel call so func.func declaration is emitted,
                        -- enabling the closure wrapper to know parameter types.
                        let
                            ( paramTypes, resultType ) =
                                Types.flattenFunctionType monoType

                            ctxWithKernel =
                                Ctx.registerKernelCall ctx1 kernelName paramTypes resultType

                            attrs =
                                Dict.fromList
                                    [ ( "function", SymbolRefAttr kernelName )
                                    , ( "arity", IntAttr Nothing arity )
                                    , ( "num_captured", IntAttr Nothing 0 )
                                    ]

                            ( ctx2, papOp ) =
                                Ops.mlirOp ctxWithKernel "eco.papCreate"
                                    |> Ops.opBuilder.withResults [ ( var, Types.ecoValue ) ]
                                    |> Ops.opBuilder.withAttrs attrs
                                    |> Ops.opBuilder.build
                        in
                        { ops = [ papOp ]
                        , resultVar = var
                        , resultType = Types.ecoValue
                        , ctx = ctx2
                        , isTerminated = False
                        }

                _ ->
                    -- Non-function type: call the kernel directly
                    let
                        resultMlirType =
                            Types.monoTypeToAbi monoType

                        ( ctx2, callOp ) =
                            Ops.ecoCallNamed ctx1 var kernelName [] resultMlirType
                    in
                    { ops = [ callOp ]
                    , resultVar = var
                    , resultType = resultMlirType
                    , ctx = ctx2
                    , isTerminated = False
                    }



-- ====== LIST GENERATION ======


{-| Generate MLIR code for a list literal.
-}
generateList : Ctx.Context -> List Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateList ctx items listType =
    -- Register the list type for the type graph
    let
        ( _, ctxWithType ) =
            Ctx.getOrCreateTypeIdForMonoType listType ctx
    in
    case items of
        [] ->
            -- Empty list: use eco.constant Nil (embedded constant, not heap-allocated)
            let
                ( var, ctx1 ) =
                    Ctx.freshVar ctxWithType

                ( ctx2, nilOp ) =
                    Ops.ecoConstantNil ctx1 var
            in
            { ops = [ nilOp ]
            , resultVar = var
            , resultType = Types.ecoValue
            , ctx = ctx2
            , isTerminated = False
            }

        _ ->
            -- Non-empty list: use eco.constant Nil for tail, eco.construct.list for cons cells.
            -- Now that MonoPath carries ContainerKind, projection ops (eco.project.list_head/tail)
            -- match the Cons layout created by eco.construct.list.
            let
                ( nilVar, ctx1 ) =
                    Ctx.freshVar ctxWithType

                ( ctx2, nilOp ) =
                    Ops.ecoConstantNil ctx1 nilVar

                ( consOpsReversed, finalVar, finalCtx ) =
                    List.foldr
                        (\item ( accOps, tailVar, accCtx ) ->
                            let
                                result : ExprResult
                                result =
                                    generateExpr accCtx item

                                -- Check if element can be stored unboxed based on ACTUAL SSA type
                                -- (not MonoType, which may not match SSA type in all cases)
                                headUnboxed : Bool
                                headUnboxed =
                                    Types.isUnboxable result.resultType
                            in
                            if headUnboxed then
                                -- Store element unboxed directly (no boxing needed)
                                let
                                    ( consVar, ctx3 ) =
                                        Ctx.freshVar result.ctx

                                    ( ctx4, consOp ) =
                                        Ops.ecoConstructList ctx3 consVar ( result.resultVar, result.resultType ) ( tailVar, Types.ecoValue ) True
                                in
                                ( consOp :: List.reverse result.ops ++ accOps, consVar, ctx4 )

                            else
                                -- Box element before storing in the list
                                let
                                    ( boxOps, boxedVar, ctx3 ) =
                                        boxToEcoValue result.ctx result.resultVar result.resultType

                                    ( consVar, ctx4 ) =
                                        Ctx.freshVar ctx3

                                    ( ctx5, consOp ) =
                                        Ops.ecoConstructList ctx4 consVar ( boxedVar, Types.ecoValue ) ( tailVar, Types.ecoValue ) False
                                in
                                ( consOp :: List.reverse boxOps ++ List.reverse result.ops ++ accOps, consVar, ctx5 )
                        )
                        ( [], nilVar, ctx2 )
                        items
            in
            { ops = nilOp :: List.reverse consOpsReversed
            , resultVar = finalVar
            , resultType = Types.ecoValue
            , ctx = finalCtx
            , isTerminated = False
            }



-- ====== CLOSURE GENERATION ======


{-| Generate MLIR code for a closure.
-}
generateClosure : Ctx.Context -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateClosure ctx closureInfo body monoType =
    let
        -- Generate expressions and track ACTUAL SSA types, not Mono types
        ( captureOpsReversed, captureVarsWithTypesReversed, ctx1 ) =
            List.foldl
                (\( _, expr, _ ) ( accOps, accVars, accCtx ) ->
                    let
                        result : ExprResult
                        result =
                            generateExpr accCtx expr
                    in
                    ( List.reverse result.ops ++ accOps
                    , ( result.resultVar, result.resultType ) :: accVars
                    , result.ctx
                    )
                )
                ( [], [], ctx )
                closureInfo.captures

        captureOps =
            List.reverse captureOpsReversed

        captureVarsWithTypes =
            List.reverse captureVarsWithTypesReversed

        -- Box Bool (i1) captures at closure boundary per REP_CLOSURE_001 / FORBID_CLOSURE_001
        ( boxOps, boxedCaptureVarsWithTypes, ctx1a ) =
            boxArgsForClosureBoundary False ctx1 captureVarsWithTypes

        captureVarNames : List String
        captureVarNames =
            List.map Tuple.first boxedCaptureVarsWithTypes

        captureTypesList : List MlirType
        captureTypesList =
            List.map Tuple.second boxedCaptureVarsWithTypes

        ( resultVar, ctx2 ) =
            Ctx.freshVar ctx1a

        numCaptured : Int
        numCaptured =
            List.length closureInfo.captures

        arity : Int
        arity =
            numCaptured + List.length closureInfo.params

        captureTypes : List ( Name.Name, Mono.MonoType )
        captureTypes =
            List.map (\( name, expr, _ ) -> ( name, Mono.typeOf expr )) closureInfo.captures

        -- Compute unboxed_bitmap from capture types
        -- Only i64 and f64 are unboxable; all other types are boxed (!eco.value)
        unboxedBitmap : Int
        unboxedBitmap =
            List.indexedMap
                (\i ( _, mlirTy ) ->
                    if Types.isUnboxable mlirTy then
                        Bitwise.shiftLeftBy i 1

                    else
                        0
                )
                boxedCaptureVarsWithTypes
                |> List.foldl Bitwise.or 0

        -- Use currentLetSiblings only for mutually recursive let bindings.
        -- Do NOT fall back to varMappings; non-recursive closures must capture
        -- all free variables explicitly (CGEN_CLOSURE_003).
        baseSiblings : Dict.Dict String Ctx.VarInfo
        baseSiblings =
            ctx.currentLetSiblings

        pendingLambda : Ctx.PendingLambda
        pendingLambda =
            { name = lambdaIdToString closureInfo.lambdaId
            , captures = captureTypes
            , params = closureInfo.params
            , body = body
            , returnType = Mono.typeOf body
            , siblingMappings = baseSiblings
            , isTailRecursive = False
            }
    in
    if arity == 0 then
        -- Zero-arity closure (thunk with no captures): call the lambda directly.
        -- papCreate requires arity > 0 (num_captured < arity invariant).
        let
            ctx3 : Ctx.Context
            ctx3 =
                { ctx2 | pendingLambdas = pendingLambda :: ctx2.pendingLambdas }

            closureResultType =
                Types.monoTypeToAbi monoType

            ( ctx4, callOp ) =
                Ops.ecoCallNamed ctx3 resultVar (lambdaIdToString closureInfo.lambdaId) [] closureResultType
        in
        { ops = captureOps ++ boxOps ++ [ callOp ]
        , resultVar = resultVar
        , resultType = closureResultType
        , ctx = ctx4
        , isTerminated = False
        }

    else
        -- Non-zero arity: create a PAP with captures (typed closure ABI)
        let
            hasCaptures =
                not (List.isEmpty closureInfo.captures)

            baseFuncName =
                lambdaIdToString closureInfo.lambdaId

            -- For closures with captures, reference generic clone; otherwise original
            functionName =
                if hasCaptures then
                    baseFuncName ++ "$clo"

                else
                    baseFuncName

            operandTypesAttr =
                if List.isEmpty captureVarNames then
                    Dict.empty

                else
                    -- Use actual capture types (not all !eco.value)
                    Dict.singleton "_operand_types"
                        (ArrayAttr Nothing (List.map TypeAttr captureTypesList))

            -- Add _fast_evaluator attribute for closures with captures
            fastEvaluatorAttr =
                if hasCaptures then
                    Dict.singleton "_fast_evaluator" (SymbolRefAttr (baseFuncName ++ "$cap"))

                else
                    Dict.empty

            -- Add _closure_kind attribute if available
            closureKindAttr =
                case closureInfo.closureKind of
                    Just (Mono.Known (Mono.ClosureKindId kindId)) ->
                        Dict.singleton "_closure_kind" (IntAttr Nothing kindId)

                    Nothing ->
                        Dict.empty

            papAttrs =
                Dict.union closureKindAttr
                    (Dict.union fastEvaluatorAttr
                        (Dict.union operandTypesAttr
                            (Dict.fromList
                                [ ( "function", SymbolRefAttr functionName )
                                , ( "arity", IntAttr Nothing arity )
                                , ( "num_captured", IntAttr Nothing numCaptured )
                                , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                                ]
                            )
                        )
                    )

            ( ctx3, papOp ) =
                Ops.mlirOp ctx2 "eco.papCreate"
                    |> Ops.opBuilder.withOperands captureVarNames
                    |> Ops.opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
                    |> Ops.opBuilder.withAttrs papAttrs
                    |> Ops.opBuilder.build

            ctx4 : Ctx.Context
            ctx4 =
                { ctx3 | pendingLambdas = pendingLambda :: ctx3.pendingLambdas }
        in
        { ops = captureOps ++ boxOps ++ [ papOp ]
        , resultVar = resultVar
        , resultType = Types.ecoValue
        , ctx = ctx4
        , isTerminated = False
        }


lambdaIdToString : Mono.LambdaId -> String
lambdaIdToString lambdaId =
    case lambdaId of
        Mono.AnonymousLambda home uid ->
            Names.canonicalToMLIRName home ++ "_lambda_" ++ String.fromInt uid



-- ====== CALL GENERATION ======


{-| Box a value to !eco.value given its MlirType.
If already !eco.value, returns unchanged.
-}
boxToEcoValue : Ctx.Context -> String -> MlirType -> ( List MlirOp, String, Ctx.Context )
boxToEcoValue ctx var mlirTy =
    if Types.isEcoValueType mlirTy then
        ( [], var, ctx )

    else
        let
            ( boxedVar, ctx1 ) =
                Ctx.freshVar ctx

            attrs =
                Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr mlirTy ])

            ( ctx2, boxOp ) =
                Ops.mlirOp ctx1 "eco.box"
                    |> Ops.opBuilder.withOperands [ var ]
                    |> Ops.opBuilder.withResults [ ( boxedVar, Types.ecoValue ) ]
                    |> Ops.opBuilder.withAttrs attrs
                    |> Ops.opBuilder.build
        in
        ( [ boxOp ], boxedVar, ctx2 )


{-| Box or unbox arguments (based on ACTUAL SSA types) to match the
function's expected Mono types.
-}
boxToMatchSignatureTyped :
    Ctx.Context
    -> List ( String, MlirType )
    -> List Mono.MonoType
    -> ( List MlirOp, List ( String, MlirType ), Ctx.Context )
boxToMatchSignatureTyped ctx actualArgs expectedTypes =
    let
        helper :
            ( ( String, MlirType ), Mono.MonoType )
            -> ( List MlirOp, List ( String, MlirType ), Ctx.Context )
            -> ( List MlirOp, List ( String, MlirType ), Ctx.Context )
        helper ( ( var, actualTy ), expectedTy ) ( opsAcc, pairsAcc, ctxAcc ) =
            let
                expectedMlirTy =
                    Types.monoTypeToAbi expectedTy
            in
            if expectedMlirTy == actualTy then
                ( opsAcc, ( var, actualTy ) :: pairsAcc, ctxAcc )

            else if Types.isEcoValueType expectedMlirTy && not (Types.isEcoValueType actualTy) then
                -- Function expects boxed, we have primitive -> box using actual SSA type
                let
                    ( boxOps, boxedVar, ctx1 ) =
                        boxToEcoValue ctxAcc var actualTy
                in
                ( List.reverse boxOps ++ opsAcc
                , ( boxedVar, Types.ecoValue ) :: pairsAcc
                , ctx1
                )

            else if not (Types.isEcoValueType expectedMlirTy) && Types.isEcoValueType actualTy then
                -- Function expects primitive, we have boxed -> unbox to expected primitive type
                let
                    ( unboxOps, unboxedVar, ctx1 ) =
                        Intrinsics.unboxToType ctxAcc var expectedMlirTy
                in
                ( List.reverse unboxOps ++ opsAcc
                , ( unboxedVar, expectedMlirTy ) :: pairsAcc
                , ctx1
                )

            else
                -- No boxing solution (e.g. i64 vs f64) - use actual type for now
                ( opsAcc, ( var, actualTy ) :: pairsAcc, ctxAcc )

        ( opsReversed, pairsReversed, ctxFinal ) =
            List.foldl helper ( [], [], ctx ) (List.map2 Tuple.pair actualArgs expectedTypes)
    in
    ( List.reverse opsReversed, List.reverse pairsReversed, ctxFinal )


{-| Coerce an expression result to a desired MLIR type by inserting
boxing/unboxing ops when the difference is only boxed vs unboxed.
Handles both directions:

  - primitive -> !eco.value (box)
  - !eco.value -> primitive (unbox)

-}
coerceResultToType : Ctx.Context -> String -> MlirType -> MlirType -> ( List MlirOp, String, Ctx.Context )
coerceResultToType ctx var actualTy expectedTy =
    if actualTy == expectedTy then
        -- No coercion needed
        ( [], var, ctx )

    else if Types.isEcoValueType expectedTy && not (Types.isEcoValueType actualTy) then
        -- Need primitive -> boxed
        boxToEcoValue ctx var actualTy

    else if not (Types.isEcoValueType expectedTy) && Types.isEcoValueType actualTy then
        -- Need boxed -> primitive
        Intrinsics.unboxToType ctx var expectedTy

    else
        -- Types don't match and no boxing/unboxing solution
        -- This indicates a monomorphization bug - primitive type mismatches
        -- (e.g., i64 vs f64) should have been resolved upstream
        crash <|
            "coerceResultToType: cannot coerce "
                ++ Types.mlirTypeToString actualTy
                ++ " to "
                ++ Types.mlirTypeToString expectedTy
                ++ " for variable "
                ++ var


{-| Generate MLIR code for a function call.
Uses precomputed CallInfo from GlobalOpt instead of re-deriving staging.
-}
generateCall : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> Mono.CallInfo -> ExprResult
generateCall ctx func args resultType callInfo =
    case callInfo.callKind of
        Mono.CallGenericApply ->
            -- Generic apply: staging unknown at compile time.
            -- Emit eco.papExtend without remaining_arity; EcoToLLVM will
            -- read the closure header at runtime to determine saturation.
            generateGenericApply ctx func args resultType callInfo

        Mono.CallDirectFlat ->
            -- Kernels / externs: use ABI-flattened model.
            if Types.isFunctionType resultType then
                generateClosureApplication ctx func args resultType callInfo

            else
                generateSaturatedCall ctx func args resultType callInfo

        Mono.CallDirectKnownSegmentation ->
            if callInfo.isSingleStageSaturated then
                -- Single-stage saturated call: use saturated path (has intrinsic logic)
                generateSaturatedCall ctx func args resultType callInfo

            else
                -- Multi-stage call or partial application: use closure path
                generateClosureApplication ctx func args resultType callInfo


{-| Generate a generic apply call: eco.papExtend without remaining_arity.

Saturation is determined at runtime from the closure header. The result
type is always !eco.value since the outcome (PAP vs saturated result)
is unknown at compile time.

All arguments are boxed to !eco.value for the runtime helpers, since
eco\_apply\_closure passes args through buildEvaluatorArgs which expects
HPointer-encoded values.

-}
generateGenericApply : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> Mono.CallInfo -> ExprResult
generateGenericApply ctx func args _ _ =
    let
        funcResult : ExprResult
        funcResult =
            generateExpr ctx func

        -- Generate all argument expressions
        ( argOps, argsWithTypes, ctx1 ) =
            generateExprListTyped funcResult.ctx args

        -- Box ALL primitive args to !eco.value for generic apply.
        -- The runtime helper eco_apply_closure treats all args as HPointer-encoded.
        ( boxOps, boxedArgsWithTypes, ctx2 ) =
            boxArgsForClosureBoundary True ctx1 argsWithTypes

        -- Build operand list: closure + all args
        allOperandNames =
            funcResult.resultVar :: List.map Tuple.first boxedArgsWithTypes

        allOperandTypes =
            funcResult.resultType :: List.map Tuple.second boxedArgsWithTypes

        -- Compute bitmap: after boxing all primitives, everything should be !eco.value
        -- so bitmap is 0. But compute it properly from the boxed types for correctness.
        newargsUnboxedBitmap =
            List.indexedMap
                (\i ( _, mlirTy ) ->
                    if Types.isUnboxable mlirTy then
                        Bitwise.shiftLeftBy i 1

                    else
                        0
                )
                boxedArgsWithTypes
                |> List.foldl Bitwise.or 0

        ( resVar, ctx3 ) =
            Ctx.freshVar ctx2

        -- Result type is always !eco.value for generic apply
        resultMlirType =
            Types.ecoValue

        -- Build eco.papExtend WITHOUT remaining_arity (generic mode)
        papExtendAttrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr allOperandTypes) )
                , ( "newargs_unboxed_bitmap", IntAttr Nothing newargsUnboxedBitmap )
                ]

        ( ctx4, papExtendOp ) =
            Ops.mlirOp ctx3 "eco.papExtend"
                |> Ops.opBuilder.withOperands allOperandNames
                |> Ops.opBuilder.withResults [ ( resVar, resultMlirType ) ]
                |> Ops.opBuilder.withAttrs papExtendAttrs
                |> Ops.opBuilder.build
    in
    { ops = funcResult.ops ++ argOps ++ boxOps ++ [ papExtendOp ]
    , resultVar = resVar
    , resultType = resultMlirType
    , ctx = ctx4
    , isTerminated = False
    }


{-| Result of applying arguments by stages.
-}
type alias ApplyByStagesResult =
    { ops : List MlirOp
    , resultVar : String
    , resultType : MlirType
    , ctx : Ctx.Context
    }


{-| Apply arguments to a closure by stages, emitting a chain of papExtend operations.

This is now metadata-driven: it uses `sourceRemaining` (numeric arity from GlobalOpt)
instead of calling staging helpers on MonoTypes directly.

Each papExtend consumes up to `sourceRemaining` arguments. When the stage is fully
applied and returns another closure, `remainingStageArities` provides the sequence
of subsequent stage arities.

This implements the stage-curried closure model required by MONO\_016 and CGEN\_052.

For partial applications, result type is `!eco.value` per CGEN\_034 (PAPs are boxed closures).
For fully saturated calls, result type is `saturatedReturnType` (the actual ABI return type).
CGEN\_056: `saturatedReturnType` must equal the callee's `func.func` result type, which is
guaranteed because both are derived via `Types.monoTypeToAbi` from the same Mono return type.

-}
applyByStages :
    Ctx.Context
    -> String -- funcVar: the closure variable
    -> MlirType -- funcMlirType: the closure's MLIR type (always !eco.value)
    -> Int -- sourceRemaining: the source PAP's remaining arity (CGEN_052)
    -> List Int -- remainingStageArities: arities of subsequent stages after saturation
    -> MlirType -- saturatedReturnType: callee's ABI return type (CGEN_056: must equal func.func result type)
    -> List ( String, MlirType ) -- args: remaining (var, mlirType) pairs to apply
    -> List MlirOp -- accumulated ops (in reverse order)
    -> ApplyByStagesResult
applyByStages ctx funcVar funcMlirType sourceRemaining remainingStageArities saturatedReturnType args accOps =
    case args of
        [] ->
            -- Base case: no more args to apply
            { ops = List.reverse accOps, resultVar = funcVar, resultType = funcMlirType, ctx = ctx }

        _ ->
            if sourceRemaining <= 0 then
                -- Defensive: zero-arity stage shouldn't happen with remaining args
                -- (zero-arity functions use direct calls, not PAPs)
                -- Return current value (treat as fully applied)
                { ops = List.reverse accOps, resultVar = funcVar, resultType = funcMlirType, ctx = ctx }

            else
                let
                    -- Take at most sourceRemaining args in this batch
                    batchSize =
                        min sourceRemaining (List.length args)

                    batch =
                        List.take batchSize args

                    rest =
                        List.drop batchSize args

                    -- Compute bitmap for this batch only
                    newargsUnboxedBitmap =
                        List.indexedMap
                            (\i ( _, mlirTy ) ->
                                if Types.isUnboxable mlirTy then
                                    Bitwise.shiftLeftBy i 1

                                else
                                    0
                            )
                            batch
                            |> List.foldl Bitwise.or 0

                    ( resVar, ctx1 ) =
                        Ctx.freshVar ctx

                    allOperandNames =
                        funcVar :: List.map Tuple.first batch

                    allOperandTypes =
                        funcMlirType :: List.map Tuple.second batch

                    -- CGEN_052: remaining_arity is the SOURCE PAP's remaining, not the result's
                    remainingArity =
                        sourceRemaining

                    -- The result's remaining for the next iteration.
                    -- When a stage is fully applied but returns another function,
                    -- the result is a NEW closure, so reset to the next stage's arity.
                    rawResultRemaining =
                        sourceRemaining - batchSize

                    ( resultRemaining, nextStageArities ) =
                        if rawResultRemaining <= 0 then
                            -- Stage fully applied - result is a new closure
                            -- Use next arity from remainingStageArities if available
                            case remainingStageArities of
                                nextArity :: restArities ->
                                    ( nextArity, restArities )

                                [] ->
                                    -- No more stages - result is the final value
                                    ( 0, [] )

                        else
                            -- Still within current stage
                            ( rawResultRemaining, remainingStageArities )

                    -- Result type depends on whether this is a fully saturated call or partial application.
                    -- For FULLY saturated calls (no more stages, no more args), use the actual return type.
                    -- For partial applications OR multi-stage calls that return closures, use !eco.value.
                    -- Key insight: if there are remaining stage arities, the result is still a closure.
                    isSaturatedCall =
                        rawResultRemaining <= 0 && List.isEmpty rest && List.isEmpty remainingStageArities

                    resultMlirType =
                        if isSaturatedCall then
                            saturatedReturnType

                        else
                            funcMlirType

                    papExtendAttrs =
                        Dict.fromList
                            [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr allOperandTypes) )
                            , ( "remaining_arity", IntAttr Nothing remainingArity )
                            , ( "newargs_unboxed_bitmap", IntAttr Nothing newargsUnboxedBitmap )
                            ]

                    ( ctx2, papExtendOp ) =
                        Ops.mlirOp ctx1 "eco.papExtend"
                            |> Ops.opBuilder.withOperands allOperandNames
                            |> Ops.opBuilder.withResults [ ( resVar, resultMlirType ) ]
                            |> Ops.opBuilder.withAttrs papExtendAttrs
                            |> Ops.opBuilder.build

                    nextOps =
                        papExtendOp :: accOps
                in
                if List.isEmpty rest then
                    -- No more args to apply after this batch.
                    { ops = List.reverse nextOps, resultVar = resVar, resultType = resultMlirType, ctx = ctx2 }

                else
                    -- More args to apply in later batches.
                    applyByStages ctx2 resVar resultMlirType resultRemaining nextStageArities saturatedReturnType rest nextOps


{-| Partial-apply a flattened external function (MonoExtern or kernel).

Uses total ABI arity for remaining\_arity, not stage arity.

-}
generateFlattenedPartialApplication :
    Ctx.Context
    -> Mono.MonoExpr -- func (MonoVarGlobal to MonoExtern, or MonoVarKernel)
    -> List Mono.MonoExpr -- args
    -> Mono.MonoType -- resultType (post-application)
    -> ExprResult
generateFlattenedPartialApplication ctx func args resultType =
    let
        -- 1. Generate the function value (creates PAP with total arity)
        funcResult : ExprResult
        funcResult =
            generateExpr ctx func

        -- 2. Generate argument expressions
        ( argOps, argsWithTypes, ctx1 ) =
            generateExprListTyped funcResult.ctx args

        -- 3. Get total ABI arity and evaluator boxing mode from signature
        ( totalArity, evaluatorBoxesAll ) =
            case func of
                Mono.MonoVarGlobal _ specId _ ->
                    case Dict.get specId ctx.signatures of
                        Just sig ->
                            ( List.length sig.paramTypes
                            , hasAllBoxedEvaluatorParams sig
                            )

                        Nothing ->
                            ( Types.countTotalArity (Mono.typeOf func), False )

                Mono.MonoVarKernel _ _ _ kernelType ->
                    let
                        sig =
                            Ctx.kernelFuncSignatureFromType kernelType
                    in
                    ( List.length sig.paramTypes, hasAllBoxedEvaluatorParams sig )

                Mono.MonoVarLocal name _ ->
                    ( Types.countTotalArity (Mono.typeOf func)
                    , Set.member name ctx.externBoxedVars
                    )

                _ ->
                    ( Types.countTotalArity (Mono.typeOf func), False )

        -- 4. Box args for closure boundary
        -- Extern/kernel evaluator wrappers always have !eco.value params, so box all primitives.
        -- User-defined closures: only box Bool (i1) per REP_CLOSURE_001.
        ( boxOps, boxedArgsWithTypes, ctx1b ) =
            boxArgsForClosureBoundary evaluatorBoxesAll ctx1 argsWithTypes

        -- 5. Build eco.papExtend with total arity
        ( resVar, ctx2 ) =
            Ctx.freshVar ctx1b

        allOperandNames =
            funcResult.resultVar :: List.map Tuple.first boxedArgsWithTypes

        allOperandTypes =
            funcResult.resultType :: List.map Tuple.second boxedArgsWithTypes

        newargsUnboxedBitmap =
            List.indexedMap
                (\i ( _, mlirTy ) ->
                    if Types.isUnboxable mlirTy then
                        Bitwise.shiftLeftBy i 1

                    else
                        0
                )
                boxedArgsWithTypes
                |> List.foldl Bitwise.or 0

        -- CGEN_052: remaining_arity is the SOURCE PAP's remaining, not the result's
        remainingArity =
            totalArity

        papExtendAttrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr allOperandTypes) )
                , ( "remaining_arity", IntAttr Nothing remainingArity )
                , ( "newargs_unboxed_bitmap", IntAttr Nothing newargsUnboxedBitmap )
                ]

        resultMlirType =
            Types.monoTypeToAbi resultType

        ( ctx3, papExtendOp ) =
            Ops.mlirOp ctx2 "eco.papExtend"
                |> Ops.opBuilder.withOperands allOperandNames
                |> Ops.opBuilder.withResults [ ( resVar, resultMlirType ) ]
                |> Ops.opBuilder.withAttrs papExtendAttrs
                |> Ops.opBuilder.build
    in
    { ops = funcResult.ops ++ argOps ++ boxOps ++ [ papExtendOp ]
    , resultVar = resVar
    , resultType = resultMlirType
    , ctx = ctx3
    , isTerminated = False
    }


{-| Generate a partial application where the result is still a closure.
This creates a closure via papExtend rather than attempting a direct call.
Uses precomputed CallInfo from GlobalOpt.
-}
generateClosureApplication : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> Mono.CallInfo -> ExprResult
generateClosureApplication ctx func args resultType callInfo =
    case callInfo.callModel of
        Mono.FlattenedExternal ->
            -- External/kernel: use total ABI arity
            generateFlattenedPartialApplication ctx func args resultType

        Mono.StageCurried ->
            -- User closure: use stage-curried applyByStages
            let
                funcResult : ExprResult
                funcResult =
                    generateExpr ctx func

                -- CGEN_056: expectedType becomes the saturated papExtend result type,
                -- which must equal the callee's func.func return type.
                expectedType =
                    Types.monoTypeToAbi resultType
            in
            -- If the function result is not a closure (e.g., a zero-arity thunk was
            -- already evaluated), and we're calling with no args, just return the value.
            -- This handles: let f = \() -> 42 in f
            -- where f is already evaluated to i64, and "calling" with no args is a no-op.
            if not (Types.isEcoValueType funcResult.resultType) && List.isEmpty args then
                -- Already evaluated - just return the value, coercing if needed
                let
                    ( coerceOps, finalVar, ctx1 ) =
                        coerceResultToType funcResult.ctx funcResult.resultVar funcResult.resultType expectedType
                in
                { ops = funcResult.ops ++ coerceOps
                , resultVar = finalVar
                , resultType = expectedType
                , ctx = ctx1
                , isTerminated = False
                }

            else
                -- Normal partial application via papExtend (typed closure ABI)
                -- Apply arguments by stages to handle stage-curried closures (CGEN_052)
                let
                    -- Use generateExprListTyped to get actual SSA types
                    ( argOps, argsWithTypes, ctx1 ) =
                        generateExprListTyped funcResult.ctx args

                    -- Box args for closure boundary
                    -- Extern/kernel evaluator wrappers always have !eco.value params, so box all primitives.
                    -- User-defined closures: only box Bool (i1) per REP_CLOSURE_001.
                    evaluatorBoxesAll =
                        case func of
                            Mono.MonoVarGlobal _ specId _ ->
                                case Dict.get specId ctx.signatures of
                                    Just sig ->
                                        hasAllBoxedEvaluatorParams sig

                                    Nothing ->
                                        False

                            Mono.MonoVarKernel _ _ _ kernelType ->
                                hasAllBoxedEvaluatorParams (Ctx.kernelFuncSignatureFromType kernelType)

                            Mono.MonoVarLocal name _ ->
                                Set.member name ctx.externBoxedVars

                            _ ->
                                False

                    ( boxOps, boxedArgsWithTypes, ctx1b ) =
                        boxArgsForClosureBoundary evaluatorBoxesAll ctx1 argsWithTypes

                    -- Use precomputed staging metadata from CallInfo (CGEN_052)
                    -- initialRemaining = stage arity at this call site (sourceRemaining for applyByStages)
                    -- remainingStageArities = subsequent stage arities
                    initialRemaining =
                        callInfo.initialRemaining

                    remainingStageArities =
                        callInfo.remainingStageArities

                    -- Apply arguments by stages, emitting a chain of papExtend operations
                    -- (metadata-driven: uses initialRemaining and remainingStageArities from CallInfo)
                    -- Pass expectedType as the saturated return type for when call becomes fully saturated
                    papResult =
                        applyByStages ctx1b funcResult.resultVar funcResult.resultType initialRemaining remainingStageArities expectedType boxedArgsWithTypes []
                in
                { ops = funcResult.ops ++ argOps ++ boxOps ++ papResult.ops
                , resultVar = papResult.resultVar
                , resultType = papResult.resultType
                , ctx = papResult.ctx
                , isTerminated = False
                }


{-| Box arguments for closure boundary.

When boxAllPrimitives is True (unknown callee), boxes ALL primitive types
(i64, f64, i16, i1) to !eco.value since the target function's expected
parameter types are unknown.

When boxAllPrimitives is False (known callee), only boxes i1 (Bool) per
REP\_CLOSURE\_001, leaving i64/f64/i16 as-is for known function signatures.

-}
boxArgsForClosureBoundary : Bool -> Ctx.Context -> List ( String, MlirType ) -> ( List MlirOp, List ( String, MlirType ), Ctx.Context )
boxArgsForClosureBoundary boxAllPrimitives ctx argsWithTypes =
    let
        ( opsReversed, argsReversed, ctxFinal ) =
            List.foldl
                (\( var, mlirTy ) ( opsAcc, argsAcc, ctxAcc ) ->
                    let
                        needsBoxing =
                            if boxAllPrimitives then
                                -- Unknown callee: box ALL primitives (i64, f64, i16, i1) to !eco.value
                                not (Types.isEcoValueType mlirTy)

                            else
                                -- Known callee: only box Bool (i1) per REP_CLOSURE_001
                                mlirTy == I1
                    in
                    if needsBoxing then
                        let
                            ( boxOps, boxedVar, ctx1 ) =
                                boxToEcoValue ctxAcc var mlirTy
                        in
                        ( List.reverse boxOps ++ opsAcc, ( boxedVar, Types.ecoValue ) :: argsAcc, ctx1 )

                    else
                        ( opsAcc, ( var, mlirTy ) :: argsAcc, ctxAcc )
                )
                ( [], [], ctx )
                argsWithTypes
    in
    ( List.reverse opsReversed, List.reverse argsReversed, ctxFinal )


{-| Check if a function signature's evaluator has all !eco.value params.
This covers MonoExtern, MonoManagerLeaf, AND polymorphic closures like (==)
whose closureInfo.params remain as type variables after monomorphization.
-}
hasAllBoxedEvaluatorParams : Ctx.FuncSignature -> Bool
hasAllBoxedEvaluatorParams sig =
    not (List.isEmpty sig.paramTypes)
        && List.all (Types.isEcoValueType << Types.monoTypeToAbi) sig.paramTypes


{-| Track whether a let-bound variable aliases a function whose evaluator has
all !eco.value params. Used by papExtend generation to decide whether to box
all primitive args.
-}
trackExternBoxedVar : String -> Mono.MonoExpr -> Ctx.Context -> Ctx.Context
trackExternBoxedVar name expr ctx =
    let
        isExternBoxed =
            case expr of
                Mono.MonoVarGlobal _ specId _ ->
                    case Dict.get specId ctx.signatures of
                        Just sig ->
                            hasAllBoxedEvaluatorParams sig

                        Nothing ->
                            False

                Mono.MonoVarKernel _ _ _ kernelType ->
                    hasAllBoxedEvaluatorParams (Ctx.kernelFuncSignatureFromType kernelType)

                _ ->
                    False
    in
    if isExternBoxed then
        { ctx | externBoxedVars = Set.insert name ctx.externBoxedVars }

    else
        ctx


{-| Detect inlined Bytes.Decode.decode pattern:

    MonoLet (MonoDef name decoderExpr)
        (MonoDestruct ...
            (MonoCall (MonoVarKernel "Bytes" "decode") [_, bytesExpr] ...))

When the monomorphizer inlines Bytes.Decode.decode, it produces a let binding for
the decoder value, a destructuring to extract the inner step function, and a kernel
call. We intercept this pattern to try fusion on the original decoder expression.

-}
tryInlinedDecodeFusion : Ctx.Context -> Mono.MonoDef -> Mono.MonoExpr -> Maybe ExprResult
tryInlinedDecodeFusion ctx def body =
    case def of
        Mono.MonoDef defName decoderExpr ->
            -- Collect this binding and search for the decode pattern in the body
            tryDecodeFusionWithBindings ctx [ ( defName, decoderExpr ) ] body

        Mono.MonoTailDef _ _ _ ->
            Nothing


{-| Search for the decode fusion pattern through nested MonoLet bindings.
Accumulates let bindings to resolve the decoder expression when found.
-}
tryDecodeFusionWithBindings : Ctx.Context -> List ( Name.Name, Mono.MonoExpr ) -> Mono.MonoExpr -> Maybe ExprResult
tryDecodeFusionWithBindings ctx bindings body =
    case body of
        Mono.MonoDestruct _ innerBody _ ->
            -- Found a destruct - check if its body is a kernel decode call
            case findKernelDecodeCall innerBody of
                Just bytesExpr ->
                    -- Found the decode pattern - resolve the decoder from accumulated bindings
                    case resolveDecoderExpr ctx.registry ctx.decoderExprs bindings of
                        Just decoderNode ->
                            -- Fusion successful - compile skipped let-bindings to register variables
                            let
                                ( bindingOps, ctx0 ) =
                                    compileSkippedBindings ctx (List.reverse bindings)

                                ( bytesOps, bytesArgsWithTypes, ctx1 ) =
                                    generateExprListTyped ctx0 [ bytesExpr ]

                                bytesVar : String
                                bytesVar =
                                    case bytesArgsWithTypes of
                                        [ ( bVar, _ ) ] ->
                                            bVar

                                        _ ->
                                            "invalid_bytes"

                                ( decoderOps, _ ) =
                                    BFReify.decoderNodeToOps decoderNode

                                exprCompiler : BFEmit.ExprCompiler
                                exprCompiler monoExpr compilerCtx =
                                    let
                                        result =
                                            generateExpr compilerCtx monoExpr
                                    in
                                    { ops = result.ops
                                    , resultVar = result.resultVar
                                    , resultType = result.resultType
                                    , ctx = result.ctx
                                    }

                                ( mlirOps, resultVar, ctx2 ) =
                                    BFEmit.emitFusedDecoder exprCompiler ctx1 bytesVar decoderOps
                            in
                            Just
                                { ops = bindingOps ++ bytesOps ++ mlirOps
                                , resultVar = resultVar
                                , resultType = Types.ecoValue
                                , ctx = ctx2
                                , isTerminated = False
                                }

                        Nothing ->
                            -- Reification failed - fall back to normal compilation
                            Nothing

                Nothing ->
                    Nothing

        Mono.MonoLet (Mono.MonoDef innerName innerExpr) innerBody _ ->
            -- Accumulate this binding and continue searching
            tryDecodeFusionWithBindings ctx (( innerName, innerExpr ) :: bindings) innerBody

        _ ->
            Nothing


{-| Resolve a decoder expression from accumulated let bindings.
Follows MonoVarLocal references through the binding chain.
-}
resolveDecoderExpr : Mono.SpecializationRegistry -> Dict.Dict String Mono.MonoExpr -> List ( Name.Name, Mono.MonoExpr ) -> Maybe BFReify.DecoderNode
resolveDecoderExpr registry decoderExprs bindings =
    case bindings of
        [] ->
            Nothing

        ( _, expr ) :: rest ->
            case BFReify.reifyDecoder registry decoderExprs expr of
                Just node ->
                    Just node

                Nothing ->
                    -- If this binding's expression is a local variable reference,
                    -- try to find the original expression in earlier bindings,
                    -- then check the context's cached decoder expressions from outer scopes.
                    case expr of
                        Mono.MonoVarLocal name _ ->
                            case resolveDecoderByName registry decoderExprs name rest of
                                Just node ->
                                    Just node

                                Nothing ->
                                    -- Check outer scope decoder cache
                                    case Dict.get name decoderExprs of
                                        Just outerExpr ->
                                            case BFReify.reifyDecoder registry decoderExprs outerExpr of
                                                Just node ->
                                                    Just node

                                                Nothing ->
                                                    resolveDecoderExpr registry decoderExprs rest

                                        Nothing ->
                                            resolveDecoderExpr registry decoderExprs rest

                        _ ->
                            -- Try the next binding
                            resolveDecoderExpr registry decoderExprs rest


{-| Find a binding by name and try to reify its expression as a decoder.
-}
resolveDecoderByName : Mono.SpecializationRegistry -> Dict.Dict String Mono.MonoExpr -> Name.Name -> List ( Name.Name, Mono.MonoExpr ) -> Maybe BFReify.DecoderNode
resolveDecoderByName registry decoderExprs targetName bindings =
    case bindings of
        [] ->
            Nothing

        ( name, expr ) :: rest ->
            if name == targetName then
                case BFReify.reifyDecoder registry decoderExprs expr of
                    Just node ->
                        Just node

                    Nothing ->
                        -- Follow another level of indirection
                        case expr of
                            Mono.MonoVarLocal innerName _ ->
                                resolveDecoderByName registry decoderExprs innerName rest

                            _ ->
                                Nothing

            else
                resolveDecoderByName registry decoderExprs targetName rest


{-| Try to resolve a decoder node from an expression, falling back to the
context's decoderExprs cache when the expression is a local variable reference.
This handles the case where D.decode is called with a let-bound decoder variable
that was already cached during decoder-skipping in generateLet.
-}
resolveDecoderNode : Ctx.Context -> Mono.MonoExpr -> Maybe BFReify.DecoderNode
resolveDecoderNode ctx expr =
    BFReify.reifyDecoder ctx.registry ctx.decoderExprs expr


compileSkippedBindings : Ctx.Context -> List ( Name.Name, Mono.MonoExpr ) -> ( List MlirOp, Ctx.Context )
compileSkippedBindings ctx bindings =
    case bindings of
        [] ->
            ( [], ctx )

        ( name, expr ) :: rest ->
            let
                exprResult =
                    generateExpr ctx expr

                ctx1 =
                    Ctx.addVarMapping name exprResult.resultVar exprResult.resultType exprResult.ctx

                ( restOps, ctxFinal ) =
                    compileSkippedBindings ctx1 rest
            in
            ( exprResult.ops ++ restOps, ctxFinal )


{-| Find a kernel Bytes.decode call and return the bytes argument.
-}
findKernelDecodeCall : Mono.MonoExpr -> Maybe Mono.MonoExpr
findKernelDecodeCall expr =
    case expr of
        Mono.MonoCall _ (Mono.MonoVarKernel _ "Bytes" "decode" _) args _ _ ->
            case args of
                [ _, bytesExpr ] ->
                    Just bytesExpr

                _ ->
                    Nothing

        -- The kernel decode call might be nested in more let bindings
        Mono.MonoLet _ innerBody _ ->
            findKernelDecodeCall innerBody

        _ ->
            Nothing


{-| Generate a saturated function call where all arguments are provided.
-}
generateSaturatedCall : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> Mono.CallInfo -> ExprResult
generateSaturatedCall ctx func args resultType callInfo =
    case func of
        Mono.MonoVarGlobal _ specId funcType ->
            let
                -- Use generateExprListTyped to get actual SSA types
                ( argOps, argsWithTypes, ctx1 ) =
                    generateExprListTyped ctx args

                argTypes : List Mono.MonoType
                argTypes =
                    List.map Mono.typeOf args

                -- Check if this is a call to a core module function
                maybeCoreInfo : Maybe ( String, String )
                maybeCoreInfo =
                    case Registry.lookupSpecKey specId ctx.registry of
                        Just ( Mono.Global (IO.Canonical pkg moduleName) name, _, _ ) ->
                            if pkg == Pkg.core then
                                Just ( moduleName, name )

                            else
                                Nothing

                        Just ( Mono.Accessor _, _, _ ) ->
                            -- Accessors are not core functions
                            Nothing

                        Nothing ->
                            Nothing

                -- Check if this is Bytes.Encode.encode for fusion
                maybeBytesEncodeArg : Maybe Mono.MonoExpr
                maybeBytesEncodeArg =
                    case Registry.lookupSpecKey specId ctx.registry of
                        Just ( Mono.Global (IO.Canonical pkg moduleName) name, _, _ ) ->
                            if pkg == Pkg.bytes && moduleName == "Bytes.Encode" && name == "encode" then
                                case args of
                                    [ encoderExpr ] ->
                                        Just encoderExpr

                                    _ ->
                                        Nothing

                            else
                                Nothing

                        _ ->
                            Nothing

                -- Check if this is Bytes.Decode.decode for fusion
                maybeBytesDecodeArgs : Maybe ( Mono.MonoExpr, Mono.MonoExpr )
                maybeBytesDecodeArgs =
                    case Registry.lookupSpecKey specId ctx.registry of
                        Just ( Mono.Global (IO.Canonical pkg moduleName) name, _, _ ) ->
                            if pkg == Pkg.bytes && moduleName == "Bytes.Decode" && name == "decode" then
                                case args of
                                    [ decoderExpr, bytesExpr ] ->
                                        Just ( decoderExpr, bytesExpr )

                                    _ ->
                                        Nothing

                            else
                                Nothing

                        _ ->
                            Nothing
            in
            -- Try byte fusion first, then fall back to regular dispatch
            case maybeBytesEncodeArg of
                Just encoderExpr ->
                    -- Attempt to fuse the encoder
                    case BFReify.reifyEncoder ctx.registry ctx.decoderExprs encoderExpr of
                        Just nodes ->
                            -- Fusion successful - emit fused byte encoding ops
                            let
                                loopOps =
                                    BFReify.nodesToOps nodes

                                -- Wrap generateExpr to match ExprCompiler type
                                exprCompiler : BFEmit.ExprCompiler
                                exprCompiler monoExpr compilerCtx =
                                    let
                                        result =
                                            generateExpr compilerCtx monoExpr
                                    in
                                    { ops = result.ops
                                    , resultVar = result.resultVar
                                    , resultType = result.resultType
                                    , ctx = result.ctx
                                    }

                                ( mlirOps, bufferVar, ctx2 ) =
                                    BFEmit.emitFusedEncoder exprCompiler ctx1 loopOps
                            in
                            { ops = argOps ++ mlirOps
                            , resultVar = bufferVar
                            , resultType = Types.ecoValue
                            , ctx = ctx2
                            , isTerminated = False
                            }

                        Nothing ->
                            -- Fusion failed - fall back to kernel call
                            let
                                sig : Ctx.FuncSignature
                                sig =
                                    Ctx.kernelFuncSignatureFromType funcType

                                ( boxOps, argVarPairs, ctx1b ) =
                                    boxToMatchSignatureTyped ctx1 argsWithTypes sig.paramTypes

                                ( resVar, ctx2 ) =
                                    Ctx.freshVar ctx1b

                                kernelName : String
                                kernelName =
                                    "Elm_Kernel_Bytes_Encode_encode"

                                callResultType =
                                    Types.monoTypeToAbi sig.returnType

                                ( ctx3, callOp ) =
                                    Ops.ecoCallNamed ctx2 resVar kernelName argVarPairs callResultType
                            in
                            { ops = argOps ++ boxOps ++ [ callOp ]
                            , resultVar = resVar
                            , resultType = callResultType
                            , ctx = ctx3
                            , isTerminated = False
                            }

                Nothing ->
                    -- Not a bytes encode call - check for bytes decode fusion
                    case maybeBytesDecodeArgs of
                        Just ( decoderExpr, _ ) ->
                            -- Attempt to fuse the decoder (also resolves local var refs via decoderExprs cache)
                            case resolveDecoderNode ctx decoderExpr of
                                Just decoderNode ->
                                    -- Fusion successful - emit fused byte decoding ops
                                    let
                                        -- Get the bytesVar from argsWithTypes (second argument)
                                        bytesVar : String
                                        bytesVar =
                                            case argsWithTypes of
                                                [ _, ( bVar, _ ) ] ->
                                                    bVar

                                                _ ->
                                                    -- Should not happen for valid Decode.decode call
                                                    "invalid_bytes"

                                        -- Compile decoder node to Loop IR
                                        ( decoderOps, _ ) =
                                            BFReify.decoderNodeToOps decoderNode

                                        -- Wrap generateExpr to match ExprCompiler type
                                        exprCompiler : BFEmit.ExprCompiler
                                        exprCompiler monoExpr compilerCtx =
                                            let
                                                result =
                                                    generateExpr compilerCtx monoExpr
                                            in
                                            { ops = result.ops
                                            , resultVar = result.resultVar
                                            , resultType = result.resultType
                                            , ctx = result.ctx
                                            }

                                        -- Emit the fused decoder operations
                                        ( mlirOps, resultVar, ctx2 ) =
                                            BFEmit.emitFusedDecoder exprCompiler ctx1 bytesVar decoderOps
                                    in
                                    { ops = argOps ++ mlirOps
                                    , resultVar = resultVar
                                    , resultType = Types.ecoValue
                                    , ctx = ctx2
                                    , isTerminated = False
                                    }

                                Nothing ->
                                    -- Fusion failed - fall back to kernel call
                                    -- Force both arguments to eco.value since the kernel always takes boxed values
                                    let
                                        -- Box both arguments to eco.value regardless of their current types
                                        ( boxOps, argVarPairs, ctx1b ) =
                                            boxToMatchSignatureTyped ctx1 argsWithTypes [ Mono.MUnit, Mono.MUnit ]

                                        ( resVar, ctx2 ) =
                                            Ctx.freshVar ctx1b

                                        kernelName : String
                                        kernelName =
                                            "Elm_Kernel_Bytes_decode"

                                        -- Result is always eco.value (Maybe a)
                                        callResultType =
                                            Types.ecoValue

                                        ( ctx3, callOp ) =
                                            Ops.ecoCallNamed ctx2 resVar kernelName argVarPairs callResultType
                                    in
                                    { ops = argOps ++ boxOps ++ [ callOp ]
                                    , resultVar = resVar
                                    , resultType = callResultType
                                    , ctx = ctx3
                                    , isTerminated = False
                                    }

                        Nothing ->
                            -- Not a bytes decode call - check for core intrinsics
                            case maybeCoreInfo of
                                Just ( moduleName, name ) ->
                                    -- This is a core module function - check for intrinsic
                                    case Intrinsics.kernelIntrinsic moduleName name argTypes resultType of
                                        Just intrinsic ->
                                            -- Generate intrinsic operation directly
                                            -- First unbox arguments if needed (e.g., eco.value -> i1 for Bool)
                                            let
                                                ( unboxOps, unboxedArgVars, ctx1b ) =
                                                    Intrinsics.unboxArgsForIntrinsic ctx1 argsWithTypes intrinsic

                                                ( resVar, ctx2 ) =
                                                    Ctx.freshVar ctx1b

                                                ( ctx3, intrinsicOp ) =
                                                    Intrinsics.generateIntrinsicOp ctx2 intrinsic resVar unboxedArgVars

                                                intrinsicResultType =
                                                    Intrinsics.intrinsicResultMlirType intrinsic
                                            in
                                            { ops = argOps ++ unboxOps ++ [ intrinsicOp ]
                                            , resultVar = resVar
                                            , resultType = intrinsicResultType
                                            , ctx = ctx3
                                            , isTerminated = False
                                            }

                                        Nothing ->
                                            -- No intrinsic match - check if we should use kernel or compiled function
                                            if Ctx.hasKernelImplementation moduleName name then
                                                -- Fall back to kernel call (e.g., negate with boxed values)
                                                let
                                                    sig : Ctx.FuncSignature
                                                    sig =
                                                        Ctx.kernelFuncSignatureFromType funcType

                                                    -- Use boxToMatchSignatureTyped with actual SSA types
                                                    ( boxOps, argVarPairs, ctx1b ) =
                                                        boxToMatchSignatureTyped ctx1 argsWithTypes sig.paramTypes

                                                    ( resVar, ctx2 ) =
                                                        Ctx.freshVar ctx1b

                                                    kernelName : String
                                                    kernelName =
                                                        "Elm_Kernel_" ++ moduleName ++ "_" ++ name

                                                    callResultType =
                                                        Types.monoTypeToAbi sig.returnType

                                                    ( ctx3, callOp ) =
                                                        Ops.ecoCallNamed ctx2 resVar kernelName argVarPairs callResultType
                                                in
                                                { ops = argOps ++ boxOps ++ [ callOp ]
                                                , resultVar = resVar
                                                , resultType = callResultType
                                                , ctx = ctx3
                                                , isTerminated = False
                                                }

                                            else
                                                -- Fall back to compiled function call (e.g., min, max, abs, compare)
                                                let
                                                    funcName : String
                                                    funcName =
                                                        specIdToFuncName ctx.registry specId

                                                    maybeSig : Maybe Ctx.FuncSignature
                                                    maybeSig =
                                                        Dict.get specId ctx.signatures

                                                    ( boxOps, argVarPairs, ctx1b ) =
                                                        case maybeSig of
                                                            Just sig ->
                                                                -- Use boxToMatchSignatureTyped with actual SSA types
                                                                boxToMatchSignatureTyped ctx1 argsWithTypes sig.paramTypes

                                                            Nothing ->
                                                                -- No signature: use actual SSA types
                                                                ( [], argsWithTypes, ctx1 )

                                                    ( resultVar, ctx2 ) =
                                                        Ctx.freshVar ctx1b

                                                    resultMlirType =
                                                        case maybeSig of
                                                            Just sig ->
                                                                Types.monoTypeToAbi sig.returnType

                                                            Nothing ->
                                                                Types.monoTypeToAbi resultType

                                                    ( ctx3, callOp ) =
                                                        Ops.ecoCallNamed ctx2 resultVar funcName argVarPairs resultMlirType
                                                in
                                                { ops = argOps ++ boxOps ++ [ callOp ]
                                                , resultVar = resultVar
                                                , resultType = resultMlirType
                                                , ctx = ctx3
                                                , isTerminated = False
                                                }

                                Nothing ->
                                    -- Regular function call (not a core module)
                                    let
                                        funcName : String
                                        funcName =
                                            specIdToFuncName ctx.registry specId

                                        -- Look up the function signature to determine expected parameter types
                                        maybeSig : Maybe Ctx.FuncSignature
                                        maybeSig =
                                            Dict.get specId ctx.signatures

                                        -- Use boxToMatchSignatureTyped with actual SSA types
                                        ( boxOps, argVarPairs, ctx1b ) =
                                            case maybeSig of
                                                Just sig ->
                                                    boxToMatchSignatureTyped ctx1 argsWithTypes sig.paramTypes

                                                Nothing ->
                                                    -- No signature: use actual SSA types
                                                    ( [], argsWithTypes, ctx1 )

                                        ( resultVar, ctx2 ) =
                                            Ctx.freshVar ctx1b

                                        resultMlirType =
                                            case maybeSig of
                                                Just sig ->
                                                    Types.monoTypeToAbi sig.returnType

                                                Nothing ->
                                                    Types.monoTypeToAbi resultType

                                        ( ctx3, callOp ) =
                                            Ops.ecoCallNamed ctx2 resultVar funcName argVarPairs resultMlirType
                                    in
                                    { ops = argOps ++ boxOps ++ [ callOp ]
                                    , resultVar = resultVar
                                    , resultType = resultMlirType
                                    , ctx = ctx3
                                    , isTerminated = False
                                    }

        Mono.MonoVarKernel _ home name funcType ->
            let
                -- Use generateExprListTyped to get actual SSA types
                ( argOps, argsWithTypes, ctx1 ) =
                    generateExprListTyped ctx args

                argTypes : List Mono.MonoType
                argTypes =
                    List.map Mono.typeOf args
            in
            case ( home, name, argsWithTypes ) of
                ( "Basics", "logBase", [ ( baseVar, baseType ), ( xVar, xType ) ] ) ->
                    let
                        -- Unbox baseVar if needed
                        ( unboxBaseOps, unboxedBaseVar, ctx1a ) =
                            if Types.isEcoValueType baseType then
                                Intrinsics.unboxToType ctx1 baseVar F64

                            else
                                ( [], baseVar, ctx1 )

                        -- Unbox xVar if needed
                        ( unboxXOps, unboxedXVar, ctx1b ) =
                            if Types.isEcoValueType xType then
                                Intrinsics.unboxToType ctx1a xVar F64

                            else
                                ( [], xVar, ctx1a )

                        ( logXVar, ctx2 ) =
                            Ctx.freshVar ctx1b

                        ( logBaseVar, ctx3 ) =
                            Ctx.freshVar ctx2

                        ( resVar, ctx4 ) =
                            Ctx.freshVar ctx3

                        ( ctx5, logXOp ) =
                            Ops.ecoUnaryOp ctx4 "eco.float.log" logXVar ( unboxedXVar, F64 ) F64

                        ( ctx6, logBaseOp ) =
                            Ops.ecoUnaryOp ctx5 "eco.float.log" logBaseVar ( unboxedBaseVar, F64 ) F64

                        ( ctx7, divOp ) =
                            Ops.ecoBinaryOp ctx6 "eco.float.div" resVar ( logXVar, F64 ) ( logBaseVar, F64 ) F64
                    in
                    { ops = argOps ++ unboxBaseOps ++ unboxXOps ++ [ logXOp, logBaseOp, divOp ]
                    , resultVar = resVar
                    , resultType = Types.ecoFloat
                    , ctx = ctx7
                    , isTerminated = False
                    }

                ( "Debug", "log", [ ( labelVar, _ ), ( valueVar, valueType ) ] ) ->
                    -- Special handling for Debug.log with typed output
                    -- Emit eco.dbg with arg_type_ids, then return the value
                    let
                        -- Get the type of the value being logged
                        valueMonoType : Mono.MonoType
                        valueMonoType =
                            case args of
                                [ _, valueExpr ] ->
                                    Mono.typeOf valueExpr

                                _ ->
                                    Mono.MUnit

                        -- Get or create a type ID for the string label
                        ( labelTypeId, ctx1a_ ) =
                            Ctx.getOrCreateTypeIdForMonoType Mono.MString ctx1

                        -- Get or create a type ID for this type
                        ( typeId, ctx1b ) =
                            Ctx.getOrCreateTypeIdForMonoType valueMonoType ctx1a_

                        -- Box the value if needed for eco.dbg
                        ( boxOps, boxedValueVar, ctx1c ) =
                            if Types.isEcoValueType valueType then
                                ( [], valueVar, ctx1b )

                            else
                                let
                                    ( boxVar, ctx1c_ ) =
                                        Ctx.freshVar ctx1b

                                    boxAttrs =
                                        Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr valueType ])

                                    ( ctx1c__, boxOp ) =
                                        Ops.mlirOp ctx1c_ "eco.box"
                                            |> Ops.opBuilder.withOperands [ valueVar ]
                                            |> Ops.opBuilder.withResults [ ( boxVar, Types.ecoValue ) ]
                                            |> Ops.opBuilder.withAttrs boxAttrs
                                            |> Ops.opBuilder.build
                                in
                                ( [ boxOp ], boxVar, ctx1c__ )

                        -- Create eco.dbg op with arg_type_ids
                        -- We only pass the value with its type_id
                        -- The label is printed separately by the runtime
                        ( ctx2, dbgOp ) =
                            Ops.mlirOp ctx1c "eco.dbg"
                                |> Ops.opBuilder.withOperands [ labelVar, boxedValueVar ]
                                |> Ops.opBuilder.withAttrs
                                    (Dict.fromList
                                        [ ( "_operand_types"
                                          , ArrayAttr Nothing [ TypeAttr Types.ecoValue, TypeAttr Types.ecoValue ]
                                          )
                                        , ( "arg_type_ids"
                                          , ArrayAttr (Just I64)
                                                [ IntAttr Nothing labelTypeId -- typeId for string label
                                                , IntAttr Nothing typeId -- typeId for value
                                                ]
                                          )
                                        ]
                                    )
                                |> Ops.opBuilder.build
                    in
                    { ops = argOps ++ boxOps ++ [ dbgOp ]
                    , resultVar = boxedValueVar -- Return the value (boxed)
                    , resultType = Types.ecoValue
                    , ctx = ctx2
                    , isTerminated = False
                    }

                ( "Debug", "toString", [ ( valueVar, valueType ) ] ) ->
                    -- Special handling for Debug.toString: pass type_id for constructor names
                    let
                        valueMonoType : Mono.MonoType
                        valueMonoType =
                            case args of
                                [ valueExpr ] ->
                                    Mono.typeOf valueExpr

                                _ ->
                                    Mono.MUnit

                        ( typeId, ctx1b ) =
                            Ctx.getOrCreateTypeIdForMonoType valueMonoType ctx1

                        -- Box the value if needed
                        ( boxOps, boxedValueVar, ctx1c ) =
                            if Types.isEcoValueType valueType then
                                ( [], valueVar, ctx1b )

                            else
                                let
                                    ( boxVar, ctx1c_ ) =
                                        Ctx.freshVar ctx1b

                                    boxAttrs =
                                        Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr valueType ])

                                    ( ctx1c__, boxOp ) =
                                        Ops.mlirOp ctx1c_ "eco.box"
                                            |> Ops.opBuilder.withOperands [ valueVar ]
                                            |> Ops.opBuilder.withResults [ ( boxVar, Types.ecoValue ) ]
                                            |> Ops.opBuilder.withAttrs boxAttrs
                                            |> Ops.opBuilder.build
                                in
                                ( [ boxOp ], boxVar, ctx1c__ )

                        -- Create the type_id constant
                        ( typeIdVar, ctx2a ) =
                            Ctx.freshVar ctx1c

                        ( ctx2b, typeIdOp ) =
                            Ops.arithConstantInt ctx2a typeIdVar typeId

                        ( resultVar, ctx2c ) =
                            Ctx.freshVar ctx2b

                        ( ctx2d, callOp ) =
                            Ops.ecoCallNamed ctx2c
                                resultVar
                                "Elm_Kernel_Debug_toString"
                                [ ( boxedValueVar, Types.ecoValue )
                                , ( typeIdVar, Types.ecoInt )
                                ]
                                Types.ecoValue
                    in
                    { ops = argOps ++ boxOps ++ [ typeIdOp, callOp ]
                    , resultVar = resultVar
                    , resultType = Types.ecoValue
                    , ctx = ctx2d
                    , isTerminated = False
                    }

                -- BytesFusion: intercept Bytes.encode kernel call
                ( "Bytes", "encode", [ _ ] ) ->
                    case args of
                        [ encoderExpr ] ->
                            case BFReify.reifyEncoder ctx.registry ctx.decoderExprs encoderExpr of
                                Just nodes ->
                                    -- Fusion successful - emit fused byte encoding ops
                                    let
                                        loopOps =
                                            BFReify.nodesToOps nodes

                                        exprCompiler : BFEmit.ExprCompiler
                                        exprCompiler monoExpr compilerCtx =
                                            let
                                                result =
                                                    generateExpr compilerCtx monoExpr
                                            in
                                            { ops = result.ops
                                            , resultVar = result.resultVar
                                            , resultType = result.resultType
                                            , ctx = result.ctx
                                            }

                                        ( mlirOps, bufferVar, ctx2 ) =
                                            BFEmit.emitFusedEncoder exprCompiler ctx1 loopOps
                                    in
                                    { ops = argOps ++ mlirOps
                                    , resultVar = bufferVar
                                    , resultType = Types.ecoValue
                                    , ctx = ctx2
                                    , isTerminated = False
                                    }

                                Nothing ->
                                    -- Fusion failed - fall back to kernel call
                                    let
                                        ( boxOps, argVarPairs, ctx1b ) =
                                            boxToMatchSignatureTyped ctx1 argsWithTypes [ Mono.MUnit ]

                                        ( resVar, ctx2 ) =
                                            Ctx.freshVar ctx1b

                                        ( ctx3, callOp ) =
                                            Ops.ecoCallNamed ctx2 resVar "Elm_Kernel_Bytes_encode" argVarPairs Types.ecoValue
                                    in
                                    { ops = argOps ++ boxOps ++ [ callOp ]
                                    , resultVar = resVar
                                    , resultType = Types.ecoValue
                                    , ctx = ctx3
                                    , isTerminated = False
                                    }

                        _ ->
                            -- Should not happen for valid Bytes.encode call
                            let
                                ( boxOps, argVarPairs, ctx1b ) =
                                    boxToMatchSignatureTyped ctx1 argsWithTypes [ Mono.MUnit ]

                                ( resVar, ctx2 ) =
                                    Ctx.freshVar ctx1b

                                ( ctx3, callOp ) =
                                    Ops.ecoCallNamed ctx2 resVar "Elm_Kernel_Bytes_encode" argVarPairs Types.ecoValue
                            in
                            { ops = argOps ++ boxOps ++ [ callOp ]
                            , resultVar = resVar
                            , resultType = Types.ecoValue
                            , ctx = ctx3
                            , isTerminated = False
                            }

                -- BytesFusion: intercept Bytes.decode kernel call
                ( "Bytes", "decode", [ _, _ ] ) ->
                    case args of
                        [ decoderExpr, _ ] ->
                            case resolveDecoderNode ctx decoderExpr of
                                Just decoderNode ->
                                    -- Fusion successful - emit fused byte decoding ops
                                    let
                                        bytesVar : String
                                        bytesVar =
                                            case argsWithTypes of
                                                [ _, ( bVar, _ ) ] ->
                                                    bVar

                                                _ ->
                                                    "invalid_bytes"

                                        ( decoderOps, _ ) =
                                            BFReify.decoderNodeToOps decoderNode

                                        exprCompiler : BFEmit.ExprCompiler
                                        exprCompiler monoExpr compilerCtx =
                                            let
                                                result =
                                                    generateExpr compilerCtx monoExpr
                                            in
                                            { ops = result.ops
                                            , resultVar = result.resultVar
                                            , resultType = result.resultType
                                            , ctx = result.ctx
                                            }

                                        ( mlirOps, resultVar, ctx2 ) =
                                            BFEmit.emitFusedDecoder exprCompiler ctx1 bytesVar decoderOps
                                    in
                                    { ops = argOps ++ mlirOps
                                    , resultVar = resultVar
                                    , resultType = Types.ecoValue
                                    , ctx = ctx2
                                    , isTerminated = False
                                    }

                                Nothing ->
                                    -- Fusion failed - fall back to kernel call
                                    let
                                        ( boxOps, argVarPairs, ctx1b ) =
                                            boxToMatchSignatureTyped ctx1 argsWithTypes [ Mono.MUnit, Mono.MUnit ]

                                        ( resVar, ctx2 ) =
                                            Ctx.freshVar ctx1b

                                        ( ctx3, callOp ) =
                                            Ops.ecoCallNamed ctx2 resVar "Elm_Kernel_Bytes_decode" argVarPairs Types.ecoValue
                                    in
                                    { ops = argOps ++ boxOps ++ [ callOp ]
                                    , resultVar = resVar
                                    , resultType = Types.ecoValue
                                    , ctx = ctx3
                                    , isTerminated = False
                                    }

                        _ ->
                            -- Should not happen for valid Bytes.decode call
                            let
                                ( boxOps, argVarPairs, ctx1b ) =
                                    boxToMatchSignatureTyped ctx1 argsWithTypes [ Mono.MUnit, Mono.MUnit ]

                                ( resVar, ctx2 ) =
                                    Ctx.freshVar ctx1b

                                ( ctx3, callOp ) =
                                    Ops.ecoCallNamed ctx2 resVar "Elm_Kernel_Bytes_decode" argVarPairs Types.ecoValue
                            in
                            { ops = argOps ++ boxOps ++ [ callOp ]
                            , resultVar = resVar
                            , resultType = Types.ecoValue
                            , ctx = ctx3
                            , isTerminated = False
                            }

                _ ->
                    case Intrinsics.kernelIntrinsic home name argTypes resultType of
                        Just intrinsic ->
                            let
                                -- Unbox arguments if needed (e.g., !eco.value -> i64)
                                ( unboxOps, unboxedArgVars, ctx1b ) =
                                    Intrinsics.unboxArgsForIntrinsic ctx1 argsWithTypes intrinsic

                                ( resVar, ctx2 ) =
                                    Ctx.freshVar ctx1b

                                ( ctx3, intrinsicOp ) =
                                    Intrinsics.generateIntrinsicOp ctx2 intrinsic resVar unboxedArgVars

                                intrinsicResType =
                                    Intrinsics.intrinsicResultMlirType intrinsic
                            in
                            { ops = argOps ++ unboxOps ++ [ intrinsicOp ]
                            , resultVar = resVar
                            , resultType = intrinsicResType
                            , ctx = ctx3
                            , isTerminated = False
                            }

                        Nothing ->
                            let
                                policy : Ctx.KernelBackendAbiPolicy
                                policy =
                                    Ctx.kernelBackendAbiPolicy home name
                            in
                            case policy of
                                Ctx.AllBoxed ->
                                    -- Underlying C++ ABI: all args and result are !eco.value,
                                    -- regardless of the monomorphic Elm wrapper type.
                                    -- Box any primitive SSA values to match the kernel ABI.
                                    let
                                        elmSig : Ctx.FuncSignature
                                        elmSig =
                                            Ctx.kernelFuncSignatureFromType funcType

                                        numArgs : Int
                                        numArgs =
                                            List.length elmSig.paramTypes

                                        -- Backend ABI: all MUnit => all !eco.value
                                        backendParamTypes : List Mono.MonoType
                                        backendParamTypes =
                                            List.repeat numArgs Mono.MUnit

                                        ( boxOps, argVarPairs, ctx1b ) =
                                            boxToMatchSignatureTyped ctx1 argsWithTypes backendParamTypes

                                        ( resVar, ctx2 ) =
                                            Ctx.freshVar ctx1b

                                        kernelName : String
                                        kernelName =
                                            "Elm_Kernel_" ++ home ++ "_" ++ name

                                        resultMlirType : MlirType
                                        resultMlirType =
                                            Types.ecoValue

                                        ( ctx3, callOp ) =
                                            Ops.ecoCallNamed ctx2 resVar kernelName argVarPairs resultMlirType
                                    in
                                    { ops = argOps ++ boxOps ++ [ callOp ]
                                    , resultVar = resVar
                                    , resultType = resultMlirType
                                    , ctx = ctx3
                                    , isTerminated = False
                                    }

                                Ctx.ElmDerived ->
                                    -- ABI derived from the Elm wrapper's funcType.
                                    -- Polymorphic kernels have MVar in their funcType, which
                                    -- Types.monoTypeToAbi maps to !eco.value, so they naturally
                                    -- get all-boxed ABI without name-based checks.
                                    let
                                        elmSig : Ctx.FuncSignature
                                        elmSig =
                                            Ctx.kernelFuncSignatureFromType funcType

                                        ( boxOps, argVarPairs, ctx1b ) =
                                            boxToMatchSignatureTyped ctx1 argsWithTypes elmSig.paramTypes

                                        ( resVar, ctx2 ) =
                                            Ctx.freshVar ctx1b

                                        kernelName : String
                                        kernelName =
                                            "Elm_Kernel_" ++ home ++ "_" ++ name

                                        resultMlirType : MlirType
                                        resultMlirType =
                                            Types.monoTypeToAbi elmSig.returnType

                                        ( ctx3, callOp ) =
                                            Ops.ecoCallNamed ctx2 resVar kernelName argVarPairs resultMlirType
                                    in
                                    { ops = argOps ++ boxOps ++ [ callOp ]
                                    , resultVar = resVar
                                    , resultType = resultMlirType
                                    , ctx = ctx3
                                    , isTerminated = False
                                    }

        Mono.MonoVarLocal name _ ->
            let
                ( funcVarName, funcVarType ) =
                    Ctx.lookupVar ctx name

                expectedType =
                    Types.monoTypeToAbi resultType
            in
            case callInfo.callModel of
                Mono.FlattenedExternal ->
                    -- Local alias of a flattened external (e.g. let f = List.map in f x xs)
                    -- Reuse the flattened external machinery
                    generateFlattenedPartialApplication ctx func args resultType

                Mono.StageCurried ->
                    -- If the function variable is not a closure (e.g., a zero-arity thunk was
                    -- already evaluated), and we're calling with no args, just return the value.
                    -- This handles: let f = \() -> 42 in f()
                    -- where f is already evaluated to i64, not a closure.
                    if not (Types.isEcoValueType funcVarType) && List.isEmpty args then
                        -- Already evaluated - just return the value, coercing if needed
                        let
                            ( coerceOps, finalVar, ctx1 ) =
                                coerceResultToType ctx funcVarName funcVarType expectedType
                        in
                        { ops = coerceOps
                        , resultVar = finalVar
                        , resultType = expectedType
                        , ctx = ctx1
                        , isTerminated = False
                        }

                    else
                        -- Normal closure call via papExtend (typed closure ABI)
                        -- Apply arguments by stages to handle stage-curried closures (CGEN_052)
                        let
                            -- Use generateExprListTyped to get actual SSA types
                            ( argOps, argsWithTypes, ctx1 ) =
                                generateExprListTyped ctx args

                            -- Box Bool (i1) to !eco.value at closure boundary per REP_CLOSURE_001
                            ( boxOps, boxedArgsWithTypes, ctx1b ) =
                                boxArgsForClosureBoundary False ctx1 argsWithTypes

                            -- CGEN_052: Use precomputed staging metadata from CallInfo.
                            -- initialRemaining = stage arity at this call site (for applyByStages sourceRemaining)
                            -- remainingStageArities = subsequent stage arities
                            initialRemaining =
                                callInfo.initialRemaining

                            remainingStageArities =
                                callInfo.remainingStageArities

                            -- Apply arguments by stages, emitting a chain of papExtend operations
                            -- (metadata-driven: uses initialRemaining and remainingStageArities from CallInfo)
                            -- Pass expectedType as the saturated return type
                            papResult =
                                applyByStages ctx1b funcVarName funcVarType initialRemaining remainingStageArities expectedType boxedArgsWithTypes []
                        in
                        { ops = argOps ++ boxOps ++ papResult.ops
                        , resultVar = papResult.resultVar
                        , resultType = papResult.resultType
                        , ctx = papResult.ctx
                        , isTerminated = False
                        }

        _ ->
            let
                funcResult : ExprResult
                funcResult =
                    generateExpr ctx func

                expectedType =
                    Types.monoTypeToAbi resultType
            in
            -- If the function result is not a closure (e.g., a zero-arity thunk was
            -- already evaluated), and we're calling with no args, just return the value.
            if not (Types.isEcoValueType funcResult.resultType) && List.isEmpty args then
                -- Already evaluated - just return the value, coercing if needed
                let
                    ( coerceOps, finalVar, ctx1 ) =
                        coerceResultToType funcResult.ctx funcResult.resultVar funcResult.resultType expectedType
                in
                { ops = funcResult.ops ++ coerceOps
                , resultVar = finalVar
                , resultType = expectedType
                , ctx = ctx1
                , isTerminated = False
                }

            else
                -- Normal closure call via papExtend (typed closure ABI)
                -- Apply arguments by stages to handle stage-curried closures (CGEN_052)
                let
                    -- Use generateExprListTyped to get actual SSA types
                    ( argOps, argsWithTypes, ctx1 ) =
                        generateExprListTyped funcResult.ctx args

                    -- Box Bool (i1) to !eco.value at closure boundary per REP_CLOSURE_001
                    ( boxOps, boxedArgsWithTypes, ctx1b ) =
                        boxArgsForClosureBoundary False ctx1 argsWithTypes

                    -- CGEN_052: Use precomputed staging metadata from CallInfo.
                    -- initialRemaining = stage arity at this call site (for applyByStages sourceRemaining)
                    -- remainingStageArities = subsequent stage arities
                    initialRemaining =
                        callInfo.initialRemaining

                    remainingStageArities =
                        callInfo.remainingStageArities

                    -- Apply arguments by stages, emitting a chain of papExtend operations
                    -- (metadata-driven: uses initialRemaining and remainingStageArities from CallInfo)
                    -- Pass expectedType as the saturated return type
                    papResult =
                        applyByStages ctx1b funcResult.resultVar funcResult.resultType initialRemaining remainingStageArities expectedType boxedArgsWithTypes []
                in
                { ops = funcResult.ops ++ argOps ++ boxOps ++ papResult.ops
                , resultVar = papResult.resultVar
                , resultType = papResult.resultType
                , ctx = papResult.ctx
                , isTerminated = False
                }


{-| Generate expressions and return their ACTUAL MLIR types (not from Mono.typeOf).
This is important when the Mono types may be incorrect/stale, but the generated
SSA values have correct types.
-}
generateExprListTyped : Ctx.Context -> List Mono.MonoExpr -> ( List MlirOp, List ( String, MlirType ), Ctx.Context )
generateExprListTyped ctx exprs =
    let
        ( opsReversed, varsReversed, ctxFinal ) =
            List.foldl
                (\expr ( accOps, accVarsWithTypes, accCtx ) ->
                    let
                        result : ExprResult
                        result =
                            generateExpr accCtx expr
                    in
                    ( List.reverse result.ops ++ accOps
                    , ( result.resultVar, result.resultType ) :: accVarsWithTypes
                    , result.ctx
                    )
                )
                ( [], [], ctx )
                exprs
    in
    ( List.reverse opsReversed, List.reverse varsReversed, ctxFinal )


{-| Box arguments to !eco.value using their ACTUAL MLIR types.
This is safer than boxArgsIfNeeded because it uses the real SSA types
instead of relying on potentially incorrect Mono types.
-}
boxArgsWithMlirTypes :
    Ctx.Context
    -> List ( String, MlirType )
    -> ( List MlirOp, List String, Ctx.Context )
boxArgsWithMlirTypes ctx args =
    let
        ( opsReversed, varsReversed, ctxFinal ) =
            List.foldl
                (\( var, mlirTy ) ( opsAcc, varsAcc, ctxAcc ) ->
                    let
                        ( moreOps, boxedVar, ctx1 ) =
                            boxToEcoValue ctxAcc var mlirTy
                    in
                    ( List.reverse moreOps ++ opsAcc, boxedVar :: varsAcc, ctx1 )
                )
                ( [], [], ctx )
                args
    in
    ( List.reverse opsReversed, List.reverse varsReversed, ctxFinal )



-- ====== TAIL CALL GENERATION ======


{-| Generate MLIR code for a tail call.
-}
generateTailCall : Ctx.Context -> Name.Name -> List ( Name.Name, Mono.MonoExpr ) -> ExprResult
generateTailCall ctx _ args =
    let
        -- Generate arguments and track actual SSA types
        ( argsOpsReversed, argsWithTypesReversed, ctx1 ) =
            List.foldl
                (\( _, expr ) ( accOps, accVarsWithTypes, accCtx ) ->
                    let
                        result : ExprResult
                        result =
                            generateExpr accCtx expr
                    in
                    ( List.reverse result.ops ++ accOps
                    , ( result.resultVar, result.resultType ) :: accVarsWithTypes
                    , result.ctx
                    )
                )
                ( [], [], ctx )
                args

        argsOps =
            List.reverse argsOpsReversed

        argsWithTypes =
            List.reverse argsWithTypesReversed

        -- Extract variable names and their actual SSA types
        argVarNames : List String
        argVarNames =
            List.map Tuple.first argsWithTypes

        argVarTypes : List MlirType
        argVarTypes =
            List.map Tuple.second argsWithTypes

        -- eco.jump target is a joinpoint ID (integer), not a symbol name.
        -- For tail-recursive functions, the joinpoint ID is 0.
        jumpAttrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr argVarTypes) )
                , ( "target", IntAttr Nothing 0 )
                ]

        ( ctx2, jumpOp ) =
            Ops.mlirOp ctx1 "eco.jump"
                |> Ops.opBuilder.withOperands argVarNames
                |> Ops.opBuilder.withAttrs jumpAttrs
                |> Ops.opBuilder.isTerminator True
                |> Ops.opBuilder.build
    in
    -- eco.jump is a terminator - it does not produce a result value.
    -- INVARIANT: resultVar is meaningless when isTerminated=True, must not be used.
    { ops = argsOps ++ [ jumpOp ]
    , resultVar = "" -- INVARIANT: meaningless when isTerminated=True
    , resultType = Types.ecoValue
    , ctx = ctx2
    , isTerminated = True -- eco.jump is a terminator
    }



-- ====== IF GENERATION ======


{-| Generate if expressions using eco.case on Bool.

Compiles `if c1 then t1 else if c2 then t2 else ... final` to nested
eco.case operations on boolean conditions.

-}
generateIf : Ctx.Context -> List ( Mono.MonoExpr, Mono.MonoExpr ) -> Mono.MonoExpr -> ExprResult
generateIf ctx branches final =
    case branches of
        [] ->
            generateExpr ctx final

        ( condExpr, thenExpr ) :: restBranches ->
            let
                -- Evaluate condition to Bool
                condRes =
                    generateExpr ctx condExpr

                -- Ensure condition is i1 for scf.if/eco.case
                -- If the condition is eco.value (e.g., from a function call returning Bool),
                -- we need to unbox it to i1
                ( condUnboxOps, condVar, condCtx ) =
                    if Types.isEcoValueType condRes.resultType then
                        Intrinsics.unboxToType condRes.ctx condRes.resultVar I1

                    else
                        ( [], condRes.resultVar, condRes.ctx )

                -- All condition ops including any unboxing
                condOpsAll =
                    condRes.ops ++ condUnboxOps

                -- Generate then branch first to get its actual result type
                thenRes =
                    generateExpr condCtx thenExpr
            in
            -- Check if then branch is terminated (e.g., tail call with eco.jump).
            -- If so, we can't use scf.if which requires both branches to yield.
            -- Fall back to eco.case which supports terminated regions.
            if thenRes.isTerminated then
                generateIfWithTerminatedBranch condCtx condVar thenRes restBranches final condOpsAll

            else
                -- Then branch produces a value, check else branch
                let
                    -- Use the then branch's actual SSA type as the result type
                    resultMlirType =
                        thenRes.resultType

                    -- Coerce then result to target type if needed
                    ( thenCoerceOps, thenFinalVar, thenFinalCtx ) =
                        coerceResultToType thenRes.ctx thenRes.resultVar thenRes.resultType resultMlirType

                    ( ctx1, thenYieldOp ) =
                        Ops.scfYield thenFinalCtx thenFinalVar resultMlirType

                    thenRegion =
                        Ops.mkRegion [] (thenRes.ops ++ thenCoerceOps) thenYieldOp

                    -- Generate else branch (recursive if or final)
                    -- Use ctxForSiblingRegion to avoid leaking varMappings from then-branch
                    elseCtx =
                        Ctx.ctxForSiblingRegion condCtx ctx1

                    elseRes =
                        generateIf elseCtx restBranches final
                in
                if elseRes.isTerminated then
                    -- Else branch is terminated - use eco.case instead
                    generateIfWithTerminatedElse condRes.ctx condVar thenRes elseRes resultMlirType condRes.ops

                else
                    -- Normal case: both branches produce values, use scf.if
                    let
                        -- Coerce else result to match then branch's type
                        ( elseCoerceOps, elseFinalVar, elseFinalCtx ) =
                            coerceResultToType elseRes.ctx elseRes.resultVar elseRes.resultType resultMlirType

                        ( ctx2, elseYieldOp ) =
                            Ops.scfYield elseFinalCtx elseFinalVar resultMlirType

                        elseRegion =
                            Ops.mkRegion [] (elseRes.ops ++ elseCoerceOps) elseYieldOp

                        -- Allocate result variable for scf.if
                        ( ifResultVar, ctx2b ) =
                            Ctx.freshVar ctx2

                        -- scf.if with i1 condition directly (avoids eco.get_tag on embedded constants)
                        ( ctx3, ifOp ) =
                            Ops.scfIf ctx2b condVar ifResultVar thenRegion elseRegion resultMlirType
                    in
                    { ops = condOpsAll ++ [ ifOp ]
                    , resultVar = ifResultVar
                    , resultType = resultMlirType
                    , ctx = ctx3
                    , isTerminated = False
                    }


{-| Generate if-then-else using eco.case when the then branch is terminated.
-}
generateIfWithTerminatedBranch : Ctx.Context -> String -> ExprResult -> List ( Mono.MonoExpr, Mono.MonoExpr ) -> Mono.MonoExpr -> List MlirOp -> ExprResult
generateIfWithTerminatedBranch condCtx condVar thenRes restBranches final condOps =
    let
        -- Build then region - it already has a terminator (should be eco.yield)
        thenRegion =
            mkRegionFromOps thenRes.ops

        -- Generate else branch: use condCtx varMappings (not then-branch's)
        elseCtx =
            Ctx.ctxForSiblingRegion condCtx thenRes.ctx

        elseRes =
            generateIf elseCtx restBranches final

        -- Determine result type from else branch (then is terminated)
        resultMlirType =
            if elseRes.isTerminated then
                Types.ecoValue

            else
                elseRes.resultType

        -- Build else region
        ( elseRegion, ctxAfterElse ) =
            if elseRes.isTerminated then
                ( mkRegionFromOps elseRes.ops, elseRes.ctx )

            else
                let
                    ( coerceOps, finalVar, coerceCtx ) =
                        coerceResultToType elseRes.ctx elseRes.resultVar elseRes.resultType resultMlirType

                    -- Use eco.yield for case alternatives
                    ( yieldCtx, yieldOp ) =
                        Ops.ecoYield coerceCtx finalVar resultMlirType
                in
                ( Ops.mkRegion [] (elseRes.ops ++ coerceOps) yieldOp, yieldCtx )

        -- Allocate result variable for eco.case
        ( caseResultVar, ctxWithResult ) =
            Ctx.freshVar ctxAfterElse

        -- eco.case on i1: tag 1 for True (then), tag 0 for False (else)
        ( ctxFinal, caseOp ) =
            Ops.ecoCase ctxWithResult caseResultVar condVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] resultMlirType
    in
    -- eco.case produces an SSA result
    { ops = condOps ++ [ caseOp ]
    , resultVar = caseResultVar
    , resultType = resultMlirType
    , ctx = ctxFinal
    , isTerminated = False
    }


{-| Generate if-then-else using eco.case when the else branch is terminated.
The then branch has already been processed and yields a value.
-}
generateIfWithTerminatedElse : Ctx.Context -> String -> ExprResult -> ExprResult -> MlirType -> List MlirOp -> ExprResult
generateIfWithTerminatedElse _ condVar thenRes elseRes resultMlirType condOps =
    let
        -- Build then region with eco.yield (not terminated)
        ( thenCoerceOps, thenFinalVar, thenCoerceCtx ) =
            coerceResultToType thenRes.ctx thenRes.resultVar thenRes.resultType resultMlirType

        ( _, thenYieldOp ) =
            Ops.ecoYield thenCoerceCtx thenFinalVar resultMlirType

        thenRegion =
            Ops.mkRegion [] (thenRes.ops ++ thenCoerceOps) thenYieldOp

        -- Else region already has a terminator (should be eco.yield)
        elseRegion =
            mkRegionFromOps elseRes.ops

        -- Allocate result variable for eco.case
        ( caseResultVar, ctxWithResult ) =
            Ctx.freshVar elseRes.ctx

        -- eco.case on i1: tag 1 for True (then), tag 0 for False (else)
        ( ctxFinal, caseOp ) =
            Ops.ecoCase ctxWithResult caseResultVar condVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] resultMlirType
    in
    -- eco.case produces an SSA result
    { ops = condOps ++ [ caseOp ]
    , resultVar = caseResultVar
    , resultType = resultMlirType
    , ctx = ctxFinal
    , isTerminated = False
    }



-- ====== LET GENERATION ======


{-| Approximate reverse mapping from MlirType to MonoType.
Used for PendingLambda capture types where only MlirType is available.
Correctly round-trips: monoTypeToAbi (mlirTypeToApproxMonoType t) == t
for all ABI types (I64, F64, I32, ecoValue).
-}
mlirTypeToApproxMonoType : MlirType -> Mono.MonoType
mlirTypeToApproxMonoType mlirType =
    case mlirType of
        I64 ->
            Mono.MInt

        F64 ->
            Mono.MFloat

        I32 ->
            Mono.MChar

        _ ->
            Mono.MUnit


{-| Collect all names bound in a chain of nested Let expressions.
This is used to add placeholder mappings for mutually recursive definitions
before generating any closures.
-}
collectLetBoundNames : Mono.MonoExpr -> List Name.Name
collectLetBoundNames expr =
    case expr of
        Mono.MonoLet def body _ ->
            let
                defName =
                    case def of
                        Mono.MonoDef name _ ->
                            name

                        Mono.MonoTailDef name _ _ ->
                            name
            in
            defName :: collectLetBoundNames body

        _ ->
            []


{-| Add placeholder mappings for a list of names.
These placeholders allow closures to reference sibling functions
in mutually recursive let-rec definitions.

If a name already has a placeholder in currentLetSiblings (from an outer
let-rec group that created placeholders for the full chain), reuse that
mapping. This prevents orphaned SSA vars when nested generateLet calls
would otherwise create new placeholders for names already allocated by
the outer group. Only currentLetSiblings entries are reused, not
arbitrary varMappings (which could be from unrelated scopes like
function parameters or prior let bindings).
-}
addPlaceholderMappings : List Name.Name -> Ctx.Context -> Ctx.Context
addPlaceholderMappings names ctx =
    List.foldl
        (\name acc ->
            case Dict.get name acc.currentLetSiblings of
                Just _ ->
                    -- Already has a placeholder from outer let-rec group; reuse it
                    acc

                Nothing ->
                    let
                        ( ssaVar, acc1 ) =
                            Ctx.freshVar acc
                    in
                    Ctx.addVarMapping name ssaVar Types.ecoValue acc1
        )
        ctx
        names


{-| Generate MLIR code for a let expression.
-}
generateLet : Ctx.Context -> Mono.MonoDef -> Mono.MonoExpr -> ExprResult
generateLet ctx def body =
    -- For mutually recursive definitions, add placeholder mappings for all
    -- names in the Let chain before generating any closures.
    -- We also set currentLetSiblings so that closures created in this group
    -- capture the correct sibling environment.
    let
        boundNames =
            collectLetBoundNames (Mono.MonoLet def body Mono.MUnit)

        -- Save outer siblings for restoration on exit (lexical scoping)
        outerSiblings =
            ctx.currentLetSiblings

        -- Build placeholder mappings for the whole let-group
        groupVarMappings =
            addPlaceholderMappings boundNames ctx

        -- Only include the let-bound names in currentLetSiblings (not all varMappings).
        -- This prevents outer-scope variables from leaking into lambda siblingMappings,
        -- which would cause cross-function SSA references (CGEN_CLOSURE_003).
        letBoundSiblings =
            List.foldl
                (\name acc ->
                    case Dict.get name groupVarMappings.varMappings of
                        Just info ->
                            Dict.insert name info acc

                        Nothing ->
                            acc
                )
                Dict.empty
                boundNames

        ctxWithPlaceholders =
            { groupVarMappings | currentLetSiblings = letBoundSiblings }
    in
    case def of
        Mono.MonoDef name expr ->
            let
                -- Look up the placeholder SSA var installed by addPlaceholderMappings.
                -- This is "%name" with type !eco.value for each let-bound name.
                ( placeholderVar, _ ) =
                    Ctx.lookupVar ctxWithPlaceholders name

                -- Generate the bound expression with placeholders in scope.
                rawResult : ExprResult
                rawResult =
                    generateExpr ctxWithPlaceholders expr

                -- Force the bound expression's result SSA id to be the placeholder var.
                -- When the RHS produces ops, forceResultVar renames the result to the
                -- placeholder, so the defining op (e.g. eco.papCreate) directly defines
                -- the placeholder SSA var that sibling closures captured.
                --
                -- When the RHS produces NO ops (e.g. a simple variable reference),
                -- there is no defining op to rename, so we alias the let-bound name
                -- to the existing SSA var instead.
                -- Handle self-capturing closures (e.g., recursive helper in Array.foldr).
                -- If a papCreate uses the placeholder var as a capture operand,
                -- replace it with a Unit constant and mark the self-capture index.
                -- The C++ lowering will patch the closure to point to itself.
                ( fixedResult, _ ) =
                    if hasSelfCapture placeholderVar rawResult.ops then
                        let
                            ( unitVar, ctxWithUnit ) =
                                Ctx.freshVar rawResult.ctx

                            ( ctxWithUnit2, unitOp ) =
                                Ops.ecoConstantUnit ctxWithUnit unitVar

                            resultWithUnit =
                                { rawResult | ops = unitOp :: rawResult.ops, ctx = ctxWithUnit2 }
                        in
                        fixSelfCaptures placeholderVar unitVar ctxWithUnit2 resultWithUnit

                    else
                        ( rawResult, rawResult.ctx )

                ( exprResult, effectiveVar ) =
                    if List.isEmpty fixedResult.ops then
                        ( fixedResult, fixedResult.resultVar )

                    else if not (isVarDefinedInOps fixedResult.resultVar fixedResult.ops) then
                        -- The result var is from an outer scope (not defined by this
                        -- expression's ops), e.g. Debug.log returning an already-boxed
                        -- value. Renaming would break SSA references, so just alias.
                        ( fixedResult, fixedResult.resultVar )

                    else
                        ( forceResultVar placeholderVar fixedResult, placeholderVar )

                -- Update varMappings for this name to use the effective SSA var,
                -- with the actual result type.
                ctx1 : Ctx.Context
                ctx1 =
                    Ctx.addVarMapping name effectiveVar exprResult.resultType exprResult.ctx
                        |> Ctx.addDecoderExpr name expr
                        |> trackExternBoxedVar name expr

                bodyResult : ExprResult
                bodyResult =
                    generateExpr ctx1 body

                -- Restore outer siblings on exit from the let-rec group
                bodyCtx : Ctx.Context
                bodyCtx =
                    bodyResult.ctx

                ctxOut : Ctx.Context
                ctxOut =
                    { bodyCtx | currentLetSiblings = outerSiblings }

                -- Propagate isTerminated when:
                -- 1. The bound expression is terminated (eco.case, eco.jump), AND
                --    the body is trivial (just returning the let-bound variable, so no body ops)
                -- 2. OR the body itself is terminated
                -- In these cases, the case alternatives already contain the correct returns.
                finalIsTerminated =
                    (exprResult.isTerminated && List.isEmpty bodyResult.ops) || bodyResult.isTerminated
            in
            { ops = exprResult.ops ++ bodyResult.ops
            , resultVar = bodyResult.resultVar
            , resultType = bodyResult.resultType
            , ctx = ctxOut
            , isTerminated = finalIsTerminated
            }

        Mono.MonoTailDef name params tailBody ->
            -- For local tail-recursive functions:
            -- 1. Find free variables of the body (captures)
            -- 2. Create a PendingLambda with isTailRecursive=True
            -- 3. Generate eco.papCreate to define %name
            -- 4. Apply forceResultVar to match the placeholder
            -- 5. Generate the let body
            let
                -- Look up the placeholder SSA var
                ( placeholderVar, _ ) =
                    Ctx.lookupVar ctxWithPlaceholders name

                -- Find free variables in the tail body.
                -- Exclude params and function name (they are bound, not captured).
                paramNames =
                    List.map Tuple.first params

                boundSet =
                    EverySet.fromList identity (name :: paramNames)

                freeVarNames =
                    Closure.findFreeLocals boundSet tailBody

                -- Separate free vars into siblings (in currentLetSiblings) and captures
                captureNames =
                    List.filter
                        (\n -> not (Dict.member n ctxWithPlaceholders.currentLetSiblings))
                        freeVarNames
                        |> Set.fromList
                        |> Set.toList

                -- Look up capture SSA vars and MlirTypes from varMappings
                captureInfos =
                    List.filterMap
                        (\capName ->
                            case Dict.get capName ctxWithPlaceholders.varMappings of
                                Just info ->
                                    Just ( capName, info.ssaVar, info.mlirType )

                                Nothing ->
                                    Nothing
                        )
                        captureNames

                -- Convert captures to PendingLambda format (name, approxMonoType)
                captureTypes =
                    List.map
                        (\( capName, _, mlirTy ) -> ( capName, mlirTypeToApproxMonoType mlirTy ))
                        captureInfos

                captureVarNames =
                    List.map (\( _, ssaVar, _ ) -> ssaVar) captureInfos

                captureMlirTypes =
                    List.map (\( _, _, mlirTy ) -> mlirTy) captureInfos

                -- Generate a unique function name using the opId counter
                tailFuncName =
                    "_tail_" ++ name ++ "_" ++ String.fromInt ctxWithPlaceholders.nextOpId

                -- Create the PendingLambda (isTailRecursive = True)
                pendingLambda : Ctx.PendingLambda
                pendingLambda =
                    { name = tailFuncName
                    , captures = captureTypes
                    , params = params
                    , body = tailBody
                    , returnType = Mono.typeOf tailBody
                    , siblingMappings = ctxWithPlaceholders.currentLetSiblings
                    , isTailRecursive = True
                    }

                ctx1 =
                    { ctxWithPlaceholders
                        | pendingLambdas = pendingLambda :: ctxWithPlaceholders.pendingLambdas
                    }

                -- Generate eco.papCreate to define the closure value
                hasCaptures =
                    not (List.isEmpty captureInfos)

                numCaptured =
                    List.length captureInfos

                arity =
                    numCaptured + List.length params

                functionName =
                    if hasCaptures then
                        tailFuncName ++ "$clo"

                    else
                        tailFuncName

                ( resultVar, ctx2 ) =
                    Ctx.freshVar ctx1

                unboxedBitmap =
                    List.indexedMap
                        (\i mlirTy ->
                            if Types.isUnboxable mlirTy then
                                Bitwise.shiftLeftBy i 1

                            else
                                0
                        )
                        captureMlirTypes
                        |> List.foldl Bitwise.or 0

                operandTypesAttr =
                    if List.isEmpty captureMlirTypes then
                        Dict.empty

                    else
                        Dict.singleton "_operand_types"
                            (ArrayAttr Nothing (List.map TypeAttr captureMlirTypes))

                fastEvaluatorAttr =
                    if hasCaptures then
                        Dict.singleton "_fast_evaluator" (SymbolRefAttr (tailFuncName ++ "$cap"))

                    else
                        Dict.empty

                papAttrs =
                    Dict.union fastEvaluatorAttr
                        (Dict.union operandTypesAttr
                            (Dict.fromList
                                [ ( "function", SymbolRefAttr functionName )
                                , ( "arity", IntAttr Nothing arity )
                                , ( "num_captured", IntAttr Nothing numCaptured )
                                , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                                ]
                            )
                        )

                ( ctx3, papOp ) =
                    Ops.mlirOp ctx2 "eco.papCreate"
                        |> Ops.opBuilder.withOperands captureVarNames
                        |> Ops.opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
                        |> Ops.opBuilder.withAttrs papAttrs
                        |> Ops.opBuilder.build

                -- Force result to placeholder var
                rawResult =
                    { ops = [ papOp ]
                    , resultVar = resultVar
                    , resultType = Types.ecoValue
                    , ctx = ctx3
                    , isTerminated = False
                    }

                exprResult =
                    forceResultVar placeholderVar rawResult

                -- Update varMappings for the let body
                ctx4 =
                    Ctx.addVarMapping name placeholderVar exprResult.resultType exprResult.ctx

                -- Generate the let body
                bodyResult =
                    generateExpr ctx4 body

                bodyCtx =
                    bodyResult.ctx

                ctxOut =
                    { bodyCtx | currentLetSiblings = outerSiblings }

                finalIsTerminated =
                    (exprResult.isTerminated && List.isEmpty bodyResult.ops) || bodyResult.isTerminated
            in
            { ops = exprResult.ops ++ bodyResult.ops
            , resultVar = bodyResult.resultVar
            , resultType = bodyResult.resultType
            , ctx = ctxOut
            , isTerminated = finalIsTerminated
            }



-- ====== DESTRUCT GENERATION ======


generateDestruct : Ctx.Context -> Mono.MonoDestructor -> Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateDestruct ctx (Mono.MonoDestructor name path _) body _ =
    let
        -- Use the path's actual result type for generating the destructor.
        -- The path's MonoIndex/MonoField/etc. nodes carry the correctly-specialized
        -- result type (e.g., MInt), whereas the destructor's monoType may be an
        -- unsubstituted type variable (MVar) due to type variable name mismatches
        -- between the function signature and the type definition.
        --
        -- For example, in Result.andThen:
        --   - Function signature uses type vars: a, b, x
        --   - Result type definition uses: error, value
        --   - The destructor's monoType may be MVar "value" (not in substitution)
        --   - But the path's resultType is correctly MInt
        --
        -- By using the path's type, we ensure correct primitive types are used.
        pathResultType =
            Mono.getMonoPathType path

        -- Convert to MLIR type
        destructorMlirType =
            Types.monoTypeToAbi pathResultType

        -- Use the path's type for path generation
        targetType =
            destructorMlirType

        ( pathOps, pathVar, ctx1 ) =
            Patterns.generateMonoPath ctx path targetType

        -- Save the previous mapping for this name (if any) so we can restore it
        -- after the body. MonoDestruct introduces a scoped binding that should not
        -- leak into sibling expressions.
        previousMapping =
            Dict.get name ctx1.varMappings

        -- Use mapping with the path's type
        ctx2 : Ctx.Context
        ctx2 =
            Ctx.addVarMapping name pathVar targetType ctx1

        bodyResult : ExprResult
        bodyResult =
            generateExpr ctx2 body

        -- Restore the previous variable mapping for 'name' so that sibling
        -- expressions (processed after this destruct) see the outer binding,
        -- not the destructured one.
        bodyCtx =
            bodyResult.ctx

        restoredCtx =
            case previousMapping of
                Just oldInfo ->
                    { bodyCtx | varMappings = Dict.insert name oldInfo bodyCtx.varMappings }

                Nothing ->
                    { bodyCtx | varMappings = Dict.remove name bodyCtx.varMappings }
    in
    { ops = pathOps ++ bodyResult.ops
    , resultVar = bodyResult.resultVar
    , resultType = bodyResult.resultType
    , ctx = restoredCtx
    , isTerminated = bodyResult.isTerminated
    }



-- ====== CASE GENERATION ======


{-| Generate the decision tree with jump expression inlining (yield-based mode).
Instead of generating eco.jump to joinpoints, this version inlines branch bodies
directly when encountering Mono.Jump. This enables single-block alternative regions
required for SCF lowering.
-}
generateDeciderWithJumps : Ctx.Context -> Mono.Decider Mono.MonoChoice -> Array (Maybe Mono.MonoExpr) -> MlirType -> ExprResult
generateDeciderWithJumps ctx decider jumpLookup resultTy =
    case decider of
        Mono.Leaf choice ->
            generateLeafWithJumps ctx choice jumpLookup resultTy

        Mono.Chain testChain success failure ->
            generateChainWithJumps ctx testChain success failure jumpLookup resultTy

        Mono.FanOut path edges fallback ->
            generateFanOutWithJumps ctx path edges fallback jumpLookup resultTy


{-| Generate code for a Leaf node with jump inlining (yield-based mode).
Instead of emitting eco.jump to joinpoints, this looks up the branch expression
and inlines it directly. This enables single-block alternative regions.
-}
generateLeafWithJumps : Ctx.Context -> Mono.MonoChoice -> Array (Maybe Mono.MonoExpr) -> MlirType -> ExprResult
generateLeafWithJumps ctx choice jumpLookup resultTy =
    case choice of
        Mono.Inline branchExpr ->
            -- Same as generateLeaf - evaluate and yield
            let
                branchRes =
                    generateExpr ctx branchExpr
            in
            if branchRes.isTerminated then
                -- Only short-circuit if already terminated with eco.yield
                case List.reverse branchRes.ops of
                    lastOp :: _ ->
                        if isValidCaseTerminator lastOp then
                            branchRes

                        else if branchRes.resultVar == "" then
                            -- Non-yield terminator with no result value - deep codegen bug,
                            -- let mkCaseRegionFromDecider crash with a good message
                            branchRes

                        else
                            -- Non-yield terminator (e.g., eco.return) but we have a resultVar,
                            -- wrap with eco.yield to ensure valid case alternative
                            let
                                actualTy =
                                    branchRes.resultType

                                ( coerceOps, finalVar, ctx1 ) =
                                    coerceResultToType branchRes.ctx branchRes.resultVar actualTy resultTy

                                ( ctx2, yieldOp ) =
                                    Ops.ecoYield ctx1 finalVar resultTy
                            in
                            { ops = branchRes.ops ++ coerceOps ++ [ yieldOp ]
                            , resultVar = finalVar
                            , resultType = resultTy
                            , ctx = ctx2
                            , isTerminated = True
                            }

                    [] ->
                        branchRes

            else
                let
                    actualTy =
                        branchRes.resultType

                    ( coerceOps, finalVar, ctx1 ) =
                        coerceResultToType branchRes.ctx branchRes.resultVar actualTy resultTy

                    ( ctx2, yieldOp ) =
                        Ops.ecoYield ctx1 finalVar resultTy
                in
                { ops = branchRes.ops ++ coerceOps ++ [ yieldOp ]
                , resultVar = finalVar
                , resultType = resultTy
                , ctx = ctx2
                , isTerminated = True
                }

        Mono.Jump index ->
            -- Yield-based mode: inline the branch body instead of jumping
            case Array.get index jumpLookup |> Maybe.andThen identity of
                Just branchExpr ->
                    -- Inline the branch expression and yield
                    let
                        branchRes =
                            generateExpr ctx branchExpr
                    in
                    if branchRes.isTerminated then
                        -- Only short-circuit if already terminated with eco.yield
                        case List.reverse branchRes.ops of
                            lastOp :: _ ->
                                if isValidCaseTerminator lastOp then
                                    branchRes

                                else if branchRes.resultVar == "" then
                                    -- Non-yield terminator with no result value - deep codegen bug,
                                    -- let mkCaseRegionFromDecider crash with a good message
                                    branchRes

                                else
                                    -- Non-yield terminator (e.g., eco.return) but we have a resultVar,
                                    -- wrap with eco.yield to ensure valid case alternative
                                    let
                                        actualTy =
                                            branchRes.resultType

                                        ( coerceOps, finalVar, ctx1 ) =
                                            coerceResultToType branchRes.ctx branchRes.resultVar actualTy resultTy

                                        ( ctx2, yieldOp ) =
                                            Ops.ecoYield ctx1 finalVar resultTy
                                    in
                                    { ops = branchRes.ops ++ coerceOps ++ [ yieldOp ]
                                    , resultVar = finalVar
                                    , resultType = resultTy
                                    , ctx = ctx2
                                    , isTerminated = True
                                    }

                            [] ->
                                branchRes

                    else
                        let
                            actualTy =
                                branchRes.resultType

                            ( coerceOps, finalVar, ctx1 ) =
                                coerceResultToType branchRes.ctx branchRes.resultVar actualTy resultTy

                            ( ctx2, yieldOp ) =
                                Ops.ecoYield ctx1 finalVar resultTy
                        in
                        { ops = branchRes.ops ++ coerceOps ++ [ yieldOp ]
                        , resultVar = finalVar
                        , resultType = resultTy
                        , ctx = ctx2
                        , isTerminated = True
                        }

                Nothing ->
                    -- Jump index not found - this shouldn't happen with valid IR
                    crash ("generateLeafWithJumps: Jump index " ++ String.fromInt index ++ " not found in jumpLookup")


{-| Generate code for a Chain node with jump inlining (yield-based mode).
-}
generateChainWithJumps : Ctx.Context -> List ( Mono.MonoDtPath, DT.Test ) -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice -> Array (Maybe Mono.MonoExpr) -> MlirType -> ExprResult
generateChainWithJumps ctx testChain success failure jumpLookup resultTy =
    case testChain of
        [ ( path, Test.IsBool True ) ] ->
            generateChainForBoolADTWithJumps ctx path success failure jumpLookup resultTy

        _ ->
            generateChainGeneralWithJumps ctx testChain success failure jumpLookup resultTy


{-| Special handling for Bool ADT pattern matching with jump inlining.
-}
generateChainForBoolADTWithJumps : Ctx.Context -> Mono.MonoDtPath -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice -> Array (Maybe Mono.MonoExpr) -> MlirType -> ExprResult
generateChainForBoolADTWithJumps ctx path success failure jumpLookup resultTy =
    let
        ( pathOps, boolVar, ctx1 ) =
            Patterns.generateMonoDtPath ctx path I1

        thenRes =
            generateDeciderWithJumps ctx1 success jumpLookup resultTy

        ( thenRegion, ctx1a ) =
            mkCaseRegionFromDecider thenRes resultTy

        ctxForElse =
            Ctx.ctxForSiblingRegion ctx1 ctx1a

        elseRes =
            generateDeciderWithJumps ctxForElse failure jumpLookup resultTy

        ( elseRegion, ctx1b ) =
            mkCaseRegionFromDecider elseRes resultTy

        ( caseResultVar, ctxWithResult ) =
            Ctx.freshVar ctx1b

        ( ctx2, caseOp ) =
            Ops.ecoCase ctxWithResult caseResultVar boolVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] resultTy
    in
    { ops = pathOps ++ [ caseOp ]
    , resultVar = caseResultVar
    , resultType = resultTy
    , ctx = ctx2
    , isTerminated = False
    }


{-| General chain case with jump inlining.
-}
generateChainGeneralWithJumps : Ctx.Context -> List ( Mono.MonoDtPath, DT.Test ) -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice -> Array (Maybe Mono.MonoExpr) -> MlirType -> ExprResult
generateChainGeneralWithJumps ctx testChain success failure jumpLookup resultTy =
    let
        ( condOps, condVar, ctx1 ) =
            Patterns.generateMonoChainCondition ctx testChain

        thenRes =
            generateDeciderWithJumps ctx1 success jumpLookup resultTy

        ( thenRegion, ctx1a ) =
            mkCaseRegionFromDecider thenRes resultTy

        ctxForElse =
            Ctx.ctxForSiblingRegion ctx1 ctx1a

        elseRes =
            generateDeciderWithJumps ctxForElse failure jumpLookup resultTy

        ( elseRegion, ctx1b ) =
            mkCaseRegionFromDecider elseRes resultTy

        ( caseResultVar, ctxWithResult ) =
            Ctx.freshVar ctx1b

        ( ctx2, caseOp ) =
            Ops.ecoCase ctxWithResult caseResultVar condVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] resultTy
    in
    { ops = condOps ++ [ caseOp ]
    , resultVar = caseResultVar
    , resultType = resultTy
    , ctx = ctx2
    , isTerminated = False
    }


{-| Check if FanOut is a Bool pattern match (has IsBool True or IsBool False tests).
-}
isBoolFanOut : List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Bool
isBoolFanOut edges =
    case edges of
        [] ->
            False

        ( test, _ ) :: _ ->
            case test of
                Test.IsBool _ ->
                    True

                _ ->
                    False


{-| Find True and False branches from Bool FanOut edges.
-}
findBoolBranches : List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Mono.Decider Mono.MonoChoice -> ( Mono.Decider Mono.MonoChoice, Mono.Decider Mono.MonoChoice )
findBoolBranches edges fallback =
    let
        findBranch target =
            edges
                |> List.filter
                    (\( test, _ ) ->
                        case test of
                            Test.IsBool b ->
                                b == target

                            _ ->
                                False
                    )
                |> List.head
                |> Maybe.map Tuple.second
                |> Maybe.withDefault fallback
    in
    ( findBranch True, findBranch False )


{-| Extract string pattern strictly - crash if not IsStr.
This ensures we never silently drop patterns in string fanouts.
-}
extractStringPatternStrict : DT.Test -> String
extractStringPatternStrict test =
    case test of
        Test.IsStr s ->
            s

        _ ->
            crash "CGEN: expected Test.IsStr in string fanout, but got non-string test"


{-| Generate code for a FanOut node with jump inlining (yield-based mode).
-}
generateFanOutWithJumps : Ctx.Context -> Mono.MonoDtPath -> List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Mono.Decider Mono.MonoChoice -> Array (Maybe Mono.MonoExpr) -> MlirType -> ExprResult
generateFanOutWithJumps ctx path edges fallback jumpLookup resultTy =
    if isBoolFanOut edges then
        generateBoolFanOutWithJumps ctx path edges fallback jumpLookup resultTy

    else
        generateFanOutGeneralWithJumps ctx path edges fallback jumpLookup resultTy


{-| Bool FanOut with jump inlining.
-}
generateBoolFanOutWithJumps : Ctx.Context -> Mono.MonoDtPath -> List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Mono.Decider Mono.MonoChoice -> Array (Maybe Mono.MonoExpr) -> MlirType -> ExprResult
generateBoolFanOutWithJumps ctx path edges fallback jumpLookup resultTy =
    let
        ( pathOps, boolVar, ctx1 ) =
            Patterns.generateMonoDtPath ctx path I1

        ( trueBranch, falseBranch ) =
            findBoolBranches edges fallback

        thenRes =
            generateDeciderWithJumps ctx1 trueBranch jumpLookup resultTy

        ( thenRegion, ctx1a ) =
            mkCaseRegionFromDecider thenRes resultTy

        ctxForElse =
            Ctx.ctxForSiblingRegion ctx1 ctx1a

        elseRes =
            generateDeciderWithJumps ctxForElse falseBranch jumpLookup resultTy

        ( elseRegion, ctx1b ) =
            mkCaseRegionFromDecider elseRes resultTy

        ( caseResultVar, ctxWithResult ) =
            Ctx.freshVar ctx1b

        ( ctx2, caseOp ) =
            Ops.ecoCase ctxWithResult caseResultVar boolVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] resultTy
    in
    { ops = pathOps ++ [ caseOp ]
    , resultVar = caseResultVar
    , resultType = resultTy
    , ctx = ctx2
    , isTerminated = False
    }


{-| General FanOut with jump inlining.
-}
generateFanOutGeneralWithJumps : Ctx.Context -> Mono.MonoDtPath -> List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Mono.Decider Mono.MonoChoice -> Array (Maybe Mono.MonoExpr) -> MlirType -> ExprResult
generateFanOutGeneralWithJumps ctx path edges fallback jumpLookup resultTy =
    let
        edgeTests =
            List.map Tuple.first edges

        caseKind =
            case edgeTests of
                firstTest :: _ ->
                    Patterns.caseKindFromTest firstTest

                [] ->
                    "ctor"

        scrutineeType =
            Patterns.scrutineeTypeFromCaseKind caseKind

        ( pathOps, scrutineeVar, ctx1 ) =
            Patterns.generateMonoDtPath ctx path scrutineeType

        ( tags, stringPatterns ) =
            if caseKind == "str" then
                let
                    edgeCount =
                        List.length edges

                    altCount =
                        edgeCount + 1

                    patterns =
                        edges
                            |> List.map Tuple.first
                            |> List.map extractStringPatternStrict

                    sequentialTags =
                        List.range 0 (altCount - 1)
                in
                ( sequentialTags, Just patterns )

            else
                let
                    edgeTags =
                        List.map (\( test, _ ) -> Patterns.testToTagInt test) edges

                    fallbackTag =
                        Patterns.computeFallbackTag edgeTests
                in
                ( edgeTags ++ [ fallbackTag ], Nothing )

        ( edgeRegionsReversed, ctx2 ) =
            List.foldl
                (\( _, subTree ) ( accRegions, accCtx ) ->
                    let
                        branchCtx =
                            Ctx.ctxForSiblingRegion ctx1 accCtx

                        subRes =
                            generateDeciderWithJumps branchCtx subTree jumpLookup resultTy

                        ( region, ctxAfterRegion ) =
                            mkCaseRegionFromDecider subRes resultTy
                    in
                    ( region :: accRegions, ctxAfterRegion )
                )
                ( [], ctx1 )
                edges

        edgeRegions =
            List.reverse edgeRegionsReversed

        fallbackCtx =
            Ctx.ctxForSiblingRegion ctx1 ctx2

        fallbackRes =
            generateDeciderWithJumps fallbackCtx fallback jumpLookup resultTy

        ( fallbackRegion, ctx2a ) =
            mkCaseRegionFromDecider fallbackRes resultTy

        allRegions =
            edgeRegions ++ [ fallbackRegion ]

        ( caseResultVar, ctxWithResult ) =
            Ctx.freshVar ctx2a

        ( ctx3, caseOp ) =
            case stringPatterns of
                Just patterns ->
                    Ops.ecoCaseString ctxWithResult caseResultVar scrutineeVar scrutineeType tags patterns allRegions resultTy

                Nothing ->
                    Ops.ecoCase ctxWithResult caseResultVar scrutineeVar scrutineeType caseKind tags allRegions resultTy
    in
    { ops = pathOps ++ [ caseOp ]
    , resultVar = caseResultVar
    , resultType = resultTy
    , ctx = ctx3
    , isTerminated = False
    }


{-| Helper to build a region from a list of ops (where the last op is the terminator).
-}
mkRegionFromOps : List MlirOp -> MlirRegion
mkRegionFromOps ops =
    case List.reverse ops of
        [] ->
            -- Empty region - crash, this indicates a codegen bug
            crash "mkRegionFromOps: empty ops - region must have terminator"

        terminator :: restReversed ->
            MlirRegion
                { entry = { args = [], body = List.reverse restReversed, terminator = terminator }
                , blocks = OrderedDict.empty
                }


{-| Check if an op is a valid terminator for eco.case alternative regions.
eco.case alternatives must terminate with eco.yield (not eco.return).
-}
isValidCaseTerminator : MlirOp -> Bool
isValidCaseTerminator op =
    op.name == "eco.yield"


{-| Create a region from an ExprResult for eco.case alternatives.

This is the single choke-point that ensures all case alternatives end with eco.yield.
If the ExprResult is already terminated (ends with eco.yield), use it directly.
Otherwise, wrap the value-producing expression with eco.yield.

This handles:

  - Leaf expressions that already have eco.yield
  - Nested eco.case (value-producing) that needs wrapping
  - Any other value-producing expression

-}
mkCaseRegionFromDecider : ExprResult -> MlirType -> ( MlirRegion, Ctx.Context )
mkCaseRegionFromDecider exprRes resultTy =
    case List.reverse exprRes.ops of
        [] ->
            crash "mkCaseRegionFromDecider: empty ops - decider must produce ops"

        lastOp :: _ ->
            if isValidCaseTerminator lastOp then
                -- Already terminated with eco.yield, use as-is
                ( mkRegionFromOps exprRes.ops, exprRes.ctx )

            else if exprRes.resultVar == "" then
                -- Defensive: non-yield terminator with empty resultVar indicates
                -- a control-flow op (e.g., eco.jump) that shouldn't be wrapped
                crash
                    ("mkCaseRegionFromDecider: non-yield terminator '"
                        ++ lastOp.name
                        ++ "' with empty resultVar; "
                        ++ "this indicates a codegen bug (e.g., eco.return or eco.jump leaked into a case alternative)"
                    )

            else
                -- Value-producing expression (e.g., nested eco.case) - wrap with eco.yield
                let
                    -- Coerce result to expected type if needed
                    ( coerceOps, finalVar, ctx1 ) =
                        coerceResultToType exprRes.ctx exprRes.resultVar exprRes.resultType resultTy

                    -- Emit eco.yield to terminate the alternative
                    ( ctx2, yieldOp ) =
                        Ops.ecoYield ctx1 finalVar resultTy
                in
                ( mkRegionFromOps (exprRes.ops ++ coerceOps ++ [ yieldOp ]), ctx2 )


{-| Generate case expression control flow.

This is the main entry point for case expressions. It:

1.  Emits joinpoints for shared branches
2.  Generates the decision tree control flow (eco.case ops)
3.  Returns ExprResult with the case result (eco.case is value-producing)

eco.case is a value-producing expression that yields results via eco.yield
inside each alternative. The EcoControlFlowToSCF pass transforms eco.case
into scf.if/scf.index\_switch.

-}
generateCase : Ctx.Context -> Name.Name -> Name.Name -> Mono.Decider Mono.MonoChoice -> List ( Int, Mono.MonoExpr ) -> Mono.MonoType -> ExprResult
generateCase ctx _ root decider jumps resultMonoType =
    let
        resultMlirType =
            Types.monoTypeToAbi resultMonoType

        -- Build jump lookup for inlining shared branches (yield-based mode)
        -- Instead of emitting joinpoints, we inline branch bodies directly
        jumpLookup =
            pairsToSparseArray jumps

        -- eco.case is now a value-producing expression
        -- Pass jumpLookup so Mono.Jump can inline branch bodies
        decisionResult =
            generateDeciderWithJumps ctx decider jumpLookup resultMlirType
    in
    -- eco.case produces an SSA result through eco.yield in alternatives
    { ops = decisionResult.ops
    , resultVar = decisionResult.resultVar
    , resultType = resultMlirType
    , ctx = decisionResult.ctx
    , isTerminated = False
    }



-- ====== RECORD GENERATION ======


{-| Generate MLIR code to create a record.
-}
generateRecordCreate : Ctx.Context -> List Mono.MonoExpr -> Types.RecordLayout -> Mono.MonoType -> ExprResult
generateRecordCreate ctx fields layout recordType =
    -- Register the record type for the type graph
    let
        ( _, ctxWithType ) =
            Ctx.getOrCreateTypeIdForMonoType recordType ctx
    in
    -- Empty records must use eco.constant EmptyRec (invariant: never heap-allocated)
    if layout.fieldCount == 0 then
        let
            ( resultVar, ctx1 ) =
                Ctx.freshVar ctxWithType

            ( ctx2, emptyRecOp ) =
                Ops.ecoConstantEmptyRec ctx1 resultVar
        in
        { ops = [ emptyRecOp ]
        , resultVar = resultVar
        , resultType = Types.ecoValue
        , ctx = ctx2
        , isTerminated = False
        }

    else
        let
            -- Use generateExprListTyped to get actual SSA types
            ( fieldsOps, fieldVarsWithTypes, ctx1 ) =
                generateExprListTyped ctxWithType fields

            -- Box fields that need to be boxed (layout says boxed, but expression is primitive)
            ( boxOpsReversed, boxedFieldVarsReversed, ctx2 ) =
                List.foldl
                    (\( ( var, ssaType ), fieldInfo ) ( opsAcc, varsAcc, ctxAcc ) ->
                        if fieldInfo.isUnboxed then
                            -- Field is stored unboxed, use as-is
                            ( opsAcc, var :: varsAcc, ctxAcc )

                        else
                            -- Field should be boxed - box using actual SSA type
                            let
                                ( moreOps, boxedVar, newCtx ) =
                                    boxToEcoValue ctxAcc var ssaType
                            in
                            ( List.reverse moreOps ++ opsAcc, boxedVar :: varsAcc, newCtx )
                    )
                    ( [], [], ctx1 )
                    (List.map2 Tuple.pair fieldVarsWithTypes layout.fields)

            boxOps =
                List.reverse boxOpsReversed

            boxedFieldVars =
                List.reverse boxedFieldVarsReversed

            ( resultVar, ctx3 ) =
                Ctx.freshVar ctx2

            fieldVarPairs : List ( String, MlirType )
            fieldVarPairs =
                List.map2
                    (\v field ->
                        ( v
                        , if field.isUnboxed then
                            Types.monoTypeToAbi field.monoType

                          else
                            Types.ecoValue
                        )
                    )
                    boxedFieldVars
                    layout.fields

            -- Use eco.construct.record for records
            ( ctx4, constructOp ) =
                Ops.ecoConstructRecord ctx3 resultVar fieldVarPairs layout.fieldCount layout.unboxedBitmap
        in
        { ops = fieldsOps ++ boxOps ++ [ constructOp ]
        , resultVar = resultVar
        , resultType = Types.ecoValue
        , ctx = ctx4
        , isTerminated = False
        }


{-| Generate MLIR code to access a record field.
-}
generateRecordAccess : Ctx.Context -> Mono.MonoExpr -> Name.Name -> Int -> Bool -> Mono.MonoType -> ExprResult
generateRecordAccess ctx record _ index isUnboxed fieldType =
    let
        recordResult : ExprResult
        recordResult =
            generateExpr ctx record

        ( projectVar, ctx1 ) =
            Ctx.freshVar recordResult.ctx

        -- Determine the MLIR type for the field
        fieldMlirType =
            Types.monoTypeToAbi fieldType
    in
    if isUnboxed then
        -- Field is stored unboxed - project directly to the primitive type
        let
            ( ctx2, projectOp ) =
                Ops.ecoProjectRecord ctx1 projectVar index fieldMlirType recordResult.resultVar
        in
        { ops = recordResult.ops ++ [ projectOp ]
        , resultVar = projectVar
        , resultType = fieldMlirType
        , ctx = ctx2
        , isTerminated = False
        }

    else if Types.isEcoValueType fieldMlirType then
        -- Field is boxed and semantic type is also !eco.value - just project
        let
            ( ctx2, projectOp ) =
                Ops.ecoProjectRecord ctx1 projectVar index Types.ecoValue recordResult.resultVar
        in
        { ops = recordResult.ops ++ [ projectOp ]
        , resultVar = projectVar
        , resultType = Types.ecoValue
        , ctx = ctx2
        , isTerminated = False
        }

    else
        -- Field is stored boxed but semantic type is primitive
        -- Project to get !eco.value, then unbox to primitive type
        let
            ( ctx2, projectOp ) =
                Ops.ecoProjectRecord ctx1 projectVar index Types.ecoValue recordResult.resultVar

            ( unboxOps, unboxedVar, ctx3 ) =
                Intrinsics.unboxToType ctx2 projectVar fieldMlirType
        in
        { ops = recordResult.ops ++ [ projectOp ] ++ unboxOps
        , resultVar = unboxedVar
        , resultType = fieldMlirType
        , ctx = ctx3
        , isTerminated = False
        }


{-| Generate MLIR code to update record fields.
-}
generateRecordUpdate : Ctx.Context -> Mono.MonoExpr -> List ( Int, Mono.MonoExpr ) -> Types.RecordLayout -> Mono.MonoType -> ExprResult
generateRecordUpdate ctx record updates layout _ =
    let
        -- Step 1: Evaluate the original record once
        recordResult : ExprResult
        recordResult =
            generateExpr ctx record
    in
    -- Step 2: Handle empty record edge case (CGEN_018)
    if layout.fieldCount == 0 then
        recordResult

    else
        let
            -- Step 3: Build update array (field index -> update expression)
            updateArr : Array (Maybe Mono.MonoExpr)
            updateArr =
                pairsToSparseArray updates

            -- Step 4: Process each field in layout order
            ( fieldVarsAndTypesReversed, allOpsReversed, finalCtx ) =
                List.foldl
                    (\fieldInfo ( accVarsTypes, accOps, accCtx ) ->
                        let
                            -- Determine storage type for this field
                            storageType =
                                if fieldInfo.isUnboxed then
                                    Types.monoTypeToAbi fieldInfo.monoType

                                else
                                    Types.ecoValue
                        in
                        case Array.get fieldInfo.index updateArr |> Maybe.andThen identity of
                            Just updateExpr ->
                                -- Field is being updated: evaluate expression and coerce
                                let
                                    exprResult =
                                        generateExpr accCtx updateExpr

                                    ( coerceOps, coercedVar, ctxAfterCoerce ) =
                                        coerceResultToType exprResult.ctx exprResult.resultVar exprResult.resultType storageType
                                in
                                ( ( coercedVar, storageType ) :: accVarsTypes
                                , List.reverse coerceOps ++ List.reverse exprResult.ops ++ accOps
                                , ctxAfterCoerce
                                )

                            Nothing ->
                                -- Field not updated: project from original record
                                let
                                    ( projectVar, ctxProj1 ) =
                                        Ctx.freshVar accCtx

                                    ( ctxProj2, projectOp ) =
                                        Ops.ecoProjectRecord ctxProj1 projectVar fieldInfo.index storageType recordResult.resultVar
                                in
                                ( ( projectVar, storageType ) :: accVarsTypes
                                , projectOp :: accOps
                                , ctxProj2
                                )
                    )
                    ( [], List.reverse recordResult.ops, recordResult.ctx )
                    layout.fields

            fieldVarsAndTypes =
                List.reverse fieldVarsAndTypesReversed

            allOps =
                List.reverse allOpsReversed

            -- Step 5: Construct the new record
            ( resultVar, ctx1 ) =
                Ctx.freshVar finalCtx

            ( ctx2, constructOp ) =
                Ops.ecoConstructRecord ctx1 resultVar fieldVarsAndTypes layout.fieldCount layout.unboxedBitmap
        in
        { ops = allOps ++ [ constructOp ]
        , resultVar = resultVar
        , resultType = Types.ecoValue
        , ctx = ctx2
        , isTerminated = False
        }



-- ====== TUPLE GENERATION ======


{-| Generate MLIR code to create a tuple.
-}
generateTupleCreate : Ctx.Context -> List Mono.MonoExpr -> Types.TupleLayout -> Mono.MonoType -> ExprResult
generateTupleCreate ctx elements layout tupleType =
    -- Register the tuple type for the type graph
    let
        ( _, ctxWithType ) =
            Ctx.getOrCreateTypeIdForMonoType tupleType ctx

        -- Use generateExprListTyped to get actual SSA types
        ( elemOps, elemVarsWithTypes, ctx1 ) =
            generateExprListTyped ctxWithType elements

        -- Box elements that need to be boxed (layout says boxed, but expression is primitive)
        ( boxOpsReversed, boxedElemVarsReversed, ctx2 ) =
            List.foldl
                (\( ( var, ssaType ), ( _, isUnboxed ) ) ( opsAcc, varsAcc, ctxAcc ) ->
                    if isUnboxed then
                        -- Element is stored unboxed, use as-is
                        ( opsAcc, var :: varsAcc, ctxAcc )

                    else
                        -- Element should be boxed - box using actual SSA type
                        let
                            ( moreOps, boxedVar, newCtx ) =
                                boxToEcoValue ctxAcc var ssaType
                        in
                        ( List.reverse moreOps ++ opsAcc, boxedVar :: varsAcc, newCtx )
                )
                ( [], [], ctx1 )
                (List.map2 Tuple.pair elemVarsWithTypes layout.elements)

        boxOps =
            List.reverse boxOpsReversed

        boxedElemVars =
            List.reverse boxedElemVarsReversed

        ( resultVar, ctx3 ) =
            Ctx.freshVar ctx2

        elemVarPairs : List ( String, MlirType )
        elemVarPairs =
            List.map2
                (\v ( elemType, isUnboxed ) ->
                    ( v
                    , if isUnboxed then
                        Types.monoTypeToAbi elemType

                      else
                        Types.ecoValue
                    )
                )
                boxedElemVars
                layout.elements

        -- Use type-specific tuple construction ops.
        -- Now that MonoPath carries ContainerKind, projection ops match construction layout.
        ( ctx4, constructOp ) =
            case elemVarPairs of
                [ ( aVar, aType ), ( bVar, bType ) ] ->
                    -- 2-tuple: use eco.construct.tuple2
                    Ops.ecoConstructTuple2 ctx3 resultVar ( aVar, aType ) ( bVar, bType ) layout.unboxedBitmap

                [ ( aVar, aType ), ( bVar, bType ), ( cVar, cType ) ] ->
                    -- 3-tuple: use eco.construct.tuple3
                    Ops.ecoConstructTuple3 ctx3 resultVar ( aVar, aType ) ( bVar, bType ) ( cVar, cType ) layout.unboxedBitmap

                _ ->
                    -- Elm rejects tuples with >3 elements during canonicalization
                    crash "Compiler.Generate.CodeGen.MLIR" "generateTupleCreate" "unreachable: tuples >3 elements rejected by canonicalization"
    in
    { ops = elemOps ++ boxOps ++ [ constructOp ]
    , resultVar = resultVar
    , resultType = Types.ecoValue
    , ctx = ctx4
    , isTerminated = False
    }



-- ====== UNIT GENERATION ======


{-| Generate MLIR code for a Unit value.
-}
generateUnit : Ctx.Context -> ExprResult
generateUnit ctx =
    let
        ( var, ctx1 ) =
            Ctx.freshVar ctx

        -- Use eco.constant Unit instead of heap-allocating
        ( ctx2, unitOp ) =
            Ops.ecoConstantUnit ctx1 var
    in
    { ops = [ unitOp ]
    , resultVar = var
    , resultType = Types.ecoValue
    , ctx = ctx2
    , isTerminated = False
    }



-- ====== CHARACTER LITERAL DECODING ======


{-| Decode a character literal from its JS-escaped string representation.

The parser stores character literals as JS-style escape sequences (e.g., "\\u03BB" for λ).
This function decodes them back to the actual Unicode code point for MLIR codegen.

Also handles single-character strings (the actual character) for compatibility with
test code that creates AST nodes directly without going through the parser.

-}
decodeCharLiteral : String -> Int
decodeCharLiteral value =
    -- If it's a single character, just return its code directly.
    -- This handles both regular chars and the case where tests pass
    -- the actual character (e.g., a single backslash) instead of escaped form.
    if String.length value == 1 then
        case String.uncons value of
            Just ( c, _ ) ->
                Char.toCode c

            Nothing ->
                crash "decodeCharLiteral: empty character literal"

    else
        case String.uncons value of
            Just ( '\\', rest ) ->
                decodeEscape rest

            Just ( c, _ ) ->
                Char.toCode c

            Nothing ->
                crash "decodeCharLiteral: empty character literal"


decodeEscape : String -> Int
decodeEscape rest =
    case String.uncons rest of
        Just ( 'u', hex ) ->
            decodeUnicodeEscape hex

        Just ( 'n', _ ) ->
            10

        Just ( 'r', _ ) ->
            13

        Just ( 't', _ ) ->
            9

        Just ( '"', _ ) ->
            34

        Just ( '\'', _ ) ->
            39

        Just ( '\\', _ ) ->
            92

        Just ( c, _ ) ->
            crash ("decodeCharLiteral: unknown escape \\" ++ String.fromChar c)

        Nothing ->
            crash "decodeCharLiteral: trailing backslash"


decodeUnicodeEscape : String -> Int
decodeUnicodeEscape hex =
    -- Parse \uXXXX format, handle surrogate pairs
    case Hex.fromString (String.toLower (String.left 4 hex)) of
        Ok code ->
            if code >= 0xD800 && code <= 0xDBFF then
                -- High surrogate - need to decode pair
                decodeSurrogatePair code (String.dropLeft 6 hex)

            else
                code

        Err _ ->
            crash ("decodeCharLiteral: invalid hex in \\u" ++ String.left 4 hex)


decodeSurrogatePair : Int -> String -> Int
decodeSurrogatePair hi rest =
    -- rest should be "XXXX" (after "\u" has been dropped)
    case Hex.fromString (String.toLower (String.left 4 rest)) of
        Ok lo ->
            0x00010000 + ((hi - 0xD800) * 0x0400) + (lo - 0xDC00)

        Err _ ->
            crash "decodeCharLiteral: invalid low surrogate in pair"



-- ====== SHAPE HELPERS ======


{-| Extract record fields Dict from a MonoType.
-}
getRecordFields : Mono.MonoType -> EveryDict.Dict String Name.Name Mono.MonoType
getRecordFields monoType =
    case monoType of
        Mono.MRecord fields ->
            EveryDict.fromList identity (Dict.toList fields)

        _ ->
            EveryDict.empty


{-| Extract tuple element types from a MonoType.
-}
getTupleElements : Mono.MonoType -> List Mono.MonoType
getTupleElements monoType =
    case monoType of
        Mono.MTuple elements ->
            elements

        _ ->
            []


pairsToSparseArray : List ( Int, a ) -> Array (Maybe a)
pairsToSparseArray pairs =
    let
        maxIdx =
            List.foldl (\( i, _ ) acc -> max i acc) -1 pairs
    in
    List.foldl (\( i, v ) arr -> Array.set i (Just v) arr) (Array.repeat (maxIdx + 1) Nothing) pairs
