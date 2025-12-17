module Compiler.Generate.JavaScript.SourceMap exposing (generate)

{-| Source map generation for JavaScript output.

This module generates source maps conforming to the Source Map Revision 3 specification,
enabling browser developer tools to map generated JavaScript back to original Elm source
code. The source maps are generated as base64-encoded data URLs for embedding directly
in the generated JavaScript.

The implementation uses Variable Length Quantity (VLQ) encoding to efficiently represent
the mappings between generated and source positions. It tracks position deltas to minimize
the encoded size.


# Source Map Generation

@docs generate

-}

import Base64
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Generate.JavaScript.Builder as JS
import Compiler.Generate.JavaScript.Name as JSName
import Data.Map as Dict exposing (Dict)
import Json.Encode as Encode
import System.TypeCheck.IO as IO
import Utils.Main as Utils
import VLQ


generate : Int -> Int -> Dict (List String) IO.Canonical String -> List JS.Mapping -> String
generate leadingLines kernelLeadingLines moduleSources mappings =
    "\n"
        ++ "//# sourceMappingURL=data:application/json;base64,"
        ++ generateHelp leadingLines kernelLeadingLines moduleSources mappings


generateHelp : Int -> Int -> Dict (List String) IO.Canonical String -> List JS.Mapping -> String
generateHelp leadingLines kernelLeadingLines moduleSources mappings =
    mappings
        |> List.map
            (\(JS.Mapping m) ->
                JS.Mapping { m | genLine = m.genLine + leadingLines + kernelLeadingLines }
            )
        |> parseMappings
        |> mappingsToJson moduleSources
        |> Encode.encode 4
        |> Base64.encode


type Mappings
    = Mappings MappingsProps


type alias MappingsProps =
    { sources : OrderedListBuilder (List String) IO.Canonical
    , names : OrderedListBuilder String JSName.Name
    , segmentAccounting : SegmentAccounting
    , vlqs : String
    }


{-| Helper to construct Mappings with positional args
-}
makeMappings : OrderedListBuilder (List String) IO.Canonical -> OrderedListBuilder String JSName.Name -> SegmentAccounting -> String -> Mappings
makeMappings sources names segmentAccounting vlqs =
    Mappings { sources = sources, names = names, segmentAccounting = segmentAccounting, vlqs = vlqs }


type alias SegmentAccountingData =
    { prevCol : Maybe Int
    , prevSourceIdx : Maybe Int
    , prevSourceLine : Maybe Int
    , prevSourceCol : Maybe Int
    , prevNameIdx : Maybe Int
    }


type SegmentAccounting
    = SegmentAccounting SegmentAccountingData


parseMappings : List JS.Mapping -> Mappings
parseMappings mappings =
    let
        mappingMap : Dict Int Int (List JS.Mapping)
        mappingMap =
            List.foldr
                (\((JS.Mapping m) as mapping) acc ->
                    Dict.update identity m.genLine (mappingMapUpdater mapping) acc
                )
                Dict.empty
                mappings
    in
    makeMappings emptyOrderedListBuilder emptyOrderedListBuilder (SegmentAccounting { prevCol = Nothing, prevSourceIdx = Nothing, prevSourceLine = Nothing, prevSourceCol = Nothing, prevNameIdx = Nothing }) "" |> parseMappingsHelp 1 (Tuple.first (Utils.findMax compare mappingMap)) mappingMap


mappingMapUpdater : JS.Mapping -> Maybe (List JS.Mapping) -> Maybe (List JS.Mapping)
mappingMapUpdater toInsert maybeVal =
    case maybeVal of
        Nothing ->
            Just [ toInsert ]

        Just existing ->
            Just (toInsert :: existing)


parseMappingsHelp : Int -> Int -> Dict Int Int (List JS.Mapping) -> Mappings -> Mappings
parseMappingsHelp currentLine lastLine mappingMap acc =
    if currentLine > lastLine then
        acc

    else
        case Dict.get identity currentLine mappingMap of
            Nothing ->
                parseMappingsHelp (currentLine + 1)
                    lastLine
                    mappingMap
                    (prepareForNewLine acc)

            Just segments ->
                let
                    sortedSegments : List JS.Mapping
                    sortedSegments =
                        List.sortBy (\(JS.Mapping m) -> -m.genCol) segments
                in
                parseMappingsHelp (currentLine + 1)
                    lastLine
                    mappingMap
                    (prepareForNewLine (List.foldr encodeSegment acc sortedSegments))


prepareForNewLine : Mappings -> Mappings
prepareForNewLine (Mappings props) =
    let
        (SegmentAccounting sa) =
            props.segmentAccounting
    in
    makeMappings
        props.sources
        props.names
        (SegmentAccounting { sa | prevCol = Nothing })
        (props.vlqs ++ ";")


