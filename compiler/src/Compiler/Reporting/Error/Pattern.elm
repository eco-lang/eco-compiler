module Compiler.Reporting.Error.Pattern exposing (toReport)

{-| The pattern checker's findings have to reach the programmer as readable
reports, and this module writes them.

`Compiler.Nitpick.PatternMatches` finds two kinds of fault, as its `Error`
docstring describes: a pattern that can never match, and a match that misses
some values. This module turns the first into a "REDUNDANT PATTERN" report and
the second into an "UNSAFE PATTERN" or "MISSING PATTERNS" report, depending on
the kind of match.

Most of the file prints the checker's example patterns of missed values back
as Elm pattern syntax. The checker reduces unit, tuples and lists to
constructors with built-in names (`#0`, `#2`, `#3`, `[]` and `::`), so printing
means recognising those names again and adding parentheses where a pattern sits
in a position that needs them.


# Reporting

@docs toReport

-}

import Compiler.Nitpick.PatternMatches as P
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Render.Code as Code
import Compiler.Reporting.Report as Report



-- ====== TO REPORT ======


{-| Builds the report for one pattern match fault, with a snippet of `source`.

A `Redundant` fault becomes "REDUNDANT PATTERN", showing the whole match with
the redundant pattern highlighted and naming its position as an ordinal. An
`Incomplete` fault lists the example missing patterns, one per line: a
function argument or a `let` destructuring gives "UNSAFE PATTERN", and a `case`
gives "MISSING PATTERNS".

-}
toReport : Code.Source -> P.Error -> Report.Report
toReport source err =
    case err of
        P.Redundant caseRegion patternRegion index ->
            Report.report "REDUNDANT PATTERN" patternRegion [] <|
                Code.toSnippet source
                    caseRegion
                    (Just patternRegion)
                    ( D.reflow <|
                        "The "
                            ++ D.intToOrdinal index
                            ++ " pattern is redundant:"
                    , "Any value with this shape will be handled by a previous pattern, so it should be removed." |> D.reflow
                    )

        P.Incomplete region context unhandled ->
            case context of
                P.BadArg ->
                    Report.report "UNSAFE PATTERN" region [] <|
                        Code.toSnippet source
                            region
                            Nothing
                            ( D.fromChars "This pattern does not cover all possibilities:"
                            , D.stack
                                [ D.fromChars "Other possibilities include:"
                                , unhandledPatternsToDocBlock unhandled
                                , D.reflow <|
                                    "I would have to crash if I saw one of those! So rather than pattern matching in function arguments, "
                                        ++ "put a `case` in the function body to account for all possibilities."
                                ]
                            )

                P.BadDestruct ->
                    Report.report "UNSAFE PATTERN" region [] <|
                        Code.toSnippet source
                            region
                            Nothing
                            ( D.fromChars "This pattern does not cover all possible values:"
                            , D.stack
                                [ D.fromChars "Other possibilities include:"
                                , unhandledPatternsToDocBlock unhandled
                                , D.reflow <|
                                    "I would have to crash if I saw one of those! You can use `let` to deconstruct values only if there is ONE possibility. "
                                        ++ "Switch to a `case` expression to account for all possibilities."
                                , "Are you calling a function that definitely returns values with a very specific shape? Try making the return type of that function more specific!" |> D.toSimpleHint
                                ]
                            )

                P.BadCase ->
                    Report.report "MISSING PATTERNS" region [] <|
                        Code.toSnippet source
                            region
                            Nothing
                            ( D.fromChars "This `case` does not have branches for all possibilities:"
                            , D.stack
                                [ D.fromChars "Missing possibilities include:"
                                , unhandledPatternsToDocBlock unhandled
                                , "I would have to crash if I saw one of those. Add branches for them!" |> D.reflow
                                , D.link "Hint"
                                    "If you want to write the code for each branch later, use `Debug.todo` as a placeholder. Read"
                                    "missing-patterns"
                                    "for more guidance on this workflow."
                                ]
                            )



-- ====== PATTERN TO DOC ======


{-| Prints each pattern on its own line, coloured and indented four spaces.
-}
unhandledPatternsToDocBlock : List P.Pattern -> D.Doc
unhandledPatternsToDocBlock unhandledPatterns =
    List.map (patternToDoc Unambiguous) unhandledPatterns |> D.vcat |> D.dullyellow |> D.indent 4


