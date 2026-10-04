module Mlir.Bytecode.IrSection exposing (encode, encodeFuncOp)

{-| An MLIR bytecode file keeps a program's operations in its IR section, and
this module writes them there, with the regions and blocks nested inside them.

In bytecode an operation does not name the SSA values it reads. It gives each
one's _value index_, a number that the reader works out for itself by counting
values as it reads them, so the encoder has to count them the same way or an
operand will point at the wrong value. It assumes MLIR's reader counts like
this:

  - Within one region, the values its blocks define are numbered one after
    another: the entry block's first, then each labelled block's in the order
    of `blocks`, and within a block its arguments, then the results of its
    operations in order. Regions nested inside those operations are not part
    of this count.
  - A region is _isolated_ when it cannot see values defined outside it. Its
    numbering starts at 0, and it is written inside an IR section of its own.
    Only the regions of `func.func` and `builtin.module` are treated as
    isolated.
  - Any other region carries on from where the numbering of the region around
    it stopped, after all of that region's values. Sibling regions of one
    operation, such as the two branches of an `scf.if`, each start from that
    same number.

So each region is handled in two passes. The first, `numberRegion`, builds its
_value environment_, the map from SSA name to value index. The second,
`encodeRegion`, writes the region using it. Because a region is numbered in
full before any of it is written, an operand may name a value defined later in
the region. A nested region is numbered only when the operation holding it is
written.

Blocks are referred to by _block index_ within their region: the entry block
is 0 and is called `bb0`, and the labelled blocks follow from 1.

Nothing here is checked. An operand name missing from the value environment
is written as -1, and a successor label that names no block as block 0. A
type, location, attribute dictionary or operation name the tables do not hold
is written as -1 too, as `Mlir.Bytecode.AttrType` and
`Mlir.Bytecode.DialectSection` describe. Either way the file is corrupt rather
than the encoding failing.

@docs encode, encodeFuncOp

-}

import Bitwise
import Bytes.Encode as BE
import Dict exposing (Dict)
import Mlir.Bytecode.AttrType as AttrType exposing (AttrTypeTable)
import Mlir.Bytecode.DialectSection as DialectSection exposing (DialectRegistry)
import Mlir.Bytecode.Section as Section
import Mlir.Bytecode.VarInt exposing (encodeVarInt)
import Mlir.Loc
import Mlir.Mlir
    exposing
        ( MlirBlock
        , MlirModule
        , MlirOp
        , MlirRegion(..)
        , MlirType
        )
import OrderedDict



-- ==== Encoding mask bits ====


{-| The bit of an operation's encoding mask saying that it has an attribute dictionary.
-}
kHasAttrs : Int
kHasAttrs =
    0x01


{-| The bit of an operation's encoding mask saying that it has results.
-}
kHasResults : Int
kHasResults =
    0x02


{-| The bit of an operation's encoding mask saying that it has operands.
-}
kHasOperands : Int
kHasOperands =
    0x04


{-| The bit of an operation's encoding mask saying that it has successors.
-}
kHasSuccessors : Int
kHasSuccessors =
    0x08


{-| The bit of an operation's encoding mask saying that it has regions.
-}
kHasInlineRegions : Int
kHasInlineRegions =
    0x10



-- ==== SSA Value Environment ====


{-| A value environment: the value index of each SSA name numbered so far, and
the index the next value numbered will get.
-}
type alias ValueEnv =
    { valueMap : Dict String Int
    , nextValueIndex : Int
    }


{-| A value environment with no names in it, whose numbering starts at 0.
-}
emptyValueEnv : ValueEnv
emptyValueEnv =
    { valueMap = Dict.empty
    , nextValueIndex = 0
    }


{-| Gives `name` the next value index in `env`.

The index is used up even when `name` already has one, and `name` then refers
to the new index.

-}
registerValue : String -> ValueEnv -> ValueEnv
registerValue name env =
    { valueMap = Dict.insert name env.nextValueIndex env.valueMap
    , nextValueIndex = env.nextValueIndex + 1
    }


