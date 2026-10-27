module Terminal.Terminal.Error exposing (exitWithError, exitWithHelp, exitWithOverview, exitWithUnknown)

{-| The messages the command-line framework ends a run with when it shows help
or reports a bad command line, and the exit that follows each.

A run of the framework ends in one of four ways that this module handles: the
user asked for help with one command, asked for the overview of all commands,
named a command that does not exist, or gave a command arguments or flags that
do not fit it. Each `exitWith...` function builds the message for one of these
from the descriptions in `Terminal.Terminal.Internal`, writes it, and exits the
process, so none of them returns. Help and the overview exit with code 0; the
two errors exit with code 1.

Every message goes to stderr, the successful help and overview included. A
message is a list of documents, printed one after another with a blank line
after each and laid out for a width of 80 columns. Colour is stripped when
`System.IO.isTerminal` reports that output is not a terminal.

The executable name shown in usage lines is the file-name part of
`Utils.Main.envGetProgName`.

Where a word in a message is a placeholder for a value, it is written as a
token: the name in angle brackets, with each space turned into a hyphen, as in
`<zero-or-more-files>`.


# Exit Functions

@docs exitWithError, exitWithHelp, exitWithOverview, exitWithUnknown

-}

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



-- ====== EXIT ======


{-| Prints the given documents as every message of this module is printed, then
exits with code 0.
-}
exitSuccess : List P.Doc -> Task Never a
exitSuccess =
    exitWith Exit.ExitSuccess


{-| Prints the given documents as every message of this module is printed, then
exits with code 1.
-}
exitFailure : List P.Doc -> Task Never a
exitFailure =
    exitWith (Exit.ExitFailure 1)


{-| Prints `docs` to stderr and exits the process with `code`.

The documents are printed one after another, each followed by a blank line, at
a width of 80 columns, and with their colour stripped when
`System.IO.isTerminal` reports that output is not a terminal. One more newline
ends the output.

-}
exitWith : Exit.ExitCode -> List P.Doc -> Task Never a
exitWith code docs =
    IO.isTerminal
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
                    (P.renderPretty
                        80
                        (adjust (P.vcat (List.concatMap (\d -> [ d, P.text "" ]) docs)))
                    )
                    |> Task.andThen (\_ -> IO.writeLn IO.stderr "")
                    |> Task.andThen (\_ -> Exit.exitWith code)
            )


{-| The executable name shown in messages: the file-name part of `Utils.Main.envGetProgName`.
-}
getExeName : Task Never String
getExeName =
    Task.map Utils.fpTakeFileName Utils.envGetProgName


{-| Returns `docs` one above another with a blank line between each two.
-}
stack : List P.Doc -> P.Doc
stack docs =
    List.intersperse (P.text "") docs |> P.vcat


{-| Returns `string` as words that are filled onto lines and wrapped at the layout width.
-}
reflow : String -> P.Doc
reflow string =
    String.words string |> List.map P.text |> P.fillSep



-- ====== HELP ======


{-| Prints the help for one command and exits with code 0.

The help is `details`, then one usage line per argument alternative in `Args`,
then `example`, then, when the command has any flags, each flag with its
description, in the order the flags were added. A usage line is the executable
name, then `maybeCommand` when it is given, then a token for each argument; an
alternative that takes any number of trailing arguments ends in
`<zero-or-more-...>` with the plural name. A flag that takes a value is shown as
`--name=<value>`, and an on/off flag as `--name`.

-}
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


{-| Returns the executable name followed by the command name when `maybeCommand` gives one.
-}
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


{-| Returns the usage line for one argument alternative, starting with `command`.
-}
argsToDoc : String -> CompleteArgs -> P.Doc
argsToDoc command args =
    case args of
        Exactly required ->
            argsToDocHelp command required []

        Multiple required (Parser { plural }) ->
            argsToDocHelp command required [ "zero or more " ++ plural ]


