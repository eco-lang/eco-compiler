module Terminal.Terminal.Chomp exposing
    ( Chomper, Chunk, Suggest
    , chomp, chompExactly, chompMultiple
    , chompArg
    , chompNormalFlag, chompRepeatableFlag, chompOnOffFlag, checkForUnknownFlags
    , map, pure, apply, andThen
    )

{-| Turns the strings that follow a command's name into typed arguments and
flags. This is the parsing half of the command-line framework. The parse
functions are passed to the chompers separately from the `Parser` and `Flags`
descriptions in `Terminal.Terminal.Internal`, which the chompers use only for
error messages and completions. Nothing here checks that the chompers a command
runs agree with the arguments and flags it describes.

Each string is a _chunk_: the string together with its position among the
strings, counting from 0. A _chomper_ is a parser over the list of chunks. It
takes out the chunks it recognises and passes the rest on, so each chomper in a
sequence sees only what the earlier ones left. A flag chomper looks through all
the chunks for its flag; `chompArg`, the chomper for one positional argument,
takes the first chunk left. Chompers are combined with `pure`, `map` and
`apply`, and in sequence with `andThen`.

`chomp` parses in two steps, because flags may appear anywhere among the
arguments. First the flag chomper takes the flags out of the whole list. Then
the chunks it left are given to each _argument alternative_ in turn: an
alternative is one accepted shape for the positional arguments, usually made
with `chompExactly` or `chompMultiple`, and the first to succeed wins.

A flag chomper takes out only the first occurrence of its flag, except
`chompRepeatableFlag`, which takes out every occurrence. `checkForUnknownFlags`,
run after the flag chompers, treats every string still left that starts with `-`
as an unknown flag, so a repeated ordinary flag is rejected while a repeatable
flag may appear any number of times.

Parsing also gathers tab completions. The _suggestion state_ (`Suggest`) that
is passed from chomper to chomper holds the position of the string to be
completed, if any. Within one sequence of chompers it is filled in at most once,
by the first chomper that finds completions for that position.


# Core Types

@docs Chomper, Chunk, Suggest


# Parsing

@docs chomp, chompExactly, chompMultiple


# Argument Chompers

@docs chompArg


# Flag Chompers

@docs chompNormalFlag, chompRepeatableFlag, chompOnOffFlag, checkForUnknownFlags


# Combinators

@docs map, pure, apply, andThen

-}

import Basics.Extra exposing (flip)
import Maybe.Extra as Maybe
import Task exposing (Task)
import Terminal.Terminal.Internal exposing (ArgError(..), Error(..), Expectation(..), Flag(..), FlagError(..), Flags(..), Parser(..))
import Utils.Task.Extra as Task



-- ====== CHOMP INTERFACE ======


{-| Parses `strings`, flags first and then positional arguments, and returns
a task giving the tab completions together with the outcome.

`maybeIndex` is the position, counting from 0, of the string to complete, or
`Nothing` when no completions are wanted, in which case the task gives an empty
list.

The flag chomper runs over all of `strings`. If it fails, the outcome is
`BadFlag` and no alternative in `args` is tried. Otherwise each alternative is
tried in order on the chunks the flag chomper left, and the first to succeed
gives the arguments. If none does, the outcome is `BadArgs` with each
alternative's error, in the order tried.

Every alternative starts from the suggestion state the flag chomper left. The
completions returned are those of that state after the successful alternative,
or, when all fail, those of each alternative's final state, in the order tried,
so completions the flags found appear once for each alternative.

-}
chomp :
    Maybe Int
    -> List String
    -> List (Suggest -> List Chunk -> ( Suggest, Result ArgError args ))
    -> Chomper FlagError flags
    -> ( Task Never (List String), Result Error ( args, flags ) )
chomp maybeIndex strings args (Chomper flagChomper) =
    case flagChomper (toSuggest maybeIndex) (toChunks strings) of
        ChomperOk suggest chunks flagValue ->
            Tuple.mapSecond (Result.map (\a -> ( a, flagValue ))) (chompArgs suggest chunks args)

        ChomperErr suggest flagError ->
            ( addSuggest (Task.succeed []) suggest, Err (BadFlag flagError) )


