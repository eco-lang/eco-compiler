module ClosureCaptureVary exposing (main)

-- CHECK: result: True

import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


buildClosures : Int -> List (Int -> Int) -> List (Int -> Int)
buildClosures i acc =
    if i <= 0 then
        acc
    else
        let
            kind =
                modBy 5 i

            closure =
                case kind of
                    0 ->
                        -- captures 1 value
                        \x -> x + i

                    1 ->
                        -- captures 2 values (i and kind)
                        \x -> x + i + kind

                    2 ->
                        -- captures 1 value, different operation
                        \x -> x + i * 2

                    3 ->
                        -- captures 2 values
                        \x -> x + i - kind

                    _ ->
                        -- captures 1 value
                        \x -> x + i + 1
        in
        buildClosures (i - 1) (closure :: acc)


applyAll : List (Int -> Int) -> Int -> Int
applyAll fns acc =
    case fns of
        [] ->
            acc

        f :: rest ->
            applyAll rest (f acc)


loop : List (Int -> Int) -> Int -> Int -> Int
loop closures count acc =
    if count <= 0 then
        acc
    else
        loop closures (count - 1) (applyAll closures acc)


main =
    let
        closures =
            buildClosures m []

        -- Run once to get the per-iteration sum
        onePass =
            applyAll closures 0

        -- Run n iterations
        total =
            loop closures n 0

        -- total should equal n * onePass since each pass adds the same constant
        result =
            total == n * onePass

        _ =
            Debug.log "result" result
    in
    text "done"
