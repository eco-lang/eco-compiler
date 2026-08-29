module JsonDecodeScalarResult exposing (main)

{-| HEAP_046 regression pins (fixed 2026-08-29, found by LssGapKernelPipeline).

The Json kernel's internal `Ok` stores its payload BOXED, but heap slot layout
is a static function of the monomorphized type — for `Result Error Int` the
compiled reader reads slot 0 as raw i64. Before the escape-boundary rewrap
(`rewrapEscapingResult` at `Json_run`/`Json_runOnString`) every scalar decode
below returned heap-pointer bits instead of its value.

Each rung exercises a distinct producer of the escaping payload:
`jdInt` DEC\_INT, `jdFloat` DEC\_FLOAT, `jdSucceed` DEC\_SUCCEED via a oneOf
fallback, `jdIndex` DEC\_INDEX (returns the INNER decoder's Result directly),
`jdValue` the `Json_run` escape point (`decodeValue`, not `decodeString`), and
`jdPap` the original shape — a partial CTOR application decoded through
`D.map`, completed Elm-side, destructured to unboxed fields.

-}

-- CHECK: jdInt: 7
-- CHECK: jdFloat: 25
-- CHECK: jdSucceed: 42
-- CHECK: jdIndex: 5
-- CHECK: jdValue: 11
-- CHECK: jdPap: 9

import Html exposing (text)
import Json.Decode as D
import Json.Encode as E


type Pair
    = Pair Int Int


pairValue : Pair -> Int
pairValue (Pair a b) =
    a + b


unwrap : Result e Int -> Int
unwrap r =
    case r of
        Ok n ->
            n

        Err _ ->
            -1


main =
    let
        _ =
            Debug.log "jdInt" (unwrap (D.decodeString D.int "7"))

        _ =
            Debug.log "jdFloat"
                (case D.decodeString D.float "2.5" of
                    Ok f ->
                        round (f * 10)

                    Err _ ->
                        -1
                )

        _ =
            Debug.log "jdSucceed"
                (unwrap (D.decodeString (D.oneOf [ D.int, D.succeed 42 ]) "true"))

        _ =
            Debug.log "jdIndex"
                (unwrap (D.decodeString (D.index 1 D.int) "[4,5]"))

        _ =
            Debug.log "jdValue"
                (unwrap (D.decodeValue D.int (E.int 11)))

        _ =
            Debug.log "jdPap"
                (unwrap
                    (D.decodeString
                        (D.map (\f -> pairValue (f 2)) (D.map Pair (D.field "a" D.int)))
                        "{\"a\":7}"
                    )
                )
    in
    text "hello"