{-| Pairs each string with its position in the list, counting from 0.
-}
toChunks : List String -> List Chunk
toChunks strings =
    List.map2 Chunk
        (List.repeat (List.length strings) ()
            |> List.indexedMap (\i _ -> i)
        )
        strings


{-| Returns the starting suggestion state: no completions wanted, or
completions wanted for the string at the given position and none found yet.
-}
toSuggest : Maybe Int -> Suggest
toSuggest maybeIndex =
    case maybeIndex of
        Nothing ->
            NoSuggestion

        Just index ->
            Suggest index



-- ====== CHOMPER ======


{-| A parser over a command's chunks that produces a value of type `a` or
fails with an error of type `x`.

A chomper takes out the chunks it recognises and passes the rest on, together
with the suggestion state, to whatever runs after it. A failure still carries
the suggestion state, with any completions found before it.

Chompers are made with `chompArg`, `chompOnOffFlag`, `chompNormalFlag`,
`checkForUnknownFlags` and `pure`, combined with `map`, `apply` and `andThen`,
and run by `chomp`, `chompExactly` and `chompMultiple`.

-}
type Chomper x a
    = Chomper (Suggest -> List Chunk -> ChomperResult x a)


{-| The outcome of running a chomper.

`ChomperOk` carries the suggestion state, the chunks left for the next chomper
and the value. `ChomperErr` carries the suggestion state and the error, and no
chunks.

-}
type ChomperResult x a
    = ChomperOk Suggest (List Chunk) a
    | ChomperErr Suggest x


{-| One of a command's argument strings, together with its position among
them, counting from 0.

The position stays with the string while other chunks are taken out around it,
which is how a chomper recognises the string being completed. Chunks are made
only inside this module, by `chomp`.

-}
type Chunk
    = Chunk Int String


{-| The tab-completion state passed along a parse.

It is in one of three states: no completions are wanted; completions are wanted
for the string at a given position and none have been found yet; or a chomper
has found them, and the state holds the task that produces them. A state that
holds found completions is passed on unchanged by every later chomper.

Values are made only inside this module, starting from `chomp`.

-}
type Suggest
    = NoSuggestion
    | Suggest Int
    | Suggestions (Task Never (List String))


{-| Fills in the completions if they are still wanted. For `Suggest index` it
returns `Suggestions` holding the task `maybeUpdate index` gives, or the state
unchanged when that is `Nothing`. Any other state is returned unchanged, so the
first completions found are the ones kept.
-}
makeSuggestion : Suggest -> (Int -> Maybe (Task Never (List String))) -> Suggest
makeSuggestion suggest maybeUpdate =
    case suggest of
        NoSuggestion ->
            suggest

        Suggestions _ ->
            suggest

        Suggest index ->
            Maybe.unwrap suggest Suggestions (maybeUpdate index)



-- ====== ARGS ======


{-| Tries each argument alternative in `completeArgsList`, in order, on
`chunks`, and returns the completions with the first success, or with
`BadArgs` when every alternative fails, as `chomp` describes.
-}
chompArgs : Suggest -> List Chunk -> List (Suggest -> List Chunk -> ( Suggest, Result ArgError a )) -> ( Task Never (List String), Result Error a )
chompArgs suggest chunks completeArgsList =
    chompArgsHelp suggest chunks completeArgsList [] []


{-| Tries the alternatives in `completeArgsList`, in order, each on `chunks`
and starting from `suggest`. `revSuggest` and `revArgErrors` hold the final
suggestion states and the errors of the alternatives that have already failed,
newest first.
-}
chompArgsHelp :
    Suggest
    -> List Chunk
    -> List (Suggest -> List Chunk -> ( Suggest, Result ArgError a ))
    -> List Suggest
    -> List ArgError
    -> ( Task Never (List String), Result Error a )
chompArgsHelp suggest chunks completeArgsList revSuggest revArgErrors =
    case completeArgsList of
        [] ->
            ( List.foldl (flip addSuggest) (Task.succeed []) revSuggest
            , Err (BadArgs (List.reverse revArgErrors))
            )

        completeArgs :: others ->
            case completeArgs suggest chunks of
                ( s1, Err argError ) ->
                    chompArgsHelp suggest chunks others (s1 :: revSuggest) (argError :: revArgErrors)

                ( s1, Ok value ) ->
                    ( addSuggest (Task.succeed []) s1
                    , Ok value
                    )


