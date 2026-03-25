module Mlir.Bytecode.Section exposing (encodeSection, sectionId)

{-| Section framing for MLIR bytecode.

Each section has:

  - idAndIsAligned: byte (id | (hasAlign << 7))
  - length: varint
  - alignment: varint? (only if hasAlign)
  - padding: byte[] (0xCB bytes to reach alignment)
  - data: byte[]

@docs encodeSection, sectionId

-}

import Bytes
import Bytes.Encode as BE
import Mlir.Bytecode.VarInt exposing (encodeVarInt)


{-| Section IDs matching MLIR's bytecode::Section::ID enum.
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


{-| Encode a section without alignment requirements.
Pre-encodes content to measure its byte length for the header.
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