{-| Returns the usage line `command`, then a token for each argument of `args`,
then the tokens of `names`.

The outermost `Required` holds the last argument, so each argument is put in
front of the names already gathered.

-}
argsToDocHelp : String -> RequiredArgs -> List String -> P.Doc
argsToDocHelp command args names =
    case args of
        Done ->
            (command :: List.map toToken names) |> List.map P.text |> P.hsep |> P.hang 4

        Required others (Parser { singular }) ->
            argsToDocHelp command others (singular :: names)


{-| Returns `string` as a placeholder token: in angle brackets, with each space turned into a hyphen.
-}
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


{-| Returns one document per flag in `flags`, each its usage and its reflowed
description, followed by `docs`.

The outermost `FMore` holds the flag added last, so prepending while walking
inwards gives the flags in the order they were added.

-}
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



-- ====== OVERVIEW ======


{-| Prints the overview of `commands` and exits with code 0.

The overview is `intro`, then the usage line and summary of every `Common`
command, then a `--help` line for every command with the names padded to one
width, then `outro`. Each `Common` command's usage line is that of its first
argument alternative.

`commands` must not be empty, and every `Common` command must have at least one
argument alternative; otherwise this crashes.

-}
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


{-| Returns the usage line and summary of a `Common` command, or `Nothing` for an
`Uncommon` one.

The usage line is that of the command's first argument alternative; a command
with no alternatives crashes here.

-}
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


{-| Returns one line per command, the executable name, the command name and
`--help`, with the names padded so that the `--help` column lines up.

The list of commands must not be empty: its widest name is found with
`Utils.Main.listMaximum`, which crashes on an empty list.

-}
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



-- ====== UNKNOWN ======


{-| Prints that there is no command called `unknown` and exits with code 1.

The message suggests every name in `knowns` whose distance from `unknown`, as
`Compiler.Reporting.Suggest.rank` measures it, is at most 3, closest first, and
tells the user to run the executable with no arguments for more hints.

-}
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



-- ====== ERROR TO DOC ======


{-| Prints the message for `err` and exits with code 1.

`BadArgs` holds one error per alternative that was tried, and only one of them
is shown: a bad argument in preference to a missing one, and a missing one in
preference to extra ones. An empty `BadArgs` is reported as arguments given to
a command that takes none.

A flag that is not recognised is shown with the flags whose edit distance from
its name is under 3, or every flag when none is that close, nearest first.

-}
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


{-| Returns an argument error's rank for showing, where lower is shown first: a
bad argument, then a missing one, then extra ones.
-}
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


{-| Returns `str` as green text.
-}
toGreen : String -> P.Doc
toGreen str =
    P.green (P.text str)


{-| Returns `str` as yellow text.
-}
toYellow : String -> P.Doc
toYellow str =
    P.yellow (P.text str)


{-| Returns `str` as red text.
-}
toRed : String -> P.Doc
toRed str =
    P.red (P.text str)



-- ====== ARG ERROR TO DOC ======


{-| Produces the message for one argument error.

For a missing or bad argument it runs the expectation's task for example
values and shows all of them.

-}
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



-- ====== FLAG ERROR TO DOC ======


{-| Returns a flag error message: `summary`, then the flag as given, `original`, in red, then `explanation`.
-}
flagErrorHelp : String -> String -> List P.Doc -> Task Never (List P.Doc)
flagErrorHelp summary original explanation =
    Task.succeed <|
        [ reflow summary
        , P.indent 4 (toRed original)
        ]
            ++ explanation


{-| Produces the message for one flag error.

For a flag missing its value or given a bad one, it runs the expectation's task
for example values and shows each as `--name=example`, or `--name=<value>` when
there are none. Every example is shown.

-}
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


{-| Returns the flags of `flags` to suggest for the flag name `unknown`, as text,
nearest first.

`unsortedFlags` gathers each flag's edit distance from `unknown` and its usage.
The suggestions are those at a distance under 3, or all of them when none is
that close. The distance is case-sensitive.

-}
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


{-| Returns the edit distance from `unknown` to the flag's name, paired with the flag's usage.
-}
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
