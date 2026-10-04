module Compiler.AST.Source exposing
    ( C1, C2, C0Eol, C1Eol, C2Eol
    , c1map, c1Value, c2map, c2Value, c0EolMap, c2EolMap, c2EolValue
    , FComment(..), FComments, Comment(..), ForceMultiline(..)
    , Expr, Expr_(..), VarType(..)
    , Pattern, Pattern_(..)
    , Type, Type_(..)
    , Def(..), Value(..), ValueData
    , Module(..), ModuleData, Import(..), getName, getImportName
    , Union(..), Alias(..), AliasData, Infix(..), InfixData
    , Effects(..), Manager(..), Port(..)
    , Exposing(..), Exposed(..), Privacy(..), Docs(..)
    , OpenCommentedList(..), Pair(..), openCommentedListMap, mapPair, sequenceAC2
    , moduleEncoder, moduleDecoder, typeEncoder, typeDecoder
    )

{-| The parsed form of an Elm module, holding enough of what was written for the
module to be printed back as Elm source as well as compiled.

Besides the syntax, this tree keeps the ordinary comments found between
tokens, the spelling of each number literal, whether a string was
triple-quoted, the parentheses the source wrote round an expression or a
pattern, and each doc comment as a slice of the file's text.

Comments are attached by pairing a value with the comments that sit next to it.
The wrappers are named by how many groups of comments they hold: a `C1` holds
one group and a `C2` two, and an `Eol` variant adds room for an end-of-line
comment. The type does not say on which side of the value a group lies. The
parser decides that at each place a wrapper is used, so in a top-level value
the `C1` of the body holds the comments after the `=` but the `C1` of the name
holds the comments just before the `=`.

Each comment between tokens is an `FComment`. Doc comments, written between
`{-|` and `-}`, are not among them: they are `Comment` values, collected in
the module's `Docs`.

The tree does not hold enough to reproduce a file byte for byte. Whitespace is
not kept, and the parser drops some comments, among them those between an
operator and a `let`, `case`, `if` or lambda that follows it, those inside a
`()` pattern, and those inside the `( .. )` of an exposed type. Several lists
are in reverse source order: the module's declarations and their doc comments,
as `Compiler.Parse.Module` describes, and the fields of a record pattern.

The second half of the file is a binary codec for the whole tree, in the format
of `Utils.Bytes.Encode`. A value of a type with more than one constructor is
written as a one-byte tag followed by its parts; a type with one constructor is
written as its parts alone. Each tag is an integer literal in the encoder's
`case`, mapped back by the matching decoder, and a decoder fails on a tag it
does not know. Regions are written in the fixed form of
`Compiler.Reporting.Annotation`.


# Comment Containers

These types wrap values with their surrounding comments:

@docs C1, C2, C0Eol, C1Eol, C2Eol
@docs c1map, c1Value, c2map, c2Value, c0EolMap, c2EolMap, c2EolValue


# Comment Types

@docs FComment, FComments, Comment, ForceMultiline


# Expressions

@docs Expr, Expr_, VarType


# Patterns

@docs Pattern, Pattern_


# Types

@docs Type, Type_


# Definitions

@docs Def, Value, ValueData


# Module Structure

@docs Module, ModuleData, Import, getName, getImportName


# Type Declarations

@docs Union, Alias, AliasData, Infix, InfixData


# Effects

@docs Effects, Manager, Port


# Exposing

@docs Exposing, Exposed, Privacy, Docs


# Utility Types

@docs OpenCommentedList, Pair, openCommentedListMap, mapPair, sequenceAC2


# Binary Serialization

@docs moduleEncoder, moduleDecoder, typeEncoder, typeDecoder

-}

import Bytes.Decode
import Bytes.Encode
import Compiler.AST.Snippet as Snippet exposing (Snippet)
import Compiler.AST.Utils.Binop as Binop
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE



-- ====== FORMAT ======


{-| A flag asking for a construct to be printed across several lines.

The parser never builds one. Among the types of this module, only `Pair` holds
one.

-}
type ForceMultiline
    = ForceMultiline Bool


{-| One ordinary comment, written between tokens in the source.

`BlockComment` is a `{- -}` comment. It holds the text between the delimiters,
split into lines, with any nested comment left in the text.

`LineComment` is a `--` comment. It holds the text after the `--` up to the end
of the line.

The other three are the comment trick, a way of switching code on and off by
editing one character. `CommentTrickOpener` stands for `{--}`,
`CommentTrickCloser` for a `--` followed by a closing brace, and
`CommentTrickBlock` for `{--` followed by its text and `-}`. The parser never
produces these three: it reads every ordinary comment as a `BlockComment` or
a `LineComment`.

-}
type FComment
    = BlockComment (List String)
    | LineComment String
    | CommentTrickOpener
    | CommentTrickCloser
    | CommentTrickBlock String


{-| The ordinary comments found together at one place in the source.
-}
type alias FComments =
    List FComment


{-| A value paired with one group of comments that belongs with it.

The type does not say on which side of the value the comments lie; the parser
decides at each place a `C1` is used. For the body of a top-level value they
are the comments after its `=`, and for its name they are the comments just
before the `=`.

-}
type alias C1 a =
    ( FComments, a )


{-| Applies `f` to the value in a `C1`, keeping its comments.
-}
c1map : (a -> b) -> C1 a -> C1 b
c1map f ( comments, a ) =
    ( comments, f a )


{-| Returns the value in a `C1` without its comments.
-}
c1Value : C1 a -> a
c1Value ( _, a ) =
    a


{-| A value paired with two groups of comments that belong with it.

The type does not say on which side of the value each group lies; the parser
decides at each place a `C2` is used. For the expression a `case` examines they
are the comments before it and after it. For the type in a top-level annotation
both groups come before the type, one on each side of the `:`.

-}
type alias C2 a =
    ( ( FComments, FComments ), a )


{-| Applies `f` to the value in a `C2`, keeping both groups of comments.
-}
c2map : (a -> b) -> C2 a -> C2 b
c2map f ( ( before, after ), a ) =
    ( ( before, after ), f a )


{-| Returns the value in a `C2` without its comments.
-}
c2Value : C2 a -> a
c2Value ( _, a ) =
    a


{-| Combines a list of `C2` values into one `C2` holding the list of values, in
order.

The first group of comments in the result is the first groups of the elements
joined in list order, and the second group is their second groups joined the
same way.

-}
sequenceAC2 : List (C2 a) -> C2 (List a)
sequenceAC2 =
    List.foldr
        (\( ( before, after ), a ) ( ( beforeAcc, afterAcc ), acc ) ->
            ( ( before ++ beforeAcc, after ++ afterAcc ), a :: acc )
        )
        ( ( [], [] ), [] )


{-| A value with room for an end-of-line comment after it, and no other comments.

The parser never fills an end-of-line slot: every `C0Eol`, `C1Eol` and `C2Eol`
it builds holds `Nothing` there.

-}
type alias C0Eol a =
    ( Maybe String, a )


