module Mlir.Bytecode.DialectSection exposing
    ( DialectRegistry
    , OpGroup
    , buildRegistry
    , collect
    , dialectIndex
    , encode
    , opIndex
    , registryFromOpMap
    )

{-| Dialect section encoding for MLIR bytecode.

Collects all dialects and operation names from an MlirModule, assigns indices,
and encodes the dialect section.

Format:
    numDialects: varint
    dialectNames: [varint(stringIdx << 1 | hasVersion)]
    opNames: [dialect varint, numOps varint, [varint(nameIdx << 1 | isRegistered)]]

@docs DialectRegistry, collect, opIndex, dialectIndex, encode

-}

import Bytes.Encode as BE
import Dict exposing (Dict)
import Mlir.Bytecode.StringTable as StringTable exposing (StringTable)
import Mlir.Bytecode.VarInt exposing (encodeVarInt)
import Mlir.Mlir
    exposing
        ( MlirBlock
        , MlirModule
        , MlirOp
        , MlirRegion(..)
        )
import OrderedDict


{-| Registry of all dialects and their operations.
-}
type DialectRegistry
    = DialectRegistry
        { dialects : List String
        , dialectIndices : Dict String Int
        , opGroups : List OpGroup
        , opIndexMap : Dict String Int
        }


type alias OpGroup =
    { dialectIdx : Int
    , opNames : List String
    }


{-| Get the global sequential index of an operation name.
-}
opIndex : String -> DialectRegistry -> Int
opIndex name (DialectRegistry reg) =
    case Dict.get name reg.opIndexMap of
        Just idx ->
            idx

        Nothing ->
            -1


{-| Get the index of a dialect.
-}
dialectIndex : String -> DialectRegistry -> Int
dialectIndex name (DialectRegistry reg) =
    case Dict.get name reg.dialectIndices of
        Just idx ->
            idx

        Nothing ->
            -1


{-| Collect all dialects and operation names from an MlirModule.
-}
collect : MlirModule -> DialectRegistry
collect mod =
    let
        -- Collect all unique operation names, grouped by dialect
        groups =
            collectOpNames mod

        -- Ensure "builtin" dialect is present with "module" op
        -- (builtin owns standard attrs/types and the module op)
        groupsWithBuiltin =
            ensureBuiltinModule groups

        -- Build dialect list from the groups
        dialectList =
            List.map .dialect groupsWithBuiltin

        dialectIdxMap =
            dialectList
                |> List.indexedMap (\i d -> ( d, i ))
                |> Dict.fromList

        -- Build op groups with dialect indices
        opGroups =
            groupsWithBuiltin
                |> List.map
                    (\g ->
                        { dialectIdx = Maybe.withDefault -1 (Dict.get g.dialect dialectIdxMap)
                        , opNames = g.ops
                        }
                    )

        -- Build global op index map (sequential across all groups)
        opIdxMap =
            opGroups
                |> List.foldl
                    (\group ( idx, acc ) ->
                        let
                            ( nextIdx, entries ) =
                                List.foldl
                                    (\opName ( i, es ) ->
                                        let
                                            fullName =
                                                dialectList
                                                    |> List.drop group.dialectIdx
                                                    |> List.head
                                                    |> Maybe.withDefault ""
                                                    |> (\d -> d ++ "." ++ opName)
                                        in
                                        ( i + 1, ( fullName, i ) :: es )
                                    )
                                    ( idx, [] )
                                    group.opNames
                        in
                        ( nextIdx, entries ++ acc )
                    )
                    ( 0, [] )
                |> Tuple.second
                |> Dict.fromList
    in
    DialectRegistry
        { dialects = dialectList
        , dialectIndices = dialectIdxMap
        , opGroups = opGroups
        , opIndexMap = opIdxMap
        }


type alias CollectedGroup =
    { dialect : String
    , ops : List String
    }


{-| Walk the module and collect operation names grouped by dialect.
-}
collectOpNames : MlirModule -> List CollectedGroup
collectOpNames mod =
    let
        -- Collect all op names into a dict: dialect -> list of op suffixes
        allOps =
            List.foldl walkOpForNames Dict.empty mod.body

        -- Convert to groups, sorted by dialect name for deterministic output
        groups =
            allOps
                |> Dict.toList
                |> List.map
                    (\( dialect, ops ) ->
                        { dialect = dialect
                        , ops = List.reverse ops
                        }
                    )
    in
    groups


