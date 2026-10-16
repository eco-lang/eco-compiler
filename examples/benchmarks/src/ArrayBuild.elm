module ArrayBuild exposing (bench)

{-| Building and splicing persistent arrays, the Elm-specific part of `Array`: `Array.push` of
`n` elements one at a time (Elm's arrays keep a tail buffer for this), then rounds of
`Array.slice` and `Array.append` that cut the array in two at a varying point, swap the halves
and join them again (concatenating relaxed trees).

Checked at every size: after the pushes the array must be `0 .. n-1`, and after each round it
must be the rotation of that range by the total cut so far (a closed form: element `i` is
`(i + offset) mod n`), compared element by element through `Array.toList`.

-}

import Array exposing (Array)


build : Int -> Array Int
build n =
    List.foldl Array.push Array.empty (List.range 0 (n - 1))


{-| Cut at `k`, swap the two halves: a left rotation by `k`.
-}
rotate : Int -> Array Int -> Array Int
rotate k a =
    Array.append (Array.slice k (Array.length a) a) (Array.slice 0 k a)


rotated : Int -> Int -> List Int
rotated n offset =
    List.map (\i -> modBy n (i + offset)) (List.range 0 (n - 1))


bench : Int -> Bool
bench n =
    let
        built =
            build n

        cuts =
            List.map (\r -> modBy n (r * 7919 + 1)) (List.range 1 8)

        go cs offset a =
            case cs of
                [] ->
                    True

                k :: rest ->
                    let
                        b =
                            rotate k a

                        o =
                            modBy n (offset + k)
                    in
                    Array.toList b == rotated n o && go rest o b
    in
    Array.toList built == List.range 0 (n - 1) && go cuts 0 built
