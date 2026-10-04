module Compiler.Reporting.Render.Type exposing
    ( Context(..)
    , srcToDoc
    , canToDoc
    , lambda, apply, tuple, record, vrecord, vrecordSnippet
    )

{-| A type shown to a programmer, in an error message for instance, should read
as the type would be written in Elm, with parentheses where Elm needs them. This
module holds that layout.

Whether a type needs parentheses depends on where it sits. A function type needs
them as an argument of a type, as in `Maybe (a -> b)`, and as a part of another
function type, as in `(a -> b) -> c`. A type applied to arguments, such as
`Maybe a`, needs them only as an argument of another type, as in
`List (Maybe a)`. Variables, unit, tuples and records never need them. A
`Context` names the position a type is printed in.

`lambda`, `apply`, `tuple`, `record`, `vrecord` and `vrecordSnippet` build each
form of type from documents already printed for its parts, so that a printer for
any representation of types can share the layout. `srcToDoc` prints a type as
parsed from source, and `canToDoc` prints a canonical type, writing each type's
name as a `Localizer` gives it.


# Rendering Context

@docs Context


# Source Type Rendering

@docs srcToDoc


# Canonical Type Rendering

@docs canToDoc


# Type Constructors

@docs lambda, apply, tuple, record, vrecord, vrecordSnippet

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Render.Type.Localizer as L
import List.Extra as List



-- ====== TO DOC ======


{-| The position a type is printed in, which decides whether it needs
parentheses.

`None` is a position where no type needs them: the whole type, a tuple element,
or the type of a record field.

`Func` is a part of a function type, one of its arguments or its final result. A
function type is parenthesised there.

`App` is an argument of a type applied to arguments. A function type, and a type
applied to arguments, are parenthesised there.

-}
type Context
    = None
    | Func
    | App


{-| Returns the function type `arg1 -> arg2 -> ...`, whose last part is its
final result, from documents already printed for its parts. It is parenthesised
unless `context` is `None`.

The parts are on one line if they fit. Otherwise each is on a line of its own,
every line after the first starting with `->`. The parentheses, if any, go on
lines of their own whenever the whole does not fit on the line, even when the
parts then fit on one line. The parts are used as they are given; printing them
in the `Func` context is for the caller to do.

-}
lambda : Context -> D.Doc -> D.Doc -> List D.Doc -> D.Doc
lambda context arg1 arg2 args =
    let
        lambdaDoc : D.Doc
        lambdaDoc =
            D.sep (arg1 :: List.map (\a -> D.plus a (D.fromChars "->")) (arg2 :: args)) |> D.align
    in
    case context of
        None ->
            lambdaDoc

        Func ->
            D.cat [ D.fromChars "(", lambdaDoc, D.fromChars ")" ]

        App ->
            D.cat [ D.fromChars "(", lambdaDoc, D.fromChars ")" ]


{-| Returns the type `name` applied to `args`. With no arguments it is `name`
alone, in any context. Otherwise it is parenthesised in the `App` context, and
the arguments follow the name on one line if they fit, or each on a line of its
own, indented four columns past where the name begins. The parentheses, if any,
go on lines of their own whenever the whole does not fit on the line, even when
the name and arguments then fit on one line.
-}
apply : Context -> D.Doc -> List D.Doc -> D.Doc
apply context name args =
    case args of
        [] ->
            name

        _ ->
            let
                applyDoc : D.Doc
                applyDoc =
                    D.sep (name :: args) |> D.hang 4
            in
            case context of
                App ->
                    D.cat [ D.fromChars "(", applyDoc, D.fromChars ")" ]

                Func ->
                    applyDoc

                None ->
                    applyDoc


{-| Returns the tuple type `( a, b, ... )` from documents already printed for
its elements. It is never parenthesised.

When the tuple does not fit on the line, the closing parenthesis goes on a line
of its own. If the rest still does not fit, the opening parenthesis, each
element and each comma between elements are each put on a line of their own too.

-}
tuple : D.Doc -> D.Doc -> List D.Doc -> D.Doc
tuple a b cs =
    let
        entries : List D.Doc
        entries =
            List.interweave (D.fromChars "( " :: List.repeat (List.length (b :: cs)) (D.fromChars ", ")) (a :: b :: cs)
    in
    D.sep [ D.cat entries, D.fromChars ")" ] |> D.align


{-| Returns a record type from documents already printed for each field's name
and type, extending `maybeExt` when it is given. With no fields and no extension
it is `{}`.

On one line, a closed record reads `{ x : Int, y : Int }`, and an extensible
one `{  r |x : Int, y : Int }`, with two spaces after the brace and none after
the bar. When the record does not fit on the line, the closing brace goes on a
line of its own, and the fields and their separators stay together on one line
while they fit; in an extensible record that line may be a line of their own
after `{  r`, indented four columns. When they do not fit, each field and each
separator is put on a line of its own, indented four columns in an extensible
record.

-}
record : List ( D.Doc, D.Doc ) -> Maybe D.Doc -> D.Doc
record entries maybeExt =
    case ( List.map entryToDoc entries, maybeExt ) of
        ( [], Nothing ) ->
            D.fromChars "{}"

        ( fields, Nothing ) ->
            D.align <|
                D.sep
                    [ D.cat
                        (List.interweave (D.fromChars "{ " :: List.repeat (List.length fields - 1) (D.fromChars ", ")) fields)
                    , D.fromChars "}"
                    ]

        ( fields, Just ext ) ->
            D.align <|
                D.sep
                    [ D.hang 4 <|
                        D.sep
                            [ D.fromChars "{ " |> D.plus ext
                            , D.cat
                                (List.interweave (D.fromChars "|" :: List.repeat (List.length fields - 1) (D.fromChars ", ")) fields)
                            ]
                    , D.fromChars "}"
                    ]


{-| Returns one record field as `name : type`, with the type on the next line,
indented four columns past where the name begins, when the two do not fit on one
line.
-}
entryToDoc : ( D.Doc, D.Doc ) -> D.Doc
entryToDoc ( fieldName, fieldType ) =
    D.sep [ fieldName |> D.plus (D.fromChars ":"), fieldType ] |> D.hang 4


{-| Returns a record type showing only some of its fields: `entry` on the line
of the opening brace, then each of `entries`, then `...` for the fields not
shown, and the closing brace, each on a line of its own.

Between each two of the lines for `entries` and `...` come three more lines: a
single space, a comma, and a single space. No comma comes between `entry` and
the first of `entries`.

-}
vrecordSnippet : ( D.Doc, D.Doc ) -> List ( D.Doc, D.Doc ) -> D.Doc
vrecordSnippet entry entries =
    let
        field : D.Doc
        field =
            D.fromChars "{" |> D.plus (entryToDoc entry)

        fields : List D.Doc
        fields =
            List.intersperse (D.fromChars ",") (List.map entryToDoc entries ++ [ D.fromChars "..." ])
                |> List.intersperse (D.fromChars " ")
    in
    D.vcat (field :: fields ++ [ D.fromChars "}" ])


{-| Returns a record type laid out over several lines, from documents already
printed for each field's name and type, extending `maybeExt` when it is given.
With no fields and no extension it is `{}`.

Without an extension, the opening brace, each field, each comma and a single
space between each of these are each put on a line of their own, followed by the
closing brace. With an extension `r`, the first line is `r {`, and the next,
indented four columns, is `| x : Int , y : Int` when the fields fit on it.

-}
vrecord : List ( D.Doc, D.Doc ) -> Maybe D.Doc -> D.Doc
vrecord entries maybeExt =
    case ( List.map entryToDoc entries, maybeExt ) of
        ( [], Nothing ) ->
            D.fromChars "{}"

        ( fields, Nothing ) ->
            D.vcat <|
                (List.interweave (D.fromChars "{" :: List.repeat (List.length fields - 1) (D.fromChars ",")) fields
                    |> List.intersperse (D.fromChars " ")
                )
                    ++ [ D.fromChars "}" ]

        ( fields, Just ext ) ->
            D.vcat
                [ D.hang 4 <|
                    D.vcat
                        [ D.plus (D.fromChars "{") ext
                        , D.cat
                            (List.interweave (D.fromChars "|" :: List.repeat (List.length fields - 1) (D.fromChars ",")) fields
                                |> List.intersperse (D.fromChars " ")
                            )
                        ]
                , D.fromChars "}"
                ]



-- ====== SOURCE TYPE TO DOC ======


{-| Returns a type as parsed from source, printed in `context`.

Names are printed as written, a qualified one with the module prefix the source
used, and a record's fields in source order. Comments within the type are not
printed.

Parentheses written in the source are not kept: each part is parenthesised as
its context needs. The exception is a function type written in parentheses, with
a comment directly after the `(` or before the `)`, as the result of another
function type. It is not joined to the chain of arrows, so
`a -> ({- c -} b -> c)` is printed as `a -> (b -> c)`.

-}
srcToDoc : Context -> Src.Type -> D.Doc
srcToDoc context (A.At _ tipe) =
    case tipe of
        Src.TLambda ( _, arg1 ) ( _, result ) ->
            let
                ( arg2, rest ) =
                    collectSrcArgs result
            in
            lambda context (srcToDoc Func arg1) (srcToDoc Func arg2) (List.map (srcToDoc Func) rest)

        Src.TVar name ->
            D.fromName name

        Src.TType _ name args ->
            apply context (D.fromName name) (List.map (Src.c1Value >> srcToDoc App) args)

        Src.TTypeQual _ home name args ->
            apply context (D.fromName home |> D.a (D.fromChars ".") |> D.a (D.fromName name)) (List.map (Src.c1Value >> srcToDoc App) args)

        Src.TRecord fields maybeExt _ ->
            record (List.map srcFieldToDocs fields) (Maybe.map (\( _, A.At _ ext ) -> D.fromName ext) maybeExt)

        Src.TUnit ->
            D.fromChars "()"

        Src.TTuple ( _, a ) ( _, b ) cs ->
            tuple (srcToDoc None a) (srcToDoc None b) (List.map (srcToDoc None) (List.map Src.c2EolValue cs))

        Src.TParens ( _, tipe_ ) ->
            srcToDoc context tipe_


{-| Returns one field of a source record type as its name and its type printed
in the `None` context.
-}
srcFieldToDocs : Src.C2 ( Src.C1 (A.Located Name.Name), Src.C1 Src.Type ) -> ( D.Doc, D.Doc )
srcFieldToDocs ( _, ( ( _, A.At _ fieldName ), ( _, fieldType ) ) ) =
    ( D.fromName fieldName, srcToDoc None fieldType )


{-| Returns the parts of a function type's result: when `tipe` is itself a
function type, its argument followed by the parts of its own result, and
otherwise `tipe` alone. The last part is the final result. A function type
inside a `Src.TParens` is not looked into.
-}
collectSrcArgs : Src.Type -> ( Src.Type, List Src.Type )
collectSrcArgs tipe =
    case tipe of
        A.At _ (Src.TLambda ( _, a ) ( _, result )) ->
            let
                ( b, cs ) =
                    collectSrcArgs result
            in
            ( a, b :: cs )

        _ ->
            ( tipe, [] )



-- ====== CANONICAL TYPE TO DOC ======


{-| Returns a canonical type printed in `context`, with the name of each named
type written as `localizer` gives it, which
`Compiler.Reporting.Render.Type.Localizer.toChars` describes. Type variables are
printed by their names.

A use of a type alias is printed as the alias applied to its arguments, never as
the type it stands for. A record's fields come in the order `Can.fieldsToList`
gives.

-}
canToDoc : L.Localizer -> Context -> Can.Type Name -> D.Doc
canToDoc localizer context tipe =
    case tipe of
        Can.TLambda _ arg1 result ->
            let
                ( arg2, rest ) =
                    collectArgs result
            in
            lambda context (canToDoc localizer Func arg1) (canToDoc localizer Func arg2) (List.map (canToDoc localizer Func) rest)

        Can.TVar name ->
            D.fromName name

        Can.TType home name args ->
            apply context (L.toDoc localizer home name) (List.map (canToDoc localizer App) args)

        Can.TRecord fields ext ->
            record (List.map (canFieldToDoc localizer) (Can.fieldsToList fields)) (Maybe.map D.fromName ext)

        Can.TUnit ->
            D.fromChars "()"

        Can.TTuple a b cs ->
            tuple (canToDoc localizer None a) (canToDoc localizer None b) (List.map (canToDoc localizer None) cs)

        Can.TAlias home name args _ ->
            apply context (L.toDoc localizer home name) (List.map (canToDoc localizer App << Tuple.second) args)


{-| Returns one field of a canonical record type as its name and its type
printed in the `None` context.
-}
canFieldToDoc : L.Localizer -> ( Name.Name, Can.Type Name ) -> ( D.Doc, D.Doc )
canFieldToDoc localizer ( name, tipe ) =
    ( D.fromName name, canToDoc localizer None tipe )


{-| Returns the parts of a function type's result: when `tipe` is itself a
function type, its argument followed by the parts of its own result, and
otherwise `tipe` alone. The last part is the final result. An alias of a
function type is not looked into.
-}
collectArgs : Can.Type Name -> ( Can.Type Name, List (Can.Type Name) )
collectArgs tipe =
    case tipe of
        Can.TLambda _ a rest ->
            let
                ( b, cs ) =
                    collectArgs rest
            in
            ( a, b :: cs )

        _ ->
            ( tipe, [] )