walkOpForNames : MlirOp -> Dict String (List String) -> Dict String (List String)
walkOpForNames op acc =
    let
        acc1 =
            addOpNameToDict op.name acc

        acc2 =
            List.foldl walkRegionForNames acc1 op.regions
    in
    acc2


walkRegionForNames : MlirRegion -> Dict String (List String) -> Dict String (List String)
walkRegionForNames (MlirRegion r) acc =
    let
        acc1 =
            walkBlockForNames r.entry acc
    in
    OrderedDict.foldl (\_ blk a -> walkBlockForNames blk a) acc1 r.blocks


walkBlockForNames : MlirBlock -> Dict String (List String) -> Dict String (List String)
walkBlockForNames blk acc =
    let
        acc1 =
            List.foldl walkOpForNames acc blk.body
    in
    walkOpForNames blk.terminator acc1


{-| Ensure the "builtin" dialect with "module" op is in the groups.
The builtin.module op is synthesized by the bytecode encoder, not present in user ops.
-}
ensureBuiltinModule : List CollectedGroup -> List CollectedGroup
ensureBuiltinModule groups =
    let
        hasBuiltin =
            List.any (\g -> g.dialect == "builtin") groups
    in
    if hasBuiltin then
        groups
            |> List.map
                (\g ->
                    if g.dialect == "builtin" && not (List.member "module" g.ops) then
                        { g | ops = g.ops ++ [ "module" ] }

                    else
                        g
                )

    else
        groups ++ [ { dialect = "builtin", ops = [ "module" ] } ]


addOpNameToDict : String -> Dict String (List String) -> Dict String (List String)
addOpNameToDict fullName acc =
    case String.split "." fullName of
        dialect :: rest ->
            let
                suffix =
                    String.join "." rest
            in
            Dict.update dialect
                (\existing ->
                    case existing of
                        Just ops ->
                            if List.member suffix ops then
                                Just ops

                            else
                                Just (suffix :: ops)

                        Nothing ->
                            Just [ suffix ]
                )
                acc

        _ ->
            acc


{-| Encode the dialect section.
-}
encode : StringTable -> DialectRegistry -> BE.Encoder
encode stringTable (DialectRegistry reg) =
    let
        numDialects =
            List.length reg.dialects

        -- Dialect names: each is (stringIdx << 1 | hasVersion)
        -- We don't use versioning, so hasVersion = 0
        dialectNameEncoders =
            reg.dialects
                |> List.map
                    (\name ->
                        let
                            strIdx =
                                StringTable.indexOf name stringTable
                        in
                        encodeVarInt (strIdx * 2)
                    )

        -- Total number of op names across all groups
        totalOpNames =
            List.foldl (\group total -> total + List.length group.opNames) 0 reg.opGroups

        -- Op name groups
        opGroupEncoders =
            reg.opGroups
                |> List.map (encodeOpGroup stringTable)
    in
    BE.sequence
        (encodeVarInt numDialects
            :: dialectNameEncoders
            ++ [ encodeVarInt totalOpNames ]
            ++ opGroupEncoders
        )


encodeOpGroup : StringTable -> OpGroup -> BE.Encoder
encodeOpGroup stringTable group =
    let
        numOps =
            List.length group.opNames

        opEncoders =
            group.opNames
                |> List.map
                    (\name ->
                        let
                            strIdx =
                                StringTable.indexOf name stringTable
                        in
                        -- Op name is a plain string table index
                        encodeVarInt strIdx
                    )
    in
    BE.sequence
        (encodeVarInt group.dialectIdx
            :: encodeVarInt numOps
            :: opEncoders
        )


{-| Build a DialectRegistry from pre-computed components.
Used by the streaming encoder to construct the final registry.
-}
buildRegistry :
    { dialects : List String
    , dialectIndices : Dict String Int
    , opGroups : List OpGroup
    , opIndexMap : Dict String Int
    }
    -> DialectRegistry
buildRegistry r =
    DialectRegistry r


{-| Create a lightweight DialectRegistry containing only the op index map.
Used for encoding individual ops during streaming — only `opIndex` lookups
are needed, not the full dialect/group structure.
-}
registryFromOpMap : Dict String Int -> DialectRegistry
registryFromOpMap opMap =
    DialectRegistry
        { dialects = []
        , dialectIndices = Dict.empty
        , opGroups = []
        , opIndexMap = opMap
        }
