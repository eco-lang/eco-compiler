module LetNumberBoxedSilentMiscompileTest exposing (main)

{-| Regression test (native/AOT backend) — the DANGEROUS variant of the
let-bound-`number` mis-specialization (see `LetNumberFloatMulTest`).

When the mistyped `number` is laundered through a box (a tuple / record / list
/ Maybe element) before reaching the Float operation, no typed-kernel
signature conflict is registered, so the program compiles and RUNS — but
produces a silently wrong result: the `i64` bit-pattern of the literal is
reinterpreted as an `f64` (a denormal ≈ 0), so every result below currently
prints `0` / `[0, 0]` instead of the correct value.

This is strictly worse than the crash cases: there is no compiler error, just
incorrect output. The CHECK lines below are the correct answers.

-}

-- CHECK: tuple: 45
-- CHECK: record: 45
-- CHECK: list: [45, 60]
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
