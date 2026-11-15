module Mlir.Bytecode.DialectSection exposing
    ( DialectRegistry, opIndex, dialectIndex, encode
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

`buildRegistry` and `registryFromOpMap` make a registry from numberings worked
out elsewhere (`Mlir.Bytecode.StreamEncode` numbers operation names as it
meets them).

@docs DialectRegistry, opIndex, dialectIndex, encode
@docs OpGroup, buildRegistry, registryFromOpMap

-}

import Bytes.Encode as BE
import Dict exposing (Dict)
import Mlir.Bytecode.StringTable as StringTable exposing (StringTable)
import Mlir.Bytecode.VarInt exposing (encodeVarInt)


{-| A numbering of dialects and operation names, together with the op groups
the dialect section lists them in.

`opIndex` and `dialectIndex` look the numbers up, and `encode` writes the
section. One from `buildRegistry` holds exactly what it was given, unchecked.
One from `registryFromOpMap` answers only `opIndex`.

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

`opNames` holds suffixes, not full names: `func` for `func.func`. `encode`
writes whatever groups a registry holds, and one from `buildRegistry` may hold
several groups for the same dialect.

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
