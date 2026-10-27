module Compiler.Generate.MLIR.Expr exposing
    ( ExprResult
    , generateExpr, unscopedTailCallError
    , coerceResultToType
    , createDummyValue
    , collectLetBoundNames, addPlaceholderMappings
    , aggBinderPromotableWith, lambdaIdToString, paramSplitAdmissible, scanChainForwardRefs, tupleBinderPromotable
    )

{-| Every function body the MLIR back end emits is made of expressions, and
this module turns one monomorphized expression into the MLIR ops that compute
it. `generateExpr` is that translation; nearly everything else in the file is
a case of it or a helper to one.

The translation keeps track of the type each SSA value actually has, which is
not always the type its Elm type maps to. `Compiler.Generate.MLIR.Types`
defines the two mappings: the _ABI type_ a value has at a boundary between
pieces of code, where Bool is `!eco.value`, and the _operand type_ inside a
function, where Bool is `i1`. A value can also be a _value aggregate_, a tuple
or constructor held as one SSA value of type `!eco.tuple2<..>`,
`!eco.tuple3<..>` or `!eco.custom<..>` instead of on the heap. So every
`ExprResult` carries the SSA type of its value, and wherever a value meets a
place that expects a particular type it is converted: boxed with `eco.box`,
put on the heap with `eco.to_heap`, unboxed with `eco.unbox`, or read back
from the heap with `eco.from_heap` (`coerceResultToType`, `boxToEcoValue`).

Calls are most of the file. How a call is made is decided mostly by the
optimizer, which attaches a `CallInfo` to it, and by tables in the context.
A function value is a closure that takes its arguments in _stages_, groups
that it takes one after another. A call to a global or kernel that supplies
all it takes is ordinarily an `eco.call`; most other calls are applications
through the closure, `eco.papExtend`, made stage by stage where the stages are
known and left to the runtime where they are not. Some
calls avoid the closure altogether: a constructor call can be built in place,
a call the optimizer has proved to reach one particular closure calls that
closure's code directly (a _fast dispatch_), some library functions become
single ops (intrinsics), and calls to `Bytes.Encode.encode` and
`Bytes.Decode.decode` can be compiled into straight-line reading and writing
(_bytes fusion_, `Compiler.Generate.MLIR.BytesFusion.Emit`).

Closures are created with `eco.papCreate` and their bodies are queued in the
context to be emitted as functions of their own. Bindings in a let chain can
refer to bindings later in the chain, through closures, so before a chain is
generated each of its names is given a _placeholder_, an SSA name a closure
can capture before anything defines it; the binding's value is later renamed
onto it. Closures at the head of a let chain that capture one another are
created together by one `eco.papCreateGroup`.

An `if` becomes a value-producing `eco.case` whose alternatives end in
`eco.yield`; so does a case's decision tree with at least one test, as
`eco.case` ops nested where a test may only run after another has passed. A
branch shared by several leaves is copied into each.

A large part of the file serves one optimization: keeping tuples and constructors
off the heap. A tuple literal or constructor call bound by a let can be built
as a value aggregate when every use of it only reads its fields; an _escape
walk_ (`walkPromo`) checks that. Two kinds of worker, prepared elsewhere and
listed in the context, extend the same idea across calls. A `$psplit` worker
takes a tuple or constructor parameter as its fields; a `$sret` worker returns
the fields of its tuple result as separate results. Inside a `$sret` worker the
expressions whose value is the function's result form its _result spine_,
which the context's `sretTailLayout` marks; on the spine a tuple is built as an
aggregate, and a case yields one value per field (a _decomposed yield_) and
rebuilds the tuple after the case.


# Result Type

@docs ExprResult


# Expression Generation

@docs generateExpr, unscopedTailCallError


# Boxing and Coercion

@docs coerceResultToType


# Utilities

@docs createDummyValue


# Let-binding Helpers

@docs collectLetBoundNames, addPlaceholderMappings
@docs aggBinderPromotableWith, lambdaIdToString, paramSplitAdmissible, scanChainForwardRefs, tupleBinderPromotable

-}

import Array exposing (Array)
import Compiler.AST.DecisionTree.Test as Test
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Generate.MLIR.BytesFusion.Emit as BFEmit
import Compiler.Generate.MLIR.BytesFusion.Reify as BFReify
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Intrinsics as Intrinsics
import Compiler.Generate.MLIR.KernelAbi as KernelAbi
import Compiler.Generate.MLIR.Names as Names
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Patterns as Patterns
import Compiler.Generate.MLIR.Types as Types
import Compiler.GlobalOpt.KernelIntrinsics as KernelIntrinsics
import Compiler.LocalOpt.Typed.DecisionTree as DT
import Compiler.Monomorphize.Closure as Closure
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Compiler.Monomorphize.Registry as Registry
import Dict
import Hex
import List.Extra as ListX
import Mlir.Mlir exposing (MlirAttr(..), MlirBlock, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import Set
import Utils.Crash exposing (crash)



-- ====== EXPRESSION RESULT ======


{-| The MLIR for one expression: the ops that compute it, the SSA value that
holds it, and the context to carry on with.

`resultType` is the type the SSA value actually has, which can differ from
what the expression's Mono type maps to at an ABI boundary (a Bool is `i1`
here, a promoted tuple is a value aggregate). A caller that needs a particular
type coerces with `coerceResultToType`.

`isTerminated` is `True` when `ops` already ends with the `eco.yield` that
closes a case alternative, so nothing may be appended after it.

-}
type alias ExprResult =
    { ops : List MlirOp
    , resultVar : String
    , resultType : MlirType
    , ctx : Ctx.Context
    , isTerminated : Bool
    }


{-| Returns a result with no ops whose value is the existing SSA value `var` of
type `ty`.
-}
emptyResult : Ctx.Context -> String -> MlirType -> ExprResult
emptyResult ctx var ty =
    { ops = [], resultVar = var, resultType = ty, ctx = ctx, isTerminated = False }