{-| Returns the value index of `name` in `env`, or -1 if it has none.
-}
lookupValue : String -> ValueEnv -> Int
lookupValue name env =
    case Dict.get name env.valueMap of
        Just idx ->
            idx

        Nothing ->
            -1


{-| Gives each of the named values in `pairs` the next value index in `env`,
in list order. The types are ignored.
-}
registerValues : List ( String, MlirType ) -> ValueEnv -> ValueEnv
registerValues pairs env =
    List.foldl (\( name, _ ) acc -> registerValue name acc) env pairs



-- ==== Pass 1: Value Numbering ====


{-| Returns `env` extended with value indices for every value defined in the
blocks of a region, numbered on from `env`'s next index: the entry block, then
the labelled blocks in order.

The regions nested inside the region's operations are not numbered.

-}
numberRegion : ValueEnv -> MlirRegion -> ValueEnv
numberRegion env (MlirRegion r) =
    let
        env1 =
            numberBlock env r.entry
    in
    OrderedDict.foldl (\_ blk acc -> numberBlock acc blk) env1 r.blocks


{-| Returns `env` extended with value indices for a block's arguments, then for
the results of its operations in order, ending with its terminator.

Operations in `body` whose `isTerminator` is set are skipped, as they are when
the block is written.

-}
numberBlock : ValueEnv -> MlirBlock -> ValueEnv
numberBlock env blk =
    let
        env1 =
            registerValues blk.args env

        nonTermBody =
            List.filter (\op -> not op.isTerminator) blk.body

        env2 =
            List.foldl numberOp env1 nonTermBody
    in
    numberOp blk.terminator env2


{-| Returns `env` extended with value indices for the results of `op`.
-}
numberOp : MlirOp -> ValueEnv -> ValueEnv
numberOp op env =
    registerValues op.results env



-- ==== Block index environment ====


{-| The block index of each block of one region, by label, with the entry block
under `bb0`.
-}
type alias BlockEnv =
    Dict String Int


{-| Returns the block indices of a region: 0 for the entry block, as `bb0`, then
1, 2, ... for the labelled blocks in the order of `blocks`.

A labelled block that is itself called `bb0` takes that name over from the
entry block.

-}
buildBlockEnv : MlirRegion -> BlockEnv
buildBlockEnv (MlirRegion r) =
    let
        namedBlocks =
            OrderedDict.toList r.blocks

        indexed =
            namedBlocks
                |> List.indexedMap (\i ( label, _ ) -> ( label, i + 1 ))
    in
    Dict.fromList (( "bb0", 0 ) :: indexed)



-- ==== Pass 2: Encoding ====


{-| Creates an encoder for the contents of the IR section of a whole module,
without the section's own frame.

The module's operations are written as the single region of one `builtin.module`
operation, which is isolated and so is numbered from 0 and written in an IR
section of its own. The tables must already hold everything the module refers
to, `builtin.module` included.

-}
encode : DialectRegistry -> AttrTypeTable -> MlirModule -> BE.Encoder
encode dialectReg attrTypeTable mod =
    encodeModuleBlock dialectReg attrTypeTable mod


{-| Creates an encoder for the top level of the IR section: a block header
saying one operation and no arguments, then the `builtin.module` operation.
-}
encodeModuleBlock : DialectRegistry -> AttrTypeTable -> MlirModule -> BE.Encoder
encodeModuleBlock dialectReg attrTypeTable mod =
    let
        blockHeader =
            Bitwise.shiftLeftBy 1 1
    in
    BE.sequence
        [ encodeVarInt blockHeader
        , encodeModuleOp dialectReg attrTypeTable mod
        ]


