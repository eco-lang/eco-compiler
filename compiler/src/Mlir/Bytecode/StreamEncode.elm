module Mlir.Bytecode.StreamEncode exposing
    ( StreamTables
    , assembleModule
    , collectAndEncodeOps
    , emptyStreamTables
    )

{-| Streaming MLIR bytecode encoder.

Enables incremental bytecode encoding where ops are generated one at a time,
collected into growing tables, and encoded immediately. This avoids holding
all MlirOps in memory simultaneously.

Key design: all table indices are append-only (insertion order). The dialect
section and attr/type offset section use run-length grouping to handle
non-contiguous same-dialect entries.

@docs StreamTables, emptyStreamTables, collectAndEncodeOps, assembleModule

-}

import Bitwise
import Bytes exposing (Bytes)
import Bytes.Encode as BE
import Dict exposing (Dict)
import Mlir.Bytecode.AttrType as AttrType exposing (AttrTypeTable)
import Mlir.Bytecode.DialectSection as DialectSection exposing (DialectRegistry)
import Mlir.Bytecode.IrSection as IrSection
import Mlir.Bytecode.Section as Section
import Mlir.Bytecode.StringTable as StringTable exposing (StringTable)
import Mlir.Bytecode.VarInt exposing (encodeVarInt)
import Mlir.Loc exposing (Loc(..))
import Mlir.Mlir
    exposing
        ( MlirBlock
        , MlirOp
        , MlirRegion(..)
        )
import OrderedDict



-- ==== Stream Tables (accumulator) ====


{-| Accumulator for streaming bytecode encoding. Bundles growing tables
and pre-encoded op bytes.
-}
type StreamTables
    = StreamTables
        { stringTable : StringTable
        , dialectBuilder : StreamDialectBuilder
        , attrAccum : AttrType.StreamAccum
        , encodedOps : List Bytes -- reverse order (newest first)
        , numOps : Int
        }


{-| Create empty stream tables with required initial entries:
builtin/module strings, builtin.module op, and unknown location attr.
-}
emptyStreamTables : StreamTables
emptyStreamTables =
    StreamTables
        { stringTable =
            StringTable.empty
                |> StringTable.addString "builtin"
                |> StringTable.addString "module"
        , dialectBuilder = emptyDialectBuilder |> addDialectOp "builtin.module"
        , attrAccum = AttrType.initStreamAccum
        , encodedOps = []
        , numOps = 0
        }


{-| Collect table entries from ops and encode each op to bytes.
The ops' strings, attrs, types, and dialect op names are added to the
growing tables, then each op is encoded using the current table state.
-}
collectAndEncodeOps : List MlirOp -> StreamTables -> StreamTables
collectAndEncodeOps ops (StreamTables st) =
    let
        -- Step 1: Collect into all tables
        newStringTable =
            List.foldl StringTable.collectOp st.stringTable ops

        newDialectBuilder =
            List.foldl walkOpForDialects st.dialectBuilder ops

        newAttrAccum =
            List.foldl AttrType.streamCollectOp st.attrAccum ops

        -- Step 2: Build encoding views from the updated accumulators
        encDialectReg =
            DialectSection.registryFromOpMap (dialectOpMap newDialectBuilder)

        encAttrTable =
            AttrType.streamAccumEncodingView newAttrAccum

        -- Step 3: Encode each op using current tables
        newEncodedOps =
            List.foldl
                (\op acc ->
                    BE.encode (IrSection.encodeFuncOp encDialectReg encAttrTable op) :: acc
                )
                st.encodedOps
                ops
    in
    StreamTables
        { stringTable = newStringTable
        , dialectBuilder = newDialectBuilder
        , attrAccum = newAttrAccum
        , encodedOps = newEncodedOps
        , numOps = st.numOps + List.length ops
        }


{-| Assemble the final bytecode from completed stream tables.
Finalizes all tables, builds the module structure, and produces the output bytes.
-}
assembleModule : StreamTables -> Loc -> Bytes
assembleModule (StreamTables st) moduleLoc =
    let
        -- Finalize tables
        stringTable =
            st.stringTable

        dialectRegistry =
            finalizeDialectBuilder st.dialectBuilder

        attrTypeTable =
            AttrType.finalizeStreamAccum st.attrAccum

        -- Encode table sections
        stringSectionBody =
            StringTable.encode stringTable

        dialectSectionBody =
            DialectSection.encode stringTable dialectRegistry

        ( attrTypeSectionBody, attrTypeOffsetSectionBody ) =
            AttrType.encodeDataAndOffsets stringTable dialectRegistry attrTypeTable

        -- Encode IR section
        irSectionBody =
            assembleIrSection dialectRegistry attrTypeTable st.numOps (List.reverse st.encodedOps) moduleLoc
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


bytecodeVersion : Int
bytecodeVersion =
    4



-- ==== IR Section Assembly ====


