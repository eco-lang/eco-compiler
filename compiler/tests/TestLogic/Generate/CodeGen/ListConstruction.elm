module TestLogic.Generate.CodeGen.ListConstruction exposing (expectListConstruction)

{-| The eco MLIR dialect has its own operations for lists: `eco.construct.list`
builds a cons cell, and the empty list is an `eco.constant`. This module checks
that no list constructor is built instead with `eco.construct.custom`, the
generic operation for a value of a custom type.

It compiles a source module to MLIR and looks at every `eco.construct.custom`
op in it. The op's `constructor` attribute, a string, names the constructor it
builds, and the op is a violation when that name is `::` or `[]`, the names of
elm/core's list constructors. The attribute holds the bare constructor name
with no module, so names a program could declare itself, such as `Cons` or
`Nil`, are not treated as list constructors: no Elm program can declare a
constructor named `::` or `[]`.

Among what is not checked:

  - that cons cells are built with `eco.construct.list`, or that the empty
    list is an `eco.constant`;
  - an `eco.construct.custom` op with no `constructor` attribute.

@docs expectListConstruction

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getStringAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that `srcModule` compiles to MLIR with no
`eco.construct.custom` op whose `constructor` attribute is `::` or `[]`.

The module is compiled with `TestLogic.TestPipeline.runToMlir`. If compilation
fails, the expectation fails with the pipeline's message. If there are
violations, it fails with the message of the first one only, as
`violationsToExpectation` describes.

-}
expectListConstruction : Src.Module -> Expectation
expectListConstruction srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkListConstruction mlirModule)


{-| Returns one violation for each `eco.construct.custom` op in `mlirModule`, at
any depth, whose `constructor` attribute is one of the names
`isListConstructorName` accepts, in the order `findOpsNamed` returns them.
-}
checkListConstruction : MlirModule -> List Violation
checkListConstruction mlirModule =
    let
        customOps =
            findOpsNamed "eco.construct.custom" mlirModule
    in
    List.filterMap checkForListConstructorMisuse customOps


{-| Returns a violation for `op` when its `constructor` string attribute is a
list constructor's name, and `Nothing` when it is another name or absent.
-}
checkForListConstructorMisuse : MlirOp -> Maybe Violation
checkForListConstructorMisuse op =
    let
        constructorName =
            getStringAttr "constructor" op
    in
    case constructorName of
        Just name ->
            if isListConstructorName name then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.construct.custom used for list constructor '" ++ name ++ "', should use eco.construct.list or eco.constant Nil"
                    }

            else
                Nothing

        Nothing ->
            Nothing


{-| Returns whether `name` is the name of one of elm/core's list constructors,
`::` or `[]`.
-}
isListConstructorName : String -> Bool
isListConstructorName name =
    List.member name [ "::", "[]" ]
