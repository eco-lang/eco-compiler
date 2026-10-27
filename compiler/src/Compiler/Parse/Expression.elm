module Compiler.Parse.Expression exposing (expression)

{-| Parses Elm expressions into the source AST of `Compiler.AST.Source`, keeping
the comments found between their parts.

`expression` is the one entry point. An expression is a `let`, `if` or `case`
expression, a lambda, or a _chain_: a possibly negated term followed by
arguments and binary operators. A _term_ is an expression that stands alone
without any operator or argument: a variable, a literal, a list, a record or
record update, a parenthesised expression, a tuple, `()`, an operator in
parentheses such as `(+)`, an accessor such as `.name`, or a GLSL shader block.
A variable, or a term that starts with `(` or `{`, may be followed directly by
field accesses, as in `point.x`.

Three facts shape the module.

Operators are not grouped here. `a + b * c` becomes one `Src.Binops` holding
each operand paired with the operator after it, then the last operand, in
source order; precedence and associativity are applied later, when the module
is canonicalized. A `let`, `case`, `if` or lambda may be the last operand only,
since its own body extends as far as it can.

A `-` is either subtraction or negation, and spacing decides which. At the start
of an expression or of an operand it negates the term after it. After a term, a
`-` with whitespace before it and none after (`f -x`) negates the next term,
which becomes an argument; any other `-` there is the subtraction operator.
Negation applies to one term only, so `-f x` calls `-f` with `x`.

Layout decides where things end. An argument or operator must be indented
further than the current indent, as `Compiler.Parse.Space` checks it. The
branches of a `case` start in the column of its first pattern, and the
definitions of a `let` in the column of its first definition; a line that starts
in that column begins the next branch or definition.

`expression` returns, with the expression, the comments it consumed after it
and the position where the expression ended, before those comments. A caller
attaches the comments where they belong and checks the indentation of the next
token against that position.

-}

import Compiler.AST.Source as Src
import Compiler.Data.Name as Name
import Compiler.Parse.Keyword as Keyword
import Compiler.Parse.Number as Number
import Compiler.Parse.Pattern as Pattern
import Compiler.Parse.Primitives as P
import Compiler.Parse.Shader as Shader
import Compiler.Parse.Space as Space
import Compiler.Parse.String as String
import Compiler.Parse.Symbol as Symbol
import Compiler.Parse.Type as Type
import Compiler.Parse.Variable as Var
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Syntax as E



-- ====== TERMS ======


{-| A parser for one term, followed by any field accesses when the term is a
variable or starts with `(` or `{`.
-}
term : P.Parser E.Expr Src.Expr
term =
    P.getPosition
        |> P.andThen
            (\start ->
                P.oneOf E.Start
                    [ variable start |> P.andThen (accessible start)
                    , string start
                    , number start
                    , Shader.shader start
                    , list start
                    , record start |> P.andThen (accessible start)
                    , tuple start |> P.andThen (accessible start)
                    , accessor start
                    , character start
                    ]
            )


{-| Produces a parser for a single-line or multi-line string literal starting at
`start`, kept in its escaped source form as `Compiler.Parse.String` describes.
-}
string : A.Position -> P.Parser E.Expr Src.Expr
string start =
    String.string E.Start E.String_
        |> P.andThen (\( str, representation ) -> P.addEnd start (Src.Str str representation))


{-| Produces a parser for a character literal starting at `start`.
-}
character : A.Position -> P.Parser E.Expr Src.Expr
character start =
    String.character E.Start E.Char
        |> P.andThen (\chr -> P.addEnd start (Src.Chr chr))


{-| Produces a parser for an integer or float literal starting at `start`, keeping
the source text of the number alongside its value.
-}
number : A.Position -> P.Parser E.Expr Src.Expr
number start =
    Number.number E.Start E.Number
        |> P.andThen
            (\nmbr ->
                P.addEnd start <|
                    case nmbr of
                        Number.Int int src ->
                            Src.Int int src

                        Number.Float float src ->
                            Src.Float float src
            )


{-| Produces a parser for a field accessor function such as `.name`, starting at
`start`.
-}
accessor : A.Position -> P.Parser E.Expr Src.Expr
accessor start =
    P.word1 '.' E.Dot
        |> P.andThen (\_ -> Var.lower E.Access)
        |> P.andThen (\field -> P.addEnd start (Src.Accessor field))


{-| Produces a parser for a variable or constructor, qualified or not, starting at
`start`.
-}
variable : A.Position -> P.Parser E.Expr Src.Expr
variable start =
    Var.foreignAlpha E.Start
        |> P.andThen (\var -> P.addEnd start var)


{-| Produces a parser that reads any `.field` accesses directly after `expr`,
with no whitespace before a dot, and returns `expr` wrapped in one `Src.Access`
per field. With no dot it returns `expr` unchanged, consuming nothing.

Each access's region runs from `start`, the start of `expr`, to the end of the
field name.

-}
accessible : A.Position -> Src.Expr -> P.Parser E.Expr Src.Expr
accessible start expr =
    P.oneOfWithFallback
        [ P.word1 '.' E.Dot
            |> P.andThen (\_ -> P.getPosition)
            |> P.andThen (\pos -> chompAccessField start expr pos)
        ]
        expr


{-| Produces a parser for the field name after a dot at `pos`, wrapping `expr` in
an access of that field and then reading any further accesses.
-}
chompAccessField : A.Position -> Src.Expr -> A.Position -> P.Parser E.Expr Src.Expr
chompAccessField start expr pos =
    Var.lower E.Access
        |> P.andThen (\field -> P.getPosition |> P.map (\end -> ( field, end )))
        |> P.andThen
            (\( field, end ) ->
                accessible start (A.at start end (Src.Access expr (A.at pos end field)))
            )



-- ====== LISTS ======


{-| Produces a parser for a list expression starting at the `[` at `start`.

Each entry, and the `,` or `]` after it, must be indented past the current
indent. The first entry's comments are the ones after the `[`; each
later entry carries the comments either side of the comma before it, and the
comments after the last entry are stored with the list.

-}
list : A.Position -> P.Parser E.Expr Src.Expr
list start =
    P.inContext E.List (P.word1 '[' E.Start) <|
        (Space.chompAndCheckIndent E.ListSpace E.ListIndentOpen
            |> P.andThen
                (\comments ->
                    P.oneOf E.ListOpen
                        [ P.specialize E.ListExpr expression
                            |> P.andThen
                                (\( ( postEntryComments, entry ), end ) ->
                                    Space.checkIndent end E.ListIndentEnd
                                        |> P.andThen (\_ -> P.loop (chompListEnd start) ( postEntryComments, [ ( ( [], comments, Nothing ), entry ) ] ))
                                )
                        , P.word1 ']' E.ListOpen
                            |> P.andThen (\_ -> P.addEnd start (Src.List [] comments))
                        ]
                )
        )


