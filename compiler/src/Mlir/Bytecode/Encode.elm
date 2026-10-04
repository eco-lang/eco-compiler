module Mlir.Bytecode.Encode exposing (encodeModule)

{-| MLIR can read a program from a binary encoding called bytecode, and this
module writes a whole `MlirModule` as an MLIR bytecode file in one go.

The file is a header followed by sections, each framed as
`Mlir.Bytecode.Section` describes. The header is the magic bytes 0x4D 0x4C 0xEF
0x52; the format version, 4, as a PrefixVarInt (see
`Mlir.Bytecode.VarInt`); and the producer name `eco`, written inline as text
followed by a zero byte rather than through the string section. The sections
follow in this order: strings, dialects, attribute and type data, attribute and
type offsets, and the IR. Last come an empty resource section and a resource
offset section holding the single number 0, since this encoder writes no
resources.

Most of the file refers to things by index rather than spelling them out: a
string by its position in the string section, an operation name by its
position in the dialect section, an attribute or type by its position in the
attribute and type section. So the encoder works in two passes. The first
walks every operation in the module and builds the three tables, with
`Mlir.Bytecode.StringTable`, `Mlir.Bytecode.DialectSection` and
`Mlir.Bytecode.AttrType`. The second writes every section from those finished
tables. No lookup is checked: as those modules describe, anything the first
pass did not collect is written as -1, and the file is then corrupt rather
than the encoding failing.

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


{-| The version of the MLIR bytecode format that the header declares.
-}
bytecodeVersion : Int
bytecodeVersion =
    4


{-| Returns `mod` written as a complete MLIR bytecode file, laid out as the
module docstring describes.

The location of `mod` itself is not collected into the attribute table, so it
is written as -1 unless the table holds an entry for it anyway: MLIR's unknown
location, which the table always holds, or an entry made for an operation in
`mod` whose location has the same name and start.

-}
encodeModule : MlirModule -> Bytes
encodeModule mod =
    let
        stringTable =
            StringTable.collect mod

        dialectRegistry =
            DialectSection.collect mod

        attrTypeTable =
            AttrType.collect mod

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

            -- Empty resource sections
            , Section.encodeSection Section.sectionId.resource (BE.sequence [])
            , Section.encodeSection Section.sectionId.resourceOffset (encodeVarInt 0)
            ]
