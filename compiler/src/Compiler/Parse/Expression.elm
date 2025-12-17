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
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Parse.Keyword as Keyword
import Compiler.Parse.Number as Number
import Compiler.Parse.Pattern as Pattern
import Compiler.Parse.Primitives as P exposing (Col, Row)
import Compiler.Parse.Shader as Shader
import Compiler.Parse.Space as Space
import Compiler.Parse.String as String
import Compiler.Parse.Symbol as Symbol
import Compiler.Parse.SyntaxVersion as SV exposing (SyntaxVersion)
import Compiler.Parse.Type as Type
import Compiler.Parse.Variable as Var
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Syntax as E



-- TERMS


term : SyntaxVersion -> P.Parser E.Expr Src.Expr
term syntaxVersion =
    P.getPosition
        |> P.andThen
            (\start ->
                P.oneOf E.Start
                    [ variable start |> P.andThen (accessible start)
                    , string syntaxVersion start
                    , number syntaxVersion start
                    , Shader.shader start
                    , list syntaxVersion start
                    , record syntaxVersion start |> P.andThen (accessible start)
                    , tuple syntaxVersion start |> P.andThen (accessible start)
                    , accessor start
                    , character syntaxVersion start
                    ]
            )


string : SyntaxVersion -> A.Position -> P.Parser E.Expr Src.Expr
string syntaxVersion start =
    String.string syntaxVersion E.Start E.String_
        |> P.andThen (\( str, representation ) -> P.addEnd start (Src.Str str representation))


character : SyntaxVersion -> A.Position -> P.Parser E.Expr Src.Expr
character syntaxVersion start =
    String.character syntaxVersion E.Start E.Char
        |> P.andThen (\chr -> P.addEnd start (Src.Chr chr))


number : SyntaxVersion -> A.Position -> P.Parser E.Expr Src.Expr
number syntaxVersion start =
    Number.number syntaxVersion E.Start E.Number
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



-- LISTS


list : SyntaxVersion -> A.Position -> P.Parser E.Expr Src.Expr
list syntaxVersion start =
    P.inContext E.List (P.word1 '[' E.Start) <|
        (Space.chompAndCheckIndent E.ListSpace E.ListIndentOpen
            |> P.andThen
                (\comments ->
                    P.oneOf E.ListOpen
                        [ P.specialize E.ListExpr (expression syntaxVersion)
                            |> P.andThen
                                (\( ( postEntryComments, entry ), end ) ->
                                    Space.checkIndent end E.ListIndentEnd
                                        |> P.andThen (\_ -> P.loop (chompListEnd syntaxVersion start) ( postEntryComments, [ ( ( [], comments, Nothing ), entry ) ] ))
                                )
                        , P.word1 ']' E.ListOpen
                            |> P.andThen (\_ -> P.addEnd start (Src.List [] comments))
                        ]
                )
        )


chompListEnd : SyntaxVersion -> A.Position -> Src.C1 (List (Src.C2Eol Src.Expr)) -> P.Parser E.List_ (P.Step (Src.C1 (List (Src.C2Eol Src.Expr))) Src.Expr)
chompListEnd syntaxVersion start ( trailingComments, entries ) =
    P.oneOf E.ListEnd
        [ P.word1 ',' E.ListEnd
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.ListSpace E.ListIndentExpr)
            |> P.andThen
                (\postComments ->
                    P.specialize E.ListExpr (expression syntaxVersion)
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



-- TUPLES


tuple : SyntaxVersion -> A.Position -> P.Parser E.Expr Src.Expr
tuple syntaxVersion ((A.Position row col) as start) =
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
                                                P.specialize E.TupleExpr (expression syntaxVersion)
                                                    |> P.andThen
                                                        (\( ( postEntryComments, entry ), end ) ->
                                                            Space.checkIndent end E.TupleIndentEnd
                                                                |> P.andThen (\_ -> chompTupleEnd syntaxVersion start ( ( preEntryComments, postEntryComments ), entry ) [])
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
                                                                            (term syntaxVersion
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
                                                                                                    chompExprEnd syntaxVersion
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
                                                                                        |> P.andThen (\_ -> chompTupleEnd syntaxVersion start ( ( preEntryComments, postEntryComments ), entry ) [])
                                                                                )
                                                                        ]

                                                                else
                                                                    P.word1 ')' E.TupleOperatorClose
                                                                        |> P.andThen (\_ -> P.addEnd start (Src.Op op))
                                                            )
                                                    , P.word1 ')' E.TupleIndentExpr1
                                                        |> P.andThen (\_ -> P.addEnd start Src.Unit)
                                                    , P.specialize E.TupleExpr (expression syntaxVersion)
                                                        |> P.andThen
                                                            (\( ( postEntryComments, entry ), end ) ->
                                                                Space.checkIndent end E.TupleIndentEnd
                                                                    |> P.andThen (\_ -> chompTupleEnd syntaxVersion start ( ( preEntryComments, postEntryComments ), entry ) [])
                                                            )
                                                    ]
                                        )
                            )
                )
        )


