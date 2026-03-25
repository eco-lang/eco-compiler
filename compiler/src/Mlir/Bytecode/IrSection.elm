module Mlir.Bytecode.IrSection exposing (encode, encodeFuncOp)

{-| IR section encoding for MLIR bytecode.

Encodes all operations, regions, and blocks in the bytecode IR format.
Uses a two-pass approach for SSA value numbering:

  - Pass 1 (numberRegion): Walk the IR to assign sequential value indices,
    matching MLIR's numbering algorithm where non-isolated region alternatives
    all start from the same base index.

  - Pass 2 (encodeRegion): Encode the IR using the pre-computed value indices.

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


kHasAttrs : Int
kHasAttrs =
    0x01


kHasResults : Int
kHasResults =
    0x02


kHasOperands : Int
kHasOperands =
    0x04


kHasSuccessors : Int
kHasSuccessors =
    0x08


kHasInlineRegions : Int
kHasInlineRegions =
    0x10



-- ==== SSA Value Environment ====


type alias ValueEnv =
    { valueMap : Dict String Int
    , nextValueIndex : Int
    }


emptyValueEnv : ValueEnv
emptyValueEnv =
    { valueMap = Dict.empty
    , nextValueIndex = 0
    }


registerValue : String -> ValueEnv -> ValueEnv
registerValue name env =
    { valueMap = Dict.insert name env.nextValueIndex env.valueMap
    , nextValueIndex = env.nextValueIndex + 1
    }


lookupValue : String -> ValueEnv -> Int
lookupValue name env =
    case Dict.get name env.valueMap of
        Just idx ->
            idx

        Nothing ->
            -1


registerValues : List ( String, MlirType ) -> ValueEnv -> ValueEnv
registerValues pairs env =
    List.foldl (\( name, _ ) acc -> registerValue name acc) env pairs



-- ==== Pass 1: Value Numbering ====
-- Walks the IR tree and assigns sequential value indices to all block args
-- and op results. For non-isolated regions (eco.case, scf.if, scf.while),
-- all alternatives start numbering from the SAME base index.


numberRegion : ValueEnv -> MlirRegion -> ValueEnv
numberRegion env (MlirRegion r) =
    let
        env1 =
            numberBlock env r.entry
    in
    OrderedDict.foldl (\_ blk acc -> numberBlock acc blk) env1 r.blocks


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


numberOp : MlirOp -> ValueEnv -> ValueEnv
numberOp op env =
    registerValues op.results env



-- ==== Block index environment ====


type alias BlockEnv =
    Dict String Int


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


{-| Encode the IR section for an MlirModule.
-}
encode : DialectRegistry -> AttrTypeTable -> MlirModule -> BE.Encoder
encode dialectReg attrTypeTable mod =
    encodeModuleBlock dialectReg attrTypeTable mod


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

        -- For isolated regions: number from scratch, then encode with that env
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


{-| Encode a region using a pre-computed ValueEnv.
The env already contains all value indices for this region.
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


{-| Encode a block using a pre-computed ValueEnv.
-}
encodeBlock : DialectRegistry -> AttrTypeTable -> ValueEnv -> BlockEnv -> MlirBlock -> BE.Encoder
encodeBlock dialectReg attrTypeTable valueEnv blockEnv blk =
    let
        hasBlockArgs =
            not (List.isEmpty blk.args)

        -- Filter out terminators from the body list. The codegen sometimes
        -- places terminator ops (eco.yield) in both body and terminator fields.
        -- The text printer skips body terminators; we must do the same.
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


{-| Encode a single operation using a pre-computed ValueEnv.
All operand lookups use the complete env — no forward reference issues.
-}
encodeOp : DialectRegistry -> AttrTypeTable -> ValueEnv -> BlockEnv -> MlirOp -> BE.Encoder
encodeOp dialectReg attrTypeTable valueEnv blockEnv op =
    let
        nameIdx =
            DialectSection.opIndex op.name dialectReg

        locIdx =
            AttrType.locIndex op.loc attrTypeTable

        hasAttrs =
            not (Dict.isEmpty op.attrs)

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
                [ encodeVarInt (AttrType.dictAttrIndex op.attrs attrTypeTable) ]

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

        -- Operands: look up in the pre-computed env (all values are known)
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

                    -- For non-isolated regions, each alternative gets the parent
                    -- env extended with its own values (numbered from the same base).
                    -- We number each alternative independently starting from valueEnv.
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
                                        -- Number this alternative from the parent base,
                                        -- producing an env with ONLY this alternative's values
                                        -- + the parent's values. No cross-alternative pollution.
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


{-| Encode a single top-level op (e.g. func.func) for streaming bytecode.
Top-level module-body ops have no parent ValueEnv or BlockEnv — isolated
regions get numbered from scratch inside encodeOp.
-}
encodeFuncOp : DialectRegistry -> AttrTypeTable -> MlirOp -> BE.Encoder
encodeFuncOp dialectReg attrTypeTable op =
    encodeOp dialectReg attrTypeTable emptyValueEnv Dict.empty op


isIsolatedOp : String -> Bool
isIsolatedOp name =
    name == "func.func" || name == "builtin.module"


{-| Count the number of values defined directly in a region's blocks.
Does NOT recurse into sub-regions — those have their own numValues
via the reader's push/pop stack.
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
