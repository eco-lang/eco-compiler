module Markup exposing (file, filePage)

import Coverage
import Dict exposing (Dict)
import Html.String as Html exposing (Html)
import Html.String.Attributes as Attr
import Overview
import Service
import Source
import Styles
import Util


file : String -> List Coverage.AnnotationInfo -> String -> Html msg
file moduleName coverageInfo source =
    let
        rendered =
            Source.render source coverageInfo
                |> render
                |> foldRendered (moduleToId moduleName)
    in
    Html.div [ Attr.class "f" ]
        [ Html.h2 [ Attr.id <| moduleToId moduleName ]
            [ Html.text "Module: "
            , Html.code [] [ Html.text moduleName ]
            , Html.a [ Attr.class "t", Attr.href "#top" ] [ Html.text "▲" ]
            ]
        , listDeclarations (moduleToId moduleName) coverageInfo
        , Html.p [ Attr.class "g" ]
            [ Html.text "Declarations sorted by cyclomatic complexity" ]
        , Html.div [ Attr.class "c" ]
            [ Html.div [ Attr.class "l" ] rendered.lines
            , Html.div [ Attr.class "s" ] rendered.source
            ]
        ]


{-| Create a standalone HTML page for a single module.
-}
filePage : Service.Version -> String -> List Coverage.AnnotationInfo -> String -> Html msg
filePage version moduleName coverageInfo source =
    let
        rendered =
            Source.render source coverageInfo
                |> render
                |> foldRendered (moduleToId moduleName)

        depth =
            moduleDepth moduleName

        content =
            Html.div [ Attr.class "f" ]
                [ Html.h2 [ Attr.id <| moduleToId moduleName ]
                    [ Html.text "Module: "
                    , Html.code [] [ Html.text moduleName ]
                    , Html.a [ Attr.class "t", Attr.href "#top" ] [ Html.text "▲" ]
                    ]
                , listDeclarations (moduleToId moduleName) coverageInfo
                , Html.p [ Attr.class "g" ]
                    [ Html.text "Declarations sorted by cyclomatic complexity" ]
                , Html.div [ Attr.class "c" ]
                    [ Html.div [ Attr.class "l" ] rendered.lines
                    , Html.div [ Attr.class "s" ] rendered.source
                    ]
                ]
    in
    Styles.modulePage ("Coverage: " ++ moduleName) version depth [ content ]


{-| Calculate the depth of a module (number of dots in the name).
E.g., "Foo" = 0, "Foo.Bar" = 1, "Foo.Bar.Baz" = 2
-}
moduleDepth : String -> Int
moduleDepth moduleName =
    moduleName
        |> String.split "."
        |> List.length
        |> (\n -> n - 1)


moduleToId : String -> String
moduleToId =
    String.toLower >> String.split "." >> String.join "-"


listDeclarations : String -> List Coverage.AnnotationInfo -> Html msg
listDeclarations moduleId annotations =
    let
        ( rows, totals, complexities ) =
            topLevelDeclarationInfo [] [] annotations
                |> List.sortBy .complexity
                |> List.foldl (foldDeclarations moduleId) ( [], Dict.empty, [] )
    in
    Html.table [ Attr.class "o" ]
        [ Html.thead [] [ Overview.heading totals ]
        , Html.tbody [] rows
        , Html.tfoot []
            [ Overview.row
                (Html.text <|
                    "("
                        ++ String.fromInt (Coverage.totalComplexity annotations)
                        ++ ") total"
                )
                totals
            ]
        ]


type alias TopLevelDecl =
    { name : Coverage.Name
    , complexity : Coverage.Complexity
    , startLine : Int
    , children : List Coverage.AnnotationInfo
    }


topLevelDeclarationInfo :
    List TopLevelDecl
    -> List Coverage.AnnotationInfo
    -> List Coverage.AnnotationInfo
    -> List TopLevelDecl
topLevelDeclarationInfo acc children annotations =
    case annotations of
        [] ->
            List.reverse acc

        ( { from }, Coverage.Declaration name complexity, _ ) :: rest ->
            let
                decl : TopLevelDecl
                decl =
                    { name = name
                    , complexity = complexity
                    , startLine = Coverage.line from
                    , children = children
                    }
            in
            topLevelDeclarationInfo (decl :: acc) [] rest

        c :: rest ->
            topLevelDeclarationInfo acc (c :: children) rest