{-| Applies `f` to the value in a `C0Eol`, keeping its end-of-line comment.
-}
c0EolMap : (a -> b) -> C0Eol a -> C0Eol b
c0EolMap f ( eol, a ) =
    ( eol, f a )


{-| A value with one group of comments and room for an end-of-line comment.
-}
type alias C1Eol a =
    ( FComments, Maybe String, a )


{-| A value with two groups of comments and room for an end-of-line comment.

As with `C2`, the parser decides at each place it is used on which side of the
value each group lies. For an entry of a list expression both groups come
before the entry: the comments before the comma that precedes it, and those
after that comma (for the first entry, nothing and the comments after the
`[`).

-}
type alias C2Eol a =
    ( ( FComments, FComments, Maybe String ), a )


{-| Applies `f` to the value in a `C2Eol`, keeping its comments and its
end-of-line comment.
-}
c2EolMap : (a -> b) -> C2Eol a -> C2Eol b
c2EolMap f ( ( before, after, eol ), a ) =
    ( ( before, after, eol ), f a )


{-| Returns the value in a `C2Eol` without its comments.
-}
c2EolValue : C2Eol a -> a
c2EolValue ( _, a ) =
    a


{-| A non-empty sequence with a delimiter before each item and nothing to close
it, such as the constructors of a custom type, each introduced by `=` or `|`.

`OpenCommentedList rest last` keeps the last item apart from the others. Each
earlier item carries two groups of comments and room for an end-of-line
comment; the last carries one group and room for an end-of-line comment.

No part of the parsed tree holds one: the parser keeps a custom type's
constructors as a plain list. It is a shape for code that prints the tree.

-}
type OpenCommentedList a
    = OpenCommentedList (List (C2Eol a)) (C1Eol a)


{-| Applies `f` to every item of an `OpenCommentedList`, keeping all of the
comments.
-}
openCommentedListMap : (a -> b) -> OpenCommentedList a -> OpenCommentedList b
openCommentedListMap f (OpenCommentedList rest ( preLst, eolLst, lst )) =
    OpenCommentedList
        (List.map (\( ( pre, post, eol ), a ) -> ( ( pre, post, eol ), f a )) rest)
        ( preLst, eolLst, f lst )


{-| Two things joined by a delimiter, such as a record field and its value
either side of `=`, or a field and its type either side of `:`.

The delimiter itself is not stored. In `Pair key value multiline`, `key` carries
the comments after it and `value` the comments before it, so both groups lie
between them. Like `OpenCommentedList`, no part of the parsed tree holds one.

-}
type Pair key value
    = Pair (C1 key) (C1 value) ForceMultiline


{-| Applies `fa` to the key and `fb` to the value of a `Pair`, keeping the
comments and the multiline flag.
-}
mapPair : (a1 -> a2) -> (b1 -> b2) -> Pair a1 b1 -> Pair a2 b2
mapPair fa fb (Pair k v fm) =
    Pair (c1map fa k) (c1map fb v) fm



-- ====== EXPRESSIONS ======


{-| An expression and the region of source it was parsed from.
-}
type alias Expr =
    A.Located Expr_


{-| One expression of Elm source, in the form it was written.

`Chr` and `Str` hold the literal in escaped form, as `Compiler.Parse.String`
produces it, not the value it denotes. The `Bool` of `Str` is `True` for a
triple-quoted string.

`Int` and `Float` hold the value and the literal's spelling, such as `0xFF` or
`1e3`.

`Var` is a name without a module prefix and `VarQual` a name with one, the
prefix first. Their `VarType` says whether the name is lower-case or
capitalised.

`List` holds its entries and then the comments just before the closing bracket.

`Op` is an operator used as a value, as in `(+)`.

`Negate` is a prefix minus. The parser puts it round a single term only, so
`-f x` is not a negated call.

`Binops` is a whole chain of infix operators, kept flat: each operand paired
with the operator after it, then the last operand. Precedence and
associativity have not been applied. A parsed chain never holds another
`Binops` as an operand.

`Lambda` holds its argument patterns and its body. `Call` is a function applied
to arguments; the parser builds one only when there is at least one.

`If` holds the first condition and branch, each `else if` condition and branch
after it, and the final `else` branch, so a chain of `else if` is one `If`.

`Let` holds its definitions, the comments between `in` and the body, and the
body.

`Case` holds the expression it examines and its branches, each a pattern and an
expression.

`Accessor` is a field accessor such as `.name`, and `Access` a field read from
an expression, as in `r.name`.

`Update` is a record update, `{ r | ... }`. The parser always makes the record
being updated a lower-case `Var`.

`Record` is a record literal, `Unit` is `()`, and `Tuple` is a tuple of two or
more, its first two elements kept apart from the rest.

`Shader` is a block of GLSL, as `Compiler.AST.Utils.Shader` describes.

`Parens` is an expression the source wrapped in parentheses, kept so that they
can be printed again.

-}
type Expr_
    = Chr String
    | Str String Bool
    | Int Int String
    | Float Float String
    | Var VarType Name
    | VarQual VarType Name Name
    | List (List (C2Eol Expr)) FComments
    | Op Name
    | Negate Expr
    | Binops (List ( Expr, C2 (A.Located Name) )) Expr
    | Lambda (C1 (List (C1 Pattern))) (C1 Expr)
    | Call Expr (List (C1 Expr))
    | If (C1 ( C2 Expr, C2 Expr )) (List (C1 ( C2 Expr, C2 Expr ))) (C1 Expr)
    | Let (List (C2 (A.Located Def))) FComments Expr
    | Case (C2 Expr) (List ( C2 Pattern, C1 Expr ))
    | Accessor Name
    | Access Expr (A.Located Name)
    | Update (C2 Expr) (C1 (List (C2Eol ( C1 (A.Located Name), C1 Expr ))))
    | Record (C1 (List (C2Eol ( C1 (A.Located Name), C1 Expr ))))
    | Unit
    | Tuple (C2 Expr) (C2 Expr) (List (C2 Expr))
    | Shader Shader.Source Shader.Types
    | Parens (C2 Expr)


{-| Whether a variable names a lower-case value (`LowVar`) or a capitalised one,
such as a constructor (`CapVar`).
-}
type VarType
    = LowVar
    | CapVar



-- ====== DEFINITIONS ======


{-| One definition inside a `let`.

`Define` binds a name: it holds the name, the argument patterns, the body, and
the type annotation if one was written. `Destruct` binds the variables of a
pattern, as in `( a, b ) = pair`.

-}
type Def
    = Define (A.Located Name) (List (C1 Pattern)) (C1 Expr) (Maybe (C1 (C2 Type)))
    | Destruct Pattern (C1 Expr)



-- ====== PATTERN ======


{-| A pattern and the region of source it was parsed from.
-}
type alias Pattern =
    A.Located Pattern_


