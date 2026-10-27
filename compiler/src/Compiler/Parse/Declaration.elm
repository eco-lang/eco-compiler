module Compiler.Parse.Declaration exposing
    ( Decl(..)
    , declaration, infix_
    )

{-| Parses one top-level declaration of a module at a time, so that the module
parser can collect them into a module.

A declaration is a value definition, a custom type, a type alias or a port,
optionally preceded by a doc comment (a `{-| -}` comment). `declaration` parses
one of these; `infix_` parses the `infix` declaration that only kernel modules
use. Which of the two is tried, and that each declaration starts on a fresh
line, is decided by `Compiler.Parse.Module`.

Two facts shape the file. The first is layout: a declaration starts in column
1, and every later token of it must be indented, which at the top level means
not in column 1 (`Space.chompAndCheckIndent` and `Space.checkIndent`). That is
how a declaration ends where the next begins. The second is comments: the
formatter puts back the comments between the tokens, so most gaps are read with
`Space.chomp` or `Space.chompAndCheckIndent` and their comments are stored in a
`Src.C1` or `Src.C2` group. Two are dropped: the comments after a type alias's
body, and the comments after the doc comment of a custom type, alias or port.
Which gap a group holds is decided here, site by site, and is said at each
function. Most of the file is that bookkeeping.

A value may have a type annotation, `name : type`, on the lines before its
definition. The definition must then start on a fresh line and repeat the same
name.


# Declaration Types

@docs Decl


# Parsing Declarations

@docs declaration, infix_

-}

import Compiler.AST.Source as Src
import Compiler.AST.Utils.Binop as Binop
import Compiler.Data.Name exposing (Name)
import Compiler.Parse.Expression as Expr
import Compiler.Parse.Keyword as Keyword
import Compiler.Parse.Number as Number
import Compiler.Parse.Pattern as Pattern
import Compiler.Parse.Primitives as P
import Compiler.Parse.Space as Space
import Compiler.Parse.Symbol as Symbol
import Compiler.Parse.Type as Type
import Compiler.Parse.Variable as Var
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Syntax as E



-- ====== DECLARATION ======


{-| One top-level declaration, with the doc comment that precedes it, if any.

`Value` is a value definition, with its annotation if it has one; its region
starts at the annotation when there is one. `Union` is a custom type, `Alias` a
type alias and `Port` a port declaration.

-}
type Decl
    = Value (Maybe Src.Comment) (A.Located Src.Value)
    | Union (Maybe Src.Comment) (A.Located Src.Union)
    | Alias (Maybe Src.Comment) (A.Located Src.Alias)
    | Port (Maybe Src.Comment) Src.Port


{-| A parser for one top-level declaration: an optional doc comment, then a
custom type or type alias, a port, or a value definition with its optional
annotation.

The result's comment group is empty for a custom type or a type alias. For a
value its second part holds the comments read after the body, and for a port
the comments read after its type. The position returned with it is where the
declaration ends.

-}
declaration : Space.Parser E.Decl (Src.C2 Decl)
declaration =
    chompDocComment
        |> P.andThen
            (\( docComments, maybeDocs ) ->
                P.getPosition
                    |> P.andThen
                        (\start ->
                            P.oneOf E.DeclStart
                                [ typeDecl maybeDocs start
                                , portDecl maybeDocs
                                , valueDecl maybeDocs docComments start
                                ]
                        )
            )



-- ====== DOC COMMENT ======


{-| A parser for an optional doc comment, followed by the comments after it.
After a doc comment the next token must start on a fresh line
(`E.DeclFreshLineAfterDocComment`). Without a doc comment it consumes nothing
and returns no comments.
-}
chompDocComment : P.Parser E.Decl (Src.C1 (Maybe Src.Comment))
chompDocComment =
    P.oneOfWithFallback
        [ Space.docComment E.DeclStart E.DeclSpace
            |> P.andThen
                (\docComment ->
                    Space.chomp E.DeclSpace
                        |> P.andThen
                            (\comments ->
                                Space.checkFreshLine E.DeclFreshLineAfterDocComment
                                    |> P.map (\_ -> ( comments, Just docComment ))
                            )
                )
        ]
        ( [], Nothing )



-- ====== DEFINITION and ANNOTATION ======


