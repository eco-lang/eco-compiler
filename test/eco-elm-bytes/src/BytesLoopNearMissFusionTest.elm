module BytesLoopNearMissFusionTest exposing (main)

{-| `Bytes.Decode.loop` decoders that each vary one detail of the usual count-based or sentinel-terminated loop give the expected results.

The usual count loop reads with `map (\x -> Loop ...) unsignedInt8` and ends
with `succeed (Done (List.reverse acc))`; the usual sentinel loop reads a byte
with `andThen` and stops at `0`. Most loops below differ from one of these in
one place. All run on the bytes `[ 1, 2, 0, 4, 5, 6, 7, 8 ]`.

  - `then_map`: a count loop of 2 whose `Done` is reached through
    `map (\_ -> Done ...) (succeed ())` instead of `succeed (Done ...)`.
  - `else_succeed`: a count loop of 2 whose step conses the counter and reads
    nothing (`succeed (Loop ...)` instead of `map`), giving `[2,1]`.
  - `else_and_then`: a count loop of 2 whose step reads through `andThen`
    instead of `map`.
  - `else_map2`: a count loop of 2 whose step reads two bytes with `map2` and
    conses their sum, giving `[3,4]`.
  - `item_mapped`: a count loop of 2 whose item decoder doubles each
    `unsignedInt8` with `map`, giving `[2,4]`.
  - `sentinel_map`: a sentinel loop whose step is a `map` instead of an
    `andThen`.
  - `sentinel_continue_map`: a sentinel loop whose `Loop` is reached through
    `map (\_ -> Loop ...) (succeed ())`.
  - `then_fail`: a count loop of 2 whose `Done` branch is `fail`, so the decode
    fails.
  - `then_and_then`: a count loop of 2 whose `Done` is reached through
    `andThen (\_ -> succeed (Done ...)) (succeed ())`.
  - `sentinel_step_fail`: a sentinel-shaped loop whose step is `fail`.
  - `sentinel_continue_map2`: a sentinel loop whose `Loop` is reached through
    `map2` of two `succeed ()`.

## eco

Exercises the bytes-fusion reifier on near misses: each loop differs in one place from the
two idioms `reifyLoop` in `compiler/src/Compiler/GenerateMlir/BytesFusion/Reify.elm`
fuses, so the reifier walks into the inlined forms of `succeed`, `map`, `map2` and
`andThen` that a build against the real elm/bytes produces, and must decline. Each result
is the value elm/bytes gives, which the unfused decoder must still produce.

-}

-- CHECK: then_map: "[1,2]"
-- CHECK: else_succeed: "[2,1]"
-- CHECK: else_and_then: "[1,2]"
-- CHECK: else_map2: "[3,4]"
-- CHECK: item_mapped: "[2,4]"
-- CHECK: sentinel_map: "[1,2]"
-- CHECK: sentinel_continue_map: "[1,2]"
-- CHECK: then_fail: "Nothing"
-- CHECK: then_and_then: "[1,2]"
-- CHECK: sentinel_step_fail: "Nothing"
-- CHECK: sentinel_continue_map2: "[1,2]"

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


input : Bytes
input =
    E.encode (E.sequence (List.map E.unsignedInt8 [ 1, 2, 0, 4, 5, 6, 7, 8 ]))


showInts : Maybe (List Int) -> String
showInts result =
    case result of
        Just xs ->
            "[" ++ String.join "," (List.map String.fromInt xs) ++ "]"

        Nothing ->
            "Nothing"


thenMap : Bytes -> Maybe (List Int)
thenMap bytes =
    D.decode
        (D.loop ( 2, [] )
            (\( k, acc ) ->
                if k <= 0 then
                    D.map (\_ -> D.Done (List.reverse acc)) (D.succeed ())

                else
                    D.map (\x -> D.Loop ( k - 1, x :: acc )) D.unsignedInt8
            )
        )
        bytes


elseSucceed : Bytes -> Maybe (List Int)
elseSucceed bytes =
    D.decode
        (D.loop ( 2, [] )
            (\( k, acc ) ->
                if k <= 0 then
                    D.succeed (D.Done (List.reverse acc))

                else
                    D.succeed (D.Loop ( k - 1, k :: acc ))
            )
        )
        bytes