{-| Returns a task giving the completions `suggest` holds, if it holds any,
followed by those `everything` gives.
-}
addSuggest : Task Never (List String) -> Suggest -> Task Never (List String)
addSuggest everything suggest =
    case suggest of
        NoSuggestion ->
            everything

        Suggest _ ->
            everything

        Suggestions newStuff ->
            Task.succeed (++)
                |> Task.apply newStuff
                |> Task.apply everything



-- ====== COMPLETE ARGS ======


{-| Turns a chomper into an argument alternative for `chomp` that must use
every chunk it is given.

The alternative succeeds with the chomper's value only when the chomper leaves
no chunks; leftover chunks give `ArgExtras` with their strings, in order. A
failure of the chomper is passed on as it is.

-}
chompExactly : Chomper ArgError a -> Suggest -> List Chunk -> ( Suggest, Result ArgError a )
chompExactly (Chomper chomper) suggest chunks =
    case chomper suggest chunks of
        ChomperOk s cs value ->
            case List.map (\(Chunk _ chunk) -> chunk) cs of
                [] ->
                    ( s, Ok value )

                es ->
                    ( s, Err (ArgExtras es) )

        ChomperErr s argError ->
            ( s, Err argError )


{-| Turns a chomper into an argument alternative for `chomp` that also takes
any number of further arguments of one kind.

The chomper runs first. Every chunk it leaves is then parsed with the parse
function, in order, and the function the chomper produced is given the list of
values. The first chunk that does not parse gives `ArgBad` with that string and
an expectation built from the `Parser`. No chunk is left over, so this
alternative never gives `ArgExtras`.

-}
chompMultiple : Chomper ArgError (List a -> b) -> Parser -> (String -> Maybe a) -> Suggest -> List Chunk -> ( Suggest, Result ArgError b )
chompMultiple (Chomper chomper) parser parserFn suggest chunks =
    case chomper suggest chunks of
        ChomperOk s1 cs func ->
            chompMultipleHelp parser parserFn [] s1 cs func

        ChomperErr s1 argError ->
            ( s1, Err argError )


{-| Parses each of `chunks` with `parserFn`, adding the values to `revArgs`
(newest first), and once every chunk has parsed applies `func` to all the
values in their original order.
-}
chompMultipleHelp : Parser -> (String -> Maybe a) -> List a -> Suggest -> List Chunk -> (List a -> b) -> ( Suggest, Result ArgError b )
chompMultipleHelp parser parserFn revArgs suggest chunks func =
    case chunks of
        [] ->
            ( suggest, Ok (func (List.reverse revArgs)) )

        (Chunk index string) :: otherChunks ->
            case tryToParse suggest parser parserFn index string of
                ( s1, Err expectation ) ->
                    ( s1, Err (ArgBad string expectation) )

                ( s1, Ok arg ) ->
                    chompMultipleHelp parser parserFn (arg :: revArgs) s1 otherChunks func



-- ====== REQUIRED ARGS ======


{-| Creates a chomper for one required positional argument. It takes the first
chunk left and parses it with the parse function.

When no chunk is left the chomper fails with `ArgMissing`, and when the chunk
does not parse it fails with `ArgBad`; both carry an expectation built from the
`Parser`.

The `Int` is used only for completion, and is meant to be the number of strings
given to `chomp`. A missing argument offers the `Parser`'s completions when the
position being completed is at or beyond that number, that is, past the last
string.

-}
chompArg : Int -> Parser -> (String -> Maybe a) -> Chomper ArgError a
chompArg numChunks ((Parser { singular, examples }) as parser) parserFn =
    Chomper <|
        \suggest chunks ->
            case chunks of
                [] ->
                    let
                        newSuggest : Suggest
                        newSuggest =
                            makeSuggestion suggest (suggestArg parser numChunks)

                        theError : ArgError
                        theError =
                            ArgMissing (Expectation singular (examples ""))
                    in
                    ChomperErr newSuggest theError

                (Chunk index string) :: otherChunks ->
                    case tryToParse suggest parser parserFn index string of
                        ( newSuggest, Err expectation ) ->
                            ChomperErr newSuggest (ArgBad string expectation)

                        ( newSuggest, Ok arg ) ->
                            ChomperOk newSuggest otherChunks arg


