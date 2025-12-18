module Compiler.Parse.Type exposing
    ( expression
    , variant
    )

{-| Parser for type annotations and type declarations in Elm.

This module parses type expressions including type variables, type constructors,
function types, tuple types, record types, and extensible record types. It also
handles parsing type constructor variants for custom type declarations.


# Type Expressions

@docs expression


# Custom Type Variants

@docs variant

-}

import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Compiler.Parse.Primitives as P
import Compiler.Parse.Space as Space
import Compiler.Parse.Variable as Var
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Syntax as E



-- TYPE TERMS


term : P.Parser E.Type Src.Type
term =
    P.getPosition
        |> P.andThen
            (\start ->
                P.oneOf E.TStart
                    [ -- types with no arguments (Int, Float, etc.)
                      Var.foreignUpper E.TStart
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
                                            A.At region <|
                                                case upper of
                                                    Var.Unqualified name ->
                                                        Src.TType region name []

                                                    Var.Qualified home name ->
                                                        Src.TTypeQual region home name []
                                        )
                            )
                    , -- type variables
                      Var.lower E.TStart
                        |> P.andThen
                            (\var ->
                                P.addEnd start (Src.TVar var)
                            )
                    , -- tuples
                      P.inContext E.TTuple (P.word1 '(' E.TStart) <|
                        P.oneOf E.TTupleOpen
                            [ P.word1 ')' E.TTupleOpen
                                |> P.andThen (\_ -> P.addEnd start Src.TUnit)
                            , Space.chompAndCheckIndent E.TTupleSpace E.TTupleIndentType1
                                |> P.andThen
                                    (\trailingComments ->
                                        P.specialize E.TTupleType (expression trailingComments)
                                            |> P.andThen
                                                (\( tipe, end ) ->
                                                    Space.checkIndent end E.TTupleIndentEnd
                                                        |> P.andThen (\_ -> chompTupleEnd start tipe [])
                                                )
                                    )
                            ]
                    , -- records
                      P.inContext E.TRecord (P.word1 '{' E.TStart) <|
                        (Space.chompAndCheckIndent E.TRecordSpace E.TRecordIndentOpen
                            |> P.andThen
                                (\initialComments ->
                                    P.oneOf E.TRecordOpen
                                        [ P.word1 '}' E.TRecordEnd
                                            |> P.andThen (\_ -> P.addEnd start (Src.TRecord [] Nothing initialComments))
                                        , P.addLocation (Var.lower E.TRecordField)
                                            |> P.andThen
                                                (\name ->
                                                    Space.chompAndCheckIndent E.TRecordSpace E.TRecordIndentColon
                                                        |> P.andThen
                                                            (\postNameComments ->
                                                                P.oneOf E.TRecordColon
                                                                    [ P.word1 '|' E.TRecordColon
                                                                        |> P.andThen
                                                                            (\_ ->
                                                                                Space.chompAndCheckIndent E.TRecordSpace E.TRecordIndentField
                                                                                    |> P.andThen
                                                                                        (\preFieldComments ->
                                                                                            chompField
                                                                                                |> P.andThen
                                                                                                    (\( postFieldComments, field ) ->
                                                                                                        chompRecordEnd postFieldComments [ ( ( [], preFieldComments ), field ) ]
                                                                                                            |> P.andThen
                                                                                                                (\( trailingComments, fields ) ->
                                                                                                                    let
                                                                                                                        extRecord : Maybe (Src.C2 (A.Located Name))
                                                                                                                        extRecord =
                                                                                                                            Just ( ( initialComments, postNameComments ), name )
                                                                                                                    in
                                                                                                                    P.addEnd start (Src.TRecord fields extRecord trailingComments)
                                                                                                                )
                                                                                                    )
                                                                                        )
                                                                            )
                                                                    , P.word1 ':' E.TRecordColon
                                                                        |> P.andThen
                                                                            (\_ ->
                                                                                Space.chompAndCheckIndent E.TRecordSpace E.TRecordIndentType
                                                                                    |> P.andThen
                                                                                        (\preTypeComments ->
                                                                                            P.specialize E.TRecordType (expression [])
                                                                                                |> P.andThen
                                                                                                    (\( ( ( _, postExpressionComments, _ ), tipe ), end ) ->
                                                                                                        let
                                                                                                            firstField : Src.C2 Field
                                                                                                            firstField =
                                                                                                                ( ( [], initialComments )
                                                                                                                , ( ( postNameComments, name ), ( preTypeComments, tipe ) )
                                                                                                                )
                                                                                                        in
                                                                                                        Space.checkIndent end E.TRecordIndentEnd
                                                                                                            |> P.andThen (\_ -> chompRecordEnd postExpressionComments [ firstField ])
                                                                                                            |> P.andThen
                                                                                                                (\( trailingComments, fields ) ->
                                                                                                                    P.addEnd start (Src.TRecord fields Nothing trailingComments)
                                                                                                                )
                                                                                                    )
                                                                                        )
                                                                            )
                                                                    ]
                                                            )
                                                )
                                        ]
                                )
                        )
                    ]
            )