{-| Produces one step of the loop that reads the rest of a list: another entry
after a comma, or the closing `]`.

`entries` is in reverse order and is reversed when the list is closed;
`trailingComments` are the comments after the latest entry.

-}
chompListEnd : A.Position -> Src.C1 (List (Src.C2Eol Src.Expr)) -> P.Parser E.List_ (P.Step (Src.C1 (List (Src.C2Eol Src.Expr))) Src.Expr)
chompListEnd start ( trailingComments, entries ) =
    P.oneOf E.ListEnd
        [ P.word1 ',' E.ListEnd
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.ListSpace E.ListIndentExpr)
            |> P.andThen
                (\postComments ->
                    P.specialize E.ListExpr expression
                        |> P.andThen
                            (\( ( preComments, entry ), end ) ->
                                Space.checkIndent end E.ListIndentEnd
                                    |> P.map (\_ -> P.Loop ( preComments, ( ( trailingComments, postComments, Nothing ), entry ) :: entries ))
                            )
                )
        , P.word1 ']' E.ListEnd
            |> P.andThen (\_ -> P.addEnd start (Src.List (List.reverse entries) trailingComments))
            |> P.map P.Done
        ]



-- ====== TUPLES ======


{-| Produces a parser for everything that starts with `(` at `start`: `()`, an
operator in parentheses such as `(+)`, a parenthesised expression, or a tuple.

When the `(` is followed directly by `-`, the `-` is read as the operator `(-)`
if `)` follows at once, and, if a term follows at once, negates that term, which
then begins the expression inside the parentheses. The region of that negation,
and of any chain it starts, begins two columns after the `(`, at the negated
term rather than at the `-`. Any other operator must be followed at once by
`)`.

-}
tuple : A.Position -> P.Parser E.Expr Src.Expr
tuple ((A.Position row col) as start) =
    P.inContext E.Tuple (P.word1 '(' E.Start) <|
        (P.getPosition
            |> P.andThen
                (\before ->
                    Space.chompAndCheckIndent E.TupleSpace E.TupleIndentExpr1
                        |> P.andThen
                            (\preEntryComments ->
                                P.getPosition
                                    |> P.andThen
                                        (\after ->
                                            if before /= after then
                                                P.specialize E.TupleExpr expression
                                                    |> P.andThen
                                                        (\( ( postEntryComments, entry ), end ) ->
                                                            Space.checkIndent end E.TupleIndentEnd
                                                                |> P.andThen (\_ -> chompTupleEnd start ( ( preEntryComments, postEntryComments ), entry ) [])
                                                        )

                                            else
                                                P.oneOf E.TupleIndentExpr1
                                                    [ Symbol.operator E.TupleIndentExpr1 E.TupleOperatorReserved
                                                        |> P.andThen
                                                            (\op ->
                                                                if op == "-" then
                                                                    P.oneOf E.TupleOperatorClose
                                                                        [ P.word1 ')' E.TupleOperatorClose
                                                                            |> P.andThen (\_ -> P.addEnd start (Src.Op op))
                                                                        , P.specialize E.TupleExpr
                                                                            (term
                                                                                |> P.andThen
                                                                                    (\((A.At (A.Region _ end) _) as negatedExpr) ->
                                                                                        Space.chomp E.Space
                                                                                            |> P.andThen
                                                                                                (\postTermComments ->
                                                                                                    let
                                                                                                        exprStart : A.Position
                                                                                                        exprStart =
                                                                                                            A.Position row (col + 2)

                                                                                                        expr : A.Located Src.Expr_
                                                                                                        expr =
                                                                                                            A.at exprStart end (Src.Negate negatedExpr)
                                                                                                    in
                                                                                                    chompExprEnd
                                                                                                        exprStart
                                                                                                        (State
                                                                                                            { ops = []
                                                                                                            , expr = expr
                                                                                                            , args = []
                                                                                                            , end = end
                                                                                                            }
                                                                                                        )
                                                                                                        postTermComments
                                                                                                )
                                                                                    )
                                                                            )
                                                                            |> P.andThen
                                                                                (\( ( postEntryComments, entry ), end ) ->
                                                                                    Space.checkIndent end E.TupleIndentEnd
                                                                                        |> P.andThen (\_ -> chompTupleEnd start ( ( preEntryComments, postEntryComments ), entry ) [])
                                                                                )
                                                                        ]

                                                                else
                                                                    P.word1 ')' E.TupleOperatorClose
                                                                        |> P.andThen (\_ -> P.addEnd start (Src.Op op))
                                                            )
                                                    , P.word1 ')' E.TupleIndentExpr1
                                                        |> P.andThen (\_ -> P.addEnd start Src.Unit)
                                                    , P.specialize E.TupleExpr expression
                                                        |> P.andThen
                                                            (\( ( postEntryComments, entry ), end ) ->
                                                                Space.checkIndent end E.TupleIndentEnd
                                                                    |> P.andThen (\_ -> chompTupleEnd start ( ( preEntryComments, postEntryComments ), entry ) [])
                                                            )
                                                    ]
                                        )
                            )
                )
        )


{-| Produces a parser for the rest of a parenthesised expression or tuple after
its first entry `firstExpr`: more entries after commas, then the `)`.

One entry gives a `Src.Parens` and two or more a `Src.Tuple`. `revExprs` holds
the entries after the first, in reverse order.

-}
chompTupleEnd : A.Position -> Src.C2 Src.Expr -> List (Src.C2 Src.Expr) -> P.Parser E.Tuple Src.Expr
chompTupleEnd start firstExpr revExprs =
    P.oneOf E.TupleEnd
        [ P.word1 ',' E.TupleEnd
            |> P.andThen
                (\_ ->
                    Space.chompAndCheckIndent E.TupleSpace E.TupleIndentExprN
                        |> P.andThen
                            (\preEntryComments ->
                                P.specialize E.TupleExpr expression
                                    |> P.andThen
                                        (\( ( postEntryComments, entry ), end ) ->
                                            Space.checkIndent end E.TupleIndentEnd
                                                |> P.andThen (\_ -> chompTupleEnd start firstExpr (( ( preEntryComments, postEntryComments ), entry ) :: revExprs))
                                        )
                            )
                )
        , P.word1 ')' E.TupleEnd
            |> P.andThen
                (\_ ->
                    case List.reverse revExprs of
                        [] ->
                            P.addEnd start (Src.Parens firstExpr)

                        secondExpr :: otherExprs ->
                            P.addEnd start (Src.Tuple firstExpr secondExpr otherExprs)
                )
        ]



-- ====== RECORDS ======


