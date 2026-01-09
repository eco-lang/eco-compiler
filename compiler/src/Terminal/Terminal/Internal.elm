module Terminal.Terminal.Internal exposing
    ( Command(..), CommandData, Summary(..), toName
    , Args(..), CompleteArgs(..), RequiredArgs(..)
    , Flags(..), Flag(..)
    , Parser(..)
    , Error(..), ArgError(..), FlagError(..), Expectation(..)
    )

{-| Internal types and data structures for terminal command parsing.

This module defines the core types used throughout the terminal command system,
including command definitions, argument specifications, error types, and parsers.


# Command Types

@docs Command, CommandData, Summary, toName


# Argument Types

@docs Args, CompleteArgs, RequiredArgs


# Flag Types

@docs Flags, Flag


# Parser Types

@docs Parser


# Error Types

@docs Error, ArgError, FlagError, Expectation

-}

import Task exposing (Task)
import Text.PrettyPrint.ANSI.Leijen exposing (Doc)



-- ====== COMMAND ======


{-| Configuration data for a terminal command.

Includes the command name, summary, detailed help text, usage example,
argument and flag specifications, and the run function that executes the command.

-}
type alias CommandData =
    { name : String
    , summary : Summary
    , details : String
    , example : Doc
    , args : Args
    , flags : Flags
    , run : List String -> Result Error (Task Never ())
    }


{-| A terminal command with all its configuration.

Wraps CommandData to provide a distinct type for commands.

-}
type Command
    = Command CommandData


{-| Extract the name from a command.

Returns the command's name string.

-}
toName : Command -> String
toName (Command cmdData) =
    cmdData.name


{-| Indicates whether a command should be shown in the main help overview.

Common commands appear with a description in the overview, Uncommon commands
are only listed by name. Use Common for frequently-used commands with a brief
2-3 line description, Uncommon for specialized or advanced commands.

-}
type Summary
    = Common String
    | Uncommon



-- ====== FLAGS ======


{-| A collection of command-line flags.

FDone represents no flags, FMore adds a flag to the collection.
Built up recursively to form a list of flags.

-}
type Flags
    = FDone
    | FMore Flags Flag


{-| A single command-line flag specification.

Flag takes a name, parser, and description for flags with values.
OnOff takes a name and description for boolean flags.

-}
type Flag
    = Flag String Parser String
    | OnOff String String



-- ====== PARSERS ======


{-| A parser for command-line argument values.

Contains the singular and plural names for help text, a suggestion function
for tab completion, and an examples function for error messages.

-}
type Parser
    = Parser
        { singular : String
        , plural : String

        -- ,parser : String -> Maybe a
        , suggest : String -> Task Never (List String)
        , examples : String -> Task Never (List String)
        }



-- ====== ARGS ======


{-| A specification for command arguments.

Contains a list of possible complete argument patterns that the command accepts.

-}
type Args
    = Args (List CompleteArgs)


{-| A complete pattern of arguments for a command.

Exactly means a fixed sequence of required arguments, Multiple adds a repeating
argument that can appear zero or more times after the required arguments.

-}
type CompleteArgs
    = Exactly RequiredArgs
    | Multiple RequiredArgs Parser


{-| A sequence of required arguments.

Done represents no more required arguments, Required adds one required argument
to the sequence.

-}
type RequiredArgs
    = Done
    | Required RequiredArgs Parser



-- ====== ERROR ======


{-| Top-level error type for command parsing.

BadArgs contains a list of argument errors, BadFlag contains a single flag error.

-}
type Error
    = BadArgs (List ArgError)
    | BadFlag FlagError


{-| Error type for argument parsing failures.

ArgMissing means a required argument was not provided, ArgBad means an argument
was provided but couldn't be parsed, ArgExtras means unexpected extra arguments
were provided.

-}
type ArgError
    = ArgMissing Expectation
    | ArgBad String Expectation
    | ArgExtras (List String)


{-| Error type for flag parsing failures.

FlagWithValue means an on/off flag was given a value, FlagWithBadValue means
a flag value couldn't be parsed, FlagWithNoValue means a flag requiring a value
had none, FlagUnknown means an unrecognized flag was provided.

-}
type FlagError
    = FlagWithValue String String
    | FlagWithBadValue String String Expectation
    | FlagWithNoValue String Expectation
    | FlagUnknown String Flags


{-| Expected value information for error messages.

Contains the singular type name and a task to generate example values.

-}
type Expectation
    = Expectation String (Task Never (List String))
