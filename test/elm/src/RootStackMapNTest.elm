module RootStackMapNTest exposing (main)

{-| GC shadow-root-stack pin (plans/kernel-root-stack-bounded-rooting.md §4): `List.map2` .. `List.map5` producing long lists of `String`s.

The `map2`..`map5` exports root their buffers as whole arrays, so this is expected to pass; it
guards against a regression to per-element rooting.
-}

-- CHECK: map2: 70000
-- CHECK: map3: 70000
-- CHECK: map4: 70000
-- CHECK: map5: 70000

import Html exposing (text)


pad : Int -> String
pad n =
    String.padLeft 5 '0' (String.fromInt n)


{-| "00000" .. "69999": 70,000 boxed elements, more than the 65,536 records the shadow stack holds.
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