{-| Produces a parser for a value definition, with or without an annotation.
`docComments` are the comments after the doc comment, and `start` is where the
declaration starts.

With an annotation, the definition must start on a fresh line with the same
name, and the result's `tipe` holds the type with three groups of comments:
the outer group is those after the type, and the inner pair those before and
after the `:`.

-}
valueDecl : Maybe Src.Comment -> Src.FComments -> A.Position -> Space.Parser E.Decl (Src.C2 Decl)
valueDecl maybeDocs docComments start =
    Var.lower E.DeclStart
        |> P.andThen
            (\name ->
                P.getPosition
                    |> P.andThen
                        (\end ->
                            P.specialize (E.DeclDef name) <|
                                (Space.chompAndCheckIndent E.DeclDefSpace E.DeclDefIndentEquals
                                    |> P.andThen
                                        (\postNameComments ->
                                            P.oneOf E.DeclDefEquals
                                                [ P.word1 ':' E.DeclDefEquals
                                                    |> P.andThen (\_ -> Space.chompAndCheckIndent E.DeclDefSpace E.DeclDefIndentType)
                                                    |> P.andThen
                                                        (\preTypeComments ->
                                                            P.specialize E.DeclDefType (Type.expression preTypeComments)
                                                                |> P.andThen
                                                                    (\( ( ( preTipeComments, postTipeComments, _ ), tipe ), _ ) ->
                                                                        Space.checkFreshLine E.DeclDefNameRepeat
                                                                            |> P.andThen (\_ -> chompMatchingName name)
                                                                            |> P.andThen
                                                                                (\defName ->
                                                                                    Space.chompAndCheckIndent E.DeclDefSpace E.DeclDefIndentEquals
                                                                                        |> P.andThen
                                                                                            (\preArgComments ->
                                                                                                let
                                                                                                    typeAnnotation : Maybe (Src.C1 (Src.C2 Src.Type))
                                                                                                    typeAnnotation =
                                                                                                        Just ( postTipeComments, ( ( postNameComments, preTipeComments ), tipe ) )
                                                                                                in
                                                                                                chompDefArgsAndBody maybeDocs docComments start defName typeAnnotation preArgComments []
                                                                                            )
                                                                                )
                                                                    )
                                                        )
                                                , let
                                                    locatedName : A.Located Name
                                                    locatedName =
                                                        A.at start end name
                                                  in
                                                  chompDefArgsAndBody maybeDocs docComments start locatedName Nothing postNameComments []
                                                ]
                                        )
                                )
                        )
            )


{-| Produces a parser for a definition's argument patterns, `=` and body, given
the parts already read. `revArgs` holds the arguments read so far, newest
first.

Each argument is paired with the comments before it, so the comments just after
the name go to the first argument. The name keeps `preArgComments` as they
stand when `=` is reached: the comments just before the `=`.

-}
chompDefArgsAndBody :
    Maybe Src.Comment
    -> Src.FComments
    -> A.Position
    -> A.Located Name
    -> Maybe (Src.C1 (Src.C2 Src.Type))
    -> Src.FComments
    -> List (Src.C1 Src.Pattern)
    -> Space.Parser E.DeclDef (Src.C2 Decl)
chompDefArgsAndBody maybeDocs docComments start name tipe preArgComments revArgs =
    P.oneOf E.DeclDefEquals
        [ P.specialize E.DeclDefArg Pattern.term
            |> P.andThen
                (\arg ->
                    Space.chompAndCheckIndent E.DeclDefSpace E.DeclDefIndentEquals
                        |> P.andThen
                            (\postArgComments ->
                                chompDefArgsAndBody maybeDocs docComments start name tipe postArgComments (( preArgComments, arg ) :: revArgs)
                            )
                )
        , P.word1 '=' E.DeclDefEquals
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.DeclDefSpace E.DeclDefIndentBody)
            |> P.andThen
                (\preBodyComments ->
                    P.specialize E.DeclDefBody Expr.expression
                        |> P.map
                            (\( ( trailingComments, body ), end ) ->
                                let
                                    value : Src.Value
                                    value =
                                        Src.Value { comments = docComments, name = ( preArgComments, name ), args = List.reverse revArgs, body = ( preBodyComments, body ), tipe = tipe }

                                    avalue : A.Located Src.Value
                                    avalue =
                                        A.at start end value
                                in
                                ( ( ( [], trailingComments ), Value maybeDocs avalue ), end )
                            )
                )
        ]


