module Compiler.Generate.JavaScript.SourceMap exposing (generate)

{-| Builds the source map for a generated JavaScript program, so that a
debugger can show the Elm code each part of the program came from.

A source map, in the version 3 format written here, is a JSON document with a
list of `sources`, a list of `names`, and a `mappings` string. Here each source
is an Elm module, listed by its module name rather than a file path, and each
name is one that a mapping reports. The `mappings` string has one _group_ for
each line of the generated JavaScript, the groups separated by `;`. A group
holds one _segment_ for each mapped position on its line, separated by `,`. A
segment is four numbers, or five: the generated column, the index of the
source, the source line, the source column, and, when there is one, the index
of the name. All of them count from 0.

Each number in a segment is written as a delta: its difference from the same
number in the previous segment, or for the name index, the previous segment
that had a name. The generated column starts again from 0 on each new line; the
other four carry on across lines. The deltas of one segment are written
together by `VLQ.encode`, in the base64 variable-length quantity (VLQ) form the
format uses.

The input is the list of mappings that `Compiler.Generate.JavaScript.Builder`
records while printing. Their columns and source lines are taken to count from
1, and have 1 subtracted here; generated line 1 becomes the first group. Most
of this module is bookkeeping for the delta encoding: `Mappings` is the
document under construction, `SegmentAccounting` holds the previous segment's
numbers, and `OrderedListBuilder` numbers the sources and names in the order
they are first used.

The finished document is not written to a file of its own. `generate` returns
it as a comment holding a base64 `data:` URL, to be appended to the program.

@docs generate

-}

import Base64
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Generate.JavaScript.Builder as JS
import Compiler.Generate.JavaScript.Name as JSName
import Data.Map as DataMap
import Dict exposing (Dict)
import Json.Encode as Encode
import VLQ


{-| Returns the source map for a program as a newline followed by a
`//# sourceMappingURL=data:application/json;base64,` comment, ready to be
appended to the JavaScript.

`mappings` may be in any order; they are grouped by generated line and sorted
by column here. `leadingLines` and `kernelLeadingLines` are both added to every
mapping's generated line, and are treated alike. `moduleSources` holds the Elm
source text of each module, keyed by `ModuleName.toComparableCanonical`, and
fills the map's `sourcesContent`; a module with no entry there gets `null`.

-}
generate : Int -> Int -> DataMap.Dict String ModuleName.Canonical String -> List JS.Mapping -> String
generate leadingLines kernelLeadingLines moduleSources mappings =
    "\n"
        ++ "//# sourceMappingURL=data:application/json;base64,"
        ++ generateHelp leadingLines kernelLeadingLines moduleSources mappings


{-| Returns the base64 text of the source map for `generate`: the JSON,
indented by four spaces, of `mappings` once each generated line is shifted by
`leadingLines + kernelLeadingLines`.
-}
generateHelp : Int -> Int -> DataMap.Dict String ModuleName.Canonical String -> List JS.Mapping -> String
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


{-| A source map document under construction: the sources and names numbered
so far, the previous segment's numbers, and the `mappings` text written so far.
Its one constructor holds what `MappingsProps` describes.
-}
type Mappings
    = Mappings MappingsProps


{-| The parts of a `Mappings`. `vlqs` is the document's `mappings` string as
written so far, separators included.
-}
type alias MappingsProps =
    { sources : OrderedListBuilder String ModuleName.Canonical
    , names : OrderedListBuilder String JSName.Name
    , segmentAccounting : SegmentAccounting
    , vlqs : String
    }


{-| Builds a `Mappings` from its parts, given in the order of the fields of
`MappingsProps`.
-}
makeMappings : OrderedListBuilder String ModuleName.Canonical -> OrderedListBuilder String JSName.Name -> SegmentAccounting -> String -> Mappings
makeMappings sources names segmentAccounting vlqs =
    Mappings { sources = sources, names = names, segmentAccounting = segmentAccounting, vlqs = vlqs }


{-| The numbers of the last segment written, which the next segment is written
relative to.

A `Nothing` is read as 0, and every field starts as `Nothing`. `prevCol` is
set back to `Nothing` at the end of each generated line, so it is `Nothing`
exactly when no segment has yet been written on the current line, and the
next segment then needs no `,` before it. `prevNameIdx` is left as it is by a
segment without a name.

-}
type alias SegmentAccountingData =
    { prevCol : Maybe Int
    , prevSourceIdx : Maybe Int
    , prevSourceLine : Maybe Int
    , prevSourceCol : Maybe Int
    , prevNameIdx : Maybe Int
    }


{-| The state of the delta encoding between one segment and the next, holding
what `SegmentAccountingData` describes.
-}
type SegmentAccounting
    = SegmentAccounting SegmentAccountingData


{-| Builds the document's sources, names and `mappings` text from `mappings`,
whose generated lines must already be shifted.

It writes a group for every line from 1 to the highest generated line of any
mapping, an empty group where a line has none, and ends every group, the last
included, with `;`. A mapping on line 0 or below is not written, and with no
mappings the text is empty.

-}
parseMappings : List JS.Mapping -> Mappings
parseMappings mappings =
    let
        mappingMap : Dict Int (List JS.Mapping)
        mappingMap =
            List.foldr
                (\((JS.Mapping m) as mapping) acc ->
                    Dict.update m.genLine (mappingMapUpdater mapping) acc
                )
                Dict.empty
                mappings
    in
    makeMappings emptyOrderedListBuilder emptyOrderedListBuilder (SegmentAccounting { prevCol = Nothing, prevSourceIdx = Nothing, prevSourceLine = Nothing, prevSourceCol = Nothing, prevNameIdx = Nothing }) "" |> parseMappingsHelp 1 (Dict.keys mappingMap |> List.maximum |> Maybe.withDefault 0) mappingMap