{-| Produces a parser for an expression that starts with `{` at `start`: an empty
record, a record literal, or a record update such as `{ point | x = 1 }`.

The record being updated must be a plain lower-case variable. Anything after
the `{` other than `}` or a lower-case name, such as an upper-case name,
fails with `E.RecordOpen`; a lower-case name followed by anything but `|` or `=`
fails with `E.RecordEquals`.

-}
record : A.Position -> P.Parser E.Expr Src.Expr
record start =
    P.inContext E.Record (P.word1 '{' E.Start) <|
        (Space.chompAndCheckIndent E.RecordSpace E.RecordIndentOpen
            |> P.andThen
                (\preStarterNameComments ->
                    P.oneOf E.RecordOpen
                        [ P.word1 '}' E.RecordOpen
                            |> P.andThen (\_ -> P.addEnd start (Src.Record ( preStarterNameComments, [] )))
                        , P.addLocation (Var.lower E.RecordField)
                            |> P.andThen
                                (\((A.At starterPosition starterName) as starter) ->
                                    Space.chompAndCheckIndent E.RecordSpace E.RecordIndentEquals
                                        |> P.andThen
                                            (\postStarterNameComments ->
                                                P.oneOf E.RecordEquals
                                                    [ P.word1 '|' E.RecordEquals
                                                        |> P.andThen (\_ -> Space.chompAndCheckIndent E.RecordSpace E.RecordIndentField)
                                                        |> P.andThen
                                                            (\postPipeComments ->
                                                                chompField [] postPipeComments
                                                            )
                                                        |> P.andThen (\( postFirstFieldComments, firstField ) -> chompFields postFirstFieldComments [ firstField ])
                                                        |> P.andThen
                                                            (\fields ->
                                                                let
                                                                    starterExpr : Src.Expr
                                                                    starterExpr =
                                                                        A.At starterPosition (Src.Var Src.LowVar starterName)
                                                                in
                                                                P.addEnd start (Src.Update ( ( preStarterNameComments, postStarterNameComments ), starterExpr ) fields)
                                                            )
                                                    , P.word1 '=' E.RecordEquals
                                                        |> P.andThen (\_ -> Space.chompAndCheckIndent E.RecordSpace E.RecordIndentExpr)
                                                        |> P.andThen
                                                            (\preValueComments ->
                                                                P.specialize E.RecordExpr expression
                                                                    |> P.andThen
                                                                        (\( ( postValueComments, value ), end ) ->
                                                                            let
                                                                                firstField : Field
                                                                                firstField =
                                                                                    ( ( [], preStarterNameComments, Nothing )
                                                                                    , ( ( postStarterNameComments, starter ), ( preValueComments, value ) )
                                                                                    )
                                                                            in
                                                                            Space.checkIndent end E.RecordIndentEnd
                                                                                |> P.andThen (\_ -> chompFields postValueComments [ firstField ])
                                                                                |> P.andThen (\fields -> P.addEnd start (Src.Record fields))
                                                                        )
                                                            )
                                                    ]
                                            )
                                )
                        ]
                )
        )


{-| Produces a parser that reads `.field` accesses after `expr` and reports a
failed field name as a record error. Nothing in this module calls it.
-}
accessibleRecord : A.Position -> Src.Expr -> P.Parser E.Record Src.Expr
accessibleRecord start expr =
    P.oneOfWithFallback
        [ P.word1 '.' E.RecordOpen
            |> P.andThen (\_ -> P.getPosition)
            |> P.andThen (\pos -> chompRecordAccessField start expr pos)
        ]
        expr


{-| Produces a parser for the field name after a dot at `pos`, wrapping `expr` in
that access and then reading any further accesses through `accessibleRecord`.
Nothing in this module calls it, except `accessibleRecord`.
-}
chompRecordAccessField : A.Position -> Src.Expr -> A.Position -> P.Parser E.Record Src.Expr
chompRecordAccessField start expr pos =
    Var.lower E.RecordOpen
        |> P.andThen (\field -> P.getPosition |> P.map (\end -> ( field, end )))
        |> P.andThen
            (\( field, end ) ->
                accessibleRecord start (A.at start end (Src.Access expr (A.at pos end field)))
            )



-- ====== RECORD FIELDS ======


{-| One `name = value` field of a record literal or record update, with the
comments around it.

The outer comment groups are the comments either side of the comma before the
field (for the first field, nothing and the comments after the `{` or `|`).
Then come the comments before the `=` with the name, and the comments after the
`=` with the value.

-}
type alias Field =
    Src.C2Eol ( Src.C1 (A.Located Name.Name), Src.C1 Src.Expr )


{-| Produces a parser for the fields of a record after the first, each preceded
by a comma, up to and including the `}`.

`fields` holds the fields read so far in reverse order, and the result has them
in source order, paired with the comments after the last field.

-}
chompFields : Src.FComments -> List Field -> P.Parser E.Record (Src.C1 (List Field))
chompFields trailingComments fields =
    P.oneOf E.RecordEnd
        [ P.word1 ',' E.RecordEnd
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.RecordSpace E.RecordIndentField)
            |> P.andThen (\postCommaComments -> chompField trailingComments postCommaComments)
            |> P.andThen (\( postFieldComments, f ) -> chompFields postFieldComments (f :: fields))
        , P.word1 '}' E.RecordEnd
            |> P.map (\_ -> ( trailingComments, List.reverse fields ))
        ]


{-| Produces a parser for one `name = value` field, given the comments before
and after the comma that precedes it (for an update's first field, nothing and
the comments after the `|`). The result is paired with the comments
after the value.
-}
chompField : Src.FComments -> Src.FComments -> P.Parser E.Record (Src.C1 Field)
chompField preCommaComents postCommaComments =
    P.addLocation (Var.lower E.RecordField)
        |> P.andThen
            (\key ->
                Space.chompAndCheckIndent E.RecordSpace E.RecordIndentEquals
                    |> P.andThen
                        (\preEqualSignComments ->
                            P.word1 '=' E.RecordEquals
                                |> P.andThen (\_ -> Space.chompAndCheckIndent E.RecordSpace E.RecordIndentExpr)
                                |> P.andThen
                                    (\postEqualSignComments ->
                                        P.specialize E.RecordExpr expression
                                            |> P.andThen
                                                (\( ( postFieldComments, value ), end ) ->
                                                    Space.checkIndent end E.RecordIndentEnd
                                                        |> P.map
                                                            (\_ ->
                                                                ( postFieldComments
                                                                , ( ( preCommaComents, postCommaComments, Nothing ), ( ( preEqualSignComments, key ), ( postEqualSignComments, value ) ) )
                                                                )
                                                            )
                                                )
                                    )
                        )
            )



-- ====== EXPRESSIONS ======


{-| A parser for a complete expression: a `let`, `if` or `case` expression, a
lambda, or a chain of a possibly negated term, its arguments, and binary
operators with their operands.

The expression is returned with the comments that follow it, and with the
position where it ends, which is before those comments. Operators are left
ungrouped in a `Src.Binops`, in source order.

-}
expression : Space.Parser E.Expr (Src.C1 Src.Expr)
expression =
    P.getPosition
        |> P.andThen
            (\start ->
                P.oneOf E.Start
                    [ let_ start
                    , if_ start
                    , case_ start
                    , function start
                    , possiblyNegativeTerm start
                        |> P.andThen
                            (\expr ->
                                P.getPosition
                                    |> P.andThen
                                        (\end ->
                                            Space.chomp E.Space
                                                |> P.andThen
                                                    (\comments ->
                                                        chompExprEnd
                                                            start
                                                            (State
                                                                { ops = []
                                                                , expr = expr
                                                                , args = []
                                                                , end = end
                                                                }
                                                            )
                                                            comments
                                                    )
                                        )
                            )
                    ]
            )