{-| One pattern of Elm source, in the form it was written.

`PAnything` is the wildcard `_`. The parser always gives it the empty name,
since it rejects `_` followed by a name.

`PVar` binds a variable.

`PRecord` holds the names of the fields it binds, which the parser stores in
reverse source order.

`PAlias` is a pattern followed by `as` and a name.

`PUnit` is `()`. The parser always gives it an empty list of comments.

`PTuple` is a tuple of two or more, its first two elements kept apart from the
rest.

`PCtor` is a constructor applied to argument patterns, and `PCtorQual` the same
with a module prefix, the prefix first. Their `A.Region` argument covers the
constructor's name only; the pattern's own region covers the arguments too.

`PList` is a list pattern and `PCons` is `head :: tail`.

`PChr`, `PStr` and `PInt` are literal patterns, holding what `Chr`, `Str` and
`Int` hold in an expression.

`PParens` is a pattern the source wrapped in parentheses, kept so that they can
be printed again.

-}
type Pattern_
    = PAnything Name
    | PVar Name
    | PRecord (C1 (List (C2 (A.Located Name))))
    | PAlias (C1 Pattern) (C1 (A.Located Name))
    | PUnit FComments
    | PTuple (C2 Pattern) (C2 Pattern) (List (C2 Pattern))
    | PCtor A.Region Name (List (C1 Pattern))
    | PCtorQual A.Region Name Name (List (C1 Pattern))
    | PList (C1 (List (C2 Pattern)))
    | PCons (C0Eol Pattern) (C2Eol Pattern)
    | PChr String
    | PStr String Bool
    | PInt Int String
    | PParens (C2 Pattern)



-- ====== TYPE ======


{-| A type as written in the source, and the region it was parsed from.
-}
type alias Type =
    A.Located Type_


{-| One type of Elm source, as written in an annotation or a declaration.

`TLambda` is one arrow, from its argument to its result, so `a -> b -> c` is an
arrow whose result is the arrow `b -> c`.

`TVar` is a type variable.

`TType` is a named type applied to its arguments, and `TTypeQual` the same with
a module prefix, the prefix first. Their `A.Region` argument covers the type's
name only.

`TRecord` is a record type. It holds its fields, the variable it extends when
written as `{ r | ... }`, and the comments just before the closing brace.

`TUnit` is `()`, and `TTuple` is a tuple of two or more, its first two elements
kept apart from the rest.

`TParens` is a parenthesised type with comments inside its parentheses. A
parenthesised type without such comments is stored as the bare inner type, so
its parentheses are not kept.

-}
type Type_
    = TLambda (C0Eol Type) (C2Eol Type)
    | TVar Name
    | TType A.Region Name (List (C1 Type))
    | TTypeQual A.Region Name Name (List (C1 Type))
    | TRecord (List (C2 ( C1 (A.Located Name), C1 Type ))) (Maybe (C2 (A.Located Name))) FComments
    | TUnit
    | TTuple (C2Eol Type) (C2Eol Type) (List (C2Eol Type))
    | TParens (C2 Type)



-- ====== MODULE ======


{-| Everything parsed from one module file.

`name` is `Nothing` for a file with no `module` line, and for such a file
`exports` is an open `exposing (..)` with the region `A.one`.

`values`, `unions`, `aliases` and `infixes` are in reverse source order, as
`Compiler.Parse.Module` describes. Ports are not among them; they are in
`effects`.

`imports` starts with the default imports the parser adds, except when the
package is `elm/core`, followed by the file's `import` lines in source order.

-}
type alias ModuleData =
    { name : Maybe (A.Located Name)
    , exports : A.Located Exposing
    , docs : Docs
    , imports : List Import
    , values : List (A.Located Value)
    , unions : List (A.Located Union)
    , aliases : List (A.Located Alias)
    , infixes : List (A.Located Infix)
    , effects : Effects
    }


{-| A parsed module. It wraps `ModuleData` and adds nothing to it.
-}
type Module
    = Module ModuleData


{-| Returns the name from the module's `module` line, or `Main`
(`Name.mainModule`) for a file without one.
-}
getName : Module -> Name
getName (Module data) =
    case data.name of
        Just (A.At _ name) ->
            name

        Nothing ->
            Name.mainModule


{-| Returns the name of the module an import brings in, as written, without any
alias.
-}
getImportName : Import -> Name
getImportName (Import ( _, A.At _ name ) _ _) =
    name


{-| One import: an `import` line of the file, or one of the default imports the
parser adds. It holds the module's name, its alias if `as` gave one, and its
`exposing` list.

An import written without `exposing` gets an empty `Explicit` list whose region
is `A.zero`. An `Import` has no region of its own; only its name does.

-}
type Import
    = Import (C1 (A.Located Name)) (Maybe (C2 Name)) (C2 Exposing)


{-| A top-level value or function definition, with its comments.

`comments` holds the ordinary comments between the definition's doc comment and
the definition, and is empty when there is no doc comment. The doc comment
itself is in the module's `Docs`. `tipe` is the type annotation, if one was
written.

-}
type alias ValueData =
    { comments : FComments
    , name : C1 (A.Located Name)
    , args : List (C1 Pattern)
    , body : C1 Expr
    , tipe : Maybe (C1 (C2 Type))
    }


{-| A top-level value or function definition. It wraps `ValueData` and adds
nothing to it.
-}
type Value
    = Value ValueData


{-| A custom type declaration: its name, its type parameters, and its
constructors, each a name with the types of its arguments.
-}
type Union
    = Union (C2 (A.Located Name)) (List (C1 (A.Located Name))) (List (C2Eol ( A.Located Name, List (C1 Type) )))


{-| A type alias declaration, with its comments.

`comments` holds the comments between the keywords `type` and `alias`.

-}
type alias AliasData =
    { comments : FComments
    , name : C2 (A.Located Name)
    , args : List (C1 (A.Located Name))
    , tipe : C1 Type
    }


{-| A type alias declaration. It wraps `AliasData` and adds nothing to it.
-}
type Alias
    = Alias AliasData


{-| An infix declaration, which makes an operator stand for a named function and
gives it an associativity and a precedence.

`op` is the operator and `name` the function it stands for. The parser accepts
infix declarations only in kernel projects, as `Compiler.Parse.Module`
describes.

-}
type alias InfixData =
    { op : C2 Name
    , associativity : C1 Binop.Associativity
    , precedence : C1 Binop.Precedence
    , name : C1 Name
    }


{-| An infix declaration. It wraps `InfixData` and adds nothing to it.
-}
type Infix
    = Infix InfixData


{-| A `port` declaration: its name and its type.

The `FComments` field is the comments between the `:` and the type. A `Port`
has no region of its own; only its name does.

-}
type Port
    = Port FComments (C2 (A.Located Name)) Type


{-| The kind of effects a module declares.

`NoEffects` is an ordinary module. `Ports` holds a port module's port
declarations. `Manager` is an effect module, with the region of its
`effect module` keywords and what it manages.

The parser checks these against the kind of project, as `Compiler.Parse.Module`
describes. A file with no `module` line skips that check and keeps any ports it
declares as `Ports`.

-}
type Effects
    = NoEffects
    | Ports (List Port)
    | Manager A.Region Manager