{-| Returns the parser's completions for an empty string when `targetIndex`,
the position being completed, is at or beyond `numChunks`, and `Nothing`
otherwise.
-}
suggestArg : Parser -> Int -> Int -> Maybe (Task Never (List String))
suggestArg (Parser { suggest }) numChunks targetIndex =
    if numChunks <= targetIndex then
        Just (suggest "")

    else
        Nothing



-- ====== PARSER ======


{-| Parses `string`, the chunk at position `index`, with `parserFn`. A string
that does not parse gives an expectation built from the parser, with examples
for `string`.

If `index` is the position being completed, the parser's completions for
`string` go into the suggestion state, whether or not it parses.

-}
tryToParse : Suggest -> Parser -> (String -> Maybe a) -> Int -> String -> ( Suggest, Result Expectation a )
tryToParse suggest (Parser parser) parserFn index string =
    let
        newSuggest : Suggest
        newSuggest =
            makeSuggestion suggest <|
                \targetIndex ->
                    if index == targetIndex then
                        Just (parser.suggest string)

                    else
                        Nothing

        outcome : Result Expectation a
        outcome =
            case parserFn string of
                Nothing ->
                    Err (Expectation parser.singular (parser.examples string))

                Just value ->
                    Ok value
    in
    ( newSuggest, outcome )



-- ====== FLAG ======


{-| Creates a chomper for a flag that takes no value. It gives `True` when the
string `--flagName` is present, and takes it out, and `False` otherwise.

Only the first occurrence of the flag is taken out. A string after the flag
that does not start with `-` stays where it was, for the positional arguments.
`--flagName=value` fails with `FlagWithValue`.

-}
chompOnOffFlag : String -> Chomper FlagError Bool
chompOnOffFlag flagName =
    Chomper <|
        \suggest chunks ->
            case findFlag flagName chunks of
                Nothing ->
                    ChomperOk suggest chunks False

                Just (FoundFlag before value after) ->
                    case value of
                        DefNope ->
                            ChomperOk suggest (before ++ after) True

                        Possibly chunk ->
                            ChomperOk suggest (before ++ chunk :: after) True

                        Definitely _ string ->
                            ChomperErr suggest (FlagWithValue flagName string)


{-| Creates a chomper for a flag that takes a value. It gives `Just` the value,
parsed with the parse function, when the flag is present, and `Nothing`
otherwise.

The value is written `--flagName=value` or `--flagName value`. In the second
form it is the next string, and only if that does not start with `-`. The flag
and its value are taken out, and only the first occurrence of the flag is. A
flag with no value fails with `FlagWithNoValue`, and a value that does not parse
fails with `FlagWithBadValue`; both carry an expectation built from the
`Parser`.

-}
chompNormalFlag : String -> Parser -> (String -> Maybe a) -> Chomper FlagError (Maybe a)
chompNormalFlag flagName ((Parser { singular, examples }) as parser) parserFn =
    Chomper <|
        \suggest chunks ->
            case findFlag flagName chunks of
                Nothing ->
                    ChomperOk suggest chunks Nothing

                Just (FoundFlag before value after) ->
                    let
                        attempt : Int -> String -> ChomperResult FlagError (Maybe a)
                        attempt index string =
                            case tryToParse suggest parser parserFn index string of
                                ( newSuggest, Err expectation ) ->
                                    ChomperErr newSuggest (FlagWithBadValue flagName string expectation)

                                ( newSuggest, Ok flagValue ) ->
                                    ChomperOk newSuggest (before ++ after) (Just flagValue)
                    in
                    case value of
                        Definitely index string ->
                            attempt index string

                        Possibly (Chunk index string) ->
                            attempt index string

                        DefNope ->
                            ChomperErr suggest (FlagWithNoValue flagName (Expectation singular (examples "")))