{-| The progress of a chain being read by `chompExprEnd`.

`expr` and `args` are the current operand, a possibly negated term and the
arguments applied to it so far, with `args` in reverse order and each argument carrying the comments
before it, except a negated argument (`f -x`), which carries the comments after
it. `ops` holds every earlier operand, already turned into a call, paired
with the operator after it and the comments either side of that operator, latest
first. `end` is where the last term read ends, the position the next token's
indentation is checked against.

-}
type State
    = State
        { ops : List ( Src.Expr, Src.C2 (A.Located Name.Name) )
        , expr : Src.Expr
        , args : List (Src.C1 Src.Expr)
        , end : A.Position
        }


{-| Produces a parser that finishes the chain described by the state, where
`comments` are the comments after its last term (empty after a negated
argument, which carries its trailing comments) and `start` is where the chain
began.

It reads, in order of preference, another argument term, or an operator and the
operand after it, and stops when neither an argument nor an operator can be
read. A `let`, `case`, `if` or lambda after an operator ends the chain. With no
operator read, the result is the current operand alone; otherwise it is a
`Src.Binops` spanning from `start`.

-}
chompExprEnd : A.Position -> State -> Src.FComments -> Space.Parser E.Expr (Src.C1 Src.Expr)
chompExprEnd start (State { ops, expr, args, end }) comments =
    P.oneOfWithFallback
        [ -- argument
          Space.checkIndent end E.Start
            |> P.andThen (\_ -> term)
            |> P.andThen
                (\arg ->
                    P.getPosition
                        |> P.andThen
                            (\newEnd ->
                                Space.chomp E.Space
                                    |> P.andThen
                                        (\trailingComments ->
                                            chompExprEnd
                                                start
                                                (State
                                                    { ops = ops
                                                    , expr = expr
                                                    , args = ( comments, arg ) :: args
                                                    , end = newEnd
                                                    }
                                                )
                                                trailingComments
                                        )
                            )
                )
        , -- operator
          Space.checkIndent end E.Start
            |> P.andThen (\_ -> P.addLocation (Symbol.operator E.Start E.OperatorReserved))
            |> P.andThen
                (\((A.At (A.Region opStart opEnd) opName) as op) ->
                    Space.chompAndCheckIndent E.Space (E.IndentOperatorRight opName)
                        |> P.andThen
                            (\postOpComments ->
                                P.getPosition
                                    |> P.andThen
                                        (\newStart ->
                                            if "-" == opName && end /= opStart && opEnd == newStart then
                                                -- negative terms
                                                term
                                                    |> P.andThen
                                                        (\negatedExpr ->
                                                            P.getPosition
                                                                |> P.andThen
                                                                    (\newEnd ->
                                                                        Space.chomp E.Space
                                                                            |> P.andThen
                                                                                (\postNegatedExprComments ->
                                                                                    let
                                                                                        arg : Src.C1 (A.Located Src.Expr_)
                                                                                        arg =
                                                                                            ( postNegatedExprComments, A.at opStart newEnd (Src.Negate negatedExpr) )
                                                                                    in
                                                                                    chompExprEnd
                                                                                        start
                                                                                        (State
                                                                                            { ops = ops
                                                                                            , expr = expr
                                                                                            , args = arg :: args
                                                                                            , end = newEnd
                                                                                            }
                                                                                        )
                                                                                        []
                                                                                )
                                                                    )
                                                        )

                                            else
                                                let
                                                    err : P.Row -> P.Col -> E.Expr
                                                    err =
                                                        E.OperatorRight opName
                                                in
                                                P.oneOf err
                                                    [ -- term
                                                      possiblyNegativeTerm newStart
                                                        |> P.andThen
                                                            (\newExpr ->
                                                                P.getPosition
                                                                    |> P.andThen
                                                                        (\newEnd ->
                                                                            Space.chomp E.Space
                                                                                |> P.andThen
                                                                                    (\trailingComments ->
                                                                                        let
                                                                                            newOps : List ( Src.Expr, Src.C2 (A.Located Name.Name) )
                                                                                            newOps =
                                                                                                ( toCall expr args, ( ( comments, postOpComments ), op ) ) :: ops
                                                                                        in
                                                                                        chompExprEnd
                                                                                            start
                                                                                            (State
                                                                                                { ops = newOps
                                                                                                , expr = newExpr
                                                                                                , args = []
                                                                                                , end = newEnd
                                                                                                }
                                                                                            )
                                                                                            trailingComments
                                                                                    )
                                                                        )
                                                            )
                                                    , -- final term
                                                      P.oneOf err
                                                        [ let_ newStart
                                                        , case_ newStart
                                                        , if_ newStart
                                                        , function newStart
                                                        ]
                                                        |> P.map
                                                            (\( ( trailingComments, newLast ), newEnd ) ->
                                                                let
                                                                    newOps : List ( Src.Expr, Src.C2 (A.Located Name.Name) )
                                                                    newOps =
                                                                        ( toCall expr args, ( ( comments, [] ), op ) ) :: ops

                                                                    finalExpr : Src.Expr_
                                                                    finalExpr =
                                                                        Src.Binops (List.reverse newOps) newLast
                                                                in
                                                                ( ( trailingComments, A.at start newEnd finalExpr ), newEnd )
                                                            )
                                                    ]
                                        )
                            )
                )
        ]
        -- done
        (case ops of
            [] ->
                ( ( comments, toCall expr args )
                , end
                )

            _ ->
                ( ( comments, A.at start end (Src.Binops (List.reverse ops) (toCall expr args)) )
                , end
                )
        )


{-| Produces a parser for a term starting at `start`, negated if a `-` comes
directly before it.
-}
possiblyNegativeTerm : A.Position -> P.Parser E.Expr Src.Expr
possiblyNegativeTerm start =
    P.oneOf E.Start
        [ P.word1 '-' E.Start
            |> P.andThen
                (\_ ->
                    term
                        |> P.andThen
                            (\expr ->
                                P.addEnd start (Src.Negate expr)
                            )
                )
        , term
        ]


{-| Returns `func` applied to the arguments in `revArgs`, which are in reverse
order, or `func` alone when there are none. The call's region runs from `func`
to the last argument.
-}
toCall : Src.Expr -> List (Src.C1 Src.Expr) -> Src.Expr
toCall func revArgs =
    case revArgs of
        [] ->
            func

        ( _, lastArg ) :: _ ->
            A.merge func lastArg (Src.Call func (List.reverse revArgs))



-- ====== IF EXPRESSION ======


{-| Produces a parser for an `if` expression starting at `start`, including any
`else if` branches.
-}
if_ : A.Position -> Space.Parser E.Expr (Src.C1 Src.Expr)
if_ start =
    chompIfEnd start [] [] |> P.inContext E.If (Keyword.if_ E.Start)


{-| Produces a parser for the rest of an `if` after the `if` keyword: a condition,
a `then` branch and an `else` branch.

`branches` holds the condition and `then` pairs already read, latest first, and
`comments` are the comments between the `else` and this `if`, empty for the
first `if`.

-}
chompIfEnd : A.Position -> Src.FComments -> List (Src.C1 ( Src.C2 Src.Expr, Src.C2 Src.Expr )) -> Space.Parser E.If (Src.C1 Src.Expr)
chompIfEnd start comments branches =
    Space.chompAndCheckIndent E.IfSpace E.IfIndentCondition
        |> P.andThen (\preConditionComments -> chompIfCondition start comments branches preConditionComments)