{-| What an effect module manages: commands, subscriptions or both. Each is given
by the name of the type that represents it, as in `command = MyCmd`.
-}
type Manager
    = Cmd (C2 (C2 (A.Located Name)))
    | Sub (C2 (C2 (A.Located Name)))
    | Fx (C2 (C2 (A.Located Name))) (C2 (C2 (A.Located Name)))


{-| The doc comments of a module: the module's own, and those of its
declarations.

`YesDocs` carries the module's doc comment. `NoDocs` is a module without one,
and carries the region where it was looked for, which is `A.one` for a file
with no `module` line.

Both carry the declarations' doc comments, each paired with the name it
documents, in reverse source order, as `Compiler.Parse.Module` describes. A
declaration with no doc comment has no entry.

-}
type Docs
    = NoDocs A.Region (List ( Name, Comment ))
    | YesDocs Comment (List ( Name, Comment ))


{-| A doc comment, held as the `Snippet` of the text between `{-|` and `-}`.

A snippet holds the whole text of its file, so encoding a `Comment` writes the
whole file.

-}
type Comment
    = Comment Snippet



-- ====== EXPOSING ======


{-| An `exposing` list.

`Open` is `exposing (..)`, with the comments before and after the `..`.
`Explicit` holds the items, with a region running from just after the `(` to
just after the `)`.

-}
type Exposing
    = Open FComments FComments
    | Explicit (A.Located (List (C2 Exposed)))


{-| One item of an explicit `exposing` list.

`Lower` is a value. `Upper` is a type, with whether its constructors are
exposed. `Operator` is an operator in parentheses, with a region covering the
parentheses and the operator.

-}
type Exposed
    = Lower (A.Located Name)
    | Upper (A.Located Name) (C1 Privacy)
    | Operator A.Region Name


{-| Whether an exposed type exposes its constructors.

`Public` is `Type(..)`, with the region of the `..` only. `Private` is a bare
`Type`. Comments inside the parentheses are not kept.

-}
type Privacy
    = Public A.Region
    | Private



-- ====== ENCODERS and DECODERS ======


{-| Encodes one comment as a tag byte followed by its text, if it has any.
-}
fCommentEncoder : FComment -> Bytes.Encode.Encoder
fCommentEncoder formatComment =
    case formatComment of
        BlockComment c ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.list BE.string c
                ]

        LineComment c ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string c
                ]

        CommentTrickOpener ->
            Bytes.Encode.unsignedInt8 2

        CommentTrickCloser ->
            Bytes.Encode.unsignedInt8 3

        CommentTrickBlock c ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , BE.string c
                ]


{-| A decoder for one comment as `fCommentEncoder` writes it.
-}
fCommentDecoder : Bytes.Decode.Decoder FComment
fCommentDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map BlockComment (BD.list BD.string)

                    1 ->
                        Bytes.Decode.map LineComment BD.string

                    2 ->
                        Bytes.Decode.succeed CommentTrickOpener

                    3 ->
                        Bytes.Decode.succeed CommentTrickCloser

                    4 ->
                        Bytes.Decode.map CommentTrickBlock BD.string

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a list of comments.
-}
fCommentsEncoder : FComments -> Bytes.Encode.Encoder
fCommentsEncoder =
    BE.list fCommentEncoder


{-| A decoder for a list of comments as `fCommentsEncoder` writes it.
-}
fCommentsDecoder : Bytes.Decode.Decoder FComments
fCommentsDecoder =
    BD.list fCommentDecoder


{-| Encodes a `C0Eol` as its end-of-line comment, then its value as `encoder`
writes it.
-}
c0EolEncoder : (a -> Bytes.Encode.Encoder) -> C0Eol a -> Bytes.Encode.Encoder
c0EolEncoder encoder ( eol, a ) =
    Bytes.Encode.sequence
        [ BE.maybe BE.string eol
        , encoder a
        ]


{-| Produces a decoder for a `C0Eol` as `c0EolEncoder` writes it, reading the
value with `decoder`.
-}
c0EolDecoder : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (C0Eol a)
c0EolDecoder decoder =
    Bytes.Decode.map2 Tuple.pair
        (BD.maybe BD.string)
        decoder


{-| Encodes a `C1` as its comments, then its value as `encoder` writes it.
-}
c1Encoder : (a -> Bytes.Encode.Encoder) -> C1 a -> Bytes.Encode.Encoder
c1Encoder encoder ( comments, a ) =
    Bytes.Encode.sequence
        [ fCommentsEncoder comments
        , encoder a
        ]


{-| Produces a decoder for a `C1` as `c1Encoder` writes it, reading the value with
`decoder`.
-}
c1Decoder : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (C1 a)
c1Decoder decoder =
    Bytes.Decode.map2 Tuple.pair fCommentsDecoder decoder


{-| Encodes a `C2` as its first group of comments, its second, then its value as
`encoder` writes it.
-}
c2Encoder : (a -> Bytes.Encode.Encoder) -> C2 a -> Bytes.Encode.Encoder
c2Encoder encoder ( ( preComments, postComments ), a ) =
    Bytes.Encode.sequence
        [ fCommentsEncoder preComments
        , fCommentsEncoder postComments
        , encoder a
        ]


{-| Produces a decoder for a `C2` as `c2Encoder` writes it, reading the value with
`decoder`.
-}
c2Decoder : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (C2 a)
c2Decoder decoder =
    Bytes.Decode.map3
        (\preComments postComments a ->
            ( ( preComments, postComments ), a )
        )
        fCommentsDecoder
        fCommentsDecoder
        decoder


{-| Encodes a `C2Eol` as its two groups of comments, its end-of-line comment, then
its value as `encoder` writes it.
-}
c2EolEncoder : (a -> Bytes.Encode.Encoder) -> C2Eol a -> Bytes.Encode.Encoder
c2EolEncoder encoder ( ( preComments, postComments, eol ), a ) =
    Bytes.Encode.sequence
        [ fCommentsEncoder preComments
        , fCommentsEncoder postComments
        , BE.maybe BE.string eol
        , encoder a
        ]


{-| Produces a decoder for a `C2Eol` as `c2EolEncoder` writes it, reading the
value with `decoder`.
-}
c2EolDecoder : Bytes.Decode.Decoder a -> Bytes.Decode.Decoder (C2Eol a)
c2EolDecoder decoder =
    Bytes.Decode.map4
        (\preComments postComments eol a ->
            ( ( preComments, postComments, eol ), a )
        )
        fCommentsDecoder
        fCommentsDecoder
        (BD.maybe BD.string)
        decoder


{-| Encodes a type and its region, for `typeDecoder` to read back.
-}
typeEncoder : Type -> Bytes.Encode.Encoder
typeEncoder =
    A.locatedEncoder internalTypeEncoder


{-| A decoder for a type that `typeEncoder` wrote.
-}
typeDecoder : Bytes.Decode.Decoder Type
typeDecoder =
    A.locatedDecoder internalTypeDecoder


