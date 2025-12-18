module Terminal.Terminal exposing
    ( app
    , flags, noFlags, more, flag, onOff
    , noArgs, zeroOrMore, oneOf, require0, require1, require2, require3
    )

{-| Terminal application framework for building command-line interfaces.

This module provides a declarative API for defining CLI commands with typed
arguments and flags. It handles command parsing, help text generation, and
routing to command implementations.


# Application

@docs app


# Flags

@docs flags, noFlags, more, flag, onOff


# Arguments

@docs noArgs, zeroOrMore, oneOf, require0, require1, require2, require3

-}

import Compiler.Elm.Version as V
import Compiler.Reporting.Doc as D
import List.Extra as List
import System.Exit as Exit
import System.IO as IO
import Task exposing (Task)
import Terminal.Terminal.Error as Error
import Terminal.Terminal.Internal exposing (Args(..), Command(..), CompleteArgs(..), Flag(..), Flags(..), Parser, RequiredArgs(..), toName)
import Utils.Main as Utils



-- APP


{-| Create and run a terminal application with commands.

Takes an intro message, outro message, and list of available commands.
Parses command-line arguments and routes to the appropriate command handler.

-}
app : D.Doc -> D.Doc -> List Command -> Task Never ()
app intro outro commands =
    Utils.envGetArgs
        |> Task.andThen
            (\argStrings ->
                case argStrings of
                    [] ->
                        Error.exitWithOverview intro outro commands

                    [ "--help" ] ->
                        Error.exitWithOverview intro outro commands

                    [ "--version" ] ->
                        IO.hPutStrLn IO.stdout (V.toChars V.compiler)
                            |> Task.andThen (\_ -> Exit.exitSuccess)

                    command :: chunks ->
                        case List.find (\cmd -> toName cmd == command) commands of
                            Nothing ->
                                Error.exitWithUnknown command (List.map toName commands)

                            Just (Command cmdData) ->
                                if List.member "--help" chunks then
                                    Error.exitWithHelp (Just command) cmdData.details cmdData.example cmdData.args cmdData.flags

                                else
                                    case cmdData.run chunks of
                                        Ok res ->
                                            res

                                        Err err ->
                                            Error.exitWithError err
            )



-- FLAGS


{-| A command with no flags.

Use this when your command doesn't accept any command-line flags.

-}
noFlags : Flags
noFlags =
    FDone


{-| Start building a flags specification.

Equivalent to noFlags, used as the starting point when adding flags with more.

-}
flags : Flags
flags =
    FDone


{-| Add a flag to a flags specification.

Builds up a list of flags by prepending each flag to the existing specification.

-}
more : Flag -> Flags -> Flags
more f fs =
    FMore fs f



-- FLAG


{-| Define a flag that takes a value.

Takes the flag name, a parser for the value type, and a help description.
Example: flag "output" filePath "The output file path"

-}
flag : String -> Parser -> String -> Flag
flag =
    Flag


{-| Define a boolean on/off flag.

Takes the flag name and a help description. The flag is either present (True)
or absent (False). Example: onOff "verbose" "Enable verbose output"

-}
onOff : String -> String -> Flag
onOff =
    OnOff



-- FANCY ARGS


{-| -}
args : RequiredArgs
args =
    Done


exactly : RequiredArgs -> Args
exactly requiredArgs =
    Args [ Exactly requiredArgs ]


exclamantionMark : RequiredArgs -> Parser -> RequiredArgs
exclamantionMark =
    Required



-- questionMark : RequiredArgs -> Parser -> Args
-- questionMark requiredArgs optionalArg =
--     Args [ Optional requiredArgs optionalArg ]


dotdotdot : RequiredArgs -> Parser -> Args
dotdotdot requiredArgs repeatedArg =
    Args [ Multiple requiredArgs repeatedArg ]


{-| Specify that a command accepts multiple possible argument patterns.

Takes a list of argument specifications and allows any one of them to match.
Useful for commands that can be invoked in different ways.

-}
oneOf : List Args -> Args
oneOf listOfArgs =
    Args (List.concatMap (\(Args a) -> a) listOfArgs)



-- -- SIMPLE ARGS


{-| Specify that a command takes no arguments.

Use this for commands that only use flags or don't take any input.

-}
noArgs : Args
noArgs =
    exactly args



-- required : Parser -> Args
-- required parser =
--     require1 identity parser
-- optional : Parser -> Args
-- optional parser =
--     questionMark args parser


{-| Specify that a command accepts zero or more arguments.

Takes a parser for the argument type. All remaining command-line arguments
will be collected and parsed with this parser.

-}
zeroOrMore : Parser -> Args
zeroOrMore parser =
    dotdotdot args parser



-- oneOrMore : Parser -> Args
-- oneOrMore parser =
--     exclamantionMark args (dotdotdot parser parser)


{-| Specify that a command requires exactly zero arguments.

Equivalent to noArgs, used for consistency in the requireN family of functions.

-}
require0 : Args
require0 =
    exactly args


{-| Specify that a command requires exactly one argument.

Takes a parser for the required argument type.

-}
require1 : Parser -> Args
require1 a =
    exactly (exclamantionMark args a)


{-| Specify that a command requires exactly two arguments.

Takes parsers for both required argument types.

-}
require2 : Parser -> Parser -> Args
require2 a b =
    exactly (exclamantionMark (exclamantionMark args a) b)


{-| Specify that a command requires exactly three arguments.

Takes parsers for all three required argument types.

-}
require3 : Parser -> Parser -> Parser -> Args
require3 a b c =
    exactly (exclamantionMark (exclamantionMark (exclamantionMark args a) b) c)



-- require4 : (a -> b -> c -> d -> args) -> Parser a -> Parser b -> Parser c -> Parser d -> Args args
-- require4 func a b c d =
--     exactly (exclamantionMark (exclamantionMark (exclamantionMark (exclamantionMark (args func) a) b) c) d)
-- require5 : (a -> b -> c -> d -> e -> args) -> Parser a -> Parser b -> Parser c -> Parser d -> Parser e -> Args args
-- require5 func a b c d e =
--     exactly (exclamantionMark (exclamantionMark (exclamantionMark (exclamantionMark (exclamantionMark (args func) a) b) c) d) e)