{-| Creates an encoder for the `builtin.module` operation that holds the module's
operations.

It has no attributes, results, operands or successors. When the module has
operations, it has one isolated region holding them, numbered from 0 and written
in a nested IR section. A module with no operations is written with no region.

-}
encodeModuleOp : DialectRegistry -> AttrTypeTable -> MlirModule -> BE.Encoder
encodeModuleOp dialectReg attrTypeTable mod =
    let
        nameIdx =
            DialectSection.opIndex "builtin.module" dialectReg

        locIdx =
            AttrType.locIndex mod.loc attrTypeTable

        hasRegions =
            not (List.isEmpty mod.body)

        encodingMask =
            if hasRegions then
                kHasInlineRegions

            else
                0

        regionEncoding =
            Bitwise.or (Bitwise.shiftLeftBy 1 1) 1

        region =
            moduleBodyRegion mod

        numberedEnv =
            numberRegion emptyValueEnv region

        moduleRegionEncoder =
            encodeRegion dialectReg attrTypeTable numberedEnv region

        moduleRegionSection =
            Section.encodeSection Section.sectionId.ir moduleRegionEncoder
    in
    BE.sequence
        ([ encodeVarInt nameIdx
         , BE.unsignedInt8 encodingMask
         , encodeVarInt locIdx
         ]
            ++ (if hasRegions then
                    [ encodeVarInt regionEncoding
                    , moduleRegionSection
                    ]

                else
                    []
               )
        )


{-| Returns a region of one block, with no arguments, holding the module's
operations in order.

The last operation becomes the block's terminator, whatever its `isTerminator`.
An earlier operation whose `isTerminator` is set is skipped when the block is
numbered and written. For a module with no operations the terminator is a
placeholder `builtin.unrealized_cast`, which `encodeModuleOp` never writes,
since it writes no region for an empty module.

-}
moduleBodyRegion : MlirModule -> MlirRegion
moduleBodyRegion mod =
    let
        ( bodyOps, termOp ) =
            case List.reverse mod.body of
                [] ->
                    ( []
                    , { name = "builtin.unrealized_cast"
                      , id = ""
                      , operands = []
                      , results = []
                      , attrs = Dict.empty
                      , regions = []
                      , isTerminator = True
                      , loc = Mlir.Loc.unknown
                      , successors = []
                      }
                    )

                last :: rest ->
                    ( List.reverse rest, last )
    in
    MlirRegion
        { entry =
            { args = []
            , body = bodyOps
            , terminator = termOp
            }
        , blocks = OrderedDict.empty
        }


{-| Creates an encoder for a region, given `valueEnv`, its value environment,
which must already number every value the region's blocks define.

It writes the number of blocks, the number of values the region's blocks
define, then the entry block and the labelled blocks in order. Successors are
resolved against this region's blocks.

-}
encodeRegion : DialectRegistry -> AttrTypeTable -> ValueEnv -> MlirRegion -> BE.Encoder
encodeRegion dialectReg attrTypeTable valueEnv (MlirRegion r) =
    let
        namedBlocks =
            OrderedDict.toList r.blocks

        numBlocks =
            1 + List.length namedBlocks

        blockEnv =
            buildBlockEnv (MlirRegion r)

        numValues =
            countRegionValues (MlirRegion r)

        entryEncoder =
            encodeBlock dialectReg attrTypeTable valueEnv blockEnv r.entry

        namedEncoders =
            namedBlocks
                |> List.map (\( _, blk ) -> encodeBlock dialectReg attrTypeTable valueEnv blockEnv blk)
    in
    if numBlocks == 0 then
        encodeVarInt 0

    else
        BE.sequence
            (encodeVarInt numBlocks
                :: encodeVarInt numValues
                :: entryEncoder
                :: namedEncoders
            )


{-| Creates an encoder for a block: a header giving its number of operations
and whether it has arguments, the arguments if it has any, then its operations.

The operations written are those of `body` whose `isTerminator` is not set,
followed by `terminator`.

-}
encodeBlock : DialectRegistry -> AttrTypeTable -> ValueEnv -> BlockEnv -> MlirBlock -> BE.Encoder
encodeBlock dialectReg attrTypeTable valueEnv blockEnv blk =
    let
        hasBlockArgs =
            not (List.isEmpty blk.args)

        -- A terminator may also be in body; it is written once, as terminator.
        allOps =
            List.filter (\op -> not op.isTerminator) blk.body ++ [ blk.terminator ]

        numOps =
            List.length allOps

        blockHeader =
            Bitwise.or
                (Bitwise.shiftLeftBy 1 numOps)
                (if hasBlockArgs then
                    1

                 else
                    0
                )

        blockArgsEncoder =
            if hasBlockArgs then
                encodeBlockArgs attrTypeTable blk.args

            else
                BE.sequence []

        opEncoders =
            allOps
                |> List.map (encodeOp dialectReg attrTypeTable valueEnv blockEnv)
    in
    BE.sequence
        (encodeVarInt blockHeader
            :: blockArgsEncoder
            :: opEncoders
        )