{-| Produces a parser for a lower-case name that must equal `expectedName`,
returning it with its region. A different name fails with `E.DeclDefNameMatch`
at the position where the name starts.
-}
chompMatchingName : Name -> P.Parser E.DeclDef (A.Located Name)
chompMatchingName expectedName =
    let
        (P.Parser parserL) =
            Var.lower E.DeclDefNameRepeat
    in
    P.Parser <|
        \((P.State st) as state) ->
            case parserL state of
                P.Cok name ((P.State st2) as newState) ->
                    if expectedName == name then
                        P.Cok (A.At (A.Region (A.Position st.row st.col) (A.Position st2.row st2.col)) name) newState

                    else
                        P.Cerr st.row st.col (E.DeclDefNameMatch name)

                P.Eok name ((P.State st2) as newState) ->
                    if expectedName == name then
                        P.Eok (A.At (A.Region (A.Position st.row st.col) (A.Position st2.row st2.col)) name) newState

                    else
                        P.Eerr st.row st.col (E.DeclDefNameMatch name)

                P.Cerr r c t ->
                    P.Cerr r c t

                P.Eerr r c t ->
                    P.Eerr r c t



-- ====== TYPE DECLARATIONS ======


{-| Produces a parser for a declaration starting with `type`: a type alias when
`alias` follows, otherwise a custom type. The comments between `type` and the
next word become the alias's `comments`, or the comments before a custom
type's name.
-}
typeDecl : Maybe Src.Comment -> A.Position -> Space.Parser E.Decl (Src.C2 Decl)
typeDecl maybeDocs start =
    P.inContext E.DeclType (Keyword.type_ E.DeclStart) <|
        (Space.chompAndCheckIndent E.DT_Space E.DT_IndentName
            |> P.andThen
                (\postTypeComments ->
                    P.oneOf E.DT_Name
                        [ P.inContext E.DT_Alias (Keyword.alias_ E.DT_Name) <|
                            (Space.chompAndCheckIndent E.AliasSpace E.AliasIndentEquals
                                |> P.andThen
                                    (\preComments ->
                                        chompAliasNameToEquals
                                            |> P.andThen
                                                (\( ( name, args, postComments ), preTypeComments ) ->
                                                    P.specialize E.AliasBody (Type.expression [])
                                                        |> P.map
                                                            (\( ( _, tipe ), end ) ->
                                                                let
                                                                    alias_ : A.Located Src.Alias
                                                                    alias_ =
                                                                        A.at start
                                                                            end
                                                                            (Src.Alias
                                                                                { comments = postTypeComments
                                                                                , name = ( ( preComments, postComments ), name )
                                                                                , args = args
                                                                                , tipe = ( preTypeComments, tipe )
                                                                                }
                                                                            )
                                                                in
                                                                ( ( ( [], [] ), Alias maybeDocs alias_ ), end )
                                                            )
                                                )
                                    )
                            )
                        , P.specialize E.DT_Union <|
                            (chompCustomNameToEquals postTypeComments
                                |> P.andThen
                                    (\( preVariantsComments, ( name, args ) ) ->
                                        Type.variant preVariantsComments
                                            |> P.andThen
                                                (\( firstVariant, firstEnd ) ->
                                                    chompVariants [ firstVariant ] firstEnd
                                                        |> P.map
                                                            (\( variants, end ) ->
                                                                let
                                                                    union : A.Located Src.Union
                                                                    union =
                                                                        A.at start end (Src.Union name args variants)
                                                                in
                                                                ( ( ( [], [] ), Union maybeDocs union ), end )
                                                            )
                                                )
                                    )
                            )
                        ]
                )
        )



-- ====== TYPE ALIASES ======


{-| A parser for a type alias's name, its type variables and the `=`. The
result holds the name, the variables each with the comments before it, the
comments just before the `=`, and then the comments after the `=`.
-}
chompAliasNameToEquals : P.Parser E.TypeAlias ( ( A.Located Name, List (Src.C1 (A.Located Name)), Src.FComments ), Src.FComments )
chompAliasNameToEquals =
    P.addLocation (Var.upper E.AliasName)
        |> P.andThen
            (\name ->
                Space.chompAndCheckIndent E.AliasSpace E.AliasIndentEquals
                    |> P.andThen
                        (\comments ->
                            chompAliasNameToEqualsHelp name [] comments
                        )
            )


