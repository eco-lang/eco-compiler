module PolySpecializeRecursiveTest exposing (main)

{-| Annotated polymorphic recursive functions, `myLength` and `myMap`, give the
right results when called at both `Int` and `String` element types.

Neither function is tail-recursive. The test logs the lengths of a three-element
`Int` list and a two-element `String` list, and maps doubling over the `Int`
list and self-concatenation over the `String` list.

-}

-- CHECK: intLen: 3
-- CHECK: strLen: 2
-- CHECK: intMap: [2,4,6]
-- CHECK: strMap: ["aa","bb"]

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
