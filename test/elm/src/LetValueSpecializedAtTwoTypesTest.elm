module LetValueSpecializedAtTwoTypesTest exposing (main)

{-| A polymorphic function whose let-bound values are compared with `==` must build each value once,
at the instantiation's own types. Here `check` is used at `Int -> String` values on a large dict and
at `Int -> Int` values on a one-entry dict; the `==` of `mapped` and `fresh` at the String instance
must be `True`, as the lists they hold are equal. The String instance used to build both values a
second time with the Int instance's specializations: the let took the number-per-use path because a
variable of its type was `number` in the super table, although its type there, `Dict Int String`, held
no unresolved `number` (`Translate.isNumberMultiEligible`).

-}

-- CHECK: deep: [True,True,True]
-- CHECK: one: [True,True,True]

import Dict exposing (Dict)
import Html exposing (text)


check : (comparable -> a -> b) -> Dict comparable a -> List Bool
check f d =
    let
        mapped =
            Dict.map f d

        expected =
            List.map (\( k, v ) -> ( k, f k v )) (Dict.toList d)

        fresh =
            Dict.fromList expected
    in
    [ Dict.toList mapped == expected
    , mapped == fresh
    , Dict.toList fresh == expected
    ]


big : Dict Int Int
big =
    Dict.fromList (List.map (\k -> ( k, 3 * k )) (List.range 0 1999))


main =
    let
        _ =
            Debug.log "deep" (check (\k v -> String.fromInt (k + v)) big)

        _ =
            Debug.log "one" (check (\_ v -> v + 1) (Dict.singleton 1 1))
    in
    text "done"