{-| Where a pattern being printed sits, which decides whether it needs
parentheses.

`Arg` is an argument of a constructor: a constructor with arguments, or a cons
chain, is parenthesised there. `Head` is the head of a cons chain: a cons chain
is parenthesised there, but a constructor with arguments is not. `Unambiguous`
is a position needing no parentheses, such as a whole pattern or a tuple entry.

-}
type Context
    = Arg
    | Head
    | Unambiguous


{-| Prints `pattern` as Elm pattern syntax, parenthesised as `context` requires.

A wildcard prints as `_`, and characters and strings are quoted. A constructor
named `#N` (a tuple of four or more) has no special case and prints as a
constructor.

A finite list prints as `[` and its entries in order, separated by `,`, then `]`.

-}
patternToDoc : Context -> P.Pattern -> D.Doc
patternToDoc context pattern =
    case delist pattern [] of
        NonList P.Anything ->
            D.fromChars "_"

        NonList (P.Literal literal) ->
            case literal of
                P.Chr chr ->
                    D.fromChars ("'" ++ chr ++ "'")

                P.Str str ->
                    D.fromChars ("\"" ++ str ++ "\"")

                P.Int int ->
                    D.fromChars (String.fromInt int)

        NonList (P.Ctor _ "#0" []) ->
            D.fromChars "()"

        NonList (P.Ctor _ "#2" [ a, b ]) ->
            D.fromChars "( "
                |> D.a (patternToDoc Unambiguous a)
                |> D.a (D.fromChars ", ")
                |> D.a (patternToDoc Unambiguous b)
                |> D.a (D.fromChars " )")

        NonList (P.Ctor _ "#3" [ a, b, c ]) ->
            D.fromChars "( "
                |> D.a (patternToDoc Unambiguous a)
                |> D.a (D.fromChars ", ")
                |> D.a (patternToDoc Unambiguous b)
                |> D.a (D.fromChars ", ")
                |> D.a (patternToDoc Unambiguous c)
                |> D.a (D.fromChars " )")

        NonList (P.Ctor _ name args) ->
            let
                ctorDoc : D.Doc
                ctorDoc =
                    D.hsep (D.fromChars name :: List.map (patternToDoc Arg) args)
            in
            if context == Arg && not (List.isEmpty args) then
                D.fromChars "("
                    |> D.a ctorDoc
                    |> D.a (D.fromChars ")")

            else
                ctorDoc

        FiniteList [] ->
            D.fromChars "[]"

        FiniteList entries ->
            let
                entryDocs : List D.Doc
                entryDocs =
                    List.map (patternToDoc Unambiguous) entries
            in
            D.fromChars "["
                |> D.a (D.hcat (List.intersperse (D.fromChars ",") entryDocs))
                |> D.a (D.fromChars "]")

        Conses conses finalPattern ->
            let
                consDoc : D.Doc
                consDoc =
                    List.foldr
                        (\hd tl ->
                            patternToDoc Head hd
                                |> D.a (D.fromChars " :: ")
                                |> D.a tl
                        )
                        (patternToDoc Unambiguous finalPattern)
                        conses
            in
            if context == Unambiguous then
                consDoc

            else
                D.fromChars "("
                    |> D.a consDoc
                    |> D.a (D.fromChars ")")


{-| A pattern seen as a list, if it is one.

`FiniteList` is a list ending in `[]`, with its entries in order. `Conses` is a chain of heads, in order, ending in a
tail that is not a list constructor. `NonList` is any other pattern.

-}
type Structure
    = FiniteList (List P.Pattern)
    | Conses (List P.Pattern) P.Pattern
    | NonList P.Pattern


{-| Returns the `Structure` of `pattern`, given the heads already taken from
the front of the list, most recent first, in `revEntries`.
-}
delist : P.Pattern -> List P.Pattern -> Structure
delist pattern revEntries =
    case pattern of
        P.Ctor _ "[]" [] ->
            FiniteList (List.reverse revEntries)

        P.Ctor _ "::" [ hd, tl ] ->
            delist tl (hd :: revEntries)

        _ ->
            case revEntries of
                [] ->
                    NonList pattern

                _ ->
                    Conses (List.reverse revEntries) pattern
