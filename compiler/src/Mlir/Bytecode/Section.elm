module Mlir.Bytecode.Section exposing
    ( encodeSection, encodeSectionAligned
    , sectionId
    )

{-| Section framing for MLIR bytecode.

Each section has:

  - idAndIsAligned: byte (id | (hasAlign << 7))
  - length: varint
  - alignment: varint? (only if hasAlign)
  - padding: byte[] (0xCB bytes to reach alignment)
  - data: byte[]

@docs encodeSection, encodeSectionAligned, sectionId

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


{-| Encode a section with alignment requirements.
Sets the high bit on the ID byte, includes alignment varint, and pads with 0xCB.

The `currentOffset` parameter is the byte offset where the section data will start
(after magic + version + producer + prior sections). This is needed to compute
how many padding bytes are required to reach the desired alignment.

-}
encodeSectionAligned : Int -> Int -> Int -> BE.Encoder -> BE.Encoder
encodeSectionAligned id alignment currentOffset contentEncoder =
    let
        contentBytes =
            BE.encode contentEncoder

        contentLen =
            Bytes.width contentBytes

        -- ID byte with high bit set for alignment
        idByte =
            id + 0x80

        -- Padding needed after the alignment varint to reach alignment boundary
        -- We need to account for the id byte + length varint + alignment varint
        paddingNeeded =
            let
                remainder =
                    modBy alignment currentOffset
            in
            if remainder == 0 then
                0

            else
                alignment - remainder

        paddingBytes =
            List.repeat paddingNeeded (BE.unsignedInt8 0xCB)

        totalLen =
            contentLen + paddingNeeded
    in
    BE.sequence
        ([ BE.unsignedInt8 idByte
         , encodeVarInt totalLen
         , encodeVarInt alignment
         ]
            ++ paddingBytes
            ++ [ BE.bytes contentBytes ]
        )
