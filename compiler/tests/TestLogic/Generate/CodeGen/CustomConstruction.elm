module TestLogic.Generate.CodeGen.CustomConstruction exposing (expectCustomConstruction)

{-| An `eco.construct.custom` op builds a value of a custom type. Its `tag`
attribute identifies the constructor and its `size` attribute is the number of
fields. This module checks those attributes on the MLIR generated for a test
program, and checks that list values (a cell or the empty list) are not built
this way, since lists have their own ops (`eco.construct.list` for a cell,
`eco.constant` for the empty list).

Each `eco.construct.custom` op is reported as a violation, in the sense of
`TestLogic.Generate.CodeGen.Invariants`, for each of these that holds:

  - it has no integer `tag` attribute;
  - it has no integer `size` attribute;
  - its `size` differs from its number of operands;
  - its `constructor` attribute is `Cons` or `Nil`.

Only the presence of `tag` is checked, not its value. The operand count
includes any GC-root hint operands appended after the fields. The list check
goes by the constructor's name alone, so a constructor named `Cons` or `Nil` in
a program's own type is reported too, and an op with no `constructor`
attribute is never reported by it. Other built-in types, such as `Maybe`, are
not checked for.

@docs expectCustomConstruction

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


{-| Returns an expectation that compiles `srcModule` to MLIR with
`TestLogic.TestPipeline.runToMlir` and passes when no `eco.construct.custom` op
in the result breaks one of the four rules listed in the module docstring.

It fails with the pipeline's error if compilation fails, and otherwise with the
first violation found.

-}
expectCustomConstruction : Src.Module -> Expectation
expectCustomConstruction srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCustomConstruction mlirModule)


{-| Returns every violation found on the `eco.construct.custom` ops of the
module, at any depth.
-}
checkCustomConstruction : MlirModule -> List Violation
checkCustomConstruction mlirModule =
    let
        customOps =
            findOpsNamed "eco.construct.custom" mlirModule
    in
    List.concatMap checkCustomOp customOps


{-| Returns the violations of one `eco.construct.custom` op: at most three, in
the order missing `tag`, missing or mismatched `size`, list constructor.
-}
checkCustomOp : MlirOp -> List Violation
checkCustomOp op =
    let
        maybeTag =
            getIntAttr "tag" op

        maybeSize =
            getIntAttr "size" op

        operandCount =
            List.length op.operands

        maybeConstructorName =
            getStringAttr "constructor" op
    in
    List.filterMap identity
        [ -- One entry per attribute checked; Nothing means it passed.
          case maybeTag of
            Nothing ->
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.construct.custom missing tag attribute"
                    }

            _ ->
                Nothing
        , case maybeSize of
            Nothing ->
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.construct.custom missing size attribute"
                    }

            Just size ->
                if size /= operandCount then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message =
                            "eco.construct.custom size="
                                ++ String.fromInt size
                                ++ " but operand count="
                                ++ String.fromInt operandCount
                        }

                else
                    Nothing
        , case maybeConstructorName of
            Just name ->
                if List.member name [ "Cons", "Nil" ] then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message = "List constructor '" ++ name ++ "' should use eco.construct.list or eco.constant, not eco.construct.custom"
                        }

                else
                    Nothing

            Nothing ->
                Nothing
        ]
