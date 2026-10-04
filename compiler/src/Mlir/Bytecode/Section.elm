module Mlir.Bytecode.Section exposing (encodeSection, sectionId)

{-| An MLIR bytecode file is divided into sections, and this module writes the
frame that goes around a section.

A _section_ is one block of the file with a single job, such as holding the
string table or the operations. Each starts with a byte naming which section it
is, its _id_, followed by the length of its contents in bytes as a PrefixVarInt
(see `Mlir.Bytecode.VarInt`), so that a reader can find the end of a section
without decoding it. The ids are fixed by MLIR, and `sectionId` lists them.

The general format also lets a section ask for its contents to be aligned: the
high bit of the id byte then says that an alignment value and padding bytes
follow the length. `encodeSection` writes the id it is given as the whole id
byte and puts nothing between the length and the contents, so with any id from
`sectionId` the section is unaligned and is exactly the id byte, the length
and the contents.

@docs encodeSection, sectionId

-}

import Bytes
import Bytes.Encode as BE
import Mlir.Bytecode.VarInt exposing (encodeVarInt)


{-| The id of each kind of section, using the numbers MLIR's bytecode format
assigns to them.
-}
sectionId :
    { string : Int
    , dialect : Int
    , attrType : Int
    , attrTypeOffset : Int
    , ir : Int
    , resource : Int
    , resourceOffset : Int
    , dialectVersions : Int
    , properties : Int
    }
sectionId =
    { string = 0
    , dialect = 1
    , attrType = 2
    , attrTypeOffset = 3
    , ir = 4
    , resource = 5
    , resourceOffset = 6
    , dialectVersions = 7
    , properties = 8
    }


{-| Creates an encoder that writes `contentEncoder` as a section with the id
`id`: the id byte, the length of the contents in bytes as a PrefixVarInt, then
the contents.

The contents are encoded once here to measure their length, and those bytes are
what the section carries.

-}
encodeSection : Int -> BE.Encoder -> BE.Encoder
encodeSection id contentEncoder =
    let
        contentBytes =
            BE.encode contentEncoder

        contentLen =
            Bytes.width contentBytes
    in
    BE.sequence
        [ BE.unsignedInt8 id
        , encodeVarInt contentLen
        , BE.bytes contentBytes
        ]
