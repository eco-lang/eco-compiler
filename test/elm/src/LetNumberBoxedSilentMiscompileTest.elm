module LetNumberBoxedSilentMiscompileTest exposing (main)

{-| Number literals placed inside a container by an unannotated `let` binding, then
taken out and used as Floats, give the correct Float results.

Each case multiplies by 1.5 and rounds: the first element of a tuple `( 30, 99 )`
(45), a record field `{ a = 30 }` (45), each element of a list `[ 30, 40 ]`
(`[45,60]`), the contents of `Just 30` through `Maybe.map` (45), and each element of a
list held in a record field (`[45]`).

-}

-- CHECK: tuple: 45
-- CHECK: record: 45
-- CHECK: list: [45,60]
-- CHECK: maybe: 45
-- CHECK: nested: [45]

import Html exposing (text)


main =
    let
        fromTuple =
            let
                p =
                    ( 30, 99 )
            in
            round (Tuple.first p * 1.5)

        fromRecord =
            let
                r =
                    { a = 30 }
            in
            round (r.a * 1.5)

        fromList =
            let
                xs =
                    [ 30, 40 ]
            in
            List.map (\x -> round (x * 1.5)) xs

        fromMaybe =
            let
                m =
                    Just 30
            in
            Maybe.withDefault 0 (Maybe.map (\x -> round (x * 1.5)) m)

        fromNested =
            let
                r =
                    { xs = [ 30 ] }
            in
            List.map (\x -> round (x * 1.5)) r.xs

        _ =
            Debug.log "tuple" fromTuple

        _ =
            Debug.log "record" fromRecord

        _ =
            Debug.log "list" fromList

        _ =
            Debug.log "maybe" fromMaybe

        _ =
            Debug.log "nested" fromNested
    in
    text "done"