{-| Encodes one type, without its region, as a tag byte followed by its parts.
-}
internalTypeEncoder : Type_ -> Bytes.Encode.Encoder
internalTypeEncoder type_ =
    case type_ of
        TLambda arg result ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , c0EolEncoder typeEncoder arg
                , c2EolEncoder typeEncoder result
                ]

        TVar name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string name
                ]

        TType region name args ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , A.regionEncoder region
                , BE.string name
                , BE.list (c1Encoder typeEncoder) args
                ]

        TTypeQual region home name args ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , A.regionEncoder region
                , BE.string home
                , BE.string name
                , BE.list (c1Encoder typeEncoder) args
                ]

        TRecord fields ext trailing ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , BE.list (c2Encoder (BE.jsonPair (c1Encoder (A.locatedEncoder BE.string)) (c1Encoder typeEncoder))) fields
                , BE.maybe (c2Encoder (A.locatedEncoder BE.string)) ext
                , fCommentsEncoder trailing
                ]

        TUnit ->
            Bytes.Encode.unsignedInt8 5

        TTuple a b cs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , c2EolEncoder typeEncoder a
                , c2EolEncoder typeEncoder b
                , BE.list (c2EolEncoder typeEncoder) cs
                ]

        TParens type__ ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , c2Encoder typeEncoder type__
                ]


{-| A decoder for one type as `internalTypeEncoder` writes it.
-}
internalTypeDecoder : Bytes.Decode.Decoder Type_
internalTypeDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 TLambda
                            (c0EolDecoder typeDecoder)
                            (c2EolDecoder typeDecoder)

                    1 ->
                        Bytes.Decode.map TVar BD.string

                    2 ->
                        Bytes.Decode.map3 TType
                            A.regionDecoder
                            BD.string
                            (BD.list (c1Decoder typeDecoder))

                    3 ->
                        Bytes.Decode.map4 TTypeQual
                            A.regionDecoder
                            BD.string
                            BD.string
                            (BD.list (c1Decoder typeDecoder))

                    4 ->
                        Bytes.Decode.map3 TRecord
                            (BD.list (c2Decoder (BD.jsonPair (c1Decoder (A.locatedDecoder BD.string)) (c1Decoder typeDecoder))))
                            (BD.maybe (c2Decoder (A.locatedDecoder BD.string)))
                            fCommentsDecoder

                    5 ->
                        Bytes.Decode.succeed TUnit

                    6 ->
                        Bytes.Decode.map3 TTuple
                            (c2EolDecoder typeDecoder)
                            (c2EolDecoder typeDecoder)
                            (BD.list (c2EolDecoder typeDecoder))

                    7 ->
                        Bytes.Decode.map TParens
                            (c2Decoder typeDecoder)

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a whole module, for `moduleDecoder` to read back.

Each doc comment is written with the whole text of the file it came from (see
`Comment`), so the encoding of a documented module holds that text once per doc
comment.

-}
moduleEncoder : Module -> Bytes.Encode.Encoder
moduleEncoder (Module data) =
    Bytes.Encode.sequence
        [ BE.maybe (A.locatedEncoder BE.string) data.name
        , A.locatedEncoder exposingEncoder data.exports
        , docsEncoder data.docs
        , BE.list importEncoder data.imports
        , BE.list (A.locatedEncoder valueEncoder) data.values
        , BE.list (A.locatedEncoder unionEncoder) data.unions
        , BE.list (A.locatedEncoder aliasEncoder) data.aliases
        , BE.list (A.locatedEncoder infixEncoder) data.infixes
        , effectsEncoder data.effects
        ]


{-| A decoder for a module that `moduleEncoder` wrote.
-}
moduleDecoder : Bytes.Decode.Decoder Module
moduleDecoder =
    BD.map8
        (\maybeName ( exports, docs ) imports values unions aliases infixes effects ->
            Module
                { name = maybeName
                , exports = exports
                , docs = docs
                , imports = imports
                , values = values
                , unions = unions
                , aliases = aliases
                , infixes = infixes
                , effects = effects
                }
        )
        (BD.maybe (A.locatedDecoder BD.string))
        (BD.jsonPair (A.locatedDecoder exposingDecoder) docsDecoder)
        (BD.list importDecoder)
        (BD.list (A.locatedDecoder valueDecoder))
        (BD.list (A.locatedDecoder unionDecoder))
        (BD.list (A.locatedDecoder aliasDecoder))
        (BD.list (A.locatedDecoder infixDecoder))
        effectsDecoder


{-| Encodes an `exposing` list as a tag byte followed by its parts.
-}
exposingEncoder : Exposing -> Bytes.Encode.Encoder
exposingEncoder exposing_ =
    case exposing_ of
        Open preComments postComments ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , fCommentsEncoder preComments
                , fCommentsEncoder postComments
                ]

        Explicit exposedList ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.locatedEncoder (BE.list (c2Encoder exposedEncoder)) exposedList
                ]


{-| A decoder for an `exposing` list as `exposingEncoder` writes it.
-}
exposingDecoder : Bytes.Decode.Decoder Exposing
exposingDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 Open
                            fCommentsDecoder
                            fCommentsDecoder

                    1 ->
                        Bytes.Decode.map Explicit (A.locatedDecoder (BD.list (c2Decoder exposedDecoder)))

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a module's doc comments as a tag byte followed by its parts.
-}
docsEncoder : Docs -> Bytes.Encode.Encoder
docsEncoder docs =
    case docs of
        NoDocs region comments ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.regionEncoder region
                , BE.list (BE.jsonPair BE.string commentEncoder) comments
                ]

        YesDocs overview comments ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , commentEncoder overview
                , BE.list (BE.jsonPair BE.string commentEncoder) comments
                ]


{-| A decoder for a module's doc comments as `docsEncoder` writes them.
-}
docsDecoder : Bytes.Decode.Decoder Docs
docsDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map2 NoDocs
                            A.regionDecoder
                            (BD.list (BD.jsonPair BD.string commentDecoder))

                    1 ->
                        Bytes.Decode.map2 YesDocs
                            commentDecoder
                            (BD.list (BD.jsonPair BD.string commentDecoder))

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes an import as its parts in order, with no tag.
-}
importEncoder : Import -> Bytes.Encode.Encoder
importEncoder (Import importName maybeAlias exposing_) =
    Bytes.Encode.sequence
        [ c1Encoder (A.locatedEncoder BE.string) importName
        , BE.maybe (c2Encoder BE.string) maybeAlias
        , c2Encoder exposingEncoder exposing_
        ]


{-| A decoder for an import as `importEncoder` writes it.
-}
importDecoder : Bytes.Decode.Decoder Import
importDecoder =
    Bytes.Decode.map3 Import
        (c1Decoder (A.locatedDecoder BD.string))
        (BD.maybe (c2Decoder BD.string))
        (c2Decoder exposingDecoder)


{-| Encodes a top-level definition as its fields in order, with no tag.
-}
valueEncoder : Value -> Bytes.Encode.Encoder
valueEncoder (Value v) =
    Bytes.Encode.sequence
        [ fCommentsEncoder v.comments
        , c1Encoder (A.locatedEncoder BE.string) v.name
        , BE.list (c1Encoder patternEncoder) v.args
        , c1Encoder exprEncoder v.body
        , BE.maybe (c1Encoder (c2Encoder typeEncoder)) v.tipe
        ]