{-| Produces a parser for an `if` condition followed by the `then` keyword and
its branch, and what follows.
-}
chompIfCondition :
    A.Position
    -> Src.FComments
    -> List (Src.C1 ( Src.C2 Src.Expr, Src.C2 Src.Expr ))
    -> Src.FComments
    -> Space.Parser E.If (Src.C1 Src.Expr)
chompIfCondition start comments branches preConditionComments =
    P.specialize E.IfCondition expression
        |> P.andThen
            (\( ( postConditionComments, condition ), condEnd ) ->
                Space.checkIndent condEnd E.IfIndentThen
                    |> P.andThen (\_ -> Keyword.then_ E.IfThen)
                    |> P.andThen (\_ -> Space.chompAndCheckIndent E.IfSpace E.IfIndentThenBranch)
                    |> P.andThen (\preThenBranchComments -> chompIfThen start comments branches preConditionComments postConditionComments condition preThenBranchComments)
            )


{-| Produces a parser for the `then` branch of an `if`, followed by the `else`
keyword and what follows it.
-}
chompIfThen :
    A.Position
    -> Src.FComments
    -> List (Src.C1 ( Src.C2 Src.Expr, Src.C2 Src.Expr ))
    -> Src.FComments
    -> Src.FComments
    -> Src.Expr
    -> Src.FComments
    -> Space.Parser E.If (Src.C1 Src.Expr)
chompIfThen start comments branches preConditionComments postConditionComments condition preThenBranchComments =
    P.specialize E.IfThenBranch expression
        |> P.andThen
            (\( ( postThenBranchComments, thenBranch ), thenEnd ) ->
                Space.checkIndent thenEnd E.IfIndentElse
                    |> P.andThen (\_ -> Keyword.else_ E.IfElse)
                    |> P.andThen (\_ -> Space.chompAndCheckIndent E.IfSpace E.IfIndentElseBranch)
                    |> P.andThen
                        (\trailingComments ->
                            chompIfElse
                                start
                                comments
                                branches
                                preConditionComments
                                postConditionComments
                                condition
                                preThenBranchComments
                                postThenBranchComments
                                thenBranch
                                trailingComments
                        )
            )


{-| Produces a parser for what follows an `else`: either another `if`, which
adds a condition and branch to the same `Src.If`, or the final `else` branch.

So `else if` does not nest; a chain of them is one `Src.If` with several
condition and branch pairs.

-}
chompIfElse :
    A.Position
    -> Src.FComments
    -> List (Src.C1 ( Src.C2 Src.Expr, Src.C2 Src.Expr ))
    -> Src.FComments
    -> Src.FComments
    -> Src.Expr
    -> Src.FComments
    -> Src.FComments
    -> Src.Expr
    -> Src.FComments
    -> Space.Parser E.If (Src.C1 Src.Expr)
chompIfElse start comments branches preConditionComments postConditionComments condition preThenBranchComments postThenBranchComments thenBranch trailingComments =
    let
        conditionPair : Src.C2 Src.Expr
        conditionPair =
            ( ( preConditionComments, postConditionComments ), condition )

        thenPair : Src.C2 Src.Expr
        thenPair =
            ( ( preThenBranchComments, postThenBranchComments ), thenBranch )

        newBranch : Src.C1 ( Src.C2 Src.Expr, Src.C2 Src.Expr )
        newBranch =
            ( comments, ( conditionPair, thenPair ) )

        newBranches : List (Src.C1 ( Src.C2 Src.Expr, Src.C2 Src.Expr ))
        newBranches =
            newBranch :: branches
    in
    P.oneOf E.IfElseBranchStart
        [ Keyword.if_ E.IfElseBranchStart
            |> P.andThen (\_ -> chompIfEnd start trailingComments newBranches)
        , P.specialize E.IfElseBranch expression
            |> P.map (buildIfExpr start newBranch newBranches trailingComments)
        ]


{-| Returns the `Src.If` built from the branches read, with `newBranches` latest
first, and the final `else` branch, spanning from `start` to the end of the
`else` branch.

`newBranch` is a stand-in for the first branch should the list be empty, which
it never is here.

-}
buildIfExpr :
    A.Position
    -> Src.C1 ( Src.C2 Src.Expr, Src.C2 Src.Expr )
    -> List (Src.C1 ( Src.C2 Src.Expr, Src.C2 Src.Expr ))
    -> Src.FComments
    -> ( Src.C1 Src.Expr, A.Position )
    -> ( Src.C1 Src.Expr, A.Position )
buildIfExpr start newBranch newBranches trailingComments ( ( postElseBranch, elseBranch ), elseEnd ) =
    let
        reversedBranches : List (Src.C1 ( Src.C2 Src.Expr, Src.C2 Src.Expr ))
        reversedBranches =
            List.reverse newBranches

        firstBranch : Src.C1 ( Src.C2 Src.Expr, Src.C2 Src.Expr )
        firstBranch =
            Maybe.withDefault newBranch (List.head reversedBranches)

        restBranches : List (Src.C1 ( Src.C2 Src.Expr, Src.C2 Src.Expr ))
        restBranches =
            Maybe.withDefault [] (List.tail reversedBranches)

        ifExpr : Src.Expr_
        ifExpr =
            Src.If firstBranch restBranches ( trailingComments, elseBranch )
    in
    ( ( postElseBranch, A.at start elseEnd ifExpr ), elseEnd )



-- ====== LAMBDA EXPRESSION ======


{-| Produces a parser for a lambda such as `\x y -> x`, starting at the
backslash at `start`.
-}
function : A.Position -> Space.Parser E.Expr (Src.C1 Src.Expr)
function start =
    P.inContext E.Func (P.word1 '\\' E.Start) <|
        (Space.chompAndCheckIndent E.FuncSpace E.FuncIndentArg
            |> P.andThen (\preArgComments -> chompFunctionFirstArg start preArgComments)
        )


{-| Produces a parser for a lambda's first argument and the rest of the lambda.
Arguments are pattern terms, as `Compiler.Parse.Pattern` defines them.
-}
chompFunctionFirstArg : A.Position -> Src.FComments -> Space.Parser E.Func (Src.C1 Src.Expr)
chompFunctionFirstArg start preArgComments =
    P.specialize E.FuncArg Pattern.term
        |> P.andThen (\arg -> chompFunctionArgs start preArgComments arg)


{-| Produces a parser for the rest of a lambda after its first argument `arg`:
any further arguments, the `->` and the body.
-}
chompFunctionArgs : A.Position -> Src.FComments -> Src.Pattern -> Space.Parser E.Func (Src.C1 Src.Expr)
chompFunctionArgs start preArgComments arg =
    Space.chompAndCheckIndent E.FuncSpace E.FuncIndentArrow
        |> P.andThen (\trailingComments -> chompArgs trailingComments [ ( preArgComments, arg ) ])
        |> P.andThen (\( trailingComments, revArgs ) -> chompFunctionBody start trailingComments revArgs)


