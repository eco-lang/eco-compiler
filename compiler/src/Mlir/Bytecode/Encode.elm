module Mlir.Bytecode.Encode exposing (encodeModule)

{-| Top-level MLIR bytecode encoder.

Orchestrates the two-pass encoding:

1.  Collection pass: builds string table, dialect registry, attr/type table
2.  Encoding pass: encodes all sections and assembles the final bytecode

Output format:
magic: [0x4D, 0x4C, 0xEF, 0x52]
version: varint(6)
producer: null-terminated string "eco"
sections: section[]

@docs encodeModule

-}

import Bytes exposing (Bytes)
import Bytes.Encode as BE
import Mlir.Bytecode.AttrType as AttrType
import Mlir.Bytecode.DialectSection as DialectSection
import Mlir.Bytecode.IrSection as IrSection
import Mlir.Bytecode.Section as Section
import Mlir.Bytecode.StringTable as StringTable
import Mlir.Bytecode.VarInt exposing (encodeVarInt)
import Mlir.Mlir exposing (MlirModule)


{-| Bytecode format version. We target version 4 which avoids the native
properties encoding requirement of v5/v6. MLIR's parseSourceFile supports
all versions from 0 to kVersion, so this is fully compatible.
-}
bytecodeVersion : Int
bytecodeVersion =
    4


{-| Encode an MlirModule as MLIR bytecode bytes.
-}
encodeModule : MlirModule -> Bytes
encodeModule mod =
    let
        -- Pass 1: Collection
        stringTable =
            StringTable.collect mod

        dialectRegistry =
            DialectSection.collect mod

        attrTypeTable =
            AttrType.collect mod

        -- Pass 2: Encoding
        stringSectionBody =
            StringTable.encode stringTable

        dialectSectionBody =
            DialectSection.encode stringTable dialectRegistry

        ( attrTypeSectionBody, attrTypeOffsetSectionBody ) =
            AttrType.encodeDataAndOffsets stringTable dialectRegistry attrTypeTable

        irSectionBody =
            IrSection.encode dialectRegistry attrTypeTable mod
    in
    BE.encode <|
        BE.sequence
            [ -- Magic number: "MLïR"
              BE.unsignedInt8 0x4D
            , BE.unsignedInt8 0x4C
            , BE.unsignedInt8 0xEF
            , BE.unsignedInt8 0x52

            -- Version
            , encodeVarInt bytecodeVersion

            -- Producer string (null-terminated)
            , BE.string "eco"
            , BE.unsignedInt8 0x00

            -- Sections
            , Section.encodeSection Section.sectionId.string stringSectionBody
            , Section.encodeSection Section.sectionId.dialect dialectSectionBody
            , Section.encodeSection Section.sectionId.attrType attrTypeSectionBody
            , Section.encodeSection Section.sectionId.attrTypeOffset attrTypeOffsetSectionBody
            , Section.encodeSection Section.sectionId.ir irSectionBody

            -- Empty resource sections (no resources in eco programs)
            , Section.encodeSection Section.sectionId.resource (BE.sequence [])
            , Section.encodeSection Section.sectionId.resourceOffset (encodeVarInt 0)
            ]
