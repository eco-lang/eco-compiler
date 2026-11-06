module CompilerIssue1858AnnotatedPolymorphicRecursionTest exposing (..)

{-| A recursive call at a different type argument is rejected despite the annotation.

<https://github.com/elm/compiler/issues/1858>

`bVals : Silly a b -> Maybe b` is annotated, so the recursive call `bVals nested` at
`Silly Int b` is well-typed (polymorphic recursion with an annotation; Elm 0.18 accepted it).
Elm 0.19.1 reports a type mismatch saying it needs `Silly a b`.

-}

-- CHECK: bVals: Just "b"

import Html exposing (text)


type Silly a b
    = AsB b
    | DeeplySilly (Silly a a) (Silly Int b)
    | NoArg


bVals : Silly a b -> Maybe b
bVals silly =
    case silly of
        AsB b ->
            Just b

        DeeplySilly _ nested ->
            bVals nested

        NoArg ->
            Nothing


value : Silly () String
value =
    DeeplySilly NoArg (AsB "b")


main =
    let
        _ =
            Debug.log "bVals" (bVals value)
    in
    text "done"
