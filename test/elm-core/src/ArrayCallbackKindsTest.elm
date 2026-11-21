module ArrayCallbackKindsTest exposing (main)

{-| `Array.map`, `Array.indexedMap`, `Array.foldl` and `Array.foldr` over arrays of
`Int`, `Float` and `Char` (40 elements, so both the tree and the tail are
visited), with closures typed at the element, with the cons kernel `(::)` and
with a function value polymorphic in the element, which take the element boxed.

## eco

The `JsArray` kernels pass each element to the closure in the array's own slot
kind; the runtime boxes it only for a closure that takes it boxed
(plans/constructor-representation-followups.md F5c).

-}

-- CHECK: mapInt: 1640
-- CHECK: indexedMapInt: 1560
-- CHECK: foldlInt: 780
-- CHECK: foldrIntCons: [0,1,2,3,4]
-- CHECK: foldlIntCons: [39,38,37]
-- CHECK: mapFloat: 410
-- CHECK: foldrFloat: 390
-- CHECK: mapChar: "bcdefghijklmnopqrstuvwxyz{|}~"
-- CHECK: foldlChar: 40
-- CHECK: polyLength: 40

import Array exposing (Array)
import Html exposing (text)


countAll : (a -> Int -> Int) -> Array a -> Int
countAll step arr =
    Array.foldl step 0 arr


main =
    let
        ints =
            Array.initialize 40 identity

        floats =
            Array.initialize 40 (\i -> toFloat i / 2)

        chars =
            Array.initialize 40 (\i -> Char.fromCode (97 + modBy 30 i))

        _ =
            Debug.log "mapInt" (Array.foldl (+) 0 (Array.map (\x -> x * 2 + 2) ints))

        _ =
            Debug.log "indexedMapInt" (Array.foldl (+) 0 (Array.indexedMap (\i x -> i + x) ints))

        _ =
            Debug.log "foldlInt" (Array.foldl (+) 0 ints)

        _ =
            Debug.log "foldrIntCons" (List.take 5 (Array.foldr (::) [] ints))

        _ =
            Debug.log "foldlIntCons" (List.take 3 (Array.foldl (::) [] ints))

        _ =
            Debug.log "mapFloat" (Array.foldl (+) 0 (Array.map (\x -> x + 0.5) floats))

        _ =
            Debug.log "foldrFloat" (Array.foldr (+) 0 floats)

        _ =
            Debug.log "mapChar" (String.fromList (List.take 29 (Array.toList (Array.map (\c -> Char.fromCode (Char.toCode c + 1)) chars))))

        _ =
            Debug.log "foldlChar" (Array.foldl (\c n -> n + 1) 0 chars)

        _ =
            Debug.log "polyLength" (countAll (\_ n -> n + 1) ints)
    in
    text "done"
