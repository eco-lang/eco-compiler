module TestLogic.Generate.CodeGen.PapExtendSaturatedResultType exposing (expectPapExtendSaturatedResultType)

{-| When a closure receives its last arguments, the function it was made from
runs and its result becomes the result of the application. The MLIR type the
code generator gives that application must therefore be the type the function
returns. This module checks, on the MLIR generated for a test program, that the
two types agree.

A closure value is a _PAP_ (partial application): an `eco.papCreate` (or, for a
group of mutually recursive closures, an `eco.papCreateGroup`) makes one from a
target function and the values it captures, and each `eco.papExtend` applies it
to more arguments. A PAP's _remaining arity_ is how many more arguments it needs
before the target runs. An `eco.papExtend` is _saturated_ when it supplies at
least that many, so that its result is the target's result rather than another
PAP. Only _typed_ extends are checked: those carrying a `remaining_arity`
attribute. An extend without one is skipped.

`expectPapExtendSaturatedResultType` compiles a program with
`TestLogic.TestPipeline.runToMlir` and fails if any saturated typed
`eco.papExtend` it can trace to its target has a result type different from
the first result type of its target's `func.func`. The failure message lists
every such extend, then the return type of each top-level `func.func` that has
one, then the generated MLIR text.

The check works within one top-level op at a time, because SSA value names
repeat from one function to the next. It follows each PAP from the
`eco.papCreate` that made it through any typed `eco.papExtend`s that leave it
unsaturated, recording the target and the remaining arity. The target is the
function named by the papCreate's `_fast_evaluator` attribute when it has one,
and by its `function` attribute otherwise. On a papCreate, the code generator
sets `_fast_evaluator` only for a closure with captures, and there it names a
`$cap` clone of the closure's function, a different `func.func` from the `$clo`
clone that `function` names.

Among what is not checked:

  - an extend whose PAP was not made in the same top-level op, such as one
    received as a block argument;
  - an extend of a value produced by a saturated extend, which is not tracked
    even when it is itself a closure;
  - an extend whose target is not a top-level `func.func` with a result type in
    the module;
  - an `eco.papCreate` without integer `arity` and `num_captured` attributes,
    or with neither a `_fast_evaluator` nor a `function` attribute, and the
    extends of its PAP;
  - an extend of a PAP made by `eco.papCreateGroup`, which is not tracked.

@docs expectPapExtendSaturatedResultType

-}

import Compiler.AST.Source as Src
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , getIntAttr
        , getStringAttr
        , getTypeAttr
        , walkOpAndChildren
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| What is known about one PAP: the symbol of its target function, chosen as
the module docstring describes, and `remaining`, how many more arguments it
needs before the target runs.
-}
type alias PapInfo =
    { targetFunc : String
    , remaining : Int
    }


{-| Returns an expectation that compiles `srcModule` to MLIR and passes when
every saturated typed `eco.papExtend` that can be traced to its target has the
target's return type as its result type.

It fails if compilation fails. Otherwise a failure lists the message of every
mismatching extend, then the return type of each top-level `func.func` that
has one, then the generated MLIR text.

-}
expectPapExtendSaturatedResultType : Src.Module -> Expectation
expectPapExtendSaturatedResultType srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule, mlirOutput } ->
            let
                violations =
                    checkPapExtendSaturatedResultType mlirModule
            in
            if List.isEmpty violations then
                Expect.pass

            else
                let
                    funcReturnTypeMap =
                        buildFuncReturnTypeMap mlirModule

                    funcMapStr =
                        Dict.toList funcReturnTypeMap
                            |> List.map (\( name, ty ) -> "  @" ++ name ++ " -> " ++ typeToString ty)
                            |> String.join "\n"

                    violationStrs =
                        List.map (\v -> v.message) violations
                            |> String.join "\n"
                in
                Expect.fail
                    (violationStrs
                        ++ "\n\nfuncReturnTypeMap:\n"
                        ++ funcMapStr
                        ++ "\n\nMLIR:\n"
                        ++ mlirOutput
                    )


{-| Returns a violation for every saturated typed `eco.papExtend` in the module
that can be traced to its target and whose result type differs from the
target's return type, checking each top-level op separately.
-}
checkPapExtendSaturatedResultType : MlirModule -> List Violation
checkPapExtendSaturatedResultType mlirModule =
    let
        funcReturnTypeMap =
            buildFuncReturnTypeMap mlirModule
    in
    List.concatMap (checkFunction funcReturnTypeMap) mlirModule.body


{-| Returns the return type of each top-level `func.func`, keyed by its
`sym_name`: the first result of its `function_type` attribute. A function with
no results, or missing either attribute, or whose `function_type` is not a
function type, is left out.
-}
buildFuncReturnTypeMap : MlirModule -> Dict String MlirType
buildFuncReturnTypeMap mlirModule =
    let
        extractFuncReturnType : MlirOp -> Maybe ( String, MlirType )
        extractFuncReturnType op =
            case ( getStringAttr "sym_name" op, getTypeAttr "function_type" op ) of
                ( Just symName, Just (FunctionType { results }) ) ->
                    case results of
                        returnType :: _ ->
                            Just ( symName, returnType )

                        [] ->
                            Nothing

                _ ->
                    Nothing
    in
    findFuncOps mlirModule
        |> List.filterMap extractFuncReturnType
        |> Dict.fromList


{-| Returns the violations among the `eco.papExtend` ops in `funcOp` and the ops
nested in it, given the return types in `funcReturnTypeMap`.

PAPs are tracked within `funcOp` only, because SSA value names repeat from one
function to the next.

-}
checkFunction : Dict String MlirType -> MlirOp -> List Violation
checkFunction funcReturnTypeMap funcOp =
    let
        allOpsInFunc =
            walkOpAndChildren funcOp

        papInfoMap =
            buildPapInfoMap allOpsInFunc

        papExtendOps =
            List.filter (\op -> op.name == "eco.papExtend") allOpsInFunc
    in
    List.filterMap (checkSaturatedPapExtend funcReturnTypeMap papInfoMap) papExtendOps


{-| Returns what is known about each PAP in `ops` that can be traced to an
`eco.papCreate`, keyed by the SSA name of the value that holds it. The ops are
read in order, so an extend's result is tracked only if the PAP it extends was
recorded from an earlier op in `ops`.
-}
buildPapInfoMap : List MlirOp -> Dict String PapInfo
buildPapInfoMap ops =
    List.foldl processOp Dict.empty ops


{-| Returns `map` with the PAP that `op` defines added, if it defines one.

An `eco.papCreate` that has a result, integer `arity` and `num_captured`
attributes, and a non-empty target adds its result, targeting `_fast_evaluator`
or else `function`, with `arity` minus `num_captured` arguments remaining. A
typed `eco.papExtend` of a tracked PAP adds its result with the same target,
when its `remaining_arity` minus the arguments it supplies is still above zero.
The arguments supplied are the operands after the first, less the trailing
GC-root operands that `eco.gc_roots_count` counts. Any other op leaves `map`
unchanged.

-}
processOp : MlirOp -> Dict String PapInfo -> Dict String PapInfo
processOp op map =
    if op.name == "eco.papCreate" then
        case ( List.head op.results, getIntAttr "arity" op, getIntAttr "num_captured" op ) of
            ( Just ( resultName, _ ), Just arity, Just numCaptured ) ->
                let
                    targetFunc =
                        case getStringAttr "_fast_evaluator" op of
                            Just fastEvalName ->
                                fastEvalName

                            Nothing ->
                                getStringAttr "function" op
                                    |> Maybe.withDefault ""
                in
                if targetFunc == "" then
                    map

                else
                    Dict.insert resultName
                        { targetFunc = targetFunc
                        , remaining = arity - numCaptured
                        }
                        map

            _ ->
                map

    else if op.name == "eco.papExtend" then
        case ( List.head op.results, List.head op.operands, getIntAttr "remaining_arity" op ) of
            ( Just ( resultName, _ ), Just sourcePapName, Just remainingArity ) ->
                case Dict.get sourcePapName map of
                    Just sourceInfo ->
                        let
                            rootCount =
                                Maybe.withDefault 0 (getIntAttr "eco.gc_roots_count" op)

                            numNewArgs =
                                List.length op.operands - 1 - rootCount

                            newRemaining =
                                remainingArity - numNewArgs
                        in
                        if newRemaining > 0 then
                            Dict.insert resultName
                                { targetFunc = sourceInfo.targetFunc
                                , remaining = newRemaining
                                }
                                map

                        else
                            map

                    Nothing ->
                        map

            _ ->
                map

    else
        map


