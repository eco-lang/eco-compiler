module Compiler.Parse.Expression exposing (expression, record)

{-| Expression parser for Elm source code.

This module parses Elm expressions into the Source AST, handling:

  - Literals (strings, numbers, characters)
  - Variables and qualified names
  - Operators and operator sections
  - Function application and lambdas
  - Control flow (if/then/else, case/of, let/in)
  - Data structures (lists, tuples, records)
  - Record access and update syntax


# Parsing

@docs expression, record

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


string : A.Position -> P.Parser E.Expr Src.Expr
string start =
    String.string E.Start E.String_
        |> P.andThen (\( str, representation ) -> P.addEnd start (Src.Str str representation))


character : A.Position -> P.Parser E.Expr Src.Expr
character start =
    String.character E.Start E.Char
        |> P.andThen (\chr -> P.addEnd start (Src.Chr chr))


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


accessor : A.Position -> P.Parser E.Expr Src.Expr
accessor start =
    P.word1 '.' E.Dot
        |> P.andThen (\_ -> Var.lower E.Access)
        |> P.andThen (\field -> P.addEnd start (Src.Accessor field))


variable : A.Position -> P.Parser E.Expr Src.Expr
variable start =
    Var.foreignAlpha E.Start
        |> P.andThen (\var -> P.addEnd start var)


accessible : A.Position -> Src.Expr -> P.Parser E.Expr Src.Expr
accessible start expr =
    P.oneOfWithFallback
        [ P.word1 '.' E.Dot
            |> P.andThen (\_ -> P.getPosition)
            |> P.andThen (\pos -> chompAccessField start expr pos)
        ]
        expr


chompAccessField : A.Position -> Src.Expr -> A.Position -> P.Parser E.Expr Src.Expr
chompAccessField start expr pos =
    Var.lower E.Access
        |> P.andThen (\field -> P.getPosition |> P.map (\end -> ( field, end )))
        |> P.andThen
            (\( field, end ) ->
                accessible start (A.at start end (Src.Access expr (A.at pos end field)))
            )



-- ====== LISTS ======


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


{-| Parse record expressions including record literals and record update syntax.
Handles both empty records and records with fields.
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


accessibleRecord : A.Position -> Src.Expr -> P.Parser E.Record Src.Expr
accessibleRecord start expr =
    P.oneOfWithFallback
        [ P.word1 '.' E.RecordOpen
            |> P.andThen (\_ -> P.getPosition)
            |> P.andThen (\pos -> chompRecordAccessField start expr pos)
        ]
        expr


chompRecordAccessField : A.Position -> Src.Expr -> A.Position -> P.Parser E.Record Src.Expr
chompRecordAccessField start expr pos =
    Var.lower E.RecordOpen
        |> P.andThen (\field -> P.getPosition |> P.map (\end -> ( field, end )))
        |> P.andThen
            (\( field, end ) ->
                accessibleRecord start (A.at start end (Src.Access expr (A.at pos end field)))
            )



-- ====== FOREIGN ALPHA ======


type alias Field =
    Src.C2Eol ( Src.C1 (A.Located Name.Name), Src.C1 Src.Expr )


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


{-| Parse a complete Elm expression including operators, function application,
and special forms like if/case/let/lambda. Returns the parsed expression with
associated comments and position information.
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


type State
    = State
        { ops : List ( Src.Expr, Src.C2 (A.Located Name.Name) )
        , expr : Src.Expr
        , args : List (Src.C1 Src.Expr)
        , end : A.Position
        }


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


toCall : Src.Expr -> List (Src.C1 Src.Expr) -> Src.Expr
toCall func revArgs =
    case revArgs of
        [] ->
            func

        ( _, lastArg ) :: _ ->
            A.merge func lastArg (Src.Call func (List.reverse revArgs))



-- ====== IF EXPRESSION ======


if_ : A.Position -> Space.Parser E.Expr (Src.C1 Src.Expr)
if_ start =
    chompIfEnd start [] [] |> P.inContext E.If (Keyword.if_ E.Start)


chompIfEnd : A.Position -> Src.FComments -> List (Src.C1 ( Src.C2 Src.Expr, Src.C2 Src.Expr )) -> Space.Parser E.If (Src.C1 Src.Expr)
chompIfEnd start comments branches =
    Space.chompAndCheckIndent E.IfSpace E.IfIndentCondition
        |> P.andThen (\preConditionComments -> chompIfCondition start comments branches preConditionComments)


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


function : A.Position -> Space.Parser E.Expr (Src.C1 Src.Expr)
function start =
    P.inContext E.Func (P.word1 '\\' E.Start) <|
        (Space.chompAndCheckIndent E.FuncSpace E.FuncIndentArg
            |> P.andThen (\preArgComments -> chompFunctionFirstArg start preArgComments)
        )


chompFunctionFirstArg : A.Position -> Src.FComments -> Space.Parser E.Func (Src.C1 Src.Expr)
chompFunctionFirstArg start preArgComments =
    P.specialize E.FuncArg Pattern.term
        |> P.andThen (\arg -> chompFunctionArgs start preArgComments arg)


chompFunctionArgs : A.Position -> Src.FComments -> Src.Pattern -> Space.Parser E.Func (Src.C1 Src.Expr)
chompFunctionArgs start preArgComments arg =
    Space.chompAndCheckIndent E.FuncSpace E.FuncIndentArrow
        |> P.andThen (\trailingComments -> chompArgs trailingComments [ ( preArgComments, arg ) ])
        |> P.andThen (\( trailingComments, revArgs ) -> chompFunctionBody start trailingComments revArgs)


chompFunctionBody : A.Position -> Src.FComments -> List (Src.C1 Src.Pattern) -> Space.Parser E.Func (Src.C1 Src.Expr)
chompFunctionBody start trailingComments revArgs =
    Space.chompAndCheckIndent E.FuncSpace E.FuncIndentBody
        |> P.andThen
            (\preComments ->
                P.specialize E.FuncBody expression
                    |> P.map (\( ( afterBodyComments, body ), end ) -> ( afterBodyComments, ( preComments, body ), end ))
            )
        |> P.map (\( afterBodyComments, body, end ) -> buildFunctionExpr start trailingComments revArgs afterBodyComments body end)


buildFunctionExpr : A.Position -> Src.FComments -> List (Src.C1 Src.Pattern) -> Src.FComments -> Src.C1 Src.Expr -> A.Position -> ( Src.C1 Src.Expr, A.Position )
buildFunctionExpr start trailingComments revArgs afterBodyComments body end =
    let
        funcExpr : Src.Expr_
        funcExpr =
            Src.Lambda ( trailingComments, List.reverse revArgs ) body
    in
    ( ( afterBodyComments, A.at start end funcExpr ), end )


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


case_ : A.Position -> Space.Parser E.Expr (Src.C1 Src.Expr)
case_ start =
    P.inContext E.Case (Keyword.case_ E.Start) <|
        (Space.chompAndCheckIndent E.CaseSpace E.CaseIndentExpr
            |> P.andThen (\preExprComments -> chompCaseExpr start preExprComments)
        )


chompCaseExpr : A.Position -> Src.FComments -> Space.Parser E.Case (Src.C1 Src.Expr)
chompCaseExpr start preExprComments =
    P.specialize E.CaseExpr expression
        |> P.andThen
            (\( ( postExprComments, expr ), exprEnd ) ->
                chompCaseOf start preExprComments postExprComments expr exprEnd
            )


chompCaseOf : A.Position -> Src.FComments -> Src.FComments -> Src.Expr -> A.Position -> Space.Parser E.Case (Src.C1 Src.Expr)
chompCaseOf start preExprComments postExprComments expr exprEnd =
    Space.checkIndent exprEnd E.CaseIndentOf
        |> P.andThen (\_ -> Keyword.of_ E.CaseOf)
        |> P.andThen (\_ -> Space.chompAndCheckIndent E.CaseSpace E.CaseIndentPattern)
        |> P.andThen (\comments -> chompCaseBranches start preExprComments postExprComments expr comments)


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


buildCaseExpr : A.Position -> Src.FComments -> Src.FComments -> Src.Expr -> ( Src.C1 (List ( Src.C2 Src.Pattern, Src.C1 Src.Expr )), A.Position ) -> ( Src.C1 Src.Expr, A.Position )
buildCaseExpr start preExprComments postExprComments expr ( ( branchesTrailingComments, branches ), end ) =
    ( ( branchesTrailingComments, A.at start end (Src.Case ( ( preExprComments, postExprComments ), expr ) branches) )
    , end
    )


chompBranch : Src.FComments -> Space.Parser E.Case (Src.C1 ( Src.C2 Src.Pattern, Src.C1 Src.Expr ))
chompBranch prePatternComments =
    P.specialize E.CasePattern Pattern.expression
        |> P.andThen (\( ( postPatternComments, pattern ), patternEnd ) -> chompBranchArrow prePatternComments postPatternComments pattern patternEnd)


chompBranchArrow : Src.FComments -> Src.FComments -> Src.Pattern -> A.Position -> Space.Parser E.Case (Src.C1 ( Src.C2 Src.Pattern, Src.C1 Src.Expr ))
chompBranchArrow prePatternComments postPatternComments pattern patternEnd =
    Space.checkIndent patternEnd E.CaseIndentArrow
        |> P.andThen (\_ -> P.word2 '-' '>' E.CaseArrow)
        |> P.andThen (\_ -> Space.chompAndCheckIndent E.CaseSpace E.CaseIndentBranch)
        |> P.andThen (\preBranchExprComments -> chompBranchExpr prePatternComments postPatternComments pattern preBranchExprComments)


chompBranchExpr : Src.FComments -> Src.FComments -> Src.Pattern -> Src.FComments -> Space.Parser E.Case (Src.C1 ( Src.C2 Src.Pattern, Src.C1 Src.Expr ))
chompBranchExpr prePatternComments postPatternComments pattern preBranchExprComments =
    P.specialize E.CaseBranch expression
        |> P.map (buildBranchResult prePatternComments postPatternComments pattern preBranchExprComments)


buildBranchResult : Src.FComments -> Src.FComments -> Src.Pattern -> Src.FComments -> ( Src.C1 Src.Expr, A.Position ) -> ( Src.C1 ( Src.C2 Src.Pattern, Src.C1 Src.Expr ), A.Position )
buildBranchResult prePatternComments postPatternComments pattern preBranchExprComments ( ( trailingComments, branchExpr ), end ) =
    ( ( trailingComments
      , ( ( ( prePatternComments, postPatternComments ), pattern )
        , ( preBranchExprComments, branchExpr )
        )
      )
    , end
    )


chompCaseEnd : Src.FComments -> List ( Src.C2 Src.Pattern, Src.C1 Src.Expr ) -> A.Position -> Space.Parser E.Case (Src.C1 (List ( Src.C2 Src.Pattern, Src.C1 Src.Expr )))
chompCaseEnd prePatternComments branches end =
    P.oneOfWithFallback
        [ Space.checkAligned E.CasePatternAlignment
            |> P.andThen (\_ -> chompBranch prePatternComments)
            |> P.andThen (\( ( comments, branch ), newEnd ) -> chompCaseEnd comments (branch :: branches) newEnd)
        ]
        ( ( prePatternComments, List.reverse branches ), end )



-- ====== LET EXPRESSION ======


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


chompLetFirstDef : Src.FComments -> Space.Parser E.Let (List (Src.C2 (A.Located Src.Def)))
chompLetFirstDef preDefComments =
    P.withIndent <|
        (chompLetDef
            |> P.andThen (\( ( postDefComments, def ), end ) -> chompLetDefs [ ( ( preDefComments, postDefComments ), def ) ] end)
        )


chompLetIn : A.Position -> List (Src.C2 (A.Located Src.Def)) -> A.Position -> Space.Parser E.Let (Src.C1 Src.Expr)
chompLetIn start defs defsEnd =
    Space.checkIndent defsEnd E.LetIndentIn
        |> P.andThen (\_ -> Keyword.in_ E.LetIn)
        |> P.andThen (\_ -> Space.chompAndCheckIndent E.LetSpace E.LetIndentBody)
        |> P.andThen (\bodyComments -> chompLetBody start defs bodyComments)


chompLetBody : A.Position -> List (Src.C2 (A.Located Src.Def)) -> Src.FComments -> Space.Parser E.Let (Src.C1 Src.Expr)
chompLetBody start defs bodyComments =
    P.specialize E.LetBody expression
        |> P.map (buildLetExpr start defs bodyComments)


buildLetExpr : A.Position -> List (Src.C2 (A.Located Src.Def)) -> Src.FComments -> ( Src.C1 Src.Expr, A.Position ) -> ( Src.C1 Src.Expr, A.Position )
buildLetExpr start defs bodyComments ( ( trailingComments, body ), end ) =
    ( ( trailingComments, A.at start end (Src.Let defs bodyComments body) ), end )


chompLetDefs : List (Src.C2 (A.Located Src.Def)) -> A.Position -> Space.Parser E.Let (List (Src.C2 (A.Located Src.Def)))
chompLetDefs revDefs end =
    P.oneOfWithFallback
        [ Space.checkAligned E.LetDefAlignment
            |> P.andThen (\_ -> chompLetDef)
            |> P.andThen (\( ( postDefComments, def ), newEnd ) -> chompLetDefs (( ( [], postDefComments ), def ) :: revDefs) newEnd)
        ]
        ( List.reverse revDefs, end )



-- ====== LET DEFINITIONS ======


chompLetDef : Space.Parser E.Let (Src.C1 (A.Located Src.Def))
chompLetDef =
    P.oneOf E.LetDefName
        [ definition
        , destructure
        ]



-- ====== DEFINITION ======


definition : Space.Parser E.Let (Src.C1 (A.Located Src.Def))
definition =
    P.addLocation (Var.lower E.LetDefName)
        |> P.andThen (\aname -> chompDefinitionBody aname)


chompDefinitionBody : A.Located Name.Name -> Space.Parser E.Let (Src.C1 (A.Located Src.Def))
chompDefinitionBody ((A.At (A.Region start _) name) as aname) =
    P.specialize (E.LetDef name) <|
        (Space.chompAndCheckIndent E.DefSpace E.DefIndentEquals
            |> P.andThen (\postNameComments -> chompDefinitionEqualsOrType start name aname postNameComments)
        )


chompDefinitionEqualsOrType : A.Position -> Name.Name -> A.Located Name.Name -> Src.FComments -> Space.Parser E.Def (Src.C1 (A.Located Src.Def))
chompDefinitionEqualsOrType start name aname postNameComments =
    P.oneOf E.DefEquals
        [ P.word1 ':' E.DefEquals
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.DefSpace E.DefIndentType)
            |> P.andThen (\preTypeComments -> P.specialize E.DefType (Type.expression preTypeComments))
            |> P.andThen (\( ( ( preTipeComments, postTipeComments, _ ), tipe ), _ ) -> chompDefinitionAfterType start name postNameComments preTipeComments postTipeComments tipe)
        , chompDefArgsAndBody start aname Nothing postNameComments []
        ]


chompDefinitionAfterType : A.Position -> Name.Name -> Src.FComments -> Src.FComments -> Src.FComments -> Src.Type -> Space.Parser E.Def (Src.C1 (A.Located Src.Def))
chompDefinitionAfterType start name postNameComments preTipeComments postTipeComments tipe =
    Space.checkAligned E.DefAlignment
        |> P.andThen (\_ -> chompMatchingName name)
        |> P.andThen (\defName -> chompDefinitionWithType start defName postNameComments preTipeComments postTipeComments tipe)


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


destructure : Space.Parser E.Let (Src.C1 (A.Located Src.Def))
destructure =
    P.specialize E.LetDestruct <|
        (P.getPosition
            |> P.andThen (\start -> chompDestructPattern start)
        )


chompDestructPattern : A.Position -> Space.Parser E.Destruct (Src.C1 (A.Located Src.Def))
chompDestructPattern start =
    P.specialize E.DestructPattern Pattern.term
        |> P.andThen (\pattern -> chompDestructEquals start pattern)


chompDestructEquals : A.Position -> Src.Pattern -> Space.Parser E.Destruct (Src.C1 (A.Located Src.Def))
chompDestructEquals start pattern =
    Space.chompAndCheckIndent E.DestructSpace E.DestructIndentEquals
        |> P.andThen (\preEqualSignComments -> chompDestructBody start pattern preEqualSignComments)


chompDestructBody : A.Position -> Src.Pattern -> Src.FComments -> Space.Parser E.Destruct (Src.C1 (A.Located Src.Def))
chompDestructBody start pattern preEqualSignComments =
    P.word1 '=' E.DestructEquals
        |> P.andThen (\_ -> Space.chompAndCheckIndent E.DestructSpace E.DestructIndentBody)
        |> P.andThen (\preExpressionComments -> chompDestructExpr start pattern preEqualSignComments preExpressionComments)


chompDestructExpr : A.Position -> Src.Pattern -> Src.FComments -> Src.FComments -> Space.Parser E.Destruct (Src.C1 (A.Located Src.Def))
chompDestructExpr start pattern preEqualSignComments preExpressionComments =
    P.specialize E.DestructBody expression
        |> P.map (buildDestructDef start pattern preEqualSignComments preExpressionComments)


buildDestructDef : A.Position -> Src.Pattern -> Src.FComments -> Src.FComments -> ( Src.C1 Src.Expr, A.Position ) -> ( Src.C1 (A.Located Src.Def), A.Position )
buildDestructDef start pattern preEqualSignComments preExpressionComments ( ( comments, expr ), end ) =
    ( ( comments, A.at start end (Src.Destruct pattern ( preEqualSignComments ++ preExpressionComments, expr )) )
    , end
    )