{-| Returns `ops` with every occurrence of the SSA name `fromVar` replaced by
`toVar`: in each op's id, operands and results, and in the ops and terminators
of nested regions. Block arguments are left alone, because they bind names of
their own.
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


{-| Returns the region with `fromVar` renamed to `toVar` in every block, as
`renameSsaVarInOps` does for a list of ops.
-}
renameSsaVarInRegion : String -> String -> MlirRegion -> MlirRegion
renameSsaVarInRegion fromVar toVar (MlirRegion r) =
    MlirRegion
        { entry = renameSsaVarInBlock fromVar toVar r.entry
        , blocks = OrderedDict.map (\_ block -> renameSsaVarInBlock fromVar toVar block) r.blocks
        }


{-| Returns the block with `fromVar` renamed to `toVar` in its body and its
terminator, leaving its arguments unchanged.
-}
renameSsaVarInBlock : String -> String -> MlirBlock -> MlirBlock
renameSsaVarInBlock fromVar toVar block =
    { block
        | body = renameSsaVarInOps fromVar toVar block.body
        , terminator = renameSsaVarInSingleOp fromVar toVar block.terminator
    }


{-| Returns the one op with `fromVar` renamed to `toVar`, as
`renameSsaVarInOps` does for a list.
-}
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


{-| Returns the result with its value renamed to `desiredVar`, throughout its
ops and nested regions. This is how a let binding's value is made to define
the placeholder name that sibling closures have already captured.
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


{-| Tells whether one of the top-level `ops` (not a nested region) lists `var`
among its results.
-}
isVarDefinedInOps : String -> List MlirOp -> Bool
isVarDefinedInOps var ops =
    List.any (\op -> List.any (\( name, _ ) -> name == var) op.results) ops


{-| Rewrites each top-level `eco.papCreate` in `result` that captures
`placeholderVar`, the closure's own not-yet-defined name: the operand becomes
`unitVar`, and the operand positions it occupied are listed in a
`self_capture_indices` attribute. The context is returned unchanged.
-}
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


{-| Tells whether a top-level `eco.papCreate` in `ops` captures
`placeholderVar`.
-}
hasSelfCapture : String -> List MlirOp -> Bool
hasSelfCapture placeholderVar ops =
    List.any
        (\op -> op.name == "eco.papCreate" && List.member placeholderVar op.operands)
        ops



-- ====== HELPER FUNCTIONS ======


{-| A reference to the function a fast-dispatch stamp names: the closure's
lambda id, and the specialization whose top-level closure it is, if it is one.

The two are needed because the function is emitted under different names. A
specialization's top-level closure is emitted under the specialization's
function name, never under its lambda id; every other closure is emitted under
`lambdaIdToString` of its lambda id.

-}
type alias FastRef =
    ( Mono.LambdaId, Maybe Mono.SpecId )


{-| Returns the symbol the function `FastRef` names was emitted under: the
specialization's function name when there is one, otherwise the lambda's name.
-}
fastRefBaseName : Ctx.Context -> FastRef -> String
fastRefBaseName ctx ( lambdaId, maybeSpec ) =
    case maybeSpec of
        Just specId ->
            specIdToFuncName ctx.registry specId

        Nothing ->
            lambdaIdToString lambdaId


{-| Returns the MLIR function name of a specialization: the global's mangled
home and name (or `accessor_` and the field name), then `_$_` and the
specialization id. An id missing from the registry gives `unknown_$_` and the
id.
-}
specIdToFuncName : Mono.SpecializationRegistry -> Mono.SpecId -> String
specIdToFuncName registry specId =
    case Registry.lookupSpecKey specId registry of
        Just ( Mono.Global home name, _ ) ->
            Names.canonicalToMLIRName home ++ "_" ++ Names.sanitizeName name ++ "_$_" ++ String.fromInt specId

        Just ( Mono.Accessor fieldName, _ ) ->
            "accessor_" ++ Names.sanitizeName fieldName ++ "_$_" ++ String.fromInt specId

        Nothing ->
            "unknown_$_" ++ String.fromInt specId


{-| Creates a placeholder value of `mlirType`, for a place that needs a value
whose contents do not matter, such as a path that is never reached. It is a
zero constant for `i64`, `f64`, `i1` and `i16`, and the Unit constant for every
other type, so its type is `!eco.value` whenever `mlirType` is not one of those
four.
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
            let
                ( ctx2, op ) =
                    Ops.ecoConstantUnit ctx1 resultVar
            in
            ( [ op ], resultVar, ctx2 )



-- ====== GENERATE EXPRESSION ======


{-| Generates the MLIR for one monomorphized expression in the context `ctx0`,
returning its ops, its value and the context to continue with.

The context's `sretTailLayout` marks the result spine, and only a tuple
literal, let, destructuring, case or if keeps it for its own generation; every
other expression clears it first, so that nothing off the spine is built as an
aggregate. A call is first tried as a `$sret` call on the spine
(`trySretFreshLeaf`), and a let as an inlined bytes decode
(`tryInlinedDecodeFusion`). A record's fields are put in layout order, and a
record access or update takes its layout from the type of the record it reads.

A `MonoTailCall` crashes the compiler with `unscopedTailCallError`. A
`MonoAccessorValue`, which earlier passes are expected to have removed,
crashes it too.

-}
generateExpr : Ctx.Context -> Mono.MonoExpr -> ExprResult
generateExpr ctx0 expr =
    let
        ctx =
            case ctx0.sretTailLayout of
                Nothing ->
                    ctx0

                Just _ ->
                    case expr of
                        Mono.MonoTupleCreate _ _ _ ->
                            ctx0

                        Mono.MonoLet _ _ _ ->
                            ctx0

                        Mono.MonoDestruct _ _ _ ->
                            ctx0

                        Mono.MonoCase _ _ _ _ _ ->
                            ctx0

                        Mono.MonoIf _ _ _ ->
                            ctx0

                        _ ->
                            { ctx0 | sretTailLayout = Nothing }
    in
    case expr of
        Mono.MonoLiteral lit _ ->
            generateLiteral ctx lit

        Mono.MonoVarLocal name _ ->
            case Dict.get name ctx.splitAggParams of
                Just splitInfo ->
                    -- A whole-value use of a name held as scalar slots: rebuild
                    -- the value from the current slots. Elm values are
                    -- immutable, so the rebuilt value is indistinguishable.
                    let
                        ( matOps, matVar, ctxM ) =
                            Patterns.materializeSplitParam ctx splitInfo
                    in
                    { ops = matOps
                    , resultVar = matVar
                    , resultType = Types.ecoValue
                    , ctx = ctxM
                    , isTerminated = False
                    }

                Nothing ->
                    let
                        ( varName, varType ) =
                            Ctx.lookupVar ctx name
                    in
                    emptyResult ctx varName varType

        Mono.MonoVarGlobal _ specId monoType ->
            generateVarGlobal ctx specId monoType

        Mono.MonoVarKernel _ kernelPrefix home name monoType ->
            generateVarKernel ctx kernelPrefix home name monoType

        Mono.MonoList _ items listType ->
            generateList ctx items listType

        Mono.MonoClosure closureInfo body monoType ->
            generateClosure ctx closureInfo body monoType

        Mono.MonoCall _ func args resultType callInfo ->
            case trySretFreshLeaf ctx0 func args of
                Just res ->
                    res

                Nothing ->
                    generateCall ctx func args resultType callInfo

        Mono.MonoTailCall name _ _ ->
            crash (unscopedTailCallError name)

        Mono.MonoIf branches final monoType ->
            -- `if` is on the result spine: `generateIf` clears the flag for
            -- the condition and keeps it for the branches, and the returned
            -- ctx carries the caller's flag, as the tuple arm does.
            let
                res =
                    generateIf ctx branches final monoType

                resCtx =
                    res.ctx
            in
            { res | ctx = { resCtx | sretTailLayout = ctx.sretTailLayout } }

        Mono.MonoLet def body _ ->
            case tryInlinedDecodeFusion ctx def body of
                Just result ->
                    result

                Nothing ->
                    generateLet ctx def body

        Mono.MonoDestruct destructor body _ ->
            generateDestruct ctx destructor body

        Mono.MonoCase _ _ decider jumps resultType ->
            generateCase ctx decider jumps resultType

        Mono.MonoRecordCreate namedFields monoType ->
            let
                layout =
                    Types.computeRecordLayout (getRecordFields monoType)

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
                    case ListX.find (\fi -> fi.name == fieldName) layout.fields of
                        Just fi ->
                            fi

                        Nothing ->
                            crash ("record access: field " ++ fieldName ++ " not in layout")
            in
            generateRecordAccess ctx record fieldInfo.index fieldInfo.isUnboxed fieldType

        Mono.MonoRecordUpdate record namedUpdates _ ->
            let
                recordType =
                    Mono.typeOf record

                layout =
                    Types.computeRecordLayout (getRecordFields recordType)

                indexedUpdates =
                    List.filterMap
                        (\( name, updateExpr ) ->
                            ListX.find (\fi -> fi.name == name) layout.fields
                                |> Maybe.map (\fi -> ( fi.index, updateExpr ))
                        )
                        namedUpdates
            in
            generateRecordUpdate ctx record indexedUpdates layout

        Mono.MonoTupleCreate _ elements monoType ->
            case ctx.sretTailLayout of
                Just tailLayout ->
                    -- A tuple literal on the result spine is built as a value
                    -- aggregate, with no allocation. Its elements compile with
                    -- the flag cleared, but the returned ctx carries the flag
                    -- on, because the case leaf that yields this value reads
                    -- it to yield one value per slot.
                    let
                        res =
                            -- The slot types must match the layout exactly, not
                            -- just the arity; a tuple of another layout is built
                            -- boxed and converted by the leaf's coercion.
                            if
                                Types.tupleSlotTypes (Types.computeTupleLayout (getTupleElements monoType))
                                    == Types.tupleSlotTypes tailLayout
                            then
                                generateTupleCreateValue { ctx | sretTailLayout = Nothing } elements monoType

                            else
                                let
                                    layout =
                                        Types.computeTupleLayout (getTupleElements monoType)
                                in
                                generateTupleCreate { ctx | sretTailLayout = Nothing } elements layout monoType

                        resCtx =
                            res.ctx
                    in
                    { res | ctx = { resCtx | sretTailLayout = ctx.sretTailLayout } }

                Nothing ->
                    let
                        layout =
                            Types.computeTupleLayout (getTupleElements monoType)
                    in
                    generateTupleCreate ctx elements layout monoType

        Mono.MonoUnit ->
            generateUnit ctx

        Mono.MonoAccessorValue _ fieldName _ ->
            crash ("MonoAccessorValue ." ++ fieldName ++ " should have been eliminated by ResolveAccessorValues")



-- ====== LITERAL GENERATION ======


{-| Generates a literal as one constant op. Bool, Int, Float and Char literals
are unboxed constants (`i1`, `i64`, `f64`, `i16`); a Char literal's source text
is decoded to its code point first. A String literal is an `!eco.value`: the
embedded empty-string constant for `""`, otherwise an `eco.string_literal`.
-}
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


{-| Generates a reference to a constant thunk by emitting the thunk's `body` in
place of a call to it, coerced to the ABI type of `sig`'s return type, so that
the value is the one the call would have returned.

A constant thunk is a zero-argument global listed, with its body, in the
context's `constThunkBySpec` table. Emitting the body lets later passes fold
the constant.

The body is generated in a fresh lexical scope: every name-keyed field of the
context is emptied, so that a name bound in the body cannot see or overwrite
one of the caller's, and restored afterwards. Everything else threads through,
including the set of defined SSA values, which grows because the new values
are defined in the caller's function.

-}
generateConstThunkRef : Ctx.Context -> Ctx.FuncSignature -> Mono.MonoExpr -> ExprResult
generateConstThunkRef ctx sig body =
    let
        scoped =
            { ctx
                | varMappings = Dict.empty
                , currentLetSiblings = Dict.empty
                , localEvaluatorParams = Dict.empty
                , splitAggParams = Dict.empty
                , decoderExprs = Dict.empty
                , fwdRefdLetNames = Set.empty
                , tailRecLetBody = Nothing
                , sretTailLayout = Nothing
            }

        r =
            generateExpr scoped body

        retTy =
            Types.monoTypeToAbi sig.returnType

        ( coerceOps, finalVar, ctxC ) =
            coerceResultToType r.ctx r.resultVar r.resultType retTy
    in
    { ops = r.ops ++ coerceOps
    , resultVar = finalVar
    , resultType = retTy
    , ctx =
        { ctxC
            | varMappings = ctx.varMappings
            , currentLetSiblings = ctx.currentLetSiblings
            , localEvaluatorParams = ctx.localEvaluatorParams
            , splitAggParams = ctx.splitAggParams
            , decoderExprs = ctx.decoderExprs
            , fwdRefdLetNames = ctx.fwdRefdLetNames
            , tailRecLetBody = ctx.tailRecLetBody
            , sretTailLayout = ctx.sretTailLayout
        }
    , isTerminated = False
    }


{-| Generates a reference to a global specialization as a value.

The arity comes from the specialization's signature, because `monoType` can be
a type variable even when the global is a function. A global with parameters
becomes an `eco.papCreate` with no captures. A global with none is looked up in
the context's constant tables, in this order: a nullary constructor with a
null-cons tag becomes that `eco.constant`; one whose value is the embedded
`Nothing` constant becomes that constant; a constant thunk has its body emitted
in place (`generateConstThunkRef`); anything else is an `eco.call` with no
arguments. These tables change only references made here: the global's own
function is still emitted.

A global with no signature is called with no arguments, typed by `monoType`;
if `monoType` is a function type, compilation crashes.

-}
generateVarGlobal : Ctx.Context -> Mono.SpecId -> Mono.MonoType -> ExprResult
generateVarGlobal ctx specId monoType =
    let
        ( var, ctx1 ) =
            Ctx.freshVar ctx

        funcName : String
        funcName =
            specIdToFuncName ctx.registry specId

        maybeSig : Maybe Ctx.FuncSignature
        maybeSig =
            Array.get specId ctx.signatures |> Maybe.andThen identity
    in
    case maybeSig of
        Just sig ->
            let
                arity : Int
                arity =
                    List.length sig.paramTypes
            in
            if arity == 0 then
                case Dict.get specId ctx.nullConsBySpec of
                    Just nullConsTag ->
                        let
                            ( ctx2, constOp ) =
                                Ops.ecoConstantNullCons ctx1 var nullConsTag
                        in
                        { ops = [ constOp ]
                        , resultVar = var
                        , resultType = Types.ecoValue
                        , ctx = ctx2
                        , isTerminated = False
                        }

                    Nothing ->
                        case Dict.get specId ctx.constCtorBySpec of
                            Just _ ->
                                let
                                    ( ctx2, constOp ) =
                                        Ops.ecoConstantNothing ctx1 var
                                in
                                { ops = [ constOp ]
                                , resultVar = var
                                , resultType = Types.ecoValue
                                , ctx = ctx2
                                , isTerminated = False
                                }

                            Nothing ->
                                case Dict.get specId ctx.constThunkBySpec of
                                    Just thunkBody ->
                                        generateConstThunkRef ctx sig thunkBody

                                    Nothing ->
                                        -- Called, not wrapped: papCreate needs an
                                        -- arity above zero.
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
                let
                    -- _result_kind is the kind of the function's own return
                    -- type, omitted when boxed.
                    globalResultKind =
                        Types.mlirTypeToKind (Types.monoTypeToAbi sig.returnType)

                    globalResultKindAttr =
                        if globalResultKind == 0 then
                            Dict.empty

                        else
                            Dict.singleton "_result_kind" (IntAttr (Just I8) globalResultKind)

                    attrs =
                        Dict.union globalResultKindAttr
                            (Dict.fromList
                                [ ( "function", SymbolRefAttr funcName )
                                , ( "arity", IntAttr Nothing (Ops.assertStageArity arity) )
                                , ( "num_captured", IntAttr Nothing 0 )
                                ]
                            )

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
            case monoType of
                Mono.MFunction _ _ _ _ ->
                    Utils.Crash.crash
                        ("generateVarGlobal: missing FuncSignature for function-typed global "
                            ++ specIdToFuncName ctx.registry specId
                        )

                _ ->
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


{-| Generates a reference to a kernel value.

A kernel that `KernelIntrinsics` classifies as a float constant (such as `pi`)
becomes an `arith.constant`. Otherwise a function type whose flattened arity is
above zero becomes an `eco.papCreate` with no captures through
`instanceClosureResult`, naming the symbol `Context.registerKernelInstance`
chooses, and any other kernel is an `eco.call` with no arguments to the symbol
`<kernelPrefix>_Kernel_<home>_<name>`, typed by the ABI of `monoType`.

-}
generateVarKernel : Ctx.Context -> Name.Name -> Name.Name -> Name.Name -> Mono.MonoType -> ExprResult
generateVarKernel ctx kernelPrefix home name monoType =
    let
        ( var, ctx1 ) =
            Ctx.freshVar ctx

        kernelName : String
        kernelName =
            kernelPrefix ++ "_Kernel_" ++ home ++ "_" ++ name
    in
    case KernelIntrinsics.kernelIntrinsic home name [] monoType of
        Just (KernelIntrinsics.ConstantFloat { value }) ->
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
            case monoType of
                Mono.MFunction _ _ _ _ ->
                    -- Kernels use total ABI arity (flattened), not stage arity
                    let
                        arity : Int
                        arity =
                            Types.countTotalArity monoType
                    in
                    if arity == 0 then
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
                        instanceClosureResult ctx1 var kernelPrefix home name monoType arity

                _ ->
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
            case monoType of
                Mono.MFunction _ _ _ _ ->
                    -- Kernels use total ABI arity (flattened), not stage arity
                    let
                        arity : Int
                        arity =
                            Types.countTotalArity monoType
                    in
                    if arity == 0 then
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
                        instanceClosureResult ctx1 var kernelPrefix home name monoType arity

                _ ->
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


{-| Generates a kernel function used as a value: an `eco.papCreate` with no
captures and the given `arity`, defining `var`.

The kernel is registered with `Context.registerKernelInstance` under its
argument and result types, which chooses the symbol the closure names
(possibly with a type suffix, as `Compiler.Generate.MLIR.KernelAbi` describes)
and makes sure the kernel is declared.

-}
instanceClosureResult : Ctx.Context -> String -> Name.Name -> Name.Name -> Name.Name -> Mono.MonoType -> Int -> ExprResult
instanceClosureResult ctx var kernelPrefix home name monoType arity =
    let
        ( argTypes, returnType ) =
            Mono.decomposeFunctionType monoType

        instanceKey : KernelAbi.KernelInstanceKey
        instanceKey =
            { prefix = kernelPrefix
            , home = home
            , name = name
            , argTypes = argTypes
            , resultType = returnType
            }

        ( instanceAbi, ctxWithKernel ) =
            Ctx.registerKernelInstance instanceKey ctx

        kernelResultKind =
            Types.mlirTypeToKind (Types.monoTypeToAbi returnType)

        kernelResultKindAttr =
            if kernelResultKind == 0 then
                Dict.empty

            else
                Dict.singleton "_result_kind" (IntAttr (Just I8) kernelResultKind)

        attrs =
            Dict.union kernelResultKindAttr
                (Dict.fromList
                    [ ( "function", SymbolRefAttr instanceAbi.symbolName )
                    , ( "arity", IntAttr Nothing (Ops.assertStageArity arity) )
                    , ( "num_captured", IntAttr Nothing 0 )
                    ]
                )

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



-- ====== LIST GENERATION ======


{-| Generates a list literal. `[]` is the embedded Nil constant. A longer list
is built from the last element forwards, one `eco.construct.list` per element
onto the Nil constant; an element whose SSA type is unboxable is stored
unboxed, and any other is boxed first. The list's type is registered in the
type table either way.
-}
generateList : Ctx.Context -> List Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateList ctx items listType =
    let
        ( _, ctxWithType ) =
            Ctx.getOrCreateTypeIdForMonoType listType ctx
    in
    case items of
        [] ->
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

                                -- Decided by the SSA type, which can differ
                                -- from what the Mono type maps to.
                                headUnboxed : Bool
                                headUnboxed =
                                    Types.isUnboxable result.resultType
                            in
                            if headUnboxed then
                                let
                                    ( consVar, ctx3 ) =
                                        Ctx.freshVar result.ctx

                                    ( ctx4, consOp ) =
                                        Ops.ecoConstructList ctx3 consVar ( result.resultVar, result.resultType ) ( tailVar, Types.ecoValue ) True
                                in
                                ( consOp :: List.reverse result.ops ++ accOps, consVar, ctx4 )

                            else
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


{-| Generates a closure value and queues its body, as a `PendingLambda`, to be
emitted as a function of its own.

The captures are generated first, and a Bool capture is boxed
(`boxArgsForClosureBoundary`); other captures keep their SSA type. With no
captures and no parameters the closure is a thunk and is called at once, with
an `eco.call`. Otherwise the value is an `eco.papCreate` whose `arity` counts
captures plus parameters. Without captures its `function` is the lambda's own
name; with captures both `function` and `_fast_evaluator` name the lambda's
`$cap` clone, which takes the captures then the parameters.

The queued lambda sees the enclosing let's sibling placeholders, so that
mutually recursive local closures can name each other; it does not see any
other outer variable, which must be captured explicitly.

-}
generateClosure : Ctx.Context -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateClosure ctx closureInfo body monoType =
    let
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

        ( boxOps, boxedCaptureVarsWithTypes, ctx1a ) =
            boxArgsForClosureBoundary ctx1 captureVarsWithTypes

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
            , selfBindingName = Nothing
            }
    in
    if arity == 0 then
        -- Called, not wrapped: papCreate needs an arity above zero.
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
        let
            hasCaptures =
                not (List.isEmpty closureInfo.captures)

            baseFuncName =
                lambdaIdToString closureInfo.lambdaId

            functionName =
                if hasCaptures then
                    baseFuncName ++ "$cap"

                else
                    baseFuncName

            operandTypesAttr =
                if List.isEmpty captureVarNames then
                    Dict.empty

                else
                    Dict.singleton "_operand_types"
                        (ArrayAttr Nothing (List.map TypeAttr captureTypesList))

            fastEvaluatorAttr =
                if hasCaptures then
                    Dict.singleton "_fast_evaluator" (SymbolRefAttr (baseFuncName ++ "$cap"))

                else
                    Dict.empty

            closureKindAttr =
                case closureInfo.closureKind of
                    Just (Mono.Known (Mono.ClosureKindId kindId)) ->
                        Dict.singleton "_closure_kind" (IntAttr Nothing kindId)

                    Nothing ->
                        Dict.empty

            -- _result_kind is the slot kind of the body's ABI type (0 boxed,
            -- 1 Int, 2 Float, 3 Char), omitted when 0. A body that returns a
            -- further stage returns a function, which is boxed.
            bodyResultKind =
                Types.mlirTypeToKind (Types.monoTypeToAbi (Mono.typeOf body))

            resultKindAttr =
                if bodyResultKind == 0 then
                    Dict.empty

                else
                    Dict.singleton "_result_kind" (IntAttr (Just I8) bodyResultKind)

            papAttrs =
                Dict.union resultKindAttr
                    (Dict.union closureKindAttr
                        (Dict.union fastEvaluatorAttr
                            (Dict.union operandTypesAttr
                                (Dict.fromList
                                    [ ( "function", SymbolRefAttr functionName )
                                    , ( "arity", IntAttr Nothing (Ops.assertStageArity arity) )
                                    , ( "num_captured", IntAttr Nothing numCaptured )
                                    ]
                                    |> Ops.withSlotKinds captureTypesList
                                )
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


{-| Returns the MLIR function name of an anonymous lambda: its home module's
MLIR name, then `_lambda_` and the lambda's unique id.
-}
lambdaIdToString : Mono.LambdaId -> String
lambdaIdToString lambdaId =
    case lambdaId of
        Mono.AnonymousLambda home uid ->
            Names.canonicalToMLIRName home ++ "_lambda_" ++ String.fromInt uid



-- ====== CALL GENERATION ======


{-| Boxes `var`, whose SSA type is `mlirTy`, to an `!eco.value`. A value that
is already one is returned with no ops; a value aggregate is put on the heap
with `eco.to_heap`; anything else is wrapped with `eco.box`.
-}
boxToEcoValue : Ctx.Context -> String -> MlirType -> ( List MlirOp, String, Ctx.Context )
boxToEcoValue ctx var mlirTy =
    if Types.isEcoValueType mlirTy then
        ( [], var, ctx )

    else if Types.isAggValueType mlirTy then
        let
            ( heapVar, ctx1 ) =
                Ctx.freshVar ctx

            ( ctx2, toHeapOp ) =
                Ops.ecoToHeap ctx1 heapVar ( var, mlirTy )
        in
        ( [ toHeapOp ], heapVar, ctx2 )

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


{-| Returns `intrinsic` if it may be emitted at this call, or `Nothing` to
make the call an ordinary kernel call. `KernelIntrinsics.kernelIntrinsic`
decides what op a call could become; this decides whether to use it, given the
configuration and the arguments' SSA types.

`StringLength`, `AppendString`, `AppendList` and `StringOrderCompare` are
admitted when their configuration flag is on. `ValueEq` also needs every
argument to be an `!eco.value` already, because the intrinsic path can unbox
but not box, and an argument may arrive as a value aggregate. `ConstructList`
needs its flag and exactly two arguments, and admits a primitive head slot only
when the head's SSA type is `!eco.value` or the slot's own type, so that a
mismatched primitive is never written under the wrong head kind; a boxed head
slot is always admitted. Every other intrinsic is admitted unconditionally.

-}
gateIntrinsic : Ctx.Context -> List ( String, MlirType ) -> KernelIntrinsics.Intrinsic -> Maybe KernelIntrinsics.Intrinsic
gateIntrinsic ctx argsWithTypes intrinsic =
    case intrinsic of
        KernelIntrinsics.StringLength ->
            if ctx.ecoConfig.stringLengthOp then
                Just intrinsic

            else
                Nothing

        KernelIntrinsics.AppendString ->
            if ctx.ecoConfig.appendSplit then
                Just intrinsic

            else
                Nothing

        KernelIntrinsics.AppendList ->
            if ctx.ecoConfig.appendSplit then
                Just intrinsic

            else
                Nothing

        KernelIntrinsics.StringOrderCompare _ ->
            if ctx.ecoConfig.stringOrderIntrinsic then
                Just intrinsic

            else
                Nothing

        KernelIntrinsics.ValueEq _ ->
            if ctx.ecoConfig.valueEq && List.all (Tuple.second >> Types.isEcoValueType) argsWithTypes then
                Just intrinsic

            else
                Nothing

        KernelIntrinsics.ConstructList { headMlirType } ->
            case ( ctx.ecoConfig.list.consIntrinsic, argsWithTypes ) of
                ( True, [ ( _, headSsaTy ), _ ] ) ->
                    if Types.isEcoValueType headMlirType then
                        Just intrinsic

                    else if Types.isEcoValueType headSsaTy || headSsaTy == headMlirType then
                        Just intrinsic

                    else
                        Nothing

                _ ->
                    Nothing

        _ ->
            Just intrinsic


{-| Converts the arguments of an admitted intrinsic to the operand types it
expects. For `ConstructList` the tail is boxed, and the head is boxed into a
boxed slot or unboxed into a primitive one. Every other intrinsic goes through
`Intrinsics.unboxArgsForIntrinsic`, which only unboxes.
-}
coerceIntrinsicArgs : Ctx.Context -> List ( String, MlirType ) -> KernelIntrinsics.Intrinsic -> ( List MlirOp, List String, Ctx.Context )
coerceIntrinsicArgs ctx argsWithTypes intrinsic =
    case ( intrinsic, argsWithTypes ) of
        ( KernelIntrinsics.ConstructList { headMlirType }, [ ( headVar, headSsaTy ), ( tailVar, tailSsaTy ) ] ) ->
            let
                ( headOps, headVar1, ctxH ) =
                    if Types.isEcoValueType headMlirType then
                        boxToEcoValue ctx headVar headSsaTy

                    else if Types.isEcoValueType headSsaTy then
                        Intrinsics.unboxToType ctx headVar headMlirType

                    else
                        ( [], headVar, ctx )

                ( tailOps, tailVar1, ctxT ) =
                    boxToEcoValue ctxH tailVar tailSsaTy
            in
            ( headOps ++ tailOps, [ headVar1, tailVar1 ], ctxT )

        _ ->
            Intrinsics.unboxArgsForIntrinsic ctx argsWithTypes intrinsic


{-| Converts each argument to the ABI type of the matching entry of
`expectedTypes`, judging by the argument's SSA type: a primitive is boxed where
`!eco.value` is expected, and an `!eco.value` is unboxed where a primitive is.
Any other mismatch, such as `i64` against `f64`, is passed through unchanged.
Arguments beyond the length of `expectedTypes` are dropped.
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
                let
                    ( boxOps, boxedVar, ctx1 ) =
                        boxToEcoValue ctxAcc var actualTy
                in
                ( List.reverse boxOps ++ opsAcc
                , ( boxedVar, Types.ecoValue ) :: pairsAcc
                , ctx1
                )

            else if not (Types.isEcoValueType expectedMlirTy) && Types.isEcoValueType actualTy then
                let
                    ( unboxOps, unboxedVar, ctx1 ) =
                        Intrinsics.unboxToType ctxAcc var expectedMlirTy
                in
                ( List.reverse unboxOps ++ opsAcc
                , ( unboxedVar, expectedMlirTy ) :: pairsAcc
                , ctx1
                )

            else
                ( opsAcc, ( var, actualTy ) :: pairsAcc, ctxAcc )

        ( opsReversed, pairsReversed, ctxFinal ) =
            List.foldl helper ( [], [], ctx ) (List.map2 Tuple.pair actualArgs expectedTypes)
    in
    ( List.reverse opsReversed, List.reverse pairsReversed, ctxFinal )


{-| Converts `var` from its SSA type `actualTy` to `expectedTy`, returning the
ops and the converted value.

Equal types need nothing. A primitive is converted to `!eco.value` with
`eco.box`, and a value aggregate with `eco.to_heap`, which puts it on the heap.
An `!eco.value` is converted to a value aggregate with
`eco.from_heap`, and to a primitive by unboxing. Any other pair, such as `i64`
to `f64` or one aggregate type to another, crashes the compiler, because such a
mismatch should have been resolved before code generation.

-}
coerceResultToType : Ctx.Context -> String -> MlirType -> MlirType -> ( List MlirOp, String, Ctx.Context )
coerceResultToType ctx var actualTy expectedTy =
    if actualTy == expectedTy then
        ( [], var, ctx )

    else if Types.isEcoValueType expectedTy && not (Types.isEcoValueType actualTy) then
        boxToEcoValue ctx var actualTy

    else if Types.isAggValueType expectedTy && Types.isEcoValueType actualTy then
        let
            ( aggVar, ctx1 ) =
                Ctx.freshVar ctx

            ( ctx2, fromHeapOp ) =
                Ops.ecoFromHeap ctx1 aggVar expectedTy var
        in
        ( [ fromHeapOp ], aggVar, ctx2 )

    else if not (Types.isEcoValueType expectedTy) && Types.isEcoValueType actualTy then
        Intrinsics.unboxToType ctx var expectedTy

    else
        crash <|
            "coerceResultToType: cannot coerce "
                ++ Types.mlirTypeToString actualTy
                ++ " to "
                ++ Types.mlirTypeToString expectedTy
                ++ " for variable "
                ++ var


{-| Generates a call, choosing the kind of op from the `CallInfo` the optimizer
attached to it rather than from the callee's type. A call through a closure
value is coerced to the ABI type of `resultType`; a direct call to a global or
kernel has the result type of what it calls (see
`generateSaturatedCallNoFusion`).

A _fast-dispatch stamp_ is the optimizer's finding that the callee value can
only be one particular closure (`fastEvaluator` with its `captureAbi`). Only
`CallGenericApply`, `CallSegmentationUnknown` and
`CallDirectKnownSegmentation` consult it, except a single-stage saturated
`CallDirectKnownSegmentation` whose callee is a global or kernel reference;
`CallDirectFlat` never does. When such a call carries one and supplies
exactly the closure's next stage of arguments, it becomes a fast dispatch
(`generateFastDispatchCall`) that calls that closure's code directly; when it
supplies more, the first stage is a fast dispatch and the rest is applied
generically (`generateStagedFastDispatchCall`). Without a usable stamp:

  - `CallGenericApply` becomes a generic `eco.papExtend`
    (`generateGenericApply`).
  - `CallSegmentationUnknown` becomes an `eco.papExtend` without
    `remaining_arity` whose arguments are boxed to what the callee's evaluator
    takes, if that is known (`generateUnknownSegmentationCall`). With no
    arguments it is just the callee's value, which need not be a closure.
  - `CallDirectFlat` is a saturated call (`generateSaturatedCall`), or a
    partial application when `resultType` is a function.
  - `CallDirectKnownSegmentation` is a saturated call when it saturates one
    stage, and a stage-by-stage application otherwise. A saturated call whose
    callee is a global or kernel reference never consults the stamp, because
    a direct `eco.call` to it is cheaper than any closure dispatch.

-}
generateCall : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> Mono.CallInfo -> ExprResult
generateCall ctx func args resultType callInfo =
    case callInfo.callKind of
        Mono.CallGenericApply ->
            case fastDispatchStamp callInfo args of
                Just ( fastLambdaId, fastAbi, papPrefix ) ->
                    generateFastDispatchCall ctx func args resultType fastLambdaId fastAbi papPrefix

                Nothing ->
                    case fastDispatchStampStaged callInfo args of
                        Just ( fastLambdaId, fastAbi ) ->
                            generateStagedFastDispatchCall ctx func args resultType fastLambdaId fastAbi

                        Nothing ->
                            generateGenericApplyCoerced ctx func args resultType

        Mono.CallSegmentationUnknown ->
            case fastDispatchStamp callInfo args of
                Just ( fastLambdaId, fastAbi, papPrefix ) ->
                    generateFastDispatchCall ctx func args resultType fastLambdaId fastAbi papPrefix

                Nothing ->
                    case fastDispatchStampStaged callInfo args of
                        Just ( fastLambdaId, fastAbi ) ->
                            generateStagedFastDispatchCall ctx func args resultType fastLambdaId fastAbi

                        Nothing ->
                            -- A call with no arguments applies nothing: its value
                            -- is the callee's, which may not be a closure (an i1
                            -- Bool, say), so no papExtend is emitted.
                            let
                                unkRes =
                                    if List.isEmpty args then
                                        generateExpr ctx func

                                    else
                                        generateUnknownSegmentationCall ctx func args resultType

                                expectedType =
                                    Types.monoTypeToAbi resultType

                                ( coerceOps, finalVar, finalCtx ) =
                                    coerceResultToType unkRes.ctx
                                        unkRes.resultVar
                                        unkRes.resultType
                                        expectedType
                            in
                            { ops = unkRes.ops ++ coerceOps
                            , resultVar = finalVar
                            , resultType = expectedType
                            , ctx = finalCtx
                            , isTerminated = False
                            }

        Mono.CallDirectFlat ->
            if Types.isFunctionType resultType then
                generateClosureApplication ctx func args resultType callInfo

            else
                generateSaturatedCall ctx func args resultType callInfo

        Mono.CallDirectKnownSegmentation ->
            if callInfo.isSingleStageSaturated then
                -- A global or kernel callee may carry a stamp too, but it is
                -- called directly with eco.call, which beats any papExtend;
                -- only a closure value consults the stamp.
                case func of
                    Mono.MonoVarGlobal _ _ _ ->
                        generateSaturatedCall ctx func args resultType callInfo

                    Mono.MonoVarKernel _ _ _ _ _ ->
                        generateSaturatedCall ctx func args resultType callInfo

                    _ ->
                        case fastDispatchStamp callInfo args of
                            Just ( fastLambdaId, fastAbi, papPrefix ) ->
                                generateFastDispatchCall ctx func args resultType fastLambdaId fastAbi papPrefix

                            Nothing ->
                                generateSaturatedCall ctx func args resultType callInfo

            else
                case fastDispatchStamp callInfo args of
                    Just ( fastLambdaId, fastAbi, papPrefix ) ->
                        generateFastDispatchCall ctx func args resultType fastLambdaId fastAbi papPrefix

                    Nothing ->
                        case fastDispatchStampStaged callInfo args of
                            Just ( fastLambdaId, fastAbi ) ->
                                generateStagedFastDispatchCall ctx func args resultType fastLambdaId fastAbi

                            Nothing ->
                                generateClosureApplication ctx func args resultType callInfo


{-| Returns the `_gencall_reason` attribute recording why a papExtend is
generic, or nothing when the configuration's `mono.stagingReport` census flag
is off.

The reasons written here are 1 to 6 for the shape of the callee
(`gencallCalleeReason`), 7 for a batch after the first in a stage-by-stage
application, 8 for a generic call kind applied stage by stage, and 9 for the
arguments beyond the first stage of a stamped call.

-}
gencallReasonAttr : Ctx.Context -> Int -> List ( String, MlirAttr )
gencallReasonAttr ctx reason =
    if ctx.ecoConfig.mono.stagingReport then
        [ ( "_gencall_reason", IntAttr Nothing reason ) ]

    else
        []


{-| Returns the `_gencall_reason` number for a callee's shape: 1 a local
variable, 2 a call result, 3 a record field, 4 a case or if, 5 a global, and 6
anything else.
-}
gencallCalleeReason : Mono.MonoExpr -> Int
gencallCalleeReason func =
    case func of
        Mono.MonoVarLocal _ _ ->
            1

        Mono.MonoCall _ _ _ _ _ ->
            2

        Mono.MonoRecordAccess _ _ _ ->
            3

        Mono.MonoCase _ _ _ _ _ ->
            4

        Mono.MonoIf _ _ _ ->
            4

        Mono.MonoVarGlobal _ _ _ ->
            5

        _ ->
            6


{-| Returns the `_call_kind` attribute text for a call kind, the kind's name in
snake case.
-}
callKindToAttrString : Mono.CallKind -> String
callKindToAttrString callKind =
    case callKind of
        Mono.CallGenericApply ->
            "generic_apply"

        Mono.CallDirectFlat ->
            "direct_flat"

        Mono.CallDirectKnownSegmentation ->
            "direct_known_segmentation"

        Mono.CallSegmentationUnknown ->
            "segmentation_unknown"


{-| Generates a generic application of the callee value to `args`: one
`eco.papExtend` with `_call_kind` `generic_apply` and no `remaining_arity`, so
that the runtime decides from the closure whether the call is saturated.

Only Bool arguments are boxed; Int, Float and Char arguments are passed
unboxed, with their kinds in `slot_kinds`. The op's result type follows the ABI
of `resultType`: a primitive, with the matching `_result_kind`, when that is
`i64`, `f64` or `i16`, and `!eco.value` otherwise. The result is not coerced
further.

-}
generateGenericApply : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateGenericApply ctx func args resultType =
    let
        funcResult : ExprResult
        funcResult =
            generateExpr ctx func

        ( argOps, argsWithTypes, ctx1 ) =
            generateExprListTyped funcResult.ctx args

        ( boxOps, argsForClosure, ctx2 ) =
            boxArgsForClosureBoundary ctx1 argsWithTypes

        allOperandNames =
            funcResult.resultVar :: List.map Tuple.first argsForClosure

        allOperandTypes =
            funcResult.resultType :: List.map Tuple.second argsForClosure

        newargsSlotKinds =
            Ops.slotKindsAttr (List.map Tuple.second argsForClosure)

        ( resVar, ctx3 ) =
            Ctx.freshVar ctx2

        callResultMlirType =
            Types.monoTypeToAbi resultType

        genericApplyResultKind =
            Types.mlirTypeToKind callResultMlirType

        resultMlirType =
            if genericApplyResultKind == 0 then
                Types.ecoValue

            else
                callResultMlirType

        genericApplyResultKindAttr =
            if genericApplyResultKind == 0 then
                []

            else
                [ ( "_result_kind", IntAttr (Just I8) genericApplyResultKind ) ]

        papExtendAttrs =
            Dict.fromList
                ([ ( "_operand_types"
                   , ArrayAttr Nothing
                        (List.map TypeAttr allOperandTypes)
                   )
                 , ( "slot_kinds", newargsSlotKinds )
                 , ( "_call_kind", StringAttr "generic_apply" )
                 ]
                    ++ gencallReasonAttr ctx (gencallCalleeReason func)
                    ++ genericApplyResultKindAttr
                )

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


{-| Generates an application of the callee value to `args` when the callee's
stages are not known: one `eco.papExtend` with `_call_kind`
`segmentation_unknown` and no `remaining_arity`.

Apart from its call kind, it differs from `generateGenericApply` only in how
arguments are prepared:
a primitive argument is boxed when the matching parameter of the callee's
evaluator, if that is known, is `!eco.value`, and a Bool argument always is
(`boxArgsToEvaluatorParams`). The result type follows
the ABI of `resultType` as in `generateGenericApply`.

-}
generateUnknownSegmentationCall : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateUnknownSegmentationCall ctx func args resultType =
    let
        funcResult : ExprResult
        funcResult =
            generateExpr ctx func

        ( argOps, argsWithTypes, ctx1 ) =
            generateExprListTyped funcResult.ctx args

        ( boxOps, argsForClosure, ctx2 ) =
            boxArgsToEvaluatorParams (knownEvaluatorParamAbi ctx func) ctx1 argsWithTypes

        allOperandNames =
            funcResult.resultVar :: List.map Tuple.first argsForClosure

        allOperandTypes =
            funcResult.resultType :: List.map Tuple.second argsForClosure

        newargsSlotKinds =
            Ops.slotKindsAttr (List.map Tuple.second argsForClosure)

        ( resVar, ctx3 ) =
            Ctx.freshVar ctx2

        callResultMlirType =
            Types.monoTypeToAbi resultType

        unknownSegResultKind =
            Types.mlirTypeToKind callResultMlirType

        resultMlirType =
            if unknownSegResultKind == 0 then
                Types.ecoValue

            else
                callResultMlirType

        unknownSegResultKindAttr =
            if unknownSegResultKind == 0 then
                []

            else
                [ ( "_result_kind", IntAttr (Just I8) unknownSegResultKind ) ]

        papExtendAttrs =
            Dict.fromList
                ([ ( "_operand_types"
                   , ArrayAttr Nothing
                        (List.map TypeAttr allOperandTypes)
                   )
                 , ( "slot_kinds", newargsSlotKinds )
                 , ( "_call_kind", StringAttr "segmentation_unknown" )
                 ]
                    ++ gencallReasonAttr ctx (gencallCalleeReason func)
                    ++ unknownSegResultKindAttr
                )

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


{-| Returns the fast-dispatch stamp of a call that supplies more arguments than
the stamped closure's next stage takes, or `Nothing`. Only a stamp on the
closure itself qualifies, not one on a partial application of it
(`fastPapPrefix` set), and the stage must take at least one argument.
-}
fastDispatchStampStaged : Mono.CallInfo -> List Mono.MonoExpr -> Maybe ( FastRef, Mono.CaptureABI )
fastDispatchStampStaged callInfo args =
    case ( callInfo.fastEvaluator, callInfo.captureAbi, callInfo.fastPapPrefix ) of
        ( Just fastLambdaId, Just abi, Nothing ) ->
            if not (List.isEmpty abi.paramTypes) && List.length args > List.length abi.paramTypes then
                Just ( ( fastLambdaId, callInfo.fastEvaluatorSpec ), abi )

            else
                Nothing

        _ ->
            Nothing


{-| Generates a stamped call that supplies more arguments than the stamped
closure's next stage takes. The first stage's arguments go to a fast dispatch
(`generateFastDispatchCall`), whose result is a closure computed at run time;
the remaining arguments are applied to it with one `segmentation_unknown`
`eco.papExtend` (`applySegUnknownToVar`), and the value is coerced to the ABI of
`resultType`.
-}
generateStagedFastDispatchCall : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> FastRef -> Mono.CaptureABI -> ExprResult
generateStagedFastDispatchCall ctx func args resultType fastRef abi =
    let
        stage1Count =
            List.length abi.paramTypes

        batch1 =
            List.take stage1Count args

        rest =
            List.drop stage1Count args

        -- Typed at the closure's own return type, a function, so that the
        -- inner coercion does nothing and the result is the next closure.
        innerRes =
            generateFastDispatchCall ctx func batch1 abi.returnType fastRef abi 0

        tailRes =
            applySegUnknownToVar innerRes.ctx innerRes.resultVar innerRes.resultType rest resultType
    in
    { ops = innerRes.ops ++ tailRes.ops
    , resultVar = tailRes.resultVar
    , resultType = tailRes.resultType
    , ctx = tailRes.ctx
    , isTerminated = False
    }


{-| Generates the application of `args` to the closure already held in
`funcVar`: one `eco.papExtend` with `_call_kind` `segmentation_unknown` and no
`remaining_arity`, coerced to the ABI of `resultType`. Nothing is known about
the closure, so only Bool arguments are boxed.
-}
applySegUnknownToVar : Ctx.Context -> String -> MlirType -> List Mono.MonoExpr -> Mono.MonoType -> ExprResult
applySegUnknownToVar ctx funcVar funcMlirType args resultType =
    let
        ( argOps, argsWithTypes, ctx1 ) =
            generateExprListTyped ctx args

        ( boxOps, argsForClosure, ctx2 ) =
            boxArgsForClosureBoundary ctx1 argsWithTypes

        allOperandNames =
            funcVar :: List.map Tuple.first argsForClosure

        allOperandTypes =
            funcMlirType :: List.map Tuple.second argsForClosure

        newargsSlotKinds =
            Ops.slotKindsAttr (List.map Tuple.second argsForClosure)

        ( resVar, ctx3 ) =
            Ctx.freshVar ctx2

        callResultMlirType =
            Types.monoTypeToAbi resultType

        segResultKind =
            Types.mlirTypeToKind callResultMlirType

        resultMlirType =
            if segResultKind == 0 then
                Types.ecoValue

            else
                callResultMlirType

        segResultKindAttr =
            if segResultKind == 0 then
                []

            else
                [ ( "_result_kind", IntAttr (Just I8) segResultKind ) ]

        papExtendAttrs =
            Dict.fromList
                ([ ( "_operand_types"
                   , ArrayAttr Nothing
                        (List.map TypeAttr allOperandTypes)
                   )
                 , ( "slot_kinds", newargsSlotKinds )
                 , ( "_call_kind", StringAttr "segmentation_unknown" )
                 ]
                    ++ gencallReasonAttr ctx 9
                    ++ segResultKindAttr
                )

        ( ctx4, papExtendOp ) =
            Ops.mlirOp ctx3 "eco.papExtend"
                |> Ops.opBuilder.withOperands allOperandNames
                |> Ops.opBuilder.withResults [ ( resVar, resultMlirType ) ]
                |> Ops.opBuilder.withAttrs papExtendAttrs
                |> Ops.opBuilder.build

        ( coerceOps, finalVar, finalCtx ) =
            coerceResultToType ctx4 resVar resultMlirType callResultMlirType
    in
    { ops = argOps ++ boxOps ++ [ papExtendOp ] ++ coerceOps
    , resultVar = finalVar
    , resultType = callResultMlirType
    , ctx = finalCtx
    , isTerminated = False
    }


{-| Generates a generic application (`generateGenericApply`) and coerces its
value to the ABI of `resultType`.
-}
generateGenericApplyCoerced : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateGenericApplyCoerced ctx func args resultType =
    let
        genericRes =
            generateGenericApply ctx func args resultType

        expectedType =
            Types.monoTypeToAbi resultType

        ( coerceOps, finalVar, finalCtx ) =
            coerceResultToType genericRes.ctx
                genericRes.resultVar
                genericRes.resultType
                expectedType
    in
    { ops = genericRes.ops ++ coerceOps
    , resultVar = finalVar
    , resultType = expectedType
    , ctx = finalCtx
    , isTerminated = False
    }


{-| Returns the call's fast-dispatch stamp when the call supplies exactly the
arguments the stamped closure's next stage takes, at least one: the reference
to the closure, its `CaptureABI`, and the number of arguments a stamped partial
application already holds (`fastPapPrefix`, 0 when the stamp is on the closure
itself).
-}
fastDispatchStamp : Mono.CallInfo -> List Mono.MonoExpr -> Maybe ( FastRef, Mono.CaptureABI, Int )
fastDispatchStamp callInfo args =
    case ( callInfo.fastEvaluator, callInfo.captureAbi ) of
        ( Just fastLambdaId, Just abi ) ->
            if not (List.isEmpty abi.paramTypes) && List.length args == List.length abi.paramTypes then
                Just ( ( fastLambdaId, callInfo.fastEvaluatorSpec ), abi, Maybe.withDefault 0 callInfo.fastPapPrefix )

            else
                Nothing

        _ ->
            Nothing


{-| Generates a call through a callee value that the fast-dispatch stamp says
can only be one particular closure, given exactly that closure's next stage of
arguments. The result is one saturating `eco.papExtend` with `_call_kind`
`singleton_fast`, `remaining_arity` equal to the number of arguments, and
`_fast_evaluator` naming the closure's code, which lets the lowering call that
code directly instead of dispatching through the closure.

Each argument is coerced to the ABI of the matching parameter type in `abi`,
and `_capture_abi` lists the ABI types of `abi.captureTypes`. The symbol is the
closure's `$cap` clone when the closure has captures of its own, and its plain
name when it has none; when the stamp is on a partial application holding
`papPrefix` arguments, those arguments are counted in `captureTypes` but not
as captures, and `_pap_prefix` records them. The op's result has the ABI of
`abi.returnType` and is coerced to the ABI of `resultType`.

The stamp is trusted: nothing here checks that the callee value really is that
closure.

-}
generateFastDispatchCall : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> FastRef -> Mono.CaptureABI -> Int -> ExprResult
generateFastDispatchCall ctx func args resultType fastRef abi papPrefix =
    let
        funcResult : ExprResult
        funcResult =
            generateExpr ctx func

        ( argOps, argsWithTypes, ctx1 ) =
            generateExprListTyped funcResult.ctx args

        paramAbiTypes =
            List.map Types.monoTypeToAbi abi.paramTypes

        ( coerceArgOpsRev, coercedArgsRev, ctx2 ) =
            List.foldl
                (\( ( argVar, argTy ), wantTy ) ( opsAcc, argsAcc, ctxAcc ) ->
                    let
                        ( ops, v, c ) =
                            coerceResultToType ctxAcc argVar argTy wantTy
                    in
                    ( List.reverse ops ++ opsAcc, ( v, wantTy ) :: argsAcc, c )
                )
                ( [], [], ctx1 )
                (List.map2 Tuple.pair argsWithTypes paramAbiTypes)

        coercedArgs =
            List.reverse coercedArgsRev

        fastSymbol =
            -- captureTypes includes the papPrefix arguments a stamped
            -- partial application holds; they are not the closure's own
            -- captures, and a closure without captures has no $cap clone.
            if List.length abi.captureTypes - papPrefix <= 0 then
                fastRefBaseName ctx fastRef

            else
                fastRefBaseName ctx fastRef ++ "$cap"

        retAbiType =
            Types.monoTypeToAbi abi.returnType

        allOperandNames =
            funcResult.resultVar :: List.map Tuple.first coercedArgs

        allOperandTypes =
            funcResult.resultType :: List.map Tuple.second coercedArgs

        newargsSlotKinds =
            Ops.slotKindsAttr (List.map Tuple.second coercedArgs)

        ( resVar, ctx3 ) =
            Ctx.freshVar ctx2

        papExtendAttrs =
            Dict.fromList
                ([ ( "_operand_types"
                   , ArrayAttr Nothing
                        (List.map TypeAttr allOperandTypes)
                   )
                 , ( "slot_kinds", newargsSlotKinds )
                 , ( "remaining_arity", IntAttr Nothing (List.length args) )
                 , ( "_call_kind", StringAttr "singleton_fast" )
                 , ( "_fast_evaluator", SymbolRefAttr fastSymbol )
                 , ( "_capture_abi"
                   , ArrayAttr Nothing (List.map (\t -> TypeAttr (Types.monoTypeToAbi t)) abi.captureTypes)
                   )
                 ]
                    ++ (if papPrefix > 0 then
                            [ ( "_pap_prefix", IntAttr Nothing papPrefix ) ]

                        else
                            []
                       )
                )

        ( ctx4, papExtendOp ) =
            Ops.mlirOp ctx3 "eco.papExtend"
                |> Ops.opBuilder.withOperands allOperandNames
                |> Ops.opBuilder.withResults [ ( resVar, retAbiType ) ]
                |> Ops.opBuilder.withAttrs papExtendAttrs
                |> Ops.opBuilder.build

        expectedType =
            Types.monoTypeToAbi resultType

        ( coerceOps, finalVar, finalCtx ) =
            coerceResultToType ctx4 resVar retAbiType expectedType
    in
    { ops = funcResult.ops ++ argOps ++ List.reverse coerceArgOpsRev ++ [ papExtendOp ] ++ coerceOps
    , resultVar = finalVar
    , resultType = expectedType
    , ctx = finalCtx
    , isTerminated = False
    }


{-| The ops and final value of a stage-by-stage application, as
`applyByStages` returns them: an `ExprResult` without `isTerminated`.
-}
type alias ApplyByStagesResult =
    { ops : List MlirOp
    , resultVar : String
    , resultType : MlirType
    , ctx : Ctx.Context
    }


{-| Applies `args` to the closure `funcVar` one stage at a time, as a chain of
`eco.papExtend` ops, each taking at most the arguments its closure still needs.

`sourceRemaining` is the number of arguments the closure still takes in its
current stage, and becomes each op's `remaining_arity`. When a batch completes
a stage, the result is the closure the stage returns, and the next batch is
sized from `remainingStageArities`. Only the op that completes the last stage
with no arguments left over has the type `saturatedReturnType`, with the
matching `_result_kind`; every other op returns a closure of type
`funcMlirType`. `saturatedReturnType` must be the return type of the function
that last op actually runs, which for a call supplying more than one stage is
not the type of the call itself.

Only the first batch carries `remaining_arity` and the `callKindAttr` call
kind. A later batch is applied to a closure computed at run time, about which
nothing is known, so it is a `segmentation_unknown` op without
`remaining_arity`.

If `sourceRemaining` is zero or less while arguments remain, those arguments
are dropped and the current value is returned.

-}
applyByStages :
    Ctx.Context
    -> String -- funcVar: the closure
    -> MlirType -- funcMlirType: the closure's type
    -> Int -- sourceRemaining: arguments the closure takes in its current stage
    -> List Int -- remainingStageArities: arities of the stages after it
    -> MlirType -- saturatedReturnType: ABI result of the last stage's function
    -> Maybe String -- callKindAttr: _call_kind of the first op only
    -> List ( String, MlirType ) -- args: arguments still to apply
    -> List MlirOp -- accumulated ops, in reverse order
    -> List MlirType -- accCaptureTypes: types of arguments already applied; [] on the first batch
    -> ApplyByStagesResult
applyByStages ctx funcVar funcMlirType sourceRemaining remainingStageArities saturatedReturnType callKindAttr args accOps accCaptureTypes =
    case args of
        [] ->
            { ops = List.reverse accOps, resultVar = funcVar, resultType = funcMlirType, ctx = ctx }

        _ ->
            if sourceRemaining <= 0 then
                -- The remaining args are dropped here.
                { ops = List.reverse accOps, resultVar = funcVar, resultType = funcMlirType, ctx = ctx }

            else
                let
                    batchSize =
                        min sourceRemaining (List.length args)

                    batch =
                        List.take batchSize args

                    rest =
                        List.drop batchSize args

                    newargsSlotKinds =
                        Ops.slotKindsAttr (List.map Tuple.second batch)

                    ( resVar, ctx1 ) =
                        Ctx.freshVar ctx

                    allOperandNames =
                        funcVar :: List.map Tuple.first batch

                    allOperandTypes =
                        funcMlirType :: List.map Tuple.second batch

                    -- remaining_arity counts what the closure takes before this
                    -- op, not what the result takes.
                    remainingArity =
                        sourceRemaining

                    rawResultRemaining =
                        sourceRemaining - batchSize

                    ( resultRemaining, nextStageArities ) =
                        if rawResultRemaining <= 0 then
                            case remainingStageArities of
                                nextArity :: restArities ->
                                    ( nextArity, restArities )

                                [] ->
                                    ( 0, [] )

                        else
                            ( rawResultRemaining, remainingStageArities )

                    isSaturatedCall =
                        rawResultRemaining <= 0 && List.isEmpty rest && List.isEmpty remainingStageArities

                    resultMlirType =
                        if isSaturatedCall then
                            saturatedReturnType

                        else
                            funcMlirType

                    -- An earlier stage returns a boxed closure, so only the last
                    -- stage may carry a primitive _result_kind.
                    saturatedResultKind =
                        if isSaturatedCall then
                            Types.mlirTypeToKind saturatedReturnType

                        else
                            0

                    resultKindAttrs =
                        if saturatedResultKind == 0 then
                            []

                        else
                            [ ( "_result_kind", IntAttr (Just I8) saturatedResultKind ) ]

                    -- A batch after the first extends whatever closure the
                    -- previous stage returned at run time, which can be any
                    -- function, so nothing about its layout or arity is
                    -- claimed.
                    isCrossStage =
                        not (List.isEmpty accCaptureTypes)

                    baseAttrs =
                        [ ( "_operand_types"
                          , ArrayAttr Nothing
                                (List.map TypeAttr allOperandTypes)
                          )
                        , ( "slot_kinds", newargsSlotKinds )
                        ]
                            ++ (if isCrossStage then
                                    []

                                else
                                    [ ( "remaining_arity", IntAttr Nothing remainingArity ) ]
                               )
                            ++ resultKindAttrs

                    callKindAttrs =
                        -- Later batches recurse with callKindAttr = Nothing, so
                        -- the cross-stage kind is set here regardless of it.
                        if isCrossStage then
                            ( "_call_kind", StringAttr "segmentation_unknown" ) :: gencallReasonAttr ctx 7

                        else
                            case callKindAttr of
                                Just ck ->
                                    ( "_call_kind", StringAttr ck )
                                        :: (if ck == "segmentation_unknown" || ck == "generic_apply" then
                                                gencallReasonAttr ctx 8

                                            else
                                                []
                                           )

                                Nothing ->
                                    []

                    papExtendAttrs =
                        Dict.fromList (baseAttrs ++ callKindAttrs)

                    ( ctx2, papExtendOp ) =
                        Ops.mlirOp ctx1 "eco.papExtend"
                            |> Ops.opBuilder.withOperands allOperandNames
                            |> Ops.opBuilder.withResults [ ( resVar, resultMlirType ) ]
                            |> Ops.opBuilder.withAttrs papExtendAttrs
                            |> Ops.opBuilder.build

                    nextOps =
                        papExtendOp :: accOps

                    nextCaptureTypes =
                        accCaptureTypes ++ List.map Tuple.second batch
                in
                if List.isEmpty rest then
                    { ops = List.reverse nextOps, resultVar = resVar, resultType = resultMlirType, ctx = ctx2 }

                else
                    applyByStages ctx2 resVar resultMlirType resultRemaining nextStageArities saturatedReturnType Nothing rest nextOps nextCaptureTypes


{-| Generates a partial application of an external or kernel function, which
takes all its arguments in one flat call: the function's closure value, then
one `eco.papExtend` whose `remaining_arity` is the function's total number of
parameters over all stages. Arguments are boxed to the function's parameter
types as `boxArgsToEvaluatorParams` does, and the result has the ABI type of
`resultType`.
-}
generateFlattenedPartialApplication :
    Ctx.Context
    -> Mono.MonoExpr
    -> List Mono.MonoExpr
    -> Mono.MonoType
    -> ExprResult
generateFlattenedPartialApplication ctx func args resultType =
    let
        funcResult : ExprResult
        funcResult =
            generateExpr ctx func

        ( argOps, argsWithTypes, ctx1 ) =
            generateExprListTyped funcResult.ctx args

        totalArity =
            case func of
                Mono.MonoVarGlobal _ specId _ ->
                    case Array.get specId ctx.signatures |> Maybe.andThen identity of
                        Just sig ->
                            List.length sig.paramTypes

                        Nothing ->
                            Types.countTotalArity (Mono.typeOf func)

                Mono.MonoVarKernel _ _ _ _ kernelType ->
                    List.length (Ctx.kernelFuncSignatureFromType kernelType).paramTypes

                _ ->
                    Types.countTotalArity (Mono.typeOf func)

        ( boxOps, boxedArgsWithTypes, ctx1b ) =
            boxArgsToEvaluatorParams (knownEvaluatorParamAbi ctx func) ctx1 argsWithTypes

        ( resVar, ctx2 ) =
            Ctx.freshVar ctx1b

        allOperandNames =
            funcResult.resultVar :: List.map Tuple.first boxedArgsWithTypes

        allOperandTypes =
            funcResult.resultType :: List.map Tuple.second boxedArgsWithTypes

        newargsSlotKinds =
            Ops.slotKindsAttr (List.map Tuple.second boxedArgsWithTypes)

        remainingArity =
            totalArity

        resultMlirType =
            Types.monoTypeToAbi resultType

        flatPapResultKind =
            Types.mlirTypeToKind resultMlirType

        flatPapResultKindAttr =
            if flatPapResultKind == 0 then
                []

            else
                [ ( "_result_kind", IntAttr (Just I8) flatPapResultKind ) ]

        papExtendAttrs =
            Dict.fromList
                ([ ( "_operand_types"
                   , ArrayAttr Nothing
                        (List.map TypeAttr allOperandTypes)
                   )
                 , ( "remaining_arity", IntAttr Nothing remainingArity )
                 , ( "slot_kinds", newargsSlotKinds )
                 ]
                    ++ flatPapResultKindAttr
                )

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


{-| Returns the ABI type of `evaluatorReturnType`, the result of the function
a saturating call actually runs. For a call that supplies more than one stage
of arguments this differs from the ABI type of the call's own result.
-}
evaluatorAbiResultType : Mono.CallInfo -> MlirType
evaluatorAbiResultType callInfo =
    Types.monoTypeToAbi callInfo.evaluatorReturnType


{-| Generates an application through a closure by `eco.papExtend`, for a
partial application or a call spanning several stages.

An external or kernel callee (`FlattenedExternal`) goes to
`generateFlattenedPartialApplication`. Any other callee has its arguments boxed
to the callee's known parameter types (`boxArgsToEvaluatorParams`) and applied
stage by stage from the `CallInfo` arities (`applyByStages`); the value is
then coerced to the ABI of `resultType`. A callee whose value is not
`!eco.value`, applied to no arguments, is already the call's value and is only
coerced.

-}
generateClosureApplication : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> Mono.CallInfo -> ExprResult
generateClosureApplication ctx func args resultType callInfo =
    case callInfo.callModel of
        Mono.FlattenedExternal ->
            generateFlattenedPartialApplication ctx func args resultType

        Mono.StageCurried ->
            let
                funcResult : ExprResult
                funcResult =
                    generateExpr ctx func

                callResultMlirType =
                    Types.monoTypeToAbi resultType

                evaluatorResultMlirType =
                    evaluatorAbiResultType callInfo
            in
            if not (Types.isEcoValueType funcResult.resultType) && List.isEmpty args then
                let
                    ( coerceOps, finalVar, ctx1 ) =
                        coerceResultToType funcResult.ctx funcResult.resultVar funcResult.resultType callResultMlirType
                in
                { ops = funcResult.ops ++ coerceOps
                , resultVar = finalVar
                , resultType = callResultMlirType
                , ctx = ctx1
                , isTerminated = False
                }

            else
                let
                    ( argOps, argsWithTypes, ctx1 ) =
                        generateExprListTyped funcResult.ctx args

                    ( boxOps, boxedArgsWithTypes, ctx1b ) =
                        boxArgsToEvaluatorParams (knownEvaluatorParamAbi ctx func) ctx1 argsWithTypes

                    initialRemaining =
                        callInfo.initialRemaining

                    remainingStageArities =
                        callInfo.remainingStageArities

                    papResult =
                        applyByStages ctx1b funcResult.resultVar funcResult.resultType initialRemaining remainingStageArities evaluatorResultMlirType (Just (callKindToAttrString callInfo.callKind)) boxedArgsWithTypes [] []

                    -- The last stage's function may return a different ABI type
                    -- from the call's own, e.g. a boxed polymorphic result.
                    ( coerceOps, finalVar, ctxFinal ) =
                        coerceResultToType papResult.ctx papResult.resultVar papResult.resultType callResultMlirType
                in
                { ops = funcResult.ops ++ argOps ++ boxOps ++ papResult.ops ++ coerceOps
                , resultVar = finalVar
                , resultType = callResultMlirType
                , ctx = ctxFinal
                , isTerminated = False
                }


{-| Boxes the Bool (`i1`) values among `argsWithTypes` and leaves every other
value, including Int, Float and Char, as it is. This is the preparation for
passing values into a closure when nothing is known about what it takes.
-}
boxArgsForClosureBoundary : Ctx.Context -> List ( String, MlirType ) -> ( List MlirOp, List ( String, MlirType ), Ctx.Context )
boxArgsForClosureBoundary ctx argsWithTypes =
    let
        ( opsReversed, argsReversed, ctxFinal ) =
            List.foldl
                (\( var, mlirTy ) ( opsAcc, argsAcc, ctxAcc ) ->
                    if mlirTy == I1 then
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


{-| Boxes each argument that the closure's function takes as `!eco.value`,
given `paramAbis`, the ABI types of that function's leading parameters (`[]`
when they are not known). Argument _i_ is boxed when it is not already an
`!eco.value` and parameter _i_ is one, as happens when the function keeps a
type variable boxed that the call site has made an Int. A Bool argument is
always boxed. Arguments beyond `paramAbis` are treated as
`boxArgsForClosureBoundary` treats them.
-}
boxArgsToEvaluatorParams : List MlirType -> Ctx.Context -> List ( String, MlirType ) -> ( List MlirOp, List ( String, MlirType ), Ctx.Context )
boxArgsToEvaluatorParams paramAbis ctx argsWithTypes =
    let
        step ( var, mlirTy ) ( params, ( opsAcc, argsAcc, ctxAcc ) ) =
            let
                ( paramIsBoxed, restParams ) =
                    case params of
                        p :: ps ->
                            ( Types.isEcoValueType p, ps )

                        [] ->
                            ( False, [] )

                needsBoxing =
                    mlirTy == I1 || (paramIsBoxed && not (Types.isEcoValueType mlirTy))
            in
            if needsBoxing then
                let
                    ( boxOps, boxedVar, ctx1 ) =
                        boxToEcoValue ctxAcc var mlirTy
                in
                ( restParams, ( List.reverse boxOps ++ opsAcc, ( boxedVar, Types.ecoValue ) :: argsAcc, ctx1 ) )

            else
                ( restParams, ( opsAcc, ( var, mlirTy ) :: argsAcc, ctxAcc ) )

        ( _, ( opsReversed, argsReversed, ctxFinal ) ) =
            List.foldl step ( paramAbis, ( [], [], ctx ) ) argsWithTypes
    in
    ( List.reverse opsReversed, List.reverse argsReversed, ctxFinal )


{-| Returns the ABI parameter types of the function a callee expression
names, when that is known: a global specialization's signature, a kernel's
signature, or, for a local variable, what `trackLocalEvaluatorParams` recorded
for it. Any other callee, or a global without a signature, gives `[]`.
-}
knownEvaluatorParamAbi : Ctx.Context -> Mono.MonoExpr -> List MlirType
knownEvaluatorParamAbi ctx func =
    case func of
        Mono.MonoVarGlobal _ specId _ ->
            case Array.get specId ctx.signatures |> Maybe.andThen identity of
                Just sig ->
                    List.map Types.monoTypeToAbi sig.paramTypes

                Nothing ->
                    []

        Mono.MonoVarKernel _ _ _ _ kernelType ->
            List.map Types.monoTypeToAbi (Ctx.kernelFuncSignatureFromType kernelType).paramTypes

        Mono.MonoVarLocal name _ ->
            Dict.get name ctx.localEvaluatorParams |> Maybe.withDefault []

        _ ->
            []


{-| Returns the context with the ABI parameter types of the function `expr`
names recorded for the let-bound local `name`, so that calls through the local
box their arguments as calls through that function would. When `expr` names no
known function, any entry for `name` is removed, so a rebinding of the same
name never inherits an old one.
-}
trackLocalEvaluatorParams : String -> Mono.MonoExpr -> Ctx.Context -> Ctx.Context
trackLocalEvaluatorParams name expr ctx =
    case knownEvaluatorParamAbi ctx expr of
        [] ->
            if Dict.member name ctx.localEvaluatorParams then
                { ctx | localEvaluatorParams = Dict.remove name ctx.localEvaluatorParams }

            else
                ctx

        paramAbis ->
            { ctx | localEvaluatorParams = Dict.insert name paramAbis ctx.localEvaluatorParams }


{-| Tries to generate the let `def` with `body` as a fused bytes decode, and
returns `Nothing` when it is not one or the decoder cannot be fused.

An inlined `Bytes.Decode.decode` has this shape: one or more let bindings, one
of which holds the decoder, then a destructuring, then a kernel `Bytes.decode`
call with the bytes as its second argument.

    MonoLet (MonoDef name decoderExpr)
        (MonoDestruct ...
            (MonoCall (MonoVarKernel "Bytes" "decode") [ _, bytesExpr ] ...))

Unlike encoder fusion, this is attempted whatever the configuration's
`bytesFusion` flag says.

-}
tryInlinedDecodeFusion : Ctx.Context -> Mono.MonoDef -> Mono.MonoExpr -> Maybe ExprResult
tryInlinedDecodeFusion ctx def body =
    case def of
        Mono.MonoDef defName decoderExpr ->
            tryDecodeFusionWithBindings ctx [ ( defName, decoderExpr ) ] body

        Mono.MonoTailDef _ _ _ ->
            Nothing


{-| Produces the callback bytes fusion uses to compile an ordinary expression
left inside a fused encoder or decoder.

Reification walks past let bindings without compiling them, so such an
expression can name a variable that was never given an SSA value. Before
compiling, each variable that is not in the context's `varMappings` is
replaced by the expression `fusedLets` binds it to (see `resolveFusedLets`).
A variable that is in `varMappings` is left alone.

-}
bfExprCompiler : Dict.Dict Name.Name Mono.MonoExpr -> BFEmit.ExprCompiler
bfExprCompiler fusedLets monoExpr compilerCtx =
    let
        result =
            generateExpr compilerCtx (resolveFusedLets fusedLets compilerCtx monoExpr)
    in
    { ops = result.ops
    , resultVar = result.resultVar
    , resultType = result.resultType
    , ctx = result.ctx
    }


{-| Returns `expr` with each local variable that has no entry in `varMappings`
replaced by the expression it is bound to, recursively: first from
`fusedLets`, then from a let anywhere in the context's inlined bodies
(`findLetInInlineBodies`). A variable found in neither is left as it is.
-}
resolveFusedLets : Dict.Dict Name.Name Mono.MonoExpr -> Ctx.Context -> Mono.MonoExpr -> Mono.MonoExpr
resolveFusedLets fusedLets ctx expr =
    MonoTraverse.mapExpr
        (\e ->
            case e of
                Mono.MonoVarLocal name _ ->
                    if Dict.member name ctx.varMappings then
                        Nothing

                    else
                        case Dict.get name fusedLets of
                            Just bound ->
                                Just (resolveFusedLets fusedLets ctx bound)

                            Nothing ->
                                -- Reification also walks past lets inside the
                                -- inlined bodies it pulls in, which fusedLets
                                -- does not contain.
                                case findLetInInlineBodies name ctx of
                                    Just bound ->
                                        Just (resolveFusedLets fusedLets ctx bound)

                                    Nothing ->
                                        Nothing

                _ ->
                    Nothing
        )
        expr


{-| Returns the expression bound to `name` by a non-recursive let somewhere in
one of the context's `inlineBodies`, the first one found, if any.
-}
findLetInInlineBodies : Name.Name -> Ctx.Context -> Maybe Mono.MonoExpr
findLetInInlineBodies name ctx =
    Dict.foldl
        (\_ ( _, bodyExpr ) acc ->
            case acc of
                Just _ ->
                    acc

                Nothing ->
                    MonoTraverse.foldExpr
                        (\e found ->
                            case found of
                                Just _ ->
                                    found

                                Nothing ->
                                    case e of
                                        Mono.MonoLet (Mono.MonoDef n b) _ _ ->
                                            if n == name then
                                                Just b

                                            else
                                                Nothing

                                        _ ->
                                            Nothing
                        )
                        Nothing
                        bodyExpr
        )
        Nothing
        ctx.inlineBodies


{-| Returns every non-recursive let binding anywhere in `expr`, by name.
Where a name is bound twice, the binding the fold visits last wins.
-}
collectFusedLets : Mono.MonoExpr -> Dict.Dict Name.Name Mono.MonoExpr
collectFusedLets expr =
    MonoTraverse.foldExpr
        (\e acc ->
            case e of
                Mono.MonoLet (Mono.MonoDef n b) _ _ ->
                    Dict.insert n b acc

                _ ->
                    acc
        )
        Dict.empty
        expr


{-| Returns the bindings of `chain`, those inside their bound expressions, and
those inside `body`, by name, for `bfExprCompiler`.
-}
fusedLetsFromChain : List ( Name.Name, Mono.MonoExpr ) -> Mono.MonoExpr -> Dict.Dict Name.Name Mono.MonoExpr
fusedLetsFromChain chain body =
    List.foldl
        (\( n, b ) acc -> Dict.union (collectFusedLets b) (Dict.insert n b acc))
        (collectFusedLets body)
        chain


{-| Returns the non-recursive let bindings inside any of `exprs`, by name.
-}
fusedLetsFromExprs : List Mono.MonoExpr -> Dict.Dict Name.Name Mono.MonoExpr
fusedLetsFromExprs exprs =
    List.foldl (\e acc -> Dict.union (collectFusedLets e) acc) Dict.empty exprs


{-| Looks through a chain of lets, collecting their bindings in `bindings`
(innermost first), for a destructuring whose body is a kernel `Bytes.decode`
call, and generates a fused decode when the decoder can be found among the
bindings and reified.

On success the collected bindings are compiled first, so that expressions
inside the fused decoder can refer to them, and the result is the fused
decoder's `!eco.value`. Otherwise it returns `Nothing` and the let is compiled
normally.

-}
tryDecodeFusionWithBindings : Ctx.Context -> List ( Name.Name, Mono.MonoExpr ) -> Mono.MonoExpr -> Maybe ExprResult
tryDecodeFusionWithBindings ctx bindings body =
    case body of
        Mono.MonoDestruct _ innerBody _ ->
            case findKernelDecodeCall innerBody of
                Just bytesExpr ->
                    case resolveDecoderExpr ctx.registry ctx.decoderExprs bindings of
                        Just decoderNode ->
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
                                exprCompiler =
                                    bfExprCompiler (fusedLetsFromChain bindings body)

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
                            Nothing

                Nothing ->
                    Nothing

        Mono.MonoLet (Mono.MonoDef innerName innerExpr) innerBody _ ->
            tryDecodeFusionWithBindings ctx (( innerName, innerExpr ) :: bindings) innerBody

        _ ->
            Nothing


{-| Returns the first of `bindings` (innermost first) whose expression reifies
as a decoder. A binding that is a variable is followed: to an outer binding of
that name in the chain (`resolveDecoderByName`), then to the context's cache of
decoder expressions.
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
                    case expr of
                        Mono.MonoVarLocal name _ ->
                            case resolveDecoderByName registry decoderExprs name rest of
                                Just node ->
                                    Just node

                                Nothing ->
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
                            resolveDecoderExpr registry decoderExprs rest


{-| Returns the decoder that the binding of `targetName` in `bindings`
reifies to, following a chain of variable-to-variable bindings outwards.
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
                        case expr of
                            Mono.MonoVarLocal innerName _ ->
                                resolveDecoderByName registry decoderExprs innerName rest

                            _ ->
                                Nothing

            else
                resolveDecoderByName registry decoderExprs targetName rest


{-| Returns `expr` reified as a decoder, if it can be. Reification can see
through a variable to a decoder expression recorded in the context's
`decoderExprs`.
-}
resolveDecoderNode : Ctx.Context -> Mono.MonoExpr -> Maybe BFReify.DecoderNode
resolveDecoderNode ctx expr =
    BFReify.reifyDecoder ctx.registry ctx.decoderExprs expr


{-| Generates each of `bindings` in order and maps its name to the value, so
that later code, including expressions inside a fused encoder or decoder, can
refer to it. The mappings are left in the returned context.
-}
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


{-| Generates a fused encode of `encoderExpr`, or returns `Nothing` when the
configuration's `bytesFusion` flag is off or the encoder cannot be reified.

The lets at the head of `encoderExpr` are collected into `accumulated` and
the expression under them is reified, with the collected bindings visible to
reification. On success the bindings are compiled first
(`compileSkippedBindings`), so that expressions left inside the fused encoder
can refer to them, and the result is the encoded bytes as an `!eco.value`.

-}
tryEncoderFusionWithBindings :
    Ctx.Context
    -> List ( Name.Name, Mono.MonoExpr )
    -> Mono.MonoExpr
    -> Maybe ExprResult
tryEncoderFusionWithBindings ctx accumulated encoderExpr =
    case encoderExpr of
        Mono.MonoLet (Mono.MonoDef innerName innerExpr) innerBody _ ->
            tryEncoderFusionWithBindings ctx
                (( innerName, innerExpr ) :: accumulated)
                innerBody

        _ ->
            let
                localCache : Dict.Dict String Mono.MonoExpr
                localCache =
                    List.foldl
                        (\( n, e ) acc -> Dict.insert n e acc)
                        ctx.decoderExprs
                        accumulated
            in
            case
                if ctx.ecoConfig.bytesFusion.enabled then
                    BFReify.reifyEncoderWith ctx.inlineBodies ctx.registry localCache encoderExpr

                else
                    Nothing
            of
                Just nodes ->
                    let
                        loopOps =
                            BFReify.nodesToOps nodes

                        exprCompiler : BFEmit.ExprCompiler
                        exprCompiler =
                            bfExprCompiler (fusedLetsFromChain accumulated encoderExpr)

                        ( bindingOps, ctxAfterBindings ) =
                            compileSkippedBindings ctx (List.reverse accumulated)

                        ( mlirOps, bufferVar, ctx2 ) =
                            BFEmit.emitFusedEncoder exprCompiler ctxAfterBindings loopOps
                    in
                    Just
                        { ops = bindingOps ++ mlirOps
                        , resultVar = bufferVar
                        , resultType = Types.ecoValue
                        , ctx = ctx2
                        , isTerminated = False
                        }

                Nothing ->
                    Nothing


{-| Generates a fused encode when `func` applied to `args` is
`Bytes.Encode.encode` (as a global of elm/bytes, or as the kernel
`Bytes.encode`) with one argument, as `tryEncoderFusionWithBindings` does.
Returns `Nothing` for any other call, or when fusion fails.
-}
tryBytesEncodeFusion : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Maybe ExprResult
tryBytesEncodeFusion ctx func args =
    let
        encoderArg : Maybe Mono.MonoExpr
        encoderArg =
            case func of
                Mono.MonoVarGlobal _ specId _ ->
                    case Registry.lookupSpecKey specId ctx.registry of
                        Just ( Mono.Global (ModuleName.Canonical pkg moduleName) name, _ ) ->
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

                Mono.MonoVarKernel _ _ "Bytes" "encode" _ ->
                    case args of
                        [ encoderExpr ] ->
                            Just encoderExpr

                        _ ->
                            Nothing

                _ ->
                    Nothing
    in
    case encoderArg of
        Just encoderExpr ->
            tryEncoderFusionWithBindings ctx [] encoderExpr

        Nothing ->
            Nothing


{-| Returns the bytes argument of a two-argument kernel `Bytes.decode` call,
found at `expr` or under any number of lets.
-}
findKernelDecodeCall : Mono.MonoExpr -> Maybe Mono.MonoExpr
findKernelDecodeCall expr =
    case expr of
        Mono.MonoCall _ (Mono.MonoVarKernel _ _ "Bytes" "decode" _) args _ _ ->
            case args of
                [ _, bytesExpr ] ->
                    Just bytesExpr

                _ ->
                    Nothing

        Mono.MonoLet _ innerBody _ ->
            findKernelDecodeCall innerBody

        _ ->
            Nothing


{-| Generates a call that supplies all the arguments its callee takes. The
first of these that applies is used: a constructor call built in place
(`tryCtorInline`), a call to the callee's `$psplit` worker (`tryPsplitCall`), a
fused bytes encode (`tryBytesEncodeFusion`), and otherwise
`generateSaturatedCallNoFusion`.
-}
generateSaturatedCall : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> Mono.CallInfo -> ExprResult
generateSaturatedCall ctx func args resultType callInfo =
    case tryCtorInline ctx func args resultType of
        Just inlined ->
            inlined

        Nothing ->
            case tryPsplitCall ctx func args resultType of
                Just migrated ->
                    migrated

                Nothing ->
                    generateSaturatedCallFusionGate ctx func args resultType callInfo


{-| Generates a saturated call as a fused bytes encode when it is one, and
through `generateSaturatedCallNoFusion` otherwise.
-}
generateSaturatedCallFusionGate : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> Mono.CallInfo -> ExprResult
generateSaturatedCallFusionGate ctx func args resultType callInfo =
    case () of
        _ ->
            case tryBytesEncodeFusion ctx func args of
                Just fusedResult ->
                    fusedResult

                Nothing ->
                    generateSaturatedCallNoFusion ctx func args resultType callInfo


{-| Generates a saturated call to a global that has a `$psplit` worker as a
call to that worker, or returns `Nothing` to leave it an ordinary call.

A `$psplit` worker takes some tuple or constructor parameters as their fields,
one argument per field (see `Context.PsplitInfo`). The call is redirected only
when the argument at every such position can supply its fields without
reading them from a heap object (`psplitArgFree`); otherwise the ordinary
function, which takes the boxed value, is called.

-}
tryPsplitCall : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> Maybe ExprResult
tryPsplitCall ctx func args resultType =
    if Dict.isEmpty ctx.psplitPromoted then
        Nothing

    else
        case func of
            Mono.MonoVarGlobal _ specId _ ->
                case Dict.get specId ctx.psplitPromoted of
                    Just info ->
                        if
                            (List.length args == List.length info.paramPlans)
                                && List.all
                                    (\( mPlan, arg ) ->
                                        case mPlan of
                                            Just plan ->
                                                psplitArgFree ctx plan arg

                                            Nothing ->
                                                True
                                    )
                                    (List.map2 Tuple.pair info.paramPlans args)
                        then
                            Just (emitPsplitCall ctx specId info args resultType)

                        else
                            Nothing

                    Nothing ->
                        Nothing

            _ ->
                Nothing


{-| Tells whether `arg` can supply the slots of `plan` without a heap read: a
tuple literal of the plan's arity; a call to the constructor the plan splits
with one argument per field; a call to a global whose `$sret` worker returns
exactly the plan's tuple slots; a variable already held as slots of the
plan's types; or a variable holding a value aggregate of the plan's type.
`emitPsplitSlotArg` must accept exactly these shapes.
-}
psplitArgFree : Ctx.Context -> Ctx.SlotPlan -> Mono.MonoExpr -> Bool
psplitArgFree ctx plan arg =
    case arg of
        Mono.MonoTupleCreate _ es _ ->
            case plan.spec of
                Ctx.SplitTuple layout ->
                    List.length es == layout.arity

                _ ->
                    False

        Mono.MonoCall _ (Mono.MonoVarGlobal _ sid _) cargs _ _ ->
            case ( plan.spec, Dict.get sid ctx.ctorBySpec ) of
                ( Ctx.SplitCtor clayout, Just shape ) ->
                    shape.name == clayout.name && List.length cargs == List.length clayout.fields

                _ ->
                    case ( plan.spec, Dict.get sid ctx.sretPromoted ) of
                        ( Ctx.SplitTuple _, Just sinfo ) ->
                            sinfo.slotTypes == plan.slotTypes

                        _ ->
                            False

        Mono.MonoVarLocal v _ ->
            case Dict.get v ctx.splitAggParams of
                Just entry ->
                    List.map Tuple.second entry.slots == plan.slotTypes

                Nothing ->
                    case Dict.get v ctx.varMappings of
                        Just vi ->
                            vi.mlirType == psplitAggType plan

                        Nothing ->
                            False

        _ ->
            False


{-| Returns the value-aggregate type, tuple or constructor, whose fields are
the plan's slots.
-}
psplitAggType : Ctx.SlotPlan -> MlirType
psplitAggType plan =
    case plan.spec of
        Ctx.SplitTuple _ ->
            Ops.aggTupleType plan.slotTypes

        Ctx.SplitCtor _ ->
            Ops.aggCustomType plan.slotTypes


{-| Generates the call to the `$psplit` worker of `specId`: each promoted
argument contributes its slots (`emitPsplitSlotArg`), and every other argument
is coerced to the ABI of the matching parameter in the function's signature.
The result has the ABI of the signature's return type, or of `resultType` when
there is no signature.
-}
emitPsplitCall : Ctx.Context -> Int -> Ctx.PsplitInfo -> List Mono.MonoExpr -> Mono.MonoType -> ExprResult
emitPsplitCall ctx specId info args resultType =
    let
        funcName =
            specIdToFuncName ctx.registry specId

        maybeSig =
            Array.get specId ctx.signatures |> Maybe.andThen identity

        sigParamAbi idx =
            maybeSig
                |> Maybe.andThen (\sig -> List.head (List.drop idx sig.paramTypes))
                |> Maybe.map Types.monoTypeToAbi

        ( opsRev, operandsRev, ctxA ) =
            List.foldl
                (\( idx, ( mPlan, arg ) ) ( opsAcc, argsAcc, ctxAcc ) ->
                    case mPlan of
                        Nothing ->
                            let
                                r =
                                    generateExpr ctxAcc arg

                                ( coOps, fv, ctxCo ) =
                                    case sigParamAbi idx of
                                        Just abiTy ->
                                            coerceResultToType r.ctx r.resultVar r.resultType abiTy

                                        Nothing ->
                                            ( [], r.resultVar, r.ctx )

                                fvTy =
                                    Maybe.withDefault r.resultType (sigParamAbi idx)
                            in
                            ( List.reverse (r.ops ++ coOps) ++ opsAcc, ( fv, fvTy ) :: argsAcc, ctxCo )

                        Just plan ->
                            let
                                ( sOps, slotPairs, ctxS ) =
                                    emitPsplitSlotArg ctxAcc plan arg
                            in
                            ( List.reverse sOps ++ opsAcc, List.reverse slotPairs ++ argsAcc, ctxS )
                )
                ( [], [], ctx )
                (List.indexedMap Tuple.pair (List.map2 Tuple.pair info.paramPlans args))

        returnAbi =
            case maybeSig of
                Just sig ->
                    Types.monoTypeToAbi sig.returnType

                Nothing ->
                    Types.monoTypeToAbi resultType

        ( resultVar, ctxB ) =
            Ctx.freshVar ctxA

        ( ctxC, callOp ) =
            Ops.ecoCallNamed ctxB resultVar (funcName ++ "$psplit") (List.reverse operandsRev) returnAbi
    in
    { ops = List.reverse opsRev ++ [ callOp ]
    , resultVar = resultVar
    , resultType = returnAbi
    , ctx = ctxC
    , isTerminated = False
    }


{-| Generates the slot values `arg` supplies for one promoted parameter, for
exactly the shapes `psplitArgFree` admits: the elements of a literal or
constructor call, each coerced to its slot type; the results of a `$sret`
call; the slots of a variable already held as slots; or projections from a
value-aggregate variable. Any other shape crashes the compiler.
-}
emitPsplitSlotArg : Ctx.Context -> Ctx.SlotPlan -> Mono.MonoExpr -> ( List MlirOp, List ( String, MlirType ), Ctx.Context )
emitPsplitSlotArg ctx plan arg =
    let
        inlineElements es =
            List.foldl
                (\( e, slotTy ) ( opsAcc, pairsAcc, ctxAcc ) ->
                    let
                        r =
                            generateExpr ctxAcc e

                        ( co, fv, ctxC ) =
                            coerceResultToType r.ctx r.resultVar r.resultType slotTy
                    in
                    ( opsAcc ++ r.ops ++ co, pairsAcc ++ [ ( fv, slotTy ) ], ctxC )
                )
                ( [], [], ctx )
                (List.map2 Tuple.pair es plan.slotTypes)
    in
    case arg of
        Mono.MonoTupleCreate _ es _ ->
            inlineElements es

        Mono.MonoCall _ (Mono.MonoVarGlobal _ sid _) cargs _ _ ->
            case ( plan.spec, Dict.get sid ctx.sretPromoted ) of
                ( Ctx.SplitTuple _, Just sinfo ) ->
                    if sinfo.slotTypes == plan.slotTypes then
                        emitSretCallMulti ctx sid cargs sinfo

                    else
                        inlineElements cargs

                _ ->
                    inlineElements cargs

        Mono.MonoVarLocal v _ ->
            case Dict.get v ctx.splitAggParams of
                Just entry ->
                    ( [], entry.slots, ctx )

                Nothing ->
                    let
                        ( varName, varTy ) =
                            Ctx.lookupVar ctx v

                        ( opsRev, pairsRev, ctxOut ) =
                            List.foldl
                                (\( idx, slotTy ) ( oa, pa, ca ) ->
                                    let
                                        ( pv, ca1 ) =
                                            Ctx.freshVar ca

                                        ( ca2, projOp ) =
                                            case plan.spec of
                                                Ctx.SplitTuple layout ->
                                                    if layout.arity == 2 then
                                                        Ops.ecoProjectTuple2Agg ca1 pv idx slotTy ( varName, varTy )

                                                    else
                                                        Ops.ecoProjectTuple3Agg ca1 pv idx slotTy ( varName, varTy )

                                                Ctx.SplitCtor _ ->
                                                    Ops.ecoProjectCustomAgg ca1 pv idx slotTy ( varName, varTy )
                                    in
                                    ( projOp :: oa, ( pv, slotTy ) :: pa, ca2 )
                                )
                                ( [], [], ctx )
                                (List.indexedMap Tuple.pair plan.slotTypes)
                    in
                    ( List.reverse opsRev, List.reverse pairsRev, ctxOut )

        _ ->
            crash "emitPsplitSlotArg: arg admitted by psplitArgFree but not emittable"


{-| Generates a saturated call to a constructor with fields as an
`eco.construct.custom` in the caller, instead of a call to the constructor's
function, when the configuration's `ctorInline` flag is on. The value is still
allocated on the heap. Returns `Nothing` for a nullary constructor, whose
value is a shared constant, for a call whose result is a function, and for
any other callee.
-}
tryCtorInline : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> Maybe ExprResult
tryCtorInline ctx func args resultType =
    if not ctx.ecoConfig.ctorInline then
        Nothing

    else if isFunctionMonoType resultType then
        Nothing

    else
        case func of
            Mono.MonoVarGlobal _ specId _ ->
                case Dict.get specId ctx.ctorBySpec of
                    Just shape ->
                        if
                            (List.length args == List.length shape.fieldTypes)
                                && not (List.isEmpty args)
                        then
                            Just (generateCustomCreateHeap ctx shape args)

                        else
                            Nothing

                    Nothing ->
                        Nothing

            _ ->
                Nothing


{-| Generates a call that supplies all its callee's arguments, by the shape of
the callee.

A global is first checked against a few elm/bytes functions.
`Bytes.Encode.encode` becomes a fused encode when the `bytesFusion` flag is on
and the encoder reifies, and otherwise a call to the kernel symbol
`Elm_Kernel_Bytes_encode`. `Bytes.Decode.decode` becomes a fused decode when
the decoder reifies, whatever the flag, and otherwise a call to
`Elm_Kernel_Bytes_decode` with field 0 of the `Decoder` value, its inner
function, because that is what the kernel takes. A global of elm/core is
replaced by an intrinsic op when `KernelIntrinsics` recognises it and
`gateIntrinsic` admits it. Every other global is an `eco.call` to its function;
when it has a signature, arguments are converted by `boxToMatchSignatureTyped`
and the call is typed by the signature's return type, and without one,
arguments are passed as they are and the call is typed by the ABI of
`resultType`.

A kernel is checked in the same spirit. `Basics.logBase` becomes two
`eco.float.log` ops and a division. A two-argument `Debug.log` becomes an
`eco.dbg` op on the label and the boxed value, carrying type ids for both,
and its value is the boxed value. `Debug.toString` becomes a call to
`Elm_Kernel_Debug_toString_typed` with the boxed value and its type id.
`Bytes.encode` and `Bytes.decode` are fused when possible, as for the
globals, and otherwise call their kernel symbols. Any other kernel is an
intrinsic when admitted, and otherwise an `eco.call` to the symbol
`Context.registerKernelInstance` chooses for its argument and result types.

A local variable or any other callee expression is applied by `eco.papExtend`
stage by stage, as in `generateClosureApplication`, and its value is coerced
to the ABI of `resultType`. The global and kernel arms are not coerced: their
value has the type of what they call: the function's signature (or
`resultType` without one), the kernel instance or the intrinsic.

-}
generateSaturatedCallNoFusion : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> Mono.CallInfo -> ExprResult
generateSaturatedCallNoFusion ctx func args resultType callInfo =
    case func of
        Mono.MonoVarGlobal _ specId funcType ->
            let
                ( argOps, argsWithTypes, ctx1 ) =
                    generateExprListTyped ctx args

                argTypes : List Mono.MonoType
                argTypes =
                    List.map Mono.typeOf args

                maybeCoreInfo : Maybe ( String, String )
                maybeCoreInfo =
                    case Registry.lookupSpecKey specId ctx.registry of
                        Just ( Mono.Global (ModuleName.Canonical pkg moduleName) name, _ ) ->
                            if pkg == Pkg.core then
                                Just ( moduleName, name )

                            else
                                Nothing

                        Just ( Mono.Accessor _, _ ) ->
                            Nothing

                        Nothing ->
                            Nothing

                maybeBytesEncodeArg : Maybe Mono.MonoExpr
                maybeBytesEncodeArg =
                    case Registry.lookupSpecKey specId ctx.registry of
                        Just ( Mono.Global (ModuleName.Canonical pkg moduleName) name, _ ) ->
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

                maybeBytesDecodeArgs : Maybe ( Mono.MonoExpr, Mono.MonoExpr )
                maybeBytesDecodeArgs =
                    case Registry.lookupSpecKey specId ctx.registry of
                        Just ( Mono.Global (ModuleName.Canonical pkg moduleName) name, _ ) ->
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
            case maybeBytesEncodeArg of
                Just encoderExpr ->
                    case
                        if ctx.ecoConfig.bytesFusion.enabled then
                            BFReify.reifyEncoderWith ctx.inlineBodies ctx.registry ctx.decoderExprs encoderExpr

                        else
                            Nothing
                    of
                        Just nodes ->
                            let
                                loopOps =
                                    BFReify.nodesToOps nodes

                                exprCompiler : BFEmit.ExprCompiler
                                exprCompiler =
                                    bfExprCompiler (fusedLetsFromExprs args)

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
                                    "Elm_Kernel_Bytes_encode"

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
                    case maybeBytesDecodeArgs of
                        Just ( decoderExpr, _ ) ->
                            case resolveDecoderNode ctx decoderExpr of
                                Just decoderNode ->
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
                                        exprCompiler =
                                            bfExprCompiler (fusedLetsFromExprs args)

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
                                    -- The kernel takes the function inside the
                                    -- Decoder, not the Decoder, so field 0 is
                                    -- projected out of it here.
                                    let
                                        ( boxOps, argVarPairs, ctx1b ) =
                                            boxToMatchSignatureTyped ctx1 argsWithTypes [ Mono.MUnit, Mono.MUnit ]

                                        ( decoderVar, bytesVarPair ) =
                                            case argVarPairs of
                                                [ a, b ] ->
                                                    ( a, b )

                                                _ ->
                                                    ( ( "invalid_decoder", Types.ecoValue ), ( "invalid_bytes", Types.ecoValue ) )

                                        ( innerVar, ctx1c ) =
                                            Ctx.freshVar ctx1b

                                        ( ctx1d, projectOp ) =
                                            Ops.ecoProjectCustom ctx1c innerVar 0 Types.ecoValue (Tuple.first decoderVar)

                                        kernelArgPairs : List ( String, MlirType )
                                        kernelArgPairs =
                                            [ ( innerVar, Types.ecoValue ), bytesVarPair ]

                                        ( resVar, ctx2 ) =
                                            Ctx.freshVar ctx1d

                                        kernelName : String
                                        kernelName =
                                            "Elm_Kernel_Bytes_decode"

                                        callResultType =
                                            Types.ecoValue

                                        ( ctx3, callOp ) =
                                            Ops.ecoCallNamed ctx2 resVar kernelName kernelArgPairs callResultType
                                    in
                                    { ops = argOps ++ boxOps ++ [ projectOp, callOp ]
                                    , resultVar = resVar
                                    , resultType = callResultType
                                    , ctx = ctx3
                                    , isTerminated = False
                                    }

                        Nothing ->
                            case maybeCoreInfo of
                                Just ( moduleName, name ) ->
                                    case
                                        KernelIntrinsics.kernelIntrinsic moduleName name argTypes resultType
                                            |> Maybe.andThen (gateIntrinsic ctx1 argsWithTypes)
                                    of
                                        Just intrinsic ->
                                            let
                                                ( unboxOps, unboxedArgVars, ctx1b ) =
                                                    coerceIntrinsicArgs ctx1 argsWithTypes intrinsic

                                                ( resVar, ctx2 ) =
                                                    Ctx.freshVar ctx1b

                                                ( ctx3, intrinsicOps ) =
                                                    Intrinsics.generateIntrinsicOps ctx2 intrinsic resVar unboxedArgVars

                                                intrinsicResultType =
                                                    Intrinsics.intrinsicResultMlirType intrinsic
                                            in
                                            { ops = argOps ++ unboxOps ++ intrinsicOps
                                            , resultVar = resVar
                                            , resultType = intrinsicResultType
                                            , ctx = ctx3
                                            , isTerminated = False
                                            }

                                        Nothing ->
                                            -- hasKernelImplementation is False, so the
                                            -- compiled function is always called.
                                            if Ctx.hasKernelImplementation then
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
                                                let
                                                    funcName : String
                                                    funcName =
                                                        specIdToFuncName ctx.registry specId

                                                    maybeSig : Maybe Ctx.FuncSignature
                                                    maybeSig =
                                                        Array.get specId ctx.signatures |> Maybe.andThen identity

                                                    ( boxOps, argVarPairs, ctx1b ) =
                                                        case maybeSig of
                                                            Just sig ->
                                                                boxToMatchSignatureTyped ctx1 argsWithTypes sig.paramTypes

                                                            Nothing ->
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
                                    let
                                        funcName : String
                                        funcName =
                                            specIdToFuncName ctx.registry specId

                                        maybeSig : Maybe Ctx.FuncSignature
                                        maybeSig =
                                            Array.get specId ctx.signatures |> Maybe.andThen identity

                                        ( boxOps, argVarPairs, ctx1b ) =
                                            case maybeSig of
                                                Just sig ->
                                                    boxToMatchSignatureTyped ctx1 argsWithTypes sig.paramTypes

                                                Nothing ->
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

        Mono.MonoVarKernel _ kernelPrefix home name funcType ->
            let
                ( argOps, argsWithTypes, ctx1 ) =
                    generateExprListTyped ctx args

                argTypes : List Mono.MonoType
                argTypes =
                    List.map Mono.typeOf args
            in
            case ( home, name, argsWithTypes ) of
                ( "Basics", "logBase", [ ( baseVar, baseType ), ( xVar, xType ) ] ) ->
                    let
                        ( unboxBaseOps, unboxedBaseVar, ctx1a ) =
                            if Types.isEcoValueType baseType then
                                Intrinsics.unboxToType ctx1 baseVar F64

                            else
                                ( [], baseVar, ctx1 )

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
                    let
                        valueMonoType : Mono.MonoType
                        valueMonoType =
                            case args of
                                [ _, valueExpr ] ->
                                    Mono.typeOf valueExpr

                                _ ->
                                    Mono.MUnit

                        ( labelTypeId, ctx1a_ ) =
                            Ctx.getOrCreateTypeIdForMonoType Mono.MString ctx1

                        ( typeId, ctx1b ) =
                            Ctx.getOrCreateTypeIdForMonoType valueMonoType ctx1a_

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
                                                [ IntAttr Nothing labelTypeId
                                                , IntAttr Nothing typeId
                                                ]
                                          )
                                        ]
                                    )
                                |> Ops.opBuilder.build
                    in
                    { ops = argOps ++ boxOps ++ [ dbgOp ]
                    , resultVar = boxedValueVar
                    , resultType = Types.ecoValue
                    , ctx = ctx2
                    , isTerminated = False
                    }

                ( "Debug", "toString", [ ( valueVar, valueType ) ] ) ->
                    -- The type id lets the typed kernel print constructor
                    -- names. A Debug.toString closure value calls the
                    -- one-parameter Elm_Kernel_Debug_toString instead.
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

                        ( typeIdVar, ctx2a ) =
                            Ctx.freshVar ctx1c

                        ( ctx2b, typeIdOp ) =
                            Ops.arithConstantInt ctx2a typeIdVar typeId

                        ( resultVar, ctx2c ) =
                            Ctx.freshVar ctx2b

                        ( ctx2d, callOp ) =
                            Ops.ecoCallNamed ctx2c
                                resultVar
                                "Elm_Kernel_Debug_toString_typed"
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

                ( "Bytes", "encode", [ _ ] ) ->
                    case args of
                        [ encoderExpr ] ->
                            case
                                if ctx.ecoConfig.bytesFusion.enabled then
                                    BFReify.reifyEncoderWith ctx.inlineBodies ctx.registry ctx.decoderExprs encoderExpr

                                else
                                    Nothing
                            of
                                Just nodes ->
                                    let
                                        loopOps =
                                            BFReify.nodesToOps nodes

                                        exprCompiler : BFEmit.ExprCompiler
                                        exprCompiler =
                                            bfExprCompiler (fusedLetsFromExprs args)

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

                ( "Bytes", "decode", [ _, _ ] ) ->
                    case args of
                        [ decoderExpr, _ ] ->
                            case resolveDecoderNode ctx decoderExpr of
                                Just decoderNode ->
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
                                        exprCompiler =
                                            bfExprCompiler (fusedLetsFromExprs args)

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
                    case
                        KernelIntrinsics.kernelIntrinsic home name argTypes resultType
                            |> Maybe.andThen (gateIntrinsic ctx1 argsWithTypes)
                    of
                        Just intrinsic ->
                            let
                                ( unboxOps, unboxedArgVars, ctx1b ) =
                                    coerceIntrinsicArgs ctx1 argsWithTypes intrinsic

                                ( resVar, ctx2 ) =
                                    Ctx.freshVar ctx1b

                                ( ctx3, intrinsicOps ) =
                                    Intrinsics.generateIntrinsicOps ctx2 intrinsic resVar unboxedArgVars

                                intrinsicResType =
                                    Intrinsics.intrinsicResultMlirType intrinsic
                            in
                            { ops = argOps ++ unboxOps ++ intrinsicOps
                            , resultVar = resVar
                            , resultType = intrinsicResType
                            , ctx = ctx3
                            , isTerminated = False
                            }

                        Nothing ->
                            let
                                policy : KernelAbi.KernelBackendAbiPolicy
                                policy =
                                    KernelAbi.kernelBackendAbiPolicy
                            in
                            case policy of
                                KernelAbi.ElmDerived ->
                                    -- The declared ABI and boxToMatchSignatureTyped
                                    -- both come from monoTypeToAbi of the same
                                    -- types, so the arguments match the declaration.
                                    let
                                        elmSig : Ctx.FuncSignature
                                        elmSig =
                                            Ctx.kernelFuncSignatureFromType funcType

                                        ( boxOps, argVarPairs, ctx1b ) =
                                            boxToMatchSignatureTyped ctx1 argsWithTypes elmSig.paramTypes

                                        instanceKey : KernelAbi.KernelInstanceKey
                                        instanceKey =
                                            { prefix = kernelPrefix
                                            , home = home
                                            , name = name
                                            , argTypes = elmSig.paramTypes
                                            , resultType = elmSig.returnType
                                            }

                                        ( instanceAbi, ctx1c ) =
                                            Ctx.registerKernelInstance instanceKey ctx1b

                                        ( resVar, ctx2 ) =
                                            Ctx.freshVar ctx1c

                                        kernelName : String
                                        kernelName =
                                            instanceAbi.symbolName

                                        resultMlirType : MlirType
                                        resultMlirType =
                                            instanceAbi.abiResultType

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

                callResultMlirType =
                    Types.monoTypeToAbi resultType

                evaluatorResultMlirType =
                    evaluatorAbiResultType callInfo
            in
            case callInfo.callModel of
                Mono.FlattenedExternal ->
                    -- A local naming an external or kernel function.
                    generateFlattenedPartialApplication ctx func args resultType

                Mono.StageCurried ->
                    -- A variable that is not a closure, applied to nothing, is
                    -- already the value.
                    if not (Types.isEcoValueType funcVarType) && List.isEmpty args then
                        let
                            ( coerceOps, finalVar, ctx1 ) =
                                coerceResultToType ctx funcVarName funcVarType callResultMlirType
                        in
                        { ops = coerceOps
                        , resultVar = finalVar
                        , resultType = callResultMlirType
                        , ctx = ctx1
                        , isTerminated = False
                        }

                    else
                        let
                            ( argOps, argsWithTypes, ctx1 ) =
                                generateExprListTyped ctx args

                            ( boxOps, boxedArgsWithTypes, ctx1b ) =
                                boxArgsToEvaluatorParams (knownEvaluatorParamAbi ctx func) ctx1 argsWithTypes

                            initialRemaining =
                                callInfo.initialRemaining

                            remainingStageArities =
                                callInfo.remainingStageArities

                            papResult =
                                applyByStages ctx1b funcVarName funcVarType initialRemaining remainingStageArities evaluatorResultMlirType (Just (callKindToAttrString callInfo.callKind)) boxedArgsWithTypes [] []

                            ( coerceOps, finalVar, ctxFinal ) =
                                coerceResultToType papResult.ctx papResult.resultVar papResult.resultType callResultMlirType
                        in
                        { ops = argOps ++ boxOps ++ papResult.ops ++ coerceOps
                        , resultVar = finalVar
                        , resultType = callResultMlirType
                        , ctx = ctxFinal
                        , isTerminated = False
                        }

        _ ->
            let
                funcResult : ExprResult
                funcResult =
                    generateExpr ctx func

                callResultMlirType =
                    Types.monoTypeToAbi resultType

                evaluatorResultMlirType =
                    evaluatorAbiResultType callInfo
            in
            if not (Types.isEcoValueType funcResult.resultType) && List.isEmpty args then
                let
                    ( coerceOps, finalVar, ctx1 ) =
                        coerceResultToType funcResult.ctx funcResult.resultVar funcResult.resultType callResultMlirType
                in
                { ops = funcResult.ops ++ coerceOps
                , resultVar = finalVar
                , resultType = callResultMlirType
                , ctx = ctx1
                , isTerminated = False
                }

            else
                let
                    ( argOps, argsWithTypes, ctx1 ) =
                        generateExprListTyped funcResult.ctx args

                    -- knownEvaluatorParamAbi gives [] for these callees, so
                    -- only Bool is boxed.
                    ( boxOps, boxedArgsWithTypes, ctx1b ) =
                        boxArgsToEvaluatorParams (knownEvaluatorParamAbi ctx func) ctx1 argsWithTypes

                    initialRemaining =
                        callInfo.initialRemaining

                    remainingStageArities =
                        callInfo.remainingStageArities

                    papResult =
                        applyByStages ctx1b funcResult.resultVar funcResult.resultType initialRemaining remainingStageArities evaluatorResultMlirType (Just (callKindToAttrString callInfo.callKind)) boxedArgsWithTypes [] []

                    ( coerceOps, finalVar, ctxFinal ) =
                        coerceResultToType papResult.ctx papResult.resultVar papResult.resultType callResultMlirType
                in
                { ops = funcResult.ops ++ argOps ++ boxOps ++ papResult.ops ++ coerceOps
                , resultVar = finalVar
                , resultType = callResultMlirType
                , ctx = ctxFinal
                , isTerminated = False
                }


{-| Generates `exprs` in order, threading the context, and returns their ops
with each value and the SSA type it actually has, which is the type to box or
unbox from rather than what the expression's Mono type maps to.
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



-- ====== TAIL CALL GENERATION ======


{-| Returns the message `generateExpr` crashes with when it is handed a
`MonoTailCall` to function `name`.

`Compiler.Generate.MLIR.TailRec.compileTailFuncToWhile` lowers a
tail-recursive function to a loop, turning each `MonoTailCall` into a step to
the next iteration, so none should reach `generateExpr`. No `eco.joinpoint` is
ever emitted, so an `eco.jump` built here would have nothing to target. A
`MonoTailCall` that does reach `generateExpr` is therefore a compiler bug, and
compilation stops with this message.

-}
unscopedTailCallError : Name.Name -> String
unscopedTailCallError name =
    "Expr.generateExpr: tail call to `"
        ++ name
        ++ "` outside its tail-recursive loop. TailRec.compileTailFuncToWhile must lower every MonoTailCall"
        ++ " as a loop continue; there is no eco.joinpoint for an eco.jump to target (CGEN_030)."



-- ====== IF GENERATION ======


{-| Generates `if c1 then t1 else if c2 then t2 else ... final` as nested
value-producing `eco.case` ops on `i1` conditions, with `case_kind` `bool` and
tags 1 for the then branch and 0 for the else branch. A condition that arrives
as `!eco.value` is unboxed first.

The case's result type is the then branch's SSA type, and the else branch is
coerced to it; on the result spine it is the spine's type instead
(`spineResultMlirType`), and both branches yield through `emitSpineYield`. The
condition is generated off the spine. A branch that is already terminated
goes to `generateIfWithTerminatedBranch` or `generateIfWithTerminatedElse`.

-}
generateIf : Ctx.Context -> List ( Mono.MonoExpr, Mono.MonoExpr ) -> Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateIf ctx branches final resultMonoType =
    case branches of
        [] ->
            generateExpr ctx final

        ( condExpr, thenExpr ) :: restBranches ->
            let
                -- The condition is not on the result spine; a case used as a
                -- condition would otherwise be built as an aggregate.
                condRes =
                    generateExpr { ctx | sretTailLayout = Nothing } condExpr

                ( condUnboxOps, condVar, condCtx ) =
                    if Types.isEcoValueType condRes.resultType then
                        Intrinsics.unboxToType condRes.ctx condRes.resultVar I1

                    else
                        ( [], condRes.resultVar, condRes.ctx )

                condOpsAll =
                    condRes.ops ++ condUnboxOps

                -- The branches are on the spine if the if is.
                condCtxSpine =
                    { condCtx | sretTailLayout = ctx.sretTailLayout }

                thenRes =
                    generateExpr condCtxSpine thenExpr
            in
            if thenRes.isTerminated then
                generateIfWithTerminatedBranch condCtx condVar thenRes restBranches final resultMonoType condOpsAll

            else
                let
                    resultMlirType =
                        case ctx.sretTailLayout of
                            Nothing ->
                                thenRes.resultType

                            Just _ ->
                                spineResultMlirType ctx resultMonoType

                    ( thenCoerceOps, thenFinalVar, thenFinalCtx ) =
                        coerceResultToType thenRes.ctx thenRes.resultVar thenRes.resultType resultMlirType

                    -- Names bound in the then branch are not visible in the else.
                    elseCtx =
                        let
                            sibling =
                                Ctx.ctxForSiblingRegion condCtx thenFinalCtx
                        in
                        { sibling | sretTailLayout = ctx.sretTailLayout }

                    elseRes =
                        generateIf elseCtx restBranches final resultMonoType
                in
                if elseRes.isTerminated then
                    generateIfWithTerminatedElse condRes.ctx condVar thenRes elseRes resultMlirType condRes.ops

                else
                    let
                        ( elseCoerceOps, elseFinalVar, elseFinalCtx ) =
                            coerceResultToType elseRes.ctx elseRes.resultVar elseRes.resultType resultMlirType

                        ( elseProjOps, elseYieldOp, ctx2 ) =
                            emitSpineYield elseFinalCtx elseFinalVar resultMlirType

                        elseRegion =
                            Ops.mkRegion [] (elseRes.ops ++ elseCoerceOps ++ elseProjOps) elseYieldOp

                        ( thenProjOps, thenEcoYield, _ ) =
                            emitSpineYield thenFinalCtx thenFinalVar resultMlirType

                        thenRegionEco =
                            Ops.mkRegion [] (thenRes.ops ++ thenCoerceOps ++ thenProjOps) thenEcoYield

                        spineCase =
                            finishSpineCase ctx2
                                resultMlirType
                                (\cS vS tS -> Ops.ecoCase cS vS condVar I1 "bool" [ 1, 0 ] [ thenRegionEco, elseRegion ] tS)
                                (\cM pairsM -> Ops.ecoCaseMany cM condVar I1 "bool" [ 1, 0 ] [ thenRegionEco, elseRegion ] pairsM)
                    in
                    { ops = condOpsAll ++ spineCase.ops
                    , resultVar = spineCase.resultVar
                    , resultType = spineCase.resultType
                    , ctx = Ctx.ctxAfterBranchOp condCtx spineCase.ctx spineCase.newVars
                    , isTerminated = False
                    }


{-| Generates an `if` whose then branch, `thenRes`, already ends in its own
terminator, which is used as it is. The remaining branches are generated off
the result spine, and the case's type is the else branch's SSA type, or
`!eco.value` when the else branch is terminated too.
-}
generateIfWithTerminatedBranch : Ctx.Context -> String -> ExprResult -> List ( Mono.MonoExpr, Mono.MonoExpr ) -> Mono.MonoExpr -> Mono.MonoType -> List MlirOp -> ExprResult
generateIfWithTerminatedBranch condCtx condVar thenRes restBranches final resultMonoType condOps =
    let
        thenRegion =
            mkRegionFromOps thenRes.ops

        elseCtx =
            Ctx.ctxForSiblingRegion condCtx thenRes.ctx

        elseRes =
            generateIf elseCtx restBranches final resultMonoType

        resultMlirType =
            if elseRes.isTerminated then
                Types.ecoValue

            else
                elseRes.resultType

        ( elseRegion, ctxAfterElse ) =
            if elseRes.isTerminated then
                ( mkRegionFromOps elseRes.ops, elseRes.ctx )

            else
                let
                    ( coerceOps, finalVar, coerceCtx ) =
                        coerceResultToType elseRes.ctx elseRes.resultVar elseRes.resultType resultMlirType

                    ( yieldCtx, yieldOp ) =
                        Ops.ecoYield coerceCtx finalVar resultMlirType
                in
                ( Ops.mkRegion [] (elseRes.ops ++ coerceOps) yieldOp, yieldCtx )

        ( caseResultVar, ctxWithResult ) =
            Ctx.freshVar ctxAfterElse

        ( ctxFinal, caseOp ) =
            Ops.ecoCase ctxWithResult caseResultVar condVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] resultMlirType
    in
    { ops = condOps ++ [ caseOp ]
    , resultVar = caseResultVar
    , resultType = resultMlirType
    , ctx = Ctx.ctxAfterBranchOp condCtx ctxFinal [ caseResultVar ]
    , isTerminated = False
    }


{-| Generates an `if` whose else branch, `elseRes`, already ends in its own
terminator, which is used as it is; the then branch is coerced to
`resultMlirType` and yielded. `condOps` are the ops placed before the case.
-}
generateIfWithTerminatedElse : Ctx.Context -> String -> ExprResult -> ExprResult -> MlirType -> List MlirOp -> ExprResult
generateIfWithTerminatedElse condCtx condVar thenRes elseRes resultMlirType condOps =
    let
        ( thenCoerceOps, thenFinalVar, thenCoerceCtx ) =
            coerceResultToType thenRes.ctx thenRes.resultVar thenRes.resultType resultMlirType

        ( _, thenYieldOp ) =
            Ops.ecoYield thenCoerceCtx thenFinalVar resultMlirType

        thenRegion =
            Ops.mkRegion [] (thenRes.ops ++ thenCoerceOps) thenYieldOp

        elseRegion =
            mkRegionFromOps elseRes.ops

        ( caseResultVar, ctxWithResult ) =
            Ctx.freshVar elseRes.ctx

        ( ctxFinal, caseOp ) =
            Ops.ecoCase ctxWithResult caseResultVar condVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] resultMlirType
    in
    { ops = condOps ++ [ caseOp ]
    , resultVar = caseResultVar
    , resultType = resultMlirType
    , ctx = Ctx.ctxAfterBranchOp condCtx ctxFinal [ caseResultVar ]
    , isTerminated = False
    }



-- ====== LET GENERATION ======


{-| Returns a Mono type whose ABI type is `mlirType`, for a capture of which
only the MLIR type is known: Int for `i64`, Float for `f64`, Char for `i16`,
Bool for `i1` (whose ABI type is `!eco.value`, as a captured Bool is boxed),
and Unit for anything else. `Types.monoTypeToAbi` of the result gives back
`mlirType` for `i64`, `f64`, `i16` and `!eco.value`.
-}
mlirTypeToApproxMonoType : MlirType -> Mono.MonoType
mlirTypeToApproxMonoType mlirType =
    case mlirType of
        I64 ->
            Mono.MInt

        F64 ->
            Mono.MFloat

        I16 ->
            Mono.MChar

        I1 ->
            Mono.MBool

        _ ->
            Mono.MUnit


{-| Returns the names bound by the chain of lets at the head of `expr`, outermost
first, stopping at the first expression that is not a let.
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


{-| Returns the context with a _placeholder_ for each of `names`: a fresh SSA
name of type `!eco.value`, mapped to the name before anything defines it, so
that a closure in a let chain can capture a binding that comes later in the
chain. The placeholder is not counted as defined here; it is defined only if
the binding's value is later renamed onto it.

A name that already has an entry in `currentLetSiblings`, because an enclosing
call made placeholders for the whole chain, keeps that entry and gets no new
placeholder. Other existing mappings of the name, such as a parameter of the
same name, are overridden.

-}
addPlaceholderMappings : List Name.Name -> Ctx.Context -> Ctx.Context
addPlaceholderMappings names ctx =
    List.foldl
        (\name acc ->
            case Dict.get name acc.currentLetSiblings of
                Just _ ->
                    acc

                Nothing ->
                    let
                        ( ssaVar, acc1 ) =
                            Ctx.freshVar acc

                        acc2 =
                            Ctx.addVarMapping name ssaVar Types.ecoValue acc1
                    in
                    { acc2 | definedSsaVars = Set.remove ssaVar acc2.definedSsaVars }
        )
        ctx
        names


{-| A let binding whose value is a closure literal, taken apart: the bound
name, the closure's information and body, and the closure's type.
-}
type alias ClosureBinding =
    { name : Name.Name
    , closureInfo : Mono.ClosureInfo
    , lambdaBody : Mono.MonoExpr
    , monoType : Mono.MonoType
    }


{-| Returns the definition as a `ClosureBinding` when it binds a closure
literal, and `Nothing` otherwise, including for a tail-recursive definition.
-}
classifyClosureDef : Mono.MonoDef -> Maybe ClosureBinding
classifyClosureDef def =
    case def of
        Mono.MonoDef name (Mono.MonoClosure closureInfo body monoType) ->
            Just
                { name = name
                , closureInfo = closureInfo
                , lambdaBody = body
                , monoType = monoType
                }

        _ ->
            Nothing


{-| Returns the names in `boundSet`, other than `selfName`, that the closure
captures directly as a plain variable.
-}
closureSiblingRefs :
    Set.Set Name.Name
    -> Name.Name
    -> Mono.ClosureInfo
    -> Set.Set Name.Name
closureSiblingRefs boundSet selfName info =
    List.foldl
        (\( _, captureExpr, _ ) acc ->
            case captureExpr of
                Mono.MonoVarLocal refName _ ->
                    if refName /= selfName && Set.member refName boundSet then
                        Set.insert refName acc

                    else
                        acc

                _ ->
                    acc
        )
        Set.empty
        info.captures


{-| Returns the strongly connected component of `forwardGraph` that contains
`startName`: the names reachable from it that can also reach it, moving only
through names in `closureNames`. Both reachabilities are found by an iterative
breadth-first search. The result always contains `startName`.
-}
computeSCC :
    Set.Set Name.Name
    -> Dict.Dict Name.Name (Set.Set Name.Name)
    -> Name.Name
    -> Set.Set Name.Name
computeSCC closureNames forwardGraph startName =
    let
        reverseGraph =
            Dict.foldl
                (\from tos acc ->
                    Set.foldl
                        (\to acc2 ->
                            let
                                existing =
                                    Dict.get to acc2
                                        |> Maybe.withDefault Set.empty
                            in
                            Dict.insert to (Set.insert from existing) acc2
                        )
                        acc
                        tos
                )
                Dict.empty
                forwardGraph

        bfs graph start =
            let
                step visited frontier =
                    if Set.isEmpty frontier then
                        visited

                    else
                        let
                            nextFrontier =
                                Set.foldl
                                    (\n acc ->
                                        Dict.get n graph
                                            |> Maybe.withDefault Set.empty
                                            |> Set.foldl
                                                (\next a ->
                                                    if
                                                        Set.member next closureNames
                                                            && not (Set.member next visited)
                                                    then
                                                        Set.insert next a

                                                    else
                                                        a
                                                )
                                                acc
                                    )
                                    Set.empty
                                    frontier

                            newVisited =
                                Set.union visited nextFrontier
                        in
                        step newVisited nextFrontier
            in
            step (Set.singleton start) (Set.singleton start)

        forward =
            bfs forwardGraph startName

        backward =
            bfs reverseGraph startName
    in
    Set.intersect forward backward


{-| Finds a group of mutually recursive closures that starts at `def`: two or
more closure bindings at the head of the let chain that capture one another.
Returns the members in chain order with the rest of the chain rebuilt as the
body after them.

Only the run of closure bindings at the head of the chain is considered, and
the group is the strongly connected component of their capture graph that
contains `def`. Returns `Nothing` when `def` is not a closure binding, when
that component has one member, or when it is not exactly the first bindings
of the run.

-}
detectMutualRecGroup :
    Mono.MonoDef
    -> Mono.MonoExpr
    -> Maybe ( List ClosureBinding, Mono.MonoExpr )
detectMutualRecGroup def body =
    case classifyClosureDef def of
        Nothing ->
            Nothing

        Just firstClosure ->
            let
                ( followingDefs, finalBody ) =
                    splitLetChain body

                ( closureWindow, tailAfterWindow ) =
                    collectClosurePrefix (def :: followingDefs)

                windowNames =
                    closureWindow |> List.map .name

                boundSet =
                    Set.fromList windowNames

                forwardGraph =
                    List.foldl
                        (\cb acc ->
                            Dict.insert cb.name
                                (closureSiblingRefs boundSet cb.name cb.closureInfo)
                                acc
                        )
                        Dict.empty
                        closureWindow

                scc =
                    computeSCC boundSet forwardGraph firstClosure.name

                sccSize =
                    Set.size scc
            in
            if sccSize < 2 then
                Nothing

            else
                let
                    windowWithIdx =
                        List.indexedMap Tuple.pair closureWindow

                    sccIndices =
                        windowWithIdx
                            |> List.filterMap
                                (\( i, cb ) ->
                                    if Set.member cb.name scc then
                                        Just i

                                    else
                                        Nothing
                                )

                    maxIdx =
                        List.maximum sccIndices |> Maybe.withDefault 0

                    minIdx =
                        List.minimum sccIndices |> Maybe.withDefault 0

                    isContiguous =
                        minIdx == 0 && (maxIdx - minIdx + 1 == sccSize)
                in
                if not isContiguous then
                    Nothing

                else
                    let
                        ( members, rest ) =
                            splitAtIndex sccSize closureWindow

                        restAsDefs =
                            List.map closureBindingToDef rest

                        bodyAfterGroup =
                            rebuildLetChainFromDefs
                                (restAsDefs ++ tailAfterWindow)
                                finalBody
                    in
                    Just ( members, bodyAfterGroup )


{-| Returns the closure binding as the let definition it came from.
-}
closureBindingToDef : ClosureBinding -> Mono.MonoDef
closureBindingToDef cb =
    Mono.MonoDef cb.name
        (Mono.MonoClosure cb.closureInfo cb.lambdaBody cb.monoType)


{-| Returns a chain of lets binding `defs` in order around `finalBody`. Every
let is given the type of `finalBody`.
-}
rebuildLetChainFromDefs : List Mono.MonoDef -> Mono.MonoExpr -> Mono.MonoExpr
rebuildLetChainFromDefs defs finalBody =
    case defs of
        [] ->
            finalBody

        d :: rest ->
            Mono.MonoLet d
                (rebuildLetChainFromDefs rest finalBody)
                (Mono.typeOf finalBody)


{-| Splits `defs` into the run of closure bindings at its head and the
definitions from the first other binding onwards.
-}
collectClosurePrefix :
    List Mono.MonoDef
    -> ( List ClosureBinding, List Mono.MonoDef )
collectClosurePrefix defs =
    case defs of
        [] ->
            ( [], [] )

        d :: rest ->
            case classifyClosureDef d of
                Just c ->
                    let
                        ( prefix, tailRest ) =
                            collectClosurePrefix rest
                    in
                    ( c :: prefix, tailRest )

                Nothing ->
                    ( [], d :: rest )


{-| Returns the first `n` elements of `xs` and the rest.
-}
splitAtIndex : Int -> List a -> ( List a, List a )
splitAtIndex n xs =
    ( List.take n xs, List.drop n xs )


{-| Returns the definitions of the chain of lets at the head of `expr`, in
order, and the expression under the last of them.
-}
splitLetChain : Mono.MonoExpr -> ( List Mono.MonoDef, Mono.MonoExpr )
splitLetChain expr =
    case expr of
        Mono.MonoLet def body _ ->
            let
                ( rest, finalBody ) =
                    splitLetChain body
            in
            ( def :: rest, finalBody )

        _ ->
            ( [], expr )


{-| Generates a let and its body.

At the head of a let chain (a binding not already among `currentLetSiblings`),
and when the configuration's `aggPromote` flag is on, the chain is scanned once
for forward references (`scanChainForwardRefs`), and the result is kept in the
context's `fwdRefdLetNames` while the chain is generated, then restored. A
group of mutually recursive closures at the head goes to `generateLetGroup`;
anything else to `generateLetSingle`.

-}
generateLet : Ctx.Context -> Mono.MonoDef -> Mono.MonoExpr -> ExprResult
generateLet ctx def body =
    let
        headName =
            case def of
                Mono.MonoDef n _ ->
                    n

                Mono.MonoTailDef n _ _ ->
                    n

        isChainHead =
            not (Dict.member headName ctx.currentLetSiblings)

        ctxScanned =
            if ctx.ecoConfig.aggPromote && isChainHead then
                { ctx | fwdRefdLetNames = scanChainForwardRefs ctx def body }

            else
                ctx

        result =
            case detectMutualRecGroup def body of
                Just ( members, restBody ) ->
                    generateLetGroup ctxScanned members restBody

                Nothing ->
                    generateLetSingle ctxScanned def body

        resCtx =
            result.ctx
    in
    { result | ctx = { resCtx | fwdRefdLetNames = ctx.fwdRefdLetNames } }


{-| Returns the names bound by the let chain that starts with `def` and
continues through `body` which are referred to by an earlier binding of the
same chain.

Such a reference can only be made from inside a closure, which captures the
later name; a promoted aggregate cannot be captured, so a name in this set is
never promoted. The scan is skipped, giving the empty set, when the chain has
fewer than two bindings or no binding that could be promoted: a tuple literal
or a call to a constructor's global.

-}
scanChainForwardRefs : Ctx.Context -> Mono.MonoDef -> Mono.MonoExpr -> Set.Set Name.Name
scanChainForwardRefs ctx def body =
    let
        links =
            chainLinks def body

        isCandidateRhs rhs =
            case rhs of
                Mono.MonoTupleCreate _ _ _ ->
                    True

                Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) _ _ _ ->
                    Dict.member specId ctx.ctorBySpec

                _ ->
                    False

        hasCandidate =
            List.any (\( _, rhs ) -> isCandidateRhs rhs) links
    in
    if List.length links < 2 || not hasCandidate then
        Set.empty

    else
        -- Back to front, carrying the names bound later in the chain.
        List.foldr
            (\( name, rhs ) ( laterNames, acc ) ->
                ( Set.insert name laterNames
                , if Set.isEmpty laterNames then
                    acc

                  else
                    Set.union acc (occursAnyNames laterNames rhs)
                )
            )
            ( Set.empty, Set.empty )
            links
            |> Tuple.second


{-| Returns each binding of the let chain that starts with `def` and continues
through `body`, as its name and bound expression, in order. A tail-recursive
definition gives its body.
-}
chainLinks : Mono.MonoDef -> Mono.MonoExpr -> List ( Name.Name, Mono.MonoExpr )
chainLinks def body =
    let
        link d =
            case d of
                Mono.MonoDef n rhs ->
                    ( n, rhs )

                Mono.MonoTailDef n _ rhs ->
                    ( n, rhs )
    in
    link def
        :: (case body of
                Mono.MonoLet def2 body2 _ ->
                    chainLinks def2 body2

                _ ->
                    []
           )


{-| Returns those of `targets` that `expr` refers to anywhere: as a variable,
as either name of a case scrutinee, as the root of a destructuring path, or as
the name of a closure capture.
-}
occursAnyNames : Set.Set Name.Name -> Mono.MonoExpr -> Set.Set Name.Name
occursAnyNames targets expr =
    MonoTraverse.foldExpr
        (\e acc ->
            let
                hit n a =
                    if Set.member n targets then
                        Set.insert n a

                    else
                        a
            in
            case e of
                Mono.MonoVarLocal x _ ->
                    hit x acc

                Mono.MonoCase s1 s2 _ _ _ ->
                    hit s1 (hit s2 acc)

                Mono.MonoDestruct (Mono.MonoDestructor _ path _) _ _ ->
                    case pathRootName path of
                        Just r ->
                            hit r acc

                        Nothing ->
                            acc

                Mono.MonoClosure info _ _ ->
                    List.foldl (\( c, _, _ ) a -> hit c a) acc info.captures

                _ ->
                    acc
        )
        Set.empty
        expr


{-| Returns the variable a destructuring path starts from.
-}
pathRootName : Mono.MonoPath -> Maybe Name.Name
pathRootName path =
    case path of
        Mono.MonoRoot r _ ->
            Just r

        Mono.MonoIndex _ _ _ sub ->
            pathRootName sub

        Mono.MonoField _ _ sub ->
            pathRootName sub

        Mono.MonoUnbox _ sub ->
            pathRootName sub


{-| Generates one let binding and then its body.

Every name of the chain from `def` on is first given a placeholder
(`addPlaceholderMappings`), and those names alone become `currentLetSiblings`,
so that a closure can capture a later sibling but sees no other outer
variable through its siblings. The bound expression is generated off the
result spine; the body is generated with the caller's spine flag, and
`currentLetSiblings` is restored afterwards.

For a plain definition, a `$sret` binding is tried first (`trySretLetBinding`).
Otherwise a tuple literal or constructor call may be built as a value
aggregate, when the `aggPromote` flag is on, the name is not forward-referenced
and every use of it in the body only projects fields (`tupleBinderPromotable`,
`promotableCtorCall`). When the binding's own ops define its value, the value
is renamed onto the placeholder (`forceResultVar`), after a capture of the
placeholder by the binding's own closure is replaced by a Unit constant
(`fixSelfCaptures`). When the bound expression emits no ops, or its value is
defined outside its own ops, the name is mapped to that value and the
placeholder is left undefined. A placeholder that is already defined, meaning
the same name was bound twice on the chain, crashes the compiler. Names bound
only inside the bound expression are dropped from the context afterwards.

A tail-recursive definition is queued as a tail-recursive `PendingLambda`
named `_tail_<name>_<n>`, and its value is an `eco.papCreate` defining the
placeholder. Its captures are the free locals of its body that are not
siblings; one held as scalar slots is rebuilt as a value first, a Bool is
boxed, and a free local with no mapping is left out.

The result is terminated when the body is, or when the bound expression is and
the body emits no ops.

-}
generateLetSingle : Ctx.Context -> Mono.MonoDef -> Mono.MonoExpr -> ExprResult
generateLetSingle ctx def body =
    let
        boundNames =
            collectLetBoundNames (Mono.MonoLet def body Mono.MUnit)

        outerSiblings =
            ctx.currentLetSiblings

        groupVarMappings =
            addPlaceholderMappings boundNames ctx

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
            -- tailRecLetBody belongs to this binding only, so lets nested in
            -- the bound expression must not see it.
            { groupVarMappings | currentLetSiblings = letBoundSiblings, tailRecLetBody = Nothing, sretTailLayout = Nothing }
    in
    case def of
        Mono.MonoDef name expr ->
            case trySretLetBinding ctx ctxWithPlaceholders name expr body of
                Just sretResult ->
                    sretResult

                Nothing ->
                    let
                        ( placeholderVar, _ ) =
                            Ctx.lookupVar ctxWithPlaceholders name

                        -- A Unit body may be a stand-in for a loop body generated
                        -- elsewhere, which tailRecLetBody then holds; the escape
                        -- walk must see the real body, and with none it cannot
                        -- approve promotion.
                        ( analysisBody, promotionBodyOk ) =
                            case body of
                                Mono.MonoUnit ->
                                    case ctx.tailRecLetBody of
                                        Just realBody ->
                                            ( realBody, True )

                                        Nothing ->
                                            ( body, False )

                                _ ->
                                    ( body, True )

                        chainHeadSafe =
                            promotionBodyOk && not (Set.member name ctx.fwdRefdLetNames)

                        rawResult : ExprResult
                        rawResult =
                            case expr of
                                Mono.MonoTupleCreate _ elements monoType ->
                                    if
                                        ctx.ecoConfig.aggPromote
                                            && chainHeadSafe
                                            && tupleBinderPromotable ctx.splitAggParams ctx.psplitPromoted ctx.fwdRefdLetNames name monoType analysisBody
                                    then
                                        generateTupleCreateValue ctxWithPlaceholders elements monoType

                                    else
                                        generateExpr ctxWithPlaceholders expr

                                Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) cargs callResultType callInfo ->
                                    case
                                        if chainHeadSafe then
                                            promotableCtorCall ctx name specId cargs callResultType callInfo analysisBody

                                        else
                                            Nothing
                                    of
                                        Just shape ->
                                            generateCustomCreateValue ctxWithPlaceholders shape cargs

                                        Nothing ->
                                            generateExpr ctxWithPlaceholders expr

                                _ ->
                                    generateExpr ctxWithPlaceholders expr

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
                                -- Such as Debug.log returning a value it was
                                -- given: renaming it would break its other uses.
                                ( fixedResult, fixedResult.resultVar )

                            else if Set.member placeholderVar fixedResult.ctx.definedSsaVars then
                                -- Renaming again would define the SSA name twice.
                                -- Let-bound names on a chain are expected to be
                                -- unique by this point.
                                crash
                                    ("generateLetSingle: SSA placeholder "
                                        ++ placeholderVar
                                        ++ " for let-bound name '"
                                        ++ name
                                        ++ "' is already defined - duplicate let name reached codegen"
                                    )

                            else
                                ( forceResultVar placeholderVar fixedResult, placeholderVar )

                        -- Names bound inside the bound expression go out of scope,
                        -- and so do the SSA values only they named.
                        scopedCtx : Ctx.Context
                        scopedCtx =
                            let
                                exprCtx =
                                    exprResult.ctx

                                innerOnly =
                                    Dict.foldl
                                        (\k v acc ->
                                            if Dict.member k ctxWithPlaceholders.varMappings then
                                                acc

                                            else
                                                ( k, v.ssaVar ) :: acc
                                        )
                                        []
                                        exprCtx.varMappings
                            in
                            case innerOnly of
                                [] ->
                                    exprCtx

                                _ ->
                                    { exprCtx
                                        | varMappings =
                                            List.foldl (\( k, _ ) acc -> Dict.remove k acc) exprCtx.varMappings innerOnly
                                        , definedSsaVars =
                                            Set.diff exprCtx.definedSsaVars
                                                (List.foldl (\( _, sv ) acc -> Set.insert sv acc) Set.empty innerOnly)
                                    }

                        ctx1 : Ctx.Context
                        ctx1 =
                            Ctx.addVarMapping name effectiveVar exprResult.resultType scopedCtx
                                |> Ctx.addDecoderExpr name expr
                                |> trackLocalEvaluatorParams name expr

                        bodyResult : ExprResult
                        bodyResult =
                            generateExpr { ctx1 | sretTailLayout = ctx.sretTailLayout } body

                        bodyCtx : Ctx.Context
                        bodyCtx =
                            bodyResult.ctx

                        ctxOut : Ctx.Context
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

        Mono.MonoTailDef name params tailBody ->
            let
                ( placeholderVar, _ ) =
                    Ctx.lookupVar ctxWithPlaceholders name

                paramNames =
                    List.map Tuple.first params

                boundSet =
                    Set.fromList (name :: paramNames)

                freeVarNames =
                    Closure.findFreeLocals boundSet tailBody

                captureNames =
                    List.filter
                        (\n -> not (Dict.member n ctxWithPlaceholders.currentLetSiblings))
                        freeVarNames
                        |> Set.fromList
                        |> Set.toList

                -- A name held as scalar slots has no var mapping, so it is
                -- rebuilt from its slots, as a whole-value use of it would be.
                ( captureMaterializeOpsRev, captureInfosRev, ctxCaptured ) =
                    List.foldl
                        (\capName ( opsAcc, infosAcc, ctxAcc ) ->
                            case Dict.get capName ctxAcc.splitAggParams of
                                Just splitInfo ->
                                    let
                                        ( matOps, matVar, ctxM ) =
                                            Patterns.materializeSplitParam ctxAcc splitInfo
                                    in
                                    ( List.reverse matOps ++ opsAcc, ( capName, matVar, Types.ecoValue ) :: infosAcc, ctxM )

                                Nothing ->
                                    case Dict.get capName ctxAcc.varMappings of
                                        Just info ->
                                            ( opsAcc, ( capName, info.ssaVar, info.mlirType ) :: infosAcc, ctxAcc )

                                        Nothing ->
                                            ( opsAcc, infosAcc, ctxAcc )
                        )
                        ( [], [], ctxWithPlaceholders )
                        captureNames

                captureMaterializeOps =
                    List.reverse captureMaterializeOpsRev

                captureInfos =
                    List.reverse captureInfosRev

                captureTypes =
                    List.map
                        (\( capName, _, mlirTy ) -> ( capName, mlirTypeToApproxMonoType mlirTy ))
                        captureInfos

                -- The lambda takes a Bool capture as !eco.value
                -- (mlirTypeToApproxMonoType gives MBool for i1).
                ( captureBoxOps, boxedCaptures, ctxBoxed ) =
                    boxArgsForClosureBoundary
                        ctxCaptured
                        (List.map (\( _, ssaVar, mlirTy ) -> ( ssaVar, mlirTy )) captureInfos)

                captureVarNames =
                    List.map Tuple.first boxedCaptures

                captureMlirTypes =
                    List.map Tuple.second boxedCaptures

                tailFuncName =
                    "_tail_" ++ name ++ "_" ++ String.fromInt ctxWithPlaceholders.nextOpId

                pendingLambda : Ctx.PendingLambda
                pendingLambda =
                    { name = tailFuncName
                    , captures = captureTypes
                    , params = params
                    , body = tailBody
                    , returnType = Mono.typeOf tailBody
                    , siblingMappings = ctxWithPlaceholders.currentLetSiblings
                    , isTailRecursive = True
                    , selfBindingName = Just name
                    }

                ctx1 =
                    { ctxBoxed
                        | pendingLambdas = pendingLambda :: ctxBoxed.pendingLambdas
                    }

                hasCaptures =
                    not (List.isEmpty captureInfos)

                numCaptured =
                    List.length captureInfos

                arity =
                    numCaptured + List.length params

                functionName =
                    if hasCaptures then
                        tailFuncName ++ "$cap"

                    else
                        tailFuncName

                ( resultVar, ctx2 ) =
                    Ctx.freshVar ctx1

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

                -- The slot kind of the body's ABI type, omitted when boxed.
                tailResultKind =
                    Types.mlirTypeToKind (Types.monoTypeToAbi (Mono.typeOf tailBody))

                tailResultKindAttr =
                    if tailResultKind == 0 then
                        Dict.empty

                    else
                        Dict.singleton "_result_kind" (IntAttr (Just I8) tailResultKind)

                papAttrs =
                    Dict.union tailResultKindAttr
                        (Dict.union fastEvaluatorAttr
                            (Dict.union operandTypesAttr
                                (Dict.fromList
                                    [ ( "function", SymbolRefAttr functionName )
                                    , ( "arity", IntAttr Nothing (Ops.assertStageArity arity) )
                                    , ( "num_captured", IntAttr Nothing numCaptured )
                                    ]
                                    |> Ops.withSlotKinds captureMlirTypes
                                )
                            )
                        )

                ( ctx3, papOp ) =
                    Ops.mlirOp ctx2 "eco.papCreate"
                        |> Ops.opBuilder.withOperands captureVarNames
                        |> Ops.opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
                        |> Ops.opBuilder.withAttrs papAttrs
                        |> Ops.opBuilder.build

                rawResult =
                    { ops = captureMaterializeOps ++ captureBoxOps ++ [ papOp ]
                    , resultVar = resultVar
                    , resultType = Types.ecoValue
                    , ctx = ctx3
                    , isTerminated = False
                    }

                exprResult =
                    forceResultVar placeholderVar rawResult

                ctx4 =
                    Ctx.addVarMapping name placeholderVar exprResult.resultType exprResult.ctx

                bodyResult =
                    generateExpr { ctx4 | sretTailLayout = ctx.sretTailLayout } body

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


