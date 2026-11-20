module KnownCtorCaseTest exposing (main)

{-| A `case` on a value built by a known constructor in the same function,
which `KnownCtorCase` (plans/constructor-representation-levels.md K1) folds:
directly after a `let`, after inlining a small helper that builds the value,
with a nullary constructor, with a `Jump` branch shared by several patterns,
with a nested pattern on a field (left alone), and with a field argument that
is a call (left alone). The results are the same either way.

-}

-- CHECK: direct: 7
-- CHECK: helper: 12
-- CHECK: enum: "green"
-- CHECK: shared: "small"
-- CHECK: nested: 5
-- CHECK: callArg: 9
-- CHECK: shadow: 3

import Html exposing (text)


type Work
    = WorkA Int
    | WorkB Int Int
    | Idle


type Color
    = Red
    | Green
    | Blue


run : Work -> Int
run w =
    case w of
        WorkA n ->
            n

        WorkB a b ->
            a * b

        Idle ->
            0


makeB : Int -> Work
makeB n =
    WorkB n 4


size : Int -> String
size n =
    let
        w =
            WorkA n
    in
    case w of
        WorkA 1 ->
            "small"

        WorkA 2 ->
            "small"

        _ ->
            "big"


main =
    let
        x =
            3

        direct =
            let
                w =
                    WorkA (x + 4)
            in
            case w of
                WorkA n ->
                    n

                _ ->
                    0

        _ =
            Debug.log "direct" direct

        _ =
            Debug.log "helper" (run (makeB x))

        c =
            Green

        _ =
            Debug.log "enum"
                (case c of
                    Red ->
                        "red"

                    Green ->
                        "green"

                    Blue ->
                        "blue"
                )

        _ =
            Debug.log "shared" (size 2)

        nested =
            let
                m =
                    Just (WorkA 5)
            in
            case m of
                Just (WorkA n) ->
                    n

                _ ->
                    0

        _ =
            Debug.log "nested" nested

        _ =
            Debug.log "callArg"
                (let
                    w =
                        WorkB (x * 3) 1
                 in
                 case w of
                    WorkB a _ ->
                        a

                    _ ->
                        0
                )

        shadowed =
            let
                v =
                    1

                w =
                    WorkA v
            in
            let
                v_ =
                    v + 2
            in
            case w of
                WorkA n ->
                    n + v_ - 1

                _ ->
                    0

        _ =
            Debug.log "shadow" shadowed
    in
    text "done"
