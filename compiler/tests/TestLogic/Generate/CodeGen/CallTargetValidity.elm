module TestLogic.Generate.CodeGen.CallTargetValidity exposing (expectCallTargetValidity)

{-| A call in the generated MLIR that names a function the module does not
define, or that reaches a trivial stub while another function with the same
base name (both defined below) has a fuller body, is a code generation error.
This module checks the MLIR generated for one test program for both.

The program is compiled to MLIR with `TestLogic.TestPipeline.runToMlir`. Every
`eco.call` op, at any depth, is then looked up by its `callee` among the
`func.func` ops at the top level of the module, keyed by their `sym_name`. A
call is a violation when its callee names no top-level `func.func`, which
includes a name that belongs to some other kind of op, or when its callee is a
trivial stub and another function with the same base name is not.

A _trivial stub_ is a `func.func` whose first region's entry block has at
most two body ops, all of them `arith.constant` or `eco.constant`, and an
`eco.return` terminator. An empty entry block body qualifies, so a function
whose entry block does nothing but return one of its arguments is a trivial
stub too. A `func.func` with no region is not one.

The _base name_ of a symbol is the part before its last `_$_`, or the whole
symbol when it has none. `Compiler.Generate.MLIR.Functions` names a
specialized function with its module-qualified name, then `_$_`, then a
specialization id, so functions that share a base name are usually
specializations of one source function, possibly at different types, or
`$cap`/`$clo` clones of one.

An `eco.call` with no `callee` attribute is not checked. A failing expectation
shows only the first violation, as
`TestLogic.Generate.CodeGen.Invariants.violationsToExpectation` describes.

@docs expectCallTargetValidity

-}

import Compiler.AST.Source as Src
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirRegion(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , findSymbolOps
        , getStringAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Compiles `srcModule` to MLIR and returns an expectation that passes when
no `eco.call` in the result is a violation, as the module docstring defines
one: a callee that is not a top-level `func.func`, or a trivial stub whose
base name is shared by a function that is not a stub.

When compilation fails, the expectation fails with a message that starts
`Compilation failed:` and continues with the pipeline's message.

-}
expectCallTargetValidity : Src.Module -> Expectation
expectCallTargetValidity srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCallTargetValidity mlirModule)


{-| Returns one violation for each `eco.call` in `mlirModule` whose callee is
undefined, or is a trivial stub while another function with its base name is
not, in the order the calls are found.
-}
checkCallTargetValidity : MlirModule -> List Violation
checkCallTargetValidity mlirModule =
    let
        funcDefs =
            buildFuncDefMap mlirModule

        callOps =
            findOpsNamed "eco.call" mlirModule
    in
    List.filterMap (checkCallOp funcDefs) callOps


{-| Returns the module's top-level `func.func` ops keyed by their `sym_name`.
Of two with the same name, the later one is kept.
-}
buildFuncDefMap : MlirModule -> Dict String MlirOp
buildFuncDefMap mlirModule =
    let
        symbolOps =
            findSymbolOps mlirModule
    in
    List.foldl
        (\( name, op ) acc ->
            if op.name == "func.func" then
                Dict.insert name op acc

            else
                acc
        )
        Dict.empty
        symbolOps


{-| Returns the violation for the `eco.call` `op`, if it has one, given the
function definitions `funcDefs`.

A leading `@` is dropped from the callee before it is looked up. An op with no
`callee` attribute gives `Nothing`.

-}
checkCallOp : Dict String MlirOp -> MlirOp -> Maybe Violation
checkCallOp funcDefs op =
    case getStringAttr "callee" op of
        Nothing ->
            Nothing

        Just callee ->
            let
                calleeName =
                    if String.startsWith "@" callee then
                        String.dropLeft 1 callee

                    else
                        callee
            in
            case Dict.get calleeName funcDefs of
                Nothing ->
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message = "eco.call references undefined function '" ++ calleeName ++ "'"
                        }

                Just targetFunc ->
                    if isTrivialStub targetFunc then
                        case findNonStubVersion calleeName funcDefs of
                            Nothing ->
                                Nothing

                            Just nonStubName ->
                                Just
                                    { opId = op.id
                                    , opName = op.name
                                    , message =
                                        "eco.call targets stub '"
                                            ++ calleeName
                                            ++ "' but non-stub '"
                                            ++ nonStubName
                                            ++ "' exists"
                                    }

                    else
                        Nothing


{-| Returns `True` when `funcOp` is a trivial stub: the entry block of its first
region has at most two body ops, all `arith.constant` or `eco.constant`, and an
`eco.return` terminator. An empty entry block body counts. An op with no region
is not a stub.
-}
isTrivialStub : MlirOp -> Bool
isTrivialStub funcOp =
    case funcOp.regions of
        [] ->
            False

        (MlirRegion { entry }) :: _ ->
            let
                bodyOps =
                    entry.body

                allConstants =
                    List.all isConstantOp bodyOps

                smallBody =
                    List.length bodyOps <= 2
            in
            smallBody && allConstants && isReturnTerminator entry.terminator


{-| Returns `True` when `op` is an `arith.constant` or an `eco.constant`.
-}
isConstantOp : MlirOp -> Bool
isConstantOp op =
    List.member op.name [ "arith.constant", "eco.constant" ]


{-| Returns `True` when `op` is an `eco.return`.
-}
isReturnTerminator : MlirOp -> Bool
isReturnTerminator op =
    op.name == "eco.return"


{-| Returns the name of a function in `funcDefs`, other than `stubName`, that
has the same base name as `stubName` and is not a trivial stub. Of several, the
first in name order is returned.
-}
findNonStubVersion : String -> Dict String MlirOp -> Maybe String
findNonStubVersion stubName funcDefs =
    let
        baseName =
            extractBaseName stubName
    in
    Dict.toList funcDefs
        |> List.filterMap
            (\( funcName, funcOp ) ->
                if funcName /= stubName && extractBaseName funcName == baseName then
                    if not (isTrivialStub funcOp) then
                        Just funcName

                    else
                        Nothing

                else
                    Nothing
            )
        |> List.head


{-| Returns `name` up to but not including its last `_$_`, or the whole of
`name` when it contains none.
-}
extractBaseName : String -> String
extractBaseName name =
    case String.indices "_$_" name of
        [] ->
            name

        indices ->
            case List.maximum indices of
                Nothing ->
                    name

                Just lastIdx ->
                    String.left lastIdx name
