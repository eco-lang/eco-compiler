module Terminal.Terminal.Chomp exposing
    ( Chomper, Chunk, Suggest
    , chomp, chompExactly, chompMultiple
    , chompArg
    , chompNormalFlag, chompOnOffFlag, checkForUnknownFlags
    , map, pure, apply, andThen
    )

{-| Command-line argument parsing using a chomper-based approach.

This module implements the core parsing logic for extracting and validating
command-line arguments and flags. It uses a chomper pattern to incrementally
consume and validate input strings.


# Core Types

@docs Chomper, Chunk, Suggest


# Parsing

@docs chomp, chompExactly, chompMultiple


# Argument Chompers

@docs chompArg


# Flag Chompers

@docs chompNormalFlag, chompOnOffFlag, checkForUnknownFlags


# Combinators

@docs map, pure, apply, andThen

-}

import Basics.Extra exposing (flip)
import Maybe.Extra as Maybe
import Task exposing (Task)
import Terminal.Terminal.Internal exposing (ArgError(..), Error(..), Expectation(..), Flag(..), FlagError(..), Flags(..), Parser(..))
import Utils.Task.Extra as Task



-- ====== CHOMP INTERFACE ======


{-| Main entry point for parsing command-line arguments and flags.

Takes an optional completion index, the raw argument strings, argument parsers,
and a flag chomper. Returns suggestions for tab completion and either an error
or the parsed arguments and flags.

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


toChunks : List String -> List Chunk
toChunks strings =
    List.map2 Chunk
        (List.repeat (List.length strings) ()
            |> List.indexedMap (\i _ -> i)
        )
        strings


toSuggest : Maybe Int -> Suggest
toSuggest maybeIndex =
    case maybeIndex of
        Nothing ->
            NoSuggestion

        Just index ->
            Suggest index



-- ====== CHOMPER ======


{-| A parser that consumes and validates command-line argument chunks.

Takes suggestions and chunks, produces either a success with remaining chunks
and parsed value, or an error.

-}
type Chomper x a
    = Chomper (Suggest -> List Chunk -> ChomperResult x a)


type ChomperResult x a
    = ChomperOk Suggest (List Chunk) a
    | ChomperErr Suggest x


{-| A command-line argument string paired with its position index.

Used to track which argument is being parsed for error messages and completions.

-}
type Chunk
    = Chunk Int String


{-| Tracks suggestions for tab completion.

NoSuggestion means no completion context, Suggest means we know the position,
Suggestions contains the actual completion options.

-}
type Suggest
    = NoSuggestion
    | Suggest Int
    | Suggestions (Task Never (List String))


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


chompArgs : Suggest -> List Chunk -> List (Suggest -> List Chunk -> ( Suggest, Result ArgError a )) -> ( Task Never (List String), Result Error a )
chompArgs suggest chunks completeArgsList =
    chompArgsHelp suggest chunks completeArgsList [] []


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


{-| Parse arguments and ensure no extra arguments remain.

Takes a chomper and runs it, returning an error if any unparsed arguments are left.

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


{-| Parse zero or more arguments of the same type.

Takes a chomper producing a function that accepts a list, a parser, and a parse
function. Collects all remaining arguments and applies them to the function.

-}
chompMultiple : Chomper ArgError (List a -> b) -> Parser -> (String -> Maybe a) -> Suggest -> List Chunk -> ( Suggest, Result ArgError b )
chompMultiple (Chomper chomper) parser parserFn suggest chunks =
    case chomper suggest chunks of
        ChomperOk s1 cs func ->
            chompMultipleHelp parser parserFn [] s1 cs func

        ChomperErr s1 argError ->
            ( s1, Err argError )


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


{-| Create a chomper for a single required argument.

Takes the total number of chunks, a parser for the argument type, and a parse
function. Consumes one chunk and validates it.

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


suggestArg : Parser -> Int -> Int -> Maybe (Task Never (List String))
suggestArg (Parser { suggest }) numChunks targetIndex =
    if numChunks <= targetIndex then
        Just (suggest "")

    else
        Nothing



-- ====== PARSER ======


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


{-| Create a chomper for a boolean on/off flag.

Takes the flag name and returns True if the flag is present, False if absent.

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


{-| Create a chomper for a flag that takes a value.

Takes the flag name, a parser, and a parse function. Returns Just the parsed
value if the flag is present, Nothing if absent.

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



-- ====== FIND FLAG ======


type FoundFlag
    = FoundFlag (List Chunk) Value (List Chunk)


type Value
    = Definitely Int String
    | Possibly Chunk
    | DefNope


findFlag : String -> List Chunk -> Maybe FoundFlag
findFlag flagName chunks =
    findFlagHelp [] ("--" ++ flagName) ("--" ++ flagName ++ "=") chunks


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


{-| Verify that all remaining flags are recognized.

Takes the valid flags specification and checks if any unrecognized flags remain
in the input, producing an error with suggestions if found.

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


startsWithDash : Chunk -> Bool
startsWithDash (Chunk _ string) =
    String.startsWith "-" string


getFlagNames : Flags -> List String -> List String
getFlagNames flags names =
    case flags of
        FDone ->
            "--help" :: names

        FMore subFlags flag ->
            getFlagNames subFlags (getFlagName flag :: names)


getFlagName : Flag -> String
getFlagName flag =
    case flag of
        Flag name _ _ ->
            "--" ++ name

        OnOff name _ ->
            "--" ++ name



-- ====== CHOMPER INSTANCES ======


{-| Transform the value produced by a chomper.

Applies a function to the successful result of a chomper without changing
the error type or parsing behavior.

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


{-| Create a chomper that always succeeds with a given value.

Doesn't consume any input, just wraps the value in a successful chomper result.

-}
pure : a -> Chomper x a
pure value =
    Chomper <|
        \ss cs ->
            ChomperOk ss cs value


{-| Apply a chomper producing a function to a chomper producing a value.

Sequences two chompers, applying the function from the first to the value
from the second.

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


{-| Chain chompers together, allowing the second to depend on the first's result.

Takes a function that produces a chomper based on a value, and a chomper that
produces that value. Enables dynamic parsing based on earlier results.

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