{-| Creates a chomper for a flag that takes a value and may be given any number
of times. It gives every value, parsed with the parse function, in the order the
flags appear, and the empty list when the flag is absent.

Each occurrence is written and parsed as for `chompNormalFlag`, and every
occurrence is taken out, so `checkForUnknownFlags` never sees a repeat of it.
The first occurrence with no value or a value that does not parse fails, with
`FlagWithNoValue` or `FlagWithBadValue` as for `chompNormalFlag`.

-}
chompRepeatableFlag : String -> Parser -> (String -> Maybe a) -> Chomper FlagError (List a)
chompRepeatableFlag flagName ((Parser { singular, examples }) as parser) parserFn =
    let
        loop : List a -> Suggest -> List Chunk -> ChomperResult FlagError (List a)
        loop revValues suggest chunks =
            case findFlag flagName chunks of
                Nothing ->
                    ChomperOk suggest chunks (List.reverse revValues)

                Just (FoundFlag before value after) ->
                    let
                        attempt : Int -> String -> ChomperResult FlagError (List a)
                        attempt index string =
                            case tryToParse suggest parser parserFn index string of
                                ( newSuggest, Err expectation ) ->
                                    ChomperErr newSuggest (FlagWithBadValue flagName string expectation)

                                ( newSuggest, Ok flagValue ) ->
                                    loop (flagValue :: revValues) newSuggest (before ++ after)
                    in
                    case value of
                        Definitely index string ->
                            attempt index string

                        Possibly (Chunk index string) ->
                            attempt index string

                        DefNope ->
                            ChomperErr suggest (FlagWithNoValue flagName (Expectation singular (examples "")))
    in
    Chomper (loop [])



-- ====== FIND FLAG ======


{-| A flag found among the chunks: the chunks before it, in their original
order, what followed the flag's name, and the chunks after it. When what
followed is `Possibly` the next chunk, that chunk is not among those after it.
-}
type FoundFlag
    = FoundFlag (List Chunk) Value (List Chunk)


{-| What followed a flag's name.

`Definitely index value` is a value written after `=` in the flag's own chunk,
which is at position `index`.

`Possibly chunk` is the chunk after the flag, which does not start with `-`. It
is the value of a flag that takes one, and an ordinary argument otherwise.

`DefNope` means the flag was the last chunk, or the chunk after it starts with
`-`.

-}
type Value
    = Definitely Int String
    | Possibly Chunk
    | DefNope


{-| Finds the first chunk that is `--flagName` or begins with `--flagName=`,
and splits the other chunks around it.
-}
findFlag : String -> List Chunk -> Maybe FoundFlag
findFlag flagName chunks =
    findFlagHelp [] ("--" ++ flagName) ("--" ++ flagName ++ "=") chunks


{-| Finds the first of `chunks` that begins with `flagPrefix` or equals
`loneFlag`, given the chunks already passed in `revPrev`, newest first.

A chunk beginning with `flagPrefix` gives `Definitely` the text after the
prefix. A `loneFlag` chunk gives `Possibly` the next chunk, or `DefNope` when
there is none or it starts with `-`.

-}
findFlagHelp : List Chunk -> String -> String -> List Chunk -> Maybe FoundFlag
findFlagHelp revPrev loneFlag flagPrefix chunks =
    let
        succeed : Value -> List Chunk -> Maybe FoundFlag
        succeed value after =
            Just (FoundFlag (List.reverse revPrev) value after)

        deprefix : String -> String
        deprefix string =
            String.dropLeft (String.length flagPrefix) string
    in
    case chunks of
        [] ->
            Nothing

        ((Chunk index string) as chunk) :: rest ->
            if String.startsWith flagPrefix string then
                succeed (Definitely index (deprefix string)) rest

            else if string /= loneFlag then
                findFlagHelp (chunk :: revPrev) loneFlag flagPrefix rest

            else
                case rest of
                    [] ->
                        succeed DefNope []

                    ((Chunk _ potentialArg) as argChunk) :: restOfRest ->
                        if String.startsWith "-" potentialArg then
                            succeed DefNope rest

                        else
                            succeed (Possibly argChunk) restOfRest



-- ====== CHECK FOR UNKNOWN FLAGS ======