{-| Puts `toInsert` at the front of a line's list of mappings, or starts the
list when the line has none, for use with `Dict.update`.
-}
mappingMapUpdater : JS.Mapping -> Maybe (List JS.Mapping) -> Maybe (List JS.Mapping)
mappingMapUpdater toInsert maybeVal =
    case maybeVal of
        Nothing ->
            Just [ toInsert ]

        Just existing ->
            Just (toInsert :: existing)


{-| Writes the groups for lines `currentLine` to `lastLine` onto `acc`, taking
each line's mappings from `mappingMap`. Within a line the segments are written
in ascending order of generated column.
-}
parseMappingsHelp : Int -> Int -> Dict Int (List JS.Mapping) -> Mappings -> Mappings
parseMappingsHelp currentLine lastLine mappingMap acc =
    if currentLine > lastLine then
        acc

    else
        case Dict.get currentLine mappingMap of
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


{-| Ends the current group with `;` and forgets the previous column, so that
the next line's first segment has no `,` before it and its column is written
from 0.
-}
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


{-| Appends the segment for one mapping to the document, numbering its module
and its name if they have not been seen before.

The generated column, source line and source column have 1 subtracted. The
segment has five numbers when the mapping has a name and four when it does
not, each written as its difference from the previous segment's, the name
index from the last segment that had a name.

-}
encodeSegment : JS.Mapping -> Mappings -> Mappings
encodeSegment (JS.Mapping segmentData) (Mappings props) =
    let
        (SegmentAccounting sa) =
            props.segmentAccounting

        newSources : OrderedListBuilder String ModuleName.Canonical
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



-- NUMBERING SOURCES AND NAMES


{-| A set of distinct values, each numbered from 0 in the order it was first
added. This is how sources and names get their indices in the document.

`k` is the type of the values, and `c` the comparable key each is filed under.
The same key function must be passed on every call, which nothing checks. Its
constructor holds the number the next new value will get, and each value's
number.

-}
type OrderedListBuilder c k
    = OrderedListBuilder Int (DataMap.Dict c k Int)


{-| A builder holding no values, whose first value will be numbered 0.
-}
emptyOrderedListBuilder : OrderedListBuilder c k
emptyOrderedListBuilder =
    OrderedListBuilder 0 DataMap.empty


{-| Adds `value` with the next number, or returns `builder` unchanged when a
value with the same key is already in it.
-}
insertIntoOrderedListBuilder : (k -> comparable) -> k -> OrderedListBuilder comparable k -> OrderedListBuilder comparable k
insertIntoOrderedListBuilder toComparable value ((OrderedListBuilder nextIndex values) as builder) =
    case DataMap.get toComparable value values of
        Just _ ->
            builder

        Nothing ->
            OrderedListBuilder (nextIndex + 1) (DataMap.insert toComparable value nextIndex values)


{-| Returns the number `value` was given, or `Nothing` if it has not been
added.
-}
lookupIndexOrderedListBuilder : (k -> comparable) -> k -> OrderedListBuilder comparable k -> Maybe Int
lookupIndexOrderedListBuilder toComparable value (OrderedListBuilder _ values) =
    DataMap.get toComparable value values


{-| Returns the values in order of their numbers, so that each value's position
in the list is its number. `keyComparison` has no effect.
-}
orderedListBuilderToList : OrderedListBuilder c k -> List k
orderedListBuilderToList (OrderedListBuilder _ values) =
    values
        |> DataMap.toList
        |> List.map (\( val, idx ) -> ( idx, val ))
        |> Dict.fromList
        |> Dict.values


{-| Returns the source map document for a finished `Mappings`, at version 3.

Each source is written as its bare module name, without its package, so two
modules with the same name from different packages appear as two sources of
the same name. Each `sourcesContent` entry is the module's text from
`moduleSources`, or `null` when it has none.

-}
mappingsToJson : DataMap.Dict String ModuleName.Canonical String -> Mappings -> Encode.Value
mappingsToJson moduleSources (Mappings props) =
    let
        moduleNames : List ModuleName.Canonical
        moduleNames =
            orderedListBuilderToList props.sources
    in
    Encode.object
        [ ( "version", Encode.int 3 )
        , ( "sources", Encode.list (\(ModuleName.Canonical _ name) -> Encode.string name) moduleNames )
        , ( "sourcesContent"
          , Encode.list
                (\moduleName ->
                    DataMap.get ModuleName.toComparableCanonical moduleName moduleSources
                        |> Maybe.map Encode.string
                        |> Maybe.withDefault Encode.null
                )
                moduleNames
          )
        , ( "names", Encode.list (\jsName -> Encode.string jsName) (orderedListBuilderToList props.names) )
        , ( "mappings", Encode.string props.vlqs )
        ]
