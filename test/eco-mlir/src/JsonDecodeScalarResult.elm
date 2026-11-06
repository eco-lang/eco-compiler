module JsonDecodeScalarResult exposing (main)

{-| Checks that `Json.Decode` decoders producing an Int or Float give back the decoded number in an `Ok`.

Each line decodes a value and prints the number inside the result, or -1 for
an `Err`:

  - `jdInt` decodes `"7"` with `int`.
  - `jdFloat` decodes `"2.5"` with `float` and prints it times ten, rounded.
  - `jdSucceed` decodes `true` with `oneOf [ int, succeed 42 ]`, so `int`
    fails and the result comes from `succeed`.
  - `jdIndex` decodes element 1 of `[4,5]` with `index`.
  - `jdValue` uses `decodeValue` on an encoded `Value` rather than
    `decodeString` on text.
  - `jdPap` maps the constructor `Pair` over one decoded field, giving a
    decoder of `Int -> Pair` functions, then maps a function that completes the `Pair`
    with 2 and adds its two fields: 7 + 2 is 9.

## eco

Regression test for HEAP_046 in design_docs/invariants.csv. The Json kernel
builds its internal `Ok` with a boxed payload, but heap slot layout is fixed
by the monomorphized type, so compiled code reads slot 0 of a
`Result Error Int` as a raw i64. The kernel now rewraps the escaping result at
`Json_run` and `Json_runOnString` (`rewrapEscapingResult` in
elm-kernel-cpp/src/json/JsonExports.cpp); before that every decode here
returned heap-pointer bits.

Each line covers a different producer of the escaping payload: the int, float
and succeed decoders, `index` (which returns the inner decoder's result
directly), the `decodeValue` entry point, and a partial constructor
application completed in Elm and destructured to unboxed fields. The
TEXT-MLIR directive also routes the program through the MLIR text printer
(compiler/src/Mlir/Pretty.elm).

-}

-- TEXT-MLIR: also keeps the MLIR text printer (Mlir.Pretty) covered and checked end to end
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