{-| Produces a parser for the rest of a type alias's variables and its `=`.
`comments` are those read since the previous token; they go with the next
variable, or, at the `=`, into the result.
-}
chompAliasNameToEqualsHelp :
    A.Located Name
    -> List (Src.C1 (A.Located Name))
    -> Src.FComments
    -> P.Parser E.TypeAlias ( ( A.Located Name, List (Src.C1 (A.Located Name)), Src.FComments ), Src.FComments )
chompAliasNameToEqualsHelp name args comments =
    P.oneOf E.AliasEquals
        [ P.addLocation (Var.lower E.AliasEquals)
            |> P.andThen
                (\arg ->
                    Space.chompAndCheckIndent E.AliasSpace E.AliasIndentEquals
                        |> P.andThen
                            (\postComments ->
                                chompAliasNameToEqualsHelp name (( comments, arg ) :: args) postComments
                            )
                )
        , P.word1 '=' E.AliasEquals
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.AliasSpace E.AliasIndentBody)
            |> P.map (\preBodyComments -> ( ( name, List.reverse args, comments ), preBodyComments ))
        ]



-- ====== CUSTOM TYPES ======


{-| Produces a parser for a custom type's name, its type variables and the `=`,
given the comments before the name. The name is returned with those comments
and the comments just before the `=`, each variable with the comments before
it, and all of it with the comments after the `=`.
-}
chompCustomNameToEquals : Src.FComments -> P.Parser E.CustomType (Src.C1 ( Src.C2 (A.Located Name), List (Src.C1 (A.Located Name)) ))
chompCustomNameToEquals preNameComments =
    P.addLocation (Var.upper E.CT_Name)
        |> P.andThen
            (\name ->
                Space.chompAndCheckIndent E.CT_Space E.CT_IndentEquals
                    |> P.andThen (\trailingComments -> chompCustomNameToEqualsHelp trailingComments ( preNameComments, name ) [])
            )


{-| Produces a parser for the rest of a custom type's variables and its `=`.
`trailingComments` are those read since the previous token; they go with the
next variable, or, at the `=`, with the name.
-}
chompCustomNameToEqualsHelp : Src.FComments -> Src.C1 (A.Located Name) -> List (Src.C1 (A.Located Name)) -> P.Parser E.CustomType (Src.C1 ( Src.C2 (A.Located Name), List (Src.C1 (A.Located Name)) ))
chompCustomNameToEqualsHelp trailingComments (( preNameComments, name_ ) as name) args =
    P.oneOf E.CT_Equals
        [ P.addLocation (Var.lower E.CT_Equals)
            |> P.andThen
                (\arg ->
                    Space.chompAndCheckIndent E.CT_Space E.CT_IndentEquals
                        |> P.andThen (\postArgComments -> chompCustomNameToEqualsHelp postArgComments name (( trailingComments, arg ) :: args))
                )
        , P.word1 '=' E.CT_Equals
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.CT_Space E.CT_IndentAfterEquals)
            |> P.map (\postEqualComments -> ( postEqualComments, ( ( ( preNameComments, trailingComments ), name_ ), List.reverse args ) ))
        ]


{-| Produces a parser for any further `| Variant` alternatives of a custom type,
given the variants read so far, newest first, and where the last one ended.
Each `|` must be indented. It returns the variants in source order and where
the last one ends.
-}
chompVariants : List (Src.C2Eol ( A.Located Name, List (Src.C1 Src.Type) )) -> A.Position -> Space.Parser E.CustomType (List (Src.C2Eol ( A.Located Name, List (Src.C1 Src.Type) )))
chompVariants variants end =
    P.oneOfWithFallback
        [ Space.checkIndent end E.CT_IndentBar
            |> P.andThen (\_ -> P.word1 '|' E.CT_Bar)
            |> P.andThen (\_ -> Space.chompAndCheckIndent E.CT_Space E.CT_IndentAfterBar)
            |> P.andThen (\preTypeComments -> Type.variant preTypeComments)
            |> P.andThen (\( variant, newEnd ) -> chompVariants (variant :: variants) newEnd)
        ]
        ( List.reverse variants, end )



-- ====== PORT ======


