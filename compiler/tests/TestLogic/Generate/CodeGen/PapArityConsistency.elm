module TestLogic.Generate.CodeGen.PapArityConsistency exposing (expectPapArityConsistency)

{-| An `eco.papCreate` op builds a partial application: a value holding a
function and the arguments supplied to it so far. The op's `arity` attribute
records how many arguments that function takes in all. This module checks that
number against the function's own definition in the same MLIR module, so that
a code generator miscounting a partial application's arguments fails a test.

The function an op names depends on whether the closure it builds has captured
values. Without captures, the op's `function` attribute names the function
itself. With captures, the closure is emitted as two functions, and the op's
`arity` counts the captures as well as the parameters. The _fast clone_, named
with a `$cap` suffix, takes each capture and then each parameter as separate
arguments, and the op names it in its `_fast_evaluator` attribute. The _generic
clone_, named with a `$clo` suffix, takes a pointer to the closure and then the
parameters, and the op names it in `function`. The generic clone therefore
takes fewer arguments than `arity` by design, so the check is made against the
fast clone whenever `_fast_evaluator` is present.

The program is compiled to MLIR with `TestLogic.TestPipeline.runToMlir`, and
the caller supplies the program. A function's parameter count is the number of
arguments of the entry block of its first region, read from the top-level
`func.func` whose `sym_name` matches the name the op gives. A kernel the
module declares is declared as such a `func.func`, with one block argument per
parameter, so a partial application of a declared kernel is checked too.

Among what is not checked:

  - An op with no `arity` or no `function` attribute passes here;
    `TestLogic.Generate.CodeGen.PapCreateArity` reports those.
  - An op that names a function with no top-level `func.func` of that name
    passes.
  - When `_fast_evaluator` is present, the generic clone named in `function` is
    not checked at all.
  - A `func.func` with no region counts as taking no parameters.
  - When several ops fail, only the first is reported.

@docs expectPapArityConsistency

-}

import Compiler.AST.Source as Src
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirRegion(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , findOpsNamed
        , getIntAttr
        , getStringAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Compiles `srcModule` to MLIR with `TestLogic.TestPipeline.runToMlir` and
returns an expectation that fails if the pipeline returns an error, or if an
`eco.papCreate` anywhere in the module has an `arity` other than the parameter
count of the function it targets.

The target is the function named by the op's `_fast_evaluator` attribute when
it has one, and otherwise the function named by its `function` attribute. A
function's parameter count is the number of entry-block arguments of the
top-level `func.func` of that name. An op lacking `arity` or `function`, or
whose target has no top-level `func.func`, passes. When several ops fail, the
failure message names only the first.

-}
expectPapArityConsistency : Src.Module -> Expectation
expectPapArityConsistency srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkPapArityConsistency mlirModule)


{-| Returns one violation for each `eco.papCreate` in `mlirModule`, at any
depth, whose `arity` differs from the parameter count of its target function,
in the order `findOpsNamed` lists the ops.
-}
checkPapArityConsistency : MlirModule -> List Violation
checkPapArityConsistency mlirModule =
    let
        funcParamCountMap =
            buildFuncParamCountMap mlirModule

        papCreateOps =
            findOpsNamed "eco.papCreate" mlirModule
    in
    List.filterMap (checkPapCreateOp funcParamCountMap) papCreateOps


{-| Returns a dictionary from the `sym_name` of each top-level `func.func` in
`mlirModule` to its parameter count, the number of arguments of the entry
block of its first region.

A `func.func` with no region counts as taking no parameters, and one without a
string `sym_name` is left out. When two share a name, the later one in the
module wins.

-}
buildFuncParamCountMap : MlirModule -> Dict String Int
buildFuncParamCountMap mlirModule =
    let
        funcOps =
            findFuncOps mlirModule

        extractFuncInfo : MlirOp -> Maybe ( String, Int )
        extractFuncInfo op =
            case getStringAttr "sym_name" op of
                Nothing ->
                    Nothing

                Just symName ->
                    let
                        paramCount =
                            case List.head op.regions of
                                Just (MlirRegion { entry }) ->
                                    List.length entry.args

                                Nothing ->
                                    0
                    in
                    Just ( symName, paramCount )
    in
    funcOps
        |> List.filterMap extractFuncInfo
        |> Dict.fromList


{-| Returns a violation if `op`'s `arity` differs from the parameter count, in
`funcParamCountMap`, of the function it targets, and `Nothing` otherwise.

The target is the function named by `_fast_evaluator` when `op` has that
attribute, and otherwise the one named by `function`. `Nothing` is also
returned when `op` lacks `arity` or `function`, or when the target is not in
`funcParamCountMap`.

-}
checkPapCreateOp : Dict String Int -> MlirOp -> Maybe Violation
checkPapCreateOp funcParamCountMap op =
    let
        maybeArity =
            getIntAttr "arity" op

        maybeFuncName =
            getStringAttr "function" op

        maybeFastEval =
            getStringAttr "_fast_evaluator" op
    in
    case ( maybeArity, maybeFuncName ) of
        ( Nothing, _ ) ->
            -- Reported by TestLogic.Generate.CodeGen.PapCreateArity.
            Nothing

        ( _, Nothing ) ->
            -- Reported by TestLogic.Generate.CodeGen.PapCreateArity.
            Nothing

        ( Just arity, Just funcName ) ->
            -- When the closure has captures, `function` names the $clo clone,
            -- which takes a closure pointer in place of the captures, so
            -- `_fast_evaluator` is compared with instead.
            let
                targetFuncName =
                    case maybeFastEval of
                        Just fastEvalName ->
                            fastEvalName

                        Nothing ->
                            funcName
            in
            case Dict.get targetFuncName funcParamCountMap of
                Nothing ->
                    -- No top-level func.func has this name, so there is
                    -- nothing to compare with.
                    Nothing

                Just paramCount ->
                    if arity /= paramCount then
                        Just
                            { opId = op.id
                            , opName = op.name
                            , message =
                                "eco.papCreate arity="
                                    ++ String.fromInt arity
                                    ++ " but function "
                                    ++ targetFuncName
                                    ++ " has "
                                    ++ String.fromInt paramCount
                                    ++ " parameters"
                            }

                    else
                        Nothing