{-| Generates a group of mutually recursive closures, `members`, as one
`eco.papCreateGroup` op, and then `body`.

Separate `eco.papCreate` ops cannot express closures that capture each other,
because whichever is built first would capture a value not yet defined. The
group op creates all the closures together, and the captures between them are
given as cross edges rather than as operands. Each member's capture slots
hold its other captures first, which may be unboxed, then its captures of
members, which are boxed; each capture of a member is a _cross edge_
(producer, consumer, slot). Each member is created under the name of its
`$cap` clone, defines its own placeholder, and is queued as a `PendingLambda`
whose captures follow the same order.

Placeholders are made for every name of the chain, including those bound
after the group, and the body is generated with the caller's spine flag.

-}
generateLetGroup :
    Ctx.Context
    -> List ClosureBinding
    -> Mono.MonoExpr
    -> ExprResult
generateLetGroup ctx members body =
    let
        memberNames =
            List.map .name members

        boundNames =
            collectLetBoundNames (wrapDefsIntoLet members body)

        outerSiblings =
            ctx.currentLetSiblings

        groupVarMappings =
            addPlaceholderMappings boundNames ctx

        letBoundSiblings =
            List.foldl
                (\n acc ->
                    case Dict.get n groupVarMappings.varMappings of
                        Just info ->
                            Dict.insert n info acc

                        Nothing ->
                            acc
                )
                Dict.empty
                boundNames

        ctxWithPlaceholders =
            { groupVarMappings | currentLetSiblings = letBoundSiblings, sretTailLayout = Nothing }

        memberNameSet =
            Set.fromList memberNames

        memberIndex : Dict.Dict Name.Name Int
        memberIndex =
            List.indexedMap (\i n -> ( n, i )) memberNames |> Dict.fromList

        buildSiblingData ( consumerIdx, member ) acc =
            let
                closureInfo =
                    member.closureInfo

                ( nonSiblingCaptures, siblingCaptures ) =
                    List.partition
                        (\( _, captureExpr, _ ) ->
                            case captureExpr of
                                Mono.MonoVarLocal refName _ ->
                                    not (Set.member refName memberNameSet)

                                _ ->
                                    True
                        )
                        closureInfo.captures

                ( captureOpsRev, captureVarsRev, ctxAfter ) =
                    List.foldl
                        (\( _, expr, _ ) ( ops, vars, ctx2 ) ->
                            let
                                r =
                                    generateExpr ctx2 expr
                            in
                            ( List.reverse r.ops ++ ops
                            , ( r.resultVar, r.resultType ) :: vars
                            , r.ctx
                            )
                        )
                        ( [], [], acc.ctx )
                        nonSiblingCaptures

                capVars0 =
                    List.reverse captureVarsRev

                -- Only Bool is boxed here.
                ( boxOps, capVarsBoxed, ctxAfterBox ) =
                    boxArgsForClosureBoundary ctxAfter capVars0

                captureVarNames =
                    List.map Tuple.first capVarsBoxed

                captureTypes =
                    List.map Tuple.second capVarsBoxed

                nonSiblingCount =
                    List.length capVarsBoxed

                crossEdgesForSibling =
                    List.indexedMap
                        (\j ( _, captureExpr, _ ) ->
                            case captureExpr of
                                Mono.MonoVarLocal refName _ ->
                                    case Dict.get refName memberIndex of
                                        Just producerIdx ->
                                            Just
                                                ( producerIdx
                                                , consumerIdx
                                                , nonSiblingCount + j
                                                )

                                        Nothing ->
                                            Nothing

                                _ ->
                                    Nothing
                        )
                        siblingCaptures
                        |> List.filterMap identity

                numCaptured =
                    nonSiblingCount + List.length siblingCaptures

                slotKinds =
                    captureTypes ++ List.repeat (List.length siblingCaptures) Types.ecoValue

                baseFuncName =
                    lambdaIdToString closureInfo.lambdaId

                bodyAbi =
                    Types.monoTypeToAbi (Mono.typeOf member.lambdaBody)

                siblingResultKind =
                    Types.mlirTypeToKind bodyAbi

                siblingMeta =
                    { functionName = baseFuncName ++ "$cap"
                    , fastEvaluator = baseFuncName ++ "$cap"
                    , arity = numCaptured + List.length closureInfo.params
                    , numCaptured = numCaptured
                    , slotKinds = slotKinds
                    , resultKind = siblingResultKind
                    , captureVars = captureVarNames
                    , captureTypes = captureTypes
                    }

                thisOps =
                    List.reverse captureOpsRev ++ boxOps
            in
            { ctx = ctxAfterBox
            , siblingsRev = siblingMeta :: acc.siblingsRev
            , crossEdges = crossEdgesForSibling ++ acc.crossEdges
            , opsRev = List.reverse thisOps ++ acc.opsRev
            }

        groupAcc =
            List.foldl
                buildSiblingData
                { ctx = ctxWithPlaceholders
                , siblingsRev = []
                , crossEdges = []
                , opsRev = []
                }
                (List.indexedMap Tuple.pair members)

        ctxAfterSiblings =
            groupAcc.ctx

        siblingMetaList =
            List.reverse groupAcc.siblingsRev

        crossEdges =
            groupAcc.crossEdges

        captureOpsAll =
            List.reverse groupAcc.opsRev

        resultVars =
            List.map
                (\m -> Ctx.lookupVar ctxAfterSiblings m.name |> Tuple.first)
                members

        ( ctxWithGroupOp, groupOp ) =
            Ops.ecoPapCreateGroup
                ctxAfterSiblings
                siblingMetaList
                crossEdges
                resultVars

        pendingLambdas =
            List.map
                (\member ->
                    let
                        closureInfo =
                            member.closureInfo

                        -- In slot order: other captures, then members.
                        ( nonSibCapEntries, sibCapEntries ) =
                            List.partition
                                (\( _, captureExpr, _ ) ->
                                    case captureExpr of
                                        Mono.MonoVarLocal refName _ ->
                                            not (Set.member refName memberNameSet)

                                        _ ->
                                            True
                                )
                                closureInfo.captures

                        toNameType ( name, captureExpr, _ ) =
                            ( name, Mono.typeOf captureExpr )

                        capturesOrdered =
                            List.map toNameType nonSibCapEntries
                                ++ List.map toNameType sibCapEntries
                    in
                    { name = lambdaIdToString closureInfo.lambdaId
                    , captures = capturesOrdered
                    , params = closureInfo.params
                    , body = member.lambdaBody
                    , returnType = Mono.typeOf member.lambdaBody
                    , siblingMappings = letBoundSiblings
                    , isTailRecursive = False
                    , selfBindingName = Nothing
                    }
                )
                members

        ctxAfterLambdas =
            { ctxWithGroupOp
                | pendingLambdas = pendingLambdas ++ ctxWithGroupOp.pendingLambdas
            }

        -- Mapping each name again marks its placeholder as defined.
        ctxReady =
            List.foldl
                (\member c ->
                    let
                        ( ssaVar, _ ) =
                            Ctx.lookupVar c member.name
                    in
                    Ctx.addVarMapping member.name ssaVar Types.ecoValue c
                )
                ctxAfterLambdas
                members

        bodyResult =
            generateExpr { ctxReady | sretTailLayout = ctx.sretTailLayout } body

        bodyCtx =
            bodyResult.ctx

        ctxOut =
            { bodyCtx | currentLetSiblings = outerSiblings }

        finalIsTerminated =
            bodyResult.isTerminated
    in
    { ops = captureOpsAll ++ [ groupOp ] ++ bodyResult.ops
    , resultVar = bodyResult.resultVar
    , resultType = bodyResult.resultType
    , ctx = ctxOut
    , isTerminated = finalIsTerminated
    }


