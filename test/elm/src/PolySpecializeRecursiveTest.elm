module PolySpecializeRecursiveTest exposing (main)

{-| Test polymorphic function specialization at multiple types. -}

-- CHECK: intLen: 3
-- CHECK: strLen: 2
-- CHECK: intMap: [2, 4, 6]
-- CHECK: strMap: ["aa", "bb"]

import Html exposing (text)


myLength : List a -> Int
myLength xs =
    case xs of
        [] -> 0
        _ :: rest -> 1 + myLength rest


myMap : (a -> b) -> List a -> List b
myMap f xs =
    case xs of
        [] -> []
        x :: rest -> f x :: myMap f rest


main =
    let
        _ = Debug.log "intLen" (myLength [1, 2, 3])
        _ = Debug.log "strLen" (myLength ["a", "b"])
        _ = Debug.log "intMap" (myMap (\x -> x * 2) [1, 2, 3])
        _ = Debug.log "strMap" (myMap (\s -> s ++ s) ["a", "b"])
    in
    text "done"
