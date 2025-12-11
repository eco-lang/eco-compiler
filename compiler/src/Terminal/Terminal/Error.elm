module Terminal.Terminal.Error exposing
    ( exitWithError
    , exitWithHelp
    , exitWithOverview
    , exitWithUnknown
    )

import Compiler.Reporting.Suggest as Suggest
import Levenshtein
import List.Extra as List
import Prelude
import System.Exit as Exit
import System.IO as IO
import Task exposing (Task)
import Terminal.Terminal.Internal
    exposing
        ( ArgError(..)
        , Args(..)
        , Command(..)
        , CompleteArgs(..)
        , Error(..)
        , Expectation(..)
        , Flag(..)
        , FlagError(..)
        , Flags(..)
        , Parser(..)
        , RequiredArgs(..)
        , Summary(..)
        , toName
        )
import Text.PrettyPrint.ANSI.Leijen as P
import Utils.Main as Utils



-- EXIT


exitSuccess : List P.Doc -> Task Never a
exitSuccess =
    exitWith Exit.ExitSuccess


exitFailure : List P.Doc -> Task Never a
exitFailure =
    exitWith (Exit.ExitFailure 1)


exitWith : Exit.ExitCode -> List P.Doc -> Task Never a
exitWith code docs =
    IO.hIsTerminalDevice IO.stderr
        |> Task.andThen
            (\isTerminal ->
                let
                    adjust : P.Doc -> P.Doc
                    adjust =
                        if isTerminal then
                            identity

                        else
                            P.plain
                in
                P.displayIO IO.stderr
                    (P.renderPretty 1
                        80
                        (adjust (P.vcat (List.concatMap (\d -> [ d, P.text "" ]) docs)))
                    )
                    |> Task.andThen (\_ -> IO.hPutStrLn IO.stderr "")
                    |> Task.andThen (\_ -> Exit.exitWith code)
            )


getExeName : Task Never String
getExeName =
    Task.map Utils.fpTakeFileName Utils.envGetProgName


stack : List P.Doc -> P.Doc
stack docs =
    List.intersperse (P.text "") docs |> P.vcat


reflow : String -> P.Doc
reflow string =
    String.words string |> List.map P.text |> P.fillSep



-- HELP


exitWithHelp : Maybe String -> String -> P.Doc -> Args -> Flags -> Task Never a
exitWithHelp maybeCommand details example (Args args) flags =
    toCommand maybeCommand
        |> Task.andThen
            (\command ->
                exitSuccess <|
                    [ reflow details
                    , List.map (argsToDoc command) args |> P.vcat |> P.cyan |> P.indent 4
                    , example
                    ]
                        ++ (case flagsToDocs flags [] of
                                [] ->
                                    []

                                (_ :: _) as docs ->
                                    [ P.text "You can customize this command with the following flags:"
                                    , stack docs |> P.indent 4
                                    ]
                           )
            )


toCommand : Maybe String -> Task Never String
toCommand maybeCommand =
    getExeName
        |> Task.map
            (\exeName ->
                case maybeCommand of
                    Nothing ->
                        exeName

                    Just command ->
                        exeName ++ " " ++ command
            )


argsToDoc : String -> CompleteArgs -> P.Doc
argsToDoc command args =
    case args of
        Exactly required ->
            argsToDocHelp command required []

        Multiple required (Parser { plural }) ->
            argsToDocHelp command required [ "zero or more " ++ plural ]


argsToDocHelp : String -> RequiredArgs -> List String -> P.Doc
argsToDocHelp command args names =
    case args of
        Done ->
            (command :: List.map toToken names) |> List.map P.text |> P.hsep |> P.hang 4

        Required others (Parser { singular }) ->
            argsToDocHelp command others (singular :: names)


toToken : String -> String
toToken string =
    "<"
        ++ String.map
            (\c ->
                if c == ' ' then
                    '-'

                else
                    c
            )
            string
        ++ ">"


flagsToDocs : Flags -> List P.Doc -> List P.Doc
flagsToDocs flags docs =
    case flags of
        FDone ->
            docs

        FMore more flag ->
            let
                flagDoc : P.Doc
                flagDoc =
                    P.vcat <|
                        case flag of
                            Flag name (Parser { singular }) description ->
                                [ ("--" ++ name ++ "=" ++ toToken singular) |> P.text |> P.dullcyan
                                , reflow description |> P.indent 4
                                ]

                            OnOff name description ->
                                [ ("--" ++ name) |> P.text |> P.dullcyan
                                , reflow description |> P.indent 4
                                ]
            in
            flagsToDocs more (flagDoc :: docs)



-- OVERVIEW


exitWithOverview : P.Doc -> P.Doc -> List Command -> Task Never a
exitWithOverview intro outro commands =
    getExeName
        |> Task.andThen
            (\exeName ->
                exitSuccess
                    [ intro
                    , P.text "The most common commands are:"
                    , List.filterMap (toSummary exeName) commands |> stack |> P.indent 4
                    , P.text "There are a bunch of other commands as well though. Here is a full list:"
                    , toCommandList exeName commands |> P.dullcyan |> P.indent 4
                    , P.text "Adding the --help flag gives a bunch of additional details about each one."
                    , outro
                    ]
            )