-- TYPE EXPRESSIONS


{-| Parse a type expression including function types, type applications, and type terms.

Handles parsing of complete type expressions such as:

  - Simple types: `Int`, `String`, `Maybe a`
  - Function types: `Int -> String`, `a -> b -> c`
  - Type applications: `List Int`, `Dict String Value`
  - Tuples: `(Int, String)`, `(a, b, c)`
  - Records: `{ x : Int, y : Int }`, `{ a | x : Int }`

Returns a tuple containing the parsed type with comments and the end position.

-}
expression : Src.FComments -> Space.Parser E.Type (Src.C2Eol Src.Type)
expression trailingComments =
    P.getPosition
        |> P.andThen
            (\start ->
                P.oneOf E.TStart
                    [ app start
                    , term
                        |> P.andThen
                            (\eterm ->
                                P.getPosition
                                    |> P.andThen
                                        (\end ->
                                            Space.chomp E.TSpace
                                                |> P.map (\postTermComments -> ( ( postTermComments, eterm ), end ))
                                        )
                            )
                    ]
                    |> P.andThen
                        (\( ( postTipe1comments, tipe1 ), end1 ) ->
                            P.oneOfWithFallback
                                [ -- should never trigger
                                  Space.checkIndent end1 E.TIndentStart
                                    |> P.andThen
                                        (\_ ->
                                            -- could just be another type instead
                                            P.word2 '-' '>' E.TStart
                                                |> P.andThen
                                                    (\_ ->
                                                        Space.chompAndCheckIndent E.TSpace E.TIndentStart
                                                            |> P.andThen
                                                                (\postArrowComments ->
                                                                    expression postArrowComments
                                                                        |> P.map
                                                                            (\( ( ( preTipe2Comments, postTipe2Comments, tipe2Eol ), tipe2 ), end2 ) ->
                                                                                let
                                                                                    tipe : Src.Type
                                                                                    tipe =
                                                                                        A.at start end2 (Src.TLambda ( Nothing, tipe1 ) ( ( postTipe1comments, preTipe2Comments, tipe2Eol ), tipe2 ))
                                                                                in
                                                                                ( ( ( trailingComments, postTipe2Comments, Nothing ), tipe ), end2 )
                                                                            )
                                                                )
                                                    )
                                        )
                                ]
                                ( ( ( trailingComments, postTipe1comments, Nothing ), tipe1 ), end1 )
                        )
            )



-- TYPE CONSTRUCTORS


app : A.Position -> Space.Parser E.Type (Src.C1 Src.Type)
app start =
    Var.foreignUpper E.TStart
        |> P.andThen
            (\upper ->
                P.getPosition
                    |> P.andThen
                        (\upperEnd ->
                            Space.chomp E.TSpace
                                |> P.andThen
                                    (\postUpperComments ->
                                        chompArgs postUpperComments [] upperEnd
                                            |> P.map
                                                (\( ( comments, args ), end ) ->
                                                    let
                                                        region : A.Region
                                                        region =
                                                            A.Region start upperEnd

                                                        tipe : Src.Type_
                                                        tipe =
                                                            case upper of
                                                                Var.Unqualified name ->
                                                                    Src.TType region name args

                                                                Var.Qualified home name ->
                                                                    Src.TTypeQual region home name args
                                                    in
                                                    ( ( comments, A.at start end tipe ), end )
                                                )
                                    )
                        )
            )


chompArgs : Src.FComments -> List (Src.C1 Src.Type) -> A.Position -> Space.Parser E.Type (Src.C1 (List (Src.C1 Src.Type)))
chompArgs preComments args end =
    P.oneOfWithFallback
        [ Space.checkIndent end E.TIndentStart
            |> P.andThen
                (\_ ->
                    term
                        |> P.andThen
                            (\arg ->
                                P.getPosition
                                    |> P.andThen
                                        (\newEnd ->
                                            Space.chomp E.TSpace
                                                |> P.andThen
                                                    (\comments ->
                                                        chompArgs comments (( preComments, arg ) :: args) newEnd
                                                    )
                                        )
                            )
                )
        ]
        ( ( preComments, List.reverse args ), end )



