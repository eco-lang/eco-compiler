module ListMapTemplateCtorTest exposing (main)

{-| Checks `List.map` with a constructor as the callback, for three kinds of
constructor: `Just` from elm/core, `Tagged` from a custom type that also has a
nullary constructor, and `Wrap` from a custom type with a single one-field
constructor.

Each constructor is mapped over `[1, 2, 3]`. The `Just` list is checked by its
length, 3. The `Tagged` list is folded with `untag`, which multiplies each
payload by ten, giving 60, and the `Wrap` list is folded with `unwrap`, which
gives 6.

-}

-- CHECK: justs: 3
-- CHECK-NEXT: tagged: 60
-- CHECK-NEXT: wrapped: 6

import Html exposing (text)


type Tagged
    = Tagged Int
    | Untagged


type Wrap
    = Wrap Int


untag : Tagged -> Int
untag t =
    case t of
        Tagged n ->
            n * 10

        Untagged ->
            0


unwrap : Wrap -> Int
unwrap (Wrap n) =
    n


main : Html.Html msg
main =
    let
        justs : List (Maybe Int)
        justs =
            List.map Just [ 1, 2, 3 ]

        tagged : List Tagged
        tagged =
            List.map Tagged [ 1, 2, 3 ]

        wrapped : List Wrap
        wrapped =
            List.map Wrap [ 1, 2, 3 ]

        _ =
            Debug.log "justs" (List.length justs)

        _ =
            Debug.log "tagged" (List.foldl (\t acc -> acc + untag t) 0 tagged)

        _ =
            Debug.log "wrapped" (List.foldl (\w acc -> acc + unwrap w) 0 wrapped)
    in
    text "done"
