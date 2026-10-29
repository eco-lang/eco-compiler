module Compiler.Parse.Pattern exposing (term, expression)

{-| Parses Elm patterns, the left-hand sides that take values apart, into the
source AST of `Compiler.AST.Source`, keeping the comments written among them.

Patterns come in two sizes, and the module exposes one parser for each. A
_term_ is atomic, so a term can sit next to other terms without parentheses. Records, tuples and
parenthesised patterns, lists, the wildcard `_`, a lower-case variable, a
constructor with no arguments, and an Int, string or character literal are
terms. A _pattern expression_ is a term or a constructor applied to argument
terms, followed by any number of `::` and an optional trailing `as name`. The
caller chooses which size it accepts. Each element of a tuple, of a list, or
of a parenthesised pattern is a full pattern expression again.

Two forms are refused with their own errors: a float (`E.PFloat`), and an
underscore followed by name characters (`E.PWildcardNotVar`), since a wildcard
cannot carry a name.

Comments are kept in the `C1` and `C2` wrappers that `Compiler.AST.Source`
defines; which side of a pattern each group lies on is noted at each parser.
The comments between a constructor's arguments are not kept.


# Parsing Patterns

@docs term, expression

-}

import Compiler.AST.Source as Src
import Compiler.Data.Name as Name
import Compiler.Parse.Keyword as Keyword
import Compiler.Parse.Number as Number
import Compiler.Parse.Primitives as P
import Compiler.Parse.Space as Space
import Compiler.Parse.String as String
import Compiler.Parse.Variable as Var
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Syntax as E



-- ====== TERM ======


{-| A parser for one pattern term: a record, a tuple or parenthesised
pattern, a list, the wildcard, a variable, a constructor with no arguments
(such as `Nothing` or `Maybe.Nothing`), or an Int, string or character literal.

A constructor applied to arguments, `::` and `as` are not terms; they are
accepted here only inside the parentheses or brackets of a tuple, a
parenthesised pattern or a list. A float literal, or `_` followed by name
characters, fails with its own error.

-}
term : P.Parser E.Pattern Src.Pattern
term =
    P.getPosition
        |> P.andThen
            (\start ->
                P.oneOf E.PStart
                    [ record start
                    , tuple start
                    , list start
                    , termHelp start
                    ]
            )


{-| Produces a parser for the terms that are a single token: the wildcard, a
variable, a constructor with no arguments, or a literal, with `start` as the
start of the resulting pattern's region.

A float literal is parsed and then rejected with a consumed `E.PFloat` error
whose width is the length of its source text, placed that many columns before
the end of the literal, so the report underlines the literal as written.

-}
termHelp : A.Position -> P.Parser E.Pattern Src.Pattern
termHelp start =
    P.oneOf E.PStart
        [ wildcard
            |> P.andThen (\name -> P.addEnd start (Src.PAnything name))
        , Var.lower E.PStart
            |> P.andThen (\name -> P.addEnd start (Src.PVar name))
        , Var.foreignUpper E.PStart
            |> P.andThen
                (\upper ->
                    P.getPosition
                        |> P.map
                            (\end ->
                                let
                                    region : A.Region
                                    region =
                                        A.Region start end
                                in
                                A.at start end <|
                                    case upper of
                                        Var.Unqualified name ->
                                            Src.PCtor region name []

                                        Var.Qualified home name ->
                                            Src.PCtorQual region home name []
                            )
                )
        , Number.number E.PStart E.PNumber
            |> P.andThen
                (\number ->
                    P.getPosition
                        |> P.andThen
                            (\end ->
                                case number of
                                    Number.Int int src ->
                                        P.pure (A.at start end (Src.PInt int src))

                                    Number.Float _ src ->
                                        P.Parser <|
                                            \(P.State st) ->
                                                let
                                                    width : Int
                                                    width =
                                                        String.length src
                                                in
                                                P.Cerr st.row (st.col - width) (E.PFloat width)
                            )
                )
        , String.string E.PStart E.PString
            |> P.andThen (\( str, multiline ) -> P.addEnd start (Src.PStr str multiline))
        , String.character E.PStart E.PChar
            |> P.andThen (\chr -> P.addEnd start (Src.PChr chr))
        ]



-- ====== WILDCARD ======