{-| Creates an encoder for a block's arguments: their number, then each one's
type index with a flag saying a location follows, and the index of the unknown
location, then a zero byte.

Every argument gets the unknown location. The zero byte is written after the
arguments in every case; this module assumes the reader takes it as saying the
block has no use-list orders.

-}
encodeBlockArgs : AttrTypeTable -> List ( String, MlirType ) -> BE.Encoder
encodeBlockArgs attrTypeTable args =
    let
        numArgs =
            List.length args

        argEncoders =
            args
                |> List.map
                    (\( _, ty ) ->
                        let
                            tyIdx =
                                AttrType.typeIndex ty attrTypeTable

                            typeAndLoc =
                                Bitwise.or (Bitwise.shiftLeftBy 1 tyIdx) 1

                            locIdx =
                                AttrType.locIndex Mlir.Loc.unknown attrTypeTable
                        in
                        BE.sequence
                            [ encodeVarInt typeAndLoc
                            , encodeVarInt locIdx
                            ]
                    )
    in
    BE.sequence
        (encodeVarInt numArgs
            :: argEncoders
            ++ [ BE.unsignedInt8 0 ]
        )


{-| Creates an encoder for `op`, given `valueEnv`, the value environment of the
region it is in, and `blockEnv`, the block indices of that region.

It writes the operation name's index, an encoding mask byte saying which of
the optional parts follow, and the location's index. Then come those parts that
are present, in this order: the index of the attribute dictionary, after
`Mlir.Bytecode.AttrType.bytecodeAttrs`; the number of results and each result's
type index; the number of operands and each one's value index; the number of
successors and each one's block index, looked up with one leading `^` removed;
and the regions.

The regions start with one number holding their count shifted left one bit,
with the low bit set when they are isolated, which is decided by the
operation's name. An isolated region is numbered from 0 and wrapped in an IR
section of its own. Every other region is numbered on from `valueEnv`, each
separately, so siblings start from the same index and see the names in
`valueEnv` but not each other's values.

-}
encodeOp : DialectRegistry -> AttrTypeTable -> ValueEnv -> BlockEnv -> MlirOp -> BE.Encoder
encodeOp dialectReg attrTypeTable valueEnv blockEnv op =
    let
        nameIdx =
            DialectSection.opIndex op.name dialectReg

        locIdx =
            AttrType.locIndex op.loc attrTypeTable

        -- Collection records the dictionary after bytecodeAttrs; one still
        -- holding _operand_types would not be found and would give -1.
        attrs =
            AttrType.bytecodeAttrs op.attrs

        hasAttrs =
            not (Dict.isEmpty attrs)

        hasResults =
            not (List.isEmpty op.results)

        hasOperands =
            not (List.isEmpty op.operands)

        hasSuccessors =
            not (List.isEmpty op.successors)

        hasRegions =
            not (List.isEmpty op.regions)

        encodingMask =
            (if hasAttrs then
                kHasAttrs

             else
                0
            )
                |> Bitwise.or
                    (if hasResults then
                        kHasResults

                     else
                        0
                    )
                |> Bitwise.or
                    (if hasOperands then
                        kHasOperands

                     else
                        0
                    )
                |> Bitwise.or
                    (if hasSuccessors then
                        kHasSuccessors

                     else
                        0
                    )
                |> Bitwise.or
                    (if hasRegions then
                        kHasInlineRegions

                     else
                        0
                    )

        attrEncoder =
            if hasAttrs then
                [ encodeVarInt (AttrType.dictAttrIndex attrs attrTypeTable) ]

            else
                []

        resultsEncoder =
            if hasResults then
                let
                    numResults =
                        List.length op.results

                    typeEncoders =
                        op.results
                            |> List.map (\( _, t ) -> encodeVarInt (AttrType.typeIndex t attrTypeTable))
                in
                encodeVarInt numResults :: typeEncoders

            else
                []

        operandsEncoder =
            if hasOperands then
                let
                    numOperands =
                        List.length op.operands

                    valEncoders =
                        op.operands
                            |> List.map (\name -> encodeVarInt (lookupValue name valueEnv))
                in
                encodeVarInt numOperands :: valEncoders

            else
                []

        successorsEncoder =
            if hasSuccessors then
                let
                    numSuccessors =
                        List.length op.successors

                    succEncoders =
                        op.successors
                            |> List.map
                                (\label ->
                                    let
                                        cleanLabel =
                                            if String.startsWith "^" label then
                                                String.dropLeft 1 label

                                            else
                                                label

                                        blockIdx =
                                            Dict.get cleanLabel blockEnv
                                                |> Maybe.withDefault 0
                                    in
                                    encodeVarInt blockIdx
                                )
                in
                encodeVarInt numSuccessors :: succEncoders

            else
                []

        regionsEncoder =
            if hasRegions then
                let
                    numRegions =
                        List.length op.regions

                    isIsolated =
                        isIsolatedOp op.name

                    regionEncoding =
                        Bitwise.or
                            (Bitwise.shiftLeftBy 1 numRegions)
                            (if isIsolated then
                                1

                             else
                                0
                            )

                    regionBaseEnv =
                        valueEnv

                    regionEncoders =
                        op.regions
                            |> List.map
                                (\region ->
                                    if isIsolated then
                                        let
                                            isoEnv =
                                                numberRegion emptyValueEnv region
                                        in
                                        Section.encodeSection Section.sectionId.ir
                                            (encodeRegion dialectReg attrTypeTable isoEnv region)

                                    else
                                        let
                                            altEnv =
                                                numberRegion regionBaseEnv region
                                        in
                                        encodeRegion dialectReg attrTypeTable altEnv region
                                )
                in
                encodeVarInt regionEncoding :: regionEncoders

            else
                []
    in
    BE.sequence
        ([ encodeVarInt nameIdx
         , BE.unsignedInt8 encodingMask
         , encodeVarInt locIdx
         ]
            ++ attrEncoder
            ++ resultsEncoder
            ++ operandsEncoder
            ++ successorsEncoder
            ++ regionsEncoder
        )


