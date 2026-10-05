module TestLogic.Generate.CodeGen.CallTargetValidity exposing (expectCallTargetValidity)

{-| A call in the generated MLIR that names a function the module does not
define, or that reaches an extern placeholder while a real definition of the
same function exists, is a code generation error (CGEN\_044). This module checks
the MLIR generated for one test program for both.

The program is compiled to MLIR with `TestLogic.TestPipeline.runToMlir`. Every
`eco.call` op, at any depth, is then looked up by its `callee` among the
`func.func` ops at the top level of the module, keyed by their `sym_name`. A
call is a violation when its callee names no top-level `func.func`, which
includes a name that belongs to some other kind of op, or when its callee is an
extern placeholder and another function with the same base name is a real
definition.

An _extern placeholder_ is the `func.func` that
`Compiler.Generate.MLIR.Functions.generateExtern` emits for a `MonoExtern` node
of the monomorphized graph: a body that only returns a default value, standing
in for an implementation the linker provides. It is recognised through the
graph, not by the shape of its body, so a real function whose body happens to
fold to a constant is not mistaken for one. A function is matched to its node
by the `_$_<SpecId>` suffix of its symbol; one that is not, such as a kernel
declaration, is never a placeholder.

The _base name_ of a symbol is the part before its last `_$_`, or the whole
symbol when it has none. `Compiler.Generate.MLIR.Functions` names a
specialized function with its module-qualified name, then `_$_`, then a
specialization id, so functions that share a base name are specializations of
one source function.

An `eco.call` with no `callee` attribute is not checked.

@docs expectCallTargetValidity

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import Set exposing (Set)
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
one: a callee that is not a top-level `func.func`, or an extern placeholder
whose base name is shared by a real definition.

When compilation fails, the expectation fails with a message that starts
`Compilation failed:` and continues with the pipeline's message.

-}
expectCallTargetValidity : Src.Module -> Expectation
expectCallTargetValidity srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule, monoGraph } ->
            violationsToExpectation (checkCallTargetValidity (externSpecIds monoGraph) mlirModule)


{-| The SpecIds of the `MonoExtern` nodes of `monoGraph`.
-}
externSpecIds : Mono.MonoGraph -> Set Int
externSpecIds (Mono.MonoGraph data) =
    Array.toIndexedList data.nodes
        |> List.filterMap
            (\( specId, maybeNode ) ->
                case maybeNode of
                    Just (Mono.MonoExtern _) ->
                        Just specId

                    _ ->
                        Nothing
            )
        |> Set.fromList


{-| Returns one violation for each `eco.call` in `mlirModule` whose callee is
undefined, or is an extern placeholder (its SpecId is in `externs`) while a
function with its base name is a real definition, in the order the calls are
found.
-}
checkCallTargetValidity : Set Int -> MlirModule -> List Violation
checkCallTargetValidity externs mlirModule =
    let
        funcDefs =
            buildFuncDefMap mlirModule

        callOps =
            findOpsNamed "eco.call" mlirModule
    in
    List.filterMap (checkCallOp externs funcDefs) callOps


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
checkCallOp : Set Int -> Dict String MlirOp -> MlirOp -> Maybe Violation
checkCallOp externs funcDefs op =
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

                Just _ ->
                    if isExternPlaceholder externs calleeName then
                        case findRealDefinition externs calleeName funcDefs of
                            Nothing ->
                                Nothing

                            Just realName ->
                                Just
                                    { opId = op.id
                                    , opName = op.name
                                    , message =
                                        "eco.call targets extern placeholder '"
                                            ++ calleeName
                                            ++ "' but real definition '"
                                            ++ realName
                                            ++ "' exists"
                                    }

                    else
                        Nothing


{-| Returns `True` when the symbol `name` ends in `_$_<SpecId>` for a SpecId in
`externs`.
-}
isExternPlaceholder : Set Int -> String -> Bool
isExternPlaceholder externs name =
    case specIdOf name of
        Just specId ->
            Set.member specId externs

        Nothing ->
            False


{-| The SpecId after the last `_$_` of `name`, if it is a number.
-}
specIdOf : String -> Maybe Int
specIdOf name =
    case List.reverse (String.split "_$_" name) of
        last :: _ :: _ ->
            String.toInt last

        _ ->
            Nothing


{-| Returns the name of a function in `funcDefs`, other than `stubName`, that
has the same base name as `stubName` and is not an extern placeholder. Of
several, the first in name order is returned.
-}
findRealDefinition : Set Int -> String -> Dict String MlirOp -> Maybe String
findRealDefinition externs stubName funcDefs =
    let
        baseName =
            extractBaseName stubName
    in
    Dict.keys funcDefs
        |> List.filter
            (\funcName ->
                funcName
                    /= stubName
                    && extractBaseName funcName
                    == baseName
                    && not (isExternPlaceholder externs funcName)
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