{-| Produces a parser for a lambda's body after the `->`, building the lambda
from the arguments in `revArgs`, which are in reverse order.
-}
chompFunctionBody : A.Position -> Src.FComments -> List (Src.C1 Src.Pattern) -> Space.Parser E.Func (Src.C1 Src.Expr)
chompFunctionBody start trailingComments revArgs =
    Space.chompAndCheckIndent E.FuncSpace E.FuncIndentBody
        |> P.andThen
            (\preComments ->
                P.specialize E.FuncBody expression
                    |> P.map (\( ( afterBodyComments, body ), end ) -> ( afterBodyComments, ( preComments, body ), end ))
            )
        |> P.map (\( afterBodyComments, body, end ) -> buildFunctionExpr start trailingComments revArgs afterBodyComments body end)


{-| Returns the `Src.Lambda` with the arguments in `revArgs` put back into source
order, spanning from `start` to `end`, the end of its body.
-}
buildFunctionExpr : A.Position -> Src.FComments -> List (Src.C1 Src.Pattern) -> Src.FComments -> Src.C1 Src.Expr -> A.Position -> ( Src.C1 Src.Expr, A.Position )
buildFunctionExpr start trailingComments revArgs afterBodyComments body end =
    let
        funcExpr : Src.Expr_
        funcExpr =
            Src.Lambda ( trailingComments, List.reverse revArgs ) body
    in
    ( ( afterBodyComments, A.at start end funcExpr ), end )


{-| Produces a parser for further lambda arguments up to and including the `->`.

Each argument carries the comments before it, and the result is paired with
the comments before the `->`. `revArgs` and the returned list are in reverse
order.

-}
chompArgs : Src.FComments -> List (Src.C1 Src.Pattern) -> P.Parser E.Func (Src.C1 (List (Src.C1 Src.Pattern)))
chompArgs trailingComments revArgs =
    P.oneOf E.FuncArrow
        [ P.specialize E.FuncArg Pattern.term
            |> P.andThen
                (\arg ->
                    Space.chompAndCheckIndent E.FuncSpace E.FuncIndentArrow
                        |> P.andThen (\postArgComments -> chompArgs postArgComments (( trailingComments, arg ) :: revArgs))
                )
        , P.word2 '-' '>' E.FuncArrow
            |> P.map (\_ -> ( trailingComments, revArgs ))
        ]



-- ====== CASE EXPRESSIONS ======


{-| Produces a parser for a `case` expression starting at `start`.
-}
case_ : A.Position -> Space.Parser E.Expr (Src.C1 Src.Expr)
case_ start =
    P.inContext E.Case (Keyword.case_ E.Start) <|
        (Space.chompAndCheckIndent E.CaseSpace E.CaseIndentExpr
            |> P.andThen (\preExprComments -> chompCaseExpr start preExprComments)
        )


{-| Produces a parser for the expression a `case` examines, and the rest of the
`case` after it.
-}
chompCaseExpr : A.Position -> Src.FComments -> Space.Parser E.Case (Src.C1 Src.Expr)
chompCaseExpr start preExprComments =
    P.specialize E.CaseExpr expression
        |> P.andThen
            (\( ( postExprComments, expr ), exprEnd ) ->
                chompCaseOf start preExprComments postExprComments expr exprEnd
            )


{-| Produces a parser for the `of` keyword after the examined expression and the
branches after it.
-}
chompCaseOf : A.Position -> Src.FComments -> Src.FComments -> Src.Expr -> A.Position -> Space.Parser E.Case (Src.C1 Src.Expr)
chompCaseOf start preExprComments postExprComments expr exprEnd =
    Space.checkIndent exprEnd E.CaseIndentOf
        |> P.andThen (\_ -> Keyword.of_ E.CaseOf)
        |> P.andThen (\_ -> Space.chompAndCheckIndent E.CaseSpace E.CaseIndentPattern)
        |> P.andThen (\comments -> chompCaseBranches start preExprComments postExprComments expr comments)


{-| Produces a parser for the branches of a `case`, with the indent set to the
column of the first branch's pattern, so that every later branch must start in
that column.
-}
chompCaseBranches : A.Position -> Src.FComments -> Src.FComments -> Src.Expr -> Src.FComments -> Space.Parser E.Case (Src.C1 Src.Expr)
chompCaseBranches start preExprComments postExprComments expr comments =
    P.withIndent
        (chompBranch comments
            |> P.andThen
                (\( ( trailingComments, firstBranch ), firstEnd ) ->
                    chompCaseEnd trailingComments [ firstBranch ] firstEnd
                        |> P.map (buildCaseExpr start preExprComments postExprComments expr)
                )
        )


{-| Returns the `Src.Case` built from the examined `expr` and its branches,
spanning from `start` to the end of the last branch.
-}
buildCaseExpr : A.Position -> Src.FComments -> Src.FComments -> Src.Expr -> ( Src.C1 (List ( Src.C2 Src.Pattern, Src.C1 Src.Expr )), A.Position ) -> ( Src.C1 Src.Expr, A.Position )
buildCaseExpr start preExprComments postExprComments expr ( ( branchesTrailingComments, branches ), end ) =
    ( ( branchesTrailingComments, A.at start end (Src.Case ( ( preExprComments, postExprComments ), expr ) branches) )
    , end
    )


{-| Produces a parser for one `case` branch: a pattern, the `->` and an
expression. Unlike function arguments, the pattern may be any pattern, not only
a term.
-}
chompBranch : Src.FComments -> Space.Parser E.Case (Src.C1 ( Src.C2 Src.Pattern, Src.C1 Src.Expr ))
chompBranch prePatternComments =
    P.specialize E.CasePattern Pattern.expression
        |> P.andThen (\( ( postPatternComments, pattern ), patternEnd ) -> chompBranchArrow prePatternComments postPatternComments pattern patternEnd)


{-| Produces a parser for the `->` after a branch's pattern and the expression
after it.
-}
chompBranchArrow : Src.FComments -> Src.FComments -> Src.Pattern -> A.Position -> Space.Parser E.Case (Src.C1 ( Src.C2 Src.Pattern, Src.C1 Src.Expr ))
chompBranchArrow prePatternComments postPatternComments pattern patternEnd =
    Space.checkIndent patternEnd E.CaseIndentArrow
        |> P.andThen (\_ -> P.word2 '-' '>' E.CaseArrow)
        |> P.andThen (\_ -> Space.chompAndCheckIndent E.CaseSpace E.CaseIndentBranch)
        |> P.andThen (\preBranchExprComments -> chompBranchExpr prePatternComments postPatternComments pattern preBranchExprComments)


{-| Produces a parser for the expression of a `case` branch.
-}
chompBranchExpr : Src.FComments -> Src.FComments -> Src.Pattern -> Src.FComments -> Space.Parser E.Case (Src.C1 ( Src.C2 Src.Pattern, Src.C1 Src.Expr ))
chompBranchExpr prePatternComments postPatternComments pattern preBranchExprComments =
    P.specialize E.CaseBranch expression
        |> P.map (buildBranchResult prePatternComments postPatternComments pattern preBranchExprComments)


