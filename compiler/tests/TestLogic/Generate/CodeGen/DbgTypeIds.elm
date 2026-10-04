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

  - the module has no type table, or the first top-level `eco.type_table` has
    no array `types` attribute or an empty one, all three reported as no type
    table, even when `arg_type_ids` is empty;
  - an entry of `arg_type_ids` is not an integer;
  - an entry is negative, or not less than the length of `types`.

Only the first top-level `eco.type_table` is consulted. An `eco.dbg` op with no
`arg_type_ids`, or one that is not an array, is not checked. As
`TestLogic.Generate.CodeGen.Invariants.violationsToExpectation` describes, a
failing test shows only the first violation.

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
measured against the first top-level `eco.type_table`.

The largest valid type ID handed to `checkDbgOp` is the length of that table's
`types` array minus one. It is -1, which `checkDbgOp` reads as no type table,
when the module has no such op, the op has no array `types` attribute, or the
array is empty.

-}
checkDbgTypeIds : MlirModule -> List Violation
checkDbgTypeIds mlirModule =
    let
        typeTableOps =
            List.filter (\op -> op.name == "eco.type_table") mlirModule.body

        maxTypeId =
            case List.head typeTableOps of
                Just typeTable ->
                    case getArrayAttr "types" typeTable of
                        Just types ->
                            List.length types - 1

                        Nothing ->
                            -1

                Nothing ->
                    -1

        dbgOps =
            findOpsNamed "eco.dbg" mlirModule
    in
    List.concatMap (checkDbgOp maxTypeId) dbgOps


{-| Returns the violations of one `eco.dbg` op, given `maxTypeId`, the largest
valid type ID. An op without an array `arg_type_ids` gives none. When
`maxTypeId` is negative the op gives one violation saying the module has no
type table, even if `arg_type_ids` is empty; otherwise it gives one violation
for each entry that is not an integer or is out of range.
-}
checkDbgOp : Int -> MlirOp -> List Violation
checkDbgOp maxTypeId op =
    let
        maybeTypeIds =
            getArrayAttr "arg_type_ids" op
    in
    case maybeTypeIds of
        Nothing ->
            []

        Just typeIds ->
            if maxTypeId < 0 then
                [ { opId = op.id
                  , opName = op.name
                  , message = "eco.dbg has arg_type_ids but no eco.type_table in module"
                  }
                ]

            else
                List.indexedMap (checkTypeId op maxTypeId) typeIds
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