foldDeclarations :
    String
    -> TopLevelDecl
    -> ( List (Html msg), Dict String ( Int, Int ), List Coverage.Complexity )
    -> ( List (Html msg), Dict String ( Int, Int ), List Coverage.Complexity )
foldDeclarations moduleId declaration ( rows, totals, totalComplexity ) =
    let
        counts : Dict String ( Int, Int )
        counts =
            Overview.computeCounts emptyCountDict declaration.children

        adjustTotals :
            String
            -> ( Int, Int )
            -> Dict String ( Int, Int )
            -> Dict String ( Int, Int )
        adjustTotals coverageType innerCounts =
            Dict.update coverageType
                (Maybe.map (Util.mapBoth (+) innerCounts)
                    >> Maybe.withDefault innerCounts
                    >> Just
                )

        adjustedTotals : Dict String ( Int, Int )
        adjustedTotals =
            counts
                |> Dict.foldl adjustTotals totals

        declarationId : String
        declarationId =
            "#" ++ moduleId ++ "_" ++ String.fromInt declaration.startLine

        formattedName =
            Html.a
                [ Attr.href declarationId ]
                [ Html.text <| "(" ++ String.fromInt declaration.complexity ++ ")\u{00A0}"
                , Html.code [] [ Html.text declaration.name ]
                ]
    in
    ( Overview.row formattedName counts :: rows
    , adjustedTotals
    , declaration.complexity :: totalComplexity
    )


emptyCountDict : Dict String ( Int, Int )
emptyCountDict =
    [ Coverage.letDeclaration
    , Coverage.lambdaBody
    , Coverage.caseBranch
    , Coverage.ifElseBranch
    ]
        |> List.foldl (\k -> Dict.insert k ( 0, 0 )) Dict.empty


type alias Rendered msg =
    { lines : List (Html msg), source : List (Html msg) }


foldRendered : String -> List (Line msg) -> Rendered msg
foldRendered coverageId xs =
    xs
        |> Util.indexedFoldr
            (\idx (Line info content) ( lines, sources ) ->
                ( showLine coverageId (idx + 1) info :: lines
                , content :: sources
                )
            )
            ( [], [] )
        |> Tuple.mapSecond (Util.intercalate linebreak)
        |> (\( a, b ) -> Rendered a b)


showLine : String -> Int -> List Source.MarkerInfo -> Html msg
showLine coverageId lineNr info =
    let
        lineId : String
        lineId =
            coverageId ++ "_" ++ String.fromInt lineNr
    in
    Html.a [ Attr.href <| "#" ++ lineId, Attr.id lineId, Attr.class "n" ]
        [ Html.div []
            (Util.rFilterMap
                (.annotation >> Coverage.complexity >> Maybe.map indicator)
                info
                ++ [ Html.text <| String.fromInt lineNr ]
            )
        ]


{-| Render complexity indicator using opacity classes i0-i10.
-}
indicator : Coverage.Complexity -> Html msg
indicator complexity =
    let
        -- Map complexity 0-50 to opacity level 0-10
        level : Int
        level =
            complexity
                |> clamp 0 50
                |> toFloat
                |> (\c -> c / 50)
                |> sqrt
                |> (*) 10
                |> round
    in
    Html.span
        [ Attr.class ("i i" ++ String.fromInt level) ]
        [ Html.text " " ]


linebreak : Html msg
linebreak =
    Html.br [] []


render : List Source.Content -> List (Line msg)
render content =
    let
        initialAcc : ToHtmlAcc msg
        initialAcc =
            { lineSoFar = Line [] []
            , stack = []
            , lines = []
            }

        finalize : ToHtmlAcc msg -> List (Line msg)
        finalize { lineSoFar, lines } =
            lineSoFar :: lines
    in
    List.foldl contentToHtml initialAcc content
        |> finalize


type alias ToHtmlAcc msg =
    { lineSoFar : Line msg
    , stack : List Source.MarkerInfo
    , lines : List (Line msg)
    }