elseAndThen : Bytes -> Maybe (List Int)
elseAndThen bytes =
    D.decode
        (D.loop ( 2, [] )
            (\( k, acc ) ->
                if k <= 0 then
                    D.succeed (D.Done (List.reverse acc))

                else
                    D.andThen (\x -> D.succeed (D.Loop ( k - 1, x :: acc ))) D.unsignedInt8
            )
        )
        bytes


elseMap2 : Bytes -> Maybe (List Int)
elseMap2 bytes =
    D.decode
        (D.loop ( 2, [] )
            (\( k, acc ) ->
                if k <= 0 then
                    D.succeed (D.Done (List.reverse acc))

                else
                    D.map2 (\x y -> D.Loop ( k - 1, (x + y) :: acc )) D.unsignedInt8 D.unsignedInt8
            )
        )
        bytes


itemMapped : Bytes -> Maybe (List Int)
itemMapped bytes =
    D.decode
        (D.loop ( 2, [] )
            (\( k, acc ) ->
                if k <= 0 then
                    D.succeed (D.Done (List.reverse acc))

                else
                    D.map (\x -> D.Loop ( k - 1, x :: acc )) (D.map (\v -> v * 2) D.unsignedInt8)
            )
        )
        bytes


sentinelMap : Bytes -> Maybe (List Int)
sentinelMap bytes =
    D.decode
        (D.loop []
            (\acc ->
                D.map
                    (\b ->
                        if b == 0 then
                            D.Done (List.reverse acc)

                        else
                            D.Loop (b :: acc)
                    )
                    D.unsignedInt8
            )
        )
        bytes


sentinelContinueMap : Bytes -> Maybe (List Int)
sentinelContinueMap bytes =
    D.decode
        (D.loop []
            (\acc ->
                D.andThen
                    (\b ->
                        if b == 0 then
                            D.succeed (D.Done (List.reverse acc))

                        else
                            D.map (\_ -> D.Loop (b :: acc)) (D.succeed ())
                    )
                    D.unsignedInt8
            )
        )
        bytes


thenFail : Bytes -> Maybe (List Int)
thenFail bytes =
    D.decode
        (D.loop ( 2, [] )
            (\( k, acc ) ->
                if k <= 0 then
                    D.fail

                else
                    D.map (\x -> D.Loop ( k - 1, x :: acc )) D.unsignedInt8
            )
        )
        bytes


thenAndThen : Bytes -> Maybe (List Int)
thenAndThen bytes =
    D.decode
        (D.loop ( 2, [] )
            (\( k, acc ) ->
                if k <= 0 then
                    D.andThen (\_ -> D.succeed (D.Done (List.reverse acc))) (D.succeed ())

                else
                    D.map (\x -> D.Loop ( k - 1, x :: acc )) D.unsignedInt8
            )
        )
        bytes


sentinelStepFail : Bytes -> Maybe (List Int)
sentinelStepFail bytes =
    D.decode (D.loop [] (\acc -> D.fail)) bytes


sentinelContinueMap2 : Bytes -> Maybe (List Int)
sentinelContinueMap2 bytes =
    D.decode
        (D.loop []
            (\acc ->
                D.andThen
                    (\b ->
                        if b == 0 then
                            D.succeed (D.Done (List.reverse acc))

                        else
                            D.map2 (\_ _ -> D.Loop (b :: acc)) (D.succeed ()) (D.succeed ())
                    )
                    D.unsignedInt8
            )
        )
        bytes


main =
    let
        _ =
            Debug.log "then_map" (showInts (thenMap input))

        _ =
            Debug.log "else_succeed" (showInts (elseSucceed input))

        _ =
            Debug.log "else_and_then" (showInts (elseAndThen input))

        _ =
            Debug.log "else_map2" (showInts (elseMap2 input))

        _ =
            Debug.log "item_mapped" (showInts (itemMapped input))

        _ =
            Debug.log "sentinel_map" (showInts (sentinelMap input))

        _ =
            Debug.log "sentinel_continue_map" (showInts (sentinelContinueMap input))

        _ =
            Debug.log "then_fail" (showInts (thenFail input))

        _ =
            Debug.log "then_and_then" (showInts (thenAndThen input))

        _ =
            Debug.log "sentinel_step_fail" (showInts (sentinelStepFail input))

        _ =
            Debug.log "sentinel_continue_map2" (showInts (sentinelContinueMap2 input))
    in
    text "done"