{-| Returns one `case` branch built from its pattern, its expression and the
comments around them, paired with the comments after the expression and the
position where it ends.
-}
buildBranchResult : Src.FComments -> Src.FComments -> Src.Pattern -> Src.FComments -> ( Src.C1 Src.Expr, A.Position ) -> ( Src.C1 ( Src.C2 Src.Pattern, Src.C1 Src.Expr ), A.Position )
buildBranchResult prePatternComments postPatternComments pattern preBranchExprComments ( ( trailingComments, branchExpr ), end ) =
    ( ( trailingComments
      , ( ( ( prePatternComments, postPatternComments ), pattern )
        , ( preBranchExprComments, branchExpr )
        )
      )
    , end
    )


{-| Produces a parser for further `case` branches, each starting in the column
of the first one, and returns all the branches in source order once no more
line starts there.

`branches` is in reverse order; `prePatternComments` are the comments after the
latest branch, which go with the next branch if there is one and with the
whole list otherwise.

-}
chompCaseEnd : Src.FComments -> List ( Src.C2 Src.Pattern, Src.C1 Src.Expr ) -> A.Position -> Space.Parser E.Case (Src.C1 (List ( Src.C2 Src.Pattern, Src.C1 Src.Expr )))
chompCaseEnd prePatternComments branches end =
    P.oneOfWithFallback
        [ Space.checkAligned E.CasePatternAlignment
            |> P.andThen (\_ -> chompBranch prePatternComments)
            |> P.andThen (\( ( comments, branch ), newEnd ) -> chompCaseEnd comments (branch :: branches) newEnd)
        ]
        ( ( prePatternComments, List.reverse branches ), end )



-- ====== LET EXPRESSION ======


{-| Produces a parser for a `let` expression starting at `start`.

The first definition must start in a column to the right of the column where
`let` begins. The outer indent is restored before the `in`, which only needs to
be indented past it.

-}
let_ : A.Position -> Space.Parser E.Expr (Src.C1 Src.Expr)
let_ start =
    P.inContext E.Let (Keyword.let_ E.Start) <|
        ((P.withBacksetIndent 3 <|
            (Space.chompAndCheckIndent E.LetSpace E.LetIndentDef
                |> P.andThen (\preDefComments -> chompLetFirstDef preDefComments)
            )
         )
            |> P.andThen (\( defs, defsEnd ) -> chompLetIn start defs defsEnd)
        )


{-| Produces a parser for the definitions of a `let`, with the indent set to the
column of the first one, so that every later definition must start in that
column. `preDefComments` are the comments before the first definition.
-}
chompLetFirstDef : Src.FComments -> Space.Parser E.Let (List (Src.C2 (A.Located Src.Def)))
chompLetFirstDef preDefComments =
    P.withIndent <|
        (chompLetDef
            |> P.andThen (\( ( postDefComments, def ), end ) -> chompLetDefs [ ( ( preDefComments, postDefComments ), def ) ] end)
        )


{-| Produces a parser for the `in` keyword after the definitions, which end at
`defsEnd`, and the body after it.
-}
chompLetIn : A.Position -> List (Src.C2 (A.Located Src.Def)) -> A.Position -> Space.Parser E.Let (Src.C1 Src.Expr)
chompLetIn start defs defsEnd =
    Space.checkIndent defsEnd E.LetIndentIn
        |> P.andThen (\_ -> Keyword.in_ E.LetIn)
        |> P.andThen (\_ -> Space.chompAndCheckIndent E.LetSpace E.LetIndentBody)
        |> P.andThen (\bodyComments -> chompLetBody start defs bodyComments)


{-| Produces a parser for the body of a `let` after the `in`.
-}
chompLetBody : A.Position -> List (Src.C2 (A.Located Src.Def)) -> Src.FComments -> Space.Parser E.Let (Src.C1 Src.Expr)
chompLetBody start defs bodyComments =
    P.specialize E.LetBody expression
        |> P.map (buildLetExpr start defs bodyComments)


{-| Returns the `Src.Let` built from `defs` and the body, spanning from `start`
to the end of the body.
-}
buildLetExpr : A.Position -> List (Src.C2 (A.Located Src.Def)) -> Src.FComments -> ( Src.C1 Src.Expr, A.Position ) -> ( Src.C1 Src.Expr, A.Position )
buildLetExpr start defs bodyComments ( ( trailingComments, body ), end ) =
    ( ( trailingComments, A.at start end (Src.Let defs bodyComments body) ), end )


{-| Produces a parser for further `let` definitions, each starting in the column
of the first one, and returns them all in source order once no more line starts
there.

Each definition carries the comments after it. Only the first also carries
comments before it; between two definitions the comments go with the earlier
one.

-}
chompLetDefs : List (Src.C2 (A.Located Src.Def)) -> A.Position -> Space.Parser E.Let (List (Src.C2 (A.Located Src.Def)))
chompLetDefs revDefs end =
    P.oneOfWithFallback
        [ Space.checkAligned E.LetDefAlignment
            |> P.andThen (\_ -> chompLetDef)
            |> P.andThen (\( ( postDefComments, def ), newEnd ) -> chompLetDefs (( ( [], postDefComments ), def ) :: revDefs) newEnd)
        ]
        ( List.reverse revDefs, end )



-- ====== LET DEFINITIONS ======


{-| A parser for one `let` definition: a named definition, possibly with a type
annotation, or a destructuring `pattern = value`.
-}
chompLetDef : Space.Parser E.Let (Src.C1 (A.Located Src.Def))
chompLetDef =
    P.oneOf E.LetDefName
        [ definition
        , destructure
        ]



-- ====== DEFINITION ======


{-| A parser for a named `let` definition, with or without a type annotation,
starting at its name.
-}
definition : Space.Parser E.Let (Src.C1 (A.Located Src.Def))
definition =
    P.addLocation (Var.lower E.LetDefName)
        |> P.andThen (\aname -> chompDefinitionBody aname)


{-| Produces a parser for what follows the name `aname` in a `let` definition: a
type annotation and the definition it annotates, or arguments and a body.
-}
chompDefinitionBody : A.Located Name.Name -> Space.Parser E.Let (Src.C1 (A.Located Src.Def))
chompDefinitionBody ((A.At (A.Region start _) name) as aname) =
    P.specialize (E.LetDef name) <|
        (Space.chompAndCheckIndent E.DefSpace E.DefIndentEquals
            |> P.andThen (\postNameComments -> chompDefinitionEqualsOrType start name aname postNameComments)
        )


{-| Produces a parser that reads a type annotation after `:` and then the
definition it annotates, or otherwise the arguments and body of an unannotated
definition.
-}
chompDefinitionEqualsOrType : A.Position -> Name.Name -> A.Located Name.Name -> Src.FComments -> Space.Parser E.Def (Src.C1 (A.Located Src.Def))
chompDefinitionEqualsOrType start name aname postNameComments =
    P.oneOf E.DefEquals
        [ P.word1 ':' E.DefEquals
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.DefSpace E.DefIndentType)
            |> P.andThen (\preTypeComments -> P.specialize E.DefType (Type.expression preTypeComments))
            |> P.andThen (\( ( ( preTipeComments, postTipeComments, _ ), tipe ), _ ) -> chompDefinitionAfterType start name postNameComments preTipeComments postTipeComments tipe)
        , chompDefArgsAndBody start aname Nothing postNameComments []
        ]


