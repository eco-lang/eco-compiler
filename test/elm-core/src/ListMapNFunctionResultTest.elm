module ListMapNFunctionResultTest exposing (main)

{-| `List.map2` and `List.map3` with a function whose result is itself a
function (`\a b -> \c -> a + b + c`), each result then applied, and
`Array.initialize` with such a function.

## eco

The compiler merges `\a b -> \c -> ...` into one closure of three parameters,
so the kernel's call with two (or one) arguments is a partial application: its
result is a function value, which is boxed whatever kind the closure returns
once saturated. Before the fix the kernels asked for the closure's saturated
result kind (Int) and `eco_apply_closure_eval` aborted on the under-saturated
apply (plans/constructor-representation-followups.md §9, found by
ArrayGetPrimitiveTest).

-}

-- CHECK: map2: [13,24]
-- CHECK: map3: [111,222]
-- CHECK: initialize: [10,11,12]

import Array
import Html exposing (text)


main =
    let
        adders =
            List.map2 (\a b -> \c -> a + b + c) [ 1, 2 ] [ 10, 20 ]

        adders3 =
            List.map3 (\a b c -> \d -> a + b + c + d) [ 1, 2 ] [ 10, 20 ] [ 100, 200 ]

        fromIndex =
            Array.initialize 3 (\i -> \x -> x + i)

        _ =
            Debug.log "map2" (List.map (\f -> f 2) adders)

        _ =
            Debug.log "map3" (List.map (\f -> f 0) adders3)

        _ =
            Debug.log "initialize" (List.map (\f -> f 10) (Array.toList fromIndex))
    in
    text "done"
