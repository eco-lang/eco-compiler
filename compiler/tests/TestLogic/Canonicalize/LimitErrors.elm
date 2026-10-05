module TestLogic.Canonicalize.LimitErrors exposing
    ( expectCanonicalizes
    , expectFirstReportContains
    , expectTooLarge
    )

{-| Canonicalization must reject, with a located `TooLarge` error, any function
or lambda whose parameters (plus, for a lambda or local function, its captured
variables) exceed the closure stage-arity limit of 2047 (`HEAP_078`,
`plans/wide-object-tail-kind-words.md` §S.9). This module provides the
expectations that check it, given a source module built by the caller.

Each expectation runs `Compiler.Canonicalize.Module.canonicalize` on the module,
as package `eco/example`, against the stand-in interfaces of
`Compiler.Elm.Interface.Basic.testIfaces`, and then looks only at the errors.
Warnings are ignored.

  - `expectTooLarge` passes when canonicalization fails with exactly one error,
    a `CanError.TooLarge` whose `CanError.TooLargeWhat` is the given one and
    whose actual and limit numbers are the given ones.
  - `expectCanonicalizes` passes when canonicalization succeeds; it is for the
    boundary case at exactly the limit.
  - `expectFirstReportContains` renders the first error with `CanError.toReport`
    (title, then the message laid out by `Compiler.Reporting.Doc.toString`) and
    passes when the text contains every given string.

-}

import Compiler.AST.Source as Src
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Error.Canonicalize as CanError
import Compiler.Reporting.Render.Code as Code
import Compiler.Reporting.Report as Report
import Compiler.Reporting.Result as Result
import Expect


{-| Returns an expectation that canonicalizing `modul` fails with exactly one
error, `TooLarge _ what actual limit`.
-}
expectTooLarge : CanError.TooLargeWhat -> Int -> Int -> Src.Module -> Expect.Expectation
expectTooLarge what actual limit modul =
    let
        description =
            "exactly one TooLarge (" ++ Debug.toString what ++ ") " ++ String.fromInt actual ++ " " ++ String.fromInt limit
    in
    case canonicalizeErrors modul of
        Nothing ->
            Expect.fail ("Expected " ++ description ++ " but canonicalization succeeded")

        Just [ error ] ->
            case error of
                CanError.TooLarge _ gotWhat gotActual gotLimit ->
                    if gotWhat == what && gotActual == actual && gotLimit == limit then
                        Expect.pass

                    else
                        Expect.fail ("Expected " ++ description ++ " but got: " ++ shorten (Debug.toString error))

                _ ->
                    Expect.fail ("Expected " ++ description ++ " but got: " ++ shorten (Debug.toString error))

        Just errors ->
            Expect.fail
                ("Expected "
                    ++ description
                    ++ " but got "
                    ++ String.fromInt (List.length errors)
                    ++ " errors: "
                    ++ String.join ", " (List.map (Debug.toString >> shorten) errors)
                )


{-| Returns an expectation that canonicalizing `modul` succeeds. On failure it
lists the errors reported.
-}
expectCanonicalizes : Src.Module -> Expect.Expectation
expectCanonicalizes modul =
    case canonicalizeErrors modul of
        Nothing ->
            Expect.pass

        Just errors ->
            Expect.fail
                ("Expected canonicalization to succeed but got: "
                    ++ String.join ", " (List.map (Debug.toString >> shorten) errors)
                )


{-| Returns an expectation that canonicalizing `modul` fails and that the
report of its first error, rendered as its title followed by its message,
contains every string in `needles`.
-}
expectFirstReportContains : List String -> Src.Module -> Expect.Expectation
expectFirstReportContains needles modul =
    case canonicalizeErrors modul of
        Nothing ->
            Expect.fail "Expected an error report but canonicalization succeeded"

        Just [] ->
            Expect.fail "Expected an error report but canonicalization reported no error"

        Just (error :: _) ->
            let
                text =
                    case CanError.toReport (Code.toSource "") error of
                        Report.Report props ->
                            props.title ++ "\n" ++ D.toString props.doc

                missing =
                    List.filter (\needle -> not (String.contains needle text)) needles
            in
            if List.isEmpty missing then
                Expect.pass

            else
                Expect.fail
                    ("Report is missing "
                        ++ String.join ", " missing
                        ++ ":\n"
                        ++ text
                    )


{-| Returns the errors of canonicalizing `modul`, or `Nothing` when it succeeds.
-}
canonicalizeErrors : Src.Module -> Maybe (List CanError.Error)
canonicalizeErrors modul =
    case Result.run (Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces modul) of
        ( _, Err errors ) ->
            Just (OneOrMore.destruct (::) errors)

        ( _, Ok _ ) ->
            Nothing


{-| Returns `s` cut to 300 characters, so that an error rendering naming
thousands of parameters stays readable in a failure message.
-}
shorten : String -> String
shorten s =
    if String.length s > 300 then
        String.left 300 s ++ "…"

    else
        s