{-| Returns a chain of lets binding the closure `members` in order around
`tail`, every let given the type of `tail`.
-}
wrapDefsIntoLet : List ClosureBinding -> Mono.MonoExpr -> Mono.MonoExpr
wrapDefsIntoLet members tail =
    case members of
        [] ->
            tail

        m :: rest ->
            Mono.MonoLet
                (Mono.MonoDef m.name
                    (Mono.MonoClosure m.closureInfo m.lambdaBody m.monoType)
                )
                (wrapDefsIntoLet rest tail)
                (Mono.typeOf tail)



-- ====== DESTRUCT GENERATION ======


{-| Generates a destructuring, `name` bound to the value at the end of `path`,
and then `body`.

The value is read at the ABI type of the path's result type
(`Patterns.resolvePathResultType`), which is the type computed from the
containers along the path. The destructor's own type is used instead only
when the path's type still contains a type variable and the destructor's does
not. The binding of `name` lasts for `body` only: afterwards any earlier
mapping of the name is restored.

-}
generateDestruct : Ctx.Context -> Mono.MonoDestructor -> Mono.MonoExpr -> ExprResult
generateDestruct ctx (Mono.MonoDestructor name path destructorMonoType) body =
    let
        pathResultRaw =
            Patterns.resolvePathResultType ctx path

        pathResultType =
            if Mono.containsAnyMVar pathResultRaw && not (Mono.containsAnyMVar destructorMonoType) then
                destructorMonoType

            else
                pathResultRaw

        destructorMlirType =
            Types.monoTypeToAbi pathResultType

        targetType =
            destructorMlirType

        ( pathOps, pathVar, ctx1 ) =
            Patterns.generateMonoPath ctx path targetType

        previousMapping =
            Dict.get name ctx1.varMappings

        ctx2 : Ctx.Context
        ctx2 =
            Ctx.addVarMapping name pathVar targetType ctx1

        bodyResult : ExprResult
        bodyResult =
            generateExpr ctx2 body

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


