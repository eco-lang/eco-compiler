module ListMapTemplateLongTest exposing (main)

{-| Long-list coverage for the `List.map` forward template
(plans/list-map-mlir-template.md).

**Why these exact lengths.** elm/core's `foldrHelper` is 4-way-unrolled and
bails past its depth budget to `foldl fn acc (reverse r4)` — a whole extra
reversed-spine materialization. The threshold is `ctr > 500`, and `ctr`
advances once per 4-element level, so level 501 covers elements 2005..2008 and
its `r4` (elements 2009 onward) is what the reverse leg actually processes.
2004 / 2008 / 2012 / 5000 therefore bracket the TRUE boundary from both sides:
2004 never reaches the branch, 2008 reaches it with an empty `r4`, 2012 and
5000 take the reverse leg for real. That branch had zero existing E2E
coverage, in either lowering.

The template must agree with the foldr path at every length and for every
element/result kind, so each case is checked against a reference construction
built without `List.map`.

-}

-- CHECK: boxed2004: True
-- CHECK: boxed2008: True
-- CHECK: boxed2012: True
-- CHECK: boxed5000: True
-- CHECK: ints2012: True
-- CHECK: floats2012: True
-- CHECK: chars2012: True
-- CHECK: len5000: 5000
-- CHECK: firstLast: ("x1", "x5000")

import Html exposing (text)


{-| Reference: build the mapped list WITHOUT List.map, so the comparison is
against an independent construction rather than another call of the thing
under test.
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
