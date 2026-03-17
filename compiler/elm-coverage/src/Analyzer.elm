module Analyzer exposing (main)

import Coverage
import Dict exposing (Dict)
import Html.String as Html exposing (Html)
import Html.String.Attributes as Attr
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Markup
import Overview
import Service exposing (Service)
import Styles
import Util


{-| Output type containing the overview page, individual module pages, and CSS.
-}
type alias Output =
    { overview : String
    , modules : Dict String String
    , css : String
    }


main : Service Model
main =
    Service.create
        { handle = handle
        , emit = encodeOutput
        , receive = decodeModel
        }


encodeOutput : Output -> Encode.Value
encodeOutput output =
    Encode.object
        [ ( "overview", Encode.string output.overview )
        , ( "modules"
          , output.modules
                |> Dict.toList
                |> List.map (\( k, v ) -> ( k, Encode.string v ))
                |> Encode.object
          )
        , ( "css", Encode.string output.css )
        ]


handle : Service.Flags -> Model -> Output
handle flags model =
    case flags.format of
        Service.Html ->
            { overview = viewOverview flags.version model |> Html.toString 0
            , modules = viewModulesHtml flags.version model
            , css = Styles.cssContent
            }

        Service.Json ->
            { overview = viewOverviewJson model
            , modules = viewModulesJson model
            , css = ""
            }


decodeModel : Decoder Model
decodeModel =
    Decode.map2 Model
        (Decode.field "files"
            (Decode.keyValuePairs Decode.string |> Decode.map Dict.fromList)
        )
        (Decode.field "coverage" Coverage.regionsDecoder)


type alias Model =
    { inputs : Dict String String
    , moduleMap : Coverage.Map
    }


{-| Generate the overview page with links to individual module pages.
-}
viewOverview : Service.Version -> Model -> Html msg
viewOverview version model =
    [ overview model.moduleMap ]
        |> Styles.page "Coverage report" version 0


{-| Generate individual module pages as a Dict from module name to HTML string.
-}
viewModulesHtml : Service.Version -> Model -> Dict String String
viewModulesHtml version model =
    model.moduleMap
        |> Dict.toList
        |> List.filterMap
            (\( moduleName, coverageInfo ) ->
                Dict.get moduleName model.inputs
                    |> Maybe.map
                        (\source ->
                            ( moduleName
                            , Markup.filePage version moduleName coverageInfo source
                                |> Html.toString 0
                            )
                        )
            )
        |> Dict.fromList


{-| Generate individual module pages as a Dict from module name to JSON string.
-}
viewModulesJson : Model -> Dict String String
viewModulesJson model =
    model.moduleMap
        |> Dict.toList
        |> List.filterMap
            (\( moduleName, coverageInfo ) ->
                Dict.get moduleName model.inputs
                    |> Maybe.map
                        (\source ->
                            ( moduleName
                            , encodeModuleJson moduleName source coverageInfo
                                |> Encode.encode 2
                            )
                        )
            )
        |> Dict.fromList


{-| Generate overview JSON containing summary counts for all modules.
-}
viewOverviewJson : Model -> String
viewOverviewJson model =
    let
        moduleEntries =
            model.moduleMap
                |> Dict.toList
                |> List.map
                    (\( moduleName, coverageInfo ) ->
                        let
                            counts =
                                Overview.computeCounts emptyCountDict coverageInfo
                        in
                        Encode.object
                            [ ( "module", Encode.string moduleName )
                            , ( "totalComplexity", Encode.int (Coverage.totalComplexity coverageInfo) )
                            , ( "coverage", encodeCoverageCounts counts )
                            ]
                    )

        totals =
            model.moduleMap
                |> Dict.toList
                |> List.foldr
                    (\( _, coverageInfo ) acc ->
                        let
                            counts =
                                Overview.computeCounts emptyCountDict coverageInfo
                        in
                        Dict.foldl adjustTotals acc counts
                    )
                    Dict.empty
    in
    Encode.object
        [ ( "modules", Encode.list identity moduleEntries )
        , ( "totals", encodeCoverageCounts totals )
        ]
        |> Encode.encode 2


{-| Encode a single module's coverage data to JSON.
-}
encodeModuleJson : String -> String -> List Coverage.AnnotationInfo -> Encode.Value
encodeModuleJson moduleName _ coverageInfo =
    let
        counts =
            Overview.computeCounts emptyCountDict coverageInfo
    in
    Encode.object
        [ ( "module", Encode.string moduleName )
        , ( "totalComplexity", Encode.int (Coverage.totalComplexity coverageInfo) )
        , ( "coverage", encodeCoverageCounts counts )
        , ( "annotations", Encode.list encodeAnnotationInfo coverageInfo )
        ]