{-| Produces a parser for the definition that follows a type annotation for
`name`.

The definition must start in the same column as the annotation and repeat the
name; a different name fails with `E.DefNameMatch`.

-}
chompDefinitionAfterType : A.Position -> Name.Name -> Src.FComments -> Src.FComments -> Src.FComments -> Src.Type -> Space.Parser E.Def (Src.C1 (A.Located Src.Def))
chompDefinitionAfterType start name postNameComments preTipeComments postTipeComments tipe =
    Space.checkAligned E.DefAlignment
        |> P.andThen (\_ -> chompMatchingName name)
        |> P.andThen (\defName -> chompDefinitionWithType start defName postNameComments preTipeComments postTipeComments tipe)


{-| Produces a parser for the arguments and body of a definition whose name
`defName` has been read after its annotation, attaching the annotation to it.
-}
chompDefinitionWithType : A.Position -> A.Located Name.Name -> Src.FComments -> Src.FComments -> Src.FComments -> Src.Type -> Space.Parser E.Def (Src.C1 (A.Located Src.Def))
chompDefinitionWithType start defName postNameComments preTipeComments postTipeComments tipe =
    Space.chompAndCheckIndent E.DefSpace E.DefIndentEquals
        |> P.andThen
            (\trailingComments ->
                let
                    typeAnnotation : Maybe (Src.C1 (Src.C2 Src.Type))
                    typeAnnotation =
                        Just ( postTipeComments, ( ( postNameComments, preTipeComments ), tipe ) )
                in
                chompDefArgsAndBody start defName typeAnnotation trailingComments []
            )


{-| Produces a parser for a definition's argument patterns up to the `=`, and its
body.

The arguments are pattern terms. Each carries the comments before it, and the
body carries the comments between the last argument (or the name) and the `=`
followed by those after the `=`. The definition's region runs from `start`,
the start of its first name, to the end of the body.

-}
chompDefArgsAndBody :
    A.Position
    -> A.Located Name.Name
    -> Maybe (Src.C1 (Src.C2 Src.Type))
    -> Src.FComments
    -> List (Src.C1 Src.Pattern)
    -> Space.Parser E.Def (Src.C1 (A.Located Src.Def))
chompDefArgsAndBody start name tipe trailingComments revArgs =
    P.oneOf E.DefEquals
        [ P.specialize E.DefArg Pattern.term
            |> P.andThen
                (\arg ->
                    Space.chompAndCheckIndent E.DefSpace E.DefIndentEquals
                        |> P.andThen (\comments -> chompDefArgsAndBody start name tipe comments (( trailingComments, arg ) :: revArgs))
                )
        , P.word1 '=' E.DefEquals
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.DefSpace E.DefIndentBody)
            |> P.andThen
                (\preExpressionComments ->
                    P.specialize E.DefBody expression
                        |> P.map
                            (\( ( comments, body ), end ) ->
                                ( ( comments, A.at start end (Src.Define name (List.reverse revArgs) ( trailingComments ++ preExpressionComments, body ) tipe) )
                                , end
                                )
                            )
                )
        ]


{-| Produces a parser for a lower-case name that must equal `expectedName`, as
the name repeated after a type annotation must.

A different name fails with `E.DefNameMatch` at the start of the name, with the
outcome marked consumed when the name was. The name's region is where it was
read.

-}
chompMatchingName : Name.Name -> P.Parser E.Def (A.Located Name.Name)
chompMatchingName expectedName =
    let
        (P.Parser parserL) =
            Var.lower E.DefNameRepeat
    in
    P.Parser <|
        \((P.State st) as state) ->
            case parserL state of
                P.Cok name ((P.State st2) as newState) ->
                    if expectedName == name then
                        P.Cok (A.At (A.Region (A.Position st.row st.col) (A.Position st2.row st2.col)) name) newState

                    else
                        P.Cerr st.row st.col (E.DefNameMatch name)

                P.Eok name ((P.State st2) as newState) ->
                    if expectedName == name then
                        P.Eok (A.At (A.Region (A.Position st.row st.col) (A.Position st2.row st2.col)) name) newState

                    else
                        P.Eerr st.row st.col (E.DefNameMatch name)

                P.Cerr r c t ->
                    P.Cerr r c t

                P.Eerr r c t ->
                    P.Eerr r c t



-- ====== DESTRUCTURE ======


{-| A parser for a destructuring `let` definition such as `( x, y ) = point`. The
pattern must be a pattern term.
-}
destructure : Space.Parser E.Let (Src.C1 (A.Located Src.Def))
destructure =
    P.specialize E.LetDestruct <|
        (P.getPosition
            |> P.andThen (\start -> chompDestructPattern start)
        )


{-| Produces a parser for a destructuring definition from its pattern at `start`
onward.
-}
chompDestructPattern : A.Position -> Space.Parser E.Destruct (Src.C1 (A.Located Src.Def))
chompDestructPattern start =
    P.specialize E.DestructPattern Pattern.term
        |> P.andThen (\pattern -> chompDestructEquals start pattern)


{-| Produces a parser for what follows a destructuring pattern: the `=` and the
value.
-}
chompDestructEquals : A.Position -> Src.Pattern -> Space.Parser E.Destruct (Src.C1 (A.Located Src.Def))
chompDestructEquals start pattern =
    Space.chompAndCheckIndent E.DestructSpace E.DestructIndentEquals
        |> P.andThen (\preEqualSignComments -> chompDestructBody start pattern preEqualSignComments)


{-| Produces a parser for the `=` of a destructuring definition and the value
after it.
-}
chompDestructBody : A.Position -> Src.Pattern -> Src.FComments -> Space.Parser E.Destruct (Src.C1 (A.Located Src.Def))
chompDestructBody start pattern preEqualSignComments =
    P.word1 '=' E.DestructEquals
        |> P.andThen (\_ -> Space.chompAndCheckIndent E.DestructSpace E.DestructIndentBody)
        |> P.andThen (\preExpressionComments -> chompDestructExpr start pattern preEqualSignComments preExpressionComments)


{-| Produces a parser for the value of a destructuring definition.
-}
chompDestructExpr : A.Position -> Src.Pattern -> Src.FComments -> Src.FComments -> Space.Parser E.Destruct (Src.C1 (A.Located Src.Def))
chompDestructExpr start pattern preEqualSignComments preExpressionComments =
    P.specialize E.DestructBody expression
        |> P.map (buildDestructDef start pattern preEqualSignComments preExpressionComments)


{-| Returns the `Src.Destruct` definition of `pattern`, whose value carries the
comments before and after the `=` together, spanning from `start` to the end of
the value.
-}
buildDestructDef : A.Position -> Src.Pattern -> Src.FComments -> Src.FComments -> ( Src.C1 Src.Expr, A.Position ) -> ( Src.C1 (A.Located Src.Def), A.Position )
buildDestructDef start pattern preEqualSignComments preExpressionComments ( ( comments, expr ), end ) =
    ( ( comments, A.at start end (Src.Destruct pattern ( preEqualSignComments ++ preExpressionComments, expr )) )
    , end
    )