{-| Produces a parser for `port name : type`. The result's comment group holds
the comments read after the type.
-}
portDecl : Maybe Src.Comment -> Space.Parser E.Decl (Src.C2 Decl)
portDecl maybeDocs =
    P.inContext E.Port (Keyword.port_ E.DeclStart) <|
        (Space.chompAndCheckIndent E.PortSpace E.PortIndentName
            |> P.andThen
                (\preNameComments ->
                    P.addLocation (Var.lower E.PortName)
                        |> P.andThen
                            (\name ->
                                Space.chompAndCheckIndent E.PortSpace E.PortIndentColon
                                    |> P.andThen
                                        (\postNameComments ->
                                            P.word1 ':' E.PortColon
                                                |> P.andThen (\_ -> Space.chompAndCheckIndent E.PortSpace E.PortIndentType)
                                                |> P.andThen
                                                    (\typeComments ->
                                                        P.specialize E.PortType (Type.expression [])
                                                            |> P.map
                                                                (\( ( ( preTipeComments, postTipeComments, _ ), tipe ), end ) ->
                                                                    let
                                                                        port_ : Src.Port
                                                                        port_ =
                                                                            Src.Port typeComments ( ( preNameComments, postNameComments ), name ) tipe
                                                                    in
                                                                    ( ( ( preTipeComments, postTipeComments ), Port maybeDocs port_ ), end )
                                                                )
                                                    )
                                        )
                            )
                )
        )



-- ====== INFIX ======


{-| A parser for `infix left|right|non N (op) = name`.

It reads the comments after `name` and then requires a fresh line, returning
those comments with the declaration. Every failure is reported as `E.Infix`.

-}
infix_ : P.Parser E.Module (Src.C1 (A.Located Src.Infix))
infix_ =
    let
        err : P.Row -> P.Col -> E.Module
        err =
            E.Infix

        err_ : a -> P.Row -> P.Col -> E.Module
        err_ =
            \_ -> E.Infix
    in
    P.getPosition
        |> P.andThen
            (\start ->
                Keyword.infix_ err
                    |> P.andThen (\_ -> Space.chompAndCheckIndent err_ err)
                    |> P.andThen
                        (\preBinopComments ->
                            P.oneOf err
                                [ Keyword.left_ err |> P.map (\_ -> Binop.Left)
                                , Keyword.right_ err |> P.map (\_ -> Binop.Right)
                                , Keyword.non_ err |> P.map (\_ -> Binop.Non)
                                ]
                                |> P.map (Tuple.pair preBinopComments)
                        )
                    |> P.andThen
                        (\associativity ->
                            Space.chompAndCheckIndent err_ err
                                |> P.andThen
                                    (\prePrecedenceComments ->
                                        Number.precedence err
                                            |> P.map (Tuple.pair prePrecedenceComments)
                                    )
                                |> P.andThen
                                    (\precedence ->
                                        Space.chompAndCheckIndent err_ err
                                            |> P.andThen
                                                (\preOpComments ->
                                                    P.word1 '(' err
                                                        |> P.andThen (\_ -> Symbol.operator err err_)
                                                        |> P.andThen
                                                            (\op ->
                                                                P.word1 ')' err
                                                                    |> P.andThen (\_ -> Space.chompAndCheckIndent err_ err)
                                                                    |> P.andThen
                                                                        (\postOpComments ->
                                                                            P.word1 '=' err
                                                                                |> P.andThen (\_ -> Space.chompAndCheckIndent err_ err)
                                                                                |> P.andThen
                                                                                    (\preNameComments ->
                                                                                        Var.lower err
                                                                                            |> P.andThen
                                                                                                (\name ->
                                                                                                    P.getPosition
                                                                                                        |> P.andThen
                                                                                                            (\end ->
                                                                                                                Space.chomp err_
                                                                                                                    |> P.andThen
                                                                                                                        (\comments ->
                                                                                                                            let
                                                                                                                                infixDecl : Src.Infix
                                                                                                                                infixDecl =
                                                                                                                                    Src.Infix
                                                                                                                                        { op = ( ( preOpComments, postOpComments ), op )
                                                                                                                                        , associativity = associativity
                                                                                                                                        , precedence = precedence
                                                                                                                                        , name = ( preNameComments, name )
                                                                                                                                        }
                                                                                                                            in
                                                                                                                            Space.checkFreshLine err
                                                                                                                                |> P.map (\_ -> ( comments, A.at start end infixDecl ))
                                                                                                                        )
                                                                                                            )
                                                                                                )
                                                                                    )
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )
