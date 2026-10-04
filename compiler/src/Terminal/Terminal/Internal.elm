module Terminal.Terminal.Internal exposing
    ( Command(..), CommandData, Summary(..), toName
    , Args(..), CompleteArgs(..), RequiredArgs(..)
    , Flags(..), Flag(..)
    , Parser(..)
    , Error(..), ArgError(..), FlagError(..), Expectation(..)
    )

{-| The vocabulary of the command-line framework: what a command is, the
arguments and flags it accepts, and what can be wrong with the arguments it is
given. The types live here, apart from the code that parses arguments and
prints messages, so that the module that parses arguments
(`Terminal.Terminal.Chomp`) and the module that prints help and error messages
(`Terminal.Terminal.Error`) can share them without depending on each other.

A command carries two separate accounts of its arguments. The `Args` and
`Flags` values here are descriptions: they name each argument and flag and say
what kind of value it holds, for use in help text, the command overview and
suggestions for a mistyped flag. They cannot parse anything, because a `Parser`
holds no parse function. The parsing is done by the command's `run`, which is
built separately, and nothing in these types ties the two accounts together.

`RequiredArgs` and `Flags` are lists built by adding to the end: the outermost
constructor holds the last argument or flag, and help text shows them in the
order they were added.

When an argument or flag value is missing or cannot be parsed, the error
carries an _expectation_: the name of the kind of value that was wanted,
together with a task that produces example values to show the user.


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


{-| Everything about one command: its name, its help, the descriptions of its
arguments and flags, and how to run it.

`details` is prose that is reflowed when shown, so its own line breaks are not
kept. `example` is a document shown as it is.

`run` is given the command-line arguments that follow the command's name. It
returns either the work the command is to do or the reason those arguments do
not fit the command.

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


{-| One command of a command-line program, as described by its `CommandData`.
-}
type Command
    = Command CommandData


{-| Returns the name a command is invoked by.
-}
toName : Command -> String
toName (Command cmdData) =
    cmdData.name


{-| How prominently a command is shown in the overview of all commands.

Every command shown in the overview appears by name in its full list of
commands. A `Common` command is also listed among the most common commands,
with the usage line of its first argument alternative and the given text
beneath it. An `Uncommon` command appears only in the full list.

-}
type Summary
    = Common String
    | Uncommon



-- ====== FLAGS ======


{-| The description of every flag a command accepts.

`FDone` is no flags. `FMore rest flag` is the flags of `rest` followed by
`flag`, so the outermost `FMore` holds the flag added last. Help text lists the
flags in the order they were added.

-}
type Flags
    = FDone
    | FMore Flags Flag


{-| The description of one flag. A flag's name is written without its leading
`--`.

`Flag name parser description` is a flag that takes a value, of the kind
`parser` describes.

`OnOff name description` is a flag that takes no value and is either present
or absent.

-}
type Flag
    = Flag String Parser String
    | OnOff String String



-- ====== PARSERS ======


{-| The description of one kind of argument or flag value, such as a file path
or a version number. Despite its name it does not parse: it holds no parse
function, and the function that turns a string into a value is supplied
separately wherever one is parsed.

`singular` names one such value in usage lines and error messages, and
`plural` names a sequence of them in the usage line of a repeated argument.

`suggest` produces the completions for a partly typed value. `examples`
produces example values to show in an error message, given the string that was
typed, or the empty string when the value is missing.

-}
type Parser
    = Parser
        { singular : String
        , plural : String
        , suggest : String -> Task Never (List String)
        , examples : String -> Task Never (List String)
        }



-- ====== ARGS ======


{-| The description of a command's positional arguments, as a list of
alternative shapes.

Help text shows one usage line per alternative, in this order.

-}
type Args
    = Args (List CompleteArgs)


{-| One alternative shape for a command's positional arguments.

`Exactly required` is the arguments of `required` and nothing more.

`Multiple required repeated` is the arguments of `required` followed by zero or
more further arguments, each of the kind `repeated` describes.

-}
type CompleteArgs
    = Exactly RequiredArgs
    | Multiple RequiredArgs Parser


{-| A fixed sequence of required positional arguments.

`Done` is the empty sequence. `Required rest parser` is the arguments of `rest`
followed by one more, of the kind `parser` describes, so the outermost
`Required` holds the last argument.

-}
type RequiredArgs
    = Done
    | Required RequiredArgs Parser



-- ====== ERROR ======


{-| The reason a command's arguments do not fit it.

`BadArgs` holds one `ArgError` for each alternative the command's `run` tried,
in the order it tried them, saying why the arguments did not fit it.

`BadFlag` holds the problem with one flag.

-}
type Error
    = BadArgs (List ArgError)
    | BadFlag FlagError


{-| The reason the positional arguments do not fit one alternative.

`ArgMissing` is a required argument that was not given, with the expectation
for it.

`ArgBad value expectation` is an argument that was given as `value` but could
not be parsed.

`ArgExtras` holds the arguments left over once the alternative was filled.

-}
type ArgError
    = ArgMissing Expectation
    | ArgBad String Expectation
    | ArgExtras (List String)


{-| The problem with one flag. Flag names here are written without their
leading `--`.

`FlagWithValue name value` is an on/off flag that was given a value, as
`--name=value`.

`FlagWithBadValue name value expectation` is a flag whose value could not be
parsed.

`FlagWithNoValue name expectation` is a flag that takes a value but was given
none.

`FlagUnknown typed flags` is a string starting with `-` that was left over once
the command's flags had been taken out, such as a flag the command does not
have or a second occurrence of one it does. `typed` is the string exactly as
given, dashes included, and `flags` is the description of every flag the
command does accept, from which nearby names can be suggested.

-}
type FlagError
    = FlagWithValue String String
    | FlagWithBadValue String String Expectation
    | FlagWithNoValue String Expectation
    | FlagUnknown String Flags


{-| What was wanted where an argument or flag value was missing or bad: the
singular name of the kind of value, and a task that produces example values of
that kind.
-}
type Expectation
    = Expectation String (Task Never (List String))