toSummary : String -> Command -> Maybe P.Doc
toSummary exeName (Command cmdData) =
    case cmdData.summary of
        Uncommon ->
            Nothing

        Common summaryString ->
            let
                (Args args) =
                    cmdData.args
            in
            Just <|
                P.vcat
                    [ argsToDoc (exeName ++ " " ++ cmdData.name) (Prelude.head args) |> P.cyan
                    , reflow summaryString |> P.indent 4
                    ]


toCommandList : String -> List Command -> P.Doc
toCommandList exeName commands =
    let
        names : List String
        names =
            List.map toName commands

        width : Int
        width =
            Utils.listMaximum compare (List.map String.length names)

        toExample : String -> P.Doc
        toExample name =
            P.text
                (exeName
                    ++ " "
                    ++ name
                    ++ String.repeat (width - String.length name) " "
                    ++ " --help"
                )
    in
    P.vcat (List.map toExample names)



-- UNKNOWN


exitWithUnknown : String -> List String -> Task Never a
exitWithUnknown unknown knowns =
    let
        nearbyKnowns : List ( Int, String )
        nearbyKnowns =
            List.takeWhile (\( r, _ ) -> r <= 3) (Suggest.rank unknown identity knowns)

        suggestions : List P.Doc
        suggestions =
            case List.map toGreen (List.map Tuple.second nearbyKnowns) of
                [] ->
                    []

                [ nearby ] ->
                    [ P.text "Try", nearby, P.text "instead?" ]

                [ a, b ] ->
                    [ P.text "Try", a, P.text "or", b, P.text "instead?" ]

                (_ :: _ :: _ :: _) as abcs ->
                    P.text "Try"
                        :: List.map (P.a (P.text ",")) (Prelude.init abcs)
                        ++ [ P.text "or", Prelude.last abcs, P.text "instead?" ]
    in
    getExeName
        |> Task.andThen
            (\exeName ->
                exitFailure
                    [ P.fillSep <|
                        [ P.text "There"
                        , P.text "is"
                        , P.text "no"
                        , toRed unknown
                        , P.text "command."
                        ]
                            ++ suggestions
                    , ("Run `" ++ exeName ++ "` with no arguments to get more hints.") |> reflow
                    ]
            )



-- ERROR TO DOC


exitWithError : Error -> Task Never a
exitWithError err =
    (case err of
        BadFlag flagError ->
            flagErrorToDocs flagError

        BadArgs argErrors ->
            case argErrors of
                [] ->
                    Task.succeed
                        [ "I was not expecting any arguments for this command." |> reflow
                        , "Try removing them?" |> reflow
                        ]

                [ argError ] ->
                    argErrorToDocs argError

                _ :: _ :: _ ->
                    List.sortBy toArgErrorRank argErrors |> Prelude.head |> argErrorToDocs
    )
        |> Task.andThen exitFailure


toArgErrorRank :
    ArgError
    -> Int -- lower is better
toArgErrorRank err =
    case err of
        ArgBad _ _ ->
            0

        ArgMissing _ ->
            1

        ArgExtras _ ->
            2


toGreen : String -> P.Doc
toGreen str =
    P.green (P.text str)


toYellow : String -> P.Doc
toYellow str =
    P.yellow (P.text str)


toRed : String -> P.Doc
toRed str =
    P.red (P.text str)



-- ARG ERROR TO DOC


argErrorToDocs : ArgError -> Task Never (List P.Doc)
argErrorToDocs argError =
    case argError of
        ArgMissing (Expectation tipe makeExamples) ->
            makeExamples
                |> Task.map
                    (\examples ->
                        [ P.fillSep
                            [ P.text "The"
                            , P.text "arguments"
                            , P.text "you"
                            , P.text "have"
                            , P.text "are"
                            , P.text "fine,"
                            , P.text "but"
                            , P.text "in"
                            , P.text "addition,"
                            , P.text "I"
                            , P.text "was"
                            , P.text "expecting"
                            , P.text "a"
                            , toYellow (toToken tipe)
                            , P.text "value."
                            , P.text "For"
                            , P.text "example:"
                            ]
                        , List.map P.text examples |> P.vcat |> P.green |> P.indent 4
                        ]
                    )

        ArgBad string (Expectation tipe makeExamples) ->
            makeExamples
                |> Task.map
                    (\examples ->
                        [ P.text "I am having trouble with this argument:"
                        , toRed string |> P.indent 4
                        , P.fillSep <|
                            [ P.text "It"
                            , P.text "is"
                            , P.text "supposed"
                            , P.text "to"
                            , P.text "be"
                            , P.text "a"
                            , toYellow (toToken tipe)
                            , P.text "value,"
                            , P.text "like"
                            ]
                                ++ (if List.length examples == 1 then
                                        [ P.text "this:" ]

                                    else
                                        [ P.text "one"
                                        , P.text "of"
                                        , P.text "these:"
                                        ]
                                   )
                        , List.map P.text examples |> P.vcat |> P.green |> P.indent 4
                        ]
                    )

        ArgExtras extras ->
            let
                ( these, them ) =
                    case extras of
                        [ _ ] ->
                            ( "this argument", "it" )

                        _ ->
                            ( "these arguments", "them" )
            in
            Task.succeed
                [ ("I was not expecting " ++ these ++ ":") |> reflow
                , List.map P.text extras |> P.vcat |> P.red |> P.indent 4
                , ("Try removing " ++ them ++ "?") |> reflow
                ]



