module EraseWrapperFloatTest exposing (main)

{-| A wrapper around a `Float`, `type Q = Q Float`, inside a list, a `Dict`
value, a record field, a closure capture, a `Maybe` and a tuple, and flowing
through `List.foldl` and a polymorphic helper. Under `EraseWrappers` with
unboxed payloads (plans/constructor-representation-levels.md E1b) a `Q` is an
`f64` wherever no erased view of it exists, and stays a heap value where one
does; the results are the same either way.

-}

-- CHECK: sum: 6.5
-- CHECK: dict: 2.5
-- CHECK: rec: 1.25
-- CHECK: closure: 4.5
-- CHECK: maybe: 0.5
-- CHECK: tuple: 3
-- CHECK: poly: 2
-- CHECK: show: [Q 1.5,Q 2.5]
-- CHECK: showRec: { q = Q 1.25 }

import Dict
import Html exposing (text)


type Q
    = Q Float


addQ : Q -> Q -> Q
addQ (Q a) (Q b) =
    Q (a + b)


val : Q -> Float
val (Q x) =
    x


lengthOf : List a -> Int
lengthOf xs =
    List.length xs


main =
    let
        qs =
            List.map Q [ 1.5, 2.5, 2.5 ]

        _ =
            Debug.log "sum" (val (List.foldl addQ (Q 0) qs))

        d =
            Dict.fromList [ ( "a", Q 2.5 ) ]

        _ =
            Debug.log "dict" (Dict.get "a" d |> Maybe.map val |> Maybe.withDefault 0)

        r =
            { q = Q 1.25 }

        _ =
            Debug.log "rec" (val r.q)

        f =
            \(Q x) -> addQ (Q x) r.q

        _ =
            Debug.log "closure" (val (f (Q 3.25)))

        _ =
            Debug.log "maybe" (Maybe.map val (Just (Q 0.5)) |> Maybe.withDefault 0)

        ( Q t1, Q t2 ) =
            ( Q 1, Q 2 )

        _ =
            Debug.log "tuple" (t1 + t2)

        _ =
            Debug.log "poly" (lengthOf [ Q 1, Q 2 ])

        _ =
            Debug.log "show" (List.take 2 qs)

        _ =
            Debug.log "showRec" r
    in
    text "done"
