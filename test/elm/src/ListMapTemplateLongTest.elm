module ListMapTemplateLongTest exposing (main)

{-| Checks that `List.map` agrees with a reference map on lists of 2004 to 5000
elements, around the length at which elm/core's `List.foldr` changes strategy.

elm/core defines `List.map` with `List.foldr`, which recurses over four
elements per level and counts the levels. On the level where the count first
exceeds 500, which holds elements 2005 to 2008, it hands the rest of the list
to `List.foldl` over its reverse instead of recursing further. A list of 2004
elements never reaches that level, one of 2008 reaches it with nothing left
over, and lists of 2012 and 5000 send their remaining elements through the
`List.foldl` path.

Each `agrees*` function compares `List.map` over `List.range 1 n` with `refMap`,
which maps with `List.foldl` and `List.reverse`:

  - `String` results at 2004, 2008, 2012 and 5000 elements;
  - `Int`, `Float` and `Char` results at 2012 elements.

The last two checks map 5000 integers to labels and check the length and the
first and last labels.

-}

-- CHECK: boxed2004: True
-- CHECK: boxed2008: True
-- CHECK: boxed2012: True
-- CHECK: boxed5000: True
-- CHECK: ints2012: True
-- CHECK: floats2012: True
-- CHECK: chars2012: True
-- CHECK: len5000: 5000
-- CHECK: firstLast: ("x1","x5000")

import Html exposing (text)


{-| Maps `f` over `xs` without using `List.map`, as an independent reference.
-}
refMap : (a -> b) -> List a -> List b
refMap f xs =
    List.foldl (\x acc -> f x :: acc) [] xs
        |> List.reverse


label : Int -> String
label n =
    "x" ++ String.fromInt n


agreesBoxed : Int -> Bool
agreesBoxed n =
    let
        src =
            List.range 1 n
    in
    List.map label src == refMap label src


agreesInt : Int -> Bool
agreesInt n =
    let
        src =
            List.range 1 n
    in
    List.map (\x -> x * 3 + 1) src == refMap (\x -> x * 3 + 1) src


agreesFloat : Int -> Bool
agreesFloat n =
    let
        src =
            List.range 1 n

        f =
            \x -> toFloat x * 0.5
    in
    List.map f src == refMap f src


agreesChar : Int -> Bool
agreesChar n =
    let
        src =
            List.range 1 n

        f =
            \x -> Char.fromCode (97 + modBy 26 x)
    in
    List.map f src == refMap f src


main : Html.Html msg
main =
    let
        big =
            List.map label (List.range 1 5000)

        _ =
            Debug.log "boxed2004" (agreesBoxed 2004)

        _ =
            Debug.log "boxed2008" (agreesBoxed 2008)

        _ =
            Debug.log "boxed2012" (agreesBoxed 2012)

        _ =
            Debug.log "boxed5000" (agreesBoxed 5000)

        _ =
            Debug.log "ints2012" (agreesInt 2012)

        _ =
            Debug.log "floats2012" (agreesFloat 2012)

        _ =
            Debug.log "chars2012" (agreesChar 2012)

        _ =
            Debug.log "len5000" (List.length big)

        _ =
            Debug.log "firstLast"
                ( Maybe.withDefault "?" (List.head big)
                , Maybe.withDefault "?" (List.head (List.reverse big))
                )
    in
    text "done"
