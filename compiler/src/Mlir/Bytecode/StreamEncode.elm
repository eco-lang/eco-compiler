module Mlir.Bytecode.StreamEncode exposing (StreamTables, emptyStreamTables, collectAndEncodeOps, assembleModule)

{-| Writes an MLIR bytecode file from operations handed over a batch at a time,
so that a program's operations need not all be held in memory at once: each
batch is encoded to bytes as soon as it is added, and only the bytes are kept.

MLIR bytecode refers to the operation names, attributes, types and locations
an operation uses, and to most strings, by their index in a table section near
the start of the file, rather than writing them where they are used.
The IR section, which holds the operations, comes after the tables. Encoding an
operation before the tables are complete is therefore safe only if every index
is _append-only_: a new entry takes the next free index, in the order entries
are first met, and an entry's index never changes after that. The string table
and the streaming attribute and type table work this way, as
`Mlir.Bytecode.StringTable` and `Mlir.Bytecode.AttrType.StreamAccum` describe.
This module numbers operation names the same way, and keeps these tables
together in `StreamTables`.

Append-only numbering shapes the dialect section. An operation name is a
_dialect_, the text before its first `.`, and a _suffix_, the rest, and the
section lists the names in _op groups_, each a dialect followed by suffixes of
that dialect's names. A name's index is its position across all the groups.
Names of different dialects may be met interleaved, so each run of
consecutive names of one dialect, in the order they were numbered, becomes a
group of its own, and a dialect may have several groups. That keeps every name
at the position it was numbered. The attribute and type offset section is
grouped in runs for the same reason, as
`Mlir.Bytecode.AttrType.finalizeStreamAccum` describes.

`emptyStreamTables` starts the tables, `collectAndEncodeOps` adds a batch, and
`assembleModule` writes the file. An operation is encoded only after every
operation of its batch has been collected into the tables. A lookup is not
checked: anything missing from the tables is written as the index -1, so the
file is corrupt rather than the encoding failing.

The file declares bytecode version 4. Its operations sit in one
`builtin.module` operation, whose single block holds every encoded operation in
the order they were added. The lengths that frame the IR section are computed
from the widths of the bytes already encoded.

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
import Mlir.Bytecode.VarInt exposing (encodeVarInt, varIntWidth)
import Mlir.Loc exposing (Loc)
import Mlir.Mlir
    exposing
        ( MlirBlock
        , MlirOp
        , MlirRegion(..)
        )
import OrderedDict



-- ==== Stream Tables (accumulator) ====


{-| The tables of a bytecode file being written a batch at a time, together
with the bytes of every operation encoded so far.

A value starts as `emptyStreamTables` and grows through `collectAndEncodeOps`.
Every index it has given out keeps its meaning as it grows, so the bytes it
holds are still right when `assembleModule` writes the tables they refer to.

-}
type StreamTables
    = StreamTables
        { stringTable : StringTable
        , dialectBuilder : StreamDialectBuilder
        , attrAccum : AttrType.StreamAccum
        , encodedOps : List Bytes -- newest first
        , numOps : Int
        }


{-| The tables before any operation is added.

They already hold the names the enclosing `builtin.module` operation needs,
since that operation is in no batch: the strings `builtin` and `module`, and
the operation name `builtin.module`, numbered 0 in a dialect `builtin`
numbered 0. They also hold `Mlir.Loc.unknown`.

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


{-| Adds `ops`, a batch of top-level operations, to the tables and encodes each
of them, keeping their bytes in order after those of earlier batches.

First the strings, operation names, attributes, types and locations of every
operation in the batch, and of the operations nested inside them, are added.
Then each operation is encoded, as `Mlir.Bytecode.IrSection.encodeFuncOp`
describes, against the tables as they stand once the whole batch is in them.

-}
collectAndEncodeOps : List MlirOp -> StreamTables -> StreamTables
collectAndEncodeOps ops (StreamTables st) =
    let
        newStringTable =
            List.foldl StringTable.collectOp st.stringTable ops

        newDialectBuilder =
            List.foldl walkOpForDialects st.dialectBuilder ops

        newAttrAccum =
            List.foldl AttrType.streamCollectOp st.attrAccum ops

        -- Lookup-only views of the updated tables: they answer indices but
        -- hold nothing to write.
        encDialectReg =
            DialectSection.registryFromOpMap (dialectOpMap newDialectBuilder)

        encAttrTable =
            AttrType.streamAccumEncodingView newAttrAccum

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


{-| Returns the whole bytecode file for every operation added to the tables,
held in a `builtin.module` operation whose location is `moduleLoc`.

The file is the header (the magic number, the version, and the producer name
`eco`), then the string, dialect, attribute and type, and attribute and type
offset sections, the IR section, and resource and resource offset sections that
declare no resources.

`moduleLoc` is looked up in the tables but not added to them. It is found if it
has the name and start of `Mlir.Loc.unknown`, which the tables always hold, or
of a location that some added operation carries, since
`Mlir.Bytecode.AttrType.locIndex` ignores a location's end; otherwise it is
written as -1.

-}
assembleModule : StreamTables -> Loc -> Bytes
assembleModule (StreamTables st) moduleLoc =
    let
        stringTable =
            st.stringTable

        dialectRegistry =
            finalizeDialectBuilder st.dialectBuilder

        attrTypeTable =
            AttrType.finalizeStreamAccum st.attrAccum

        stringSectionBody =
            StringTable.encode stringTable

        dialectSectionBody =
            DialectSection.encode stringTable dialectRegistry

        ( attrTypeSectionBody, attrTypeOffsetSectionBody ) =
            AttrType.encodeDataAndOffsets stringTable dialectRegistry attrTypeTable
    in
    BE.encode <|
        BE.sequence
            [ -- Magic number: "MLïR"
              BE.unsignedInt8 0x4D
            , BE.unsignedInt8 0x4C
            , BE.unsignedInt8 0xEF
            , BE.unsignedInt8 0x52
            , encodeVarInt bytecodeVersion

            -- Producer string, written inline and NUL-terminated
            , BE.string "eco"
            , BE.unsignedInt8 0x00
            , Section.encodeSection Section.sectionId.string stringSectionBody
            , Section.encodeSection Section.sectionId.dialect dialectSectionBody
            , Section.encodeSection Section.sectionId.attrType attrTypeSectionBody
            , Section.encodeSection Section.sectionId.attrTypeOffset attrTypeOffsetSectionBody
            , irSection dialectRegistry attrTypeTable st.numOps st.encodedOps moduleLoc

            -- Resource sections declaring no resources
            , Section.encodeSection Section.sectionId.resource (BE.sequence [])
            , Section.encodeSection Section.sectionId.resourceOffset (encodeVarInt 0)
            ]


{-| The version of the MLIR bytecode format that the file header declares.
-}
bytecodeVersion : Int
bytecodeVersion =
    4



-- ==== IR Section Assembly ====


{-| Creates an encoder for the whole IR section, id and length included: a
`builtin.module` operation located at `moduleLoc` whose one block holds the
operations already encoded in `encodedOpsNewestFirst`, written oldest first.
`numOps` must be the number of those operations.

The module operation has one isolated region, written in an IR section of its
own. The region has one block with no arguments, and is written as defining no
values, which is right only while none of the operations has results. Laid
out, the section is:

    u8 ir, varint irBodyLen,
        blockHeader, moduleNameIdx, 0x10, moduleLocIdx, regionEncoding,
        u8 ir, varint regionLen,
            varint 1, varint 0, bodyBlockHeader, op bytes...

Both lengths are worked out from `varIntWidth` and the widths of the operation
bytes, instead of by encoding the contents and measuring them as
`Mlir.Bytecode.Section.encodeSection` does. The bytes are those
`encodeSection` would write, since it puts nothing between a section's length
and its contents.

-}
irSection : DialectRegistry -> AttrTypeTable -> Int -> List Bytes -> Loc -> BE.Encoder
irSection dialectReg attrTypeTable numOps encodedOpsNewestFirst moduleLoc =
    let
        -- Block header (numOps << 1) | hasArgs: one op, the module, no arguments.
        blockHeaderValue =
            Bitwise.shiftLeftBy 1 1

        moduleNameIdx =
            DialectSection.opIndex "builtin.module" dialectReg

        moduleLocIdx =
            AttrType.locIndex moduleLoc attrTypeTable

        -- regionEncoding: (numRegions << 1) | isIsolated = (1 << 1) | 1 = 3
        regionEncodingValue =
            Bitwise.or (Bitwise.shiftLeftBy 1 1) 1

        -- The region's one block: every encoded op, no arguments.
        bodyBlockHeaderValue =
            Bitwise.shiftLeftBy 1 numOps

        -- Folding the newest-first list onto the front reverses it to oldest
        -- first.
        ( opEncoders, opsWidth ) =
            List.foldl
                (\b ( acc, w ) -> ( BE.bytes b :: acc, w + Bytes.width b ))
                ( [], 0 )
                encodedOpsNewestFirst

        regionLen =
            varIntWidth 1
                + varIntWidth 0
                + varIntWidth bodyBlockHeaderValue
                + opsWidth

        irBodyLen =
            varIntWidth blockHeaderValue
                + varIntWidth moduleNameIdx
                + 1
                + varIntWidth moduleLocIdx
                + varIntWidth regionEncodingValue
                + 1
                + varIntWidth regionLen
                + regionLen
    in
    BE.sequence
        [ BE.sequence
            [ -- IR section header
              BE.unsignedInt8 Section.sectionId.ir
            , encodeVarInt irBodyLen

            -- builtin.module op
            , encodeVarInt blockHeaderValue
            , encodeVarInt moduleNameIdx
            , BE.unsignedInt8 0x10 -- kHasInlineRegions
            , encodeVarInt moduleLocIdx
            , encodeVarInt regionEncodingValue

            -- Region section header + region content header
            , BE.unsignedInt8 Section.sectionId.ir
            , encodeVarInt regionLen
            , encodeVarInt 1 -- number of blocks
            , encodeVarInt 0 -- number of values the blocks define
            , encodeVarInt bodyBlockHeaderValue
            ]
        , BE.sequence opEncoders
        ]



-- ==== Streaming Dialect Builder ====


{-| The numbering of dialects and operation names for the dialect section,
built up as operations are met.

Each new dialect and each new operation name takes the next free index in its
own numbering, and an index never changes once given, so operations can be
encoded against `dialectOpMap` before every name is known. Each name's dialect
index and suffix are kept, newest first, for `finalizeDialectBuilder` to turn
into op groups.

-}
type StreamDialectBuilder
    = StreamDialectBuilder
        { dialectList : List String -- newest first
        , dialectSet : Dict String Int -- dialect -> its index
        , numDialects : Int
        , opEntries : List { dialectIdx : Int, opSuffix : String } -- newest first
        , opSet : Dict String Int -- full operation name -> its index
        , nextOpIndex : Int
        }


{-| A builder that has numbered no dialect and no operation name.
-}
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


{-| Numbers the operation named `fullName` with the next free operation index,
and its dialect with the next free dialect index if the dialect is new. A name
already numbered leaves the builder unchanged.

A name with no `.` is a dialect with an empty suffix, and keeps its index under
the name itself.

-}
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


{-| Returns every operation name numbered so far, written in full, with its
index.
-}
dialectOpMap : StreamDialectBuilder -> Dict String Int
dialectOpMap (StreamDialectBuilder b) =
    b.opSet


{-| Returns the registry the dialect section is written from: the dialects in
the order they were numbered, and the operation names in op groups, one for
each run of consecutive names of one dialect, so that each name's position in
the section is the index it was given.
-}
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


{-| Splits `entries` into op groups, one for each run of consecutive entries of
the same dialect, keeping their order. A dialect whose entries are interleaved
with another's gets one group per run.
-}
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


{-| Splits off the run at the head of `entries` whose dialect is `dIdx`.
Returns the suffixes of `acc`, which holds them newest first, followed by those
of the run, in order, and the entries left after the run.
-}
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


{-| Numbers the name of `op` and then those of the operations nested in its
regions.
-}
walkOpForDialects : MlirOp -> StreamDialectBuilder -> StreamDialectBuilder
walkOpForDialects op builder =
    let
        b1 =
            addDialectOp op.name builder
    in
    List.foldl walkRegionForDialects b1 op.regions


{-| Numbers the operation names in a region: its entry block first, then its
other blocks in their stored order.
-}
walkRegionForDialects : MlirRegion -> StreamDialectBuilder -> StreamDialectBuilder
walkRegionForDialects (MlirRegion r) builder =
    let
        b1 =
            walkBlockForDialects r.entry builder
    in
    OrderedDict.foldl (\_ blk acc -> walkBlockForDialects blk acc) b1 r.blocks


{-| Numbers the operation names in a block: its body in order, then its
terminator.
-}
walkBlockForDialects : MlirBlock -> StreamDialectBuilder -> StreamDialectBuilder
walkBlockForDialects blk builder =
    let
        b1 =
            List.foldl walkOpForDialects builder blk.body
    in
    walkOpForDialects blk.terminator b1