{-| Creates an encoder for one operation of a module's top level, such as a
`func.func`, on its own, so that a module can be written one operation at a
time.

The operation is encoded with an empty value environment and no block
indices. An isolated region inside it, such as a `func.func`'s body, is
numbered from 0 as usual, but an operand of the operation itself is written as
-1 and a successor as block 0.

-}
encodeFuncOp : DialectRegistry -> AttrTypeTable -> MlirOp -> BE.Encoder
encodeFuncOp dialectReg attrTypeTable op =
    encodeOp dialectReg attrTypeTable emptyValueEnv Dict.empty op


{-| Tells whether an operation with the given name is treated as having
isolated regions: true only for `func.func` and `builtin.module`.
-}
isIsolatedOp : String -> Bool
isIsolatedOp name =
    name == "func.func" || name == "builtin.module"


{-| Returns the number of values defined in a region's blocks: block arguments
and operation results, skipping operations in `body` whose `isTerminator` is
set, as numbering does. Values defined in nested regions are not counted.
-}
countRegionValues : MlirRegion -> Int
countRegionValues (MlirRegion r) =
    let
        countBlock blk =
            List.length blk.args
                + List.foldl (\op acc -> acc + List.length op.results)
                    0
                    (List.filter (\op -> not op.isTerminator) blk.body)
                + List.length blk.terminator.results
    in
    countBlock r.entry
        + (OrderedDict.toList r.blocks
            |> List.foldl (\( _, blk ) acc -> acc + countBlock blk) 0
          )
