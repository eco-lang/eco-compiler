module TestLogic.Generate.CodeGen.CEcoValueLowering exposing (expectCEcoValueLowering)

{-| A type variable that monomorphization leaves with the `CEcoValue`
constraint stands for a value that is always boxed, and code generation must
give it the MLIR type `!eco.value` (CGEN\_013, REP\_ABI\_001; see `Constraint` in
`Compiler.AST.Monomorphized`), so that its concrete source type never affects a
calling convention.

The expectation compiles a program with `TestLogic.TestPipeline.runToMlir` and
reads both the monomorphized graph MLIR was generated from and the MLIR. For
each function node of the graph (a `MonoTailFunc`, or a `MonoDefine` whose
expression is a closure) it finds the top-level `func.func` generated for it,
the one whose `sym_name` ends in `_$_<SpecId>`, and checks its
`function_type`:

  - when the function has as many inputs as the node has parameters, every
    input whose parameter's `MonoType` is `MVar _ CEcoValue` must be
    `!eco.value`;
  - when the node's return type (the type after its parameters) is
    `MVar _ CEcoValue`, the function's single result must be `!eco.value`.

A non-function `MonoDefine` whose type is `MVar _ CEcoValue` is checked the
same way: its function's single result must be `!eco.value`.

Not checked: a node with no generated function of that name (inlined,
pruned or emitted under another name, such as an ABI clone), a function whose
input count differs from its node's parameter count (a different ABI shape,
which other checkers cover), `CEcoValue` variables nested inside other types,
and SSA values inside function bodies.

@docs expectCEcoValueLowering

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findSymbolOps
        , getTypeAttr
        , isEcoValueType
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR with
`TestLogic.TestPipeline.runToMlir` and passes when every function signature
the module docstring describes lowers its `CEcoValue` positions to
`!eco.value`. Fails with `Compilation failed:` and the pipeline's message when
compilation fails, and with the violations otherwise.
-}
expectCEcoValueLowering : Src.Module -> Expectation
expectCEcoValueLowering srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule, monoGraph } ->
            violationsToExpectation (checkCEcoValueLowering monoGraph mlirModule)


{-| Returns the violations over every node of `monoGraph` that has a generated
function in `mlirModule`.
-}
checkCEcoValueLowering : Mono.MonoGraph -> MlirModule -> List Violation
checkCEcoValueLowering (Mono.MonoGraph data) mlirModule =
    let
        funcsBySpec =
            findSymbolOps mlirModule
                |> List.filter (\( _, op ) -> op.name == "func.func")
                |> List.filterMap
                    (\( name, op ) ->
                        case String.split "_$_" name |> List.reverse of
                            last :: _ :: _ ->
                                String.toInt last |> Maybe.map (\specId -> ( specId, op ))

                            _ ->
                                Nothing
                    )
                |> Dict.fromList
    in
    Array.toIndexedList data.nodes
        |> List.concatMap
            (\( specId, maybeNode ) ->
                case ( maybeNode, Dict.get specId funcsBySpec ) of
                    ( Just node, Just funcOp ) ->
                        checkNode node funcOp

                    _ ->
                        []
            )


{-| Returns the violations of one node against the `func.func` generated for
it.
-}
checkNode : Mono.MonoNode -> MlirOp -> List Violation
checkNode node funcOp =
    case node of
        Mono.MonoTailFunc params _ monoType ->
            checkSignature (List.map Tuple.second params) (returnTypeAfter (List.length params) monoType) funcOp

        Mono.MonoDefine (Mono.MonoClosure info _ _) monoType ->
            checkSignature (List.map Tuple.second info.params) (returnTypeAfter (List.length info.params) monoType) funcOp

        Mono.MonoDefine _ monoType ->
            checkSignature [] monoType funcOp

        _ ->
            []


{-| The type a function of type `monoType` returns once applied to `n`
arguments, its curried and flat parameter lists both counting. When `n` ends
inside a parameter list, the result is a function, and this returns the
function type `monoType` itself, which is enough for telling whether the result
is a `CEcoValue` variable.
-}
returnTypeAfter : Int -> Mono.MonoType -> Mono.MonoType
returnTypeAfter n monoType =
    if n <= 0 then
        monoType

    else
        case monoType of
            Mono.MFunction _ _ paramTypes result ->
                if List.length paramTypes <= n then
                    returnTypeAfter (n - List.length paramTypes) result

                else
                    monoType

            _ ->
                monoType


{-| Returns a violation for each `CEcoValue` parameter or return position whose
`func.func` type is not `!eco.value`.
-}
checkSignature : List Mono.MonoType -> Mono.MonoType -> MlirOp -> List Violation
checkSignature paramTypes returnType funcOp =
    case getTypeAttr "function_type" funcOp of
        Just (FunctionType { inputs, results }) ->
            let
                violation message =
                    { opId = funcOp.id, opName = funcOp.name, message = message }

                paramViolations =
                    if List.length inputs == List.length paramTypes then
                        List.map2 Tuple.pair paramTypes inputs
                            |> List.indexedMap
                                (\i ( monoType, mlirType ) ->
                                    if isCEcoValue monoType && not (isEcoValueType mlirType) then
                                        [ violation ("parameter " ++ String.fromInt i ++ " is a CEcoValue type variable but is not lowered to !eco.value") ]

                                    else
                                        []
                                )
                            |> List.concat

                    else
                        []

                resultViolations =
                    case ( isCEcoValue returnType, results ) of
                        ( True, [ resultType ] ) ->
                            if isEcoValueType resultType then
                                []

                            else
                                [ violation "result is a CEcoValue type variable but is not lowered to !eco.value" ]

                        ( True, _ ) ->
                            [ violation "result is a CEcoValue type variable but the function does not have exactly one result" ]

                        _ ->
                            []
            in
            paramViolations ++ resultViolations

        _ ->
            []


{-| True for `MVar _ CEcoValue`.
-}
isCEcoValue : Mono.MonoType -> Bool
isCEcoValue monoType =
    case monoType of
        Mono.MVar _ Mono.CEcoValue ->
            True

        _ ->
            False
