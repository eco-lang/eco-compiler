module AliasForwardTest exposing (main)

{-| Top-level values defined as another function, `dup = twice` and `plus = (+)`, behave like the function they name.

`dup` is called at `Int` and at `String` and is passed as a value to
`List.map`. `plus` is called fully applied through `inc`, passed to
`List.foldl` at `Int` and at `Float`, and partially applied in `List.map`.
Results are reduced to `Int`s before they are logged.

-}

import Html exposing (text)



-- CHECK: dupInt: 3
-- CHECK: dupStr: 3
-- CHECK: foldInt: 6
-- CHECK: foldFloat: 45
-- CHECK: mapPartial: 5
-- CHECK: value: 4


twice : (a -> a) -> a -> a
twice f x =
    f (f x)


dup : (a -> a) -> a -> a
dup =
    twice


plus : number -> number -> number
plus =
    (+)


inc : Int -> Int
inc n =
    plus n 1


bang : String -> String
bang s =
    s ++ "!"


main =
    let
        _ =
            Debug.log "dupInt" (dup inc 1)

        _ =
            Debug.log "dupStr" (String.length (dup bang "a"))

        _ =
            Debug.log "foldInt" (List.foldl plus 0 [ 1, 2, 3 ])

        _ =
            Debug.log "foldFloat" (round (List.foldl plus 0.5 [ 1.5, 2.5 ] * 10))

        _ =
            Debug.log "mapPartial" (List.sum (List.map (plus 1) [ 1, 2 ]))

        _ =
            Debug.log "value" (List.sum (List.map dup [ inc ] |> List.map (\g -> g 2)))
    in
    text "done"