{-| Generates a case's decision tree, whose leaves each end in an `eco.yield`
of a `resultTy` value. A leaf that jumps to a shared branch gets its own copy
of that branch's body, looked up in `jumpLookup`, so no `eco.joinpoint` is
emitted and every alternative is a single block. A `Leaf` emits no test; a
`Chain` and a `FanOut` emit `eco.case` ops.
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


{-| Generates a leaf of a decision tree: the branch body, inline or copied
from `jumpLookup`, coerced to `resultTy` and yielded (`emitSpineYield`).

A body that is already terminated is kept as it is when it ends in an
`eco.yield`, or when it has no result value (which `mkCaseRegionFromDecider`
then reports); one that ends in another terminator but has a value gets the
yield appended. A jump index missing from `jumpLookup` crashes the compiler.

-}
generateLeafWithJumps : Ctx.Context -> Mono.MonoChoice -> Array (Maybe Mono.MonoExpr) -> MlirType -> ExprResult
generateLeafWithJumps ctx choice jumpLookup resultTy =
    case choice of
        Mono.Inline branchExpr ->
            let
                branchRes =
                    generateExpr ctx branchExpr
            in
            if branchRes.isTerminated then
                case List.reverse branchRes.ops of
                    lastOp :: _ ->
                        if isValidCaseTerminator lastOp then
                            branchRes

                        else if branchRes.resultVar == "" then
                            branchRes

                        else
                            let
                                actualTy =
                                    branchRes.resultType

                                ( coerceOps, finalVar, ctx1 ) =
                                    coerceResultToType branchRes.ctx branchRes.resultVar actualTy resultTy

                                ( yieldPreOps, yieldOp, ctx2 ) =
                                    emitSpineYield ctx1 finalVar resultTy
                            in
                            { ops = branchRes.ops ++ coerceOps ++ yieldPreOps ++ [ yieldOp ]
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

                    ( yieldPreOps, yieldOp, ctx2 ) =
                        emitSpineYield ctx1 finalVar resultTy
                in
                { ops = branchRes.ops ++ coerceOps ++ yieldPreOps ++ [ yieldOp ]
                , resultVar = finalVar
                , resultType = resultTy
                , ctx = ctx2
                , isTerminated = True
                }

        Mono.Jump index ->
            case Array.get index jumpLookup |> Maybe.andThen identity of
                Just branchExpr ->
                    let
                        branchRes =
                            generateExpr ctx branchExpr
                    in
                    if branchRes.isTerminated then
                        case List.reverse branchRes.ops of
                            lastOp :: _ ->
                                if isValidCaseTerminator lastOp then
                                    branchRes

                                else if branchRes.resultVar == "" then
                                    branchRes

                                else
                                    let
                                        actualTy =
                                            branchRes.resultType

                                        ( coerceOps, finalVar, ctx1 ) =
                                            coerceResultToType branchRes.ctx branchRes.resultVar actualTy resultTy

                                        ( yieldPreOps, yieldOp, ctx2 ) =
                                            emitSpineYield ctx1 finalVar resultTy
                                    in
                                    { ops = branchRes.ops ++ coerceOps ++ yieldPreOps ++ [ yieldOp ]
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

                            ( yieldPreOps, yieldOp, ctx2 ) =
                                emitSpineYield ctx1 finalVar resultTy
                        in
                        { ops = branchRes.ops ++ coerceOps ++ yieldPreOps ++ [ yieldOp ]
                        , resultVar = finalVar
                        , resultType = resultTy
                        , ctx = ctx2
                        , isTerminated = True
                        }

                Nothing ->
                    crash ("generateLeafWithJumps: Jump index " ++ String.fromInt index ++ " not found in jumpLookup")


{-| Generates a `Chain` node: the tests, then `success` if all pass and
`failure` otherwise. A chain of the single test that a Bool is `True` goes to
`generateChainForBoolADTWithJumps`, any other to
`generateChainGeneralWithJumps`.
-}
generateChainWithJumps : Ctx.Context -> List ( Mono.MonoDtPath, DT.Test ) -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice -> Array (Maybe Mono.MonoExpr) -> MlirType -> ExprResult
generateChainWithJumps ctx testChain success failure jumpLookup resultTy =
    case testChain of
        [ ( path, Test.IsBool True ) ] ->
            generateChainForBoolADTWithJumps ctx path success failure jumpLookup resultTy

        _ ->
            generateChainGeneralWithJumps ctx testChain success failure jumpLookup resultTy


{-| Generates a chain that tests one Bool for `True`: the Bool is read at
`path` as an `i1`, and one `eco.case` of `case_kind` `bool` has `success` under
tag 1 and `failure` under tag 0. The failure branch does not see names bound in
the success branch.
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

        spineCase =
            finishSpineCase ctx1b
                resultTy
                (\cS vS tS -> Ops.ecoCase cS vS boolVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] tS)
                (\cM pairsM -> Ops.ecoCaseMany cM boolVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] pairsM)
    in
    { ops = pathOps ++ spineCase.ops
    , resultVar = spineCase.resultVar
    , resultType = spineCase.resultType
    , ctx = Ctx.ctxAfterBranchOp ctx1 spineCase.ctx spineCase.newVars
    , isTerminated = False
    }


{-| Generates a chain of tests as nested `eco.case` ops, so that each test
runs only after every earlier one has passed. This matters because a later
test may read a value that exists only when an earlier one holds, such as the
head of a list that must first be tested to be non-empty. An empty chain is
just `success`.
-}
generateChainGeneralWithJumps : Ctx.Context -> List ( Mono.MonoDtPath, DT.Test ) -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice -> Array (Maybe Mono.MonoExpr) -> MlirType -> ExprResult
generateChainGeneralWithJumps ctx testChain success failure jumpLookup resultTy =
    case testChain of
        [] ->
            generateDeciderWithJumps ctx success jumpLookup resultTy

        [ singleTest ] ->
            let
                ( condOps, condVar, ctx1 ) =
                    Patterns.generateMonoTest ctx singleTest

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

                spineCase =
                    finishSpineCase ctx1b
                        resultTy
                        (\cS vS tS -> Ops.ecoCase cS vS condVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] tS)
                        (\cM pairsM -> Ops.ecoCaseMany cM condVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] pairsM)
            in
            { ops = condOps ++ spineCase.ops
            , resultVar = spineCase.resultVar
            , resultType = spineCase.resultType
            , ctx = Ctx.ctxAfterBranchOp ctx1 spineCase.ctx spineCase.newVars
            , isTerminated = False
            }

        firstTest :: restTests ->
            let
                ( firstOps, firstVar, ctx1 ) =
                    Patterns.generateMonoTest ctx firstTest

                thenRes =
                    generateChainGeneralWithJumps ctx1 restTests success failure jumpLookup resultTy

                ( thenRegion, ctx1a ) =
                    mkCaseRegionFromDecider thenRes resultTy

                ctxForElse =
                    Ctx.ctxForSiblingRegion ctx1 ctx1a

                elseRes =
                    generateDeciderWithJumps ctxForElse failure jumpLookup resultTy

                ( elseRegion, ctx1b ) =
                    mkCaseRegionFromDecider elseRes resultTy

                spineCase =
                    finishSpineCase ctx1b
                        resultTy
                        (\cS vS tS -> Ops.ecoCase cS vS firstVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] tS)
                        (\cM pairsM -> Ops.ecoCaseMany cM firstVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] pairsM)
            in
            { ops = firstOps ++ spineCase.ops
            , resultVar = spineCase.resultVar
            , resultType = spineCase.resultType
            , ctx = Ctx.ctxAfterBranchOp ctx1 spineCase.ctx spineCase.newVars
            , isTerminated = False
            }


