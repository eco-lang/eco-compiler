module Compiler.Reporting.Render.Type exposing
    ( Context(..)
    , srcToDoc
    , canToDoc
    , lambda, apply, tuple, record, vrecord, vrecordSnippet
    )

{-| Rendering type expressions as human-readable documentation.

This module converts both source and canonical type representations into
formatted Doc values for display in error messages and documentation,
with proper parenthesization and layout.


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
import Compiler.Data.Name as Name
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Doc as D
import Compiler.Reporting.Render.Type.Localizer as L
import List.Extra as List



-- TO DOC


{-| Parenthesization context for type rendering. Determines whether parentheses
are needed around a type expression based on where it appears.
-}
type Context
    = None
    | Func
    | App


{-| Renders a function type with proper formatting and context-aware parenthesization.
Takes the first two arguments and any additional arguments, formatting them as
`arg1 -> arg2 -> ... -> result`.
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


{-| Renders a type application (type constructor applied to arguments) with
proper formatting and context-aware parenthesization.
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


{-| Renders a tuple type with proper formatting. Takes at least two elements
(tuples in Elm have 2 or more elements) and formats them as `( a, b, ... )`.
-}
tuple : D.Doc -> D.Doc -> List D.Doc -> D.Doc
tuple a b cs =
    let
        entries : List D.Doc
        entries =
            List.interweave (D.fromChars "( " :: List.repeat (List.length (b :: cs)) (D.fromChars ", ")) (a :: b :: cs)
    in
    D.sep [ D.cat entries, D.fromChars ")" ] |> D.align


{-| Renders a record type with horizontal layout. Takes field name/type pairs
and an optional extension variable, formatting as `{ field : Type, ... }` or
`{ ext | field : Type, ... }`.
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


entryToDoc : ( D.Doc, D.Doc ) -> D.Doc
entryToDoc ( fieldName, fieldType ) =
    D.sep [ fieldName |> D.plus (D.fromChars ":"), fieldType ] |> D.hang 4


{-| Renders a partial record type snippet with vertical layout, showing the first
field and indicating additional fields with `...`. Used for abbreviated error messages.
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


{-| Renders a record type with vertical layout (each field on its own line).
Takes field name/type pairs and an optional extension variable.
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



-- SOURCE TYPE TO DOC


{-| Converts a source-level type (as parsed from user code) into a formatted
Doc for display in error messages and documentation.
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


srcFieldToDocs : Src.C2 ( Src.C1 (A.Located Name.Name), Src.C1 Src.Type ) -> ( D.Doc, D.Doc )
srcFieldToDocs ( _, ( ( _, A.At _ fieldName ), ( _, fieldType ) ) ) =
    ( D.fromName fieldName, srcToDoc None fieldType )


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



-- CANONICAL TYPE TO DOC


{-| Converts a canonical type (after type checking and resolution) into a
formatted Doc for display, using the localizer to determine the best way to
display qualified type names.
-}
canToDoc : L.Localizer -> Context -> Can.Type -> D.Doc
canToDoc localizer context tipe =
    case tipe of
        Can.TLambda arg1 result ->
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


canFieldToDoc : L.Localizer -> ( Name.Name, Can.Type ) -> ( D.Doc, D.Doc )
canFieldToDoc localizer ( name, tipe ) =
    ( D.fromName name, canToDoc localizer None tipe )


collectArgs : Can.Type -> ( Can.Type, List Can.Type )
collectArgs tipe =
    case tipe of
        Can.TLambda a rest ->
            let
                ( b, cs ) =
                    collectArgs rest
            in
            ( a, b :: cs )

        _ ->
            ( tipe, [] )