-- FLAG ERROR TO DOC


flagErrorHelp : String -> String -> List P.Doc -> Task Never (List P.Doc)
flagErrorHelp summary original explanation =
    Task.succeed <|
        [ reflow summary
        , P.indent 4 (toRed original)
        ]
            ++ explanation


flagErrorToDocs : FlagError -> Task Never (List P.Doc)
flagErrorToDocs flagError =
    case flagError of
        FlagWithValue flagName value ->
            flagErrorHelp
                "This on/off flag was given a value:"
                ("--" ++ flagName ++ "=" ++ value)
                [ P.text "An on/off flag either exists or not. It cannot have an equals sign and value.\nMaybe you want this instead?"
                , ("--" ++ flagName) |> toGreen |> P.indent 4
                ]

        FlagWithNoValue flagName (Expectation tipe makeExamples) ->
            makeExamples
                |> Task.andThen
                    (\examples ->
                        flagErrorHelp
                            "This flag needs more information:"
                            ("--" ++ flagName)
                            [ P.fillSep
                                [ P.text "It"
                                , P.text "needs"
                                , P.text "a"
                                , toYellow (toToken tipe)
                                , P.text "like"
                                , P.text "this:"
                                ]
                            , (case List.take 4 examples of
                                [] ->
                                    [ "--" ++ flagName ++ "=" ++ toToken tipe ]

                                _ :: _ ->
                                    List.map (\example -> "--" ++ flagName ++ "=" ++ example) examples
                              )
                                |> List.map toGreen
                                |> P.vcat
                                |> P.indent 4
                            ]
                    )

        FlagWithBadValue flagName badValue (Expectation tipe makeExamples) ->
            makeExamples
                |> Task.andThen
                    (\examples ->
                        flagErrorHelp
                            "This flag was given a bad value:"
                            ("--" ++ flagName ++ "=" ++ badValue)
                            [ P.fillSep <|
                                [ P.text "I"
                                , P.text "need"
                                , P.text "a"
                                , P.text "valid"
                                , toYellow (toToken tipe)
                                , P.text "value."
                                , P.text "For"
                                , P.text "example:"
                                ]
                            , (case List.take 4 examples of
                                [] ->
                                    [ "--" ++ flagName ++ "=" ++ toToken tipe ]

                                _ :: _ ->
                                    List.map (\example -> "--" ++ flagName ++ "=" ++ example) examples
                              )
                                |> List.map toGreen
                                |> P.vcat
                                |> P.indent 4
                            ]
                    )

        FlagUnknown unknown flags ->
            flagErrorHelp "I do not recognize this flag:"
                unknown
                (let
                    unknownName : String
                    unknownName =
                        List.takeWhile ((/=) '=') (List.dropWhile ((==) '-') (String.toList unknown))
                            |> String.fromList
                 in
                 case getNearbyFlags unknownName flags [] of
                    [] ->
                        []

                    [ thisOne ] ->
                        [ P.fillSep
                            [ P.text "Maybe"
                            , P.text "you"
                            , P.text "want"
                            , P.green thisOne
                            , P.text "instead?"
                            ]
                        ]

                    suggestions ->
                        [ P.fillSep
                            [ P.text "Maybe"
                            , P.text "you"
                            , P.text "want"
                            , P.text "one"
                            , P.text "of"
                            , P.text "these"
                            , P.text "instead?"
                            ]
                        , P.vcat suggestions |> P.green |> P.indent 4
                        ]
                )


getNearbyFlags : String -> Flags -> List ( Int, String ) -> List P.Doc
getNearbyFlags unknown flags unsortedFlags =
    case flags of
        FDone ->
            (case List.filter (\( d, _ ) -> d < 3) unsortedFlags of
                [] ->
                    unsortedFlags

                nearbyUnsortedFlags ->
                    nearbyUnsortedFlags
            )
                |> List.sortBy Tuple.first
                |> List.map Tuple.second
                |> List.map P.text

        FMore more flag ->
            getNearbyFlags unknown more (getNearbyFlagsHelp unknown flag :: unsortedFlags)


getNearbyFlagsHelp : String -> Flag -> ( Int, String )
getNearbyFlagsHelp unknown flag =
    case flag of
        OnOff flagName _ ->
            ( Levenshtein.distance unknown flagName
            , "--" ++ flagName
            )

        Flag flagName (Parser { singular }) _ ->
            ( Levenshtein.distance unknown flagName
            , "--" ++ flagName ++ "=" ++ toToken singular
            )