{-| Tells whether a `FanOut`'s first edge tests a Bool, which makes it a
fan-out on a Bool.
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


{-| Returns the subtrees for `True` and for `False` among the edges of a Bool
fan-out, each falling back to `fallback` when no edge tests for it.
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


{-| Returns the string a string-equality test compares with, and crashes the
compiler on any other test, so that a string fan-out never loses an edge.
-}
extractStringPatternStrict : DT.Test -> String
extractStringPatternStrict test =
    case test of
        Test.IsStr s ->
            s

        _ ->
            crash "CGEN: expected Test.IsStr in string fanout, but got non-string test"


{-| Generates a `FanOut` node, a test of one value against several
alternatives, through `generateBoolFanOutWithJumps` for a Bool and
`generateFanOutGeneralWithJumps` otherwise.
-}
generateFanOutWithJumps : Ctx.Context -> Mono.MonoDtPath -> List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Mono.Decider Mono.MonoChoice -> Array (Maybe Mono.MonoExpr) -> MlirType -> ExprResult
generateFanOutWithJumps ctx path edges fallback jumpLookup resultTy =
    if isBoolFanOut edges then
        generateBoolFanOutWithJumps ctx path edges fallback jumpLookup resultTy

    else
        generateFanOutGeneralWithJumps ctx path edges fallback jumpLookup resultTy


{-| Generates a fan-out on a Bool as one `eco.case` of `case_kind` `bool` on the
`i1` read at `path`, with the `True` subtree under tag 1 and the `False`
subtree under tag 0.
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

        spineCase =
            finishSpineCase ctx1b
                resultTy
                (\cS vS tS -> Ops.ecoCase cS vS boolVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] tS)
                (\cM pairsM -> Ops.ecoCaseMany cM boolVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] pairsM)
    in
    { ops = pathOps ++ spineCase.ops
    , resultVar = spineCase.resultVar
    , resultType = spineCase.resultType
    , ctx = Ctx.ctxAfterBranchOp ctx1 spineCase.ctx spineCase.newVars
    , isTerminated = False
    }


{-| Generates a fan-out as one `eco.case` with an alternative per edge and a
last one for `fallback`.

The case kind and the scrutinee's type come from the first edge's test
(`Patterns.caseKindFromTest`), `ctor` when there are no edges. A string
fan-out is an `eco.case` carrying the edges' strings, with alternatives
numbered from 0; any other carries each edge's tag and a fallback tag from
`Patterns.computeFallbackTag`. Each alternative starts from the context after
the scrutinee, so no alternative sees names bound in another.

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

        spineCase =
            finishSpineCase ctx2a
                resultTy
                (\cS vS tS ->
                    case stringPatterns of
                        Just patterns ->
                            Ops.ecoCaseString cS vS scrutineeVar scrutineeType tags patterns allRegions tS

                        Nothing ->
                            Ops.ecoCase cS vS scrutineeVar scrutineeType caseKind tags allRegions tS
                )
                (\cM pairsM ->
                    case stringPatterns of
                        Just patterns ->
                            Ops.ecoCaseStringMany cM scrutineeVar scrutineeType tags patterns allRegions pairsM

                        Nothing ->
                            Ops.ecoCaseMany cM scrutineeVar scrutineeType caseKind tags allRegions pairsM
                )
    in
    { ops = pathOps ++ spineCase.ops
    , resultVar = spineCase.resultVar
    , resultType = spineCase.resultType
    , ctx = Ctx.ctxAfterBranchOp ctx1 spineCase.ctx spineCase.newVars
    , isTerminated = False
    }


{-| Returns a one-block region whose last op of `ops` is the terminator and
the rest the body. Crashes the compiler when `ops` is empty.
-}
mkRegionFromOps : List MlirOp -> MlirRegion
mkRegionFromOps ops =
    case List.reverse ops of
        [] ->
            crash "mkRegionFromOps: empty ops - region must have terminator"

        terminator :: restReversed ->
            MlirRegion
                { entry = { args = [], body = List.reverse restReversed, terminator = terminator }
                , blocks = OrderedDict.empty
                }


{-| Tells whether `op` is an `eco.yield`, the only op that may end an
`eco.case` alternative.
-}
isValidCaseTerminator : MlirOp -> Bool
isValidCaseTerminator op =
    op.name == "eco.yield"


{-| Returns the region for one `eco.case` alternative from the result of
generating it. Ops that already end in an `eco.yield` are used as they are.
Otherwise the value, such as that of a nested `eco.case`, is coerced to
`resultTy` and yielded (`emitSpineYield`). Ops that are empty, or that end in
something other than a yield with no result value, crash the compiler.
-}
mkCaseRegionFromDecider : ExprResult -> MlirType -> ( MlirRegion, Ctx.Context )
mkCaseRegionFromDecider exprRes resultTy =
    case List.reverse exprRes.ops of
        [] ->
            crash "mkCaseRegionFromDecider: empty ops - decider must produce ops"

        lastOp :: _ ->
            if isValidCaseTerminator lastOp then
                ( mkRegionFromOps exprRes.ops, exprRes.ctx )

            else if exprRes.resultVar == "" then
                crash
                    ("mkCaseRegionFromDecider: non-yield terminator '"
                        ++ lastOp.name
                        ++ "' with empty resultVar; "
                        ++ "this indicates a codegen bug (e.g., eco.return or eco.jump leaked into a case alternative)"
                    )

            else
                let
                    ( coerceOps, finalVar, ctx1 ) =
                        coerceResultToType exprRes.ctx exprRes.resultVar exprRes.resultType resultTy

                    ( yieldPreOps, yieldOp, ctx2 ) =
                        emitSpineYield ctx1 finalVar resultTy
                in
                ( mkRegionFromOps (exprRes.ops ++ coerceOps ++ yieldPreOps ++ [ yieldOp ]), ctx2 )


{-| Returns the result type a `case` or `if` declares for a value of
`resultMonoType`. On the result spine, for a tuple whose slot types match the
spine's layout exactly, it is the value-aggregate tuple type, so every branch
is coerced to that aggregate; otherwise it is the ABI type. `generateCase` and
`generateIf` both use it, so that a spine mixing the two declares one type.
-}
spineResultMlirType : Ctx.Context -> Mono.MonoType -> MlirType
spineResultMlirType ctx resultMonoType =
    case ctx.sretTailLayout of
        Just tailLayout ->
            case resultMonoType of
                Mono.MTuple _ ts ->
                    if
                        Types.tupleSlotTypes (Types.computeTupleLayout ts)
                            == Types.tupleSlotTypes tailLayout
                    then
                        Ops.aggTupleType (Types.tupleSlotTypes tailLayout)

                    else
                        Types.monoTypeToAbi resultMonoType

                _ ->
                    Types.monoTypeToAbi resultMonoType

        Nothing ->
            Types.monoTypeToAbi resultMonoType


{-| Generates a `case` (`generateDeciderWithJumps`). A decision tree with at
least one test becomes value-producing `eco.case` ops whose alternatives end in
`eco.yield`; a bare leaf is its branch body and that body's `eco.yield`, with
no `eco.case`. Shared branches, which `jumps` holds by index, are copied into
every leaf that jumps to them rather than emitted once. The result type is
`spineResultMlirType` of `resultMonoType`.
-}
generateCase : Ctx.Context -> Mono.Decider Mono.MonoChoice -> List ( Int, Mono.MonoExpr ) -> Mono.MonoType -> ExprResult
generateCase ctx decider jumps resultMonoType =
    let
        resultMlirType =
            spineResultMlirType ctx resultMonoType

        jumpLookup =
            pairsToSparseArray jumps

        decisionResult =
            generateDeciderWithJumps ctx decider jumpLookup resultMlirType
    in
    { ops = decisionResult.ops
    , resultVar = decisionResult.resultVar
    , resultType = resultMlirType
    , ctx = decisionResult.ctx
    , isTerminated = False
    }



-- ====== RECORD GENERATION ======


{-| Generates a record from `fields`, which are already in layout order. A
record with no fields is the embedded empty-record constant; any other is an
`eco.construct.record`, with each field the layout stores boxed is boxed first.
A field the layout stores unboxed is passed as it is. The record type is
registered in the type table either way.
-}
generateRecordCreate : Ctx.Context -> List Mono.MonoExpr -> Types.RecordLayout -> Mono.MonoType -> ExprResult
generateRecordCreate ctx fields layout recordType =
    let
        ( _, ctxWithType ) =
            Ctx.getOrCreateTypeIdForMonoType recordType ctx
    in
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
            ( fieldsOps, fieldVarsWithTypes, ctx1 ) =
                generateExprListTyped ctxWithType fields

            ( boxOpsReversed, boxedFieldVarsReversed, ctx2 ) =
                List.foldl
                    (\( ( var, ssaType ), fieldInfo ) ( opsAcc, varsAcc, ctxAcc ) ->
                        if fieldInfo.isUnboxed then
                            ( opsAcc, var :: varsAcc, ctxAcc )

                        else
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

            ( ctx4, constructOp ) =
                Ops.ecoConstructRecord ctx3 resultVar fieldVarPairs layout.fieldCount (Types.recordSlotKinds layout)
        in
        { ops = fieldsOps ++ boxOps ++ [ constructOp ]
        , resultVar = resultVar
        , resultType = Types.ecoValue
        , ctx = ctx4
        , isTerminated = False
        }


{-| Generates a read of the field at layout position `index` of `record`,
whose value is of the ABI type of `fieldType`. A field stored boxed whose ABI
type is a primitive is projected as `!eco.value` and then unboxed.
-}
generateRecordAccess : Ctx.Context -> Mono.MonoExpr -> Int -> Bool -> Mono.MonoType -> ExprResult
generateRecordAccess ctx record index isUnboxed fieldType =
    let
        recordResult : ExprResult
        recordResult =
            generateExpr ctx record

        ( projectVar, ctx1 ) =
            Ctx.freshVar recordResult.ctx

        fieldMlirType =
            Types.monoTypeToAbi fieldType
    in
    if isUnboxed then
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


{-| Generates a record update as a new `eco.construct.record`: the record is
evaluated once, each updated field (by layout index in `updates`) is generated
and coerced to its storage type, and every other field is projected from the
old record. A record with no fields is returned as it is.
-}
generateRecordUpdate : Ctx.Context -> Mono.MonoExpr -> List ( Int, Mono.MonoExpr ) -> Types.RecordLayout -> ExprResult
generateRecordUpdate ctx record updates layout =
    let
        recordResult : ExprResult
        recordResult =
            generateExpr ctx record
    in
    if layout.fieldCount == 0 then
        recordResult

    else
        let
            updateArr : Array (Maybe Mono.MonoExpr)
            updateArr =
                pairsToSparseArray updates

            ( fieldVarsAndTypesReversed, allOpsReversed, finalCtx ) =
                List.foldl
                    (\fieldInfo ( accVarsTypes, accOps, accCtx ) ->
                        let
                            storageType =
                                if fieldInfo.isUnboxed then
                                    Types.monoTypeToAbi fieldInfo.monoType

                                else
                                    Types.ecoValue
                        in
                        case Array.get fieldInfo.index updateArr |> Maybe.andThen identity of
                            Just updateExpr ->
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

            ( resultVar, ctx1 ) =
                Ctx.freshVar finalCtx

            ( ctx2, constructOp ) =
                Ops.ecoConstructRecord ctx1 resultVar fieldVarsAndTypes layout.fieldCount (Types.recordSlotKinds layout)
        in
        { ops = allOps ++ [ constructOp ]
        , resultVar = resultVar
        , resultType = Types.ecoValue
        , ctx = ctx2
        , isTerminated = False
        }



-- ====== TUPLE GENERATION ======


{-| Generates a heap tuple, an `eco.construct.tuple2` or `eco.construct.tuple3`,
with each element the layout stores boxed is boxed first; an element the
layout stores unboxed is passed as it is. The tuple type is registered in the
type table.
-}
generateTupleCreate : Ctx.Context -> List Mono.MonoExpr -> Types.TupleLayout -> Mono.MonoType -> ExprResult
generateTupleCreate ctx elements layout tupleType =
    let
        ( _, ctxWithType ) =
            Ctx.getOrCreateTypeIdForMonoType tupleType ctx

        ( elemOps, elemVarsWithTypes, ctx1 ) =
            generateExprListTyped ctxWithType elements

        ( boxOpsReversed, boxedElemVarsReversed, ctx2 ) =
            List.foldl
                (\( ( var, ssaType ), ( _, isUnboxed ) ) ( opsAcc, varsAcc, ctxAcc ) ->
                    if isUnboxed then
                        ( opsAcc, var :: varsAcc, ctxAcc )

                    else
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

        ( ctx4, constructOp ) =
            case elemVarPairs of
                [ ( aVar, aType ), ( bVar, bType ) ] ->
                    Ops.ecoConstructTuple2 ctx3 resultVar ( aVar, aType ) ( bVar, bType ) layout.unboxedBitmap

                [ ( aVar, aType ), ( bVar, bType ), ( cVar, cType ) ] ->
                    Ops.ecoConstructTuple3 ctx3 resultVar ( aVar, aType ) ( bVar, bType ) ( cVar, cType ) layout.unboxedBitmap

                _ ->
                    -- Elm has no tuples of more than three elements.
                    crash "Compiler.Generate.CodeGen.MLIR" "generateTupleCreate" "unreachable: tuples >3 elements rejected by canonicalization"
    in
    { ops = elemOps ++ boxOps ++ [ constructOp ]
    , resultVar = resultVar
    , resultType = Types.ecoValue
    , ctx = ctx4
    , isTerminated = False
    }



-- ====== VALUE-AGGREGATE PROMOTION ======


{-| Tells whether the tuple of type `tupleType` bound to `name` can be held as
a value aggregate while `body` runs: whether every use of `name` in `body`
only reads one of its elements. `tupleType` must be a tuple of two or three
elements.

The check is an escape walk over `body`. A use is admitted when it is a
destructuring that projects an element of the tuple; a case whose decision
tree only reaches the tuple through such projections; an alias `let a = name`,
whose uses are then checked too, unless an earlier binding of the chain refers
to the alias (`fwdRefd`); the tuple passed whole at a tail call position whose
loop parameter is held as slots of the same shape (`splitParams`); or the
tuple passed whole to a `$psplit` worker at a position split the same way
(`psplitTable`). Any other use, such as passing it to a function, capturing it,
returning it or binding the name again, makes the answer `False`.

-}
tupleBinderPromotable : Dict.Dict Name.Name Ctx.SplitParamInfo -> Dict.Dict Int Ctx.PsplitInfo -> Set.Set Name.Name -> Name.Name -> Mono.MonoType -> Mono.MonoExpr -> Bool
tupleBinderPromotable splitParams psplitTable fwdRefd name tupleType body =
    let
        wantKind =
            case tupleType of
                Mono.MTuple _ ts ->
                    if List.length ts == 2 then
                        Just Mono.Tuple2Container

                    else if List.length ts == 3 then
                        Just Mono.Tuple3Container

                    else
                        Nothing

                _ ->
                    Nothing
    in
    case wantKind of
        Nothing ->
            False

        Just kind ->
            walkPromo kind fwdRefd (tailSplitAllowSet kind splitParams) (psplitAllowPositions kind psplitTable) (Set.singleton name) body /= Nothing


{-| Returns the constructor's shape when the call bound to `name` can be built
as a value aggregate (`eco.make.custom`), and `Nothing` otherwise.

It can when the `aggPromote` flag is on, the call is a saturated direct call to
a constructor's global with at least one field and one argument per field, and
every use of `name` in `body` only reads a field, by the same escape walk as
`tupleBinderPromotable`, where reading the single field of a one-field
constructor also counts. A use that tests the constructor's tag reads the
value whole and is refused; nothing else checks how many constructors the
type has.

-}
promotableCtorCall : Ctx.Context -> Name.Name -> Int -> List Mono.MonoExpr -> Mono.MonoType -> Mono.CallInfo -> Mono.MonoExpr -> Maybe Mono.CtorShape
promotableCtorCall ctx name specId cargs resultType callInfo body =
    let
        -- The test generateCall uses to send a call to the saturated path.
        saturatedDirect =
            case callInfo.callKind of
                Mono.CallDirectFlat ->
                    not (isFunctionMonoType resultType)

                Mono.CallDirectKnownSegmentation ->
                    callInfo.isSingleStageSaturated

                _ ->
                    False
    in
    if not ctx.ecoConfig.aggPromote then
        Nothing

    else if not saturatedDirect then
        Nothing

    else
        case Dict.get specId ctx.ctorBySpec of
            Just shape ->
                if
                    (List.length cargs == List.length shape.fieldTypes)
                        && not (List.isEmpty cargs)
                        && (walkPromo (Mono.CustomContainer shape.name) ctx.fwdRefdLetNames (tailSplitAllowSet (Mono.CustomContainer shape.name) ctx.splitAggParams) (psplitAllowPositions (Mono.CustomContainer shape.name) ctx.psplitPromoted) (Set.singleton name) body /= Nothing)
                then
                    Just shape

                else
                    Nothing

            Nothing ->
                Nothing


{-| Tells whether every use of `name` in `body` only reads an element or field
of a container of `kind`, by the escape walk of `tupleBinderPromotable`, with
no forward references, split loop parameters or `$psplit` workers to allow
for.
-}
aggBinderPromotableWith : Mono.ContainerKind -> Name.Name -> Mono.MonoExpr -> Bool
aggBinderPromotableWith kind name body =
    walkPromo kind Set.empty Set.empty Dict.empty (Set.singleton name) body /= Nothing


{-| Returns the yield that ends a case alternative whose value is `finalVar`
of type `resultTy`, with any ops needed before it.

Off the result spine, or when `resultTy` is not a value aggregate, this is one
`eco.yield` of the value. On the spine an aggregate is instead projected into
its slots, which are yielded together, a _decomposed yield_, so that the case
returns one result per slot and never an aggregate; `finishSpineCase` rebuilds
the aggregate after the case. An aggregate must not cross out of the block
that made it, because the lowering's GC root tracking cannot follow a pointer
held inside one.

-}
emitSpineYield : Ctx.Context -> String -> MlirType -> ( List MlirOp, MlirOp, Ctx.Context )
emitSpineYield ctx finalVar resultTy =
    case ctx.sretTailLayout of
        Just layout ->
            if Types.isAggValueType resultTy then
                let
                    slotTys =
                        Types.tupleSlotTypes layout

                    ( projOpsRev, pairsRev, ctxA ) =
                        List.foldl
                            (\( idx, slotTy ) ( opsAcc, pairsAcc, ctxAcc ) ->
                                let
                                    ( pv, ctxF ) =
                                        Ctx.freshVar ctxAcc

                                    ( ctxP, projOp ) =
                                        if layout.arity == 2 then
                                            Ops.ecoProjectTuple2Agg ctxF pv idx slotTy ( finalVar, resultTy )

                                        else
                                            Ops.ecoProjectTuple3Agg ctxF pv idx slotTy ( finalVar, resultTy )
                                in
                                ( projOp :: opsAcc, ( pv, slotTy ) :: pairsAcc, ctxP )
                            )
                            ( [], [], ctx )
                            (List.indexedMap Tuple.pair slotTys)

                    ( ctxB, yieldOp ) =
                        Ops.ecoYieldMany ctxA (List.reverse pairsRev)
                in
                ( List.reverse projOpsRev, yieldOp, ctxB )

            else
                let
                    ( ctxA, yieldOp ) =
                        Ops.ecoYield ctx finalVar resultTy
                in
                ( [], yieldOp, ctxA )

        Nothing ->
            let
                ( ctxA, yieldOp ) =
                    Ops.ecoYield ctx finalVar resultTy
            in
            ( [], yieldOp, ctxA )


{-| The ops and value of a case built by `finishSpineCase`, with `newVars`, the
SSA values the ops define outside the case's regions.
-}
type alias SpineCaseResult =
    { ops : List MlirOp
    , resultVar : String
    , resultType : MlirType
    , newVars : List String
    , ctx : Ctx.Context
    }


{-| Builds the `eco.case` whose alternatives are already made, from the two
builders the caller supplies.

Off the result spine, or when `resultTy` is not a value aggregate,
`buildSingle` builds a case with one result of `resultTy`. On the spine an
aggregate result is built with `buildMany`, one result per slot of the spine
layout, matching the decomposed yields of `emitSpineYield`, and an
`eco.make.tuple2` or `eco.make.tuple3` right after the case rebuilds the
aggregate from them.

-}
finishSpineCase :
    Ctx.Context
    -> MlirType
    -> (Ctx.Context -> String -> MlirType -> ( Ctx.Context, MlirOp ))
    -> (Ctx.Context -> List ( String, MlirType ) -> ( Ctx.Context, MlirOp ))
    -> SpineCaseResult
finishSpineCase ctx resultTy buildSingle buildMany =
    let
        singlePath () =
            let
                ( v, ctxA ) =
                    Ctx.freshVar ctx

                ( ctxB, caseOp ) =
                    buildSingle ctxA v resultTy
            in
            { ops = [ caseOp ], resultVar = v, resultType = resultTy, newVars = [ v ], ctx = ctxB }
    in
    case ctx.sretTailLayout of
        Just layout ->
            if Types.isAggValueType resultTy then
                let
                    slotTys =
                        Types.tupleSlotTypes layout

                    ( pairsRev, ctxA ) =
                        List.foldl
                            (\slotTy ( acc, c ) ->
                                let
                                    ( v, c1 ) =
                                        Ctx.freshVar c
                                in
                                ( ( v, slotTy ) :: acc, c1 )
                            )
                            ( [], ctx )
                            slotTys

                    pairs =
                        List.reverse pairsRev

                    ( ctxB, caseOp ) =
                        buildMany ctxA pairs

                    ( aggVar, ctxC ) =
                        Ctx.freshVar ctxB

                    ( ctxD, makeOp ) =
                        case pairs of
                            [ a, b ] ->
                                Ops.ecoMakeTuple2 ctxC aggVar a b

                            [ a, b, c ] ->
                                Ops.ecoMakeTuple3 ctxC aggVar a b c

                            _ ->
                                crash "finishSpineCase: slot arity not 2/3"
                in
                { ops = [ caseOp, makeOp ]
                , resultVar = aggVar
                , resultType = resultTy
                , newVars = aggVar :: List.map Tuple.first pairs
                , ctx = ctxD
                }

            else
                singlePath ()

        Nothing ->
            singlePath ()


{-| Generates a call on the result spine to a global that has a `$sret` worker
returning exactly the spine's slot types, as a multi-result call to the
worker and an `eco.make.tuple2` or `eco.make.tuple3` that rebuilds the tuple as
a value aggregate. Returns `Nothing` for any other call, or off the spine.
-}
trySretFreshLeaf : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Maybe ExprResult
trySretFreshLeaf ctx0 func args =
    case ( ctx0.sretTailLayout, func ) of
        ( Just layout, Mono.MonoVarGlobal _ sid _ ) ->
            case Dict.get sid ctx0.sretPromoted of
                Just info ->
                    if info.slotTypes == Types.tupleSlotTypes layout then
                        let
                            ( callOps, resultPairs, ctxA ) =
                                emitSretCallMulti { ctx0 | sretTailLayout = Nothing } sid args info

                            ( aggVar, ctxB ) =
                                Ctx.freshVar ctxA

                            mMake =
                                case resultPairs of
                                    [ p1, p2 ] ->
                                        Just (Ops.ecoMakeTuple2 ctxB aggVar p1 p2)

                                    [ p1, p2, p3 ] ->
                                        Just (Ops.ecoMakeTuple3 ctxB aggVar p1 p2 p3)

                                    _ ->
                                        Nothing
                        in
                        case mMake of
                            Just ( ctxC, makeOp ) ->
                                Just
                                    { ops = callOps ++ [ makeOp ]
                                    , resultVar = aggVar
                                    , resultType = Ops.aggTupleType info.slotTypes
                                    , ctx = { ctxC | sretTailLayout = ctx0.sretTailLayout }
                                    , isTerminated = False
                                    }

                            Nothing ->
                                Nothing

                    else
                        Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| Generates a call to the `$sret` worker of `specId`: the arguments converted
to the global's signature (`boxToMatchSignatureTyped`), and one result per slot
type of `info`. Returns the ops and the result values with their types.
-}
emitSretCallMulti : Ctx.Context -> Int -> List Mono.MonoExpr -> Ctx.SretInfo -> ( List MlirOp, List ( String, MlirType ), Ctx.Context )
emitSretCallMulti ctx specId cargs info =
    let
        ( argOps, argsWithTypes, ctxA ) =
            generateExprListTyped ctx cargs

        funcName =
            specIdToFuncName ctx.registry specId

        maybeSig =
            Array.get specId ctx.signatures |> Maybe.andThen identity

        ( boxOps, argVarPairs, ctxB ) =
            case maybeSig of
                Just sig ->
                    boxToMatchSignatureTyped ctxA argsWithTypes sig.paramTypes

                Nothing ->
                    ( [], argsWithTypes, ctxA )

        ( resultPairsRev, ctxC ) =
            List.foldl
                (\slotTy ( acc, c ) ->
                    let
                        ( v, c1 ) =
                            Ctx.freshVar c
                    in
                    ( ( v, slotTy ) :: acc, c1 )
                )
                ( [], ctxB )
                info.slotTypes

        resultPairs =
            List.reverse resultPairsRev

        ( ctxD, callOp ) =
            Ops.ecoCallNamedMulti ctxC resultPairs (funcName ++ "$sret") argVarPairs
    in
    ( argOps ++ boxOps ++ [ callOp ], resultPairs, ctxD )


{-| Generates the let binding of `name` to `expr`, and its body, through a
`$sret` worker when that is possible, and returns `Nothing` otherwise.

A `$sret` worker returns each element of its function's tuple result as a
separate result (see `Context.SretInfo`). The binding uses it when `expr` is a
saturated direct call to a global that has one, `name` is not
forward-referenced, and every use of `name` only reads an element, as
`tupleBinderPromotable` decides. A Unit body stands for a loop body held in
`tailRecLetBody`, and without one the binding is refused.

-}
trySretLetBinding : Ctx.Context -> Ctx.Context -> Name.Name -> Mono.MonoExpr -> Mono.MonoExpr -> Maybe ExprResult
trySretLetBinding ctx ctxWithPlaceholders name expr body =
    if Dict.isEmpty ctx.sretPromoted then
        Nothing

    else
        case expr of
            Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) cargs callResultType callInfo ->
                case Dict.get specId ctx.sretPromoted of
                    Just info ->
                        let
                            saturatedDirect =
                                case callInfo.callKind of
                                    Mono.CallDirectFlat ->
                                        not (isFunctionMonoType callResultType)

                                    Mono.CallDirectKnownSegmentation ->
                                        callInfo.isSingleStageSaturated

                                    _ ->
                                        False

                            ( analysisBody, promotionBodyOk ) =
                                case body of
                                    Mono.MonoUnit ->
                                        case ctx.tailRecLetBody of
                                            Just realBody ->
                                                ( realBody, True )

                                            Nothing ->
                                                ( body, False )

                                    _ ->
                                        ( body, True )

                            chainHeadSafe =
                                promotionBodyOk && not (Set.member name ctx.fwdRefdLetNames)
                        in
                        if
                            saturatedDirect
                                && chainHeadSafe
                                && tupleBinderPromotable ctx.splitAggParams ctx.psplitPromoted ctx.fwdRefdLetNames name callResultType analysisBody
                        then
                            Just (emitSretLetBinding ctx ctxWithPlaceholders name specId cargs info body)

                        else
                            Nothing

                    Nothing ->
                        Nothing

            _ ->
                Nothing


{-| Generates the let binding of `name` as a call to the `$sret` worker of
`specId`, then `body`. The name is held as the call's results, in
`splitAggParams`, and has no var mapping. After the body the holding is
removed again, except when the body is Unit, the stand-in for a loop body
generated later from the returned context, in which case it is kept.
-}
emitSretLetBinding : Ctx.Context -> Ctx.Context -> Name.Name -> Int -> List Mono.MonoExpr -> Ctx.SretInfo -> Mono.MonoExpr -> ExprResult
emitSretLetBinding ctx ctxWithPlaceholders name specId cargs info body =
    let
        outerSiblings =
            ctx.currentLetSiblings

        ( callOps, resultPairs, ctxD ) =
            emitSretCallMulti ctxWithPlaceholders specId cargs info

        savedSplit =
            ctxD.splitAggParams

        ctxBody =
            { ctxD
                | varMappings = Dict.remove name ctxD.varMappings
                , splitAggParams =
                    Dict.insert name
                        { slots = resultPairs, split = Ctx.SplitTuple info.layout }
                        ctxD.splitAggParams
                , sretTailLayout = ctx.sretTailLayout
            }

        bodyResult =
            generateExpr ctxBody body

        bodyCtx =
            bodyResult.ctx

        ctxOut =
            case body of
                Mono.MonoUnit ->
                    { bodyCtx | currentLetSiblings = outerSiblings }

                _ ->
                    { bodyCtx
                        | currentLetSiblings = outerSiblings
                        , splitAggParams = savedSplit
                        , varMappings = Dict.remove name bodyCtx.varMappings
                    }
    in
    { ops = callOps ++ bodyResult.ops
    , resultVar = bodyResult.resultVar
    , resultType = bodyResult.resultType
    , ctx = ctxOut
    , isTerminated = bodyResult.isTerminated
    }


{-| Tells whether the loop parameter `name` of a tail-recursive function, a
container of `kind`, can be held as scalar slots: whether every use of it in
`body` only reads an element or field, or passes it whole to the same
parameter in a tail call, or to a `$psplit` worker at a position split the same
way. A use of the whole value would have to rebuild it, allocating inside the
loop.
-}
paramSplitAdmissible : Dict.Dict Int Ctx.PsplitInfo -> Mono.ContainerKind -> Name.Name -> Mono.MonoExpr -> Bool
paramSplitAdmissible psplitTable kind name body =
    walkPromo kind Set.empty (Set.singleton name) (psplitAllowPositions kind psplitTable) (Set.singleton name) body /= Nothing


{-| Returns the names, among the values held as scalar slots, whose split is of
the shape `kind`: the loop parameters a tracked value may be passed to whole
in a tail call without escaping.
-}
tailSplitAllowSet : Mono.ContainerKind -> Dict.Dict Name.Name Ctx.SplitParamInfo -> Set.Set Name.Name
tailSplitAllowSet kind splitParams =
    Dict.foldl
        (\pName info acc ->
            if splitMatchesKind kind info then
                Set.insert pName acc

            else
                acc
        )
        Set.empty
        splitParams


{-| Tells whether a value held as slots is split as a container of `kind`.
-}
splitMatchesKind : Mono.ContainerKind -> Ctx.SplitParamInfo -> Bool
splitMatchesKind kind info =
    specMatchesKind kind info.split


{-| Tells whether a split is of a container of `kind`: a tuple of the same
arity, or the constructor of the same name.
-}
specMatchesKind : Mono.ContainerKind -> Ctx.SplitSpec -> Bool
specMatchesKind kind spec =
    case ( kind, spec ) of
        ( Mono.Tuple2Container, Ctx.SplitTuple layout ) ->
            layout.arity == 2

        ( Mono.Tuple3Container, Ctx.SplitTuple layout ) ->
            layout.arity == 3

        ( Mono.CustomContainer cname, Ctx.SplitCtor clayout ) ->
            clayout.name == cname

        _ ->
            False


{-| Returns, for each global with a `$psplit` worker, the argument positions
split as a container of `kind`: the positions a tracked value may be passed to
whole without escaping. Globals with no such position are left out.
-}
psplitAllowPositions : Mono.ContainerKind -> Dict.Dict Int Ctx.PsplitInfo -> Dict.Dict Int (Set.Set Int)
psplitAllowPositions kind table =
    Dict.foldl
        (\sid info acc ->
            let
                positions =
                    List.indexedMap Tuple.pair info.paramPlans
                        |> List.filterMap
                            (\( i, mPlan ) ->
                                case mPlan of
                                    Just plan ->
                                        if specMatchesKind kind plan.spec then
                                            Just i

                                        else
                                            Nothing

                                    Nothing ->
                                        Nothing
                            )
                        |> Set.fromList
            in
            if Set.isEmpty positions then
                acc

            else
                Dict.insert sid positions acc
        )
        Dict.empty
        table


{-| Tells whether the type is a function type.
-}
isFunctionMonoType : Mono.MonoType -> Bool
isFunctionMonoType ty =
    case ty of
        Mono.MFunction _ _ _ _ ->
            True

        _ ->
            False


{-| Checks that `expr` uses the tracked names `s` only in admitted ways, for the
escape walk of `tupleBinderPromotable`: `Nothing` when some use lets the value
escape, and `Just` the tracked set otherwise.

The set grows only by an alias `let a = x` of a tracked `x`, and only the let's
body sees the grown set. `tailSplitOk` and `callSplitOk` are the loop
parameters and `$psplit` positions at which a tracked name may be passed
whole. Inside a closure or a nested tail-recursive definition neither applies,
because tail calls there belong to another loop; and a tracked name among a
closure's parameters or capture names refuses the value.

-}
walkPromo : Mono.ContainerKind -> Set.Set Name.Name -> Set.Set Name.Name -> Dict.Dict Int (Set.Set Int) -> Set.Set Name.Name -> Mono.MonoExpr -> Maybe (Set.Set Name.Name)
walkPromo kind fwdRefd tailSplitOk callSplitOk s expr =
    case expr of
        Mono.MonoLiteral _ _ ->
            Just s

        Mono.MonoUnit ->
            Just s

        Mono.MonoVarLocal x _ ->
            if Set.member x s then
                Nothing

            else
                Just s

        Mono.MonoVarGlobal _ _ _ ->
            Just s

        Mono.MonoVarKernel _ _ _ _ _ ->
            Just s

        Mono.MonoAccessorValue _ _ _ ->
            Just s

        Mono.MonoList _ es _ ->
            walkPromoAll kind fwdRefd tailSplitOk callSplitOk s es

        Mono.MonoTupleCreate _ es _ ->
            walkPromoAll kind fwdRefd tailSplitOk callSplitOk s es

        Mono.MonoRecordCreate fes _ ->
            walkPromoAll kind fwdRefd tailSplitOk callSplitOk s (List.map Tuple.second fes)

        Mono.MonoRecordAccess e _ _ ->
            walkPromo kind fwdRefd tailSplitOk callSplitOk s e

        Mono.MonoRecordUpdate base fes _ ->
            walkPromo kind fwdRefd tailSplitOk callSplitOk s base
                |> Maybe.andThen (\_ -> walkPromoAll kind fwdRefd tailSplitOk callSplitOk s (List.map Tuple.second fes))

        Mono.MonoDestruct (Mono.MonoDestructor bound path _) inner _ ->
            if Set.member bound s then
                Nothing

            else if promoPathOk kind s path then
                walkPromo kind fwdRefd tailSplitOk callSplitOk s inner

            else
                Nothing

        Mono.MonoCase s1 s2 decider jumps _ ->
            if Set.member s1 s then
                Nothing

            else if Set.member s2 s then
                if deciderScrutineeOk kind s decider then
                    walkPromoDecider kind fwdRefd tailSplitOk callSplitOk s decider
                        |> Maybe.andThen (\_ -> walkPromoAll kind fwdRefd tailSplitOk callSplitOk s (List.map Tuple.second jumps))

                else
                    Nothing

            else
                walkPromoDecider kind fwdRefd tailSplitOk callSplitOk s decider
                    |> Maybe.andThen (\_ -> walkPromoAll kind fwdRefd tailSplitOk callSplitOk s (List.map Tuple.second jumps))

        Mono.MonoIf branches final _ ->
            walkPromoAll kind fwdRefd tailSplitOk callSplitOk s (final :: List.concatMap (\( c, b ) -> [ c, b ]) branches)

        Mono.MonoLet (Mono.MonoDef x rhs) inner _ ->
            if Set.member x s then
                Nothing

            else
                case rhs of
                    Mono.MonoVarLocal y _ ->
                        if Set.member y s then
                            if Set.member x fwdRefd then
                                Nothing

                            else
                                walkPromo kind fwdRefd tailSplitOk callSplitOk (Set.insert x s) inner

                        else
                            walkPromo kind fwdRefd tailSplitOk callSplitOk s inner

                    _ ->
                        walkPromo kind fwdRefd tailSplitOk callSplitOk s rhs
                            |> Maybe.andThen (\_ -> walkPromo kind fwdRefd tailSplitOk callSplitOk s inner)

        Mono.MonoLet (Mono.MonoTailDef x params rhs) inner _ ->
            if Set.member x s || List.any (\( p, _ ) -> Set.member p s) params then
                Nothing

            else
                walkPromo kind fwdRefd Set.empty Dict.empty s rhs
                    |> Maybe.andThen (\_ -> walkPromo kind fwdRefd tailSplitOk callSplitOk s inner)

        Mono.MonoCall _ f args _ _ ->
            -- If the call is not redirected to the worker after all, the
            -- aggregate is put on the heap at the call (eco.to_heap).
            case f of
                Mono.MonoVarGlobal _ calleeSid _ ->
                    case Dict.get calleeSid callSplitOk of
                        Just okPositions ->
                            let
                                argOk ( i, argE ) =
                                    case argE of
                                        Mono.MonoVarLocal v _ ->
                                            not (Set.member v s) || Set.member i okPositions

                                        _ ->
                                            walkPromo kind fwdRefd tailSplitOk callSplitOk s argE /= Nothing
                            in
                            if List.all argOk (List.indexedMap Tuple.pair args) then
                                Just s

                            else
                                Nothing

                        Nothing ->
                            walkPromoAll kind fwdRefd tailSplitOk callSplitOk s args

                _ ->
                    walkPromo kind fwdRefd tailSplitOk callSplitOk s f
                        |> Maybe.andThen (\_ -> walkPromoAll kind fwdRefd tailSplitOk callSplitOk s args)

        Mono.MonoTailCall _ args _ ->
            let
                argOk ( pName, argE ) =
                    case argE of
                        Mono.MonoVarLocal v _ ->
                            not (Set.member v s) || Set.member pName tailSplitOk

                        _ ->
                            walkPromo kind fwdRefd tailSplitOk callSplitOk s argE /= Nothing
            in
            if List.all argOk args then
                Just s

            else
                Nothing

        Mono.MonoClosure info inner _ ->
            if
                List.any (\( p, _ ) -> Set.member p s) info.params
                    || List.any (\( c, _, _ ) -> Set.member c s) info.captures
            then
                Nothing

            else
                walkPromoAll kind fwdRefd tailSplitOk callSplitOk s (List.map (\( _, e, _ ) -> e) info.captures)
                    |> Maybe.andThen (\_ -> walkPromo kind fwdRefd Set.empty Dict.empty s inner)


{-| Runs `walkPromo` on each of `es` with the same tracked set, stopping at the
first that refuses.
-}
walkPromoAll : Mono.ContainerKind -> Set.Set Name.Name -> Set.Set Name.Name -> Dict.Dict Int (Set.Set Int) -> Set.Set Name.Name -> List Mono.MonoExpr -> Maybe (Set.Set Name.Name)
walkPromoAll kind fwdRefd tailSplitOk callSplitOk s es =
    List.foldl
        (\e acc -> Maybe.andThen (\_ -> walkPromo kind fwdRefd tailSplitOk callSplitOk s e) acc)
        (Just s)
        es


{-| Tells whether a decision tree reaches the tracked names `s` only through
element projections of a container of `kind`. In a chain a tracked name may
be tested whole only by an `IsTuple` test, which reads nothing; every other
test, and the value a fan-out dispatches on, must project first. A `DtUnbox`
step directly on a tracked name is accepted only for a constructor `kind`.
-}
deciderScrutineeOk : Mono.ContainerKind -> Set.Set Name.Name -> Mono.Decider Mono.MonoChoice -> Bool
deciderScrutineeOk kind s decider =
    case decider of
        Mono.Leaf _ ->
            True

        Mono.Chain tests success failure ->
            List.all (\( p, t ) -> dtTestPathOk kind s p t) tests
                && deciderScrutineeOk kind s success
                && deciderScrutineeOk kind s failure

        Mono.FanOut path edges fallback ->
            dtProjectingPathOk kind s path
                && List.all (\( _, d ) -> deciderScrutineeOk kind s d) edges
                && deciderScrutineeOk kind s fallback


{-| Tells whether the path of one chain test is acceptable for
`deciderScrutineeOk`: a tracked root itself only under `IsTuple`, any other
path as `dtProjectingPathOk` decides.
-}
dtTestPathOk : Mono.ContainerKind -> Set.Set Name.Name -> Mono.MonoDtPath -> DT.Test -> Bool
dtTestPathOk kind s path test =
    case path of
        Mono.DtRoot r _ ->
            if Set.member r s then
                case test of
                    Test.IsTuple ->
                        True

                    _ ->
                        False

            else
                True

        _ ->
            dtProjectingPathOk kind s path


{-| Tells whether a decision-tree path whose value is read reaches a tracked
root only through a projection: the step directly above the root must be a
`DtIndex` of `kind`, or a `DtUnbox` when `kind` is a constructor.
-}
dtProjectingPathOk : Mono.ContainerKind -> Set.Set Name.Name -> Mono.MonoDtPath -> Bool
dtProjectingPathOk kind s path =
    case path of
        Mono.DtRoot r _ ->
            not (Set.member r s)

        Mono.DtIndex _ stepKind _ sub ->
            case sub of
                Mono.DtRoot r _ ->
                    not (Set.member r s) || stepKind == kind

                _ ->
                    dtProjectingPathOk kind s sub

        Mono.DtUnbox _ sub ->
            case sub of
                Mono.DtRoot r _ ->
                    not (Set.member r s) || isCustomKind kind

                _ ->
                    dtProjectingPathOk kind s sub


{-| Runs `walkPromo` on every inline leaf of a decision tree. A leaf that jumps
to a shared branch is checked with the case's branches instead.
-}
walkPromoDecider : Mono.ContainerKind -> Set.Set Name.Name -> Set.Set Name.Name -> Dict.Dict Int (Set.Set Int) -> Set.Set Name.Name -> Mono.Decider Mono.MonoChoice -> Maybe (Set.Set Name.Name)
walkPromoDecider kind fwdRefd tailSplitOk callSplitOk s decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            walkPromo kind fwdRefd tailSplitOk callSplitOk s e

        Mono.Leaf (Mono.Jump _) ->
            Just s

        Mono.Chain _ success failure ->
            walkPromoDecider kind fwdRefd tailSplitOk callSplitOk s success
                |> Maybe.andThen (\_ -> walkPromoDecider kind fwdRefd tailSplitOk callSplitOk s failure)

        Mono.FanOut _ edges fallback ->
            List.foldl
                (\( _, d ) acc -> Maybe.andThen (\_ -> walkPromoDecider kind fwdRefd tailSplitOk callSplitOk s d) acc)
                (Just s)
                edges
                |> Maybe.andThen (\_ -> walkPromoDecider kind fwdRefd tailSplitOk callSplitOk s fallback)


{-| Tells whether a destructuring path reaches a tracked root only through a
projection: the step directly above the root must be a `MonoIndex` of `kind`,
or, when `kind` is a constructor, a `MonoUnbox`, which reads the single field
of a one-field constructor. A path that is just a tracked root, or that steps
from one by a record field or another container kind, is refused.
-}
promoPathOk : Mono.ContainerKind -> Set.Set Name.Name -> Mono.MonoPath -> Bool
promoPathOk kind s path =
    case path of
        Mono.MonoRoot r _ ->
            not (Set.member r s)

        Mono.MonoIndex _ stepKind _ sub ->
            case sub of
                Mono.MonoRoot r _ ->
                    not (Set.member r s) || stepKind == kind

                _ ->
                    promoPathOk kind s sub

        Mono.MonoField _ _ sub ->
            case sub of
                Mono.MonoRoot r _ ->
                    not (Set.member r s)

                _ ->
                    promoPathOk kind s sub

        Mono.MonoUnbox _ sub ->
            case sub of
                Mono.MonoRoot r _ ->
                    not (Set.member r s) || isCustomKind kind

                _ ->
                    promoPathOk kind s sub


{-| Tells whether the container kind is a constructor.
-}
isCustomKind : Mono.ContainerKind -> Bool
isCustomKind kind =
    case kind of
        Mono.CustomContainer _ ->
            True

        _ ->
            False


{-| Generates a tuple literal as a value aggregate, an `eco.make.tuple2` or
`eco.make.tuple3` of type `!eco.tuple2<..>` or `!eco.tuple3<..>`, which
allocates nothing. Elements are prepared as `generateTupleCreate` prepares
them, so the slots have the types the heap tuple's would.
-}
generateTupleCreateValue : Ctx.Context -> List Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateTupleCreateValue ctx elements monoType =
    let
        layout =
            Types.computeTupleLayout (getTupleElements monoType)

        ( _, ctxWithType ) =
            Ctx.getOrCreateTypeIdForMonoType monoType ctx

        ( elemOps, elemVarsWithTypes, ctx1 ) =
            generateExprListTyped ctxWithType elements

        ( boxOpsReversed, boxedElemVarsReversed, ctx2 ) =
            List.foldl
                (\( ( var, ssaType ), ( _, isUnboxed ) ) ( opsAcc, varsAcc, ctxAcc ) ->
                    if isUnboxed then
                        ( opsAcc, var :: varsAcc, ctxAcc )

                    else
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

        ( resultVar, ctx3 ) =
            Ctx.freshVar ctx2

        ( ctx4, makeOp ) =
            case elemVarPairs of
                [ a, b ] ->
                    Ops.ecoMakeTuple2 ctx3 resultVar a b

                [ a, b, c ] ->
                    Ops.ecoMakeTuple3 ctx3 resultVar a b c

                _ ->
                    crash "generateTupleCreateValue: unreachable: tuples >3 elements rejected by canonicalization"
    in
    { ops = elemOps ++ boxOps ++ [ makeOp ]
    , resultVar = resultVar
    , resultType = Ops.aggTupleType (List.map Tuple.second elemVarPairs)
    , ctx = ctx4
    , isTerminated = False
    }


{-| Generates a constructor call as a value aggregate, an `eco.make.custom` of
type `!eco.custom<..>`, which neither calls the constructor's function nor
allocates. The fields are prepared by `prepareCtorSlots`.
-}
generateCustomCreateValue : Ctx.Context -> Mono.CtorShape -> List Mono.MonoExpr -> ExprResult
generateCustomCreateValue ctx shape args =
    let
        layout =
            Types.computeCtorLayout shape

        ( prepOps, slotPairs, ctx2 ) =
            prepareCtorSlots ctx layout args

        ( resultVar, ctx3 ) =
            Ctx.freshVar ctx2

        ( ctx4, makeOp ) =
            Ops.ecoMakeCustom ctx3 resultVar layout.tag (Just shape.name) slotPairs
    in
    { ops = prepOps ++ [ makeOp ]
    , resultVar = resultVar
    , resultType = Ops.aggCustomType (List.map Tuple.second slotPairs)
    , ctx = ctx4
    , isTerminated = False
    }


{-| Generates a constructor call as an `eco.construct.custom` in place, an
`!eco.value` on the heap, with the fields prepared by `prepareCtorSlots` as
for `generateCustomCreateValue`.
-}
generateCustomCreateHeap : Ctx.Context -> Mono.CtorShape -> List Mono.MonoExpr -> ExprResult
generateCustomCreateHeap ctx shape args =
    let
        layout =
            Types.computeCtorLayout shape

        ( prepOps, slotPairs, ctx2 ) =
            prepareCtorSlots ctx layout args

        ( resultVar, ctx3 ) =
            Ctx.freshVar ctx2

        ( ctx4, constructOp ) =
            Ops.ecoConstructCustom ctx3
                resultVar
                layout.tag
                (List.length layout.fields)
                (Types.ctorSlotKinds layout)
                slotPairs
                (Just (Name.toElmString layout.name))
    in
    { ops = prepOps ++ [ constructOp ]
    , resultVar = resultVar
    , resultType = Types.ecoValue
    , ctx = ctx4
    , isTerminated = False
    }


{-| Generates the constructor's arguments and converts each to its slot type in
`layout`: the ABI primitive for a field stored unboxed, `!eco.value` for one
stored boxed. An argument is boxed or unboxed as needed; one whose primitive
type differs from its slot's is passed unchanged, labelled with the slot type.
-}
prepareCtorSlots : Ctx.Context -> Types.CtorLayout -> List Mono.MonoExpr -> ( List MlirOp, List ( String, MlirType ), Ctx.Context )
prepareCtorSlots ctx layout args =
    let
        ( argOps, argVarsWithTypes, ctx1 ) =
            generateExprListTyped ctx args

        ( coerceOpsRev, slotPairsRev, ctx2 ) =
            List.foldl
                (\( ( var, ssaType ), field ) ( opsAcc, pairsAcc, ctxAcc ) ->
                    let
                        target =
                            if field.isUnboxed then
                                Types.monoTypeToAbi field.monoType

                            else
                                Types.ecoValue
                    in
                    if ssaType == target then
                        ( opsAcc, ( var, target ) :: pairsAcc, ctxAcc )

                    else if Types.isEcoValueType target then
                        let
                            ( moreOps, boxedVar, newCtx ) =
                                boxToEcoValue ctxAcc var ssaType
                        in
                        ( List.reverse moreOps ++ opsAcc, ( boxedVar, target ) :: pairsAcc, newCtx )

                    else if Types.isEcoValueType ssaType then
                        let
                            ( unboxOps, unboxedVar, newCtx ) =
                                Intrinsics.unboxToType ctxAcc var target
                        in
                        ( List.reverse unboxOps ++ opsAcc, ( unboxedVar, target ) :: pairsAcc, newCtx )

                    else
                        ( opsAcc, ( var, target ) :: pairsAcc, ctxAcc )
                )
                ( [], [], ctx1 )
                (List.map2 Tuple.pair argVarsWithTypes layout.fields)
    in
    ( argOps ++ List.reverse coerceOpsRev, List.reverse slotPairsRev, ctx2 )



-- ====== UNIT GENERATION ======


{-| Generates Unit as the embedded Unit constant.
-}
generateUnit : Ctx.Context -> ExprResult
generateUnit ctx =
    let
        ( var, ctx1 ) =
            Ctx.freshVar ctx

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


{-| Returns the number a Char literal's text stands for. The text is either one
character, whose code is returned, or an escape as the parser keeps it: `\n`,
`\r`, `\t`, `\"`, `\'`, `\\` or `\uXXXX`. A `\uXXXX` that is a high
surrogate is combined with the `\uXXXX` after it into the code point it
encodes, which is above `0xFFFF`. Text of more than one unit that does not
start with a backslash, such as a raw character above `0xFFFF`, returns the
code of its first character, its full code point. Empty text, an unknown
escape, a trailing backslash or bad hex digits crash the compiler.
-}
decodeCharLiteral : String -> Int
decodeCharLiteral value =
    -- A lone backslash is the character itself, not an escape.
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


{-| Returns the character code of the escape whose text after the backslash is
`rest`, as `decodeCharLiteral` describes.
-}
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


{-| Returns the code of a `\u` escape whose text after the `u` is `hex`,
combining a high surrogate with the escape that follows it.
-}
decodeUnicodeEscape : String -> Int
decodeUnicodeEscape hex =
    case Hex.fromString (String.toLower (String.left 4 hex)) of
        Ok code ->
            if code >= 0xD800 && code <= 0xDBFF then
                decodeSurrogatePair code (String.dropLeft 6 hex)

            else
                code

        Err _ ->
            crash ("decodeCharLiteral: invalid hex in \\u" ++ String.left 4 hex)


{-| Returns the code point encoded by the high surrogate `hi` and the low
surrogate whose four hex digits begin `rest`.
-}
decodeSurrogatePair : Int -> String -> Int
decodeSurrogatePair hi rest =
    case Hex.fromString (String.toLower (String.left 4 rest)) of
        Ok lo ->
            0x00010000 + ((hi - 0xD800) * 0x0400) + (lo - 0xDC00)

        Err _ ->
            crash "decodeCharLiteral: invalid low surrogate in pair"



-- ====== SHAPE HELPERS ======


{-| Returns a record type's fields by name, or no fields for any other type.
-}
getRecordFields : Mono.MonoType -> Dict.Dict Name.Name Mono.MonoType
getRecordFields monoType =
    case monoType of
        Mono.MRecord _ fields ->
            fields

        _ ->
            Dict.empty


{-| Returns a tuple type's element types, or none for any other type.
-}
getTupleElements : Mono.MonoType -> List Mono.MonoType
getTupleElements monoType =
    case monoType of
        Mono.MTuple _ elements ->
            elements

        _ ->
            []


{-| Returns an array indexed by the integers of `pairs`, holding each value at
its index and `Nothing` at the indices no pair names. A negative index is
ignored.
-}
pairsToSparseArray : List ( Int, a ) -> Array (Maybe a)
pairsToSparseArray pairs =
    let
        maxIdx =
            List.foldl (\( i, _ ) acc -> max i acc) -1 pairs
    in
    List.foldl (\( i, v ) arr -> Array.set i (Just v) arr) (Array.repeat (maxIdx + 1) Nothing) pairs