encodeSegment : JS.Mapping -> Mappings -> Mappings
encodeSegment (JS.Mapping segmentData) (Mappings props) =
    let
        (SegmentAccounting sa) =
            props.segmentAccounting

        newSources : OrderedListBuilder (List String) IO.Canonical
        newSources =
            insertIntoOrderedListBuilder ModuleName.toComparableCanonical segmentData.srcModule props.sources

        genCol : Int
        genCol =
            segmentData.genCol - 1

        moduleIdx : Int
        moduleIdx =
            Maybe.withDefault 0 (lookupIndexOrderedListBuilder ModuleName.toComparableCanonical segmentData.srcModule newSources)

        sourceLine : Int
        sourceLine =
            segmentData.srcLine - 1

        sourceCol : Int
        sourceCol =
            segmentData.srcCol - 1

        genColDelta : Int
        genColDelta =
            genCol - Maybe.withDefault 0 sa.prevCol

        moduleIdxDelta : Int
        moduleIdxDelta =
            moduleIdx - Maybe.withDefault 0 sa.prevSourceIdx

        sourceLineDelta : Int
        sourceLineDelta =
            sourceLine - Maybe.withDefault 0 sa.prevSourceLine

        sourceColDelta : Int
        sourceColDelta =
            sourceCol - Maybe.withDefault 0 sa.prevSourceCol

        updatedSa : SegmentAccounting
        updatedSa =
            SegmentAccounting { prevCol = Just genCol, prevSourceIdx = Just moduleIdx, prevSourceLine = Just sourceLine, prevSourceCol = Just sourceCol, prevNameIdx = sa.prevNameIdx }

        vlqPrefix : String
        vlqPrefix =
            case sa.prevCol of
                Nothing ->
                    ""

                Just _ ->
                    ","
    in
    case segmentData.srcName of
        Just segmentName ->
            let
                newNames : OrderedListBuilder JSName.Name JSName.Name
                newNames =
                    insertIntoOrderedListBuilder identity segmentName props.names

                nameIdx : Int
                nameIdx =
                    Maybe.withDefault 0 (lookupIndexOrderedListBuilder identity segmentName newNames)

                nameIdxDelta : Int
                nameIdxDelta =
                    nameIdx - Maybe.withDefault 0 sa.prevNameIdx
            in
            makeMappings newSources newNames (SegmentAccounting { prevCol = Just genCol, prevSourceIdx = Just moduleIdx, prevSourceLine = Just sourceLine, prevSourceCol = Just sourceCol, prevNameIdx = Just nameIdx }) <|
                props.vlqs
                    ++ vlqPrefix
                    ++ VLQ.encode
                        [ genColDelta
                        , moduleIdxDelta
                        , sourceLineDelta
                        , sourceColDelta
                        , nameIdxDelta
                        ]

        Nothing ->
            makeMappings newSources props.names updatedSa <|
                props.vlqs
                    ++ vlqPrefix
                    ++ VLQ.encode
                        [ genColDelta
                        , moduleIdxDelta
                        , sourceLineDelta
                        , sourceColDelta
                        ]



-- Array builder


type OrderedListBuilder c k
    = OrderedListBuilder Int (Dict c k Int)


emptyOrderedListBuilder : OrderedListBuilder c k
emptyOrderedListBuilder =
    OrderedListBuilder 0 Dict.empty


insertIntoOrderedListBuilder : (k -> comparable) -> k -> OrderedListBuilder comparable k -> OrderedListBuilder comparable k
insertIntoOrderedListBuilder toComparable value ((OrderedListBuilder nextIndex values) as builder) =
    case Dict.get toComparable value values of
        Just _ ->
            builder

        Nothing ->
            OrderedListBuilder (nextIndex + 1) (Dict.insert toComparable value nextIndex values)


lookupIndexOrderedListBuilder : (k -> comparable) -> k -> OrderedListBuilder comparable k -> Maybe Int
lookupIndexOrderedListBuilder toComparable value (OrderedListBuilder _ values) =
    Dict.get toComparable value values


orderedListBuilderToList : (k -> k -> Order) -> OrderedListBuilder c k -> List k
orderedListBuilderToList keyComparison (OrderedListBuilder _ values) =
    values
        |> Dict.toList keyComparison
        |> List.map (\( val, idx ) -> ( idx, val ))
        |> Dict.fromList identity
        |> Dict.values compare


mappingsToJson : Dict (List String) IO.Canonical String -> Mappings -> Encode.Value
mappingsToJson moduleSources (Mappings props) =
    let
        moduleNames : List IO.Canonical
        moduleNames =
            orderedListBuilderToList ModuleName.compareCanonical props.sources
    in
    Encode.object
        [ ( "version", Encode.int 3 )
        , ( "sources", Encode.list (\(IO.Canonical _ name) -> Encode.string name) moduleNames )
        , ( "sourcesContent"
          , Encode.list
                (\moduleName ->
                    Dict.get ModuleName.toComparableCanonical moduleName moduleSources
                        |> Maybe.map Encode.string
                        |> Maybe.withDefault Encode.null
                )
                moduleNames
          )
        , ( "names", Encode.list (\jsName -> Encode.string jsName) (orderedListBuilderToList compare props.names) )
        , ( "mappings", Encode.string props.vlqs )
        ]
