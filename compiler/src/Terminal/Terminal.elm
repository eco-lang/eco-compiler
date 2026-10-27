module Terminal.Terminal exposing
    ( app
    , enabled, disabled
    , flags, noFlags, more, flag, onOff
    , noArgs, zeroOrMore, oneOf, require0, require1, require2, require3
    )

{-| The entry point of the command-line framework: it picks the command a run
of the program names and hands it the rest of the command line, and it offers
the builders that describe a command's flags and positional arguments.

The descriptions built here (`Flags` and `Args`, with the types in
`Terminal.Terminal.Internal`) do not parse anything. They are used for help
text, the overview of all commands, and suggestions for a mistyped flag. Each
command parses its own arguments in its `run` function, which is written
separately, so a command's description and its parsing agree only because they
are kept in agreement by hand; `Terminal.Terminal.Internal` explains this
split.

A _registration_ is a `Maybe Command`: `enabled` makes a command available, and
`disabled` stands in place of a command that is kept in the code but left out
of the program. `app` drops the disabled ones before doing anything else.


# Application

@docs app


# Command registration

@docs enabled, disabled


# Flags

@docs flags, noFlags, more, flag, onOff


# Arguments

@docs noArgs, zeroOrMore, oneOf, require0, require1, require2, require3

-}

import Compiler.Elm.Version_Build as Version_Build
import Compiler.Reporting.Doc as D
import List.Extra as List
import System.Exit as Exit
import System.IO as IO
import Task exposing (Task)
import Terminal.Terminal.Error as Error
import Terminal.Terminal.Internal exposing (Args(..), Command(..), CompleteArgs(..), Flag(..), Flags(..), Parser, RequiredArgs(..), toName)
import Utils.Main as Utils



-- ====== APP ======


{-| Creates the task that runs the program on the process's command-line
arguments, given the `intro` and `outro` shown around the overview and the
command registrations.

With no arguments, or with `--help` as the only argument, it shows the overview
of the enabled commands. With `--version` as the only argument it prints
`Compiler.Elm.Version_Build.userFacing` to stdout and exits with code 0.
Otherwise the first argument names the command, and an unknown name is reported
with suggestions. If `--help` is any of the remaining arguments, the command's
help is shown. Otherwise the command's `run` is given the remaining arguments,
and either the task it returns runs or the parse error it returns is reported.
Help, the overview and the error messages are printed and exited with as
`Terminal.Terminal.Error` describes.

-}
app : D.Doc -> D.Doc -> List (Maybe Command) -> Task Never ()
app intro outro registrations =
    let
        commands : List Command
        commands =
            List.filterMap identity registrations
    in
    Utils.envGetArgs
        |> Task.andThen
            (\argStrings ->
                case argStrings of
                    [] ->
                        Error.exitWithOverview intro outro commands

                    [ "--help" ] ->
                        Error.exitWithOverview intro outro commands

                    [ "--version" ] ->
                        IO.writeLn IO.stdout Version_Build.userFacing
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



-- ====== COMMAND REGISTRATION ======


{-| Returns the registration of a command that can be invoked and is listed in
the overview.
-}
enabled : Command -> Maybe Command
enabled command =
    Just command


{-| The registration that stands in place of a disabled command. `app` ignores
it, so the command cannot be invoked and is not listed in the overview, while
its definition stays in the code.
-}
disabled : Maybe Command
disabled =
    Nothing



-- ====== FLAGS ======


{-| The flags description of a command that accepts no flags. It is the same
value as `flags`.
-}
noFlags : Flags
noFlags =
    FDone


{-| The empty flags description that `more` adds flags to. It is the same value
as `noFlags`.
-}
flags : Flags
flags =
    FDone


{-| Returns the flags description `fs` with the flag `f` added after the flags
already in it. Help lists the flags in the order they were added.
-}
more : Flag -> Flags -> Flags
more f fs =
    FMore fs f



-- ====== FLAG ======


{-| Creates the description of a flag that takes a value, from the flag's name
without its leading dashes, the description of its kind of value, and the
sentence shown for it in help.
-}
flag : String -> Parser -> String -> Flag
flag =
    Flag


{-| Creates the description of a flag that takes no value and is either present
or absent, from the flag's name without its leading dashes and the sentence
shown for it in help.
-}
onOff : String -> String -> Flag
onOff =
    OnOff



-- ====== FANCY ARGS ======


{-| The empty sequence of required arguments that the argument builders start
from.
-}
args : RequiredArgs
args =
    Done


{-| Returns the arguments description with one alternative: exactly the
arguments in `requiredArgs`.
-}
exactly : RequiredArgs -> Args
exactly requiredArgs =
    Args [ Exactly requiredArgs ]


{-| Returns the sequence of required arguments with one more required argument,
described by the given `Parser`, added at its end.
-}
exclamantionMark : RequiredArgs -> Parser -> RequiredArgs
exclamantionMark =
    Required


{-| Returns the arguments description with one alternative: the arguments in
`requiredArgs` followed by any number of arguments described by `repeatedArg`.
-}
dotdotdot : RequiredArgs -> Parser -> Args
dotdotdot requiredArgs repeatedArg =
    Args [ Multiple requiredArgs repeatedArg ]


{-| Returns an arguments description whose alternatives are those of every
description in the list, in list order.

When the arguments fit none of the alternatives, the error holds one problem
per alternative, and `Terminal.Terminal.Error` shows the most relevant one.

-}
oneOf : List Args -> Args
oneOf listOfArgs =
    Args (List.concatMap (\(Args a) -> a) listOfArgs)



-- -- SIMPLE ARGS


{-| The arguments description of a command that takes no positional arguments.
It is the same value as `require0`.
-}
noArgs : Args
noArgs =
    exactly args


{-| Returns the arguments description of a command that takes any number of
positional arguments, each described by `parser`.
-}
zeroOrMore : Parser -> Args
zeroOrMore parser =
    dotdotdot args parser


{-| The arguments description of a command that takes no positional arguments.
It is the same value as `noArgs`.
-}
require0 : Args
require0 =
    exactly args


{-| Returns the arguments description of a command that takes exactly one
positional argument, described by `a`.
-}
require1 : Parser -> Args
require1 a =
    exactly (exclamantionMark args a)


{-| Returns the arguments description of a command that takes exactly two
positional arguments, described by `a` and `b` in that order.
-}
require2 : Parser -> Parser -> Args
require2 a b =
    exactly (exclamantionMark (exclamantionMark args a) b)


{-| Returns the arguments description of a command that takes exactly three
positional arguments, described by `a`, `b` and `c` in that order.
-}
require3 : Parser -> Parser -> Parser -> Args
require3 a b c =
    exactly (exclamantionMark (exclamantionMark (exclamantionMark args a) b) c)
