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
pass; two with different types are a violation. The scope is the whole
function, so a name defined in two sibling regions of it must also have one
type in both. MLIR allows sibling regions to reuse a name with another type,
so this check is stricter than MLIR requires.

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


{-| Returns the type of every SSA name defined in the regions of `op`, or the
first name found with two different types. `op`'s own results are not
included. `funcName` is used only in the violation's message.
-}
buildTypeEnvWithConflictCheck : String -> MlirOp -> TypeEnvResult
buildTypeEnvWithConflictCheck funcName op =
    let
        initial =
            Ok Dict.empty
    in
    List.foldl (collectFromRegionChecked funcName) initial op.regions


{-| Records that `name` is defined with `newType`.

A name not yet seen is added, and one already seen with the same type leaves
`result` unchanged. One already seen with another type gives a violation whose
`opId` is the SSA name, not an operation's id, and whose message shows the
type recorded first, then `newType`. An `Err` is passed on unchanged.

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


{-| Records every SSA name defined in a region: the entry block's arguments,
operations and terminator, then each further block in order.
-}
collectFromRegionChecked : String -> MlirRegion -> TypeEnvResult -> TypeEnvResult
collectFromRegionChecked funcName (MlirRegion { entry, blocks }) result =
    let
        withEntryArgs =
            List.foldl
                (\( name, t ) acc -> recordSsa funcName name t acc)
                result
                entry.args

        withEntryBody =
            List.foldl (collectFromOpChecked funcName) withEntryArgs entry.body

        withEntryTerm =
            collectFromOpChecked funcName entry.terminator withEntryBody
    in
    List.foldl (collectFromBlockChecked funcName) withEntryTerm (OrderedDict.values blocks)


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


{-| Records the results of `op`, then every SSA name defined in its regions.
-}
collectFromOpChecked : String -> MlirOp -> TypeEnvResult -> TypeEnvResult
collectFromOpChecked funcName op result =
    let
        withResults =
            List.foldl
                (\( name, t ) acc -> recordSsa funcName name t acc)
                result
                op.results
    in
    List.foldl (collectFromRegionChecked funcName) withResults op.regions


{-| Returns a short name for `t` for a violation message. Every function type
is shown as `function`, without its inputs or results.
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
