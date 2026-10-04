module Compiler.Parse.Type exposing
    ( expression
    , variant
    )

{-| Type annotations, alias bodies, port types and the variants of custom types
are all written in Elm's type syntax, and this module parses that syntax into
`Compiler.AST.Source` types.

A type is built from _terms_ and two ways of combining them. A term is a type
that needs no parentheses to be an argument: a type variable, a type name with
no arguments, `()`, a parenthesised type, a tuple, or a record. A _type
application_ is a type name, possibly qualified, followed by argument terms.
An arrow joins a term or application on its left to a whole type on its right,
so `a -> b -> c` is `a -> (b -> c)`. A type name with arguments is always
parsed as an application, and a type name met as an argument is a term with no
arguments of its own, which is why `Maybe List a` gives `Maybe` two arguments.

Two facts about the source shape most of the file. First, layout: each argument
of an application, and an arrow after a type, belongs to the type only when it
is indented past the current indentation column, as `Space.checkIndent`
decides. That is how a type annotation ends where the next declaration begins
in column 1. Second, comments: the formatter has to put back every comment
between the tokens of a type, so every gap is read with `Space.chomp` and its
comments are stored in the surrounding `C1`, `C2` or `C2Eol` group. Which gap
each group holds is decided here, site by site, and the end-of-line slot of a
`C2Eol` is always `Nothing`.

A parenthesised single type with no comments inside its parentheses is
returned as the inner type itself, with no `Src.TParens` node; one with
comments becomes `Src.TParens`. Tuples of any length of two or more are
accepted; their arity is not limited here.


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



-- ====== TYPE TERMS ======


{-| A parser for one term: a type name with no arguments, a type variable, `()`,
a parenthesised type or tuple, or a record or extensible record type.

An extensible record must have at least one field after the `|`. In a record,
the first field's comments after `{` are kept with the field, or, in an
extensible record, with the extended variable's name.

-}
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



-- ====== TYPE EXPRESSIONS ======


{-| Produces a parser for a whole type: a type application or a term, followed
by any number of `->` and further types, each arrow grouping to the right.

The result's comment group holds `trailingComments` first, which the caller
has already read before the type, then the comments read after the type, and
`Nothing` for the end-of-line comment. The position returned with it is where
the type ends, before those comments after it. An arrow is taken only when it
is indented past the current indentation column; otherwise the type ends
before it.

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
                                [ Space.checkIndent end1 E.TIndentStart
                                    |> P.andThen
                                        (\_ ->
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



-- ====== TYPE CONSTRUCTORS ======


{-| Produces a parser for a type name, possibly qualified, and its argument
terms, where `start` is where the name begins.

The result's comments are those read after the last argument, or after the
name when there are none. The `Src.TType` or `Src.TTypeQual` node carries the
region of the name alone, while its located wrapper spans from `start` to the
end of the last argument.

-}
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


{-| Produces a parser that reads argument terms for as long as each starts
indented past the current indentation column, where `args` holds the
arguments already read, in reverse order, and returns all of them in source
order.

`preComments` are the comments already read before the next argument and `end`
is where the previous token ended. Each argument is paired with the comments
before it, and the comments read after the last one are returned with the list,
along with the end of the last argument, or `end` when there is none.

-}
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



-- ====== TUPLES ======


{-| Produces a parser for the rest of a parenthesised type after its first
entry, up to and including the `)`, where `start` is the position of the `(`
and `revTypes` holds the later entries already read, in reverse order.

With no later entries, the result is the first type itself when no comments
were read after the `(` or before the `)`, and `Src.TParens` otherwise. With
one or more, it is a `Src.TTuple`.

-}
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



-- ====== RECORD ======


{-| One field of a record type: its name, and its type.

The name's comments are those after the name, before the `:`, and the type's
comments are those after the `:`, before the type.

-}
type alias Field =
    ( Src.C1 (A.Located Name), Src.C1 Src.Type )


{-| Produces a parser for the rest of a record type, up to and including the `}`,
where `fields` holds the fields already read, in reverse order.

`comments` are those read after the previous field's type. Each further field
is paired with the comments before its comma and those after it, and the
result is the fields in source order with the comments before the `}`.

-}
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


{-| A parser for one `name : type` field of a record type, returned with the
comments read after its type.
-}
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



-- ====== VARIANT ======


{-| Produces a parser for one variant of a custom type: an unqualified
constructor name followed by its argument terms, each indented past the
current indentation column.

The result's comment group holds `trailingComments`, which the caller has
already read before the variant, then the comments read after the last
argument (or after the name), and `Nothing` for the end-of-line comment. Each
argument is paired with the comments before it.

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