chompTupleEnd : SyntaxVersion -> A.Position -> Src.C2 Src.Expr -> List (Src.C2 Src.Expr) -> P.Parser E.Tuple Src.Expr
chompTupleEnd syntaxVersion start firstExpr revExprs =
    P.oneOf E.TupleEnd
        [ P.word1 ',' E.TupleEnd
            |> P.andThen
                (\_ ->
                    Space.chompAndCheckIndent E.TupleSpace E.TupleIndentExprN
                        |> P.andThen
                            (\preEntryComments ->
                                P.specialize E.TupleExpr (expression syntaxVersion)
                                    |> P.andThen
                                        (\( ( postEntryComments, entry ), end ) ->
                                            Space.checkIndent end E.TupleIndentEnd
                                                |> P.andThen (\_ -> chompTupleEnd syntaxVersion start firstExpr (( ( preEntryComments, postEntryComments ), entry ) :: revExprs))
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



-- RECORDS


{-| Parse record expressions including record literals and record update syntax.
Handles both empty records and records with fields.
-}
record : SyntaxVersion -> A.Position -> P.Parser E.Expr Src.Expr
record syntaxVersion start =
    case syntaxVersion of
        SV.Elm ->
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
                                                                        chompField syntaxVersion [] postPipeComments
                                                                    )
                                                                |> P.andThen (\( postFirstFieldComments, firstField ) -> chompFields syntaxVersion postFirstFieldComments [ firstField ])
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
                                                                        P.specialize E.RecordExpr (expression syntaxVersion)
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
                                                                                        |> P.andThen (\_ -> chompFields syntaxVersion postValueComments [ firstField ])
                                                                                        |> P.andThen (\fields -> P.addEnd start (Src.Record fields))
                                                                                )
                                                                    )
                                                            ]
                                                    )
                                        )
                                ]
                        )
                )

        SV.Guida ->
            P.inContext E.Record (P.word1 '{' E.Start) <|
                (Space.chompAndCheckIndent E.RecordSpace E.RecordIndentOpen
                    |> P.andThen
                        (\preStarterNameComments ->
                            P.oneOf E.RecordOpen
                                [ P.word1 '}' E.RecordOpen
                                    |> P.andThen (\_ -> P.addEnd start (Src.Record ( preStarterNameComments, [] )))
                                , P.getPosition
                                    |> P.andThen
                                        (\nameStart ->
                                            foreignAlpha E.RecordField
                                                |> P.andThen (\var -> P.addEnd nameStart var)
                                                |> P.andThen (accessibleRecord nameStart)
                                                |> P.andThen
                                                    (\starter ->
                                                        Space.chompAndCheckIndent E.RecordSpace E.RecordIndentEquals
                                                            |> P.andThen
                                                                (\postStarterNameComments ->
                                                                    P.word1 '|' E.RecordEquals
                                                                        |> P.andThen (\_ -> Space.chompAndCheckIndent E.RecordSpace E.RecordIndentField)
                                                                        |> P.andThen (\postPipeComments -> chompField syntaxVersion [] postPipeComments)
                                                                        |> P.andThen (\( postFirstFieldComments, firstField ) -> chompFields syntaxVersion postFirstFieldComments [ firstField ])
                                                                        |> P.andThen
                                                                            (\fields ->
                                                                                P.addEnd start (Src.Update ( ( preStarterNameComments, postStarterNameComments ), starter ) fields)
                                                                            )
                                                                )
                                                    )
                                        )
                                , P.addLocation (Var.lower E.RecordField)
                                    |> P.andThen
                                        (\starter ->
                                            Space.chompAndCheckIndent E.RecordSpace E.RecordIndentEquals
                                                |> P.andThen
                                                    (\postStarterNameComments ->
                                                        P.word1 '=' E.RecordEquals
                                                            |> P.andThen (\_ -> Space.chompAndCheckIndent E.RecordSpace E.RecordIndentExpr)
                                                            |> P.andThen
                                                                (\preValueComments ->
                                                                    P.specialize E.RecordExpr (expression syntaxVersion)
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
                                                                                    |> P.andThen (\_ -> chompFields syntaxVersion postValueComments [ firstField ])
                                                                                    |> P.andThen (\fields -> P.addEnd start (Src.Record fields))
                                                                            )
                                                                )
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



-- FOREIGN ALPHA


foreignAlpha : (Row -> Col -> x) -> P.Parser x Src.Expr_
foreignAlpha toError =
    P.Parser <|
        \(P.State st) ->
            let
                ( ( alphaStart, alphaEnd ), ( newCol, varType ) ) =
                    foreignAlphaHelp st.src st.pos st.end st.col
            in
            if alphaStart == alphaEnd then
                P.Eerr st.row newCol toError

            else
                case varType of
                    Src.LowVar ->
                        let
                            name : Name
                            name =
                                Name.fromPtr st.src alphaStart alphaEnd

                            newState : P.State
                            newState =
                                P.State { st | pos = alphaEnd, col = newCol }
                        in
                        if alphaStart == st.pos then
                            if Var.isReservedWord name then
                                P.Eerr st.row st.col toError

                            else
                                P.Cok (Src.Var varType name) newState

                        else
                            let
                                home : Name
                                home =
                                    Name.fromPtr st.src st.pos (alphaStart + -1)
                            in
                            P.Cok (Src.VarQual varType home name) newState

                    Src.CapVar ->
                        P.Eerr st.row st.col toError


foreignAlphaHelp : String -> Int -> Int -> Col -> ( ( Int, Int ), ( Col, Src.VarType ) )
foreignAlphaHelp src pos end col =
    let
        ( lowerPos, lowerCol ) =
            Var.chompLower src pos end col
    in
    if pos < lowerPos then
        ( ( pos, lowerPos ), ( lowerCol, Src.LowVar ) )

    else
        let
            ( upperPos, upperCol ) =
                Var.chompUpper src pos end col
        in
        if pos == upperPos then
            ( ( pos, pos ), ( col, Src.CapVar ) )

        else if Var.isDot src upperPos end then
            foreignAlphaHelp src (upperPos + 1) end (upperCol + 1)

        else
            ( ( pos, upperPos ), ( upperCol, Src.CapVar ) )


type alias Field =
    Src.C2Eol ( Src.C1 (A.Located Name.Name), Src.C1 Src.Expr )


chompFields : SyntaxVersion -> Src.FComments -> List Field -> P.Parser E.Record (Src.C1 (List Field))
chompFields syntaxVersion trailingComments fields =
    P.oneOf E.RecordEnd
        [ P.word1 ',' E.RecordEnd
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.RecordSpace E.RecordIndentField)
            |> P.andThen (\postCommaComments -> chompField syntaxVersion trailingComments postCommaComments)
            |> P.andThen (\( postFieldComments, f ) -> chompFields syntaxVersion postFieldComments (f :: fields))
        , P.word1 '}' E.RecordEnd
            |> P.map (\_ -> ( trailingComments, List.reverse fields ))
        ]


chompField : SyntaxVersion -> Src.FComments -> Src.FComments -> P.Parser E.Record (Src.C1 Field)
chompField syntaxVersion preCommaComents postCommaComments =
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
                                        P.specialize E.RecordExpr (expression syntaxVersion)
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



-- EXPRESSIONS


{-| Parse a complete Elm expression including operators, function application,
and special forms like if/case/let/lambda. Returns the parsed expression with
associated comments and position information.
-}
expression : SyntaxVersion -> Space.Parser E.Expr (Src.C1 Src.Expr)
expression syntaxVersion =
    P.getPosition
        |> P.andThen
            (\start ->
                P.oneOf E.Start
                    [ let_ syntaxVersion start
                    , if_ syntaxVersion start
                    , case_ syntaxVersion start
                    , function syntaxVersion start
                    , possiblyNegativeTerm syntaxVersion start
                        |> P.andThen
                            (\expr ->
                                P.getPosition
                                    |> P.andThen
                                        (\end ->
                                            Space.chomp E.Space
                                                |> P.andThen
                                                    (\comments ->
                                                        chompExprEnd syntaxVersion
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


chompExprEnd : SyntaxVersion -> A.Position -> State -> Src.FComments -> Space.Parser E.Expr (Src.C1 Src.Expr)
chompExprEnd syntaxVersion start (State { ops, expr, args, end }) comments =
    P.oneOfWithFallback
        [ -- argument
          Space.checkIndent end E.Start
            |> P.andThen (\_ -> term syntaxVersion)
            |> P.andThen
                (\arg ->
                    P.getPosition
                        |> P.andThen
                            (\newEnd ->
                                Space.chomp E.Space
                                    |> P.andThen
                                        (\trailingComments ->
                                            chompExprEnd syntaxVersion
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
                                                term syntaxVersion
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
                                                                                    chompExprEnd syntaxVersion
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
                                                      possiblyNegativeTerm syntaxVersion newStart
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
                                                                                        chompExprEnd syntaxVersion
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
                                                        [ let_ syntaxVersion newStart
                                                        , case_ syntaxVersion newStart
                                                        , if_ syntaxVersion newStart
                                                        , function syntaxVersion newStart
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


possiblyNegativeTerm : SyntaxVersion -> A.Position -> P.Parser E.Expr Src.Expr
possiblyNegativeTerm syntaxVersion start =
    P.oneOf E.Start
        [ P.word1 '-' E.Start
            |> P.andThen
                (\_ ->
                    term syntaxVersion
                        |> P.andThen
                            (\expr ->
                                P.addEnd start (Src.Negate expr)
                            )
                )
        , term syntaxVersion
        ]


toCall : Src.Expr -> List (Src.C1 Src.Expr) -> Src.Expr
toCall func revArgs =
    case revArgs of
        [] ->
            func

        ( _, lastArg ) :: _ ->
            A.merge func lastArg (Src.Call func (List.reverse revArgs))



-- IF EXPRESSION


if_ : SyntaxVersion -> A.Position -> Space.Parser E.Expr (Src.C1 Src.Expr)
if_ syntaxVersion start =
    chompIfEnd syntaxVersion start [] [] |> P.inContext E.If (Keyword.if_ E.Start)


chompIfEnd : SyntaxVersion -> A.Position -> Src.FComments -> List (Src.C1 ( Src.C2 Src.Expr, Src.C2 Src.Expr )) -> Space.Parser E.If (Src.C1 Src.Expr)
chompIfEnd syntaxVersion start comments branches =
    Space.chompAndCheckIndent E.IfSpace E.IfIndentCondition
        |> P.andThen (\preConditionComments -> chompIfCondition syntaxVersion start comments branches preConditionComments)


chompIfCondition :
    SyntaxVersion
    -> A.Position
    -> Src.FComments
    -> List (Src.C1 ( Src.C2 Src.Expr, Src.C2 Src.Expr ))
    -> Src.FComments
    -> Space.Parser E.If (Src.C1 Src.Expr)
chompIfCondition syntaxVersion start comments branches preConditionComments =
    P.specialize E.IfCondition (expression syntaxVersion)
        |> P.andThen
            (\( ( postConditionComments, condition ), condEnd ) ->
                Space.checkIndent condEnd E.IfIndentThen
                    |> P.andThen (\_ -> Keyword.then_ E.IfThen)
                    |> P.andThen (\_ -> Space.chompAndCheckIndent E.IfSpace E.IfIndentThenBranch)
                    |> P.andThen (\preThenBranchComments -> chompIfThen syntaxVersion start comments branches preConditionComments postConditionComments condition preThenBranchComments)
            )


chompIfThen :
    SyntaxVersion
    -> A.Position
    -> Src.FComments
    -> List (Src.C1 ( Src.C2 Src.Expr, Src.C2 Src.Expr ))
    -> Src.FComments
    -> Src.FComments
    -> Src.Expr
    -> Src.FComments
    -> Space.Parser E.If (Src.C1 Src.Expr)
chompIfThen syntaxVersion start comments branches preConditionComments postConditionComments condition preThenBranchComments =
    P.specialize E.IfThenBranch (expression syntaxVersion)
        |> P.andThen
            (\( ( postThenBranchComments, thenBranch ), thenEnd ) ->
                Space.checkIndent thenEnd E.IfIndentElse
                    |> P.andThen (\_ -> Keyword.else_ E.IfElse)
                    |> P.andThen (\_ -> Space.chompAndCheckIndent E.IfSpace E.IfIndentElseBranch)
                    |> P.andThen
                        (\trailingComments ->
                            chompIfElse syntaxVersion
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
    SyntaxVersion
    -> A.Position
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
chompIfElse syntaxVersion start comments branches preConditionComments postConditionComments condition preThenBranchComments postThenBranchComments thenBranch trailingComments =
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
            |> P.andThen (\_ -> chompIfEnd syntaxVersion start trailingComments newBranches)
        , P.specialize E.IfElseBranch (expression syntaxVersion)
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



-- LAMBDA EXPRESSION


function : SyntaxVersion -> A.Position -> Space.Parser E.Expr (Src.C1 Src.Expr)
function syntaxVersion start =
    P.inContext E.Func (P.word1 '\\' E.Start) <|
        (Space.chompAndCheckIndent E.FuncSpace E.FuncIndentArg
            |> P.andThen (\preArgComments -> chompFunctionFirstArg syntaxVersion start preArgComments)
        )


chompFunctionFirstArg : SyntaxVersion -> A.Position -> Src.FComments -> Space.Parser E.Func (Src.C1 Src.Expr)
chompFunctionFirstArg syntaxVersion start preArgComments =
    P.specialize E.FuncArg (Pattern.term syntaxVersion)
        |> P.andThen (\arg -> chompFunctionArgs syntaxVersion start preArgComments arg)


chompFunctionArgs : SyntaxVersion -> A.Position -> Src.FComments -> Src.Pattern -> Space.Parser E.Func (Src.C1 Src.Expr)
chompFunctionArgs syntaxVersion start preArgComments arg =
    Space.chompAndCheckIndent E.FuncSpace E.FuncIndentArrow
        |> P.andThen (\trailingComments -> chompArgs syntaxVersion trailingComments [ ( preArgComments, arg ) ])
        |> P.andThen (\( trailingComments, revArgs ) -> chompFunctionBody syntaxVersion start trailingComments revArgs)


chompFunctionBody : SyntaxVersion -> A.Position -> Src.FComments -> List (Src.C1 Src.Pattern) -> Space.Parser E.Func (Src.C1 Src.Expr)
chompFunctionBody syntaxVersion start trailingComments revArgs =
    Space.chompAndCheckIndent E.FuncSpace E.FuncIndentBody
        |> P.andThen
            (\preComments ->
                P.specialize E.FuncBody (expression syntaxVersion)
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


chompArgs : SyntaxVersion -> Src.FComments -> List (Src.C1 Src.Pattern) -> P.Parser E.Func (Src.C1 (List (Src.C1 Src.Pattern)))
chompArgs syntaxVersion trailingComments revArgs =
    P.oneOf E.FuncArrow
        [ P.specialize E.FuncArg (Pattern.term syntaxVersion)
            |> P.andThen
                (\arg ->
                    Space.chompAndCheckIndent E.FuncSpace E.FuncIndentArrow
                        |> P.andThen (\postArgComments -> chompArgs syntaxVersion postArgComments (( trailingComments, arg ) :: revArgs))
                )
        , P.word2 '-' '>' E.FuncArrow
            |> P.map (\_ -> ( trailingComments, revArgs ))
        ]



-- CASE EXPRESSIONS


case_ : SyntaxVersion -> A.Position -> Space.Parser E.Expr (Src.C1 Src.Expr)
case_ syntaxVersion start =
    P.inContext E.Case (Keyword.case_ E.Start) <|
        (Space.chompAndCheckIndent E.CaseSpace E.CaseIndentExpr
            |> P.andThen (\preExprComments -> chompCaseExpr syntaxVersion start preExprComments)
        )


chompCaseExpr : SyntaxVersion -> A.Position -> Src.FComments -> Space.Parser E.Case (Src.C1 Src.Expr)
chompCaseExpr syntaxVersion start preExprComments =
    P.specialize E.CaseExpr (expression syntaxVersion)
        |> P.andThen
            (\( ( postExprComments, expr ), exprEnd ) ->
                chompCaseOf syntaxVersion start preExprComments postExprComments expr exprEnd
            )


chompCaseOf : SyntaxVersion -> A.Position -> Src.FComments -> Src.FComments -> Src.Expr -> A.Position -> Space.Parser E.Case (Src.C1 Src.Expr)
chompCaseOf syntaxVersion start preExprComments postExprComments expr exprEnd =
    Space.checkIndent exprEnd E.CaseIndentOf
        |> P.andThen (\_ -> Keyword.of_ E.CaseOf)
        |> P.andThen (\_ -> Space.chompAndCheckIndent E.CaseSpace E.CaseIndentPattern)
        |> P.andThen (\comments -> chompCaseBranches syntaxVersion start preExprComments postExprComments expr comments)


chompCaseBranches : SyntaxVersion -> A.Position -> Src.FComments -> Src.FComments -> Src.Expr -> Src.FComments -> Space.Parser E.Case (Src.C1 Src.Expr)
chompCaseBranches syntaxVersion start preExprComments postExprComments expr comments =
    P.withIndent
        (chompBranch syntaxVersion comments
            |> P.andThen
                (\( ( trailingComments, firstBranch ), firstEnd ) ->
                    chompCaseEnd syntaxVersion trailingComments [ firstBranch ] firstEnd
                        |> P.map (buildCaseExpr start preExprComments postExprComments expr)
                )
        )


buildCaseExpr : A.Position -> Src.FComments -> Src.FComments -> Src.Expr -> ( Src.C1 (List ( Src.C2 Src.Pattern, Src.C1 Src.Expr )), A.Position ) -> ( Src.C1 Src.Expr, A.Position )
buildCaseExpr start preExprComments postExprComments expr ( ( branchesTrailingComments, branches ), end ) =
    ( ( branchesTrailingComments, A.at start end (Src.Case ( ( preExprComments, postExprComments ), expr ) branches) )
    , end
    )


chompBranch : SyntaxVersion -> Src.FComments -> Space.Parser E.Case (Src.C1 ( Src.C2 Src.Pattern, Src.C1 Src.Expr ))
chompBranch syntaxVersion prePatternComments =
    P.specialize E.CasePattern (Pattern.expression syntaxVersion)
        |> P.andThen (\( ( postPatternComments, pattern ), patternEnd ) -> chompBranchArrow syntaxVersion prePatternComments postPatternComments pattern patternEnd)


chompBranchArrow : SyntaxVersion -> Src.FComments -> Src.FComments -> Src.Pattern -> A.Position -> Space.Parser E.Case (Src.C1 ( Src.C2 Src.Pattern, Src.C1 Src.Expr ))
chompBranchArrow syntaxVersion prePatternComments postPatternComments pattern patternEnd =
    Space.checkIndent patternEnd E.CaseIndentArrow
        |> P.andThen (\_ -> P.word2 '-' '>' E.CaseArrow)
        |> P.andThen (\_ -> Space.chompAndCheckIndent E.CaseSpace E.CaseIndentBranch)
        |> P.andThen (\preBranchExprComments -> chompBranchExpr syntaxVersion prePatternComments postPatternComments pattern preBranchExprComments)


chompBranchExpr : SyntaxVersion -> Src.FComments -> Src.FComments -> Src.Pattern -> Src.FComments -> Space.Parser E.Case (Src.C1 ( Src.C2 Src.Pattern, Src.C1 Src.Expr ))
chompBranchExpr syntaxVersion prePatternComments postPatternComments pattern preBranchExprComments =
    P.specialize E.CaseBranch (expression syntaxVersion)
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


chompCaseEnd : SyntaxVersion -> Src.FComments -> List ( Src.C2 Src.Pattern, Src.C1 Src.Expr ) -> A.Position -> Space.Parser E.Case (Src.C1 (List ( Src.C2 Src.Pattern, Src.C1 Src.Expr )))
chompCaseEnd syntaxVersion prePatternComments branches end =
    P.oneOfWithFallback
        [ Space.checkAligned E.CasePatternAlignment
            |> P.andThen (\_ -> chompBranch syntaxVersion prePatternComments)
            |> P.andThen (\( ( comments, branch ), newEnd ) -> chompCaseEnd syntaxVersion comments (branch :: branches) newEnd)
        ]
        ( ( prePatternComments, List.reverse branches ), end )



-- LET EXPRESSION


let_ : SyntaxVersion -> A.Position -> Space.Parser E.Expr (Src.C1 Src.Expr)
let_ syntaxVersion start =
    P.inContext E.Let (Keyword.let_ E.Start) <|
        ((P.withBacksetIndent 3 <|
            (Space.chompAndCheckIndent E.LetSpace E.LetIndentDef
                |> P.andThen (\preDefComments -> chompLetFirstDef syntaxVersion preDefComments)
            )
         )
            |> P.andThen (\( defs, defsEnd ) -> chompLetIn syntaxVersion start defs defsEnd)
        )


chompLetFirstDef : SyntaxVersion -> Src.FComments -> Space.Parser E.Let (List (Src.C2 (A.Located Src.Def)))
chompLetFirstDef syntaxVersion preDefComments =
    P.withIndent <|
        (chompLetDef syntaxVersion
            |> P.andThen (\( ( postDefComments, def ), end ) -> chompLetDefs syntaxVersion [ ( ( preDefComments, postDefComments ), def ) ] end)
        )


chompLetIn : SyntaxVersion -> A.Position -> List (Src.C2 (A.Located Src.Def)) -> A.Position -> Space.Parser E.Let (Src.C1 Src.Expr)
chompLetIn syntaxVersion start defs defsEnd =
    Space.checkIndent defsEnd E.LetIndentIn
        |> P.andThen (\_ -> Keyword.in_ E.LetIn)
        |> P.andThen (\_ -> Space.chompAndCheckIndent E.LetSpace E.LetIndentBody)
        |> P.andThen (\bodyComments -> chompLetBody syntaxVersion start defs bodyComments)


chompLetBody : SyntaxVersion -> A.Position -> List (Src.C2 (A.Located Src.Def)) -> Src.FComments -> Space.Parser E.Let (Src.C1 Src.Expr)
chompLetBody syntaxVersion start defs bodyComments =
    P.specialize E.LetBody (expression syntaxVersion)
        |> P.map (buildLetExpr start defs bodyComments)


buildLetExpr : A.Position -> List (Src.C2 (A.Located Src.Def)) -> Src.FComments -> ( Src.C1 Src.Expr, A.Position ) -> ( Src.C1 Src.Expr, A.Position )
buildLetExpr start defs bodyComments ( ( trailingComments, body ), end ) =
    ( ( trailingComments, A.at start end (Src.Let defs bodyComments body) ), end )


chompLetDefs : SyntaxVersion -> List (Src.C2 (A.Located Src.Def)) -> A.Position -> Space.Parser E.Let (List (Src.C2 (A.Located Src.Def)))
chompLetDefs syntaxVersion revDefs end =
    P.oneOfWithFallback
        [ Space.checkAligned E.LetDefAlignment
            |> P.andThen (\_ -> chompLetDef syntaxVersion)
            |> P.andThen (\( ( postDefComments, def ), newEnd ) -> chompLetDefs syntaxVersion (( ( [], postDefComments ), def ) :: revDefs) newEnd)
        ]
        ( List.reverse revDefs, end )



-- LET DEFINITIONS


chompLetDef : SyntaxVersion -> Space.Parser E.Let (Src.C1 (A.Located Src.Def))
chompLetDef syntaxVersion =
    P.oneOf E.LetDefName
        [ definition syntaxVersion
        , destructure syntaxVersion
        ]



-- DEFINITION


definition : SyntaxVersion -> Space.Parser E.Let (Src.C1 (A.Located Src.Def))
definition syntaxVersion =
    P.addLocation (Var.lower E.LetDefName)
        |> P.andThen (\aname -> chompDefinitionBody syntaxVersion aname)


chompDefinitionBody : SyntaxVersion -> A.Located Name.Name -> Space.Parser E.Let (Src.C1 (A.Located Src.Def))
chompDefinitionBody syntaxVersion ((A.At (A.Region start _) name) as aname) =
    P.specialize (E.LetDef name) <|
        (Space.chompAndCheckIndent E.DefSpace E.DefIndentEquals
            |> P.andThen (\postNameComments -> chompDefinitionEqualsOrType syntaxVersion start name aname postNameComments)
        )


chompDefinitionEqualsOrType : SyntaxVersion -> A.Position -> Name.Name -> A.Located Name.Name -> Src.FComments -> Space.Parser E.Def (Src.C1 (A.Located Src.Def))
chompDefinitionEqualsOrType syntaxVersion start name aname postNameComments =
    P.oneOf E.DefEquals
        [ P.word1 ':' E.DefEquals
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.DefSpace E.DefIndentType)
            |> P.andThen (\preTypeComments -> P.specialize E.DefType (Type.expression preTypeComments))
            |> P.andThen (\( ( ( preTipeComments, postTipeComments, _ ), tipe ), _ ) -> chompDefinitionAfterType syntaxVersion start name postNameComments preTipeComments postTipeComments tipe)
        , chompDefArgsAndBody syntaxVersion start aname Nothing postNameComments []
        ]


chompDefinitionAfterType : SyntaxVersion -> A.Position -> Name.Name -> Src.FComments -> Src.FComments -> Src.FComments -> Src.Type -> Space.Parser E.Def (Src.C1 (A.Located Src.Def))
chompDefinitionAfterType syntaxVersion start name postNameComments preTipeComments postTipeComments tipe =
    Space.checkAligned E.DefAlignment
        |> P.andThen (\_ -> chompMatchingName name)
        |> P.andThen (\defName -> chompDefinitionWithType syntaxVersion start defName postNameComments preTipeComments postTipeComments tipe)


chompDefinitionWithType : SyntaxVersion -> A.Position -> A.Located Name.Name -> Src.FComments -> Src.FComments -> Src.FComments -> Src.Type -> Space.Parser E.Def (Src.C1 (A.Located Src.Def))
chompDefinitionWithType syntaxVersion start defName postNameComments preTipeComments postTipeComments tipe =
    Space.chompAndCheckIndent E.DefSpace E.DefIndentEquals
        |> P.andThen
            (\trailingComments ->
                let
                    typeAnnotation : Maybe (Src.C1 (Src.C2 Src.Type))
                    typeAnnotation =
                        Just ( postTipeComments, ( ( postNameComments, preTipeComments ), tipe ) )
                in
                chompDefArgsAndBody syntaxVersion start defName typeAnnotation trailingComments []
            )


chompDefArgsAndBody :
    SyntaxVersion
    -> A.Position
    -> A.Located Name.Name
    -> Maybe (Src.C1 (Src.C2 Src.Type))
    -> Src.FComments
    -> List (Src.C1 Src.Pattern)
    -> Space.Parser E.Def (Src.C1 (A.Located Src.Def))
chompDefArgsAndBody syntaxVersion start name tipe trailingComments revArgs =
    P.oneOf E.DefEquals
        [ P.specialize E.DefArg (Pattern.term syntaxVersion)
            |> P.andThen
                (\arg ->
                    Space.chompAndCheckIndent E.DefSpace E.DefIndentEquals
                        |> P.andThen (\comments -> chompDefArgsAndBody syntaxVersion start name tipe comments (( trailingComments, arg ) :: revArgs))
                )
        , P.word1 '=' E.DefEquals
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.DefSpace E.DefIndentBody)
            |> P.andThen
                (\preExpressionComments ->
                    P.specialize E.DefBody (expression syntaxVersion)
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



-- DESTRUCTURE


destructure : SyntaxVersion -> Space.Parser E.Let (Src.C1 (A.Located Src.Def))
destructure syntaxVersion =
    P.specialize E.LetDestruct <|
        (P.getPosition
            |> P.andThen (\start -> chompDestructPattern syntaxVersion start)
        )


chompDestructPattern : SyntaxVersion -> A.Position -> Space.Parser E.Destruct (Src.C1 (A.Located Src.Def))
chompDestructPattern syntaxVersion start =
    P.specialize E.DestructPattern (Pattern.term syntaxVersion)
        |> P.andThen (\pattern -> chompDestructEquals syntaxVersion start pattern)


chompDestructEquals : SyntaxVersion -> A.Position -> Src.Pattern -> Space.Parser E.Destruct (Src.C1 (A.Located Src.Def))
chompDestructEquals syntaxVersion start pattern =
    Space.chompAndCheckIndent E.DestructSpace E.DestructIndentEquals
        |> P.andThen (\preEqualSignComments -> chompDestructBody syntaxVersion start pattern preEqualSignComments)


chompDestructBody : SyntaxVersion -> A.Position -> Src.Pattern -> Src.FComments -> Space.Parser E.Destruct (Src.C1 (A.Located Src.Def))
chompDestructBody syntaxVersion start pattern preEqualSignComments =
    P.word1 '=' E.DestructEquals
        |> P.andThen (\_ -> Space.chompAndCheckIndent E.DestructSpace E.DestructIndentBody)
        |> P.andThen (\preExpressionComments -> chompDestructExpr syntaxVersion start pattern preEqualSignComments preExpressionComments)


chompDestructExpr : SyntaxVersion -> A.Position -> Src.Pattern -> Src.FComments -> Src.FComments -> Space.Parser E.Destruct (Src.C1 (A.Located Src.Def))
chompDestructExpr syntaxVersion start pattern preEqualSignComments preExpressionComments =
    P.specialize E.DestructBody (expression syntaxVersion)
        |> P.map (buildDestructDef start pattern preEqualSignComments preExpressionComments)


buildDestructDef : A.Position -> Src.Pattern -> Src.FComments -> Src.FComments -> ( Src.C1 Src.Expr, A.Position ) -> ( Src.C1 (A.Located Src.Def), A.Position )
buildDestructDef start pattern preEqualSignComments preExpressionComments ( ( comments, expr ), end ) =
    ( ( comments, A.at start end (Src.Destruct pattern ( preEqualSignComments ++ preExpressionComments, expr )) )
    , end
    )