{-| A parser for the wildcard `_`, giving the empty name.

When `_` is followed by name characters it fails, having consumed, with
`E.PWildcardNotVar` carrying the whole word and its width.

-}
wildcard : P.Parser E.Pattern Name.Name
wildcard =
    P.Parser <|
        \(P.State st) ->
            if st.pos == st.end || P.unsafeIndex st.src st.pos /= '_' then
                P.Eerr st.row st.col E.PStart

            else
                let
                    newPos : Int
                    newPos =
                        st.pos + 1

                    newCol : P.Col
                    newCol =
                        st.col + 1
                in
                if Var.getInnerWidth st.src newPos st.end > 0 then
                    let
                        ( badPos, badCol ) =
                            Var.chompInnerChars st.src newPos st.end newCol
                    in
                    P.Cerr st.row st.col (E.PWildcardNotVar (Name.fromPtr st.src st.pos badPos) (badCol - st.col))

                else
                    let
                        newState : P.State
                        newState =
                            P.State { st | pos = newPos, col = newCol }
                    in
                    P.Cok "" newState



-- ====== RECORDS ======


{-| Produces a parser for a record pattern `{ a, b }` or `{}`, which names
fields and binds each to a variable of the same name.

For `{}` the comments inside the braces are the `PRecord`'s own; otherwise the
comments before and after each field name are kept with that field.

-}
record : A.Position -> P.Parser E.Pattern Src.Pattern
record start =
    P.inContext E.PRecord (P.word1 '{' E.PStart) <|
        (Space.chompAndCheckIndent E.PRecordSpace E.PRecordIndentOpen
            |> P.andThen
                (\preVarComments ->
                    P.oneOf E.PRecordOpen
                        [ P.addLocation (Var.lower E.PRecordField)
                            |> P.andThen
                                (\var ->
                                    Space.chompAndCheckIndent E.PRecordSpace E.PRecordIndentEnd
                                        |> P.andThen
                                            (\postVarComments ->
                                                recordHelp start [ ( ( preVarComments, postVarComments ), var ) ]
                                            )
                                )
                        , P.word1 '}' E.PRecordEnd
                            |> P.andThen (\_ -> P.addEnd start (Src.PRecord ( preVarComments, [] )))
                        ]
                )
        )


{-| Produces a parser for the rest of a record pattern after its fields `vars`,
which are held most recent first. Further fields are added to the front, and at
the closing brace the `PRecord` is built with `vars` still in that order, so its
fields are in reverse source order.
-}
recordHelp : A.Position -> List (Src.C2 (A.Located Name.Name)) -> P.Parser E.PRecord Src.Pattern
recordHelp start vars =
    P.oneOf E.PRecordEnd
        [ P.word1 ',' E.PRecordEnd
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.PRecordSpace E.PRecordIndentField)
            |> P.andThen
                (\preVarComments ->
                    P.addLocation (Var.lower E.PRecordField)
                        |> P.andThen
                            (\var ->
                                Space.chompAndCheckIndent E.PRecordSpace E.PRecordIndentEnd
                                    |> P.andThen
                                        (\postVarComments ->
                                            recordHelp start (( ( preVarComments, postVarComments ), var ) :: vars)
                                        )
                            )
                )
        , P.word1 '}' E.PRecordEnd
            |> P.andThen (\_ -> P.addEnd start (Src.PRecord ( [], vars )))
        ]



-- ====== TUPLES ======


{-| Produces a parser for `()`, a parenthesised pattern, or a tuple pattern.
Each element is a full pattern expression, kept with the comments before and
after it. The comments inside `()` are discarded: the `PUnit` gets an empty
list.
-}
tuple : A.Position -> P.Parser E.Pattern Src.Pattern
tuple start =
    P.inContext E.PTuple (P.word1 '(' E.PStart) <|
        (Space.chompAndCheckIndent E.PTupleSpace E.PTupleIndentExpr1
            |> P.andThen
                (\prePatternComments ->
                    P.oneOf E.PTupleOpen
                        [ P.specialize E.PTupleExpr expression
                            |> P.andThen
                                (\( ( postPatternComments, pattern ), end ) ->
                                    Space.checkIndent end E.PTupleIndentEnd
                                        |> P.andThen (\_ -> tupleHelp start ( ( prePatternComments, postPatternComments ), pattern ) [])
                                )
                        , P.word1 ')' E.PTupleEnd
                            |> P.andThen (\_ -> P.addEnd start (Src.PUnit []))
                        ]
                )
        )


