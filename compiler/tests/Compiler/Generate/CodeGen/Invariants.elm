module Compiler.Generate.CodeGen.Invariants exposing
    ( Violation, violationsToExpectation
    , walkAllOps, walkOpAndChildren, walkOpsInRegion, walkOpsInBlock
    , findOpsNamed, findOpsWithPrefix, findFuncOps
    , getIntAttr, getStringAttr, getArrayAttr, getTypeAttr, getBoolAttr
    , extractOperandTypes, extractResultTypes
    , isEcoValueType, isUnboxable, isEcoPrimitive, ecoValueType
    , checkAll, checkNone
    , allBlocks
    , TypeEnv, buildTypeEnv, findSymbolOps, isValidTerminator, typesMatch, validTerminators
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

Uses Expect.all with lazy expectations to avoid accumulating strings in memory.

-}
violationsToExpectation : List Violation -> Expectation
violationsToExpectation violations =
    case violations of
        [] ->
            Expect.pass

        _ ->
            let
                checks =
                    List.map (\v -> \() -> Expect.fail (formatViolation v)) violations
            in
            Expect.all checks ()


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
    NamedStruct "eco.value"


{-| Check if a type is eco.value.
-}
isEcoValueType : MlirType -> Bool
isEcoValueType t =
    case t of
        NamedStruct name ->
            name == "eco.value"

        _ ->
            False


{-| Check if a type is unboxable for heap storage (i16, i64, f64).

Per CGEN_026, only Int (i64), Float (f64), and Char (i16) are unboxable.
Bool (i1) is NOT unboxable - it must be stored as !eco.value in heap objects.
-}
isUnboxable : MlirType -> Bool
isUnboxable t =
    case t of
        I16 ->
            True

        I64 ->
            True

        F64 ->
            True

        _ ->
            False


{-| Check if a type is an eco MLIR primitive (i1, i16, i64, f64).

This includes Bool (i1), which is a valid primitive for SSA operations
like eco.unbox results, but cannot be stored unboxed in heap objects.
-}
isEcoPrimitive : MlirType -> Bool
isEcoPrimitive t =
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



-- TYPE COMPARISON


{-| Compare two types with normalization.
-}
typesMatch : MlirType -> MlirType -> Bool
typesMatch t1 t2 =
    t1 == t2



-- TERMINATOR VALIDATION


{-| List of valid terminator operation names.

Note: eco.case is NOT a terminator - it is a value-producing expression.
eco.yield is only valid inside eco.case alternatives.
-}
validTerminators : List String
validTerminators =
    [ "eco.return"
    , "eco.jump"
    , "eco.crash"
    , "eco.yield"
    , "scf.yield"
    , "cf.br"
    , "cf.cond_br"
    , "func.return"
    ]


{-| Check if an operation is a valid terminator.
-}
isValidTerminator : MlirOp -> Bool
isValidTerminator op =
    List.member op.name validTerminators



-- SYMBOL FINDING


{-| Find all symbol-defining ops at module level with their symbol names.
-}
findSymbolOps : MlirModule -> List ( String, MlirOp )
findSymbolOps mod =
    List.filterMap
        (\op ->
            getStringAttr "sym_name" op
                |> Maybe.map (\name -> ( name, op ))
        )
        mod.body



-- TYPE ENVIRONMENT


{-| A type environment mapping SSA value names to their types.
-}
type alias TypeEnv =
    Dict String MlirType


{-| Build a type environment from a module by collecting all result definitions.
-}
buildTypeEnv : MlirModule -> TypeEnv
buildTypeEnv mod =
    let
        collectFromOps : List MlirOp -> TypeEnv -> TypeEnv
        collectFromOps ops env =
            List.foldl collectFromOp env ops

        collectFromOp : MlirOp -> TypeEnv -> TypeEnv
        collectFromOp op env =
            let
                -- Add results from this op
                withResults =
                    List.foldl
                        (\( name, t ) acc -> Dict.insert name t acc)
                        env
                        op.results

                -- Recurse into regions
                withRegions =
                    List.foldl collectFromRegion withResults op.regions
            in
            withRegions

        collectFromRegion : MlirRegion -> TypeEnv -> TypeEnv
        collectFromRegion (MlirRegion { entry, blocks }) env =
            let
                -- Add block arguments from entry
                withEntryArgs =
                    List.foldl
                        (\( name, t ) acc -> Dict.insert name t acc)
                        env
                        entry.args

                -- Add ops from entry block
                withEntryBody =
                    collectFromOps entry.body withEntryArgs

                -- Add terminator
                withEntryTerm =
                    collectFromOp entry.terminator withEntryBody

                -- Process additional blocks
                withBlocks =
                    List.foldl collectFromBlock withEntryTerm (OrderedDict.values blocks)
            in
            withBlocks

        collectFromBlock : MlirBlock -> TypeEnv -> TypeEnv
        collectFromBlock block env =
            let
                withArgs =
                    List.foldl
                        (\( name, t ) acc -> Dict.insert name t acc)
                        env
                        block.args

                withBody =
                    collectFromOps block.body withArgs

                withTerm =
                    collectFromOp block.terminator withBody
            in
            withTerm
    in
    collectFromOps mod.body Dict.empty
