module RootStackMapNTest exposing (main)

{-| Checks `List.map2`, `List.map3`, `List.map4` and `List.map5` over 70,000-element lists of `String`s.

Each call combines copies of the same list with `++`, so each result must have 70,000
elements.

## eco

GC shadow-root-stack pin, part of the bounded kernel rooting work
(plans/kernel-root-stack-bounded-rooting.md). The list has more boxed elements
than the 65,536 records the shadow root stack holds, so a kernel that pushes one
root record per element overflows it.

The `map2` to `map5` kernels root their buffers as whole arrays, so this is
expected to pass; it guards against a regression to per-element rooting.

-}

-- CHECK: map2: 70000
-- CHECK: map3: 70000
-- CHECK: map4: 70000
-- CHECK: map5: 70000

import Html exposing (text)


pad : Int -> String
pad n =
    String.padLeft 5 '0' (String.fromInt n)


{-| The 70,000 five-digit strings "00000" to "69999", in ascending order.
-}
strs : List String
strs =
    List.map pad (List.range 0 69999)


main =
    let
        _ =
            Debug.log "map2" (List.length (List.map2 (++) strs strs))

        _ =
            Debug.log "map3" (List.length (List.map3 (\a b c -> a ++ b ++ c) strs strs strs))

        _ =
            Debug.log "map4" (List.length (List.map4 (\a b c d -> a ++ b ++ c ++ d) strs strs strs strs))

        _ =
            Debug.log "map5" (List.length (List.map5 (\a b c d e -> a ++ b ++ c ++ d ++ e) strs strs strs strs strs))

    in
    text "done"
