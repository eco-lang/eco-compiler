module TestLogic.Generate.CodeGen.SingletonConstants exposing (expectSingletonConstants)

{-| The code generator gives a few well-known values, such as `True`,
`Nothing`, the empty list and the empty string, an embedded constant instead of
constructing them, and this module checks generated MLIR for one of those
values built some other way, and for an `eco.constant` whose kind it does not
accept.

An _embedded constant_ is an `eco.constant` op, which takes no operands and
says which value it is by its integer `kind` attribute alone. Which values get
one, and which kind each gets, is decided by `Compiler.Generate.MLIR.Ops` and
its callers.

`expectSingletonConstants` compiles a source module to MLIR and fails if
compilation fails or if any of these is found among the module's ops, at any
depth:

  - an `eco.constant` with no integer `kind`, or with a kind other than the
    three `Compiler.Generate.MLIR.Ops` emits, which match the runtime's
    constant codes: 0 for False, 1 for True, and 2 for the single empty
    constant that Unit, the empty record, the empty list, `Nothing` and the
    empty string all share;
  - an `eco.construct.custom` whose `size` is 0, that is, a nullary
    constructor built on the heap. Every nullary constructor must be an
    embedded constant (`eco.constant` or `eco.constant.null_cons`, CGEN\_079),
    whatever its name;
  - an `eco.string_literal` whose `value` is the empty string.

Each such op is one violation, and a failure shows only the first, as
`TestLogic.Generate.CodeGen.Invariants.violationsToExpectation` describes.

Among what is not checked: that a constant's kind is the right one for the
value it stands for, the `tag` of an `eco.constant.null_cons`, and ops with
any other name, such as `eco.make.custom`.

@docs expectSingletonConstants

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getIntAttr
        , getStringAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that passes when `srcModule` compiles to MLIR with
none of the violations the module docstring lists, and fails with
`Compilation failed:` and the error when compilation fails.
-}
expectSingletonConstants : Src.Module -> Expectation
expectSingletonConstants srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkSingletonConstants mlirModule)


{-| The `kind` values an `eco.constant` may carry: 0 (False), 1 (True) and 2
(the shared empty constant), as `Compiler.Generate.MLIR.Ops` emits them.
-}
knownSingletonKinds : List Int
knownSingletonKinds =
    [ 0, 1, 2 ]


{-| Returns every violation in `mlirModule`: those of `eco.constant` ops first,
then those of `eco.construct.custom` ops, then those of `eco.string_literal`
ops.
-}
checkSingletonConstants : MlirModule -> List Violation
checkSingletonConstants mlirModule =
    let
        constantOps =
            findOpsNamed "eco.constant" mlirModule

        constantViolations =
            List.filterMap checkConstantKind constantOps

        customOps =
            findOpsNamed "eco.construct.custom" mlirModule

        customViolations =
            List.filterMap checkForSingletonMisuse customOps

        stringOps =
            findOpsNamed "eco.string_literal" mlirModule

        stringViolations =
            List.filterMap checkEmptyStringLiteral stringOps
    in
    constantViolations ++ customViolations ++ stringViolations


{-| Returns a violation for an `eco.constant` whose `kind` is absent, is not an
integer, or is not in `knownSingletonKinds`, and `Nothing` otherwise.
-}
checkConstantKind : MlirOp -> Maybe Violation
checkConstantKind op =
    let
        maybeKind =
            getIntAttr "kind" op
    in
    case maybeKind of
        Nothing ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.constant missing kind attribute"
                }

        Just kind ->
            if not (List.member kind knownSingletonKinds) then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.constant with unknown kind " ++ String.fromInt kind
                    }

            else
                Nothing


{-| Returns a violation for an `eco.construct.custom` whose `size` attribute is
0, and `Nothing` otherwise.
-}
checkForSingletonMisuse : MlirOp -> Maybe Violation
checkForSingletonMisuse op =
    case getIntAttr "size" op of
        Just 0 ->
            Just
                { opId = op.id
                , opName = op.name
                , message =
                    "eco.construct.custom with size 0 for nullary constructor '"
                        ++ (getStringAttr "constructor" op |> Maybe.withDefault "<unnamed>")
                        ++ "', should be an embedded constant (eco.constant / eco.constant.null_cons)"
                }

        _ ->
            Nothing


{-| Returns a violation for an op whose `value` attribute is the empty string,
and `Nothing` otherwise.
-}
checkEmptyStringLiteral : MlirOp -> Maybe Violation
checkEmptyStringLiteral op =
    let
        maybeValue =
            getStringAttr "value" op
    in
    case maybeValue of
        Just "" ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "Empty string should use eco.constant EmptyString, not eco.string_literal"
                }

        _ ->
            Nothing