{-| A decoder for a top-level definition as `valueEncoder` writes it.
-}
valueDecoder : Bytes.Decode.Decoder Value
valueDecoder =
    Bytes.Decode.map5 (\comments_ name_ args_ body_ tipe_ -> Value { comments = comments_, name = name_, args = args_, body = body_, tipe = tipe_ })
        fCommentsDecoder
        (c1Decoder (A.locatedDecoder BD.string))
        (BD.list (c1Decoder patternDecoder))
        (c1Decoder exprDecoder)
        (BD.maybe (c1Decoder (c2Decoder typeDecoder)))


{-| Encodes a custom type declaration as its parts in order, with no tag.
-}
unionEncoder : Union -> Bytes.Encode.Encoder
unionEncoder (Union name args constructors) =
    Bytes.Encode.sequence
        [ c2Encoder (A.locatedEncoder BE.string) name
        , BE.list (c1Encoder (A.locatedEncoder BE.string)) args
        , BE.list (c2EolEncoder (BE.jsonPair (A.locatedEncoder BE.string) (BE.list (c1Encoder typeEncoder)))) constructors
        ]


{-| A decoder for a custom type declaration as `unionEncoder` writes it.
-}
unionDecoder : Bytes.Decode.Decoder Union
unionDecoder =
    Bytes.Decode.map3 Union
        (c2Decoder (A.locatedDecoder BD.string))
        (BD.list (c1Decoder (A.locatedDecoder BD.string)))
        (BD.list (c2EolDecoder (BD.jsonPair (A.locatedDecoder BD.string) (BD.list (c1Decoder typeDecoder)))))


{-| Encodes a type alias declaration as its fields in order, with no tag.
-}
aliasEncoder : Alias -> Bytes.Encode.Encoder
aliasEncoder (Alias data) =
    Bytes.Encode.sequence
        [ fCommentsEncoder data.comments
        , c2Encoder (A.locatedEncoder BE.string) data.name
        , BE.list (c1Encoder (A.locatedEncoder BE.string)) data.args
        , c1Encoder typeEncoder data.tipe
        ]


{-| A decoder for a type alias declaration as `aliasEncoder` writes it.
-}
aliasDecoder : Bytes.Decode.Decoder Alias
aliasDecoder =
    Bytes.Decode.map4
        (\comments name args tipe ->
            Alias { comments = comments, name = name, args = args, tipe = tipe }
        )
        fCommentsDecoder
        (c2Decoder (A.locatedDecoder BD.string))
        (BD.list (c1Decoder (A.locatedDecoder BD.string)))
        (c1Decoder typeDecoder)


{-| Encodes an infix declaration as its fields in order, with no tag.
-}
infixEncoder : Infix -> Bytes.Encode.Encoder
infixEncoder (Infix data) =
    Bytes.Encode.sequence
        [ c2Encoder BE.string data.op
        , c1Encoder Binop.associativityEncoder data.associativity
        , c1Encoder Binop.precedenceEncoder data.precedence
        , c1Encoder BE.string data.name
        ]


{-| A decoder for an infix declaration as `infixEncoder` writes it.
-}
infixDecoder : Bytes.Decode.Decoder Infix
infixDecoder =
    Bytes.Decode.map4
        (\op associativity precedence name ->
            Infix { op = op, associativity = associativity, precedence = precedence, name = name }
        )
        (c2Decoder BD.string)
        (c1Decoder Binop.associativityDecoder)
        (c1Decoder Binop.precedenceDecoder)
        (c1Decoder BD.string)


{-| Encodes a module's effects as a tag byte followed by its parts.
-}
effectsEncoder : Effects -> Bytes.Encode.Encoder
effectsEncoder effects =
    case effects of
        NoEffects ->
            Bytes.Encode.unsignedInt8 0

        Ports ports ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.list portEncoder ports
                ]

        Manager region manager ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , A.regionEncoder region
                , managerEncoder manager
                ]


{-| A decoder for a module's effects as `effectsEncoder` writes them.
-}
effectsDecoder : Bytes.Decode.Decoder Effects
effectsDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed NoEffects

                    1 ->
                        Bytes.Decode.map Ports (BD.list portDecoder)

                    2 ->
                        Bytes.Decode.map2 Manager
                            A.regionDecoder
                            managerDecoder

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a doc comment as its `Snippet`, which includes the whole text of the
file.
-}
commentEncoder : Comment -> Bytes.Encode.Encoder
commentEncoder (Comment snippet) =
    Snippet.encoder snippet


{-| A decoder for a doc comment as `commentEncoder` writes it.
-}
commentDecoder : Bytes.Decode.Decoder Comment
commentDecoder =
    Bytes.Decode.map Comment Snippet.decoder


{-| Encodes a port declaration as its parts in order, with no tag.
-}
portEncoder : Port -> Bytes.Encode.Encoder
portEncoder (Port typeComments name tipe) =
    Bytes.Encode.sequence
        [ fCommentsEncoder typeComments
        , c2Encoder (A.locatedEncoder BE.string) name
        , typeEncoder tipe
        ]


{-| A decoder for a port declaration as `portEncoder` writes it.
-}
portDecoder : Bytes.Decode.Decoder Port
portDecoder =
    Bytes.Decode.map3 Port
        fCommentsDecoder
        (c2Decoder (A.locatedDecoder BD.string))
        typeDecoder


{-| Encodes what an effect module manages as a tag byte followed by its parts.
-}
managerEncoder : Manager -> Bytes.Encode.Encoder
managerEncoder manager =
    case manager of
        Cmd cmdType ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , c2Encoder (c2Encoder (A.locatedEncoder BE.string)) cmdType
                ]

        Sub subType ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , c2Encoder (c2Encoder (A.locatedEncoder BE.string)) subType
                ]

        Fx cmdType subType ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , c2Encoder (c2Encoder (A.locatedEncoder BE.string)) cmdType
                , c2Encoder (c2Encoder (A.locatedEncoder BE.string)) subType
                ]


{-| A decoder for what an effect module manages, as `managerEncoder` writes it.
-}
managerDecoder : Bytes.Decode.Decoder Manager
managerDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Cmd (c2Decoder (c2Decoder (A.locatedDecoder BD.string)))

                    1 ->
                        Bytes.Decode.map Sub (c2Decoder (c2Decoder (A.locatedDecoder BD.string)))

                    2 ->
                        Bytes.Decode.map2 Fx
                            (c2Decoder (c2Decoder (A.locatedDecoder BD.string)))
                            (c2Decoder (c2Decoder (A.locatedDecoder BD.string)))

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes one item of an `exposing` list as a tag byte followed by its parts.
-}
exposedEncoder : Exposed -> Bytes.Encode.Encoder
exposedEncoder exposed =
    case exposed of
        Lower name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.locatedEncoder BE.string name
                ]

        Upper name dotDotRegion ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , A.locatedEncoder BE.string name
                , c1Encoder privacyEncoder dotDotRegion
                ]

        Operator region name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , A.regionEncoder region
                , BE.string name
                ]


