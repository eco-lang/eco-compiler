module TestLogic.Generate.CodeGen.SsaTypeConsistency exposing (expectSsaTypeConsistency)

{-| Checks that generated MLIR never gives one SSA name two different types
within a function.

An SSA value is a named value that is defined once and then read by name; in
MLIR each one has a single type. A value is defined either as a block argument
or as the result of an operation. A `func.func` is a scope of its own for SSA
names, so two functions may use the same names, and the check is made one
function at a time.

`expectSsaTypeConsistency` compiles a source module to MLIR and walks each
top-level `func.func` of the in-memory module; the MLIR text is not read.
Every block argument and operation result inside it, at any depth of nesting,
is recorded under its name. Two definitions of the same name with the same type
pass; two with different types are a violation when the first is still in
scope at the second. Scopes follow MLIR's: all blocks of a region share one
scope, a nested region sees the names of the regions around it, and the names
defined inside a region go out of scope at its end. So two sibling regions,
such as two `eco.case` alternatives, may each define a name at a type of their
own, as MLIR allows.

Among what is not checked:

  - The types at which values are read. Only definitions are compared, so an
    operand is never looked up.
  - Whether a name is defined more than once. A repeated definition with the
    same type passes.
  - Any conflict after the first in a function. Each function gives at most one
    violation.

@docs expectSsaTypeConsistency

-}

import Compiler.AST.Source as Src
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , getStringAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR with
`TestLogic.TestPipeline.runToMlir` and passes when no SSA name has two types
within one `func.func`.

It fails if compilation fails. When there are violations, the failure shows
the first, as `TestLogic.Generate.CodeGen.Invariants.violationsToExpectation`
describes.

-}
expectSsaTypeConsistency : Src.Module -> Expectation
expectSsaTypeConsistency srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkSsaTypeConsistency mlirModule)


{-| The state of a walk over one function: either the type recorded so far for
each SSA name, or the first conflict found, after which the walk records
nothing more.
-}
type alias TypeEnvResult =
    Result Violation (Dict String MlirType)


{-| Returns one violation for each top-level `func.func` of `mlirModule` in
which some SSA name is defined with two different types.
-}
checkSsaTypeConsistency : MlirModule -> List Violation
checkSsaTypeConsistency mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.filterMap checkFunction funcOps


{-| Returns the first type conflict in `funcOp`, or `Nothing` if it has none.
The function is named in the message by its `sym_name` attribute, or as
`<unknown>` when that is missing.
-}
checkFunction : MlirOp -> Maybe Violation
checkFunction funcOp =
    let
        funcName =
            getStringAttr "sym_name" funcOp
                |> Maybe.withDefault "<unknown>"

        result =
            buildTypeEnvWithConflictCheck funcName funcOp
    in
    case result of
        Ok _ ->
            Nothing

        Err violation ->
            Just violation


{-| Walks the regions of `op` from an empty scope and returns the first name
defined with a type other than that of a definition in scope, or `Ok` with the
last scope walked. `op`'s own results are not included. `funcName` is used
only in the violation's message.
-}
buildTypeEnvWithConflictCheck : String -> MlirOp -> TypeEnvResult
buildTypeEnvWithConflictCheck funcName op =
    walkRegions funcName op.regions (Ok Dict.empty)


{-| Walks each region in `regions` from the scope in `result`, discarding what
each defines, so siblings do not see each other's names. Returns `result`
unchanged unless a region has a conflict.
-}
walkRegions : String -> List MlirRegion -> TypeEnvResult -> TypeEnvResult
walkRegions funcName regions result =
    List.foldl
        (\region acc ->
            case acc of
                Err v ->
                    Err v

                Ok _ ->
                    case collectFromRegionChecked funcName region acc of
                        Err v ->
                            Err v

                        Ok _ ->
                            acc
        )
        result
        regions


{-| Records that `name` is defined with `newType`.

A name not in scope is added, and one in scope with the same type leaves
`result` unchanged. One in scope with another type gives a violation whose
`opId` is the SSA name, not an operation's id, and whose message shows the
type in scope, then `newType`. An `Err` is passed on unchanged.

-}
recordSsa : String -> String -> MlirType -> TypeEnvResult -> TypeEnvResult
recordSsa funcName name newType result =
    case result of
        Err v ->
            Err v

        Ok env ->
            case Dict.get name env of
                Nothing ->
                    Ok (Dict.insert name newType env)

                Just existingType ->
                    if existingType == newType then
                        Ok env

                    else
                        Err
                            { opId = name
                            , opName = "SSA definition"
                            , message =
                                "SSA value '"
                                    ++ name
                                    ++ "' in function '"
                                    ++ funcName
                                    ++ "' has conflicting types: "
                                    ++ typeToString existingType
                                    ++ " vs "
                                    ++ typeToString newType
                            }


{-| Records every SSA name defined in a region, starting from the scope in
`result`: each block's arguments, operations and terminator, entry block
first. All blocks share the region's scope.
-}
collectFromRegionChecked : String -> MlirRegion -> TypeEnvResult -> TypeEnvResult
collectFromRegionChecked funcName (MlirRegion { entry, blocks }) result =
    List.foldl (collectFromBlockChecked funcName) result (entry :: OrderedDict.values blocks)


{-| Records every SSA name defined in `block`: its arguments, then the names
defined by its operations and its terminator.
-}
collectFromBlockChecked : String -> MlirBlock -> TypeEnvResult -> TypeEnvResult
collectFromBlockChecked funcName block result =
    let
        withArgs =
            List.foldl
                (\( name, t ) acc -> recordSsa funcName name t acc)
                result
                block.args

        withBody =
            List.foldl (collectFromOpChecked funcName) withArgs block.body
    in
    collectFromOpChecked funcName block.terminator withBody


{-| Checks the names defined in the regions of `op`, each region in its own
scope, then records the results of `op`. A nested `func.func` is isolated from
above, so its regions start from an empty scope.
-}
collectFromOpChecked : String -> MlirOp -> TypeEnvResult -> TypeEnvResult
collectFromOpChecked funcName op result =
    let
        afterRegions =
            if op.name == "func.func" then
                case walkRegions funcName op.regions (Ok Dict.empty) of
                    Err v ->
                        Err v

                    Ok _ ->
                        result

            else
                walkRegions funcName op.regions result
    in
    List.foldl
        (\( name, t ) acc -> recordSsa funcName name t acc)
        afterRegions
        op.results


{-| Returns `t` in MLIR's textual style for a violation message, with a
function type's inputs and results spelled out.
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

        FunctionType { inputs, results } ->
            "("
                ++ String.join ", " (List.map typeToString inputs)
                ++ ") -> ("
                ++ String.join ", " (List.map typeToString results)
                ++ ")"