{-| Produces a parser for the rest of a parenthesised group after its first
pattern, with `revPatterns` holding the later elements most recent first.

At the closing parenthesis a single pattern becomes a `PParens` and two or more
become a `PTuple`, in source order.

-}
tupleHelp : A.Position -> Src.C2 Src.Pattern -> List (Src.C2 Src.Pattern) -> P.Parser E.PTuple Src.Pattern
tupleHelp start firstPattern revPatterns =
    P.oneOf E.PTupleEnd
        [ P.word1 ',' E.PTupleEnd
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.PTupleSpace E.PTupleIndentExprN)
            |> P.andThen
                (\prePatternComments ->
                    P.specialize E.PTupleExpr expression
                        |> P.andThen
                            (\( ( postPatternComments, pattern ), end ) ->
                                Space.checkIndent end E.PTupleIndentEnd
                                    |> P.andThen (\_ -> tupleHelp start firstPattern (( ( prePatternComments, postPatternComments ), pattern ) :: revPatterns))
                            )
                )
        , P.word1 ')' E.PTupleEnd
            |> P.andThen
                (\_ ->
                    case List.reverse revPatterns of
                        [] ->
                            P.addEnd start (Src.PParens firstPattern)

                        secondPattern :: otherPatterns ->
                            P.addEnd start (Src.PTuple firstPattern secondPattern otherPatterns)
                )
        ]



-- ====== LIST ======


{-| Produces a parser for a list pattern `[ ... ]`, whose entries are full
pattern expressions. For `[]` the comments inside the brackets are the
`PList`'s own; otherwise each entry keeps the comments before and after it.
-}
list : A.Position -> P.Parser E.Pattern Src.Pattern
list start =
    P.inContext E.PList (P.word1 '[' E.PStart) <|
        (Space.chompAndCheckIndent E.PListSpace E.PListIndentOpen
            |> P.andThen
                (\prePatternComments ->
                    P.oneOf E.PListOpen
                        [ P.specialize E.PListExpr expression
                            |> P.andThen
                                (\( ( postPatternComments, pattern ), end ) ->
                                    Space.checkIndent end E.PListIndentEnd
                                        |> P.andThen (\_ -> listHelp start [ ( ( prePatternComments, postPatternComments ), pattern ) ])
                                )
                        , P.word1 ']' E.PListEnd
                            |> P.andThen (\_ -> P.addEnd start (Src.PList ( prePatternComments, [] )))
                        ]
                )
        )


{-| Produces a parser for the rest of a list pattern after the entries
`patterns`, held most recent first. At the closing bracket they are reversed, so
the `PList` holds them in source order.
-}
listHelp : A.Position -> List (Src.C2 Src.Pattern) -> P.Parser E.PList Src.Pattern
listHelp start patterns =
    P.oneOf E.PListEnd
        [ P.word1 ',' E.PListEnd
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.PListSpace E.PListIndentExpr)
            |> P.andThen
                (\prePatternComments ->
                    P.specialize E.PListExpr expression
                        |> P.andThen
                            (\( ( postPatternComments, pattern ), end ) ->
                                Space.checkIndent end E.PListIndentEnd
                                    |> P.andThen (\_ -> listHelp start (( ( prePatternComments, postPatternComments ), pattern ) :: patterns))
                            )
                )
        , P.word1 ']' E.PListEnd
            |> P.andThen (\_ -> P.addEnd start (Src.PList ( [], List.reverse patterns )))
        ]



-- ====== EXPRESSION ======


{-| A parser for a whole pattern: a term or a constructor applied to argument
terms, then any number of `:: part`, then optionally `as name`.

`::` associates to the right, so `x :: y :: rest` is `x :: (y :: rest)`. An
`as` applies to everything before it, so `x :: xs as list` names the whole
list, and nothing more is parsed after the alias name.

Each `::` and the `as` must be indented further than the current indentation.
The result carries the comments that follow the pattern and the position where
the pattern ends, before those comments.

-}
expression : Space.Parser E.Pattern (Src.C1 Src.Pattern)
expression =
    P.getPosition
        |> P.andThen
            (\start ->
                exprPart
                    |> P.andThen
                        (\ePart ->
                            exprHelp start [] ePart
                        )
            )