{-| Assemble the IR section from pre-encoded op bytes.
Wraps everything in a builtin.module op with an isolated region.
-}
assembleIrSection : DialectRegistry -> AttrTypeTable -> Int -> List Bytes -> Loc -> BE.Encoder
assembleIrSection dialectReg attrTypeTable numOps encodedOps moduleLoc =
    let
        -- Module block header: 1 op (the module op), no block args
        blockHeader =
            encodeVarInt (Bitwise.shiftLeftBy 1 1)

        -- Module op encoding
        moduleNameIdx =
            DialectSection.opIndex "builtin.module" dialectReg

        moduleLocIdx =
            AttrType.locIndex moduleLoc attrTypeTable

        -- regionEncoding: (numRegions << 1) | isIsolated = (1 << 1) | 1 = 3
        regionEncoding =
            encodeVarInt (Bitwise.or (Bitwise.shiftLeftBy 1 1) 1)

        -- Region content: 1 block, 0 values, block with all ops
        bodyBlockHeader =
            encodeVarInt (Bitwise.shiftLeftBy 1 numOps)

        regionContent =
            BE.encode <|
                BE.sequence
                    (encodeVarInt 1
                        :: encodeVarInt 0
                        :: bodyBlockHeader
                        :: List.map BE.bytes encodedOps
                    )

        regionSection =
            Section.encodeSection Section.sectionId.ir (BE.bytes regionContent)
    in
    BE.sequence
        [ blockHeader
        , encodeVarInt moduleNameIdx
        , BE.unsignedInt8 0x10 -- kHasInlineRegions
        , encodeVarInt moduleLocIdx
        , regionEncoding
        , regionSection
        ]



-- ==== Streaming Dialect Builder ====
-- Assigns op indices in insertion order for stable, append-only indices.


type StreamDialectBuilder
    = StreamDialectBuilder
        { dialectList : List String -- reverse insertion order
        , dialectSet : Dict String Int
        , numDialects : Int
        , opEntries : List { dialectIdx : Int, opSuffix : String } -- reverse insertion order
        , opSet : Dict String Int -- fullName -> global index
        , nextOpIndex : Int
        }


emptyDialectBuilder : StreamDialectBuilder
emptyDialectBuilder =
    StreamDialectBuilder
        { dialectList = []
        , dialectSet = Dict.empty
        , numDialects = 0
        , opEntries = []
        , opSet = Dict.empty
        , nextOpIndex = 0
        }


addDialectOp : String -> StreamDialectBuilder -> StreamDialectBuilder
addDialectOp fullName (StreamDialectBuilder b) =
    case Dict.get fullName b.opSet of
        Just _ ->
            StreamDialectBuilder b

        Nothing ->
            case String.split "." fullName of
                dialect :: rest ->
                    let
                        suffix =
                            String.join "." rest

                        dIdx =
                            Dict.get dialect b.dialectSet |> Maybe.withDefault b.numDialects

                        isNewDialect =
                            not (Dict.member dialect b.dialectSet)
                    in
                    StreamDialectBuilder
                        { dialectList =
                            if isNewDialect then
                                dialect :: b.dialectList

                            else
                                b.dialectList
                        , dialectSet =
                            if isNewDialect then
                                Dict.insert dialect b.numDialects b.dialectSet

                            else
                                b.dialectSet
                        , numDialects =
                            if isNewDialect then
                                b.numDialects + 1

                            else
                                b.numDialects
                        , opEntries = { dialectIdx = dIdx, opSuffix = suffix } :: b.opEntries
                        , opSet = Dict.insert fullName b.nextOpIndex b.opSet
                        , nextOpIndex = b.nextOpIndex + 1
                        }

                _ ->
                    StreamDialectBuilder b


dialectOpMap : StreamDialectBuilder -> Dict String Int
dialectOpMap (StreamDialectBuilder b) =
    b.opSet


finalizeDialectBuilder : StreamDialectBuilder -> DialectRegistry
finalizeDialectBuilder (StreamDialectBuilder b) =
    let
        dialects =
            List.reverse b.dialectList

        entries =
            List.reverse b.opEntries

        opGroups =
            buildRunLengthOpGroups entries
    in
    DialectSection.buildRegistry
        { dialects = dialects
        , dialectIndices = b.dialectSet
        , opGroups = opGroups
        , opIndexMap = b.opSet
        }


buildRunLengthOpGroups : List { dialectIdx : Int, opSuffix : String } -> List DialectSection.OpGroup
buildRunLengthOpGroups entries =
    case entries of
        [] ->
            []

        first :: rest ->
            let
                ( groupNames, remaining ) =
                    spanByDialect first.dialectIdx [ first.opSuffix ] rest
            in
            { dialectIdx = first.dialectIdx, opNames = groupNames }
                :: buildRunLengthOpGroups remaining


spanByDialect : Int -> List String -> List { dialectIdx : Int, opSuffix : String } -> ( List String, List { dialectIdx : Int, opSuffix : String } )
spanByDialect dIdx acc entries =
    case entries of
        [] ->
            ( List.reverse acc, [] )

        e :: rest ->
            if e.dialectIdx == dIdx then
                spanByDialect dIdx (e.opSuffix :: acc) rest

            else
                ( List.reverse acc, entries )



-- ==== Walk ops for dialect op names ====


walkOpForDialects : MlirOp -> StreamDialectBuilder -> StreamDialectBuilder
walkOpForDialects op builder =
    let
        b1 =
            addDialectOp op.name builder

        b2 =
            List.foldl walkRegionForDialects b1 op.regions
    in
    b2


walkRegionForDialects : MlirRegion -> StreamDialectBuilder -> StreamDialectBuilder
walkRegionForDialects (MlirRegion r) builder =
    let
        b1 =
            walkBlockForDialects r.entry builder
    in
    OrderedDict.foldl (\_ blk acc -> walkBlockForDialects blk acc) b1 r.blocks


walkBlockForDialects : MlirBlock -> StreamDialectBuilder -> StreamDialectBuilder
walkBlockForDialects blk builder =
    let
        b1 =
            List.foldl walkOpForDialects builder blk.body
    in
    walkOpForDialects blk.terminator b1
