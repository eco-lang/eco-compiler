module TestLogic.Generate.CodeGen.DbgTypeIds exposing (expectDbgTypeIds)

{-| A type ID that points outside the module's type table is an index outside
an array, and nothing in the types of `Mlir.Mlir` prevents the code generator
from emitting one. This module checks the generated MLIR for such IDs on
`eco.dbg` ops.

The _type table_ is the `eco.type_table` op in the module's top-level body. Its
`types` attribute is an array of type descriptors, and a _type ID_ is a
position in that array, counting from 0. An `eco.dbg` op may carry an
`arg_type_ids` attribute, an array of type IDs.

`expectDbgTypeIds` compiles a source module to MLIR with
`TestLogic.TestPipeline.runToMlir`. It fails when the pipeline returns an
error, and when an `eco.dbg` op in the module, at any depth, carries an array
`arg_type_ids` and:

  - `arg_type_ids` is not empty and the module has no type table, or the
    first top-level `eco.type_table` has no array `types` attribute;
  - an entry of `arg_type_ids` is not an integer;
  - an entry is negative, or not less than the length of `types` (so every
    entry is out of range when `types` is empty).

Only the first top-level `eco.type_table` is consulted. An `eco.dbg` op with no
`arg_type_ids`, one that is not an array, or an empty one, cites no type and is
not reported.

Among what is not tested: whether a type ID names the type of the value being
logged, anything about the type table beyond the length of its `types` array,
and anything about ops other than `eco.dbg` and `eco.type_table`. A program
whose MLIR has no `eco.dbg` op carrying `arg_type_ids` passes.

@docs expectDbgTypeIds

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirAttr(..), MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getArrayAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Compiles `srcModule` to MLIR and passes when no `eco.dbg` op in it breaks
the rules the module docstring lists. When `runToMlir` returns an error, fails
with `Compilation failed:` and that error.
-}
expectDbgTypeIds : Src.Module -> Expectation
expectDbgTypeIds srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkDbgTypeIds mlirModule)


{-| Returns the violations of every `eco.dbg` op in the module, at any depth,
measured against the first top-level `eco.type_table`: the length of its
`types` array, or `Nothing` when the module has no type table or the table has
no array `types` attribute.
-}
checkDbgTypeIds : MlirModule -> List Violation
checkDbgTypeIds mlirModule =
    let
        typeCount =
            List.filter (\op -> op.name == "eco.type_table") mlirModule.body
                |> List.head
                |> Maybe.andThen (getArrayAttr "types")
                |> Maybe.map List.length

        dbgOps =
            findOpsNamed "eco.dbg" mlirModule
    in
    List.concatMap (checkDbgOp typeCount) dbgOps


{-| Returns the violations of one `eco.dbg` op, given `typeCount`, the number of
types in the type table, or `Nothing` when there is no usable table. An op
without an array `arg_type_ids`, or with an empty one, gives none. With no
table, a non-empty `arg_type_ids` gives one violation; otherwise each entry
that is not an integer or is out of range gives one.
-}
checkDbgOp : Maybe Int -> MlirOp -> List Violation
checkDbgOp typeCount op =
    case ( getArrayAttr "arg_type_ids" op, typeCount ) of
        ( Nothing, _ ) ->
            []

        ( Just [], _ ) ->
            []

        ( Just _, Nothing ) ->
            [ { opId = op.id
              , opName = op.name
              , message = "eco.dbg has arg_type_ids but the module has no eco.type_table with a types array"
              }
            ]

        ( Just typeIds, Just count ) ->
            List.indexedMap (checkTypeId op (count - 1)) typeIds
                |> List.filterMap identity


{-| Returns a violation of `op` when `attr`, the entry at position `index` of
its `arg_type_ids`, is not an integer, or is an integer outside 0 to
`maxTypeId` inclusive.
-}
checkTypeId : MlirOp -> Int -> Int -> MlirAttr -> Maybe Violation
checkTypeId op maxTypeId index attr =
    case attr of
        IntAttr _ typeId ->
            if typeId < 0 || typeId > maxTypeId then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.dbg arg_type_ids["
                            ++ String.fromInt index
                            ++ "]="
                            ++ String.fromInt typeId
                            ++ " out of range [0,"
                            ++ String.fromInt maxTypeId
                            ++ "]"
                    }

            else
                Nothing

        _ ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.dbg arg_type_ids[" ++ String.fromInt index ++ "] is not an integer"
                }