{-| A decoder for one item of an `exposing` list as `exposedEncoder` writes it.
-}
exposedDecoder : Bytes.Decode.Decoder Exposed
exposedDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Lower (A.locatedDecoder BD.string)

                    1 ->
                        Bytes.Decode.map2 Upper
                            (A.locatedDecoder BD.string)
                            (c1Decoder privacyDecoder)

                    2 ->
                        Bytes.Decode.map2 Operator
                            A.regionDecoder
                            BD.string

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a type's privacy as a tag byte, followed by the region of the `..` for
`Public`.
-}
privacyEncoder : Privacy -> Bytes.Encode.Encoder
privacyEncoder privacy =
    case privacy of
        Public region ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.regionEncoder region
                ]

        Private ->
            Bytes.Encode.unsignedInt8 1


{-| A decoder for a type's privacy as `privacyEncoder` writes it.
-}
privacyDecoder : Bytes.Decode.Decoder Privacy
privacyDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Public A.regionDecoder

                    1 ->
                        Bytes.Decode.succeed Private

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a pattern and its region.
-}
patternEncoder : Pattern -> Bytes.Encode.Encoder
patternEncoder =
    A.locatedEncoder pattern_Encoder


{-| A decoder for a pattern as `patternEncoder` writes it.
-}
patternDecoder : Bytes.Decode.Decoder Pattern
patternDecoder =
    A.locatedDecoder pattern_Decoder


{-| Encodes one pattern, without its region, as a tag byte followed by its parts.
-}
pattern_Encoder : Pattern_ -> Bytes.Encode.Encoder
pattern_Encoder pattern_ =
    case pattern_ of
        PAnything name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.string name
                ]

        PVar name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string name
                ]

        PRecord fields ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , c1Encoder (BE.list (c2Encoder (A.locatedEncoder BE.string))) fields
                ]

        PAlias aliasPattern name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , c1Encoder patternEncoder aliasPattern
                , c1Encoder (A.locatedEncoder BE.string) name
                ]

        PUnit comments ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , fCommentsEncoder comments
                ]

        PTuple a b cs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , c2Encoder patternEncoder a
                , c2Encoder patternEncoder b
                , BE.list (c2Encoder patternEncoder) cs
                ]

        PCtor nameRegion name patterns ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , A.regionEncoder nameRegion
                , BE.string name
                , BE.list (c1Encoder patternEncoder) patterns
                ]

        PCtorQual nameRegion home name patterns ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , A.regionEncoder nameRegion
                , BE.string home
                , BE.string name
                , BE.list (c1Encoder patternEncoder) patterns
                ]

        PList patterns ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , c1Encoder (BE.list (c2Encoder patternEncoder)) patterns
                ]

        PCons hd tl ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 9
                , c0EolEncoder patternEncoder hd
                , c2EolEncoder patternEncoder tl
                ]

        PChr chr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , BE.string chr
                ]

        PStr str multiline ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , BE.string str
                , BE.bool multiline
                ]

        PInt int src ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 12
                , BE.int int
                , BE.string src
                ]

        PParens pattern ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 13
                , c2Encoder patternEncoder pattern
                ]


{-| A decoder for one pattern as `pattern_Encoder` writes it.
-}
pattern_Decoder : Bytes.Decode.Decoder Pattern_
pattern_Decoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map PAnything BD.string

                    1 ->
                        Bytes.Decode.map PVar BD.string

                    2 ->
                        Bytes.Decode.map PRecord (c1Decoder (BD.list (c2Decoder (A.locatedDecoder BD.string))))

                    3 ->
                        Bytes.Decode.map2 PAlias
                            (c1Decoder patternDecoder)
                            (c1Decoder (A.locatedDecoder BD.string))

                    4 ->
                        Bytes.Decode.map PUnit fCommentsDecoder

                    5 ->
                        Bytes.Decode.map3 PTuple
                            (c2Decoder patternDecoder)
                            (c2Decoder patternDecoder)
                            (BD.list (c2Decoder patternDecoder))

                    6 ->
                        Bytes.Decode.map3 PCtor
                            A.regionDecoder
                            BD.string
                            (BD.list (c1Decoder patternDecoder))

                    7 ->
                        Bytes.Decode.map4 PCtorQual
                            A.regionDecoder
                            BD.string
                            BD.string
                            (BD.list (c1Decoder patternDecoder))

                    8 ->
                        Bytes.Decode.map PList (c1Decoder (BD.list (c2Decoder patternDecoder)))

                    9 ->
                        Bytes.Decode.map2 PCons
                            (c0EolDecoder patternDecoder)
                            (c2EolDecoder patternDecoder)

                    10 ->
                        Bytes.Decode.map PChr BD.string

                    11 ->
                        Bytes.Decode.map2 PStr
                            BD.string
                            BD.bool

                    12 ->
                        Bytes.Decode.map2 PInt
                            BD.int
                            BD.string

                    13 ->
                        Bytes.Decode.map PParens (c2Decoder patternDecoder)

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes an expression and its region.
-}
exprEncoder : Expr -> Bytes.Encode.Encoder
exprEncoder =
    A.locatedEncoder expr_Encoder


{-| A decoder for an expression as `exprEncoder` writes it.
-}
exprDecoder : Bytes.Decode.Decoder Expr
exprDecoder =
    A.locatedDecoder expr_Decoder


{-| Encodes one expression, without its region, as a tag byte followed by its
parts.
-}
expr_Encoder : Expr_ -> Bytes.Encode.Encoder
expr_Encoder expr_ =
    case expr_ of
        Chr char ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , BE.string char
                ]

        Str string multiline ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , BE.string string
                , BE.bool multiline
                ]

        Int int src ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 2
                , BE.int int
                , BE.string src
                ]

        Float float src ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 3
                , BE.float float
                , BE.string src
                ]

        Var varType name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 4
                , varTypeEncoder varType
                , BE.string name
                ]

        VarQual varType prefix name ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 5
                , varTypeEncoder varType
                , BE.string prefix
                , BE.string name
                ]

        List list trailing ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 6
                , BE.list (c2EolEncoder exprEncoder) list
                , fCommentsEncoder trailing
                ]

        Op op ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 7
                , BE.string op
                ]

        Negate expr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 8
                , exprEncoder expr
                ]

        Binops ops final ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 9
                , BE.list (BE.jsonPair exprEncoder (c2Encoder (A.locatedEncoder BE.string))) ops
                , exprEncoder final
                ]

        Lambda srcArgs body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 10
                , c1Encoder (BE.list (c1Encoder patternEncoder)) srcArgs
                , c1Encoder exprEncoder body
                ]

        Call func args ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 11
                , exprEncoder func
                , BE.list (c1Encoder exprEncoder) args
                ]

        If firstBranch branches finally ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 12
                , c1Encoder (BE.jsonPair (c2Encoder exprEncoder) (c2Encoder exprEncoder)) firstBranch
                , BE.list (c1Encoder (BE.jsonPair (c2Encoder exprEncoder) (c2Encoder exprEncoder))) branches
                , c1Encoder exprEncoder finally
                ]

        Let defs comments expr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 13
                , BE.list (c2Encoder (A.locatedEncoder defEncoder)) defs
                , fCommentsEncoder comments
                , exprEncoder expr
                ]

        Case expr branches ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 14
                , c2Encoder exprEncoder expr
                , BE.list (BE.jsonPair (c2Encoder patternEncoder) (c1Encoder exprEncoder)) branches
                ]

        Accessor field ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 15
                , BE.string field
                ]

        Access record field ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 16
                , exprEncoder record
                , A.locatedEncoder BE.string field
                ]

        Update name fields ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 17
                , c2Encoder exprEncoder name
                , c1Encoder (BE.list (c2EolEncoder (BE.jsonPair (c1Encoder (A.locatedEncoder BE.string)) (c1Encoder exprEncoder)))) fields
                ]

        Record fields ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 18
                , c1Encoder (BE.list (c2EolEncoder (BE.jsonPair (c1Encoder (A.locatedEncoder BE.string)) (c1Encoder exprEncoder)))) fields
                ]

        Unit ->
            Bytes.Encode.unsignedInt8 19

        Tuple a b cs ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 20
                , c2Encoder exprEncoder a
                , c2Encoder exprEncoder b
                , BE.list (c2Encoder exprEncoder) cs
                ]

        Shader src tipe ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 21
                , Shader.sourceEncoder src
                , Shader.typesEncoder tipe
                ]

        Parens expr ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 22
                , c2Encoder exprEncoder expr
                ]