{-| Encode coverage counts (covered/total pairs) to JSON.
-}
encodeCoverageCounts : Dict String ( Int, Int ) -> Encode.Value
encodeCoverageCounts counts =
    Encode.object
        [ ( "declarations", encodeCoverageCount (Dict.get Coverage.declaration counts) )
        , ( "letDeclarations", encodeCoverageCount (Dict.get Coverage.letDeclaration counts) )
        , ( "lambdas", encodeCoverageCount (Dict.get Coverage.lambdaBody counts) )
        , ( "caseBranches", encodeCoverageCount (Dict.get Coverage.caseBranch counts) )
        , ( "ifBranches", encodeCoverageCount (Dict.get Coverage.ifElseBranch counts) )
        ]


encodeCoverageCount : Maybe ( Int, Int ) -> Encode.Value
encodeCoverageCount maybeCounts =
    case maybeCounts of
        Just ( covered, total ) ->
            Encode.object
                [ ( "covered", Encode.int covered )
                , ( "total", Encode.int total )
                ]

        Nothing ->
            Encode.object
                [ ( "covered", Encode.int 0 )
                , ( "total", Encode.int 0 )
                ]


{-| Encode a single annotation info to JSON.
-}
encodeAnnotationInfo : Coverage.AnnotationInfo -> Encode.Value
encodeAnnotationInfo ( region, annotation, count ) =
    let
        baseFields =
            [ ( "type", Encode.string (Coverage.annotationType annotation) )
            , ( "count", Encode.int count )
            , ( "from", encodePosition region.from )
            , ( "to", encodePosition region.to )
            ]

        extraFields =
            case annotation of
                Coverage.Declaration name complexity ->
                    [ ( "name", Encode.string name )
                    , ( "complexity", Encode.int complexity )
                    ]

                Coverage.LetDeclaration complexity ->
                    [ ( "complexity", Encode.int complexity ) ]

                Coverage.LambdaBody complexity ->
                    [ ( "complexity", Encode.int complexity ) ]

                Coverage.CaseBranch ->
                    []

                Coverage.IfElseBranch ->
                    []
    in
    Encode.object (baseFields ++ extraFields)


encodePosition : Coverage.Position -> Encode.Value
encodePosition ( line, column ) =
    Encode.object
        [ ( "line", Encode.int line )
        , ( "column", Encode.int column )
        ]


overview : Coverage.Map -> Html msg
overview moduleMap =
    let
        ( rows, totals ) =
            moduleMap
                |> Dict.toList
                |> List.foldr foldFile ( [], Dict.empty )
    in
    Html.table [ Attr.class "o" ]
        [ Html.thead [] [ Overview.heading totals ]
        , Html.tbody [] rows
        , Html.tfoot [] [ Overview.row (Html.text "total") totals ]
        ]


foldFile :
    ( String, List Coverage.AnnotationInfo )
    -> ( List (Html msg), Dict String ( Int, Int ) )
    -> ( List (Html msg), Dict String ( Int, Int ) )
foldFile ( moduleName, coverageInfo ) ( rows, totals ) =
    let
        counts : Dict String ( Int, Int )
        counts =
            Overview.computeCounts emptyCountDict coverageInfo

        name : Html msg
        name =
            Html.a
                [ Attr.href <| moduleToPath moduleName ]
                [ Html.text <|
                    "("
                        ++ (String.fromInt <| Coverage.totalComplexity coverageInfo)
                        ++ ")\u{00A0}"
                , Html.code [] [ Html.text moduleName ]
                ]
    in
    ( Overview.row name counts :: rows
    , Dict.foldl adjustTotals totals counts
    )


adjustTotals :
    String
    -> ( Int, Int )
    -> Dict String ( Int, Int )
    -> Dict String ( Int, Int )
adjustTotals coverageType counts =
    Dict.update coverageType
        (Maybe.map (Util.mapBoth (+) counts)
            >> Maybe.withDefault counts
            >> Just
        )


emptyCountDict : Dict String ( Int, Int )
emptyCountDict =
    [ Coverage.declaration
    , Coverage.letDeclaration
    , Coverage.lambdaBody
    , Coverage.caseBranch
    , Coverage.ifElseBranch
    ]
        |> List.foldl (\k -> Dict.insert k ( 0, 0 )) Dict.empty


{-| Convert module name to file path.
E.g., "Foo.Bar.Baz" -> "Foo/Bar/Baz.html"
-}
moduleToPath : String -> String
moduleToPath moduleName =
    (moduleName |> String.split "." |> String.join "/") ++ ".html"