{-| Returns a violation for the `eco.papExtend` `op` if it is typed and
`checkTypedPapExtend` finds one. An extend without `remaining_arity` gives
nothing.
-}
checkSaturatedPapExtend : Dict String MlirType -> Dict String PapInfo -> MlirOp -> Maybe Violation
checkSaturatedPapExtend funcReturnTypeMap papInfoMap op =
    case getIntAttr "remaining_arity" op of
        Nothing ->
            Nothing

        Just _ ->
            checkTypedPapExtend funcReturnTypeMap papInfoMap op


{-| Returns a violation if the extend `op` saturates a tracked PAP and its
first result type differs from the return type of the PAP's target.

The extend saturates when the remaining arity recorded for the PAP in
`papInfoMap`, not the extend's own `remaining_arity`, is no more than the
arguments it supplies: its operands after the first, less the trailing GC-root
operands. An extend of an untracked PAP, one that leaves arguments remaining,
and one whose target is not in `funcReturnTypeMap` give nothing.

-}
checkTypedPapExtend : Dict String MlirType -> Dict String PapInfo -> MlirOp -> Maybe Violation
checkTypedPapExtend funcReturnTypeMap papInfoMap op =
    case List.head op.operands of
        Nothing ->
            Nothing

        Just sourcePapName ->
            case Dict.get sourcePapName papInfoMap of
                Nothing ->
                    Nothing

                Just sourceInfo ->
                    let
                        rootCount =
                            Maybe.withDefault 0 (getIntAttr "eco.gc_roots_count" op)

                        numNewArgs =
                            List.length op.operands - 1 - rootCount

                        resultRemaining =
                            sourceInfo.remaining - numNewArgs
                    in
                    if resultRemaining > 0 then
                        Nothing

                    else
                        case List.head op.results of
                            Nothing ->
                                Nothing

                            Just ( _, papExtendResultType ) ->
                                case Dict.get sourceInfo.targetFunc funcReturnTypeMap of
                                    Nothing ->
                                        Nothing

                                    Just funcReturnType ->
                                        if papExtendResultType == funcReturnType then
                                            Nothing

                                        else
                                            Just
                                                { opId = op.id
                                                , opName = op.name
                                                , message =
                                                    "Saturated eco.papExtend result type "
                                                        ++ typeToString papExtendResultType
                                                        ++ " does not match func.func @"
                                                        ++ sourceInfo.targetFunc
                                                        ++ " return type "
                                                        ++ typeToString funcReturnType
                                                }


{-| Returns a short text form of `t` for failure messages. A function type is
written as `function` whatever its parameters and results.
-}
typeToString : MlirType -> String
typeToString t =
    case t of
        I1 ->
            "i1"

        I8 ->
            "i8"

        I16 ->
            "i16"

        I32 ->
            "i32"

        I64 ->
            "i64"

        F64 ->
            "f64"

        NamedStruct name ->
            "!" ++ name

        FunctionType _ ->
            "function"