{-| Creates a chomper that fails with `FlagUnknown` if any chunk left starts
with `-`, and otherwise succeeds without taking anything.

It does not look at flag names: any string left that starts with `-` counts. So
it is meant to run after every flag chomper, and a second occurrence of a known
flag, a lone `-` or a negative number is reported as unknown. Repeats of a flag
chomped with `chompRepeatableFlag` are accepted, because that chomper takes out
every occurrence before this check runs. The error carries
the first such string and the `Flags` description, from which nearby names can
be suggested.

For completion, an unknown string at the position being completed offers each
flag name in the `Flags` description, and `--help`, that begins with it.

-}
checkForUnknownFlags : Flags -> Chomper FlagError ()
checkForUnknownFlags flags =
    Chomper <|
        \suggest chunks ->
            case List.filter startsWithDash chunks of
                [] ->
                    ChomperOk suggest chunks ()

                ((Chunk _ unknownFlag) :: _) as unknownFlags ->
                    ChomperErr
                        (makeSuggestion suggest (suggestFlag unknownFlags flags))
                        (FlagUnknown unknownFlag flags)


{-| Returns the names in `flags`, and `--help`, that begin with the string of
the chunk of `unknownFlags` at position `targetIndex`, or `Nothing` when no
chunk of `unknownFlags` is at that position.
-}
suggestFlag : List Chunk -> Flags -> Int -> Maybe (Task Never (List String))
suggestFlag unknownFlags flags targetIndex =
    case unknownFlags of
        [] ->
            Nothing

        (Chunk index string) :: otherUnknownFlags ->
            if index == targetIndex then
                Just (Task.succeed (List.filter (String.startsWith string) (getFlagNames flags [])))

            else
                suggestFlag otherUnknownFlags flags targetIndex


{-| Returns whether a chunk's string starts with `-`.
-}
startsWithDash : Chunk -> Bool
startsWithDash (Chunk _ string) =
    String.startsWith "-" string


{-| Returns `--help`, then the name of every flag in `flags` with its leading
`--`, in the order the flags were added, then `names`.
-}
getFlagNames : Flags -> List String -> List String
getFlagNames flags names =
    case flags of
        FDone ->
            "--help" :: names

        FMore subFlags flag ->
            getFlagNames subFlags (getFlagName flag :: names)


{-| Returns a flag's name with a leading `--`.
-}
getFlagName : Flag -> String
getFlagName flag =
    case flag of
        Flag name _ _ ->
            "--" ++ name

        OnOff name _ ->
            "--" ++ name



-- ====== CHOMPER INSTANCES ======


{-| Returns a chomper that does what the given one does and applies `func` to
its value.
-}
map : (a -> b) -> Chomper x a -> Chomper x b
map func (Chomper chomper) =
    Chomper <|
        \i w ->
            case chomper i w of
                ChomperOk s1 cs1 value ->
                    ChomperOk s1 cs1 (func value)

                ChomperErr sErr e ->
                    ChomperErr sErr e


{-| Creates a chomper that succeeds with `value` and takes no chunks.
-}
pure : a -> Chomper x a
pure value =
    Chomper <|
        \ss cs ->
            ChomperOk ss cs value


{-| Returns a chomper that runs `funcChomper`, then `argChomper` on the chunks
it left, and applies the function from the first to the value from the second.

The value chomper comes first in the argument list so that a pipeline reads in
order: `pure f |> apply a |> apply b` runs `a`, then `b`, and gives `f` applied
to both values. If `funcChomper` fails, `argChomper` is not run.

-}
apply : Chomper x a -> Chomper x (a -> b) -> Chomper x b
apply (Chomper argChomper) (Chomper funcChomper) =
    Chomper <|
        \s cs ->
            let
                ok1 : Suggest -> List Chunk -> (a -> b) -> ChomperResult x b
                ok1 s1 cs1 func =
                    case argChomper s1 cs1 of
                        ChomperOk s2 cs2 value ->
                            ChomperOk s2 cs2 (func value)

                        ChomperErr s2 err ->
                            ChomperErr s2 err
            in
            case funcChomper s cs of
                ChomperOk s1 cs1 func ->
                    ok1 s1 cs1 func

                ChomperErr s1 err ->
                    ChomperErr s1 err


{-| Returns a chomper that runs `aChomper`, then runs the chomper `callback`
builds from its value on the chunks `aChomper` left. If `aChomper` fails,
`callback` is not called.
-}
andThen : (a -> Chomper x b) -> Chomper x a -> Chomper x b
andThen callback (Chomper aChomper) =
    Chomper <|
        \s cs ->
            case aChomper s cs of
                ChomperOk s1 cs1 a ->
                    case callback a of
                        Chomper bChomper ->
                            bChomper s1 cs1

                ChomperErr sErr e ->
                    ChomperErr sErr e