-- TUPLES


chompTupleEnd : A.Position -> Src.C2Eol Src.Type -> List (Src.C2Eol Src.Type) -> P.Parser E.TTuple Src.Type
chompTupleEnd start ( firstTimeComments, firstType ) revTypes =
    P.oneOf E.TTupleEnd
        [ P.word1 ',' E.TTupleEnd
            |> P.andThen
                (\_ ->
                    Space.chompAndCheckIndent E.TTupleSpace E.TTupleIndentTypeN
                        |> P.andThen
                            (\preExpressionComments ->
                                P.specialize E.TTupleType (expression preExpressionComments)
                                    |> P.andThen
                                        (\( tipe, end ) ->
                                            Space.checkIndent end E.TTupleIndentEnd
                                                |> P.andThen
                                                    (\_ ->
                                                        chompTupleEnd start ( firstTimeComments, firstType ) (tipe :: revTypes)
                                                    )
                                        )
                            )
                )
        , P.word1 ')' E.TTupleEnd
            |> P.andThen (\_ -> P.getPosition)
            |> P.andThen
                (\end ->
                    case List.reverse revTypes of
                        [] ->
                            case firstTimeComments of
                                ( [], [], _ ) ->
                                    P.pure firstType

                                ( startParensComments, endParensComments, _ ) ->
                                    P.pure (A.at start end (Src.TParens ( ( startParensComments, endParensComments ), firstType )))

                        secondType :: otherTypes ->
                            P.addEnd start (Src.TTuple ( firstTimeComments, firstType ) secondType otherTypes)
                )
        ]



-- RECORD


type alias Field =
    ( Src.C1 (A.Located Name), Src.C1 Src.Type )


chompRecordEnd : Src.FComments -> List (Src.C2 Field) -> P.Parser E.TRecord (Src.C1 (List (Src.C2 Field)))
chompRecordEnd comments fields =
    P.oneOf E.TRecordEnd
        [ P.word1 ',' E.TRecordEnd
            |> P.andThen
                (\_ ->
                    Space.chompAndCheckIndent E.TRecordSpace E.TRecordIndentField
                        |> P.andThen
                            (\preNameComments ->
                                chompField
                                    |> P.andThen
                                        (\( postFieldComments, field ) ->
                                            chompRecordEnd postFieldComments (( ( comments, preNameComments ), field ) :: fields)
                                        )
                            )
                )
        , P.word1 '}' E.TRecordEnd
            |> P.map (\_ -> ( comments, List.reverse fields ))
        ]


chompField : P.Parser E.TRecord (Src.C1 Field)
chompField =
    P.addLocation (Var.lower E.TRecordField)
        |> P.andThen
            (\name ->
                Space.chompAndCheckIndent E.TRecordSpace E.TRecordIndentColon
                    |> P.andThen
                        (\postNameComments ->
                            P.word1 ':' E.TRecordColon
                                |> P.andThen
                                    (\_ ->
                                        Space.chompAndCheckIndent E.TRecordSpace E.TRecordIndentType
                                            |> P.andThen
                                                (\preTypeComments ->
                                                    P.specialize E.TRecordType (expression [])
                                                        |> P.andThen
                                                            (\( ( ( _, x1, _ ), tipe ), end ) ->
                                                                Space.checkIndent end E.TRecordIndentEnd
                                                                    |> P.map (\_ -> ( x1, ( ( postNameComments, name ), ( preTypeComments, tipe ) ) ))
                                                            )
                                                )
                                    )
                        )
            )



-- VARIANT


{-| Parse a custom type variant declaration.

Parses variant constructors in custom type definitions, handling:

  - Constructor name (must be uppercase)
  - Optional type arguments

Examples:

  - `Nothing` (no arguments)
  - `Just a` (one argument)
  - `Node a (Tree a) (Tree a)` (multiple arguments)

Returns the variant constructor name and its type arguments with associated comments.

-}
variant : Src.FComments -> Space.Parser E.CustomType (Src.C2Eol ( A.Located Name, List (Src.C1 Src.Type) ))
variant trailingComments =
    P.addLocation (Var.upper E.CT_Variant)
        |> P.andThen
            (\((A.At (A.Region _ nameEnd) _) as name) ->
                Space.chomp E.CT_Space
                    |> P.andThen
                        (\preArgComments ->
                            P.specialize E.CT_VariantArg (chompArgs preArgComments [] nameEnd)
                                |> P.map
                                    (\( ( postArgsComments, args ), end ) ->
                                        ( ( ( trailingComments, postArgsComments, Nothing ), ( name, args ) ), end )
                                    )
                        )
            )