{-| A decoder for one expression as `expr_Encoder` writes it.
-}
expr_Decoder : Bytes.Decode.Decoder Expr_
expr_Decoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map Chr BD.string

                    1 ->
                        Bytes.Decode.map2 Str
                            BD.string
                            BD.bool

                    2 ->
                        Bytes.Decode.map2 Int
                            BD.int
                            BD.string

                    3 ->
                        Bytes.Decode.map2 Float
                            BD.float
                            BD.string

                    4 ->
                        Bytes.Decode.map2 Var
                            varTypeDecoder
                            BD.string

                    5 ->
                        Bytes.Decode.map3 VarQual
                            varTypeDecoder
                            BD.string
                            BD.string

                    6 ->
                        Bytes.Decode.map2 List
                            (BD.list (c2EolDecoder exprDecoder))
                            fCommentsDecoder

                    7 ->
                        Bytes.Decode.map Op BD.string

                    8 ->
                        Bytes.Decode.map Negate exprDecoder

                    9 ->
                        Bytes.Decode.map2 Binops
                            (BD.list (BD.jsonPair exprDecoder (c2Decoder (A.locatedDecoder BD.string))))
                            exprDecoder

                    10 ->
                        Bytes.Decode.map2 Lambda
                            (c1Decoder (BD.list (c1Decoder patternDecoder)))
                            (c1Decoder exprDecoder)

                    11 ->
                        Bytes.Decode.map2 Call
                            exprDecoder
                            (BD.list (c1Decoder exprDecoder))

                    12 ->
                        Bytes.Decode.map3 If
                            (c1Decoder (BD.jsonPair (c2Decoder exprDecoder) (c2Decoder exprDecoder)))
                            (BD.list (c1Decoder (BD.jsonPair (c2Decoder exprDecoder) (c2Decoder exprDecoder))))
                            (c1Decoder exprDecoder)

                    13 ->
                        Bytes.Decode.map3 Let
                            (BD.list (c2Decoder (A.locatedDecoder defDecoder)))
                            fCommentsDecoder
                            exprDecoder

                    14 ->
                        Bytes.Decode.map2 Case
                            (c2Decoder exprDecoder)
                            (BD.list (BD.jsonPair (c2Decoder patternDecoder) (c1Decoder exprDecoder)))

                    15 ->
                        Bytes.Decode.map Accessor BD.string

                    16 ->
                        Bytes.Decode.map2 Access
                            exprDecoder
                            (A.locatedDecoder BD.string)

                    17 ->
                        Bytes.Decode.map2 Update
                            (c2Decoder exprDecoder)
                            (c1Decoder (BD.list (c2EolDecoder (BD.jsonPair (c1Decoder (A.locatedDecoder BD.string)) (c1Decoder exprDecoder)))))

                    18 ->
                        Bytes.Decode.map Record
                            (c1Decoder (BD.list (c2EolDecoder (BD.jsonPair (c1Decoder (A.locatedDecoder BD.string)) (c1Decoder exprDecoder)))))

                    19 ->
                        Bytes.Decode.succeed Unit

                    20 ->
                        Bytes.Decode.map3 Tuple
                            (c2Decoder exprDecoder)
                            (c2Decoder exprDecoder)
                            (BD.list (c2Decoder exprDecoder))

                    21 ->
                        Bytes.Decode.map2 Shader
                            Shader.sourceDecoder
                            Shader.typesDecoder

                    22 ->
                        Bytes.Decode.map Parens (c2Decoder exprDecoder)

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a `VarType` as a single tag byte.
-}
varTypeEncoder : VarType -> Bytes.Encode.Encoder
varTypeEncoder varType =
    Bytes.Encode.unsignedInt8
        (case varType of
            LowVar ->
                0

            CapVar ->
                1
        )


{-| A decoder for a `VarType` as `varTypeEncoder` writes it.
-}
varTypeDecoder : Bytes.Decode.Decoder VarType
varTypeDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.succeed LowVar

                    1 ->
                        Bytes.Decode.succeed CapVar

                    _ ->
                        Bytes.Decode.fail
            )


{-| Encodes a `let` definition as a tag byte followed by its parts.
-}
defEncoder : Def -> Bytes.Encode.Encoder
defEncoder def =
    case def of
        Define name srcArgs body maybeType ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 0
                , A.locatedEncoder BE.string name
                , BE.list (c1Encoder patternEncoder) srcArgs
                , c1Encoder exprEncoder body
                , BE.maybe (c1Encoder (c2Encoder typeEncoder)) maybeType
                ]

        Destruct pattern body ->
            Bytes.Encode.sequence
                [ Bytes.Encode.unsignedInt8 1
                , patternEncoder pattern
                , c1Encoder exprEncoder body
                ]


{-| A decoder for a `let` definition as `defEncoder` writes it.
-}
defDecoder : Bytes.Decode.Decoder Def
defDecoder =
    Bytes.Decode.unsignedInt8
        |> Bytes.Decode.andThen
            (\idx ->
                case idx of
                    0 ->
                        Bytes.Decode.map4 Define
                            (A.locatedDecoder BD.string)
                            (BD.list (c1Decoder patternDecoder))
                            (c1Decoder exprDecoder)
                            (BD.maybe (c1Decoder (c2Decoder typeDecoder)))

                    1 ->
                        Bytes.Decode.map2 Destruct
                            patternDecoder
                            (c1Decoder exprDecoder)

                    _ ->
                        Bytes.Decode.fail
            )