type Line msg
    = Line (List Source.MarkerInfo) (List (Html msg))


contentToHtml : Source.Content -> ToHtmlAcc msg -> ToHtmlAcc msg
contentToHtml content acc =
    case content of
        Source.Plain parts ->
            partsToHtml parts acc

        Source.Content marker parts ->
            List.foldl contentToHtml (pushStack marker acc) parts
                |> popStack


pushStack : Source.MarkerInfo -> ToHtmlAcc msg -> ToHtmlAcc msg
pushStack marker acc =
    { acc
        | stack = marker :: acc.stack
        , lineSoFar = addMarkerToLine marker acc.lineSoFar
    }


popStack : ToHtmlAcc msg -> ToHtmlAcc msg
popStack acc =
    case acc.stack of
        [] ->
            acc

        _ :: rest ->
            { acc | stack = rest }


partsToHtml : List Source.Part -> ToHtmlAcc msg -> ToHtmlAcc msg
partsToHtml parts acc =
    case parts of
        [] ->
            acc

        -- Empty part, just skip it
        (Source.Part "") :: rest ->
            partsToHtml rest acc

        (Source.Part s) :: rest ->
            tagAndAdd s acc
                |> partsToHtml rest

        Source.LineBreak :: rest ->
            newLine acc
                |> partsToHtml rest

        -- Empty part, useless markup to include, so skip it!
        (Source.Indented 0 "") :: rest ->
            partsToHtml rest acc

        (Source.Indented indent content) :: rest ->
            acc
                |> tagAndAdd content
                |> add (whitespace indent)
                |> partsToHtml rest


add : Html msg -> ToHtmlAcc msg -> ToHtmlAcc msg
add content acc =
    { acc | lineSoFar = addToLine content acc.lineSoFar }


addMarkerToLine : Source.MarkerInfo -> Line msg -> Line msg
addMarkerToLine marker (Line info content) =
    Line (marker :: info) content


tagAndAdd : String -> ToHtmlAcc msg -> ToHtmlAcc msg
tagAndAdd content acc =
    add (tagWith acc.stack content identity) acc


addToLine : Html msg -> Line msg -> Line msg
addToLine x (Line info xs) =
    Line info (x :: xs)


{-| We need to use this rather than inlining `wrapper << tagger` to prevent
a nasty variable shadowing bug.
-}
wrapTagger : Source.MarkerInfo -> (Html msg -> Html msg) -> Html msg -> Html msg
wrapTagger { count } tagger content =
    wrapper count <| tagger content


tagWith : List Source.MarkerInfo -> String -> (Html msg -> Html msg) -> Html msg
tagWith markers s tagger =
    case markers of
        [] ->
            tagger <| Html.text s

        marker :: rest ->
            -- Skip wrapping if parent has same coverage status (optimization #8)
            if shouldSkipWrapper marker rest then
                tagWith rest s tagger

            else
                tagWith rest s (wrapTagger marker tagger)


{-| Check if we should skip wrapping because parent has same coverage status.
This flattens nested spans like <span class="v"><span class="v">...</span></span>
-}
shouldSkipWrapper : Source.MarkerInfo -> List Source.MarkerInfo -> Bool
shouldSkipWrapper current stack =
    case stack of
        [] ->
            False

        parent :: _ ->
            -- Skip if both covered or both uncovered
            (current.count > 0 && parent.count > 0)
                || (current.count == 0 && parent.count == 0)


newLine : ToHtmlAcc msg -> ToHtmlAcc msg
newLine acc =
    { acc | lineSoFar = Line acc.stack [], lines = acc.lineSoFar :: acc.lines }


whitespace : Int -> Html msg
whitespace indent =
    Html.text <| String.repeat indent " "


{-| Wrapper span for coverage highlighting. No title attribute (optimization #5).
Uses short class names: v=covered, u=uncovered (optimization #2, #4).
-}
wrapper : Int -> Html msg -> Html msg
wrapper count content =
    Html.span
        [ Attr.class <| toClass count ]
        [ content ]


toClass : Int -> String
toClass cnt =
    if cnt == 0 then
        "u"

    else
        "v"
