module Mlir.Bytecode.DialectSection exposing
    ( DialectRegistry, collect, opIndex, dialectIndex, encode
    , OpGroup, buildRegistry, registryFromOpMap
    )

{-| MLIR bytecode does not write an operation's name with the operation. It
refers to the name by an index into a list of operation names kept in the
dialect section, and this module numbers those names and writes that section.

An MLIR operation name has the form `dialect.op`, such as `func.func`. The
_dialect_ is the text before the first `.` and the _suffix_ is the rest; a name
with no `.` is taken as a dialect with an empty suffix. The dialect section
lists the dialects, then the operation names in _op groups_. An op group is one
dialect, given by its index in the dialect list, followed by suffixes of that
dialect's operation names. An operation name is numbered by its position in the
sequence of op groups, counting from 0 and continuing across groups. A
`DialectRegistry` holds both numberings and the groups.

Dialect names and suffixes are written as indices into the string section, so
each must already be in the `StringTable` given to `encode`. No lookup in this
module is checked: a name that was never added gets the index -1, which
`Mlir.Bytecode.VarInt.encodeVarInt` writes like any other number, so a missed
name makes a corrupt file rather than an error.

`collect` numbers every operation name of a whole module at once.
`buildRegistry` and `registryFromOpMap` make a registry from numberings worked
out elsewhere.

@docs DialectRegistry, collect, opIndex, dialectIndex, encode
@docs OpGroup, buildRegistry, registryFromOpMap

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


{-| A numbering of dialects and operation names, together with the op groups
the dialect section lists them in.

`opIndex` and `dialectIndex` look the numbers up, and `encode` writes the
section. A registry from `collect` lists every operation name in the module it
was built from, and `builtin.module`, and numbers each by its position in the
section; `opIndex` finds all of them except a name with no `.`, for the reason
`collect` gives. One from `buildRegistry` holds exactly what it was given,
unchecked. One from `registryFromOpMap` answers only `opIndex`.

-}
type DialectRegistry
    = DialectRegistry
        { dialects : List String
        , dialectIndices : Dict String Int
        , opGroups : List OpGroup
        , opIndexMap : Dict String Int
        }


{-| One op group of the dialect section: a dialect, given by its index, and
suffixes of that dialect's operation names, in the order they are written.

`opNames` holds suffixes, not full names: `func` for `func.func`. A registry
from `collect` has one group per dialect, but `encode` writes whatever groups a
registry holds, and one from `buildRegistry` may hold several groups for the
same dialect.

-}
type alias OpGroup =
    { dialectIdx : Int
    , opNames : List String
    }


{-| Returns the index of the operation named `name`, written in full as
`dialect.op`, or -1 if the registry has no index for it.
-}
opIndex : String -> DialectRegistry -> Int
opIndex name (DialectRegistry reg) =
    case Dict.get name reg.opIndexMap of
        Just idx ->
            idx

        Nothing ->
            -1


{-| Returns the index of the dialect `name` in the dialect list, or -1 if the
registry has no index for it.
-}
dialectIndex : String -> DialectRegistry -> Int
dialectIndex name (DialectRegistry reg) =
    case Dict.get name reg.dialectIndices of
        Just idx ->
            idx

        Nothing ->
            -1


{-| Builds the registry for `mod`: the name of every operation in its body and
in the regions nested inside them, and `builtin.module`, which is added whether
or not `mod` contains one.

There is one op group per dialect. Dialects are listed in ascending order of
their names, except that `builtin`, when no operation in `mod` belongs to it,
is added last. Within a group each suffix is listed once, in the order a walk
first meets it: an operation before its regions, a region's entry block before
its other blocks, and a block's body before its terminator. `module` is added
at the end of the `builtin` group unless the walk met it. Operation names are
numbered from 0 in that listing order.

A name with no `.` is listed as a dialect with an empty suffix, but its index
is kept under the name followed by a `.`, so `opIndex` given the name itself
returns -1.

-}
collect : MlirModule -> DialectRegistry
collect mod =
    let
        groups =
            collectOpNames mod

        groupsWithBuiltin =
            ensureBuiltinModule groups

        dialectList =
            List.map .dialect groupsWithBuiltin

        dialectIdxMap =
            dialectList
                |> List.indexedMap (\i d -> ( d, i ))
                |> Dict.fromList

        opGroups =
            groupsWithBuiltin
                |> List.map
                    (\g ->
                        { dialectIdx = Maybe.withDefault -1 (Dict.get g.dialect dialectIdxMap)
                        , opNames = g.ops
                        }
                    )

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


{-| A dialect's name with the distinct suffixes of its operation names, before
the dialect has been given an index.
-}
type alias CollectedGroup =
    { dialect : String
    , ops : List String
    }


{-| Returns a group for each dialect that an operation in `mod` belongs to,
holding the distinct suffixes in the order `walkOpForNames` first meets them,
with the groups in ascending order of dialect name.
-}
collectOpNames : MlirModule -> List CollectedGroup
collectOpNames mod =
    let
        allOps =
            List.foldl walkOpForNames Dict.empty mod.body
    in
    allOps
        |> Dict.toList
        |> List.map
            (\( dialect, ops ) ->
                { dialect = dialect
                , ops = List.reverse ops
                }
            )


{-| Adds the name of `op`, and then the names of the operations in its regions,
to `acc`, which maps each dialect to its suffixes, newest first. A suffix
already in its dialect's list is not added again.
-}
walkOpForNames : MlirOp -> Dict String (List String) -> Dict String (List String)
walkOpForNames op acc =
    let
        acc1 =
            addOpNameToDict op.name acc
    in
    List.foldl walkRegionForNames acc1 op.regions


{-| Adds the operation names in a region, its entry block first and then its
other blocks in the order they were inserted.
-}
walkRegionForNames : MlirRegion -> Dict String (List String) -> Dict String (List String)
walkRegionForNames (MlirRegion r) acc =
    let
        acc1 =
            walkBlockForNames r.entry acc
    in
    OrderedDict.foldl (\_ blk a -> walkBlockForNames blk a) acc1 r.blocks


{-| Adds the operation names in a block, its body first and then its
terminator, each with the operations nested in its regions.
-}
walkBlockForNames : MlirBlock -> Dict String (List String) -> Dict String (List String)
walkBlockForNames blk acc =
    let
        acc1 =
            List.foldl walkOpForNames acc blk.body
    in
    walkOpForNames blk.terminator acc1


{-| Returns `groups` with `module` in the `builtin` group. It is added at the
end of that group if missing, and if there is no `builtin` group, one holding
only `module` is added at the end of the list.
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


{-| Adds the suffix of `fullName` to the front of its dialect's list in `acc`,
unless the list already holds it. A name with no `.` is its own dialect, with
the empty suffix.
-}
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


{-| Creates an encoder for the contents of the dialect section, with every name
written as its index in `stringTable`.

It writes the number of dialects; each dialect name's string index times two,
the low bit being a flag for a dialect version that is never set; the total
number of operation names across all groups; and then each op group in turn.
Every number is a PrefixVarInt, as `Mlir.Bytecode.VarInt` describes.

-}
encode : StringTable -> DialectRegistry -> BE.Encoder
encode stringTable (DialectRegistry reg) =
    let
        numDialects =
            List.length reg.dialects

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

        totalOpNames =
            List.foldl (\group total -> total + List.length group.opNames) 0 reg.opGroups

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


{-| Creates an encoder for one op group: its dialect index, its number of
suffixes, and each suffix's index in `stringTable`.
-}
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


{-| Creates a registry holding exactly the given numberings and op groups.

Nothing is checked. `opIndexMap`, keyed by full operation name, and
`dialectIndices` are what `opIndex` and `dialectIndex` return, and `dialects`
and `opGroups` are what `encode` writes, whether or not they agree with each
other.

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


{-| Creates a registry that answers only `opIndex`, from a map of full
operation names to their indices.

`dialectIndex` on it returns -1 for every name, and `encode` writes a section
with no dialects and no operation names.

-}
registryFromOpMap : Dict String Int -> DialectRegistry
registryFromOpMap opMap =
    DialectRegistry
        { dialects = []
        , dialectIndices = Dict.empty
        , opGroups = []
        , opIndexMap = opMap
        }
