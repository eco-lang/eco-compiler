module Compiler.Generate.CodeGen.Invariants exposing
    ( Violation
    , walkAllOps
    , walkOpAndChildren
    , walkOpsInRegion
    , walkOpsInBlock
    , findOpsNamed
    , findOpsWithPrefix
    , findFuncOps
    , getIntAttr
    , getStringAttr
    , getArrayAttr
    , getTypeAttr
    , getBoolAttr
    , extractOperandTypes
    , extractResultTypes
    , isEcoValueType
    , isPrimitiveType
    , checkAll
    , checkNone
    , violationsToExpectation
    , ecoValueType
    , allBlocks
    )

{-| Shared infrastructure for MLIR codegen invariant tests.

This module provides utilities for walking and inspecting MlirModule AST
structures to verify MLIR codegen invariants.


# Violation Tracking

@docs Violation, violationsToExpectation


# Op Walking

@docs walkAllOps, walkOpAndChildren, walkOpsInRegion, walkOpsInBlock


# Op Finding

@docs findOpsNamed, findOpsWithPrefix, findFuncOps


# Attribute Extraction

@docs getIntAttr, getStringAttr, getArrayAttr, getTypeAttr, getBoolAttr


# Type Extraction

@docs extractOperandTypes, extractResultTypes


# Type Predicates

@docs isEcoValueType, isPrimitiveType, ecoValueType


# Checking Utilities

@docs checkAll, checkNone


# Block Utilities

@docs allBlocks

-}

import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirAttr(..), MlirBlock, MlirModule, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict



-- VIOLATION TRACKING


{-| A violation of an invariant.
-}
type alias Violation =
    { opId : String
    , opName : String
    , message : String
    }


{-| Convert violations to an Expectation. Empty list passes, otherwise fails.
-}
violationsToExpectation : List Violation -> Expectation
violationsToExpectation violations =
    case violations of
        [] ->
            Expect.pass

        _ ->
            let
                violationStrings =
                    List.map formatViolation violations
            in
            Expect.fail (String.join "\n" violationStrings)


formatViolation : Violation -> String
formatViolation v =
    "Violation in " ++ v.opName ++ " (" ++ v.opId ++ "): " ++ v.message



-- OP WALKING


{-| Recursively walk all ops in module, including nested regions.
-}
walkAllOps : MlirModule -> List MlirOp
walkAllOps mod =
    List.concatMap walkOpAndChildren mod.body


{-| Walk an op and all ops nested within its regions.
-}
walkOpAndChildren : MlirOp -> List MlirOp
walkOpAndChildren op =
    op :: List.concatMap walkOpsInRegion op.regions


{-| Walk all ops in a region.
-}
walkOpsInRegion : MlirRegion -> List MlirOp
walkOpsInRegion (MlirRegion { entry, blocks }) =
    walkOpsInBlock entry ++ List.concatMap walkOpsInBlock (OrderedDict.values blocks)


{-| Walk all ops in a block.
-}
walkOpsInBlock : MlirBlock -> List MlirOp
walkOpsInBlock block =
    List.concatMap walkOpAndChildren block.body
        ++ walkOpAndChildren block.terminator



-- OP FINDING


{-| Find all ops with exact name match.
-}
findOpsNamed : String -> MlirModule -> List MlirOp
findOpsNamed name mod =
    List.filter (\op -> op.name == name) (walkAllOps mod)


{-| Find all ops with name starting with prefix.
-}
findOpsWithPrefix : String -> MlirModule -> List MlirOp
findOpsWithPrefix prefix mod =
    List.filter (\op -> String.startsWith prefix op.name) (walkAllOps mod)


{-| Find func.func ops (top-level functions).
-}
findFuncOps : MlirModule -> List MlirOp
findFuncOps mod =
    List.filter (\op -> op.name == "func.func") mod.body



-- ATTRIBUTE EXTRACTION


{-| Get an integer attribute value.
-}
getIntAttr : String -> MlirOp -> Maybe Int
getIntAttr key op =
    Dict.get key op.attrs |> Maybe.andThen extractInt


extractInt : MlirAttr -> Maybe Int
extractInt attr =
    case attr of
        IntAttr _ n ->
            Just n

        _ ->
            Nothing


{-| Get a string attribute value.
-}
getStringAttr : String -> MlirOp -> Maybe String
getStringAttr key op =
    Dict.get key op.attrs |> Maybe.andThen extractString


extractString : MlirAttr -> Maybe String
extractString attr =
    case attr of
        StringAttr s ->
            Just s

        SymbolRefAttr s ->
            Just s

        _ ->
            Nothing


{-| Get an array attribute value.
-}
getArrayAttr : String -> MlirOp -> Maybe (List MlirAttr)
getArrayAttr key op =
    Dict.get key op.attrs |> Maybe.andThen extractArray


extractArray : MlirAttr -> Maybe (List MlirAttr)
extractArray attr =
    case attr of
        ArrayAttr _ items ->
            Just items

        _ ->
            Nothing


{-| Get a type attribute value.
-}
getTypeAttr : String -> MlirOp -> Maybe MlirType
getTypeAttr key op =
    Dict.get key op.attrs |> Maybe.andThen extractType


extractType : MlirAttr -> Maybe MlirType
extractType attr =
    case attr of
        TypeAttr t ->
            Just t

        _ ->
            Nothing


{-| Get a boolean attribute value (interprets int as bool).
-}
getBoolAttr : String -> MlirOp -> Maybe Bool
getBoolAttr key op =
    getIntAttr key op |> Maybe.map (\n -> n /= 0)



-- TYPE EXTRACTION


{-| Extract \_operand\_types as list of MlirType.
-}
extractOperandTypes : MlirOp -> Maybe (List MlirType)
extractOperandTypes op =
    getArrayAttr "_operand_types" op
        |> Maybe.map (List.filterMap extractTypeFromAttr)


extractTypeFromAttr : MlirAttr -> Maybe MlirType
extractTypeFromAttr attr =
    case attr of
        TypeAttr t ->
            Just t

        _ ->
            Nothing


{-| Extract result types from an op.
-}
extractResultTypes : MlirOp -> List MlirType
extractResultTypes op =
    List.map Tuple.second op.results



-- TYPE PREDICATES


{-| The !eco.value type representation.
-}
ecoValueType : MlirType
ecoValueType =
    NamedStruct "!eco.value"


{-| Check if a type is !eco.value.
-}
isEcoValueType : MlirType -> Bool
isEcoValueType t =
    case t of
        NamedStruct name ->
            name == "!eco.value"

        _ ->
            False


{-| Check if a type is a primitive (i1, i16, i64, f64).
-}
isPrimitiveType : MlirType -> Bool
isPrimitiveType t =
    case t of
        I1 ->
            True

        I16 ->
            True

        I64 ->
            True

        F64 ->
            True

        _ ->
            False



-- CHECKING UTILITIES


{-| Check all items with a predicate, collect violations.
-}
checkAll : (a -> Maybe Violation) -> List a -> List Violation
checkAll check items =
    List.filterMap check items


{-| Check that no items exist (list should be empty).
-}
checkNone : String -> List MlirOp -> List Violation
checkNone message ops =
    List.map (\op -> { opId = op.id, opName = op.name, message = message }) ops



-- BLOCK UTILITIES


{-| Get all blocks from a region (entry plus additional blocks).
-}
allBlocks : MlirRegion -> List MlirBlock
allBlocks (MlirRegion { entry, blocks }) =
    entry :: OrderedDict.values blocks