{-| Produces a parser that continues a pattern expression starting at `start`
from its latest part, the `C1` and end position given last, whose comments are
those after it.

`revPatterns` holds the parts already followed by `::`, most recent first, each
with the comments before and after its `::`. When neither `::` nor `as` follows,
the result is the parts folded into `PCons` with `cons`, ending in the latest
part.

-}
exprHelp : A.Position -> List (Src.C2 Src.Pattern) -> ( Src.C1 Src.Pattern, A.Position ) -> Space.Parser E.Pattern (Src.C1 Src.Pattern)
exprHelp start revPatterns ( ( prePatternComments, pattern ), end ) =
    P.oneOfWithFallback
        [ Space.checkIndent end E.PIndentStart
            |> P.andThen (\_ -> P.word2 ':' ':' E.PStart)
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.PSpace E.PIndentStart)
            |> P.andThen
                (\postPatternComments ->
                    exprPart
                        |> P.andThen (\ePart -> exprHelp start (( ( prePatternComments, postPatternComments ), pattern ) :: revPatterns) ePart)
                )
        , Space.checkIndent end E.PIndentStart
            |> P.andThen (\_ -> Keyword.as_ E.PStart)
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.PSpace E.PIndentAlias)
            |> P.andThen
                (\preAliasComments ->
                    P.getPosition
                        |> P.andThen
                            (\nameStart ->
                                Var.lower E.PAlias
                                    |> P.andThen
                                        (\name ->
                                            P.getPosition
                                                |> P.andThen
                                                    (\newEnd ->
                                                        Space.chomp E.PSpace
                                                            |> P.map
                                                                (\postAliasComments ->
                                                                    let
                                                                        alias_ : A.Located Name.Name
                                                                        alias_ =
                                                                            A.at nameStart newEnd name

                                                                        foldedPattern : Src.Pattern
                                                                        foldedPattern =
                                                                            List.foldl cons pattern revPatterns

                                                                        aliasPattern : Src.Pattern_
                                                                        aliasPattern =
                                                                            Src.PAlias ( prePatternComments, foldedPattern ) ( preAliasComments, alias_ )
                                                                    in
                                                                    ( ( postAliasComments, A.at start newEnd aliasPattern ), newEnd )
                                                                )
                                                    )
                                        )
                            )
                )
        ]
        ( ( prePatternComments, List.foldl cons pattern revPatterns )
        , end
        )


{-| Returns the pattern `hd :: tl`, keeping the comments on either side of the
`::`, with a region covering both.
-}
cons : Src.C2 Src.Pattern -> Src.Pattern -> Src.Pattern
cons ( ( preComments, postComments ), hd ) tl =
    A.merge hd tl (Src.PCons ( Nothing, hd ) ( ( preComments, postComments, Nothing ), tl ))



-- ====== EXPRESSION PART ======


{-| A parser for one operand of `::`: a constructor with its argument terms, or
any other term, with the comments after it and its end position.
-}
exprPart : Space.Parser E.Pattern (Src.C1 Src.Pattern)
exprPart =
    P.oneOf E.PStart
        [ P.getPosition
            |> P.andThen
                (\start ->
                    Var.foreignUpper E.PStart
                        |> P.andThen
                            (\upper ->
                                P.getPosition
                                    |> P.andThen (\end -> exprTermHelp (A.Region start end) upper start [])
                            )
                )
        , term
            |> P.andThen
                (\((A.At (A.Region _ end) _) as eterm) ->
                    Space.chomp E.PSpace
                        |> P.map (\comments -> ( ( comments, eterm ), end ))
                )
        ]


{-| Produces a parser that collects the argument terms of the constructor
`upper`, whose name occupies `region`, and builds the `PCtor` or `PCtorQual`.

`revArgs` holds the arguments so far, most recent first. An argument must be
indented further than the current indentation. The comments before each
argument are discarded; only those after the last argument (or after the name,
when there are none) are kept, as the result's trailing comments.

-}
exprTermHelp : A.Region -> Var.Upper -> A.Position -> List (Src.C1 Src.Pattern) -> Space.Parser E.Pattern (Src.C1 Src.Pattern)
exprTermHelp region upper start revArgs =
    P.getPosition
        |> P.andThen
            (\end ->
                Space.chomp E.PSpace
                    |> P.andThen
                        (\comments ->
                            P.oneOfWithFallback
                                [ Space.checkIndent end E.PIndentStart
                                    |> P.andThen (\_ -> term)
                                    |> P.andThen (\arg -> exprTermHelp region upper start (( [], arg ) :: revArgs))
                                ]
                                ( ( comments
                                  , A.at start end <|
                                        case upper of
                                            Var.Unqualified name ->
                                                Src.PCtor region name (List.reverse revArgs)

                                            Var.Qualified home name ->
                                                Src.PCtorQual region home name (List.reverse revArgs)
                                  )
                                , end
                                )
                        )
            )
