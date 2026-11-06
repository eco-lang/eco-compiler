module DecodeFailureInCombinatorTest exposing (main)

{-| A decoder that fails inside a combinator, by running out of bytes, by `Bytes.Decode.fail`, or by invalid UTF-8, makes the whole `decode` return `Nothing`, and later decodes still work.

Every decoder runs through `run`, which passes it through `hide` before calling `decode` on the given bytes. Each entry of `results` compares one decode with the expected `Maybe` and logs `"ok"` on a match; `bad` lists the labels of the entries that did not match, and is expected to be empty.

What the tests establish:

  - `map_oob`, `map2_first_oob`, `map2_second_oob`, `map3_last_oob`, `map4_last_oob`, `map5_last_oob`: `map` through `map5` give `Nothing` when the bytes run out before the first or the last of their decoders.
  - `andThen_first_oob`, `andThen_second_oob`: `andThen` gives `Nothing` when the bytes run out before the first decoder, or in the decoder chosen from its result (a length of 5 with one byte left).
  - `loop_body_oob`: a three-step `loop` over two bytes gives `Nothing`.
  - `fail_in_map2`, `fail_in_map`, `fail_from_callback`, `fail_in_loop_step`: `fail` as an argument of `map2` or `map`, returned from an `andThen` callback followed by a `map`, or returned in the middle of a loop, gives `Nothing`.
  - `string_invalid_in_map2`: `string 1` on the lone byte `0x80` fails inside `map2`.
  - `string_trunc_in_loop`: a loop of length-prefixed strings fails when the second string is the single byte `0xC3`, the start of a two-byte character.
  - `nested_inner_fails`, `nested_outer_fails_after_inner_ok`: a `decode` run inside an `andThen` callback can fail without failing the outer decode (giving `Just Nothing`), and an outer decode can fail after an inner one succeeded.
  - `ok_map2`, `ok_map5`, `ok_loop`, `ok_callback`, `ok_nested`: the same combinators succeed with the expected values when the bytes are sufficient.
  - `gc_pressure_failures`: 400 decodes whose `map` callbacks build large strings, each failing on a missing third byte, all give `Nothing`.
  - `repeated_failures`: 5000 four-step loops over three bytes all give `Nothing`.
  - `after_failures_ok`: after those failures, a two-step loop over sufficient bytes decodes `[ ( 1, 2 ), ( 3, 4 ) ]`.

Among what is not tested: the signed integer and float decoders, and big-endian reads under a combinator.

## eco

Exercises the kernel (non-fused) decode-failure unwind of the bytes decode failure work
(plans/bytes-decode-failure-unwind.md). A failing primitive read or `fail` throws a C++
`BytesDecodeFailure` that `Elm_Kernel_Bytes_decode` in elm-kernel-cpp/src/bytes/BytesExports.cpp
catches, as elm/bytes' JS throws and `_Bytes_decode` catches. Before that, the read returned the
`Nothing` constant where `map`, `map2`, `andThen` and `loop` destructure an (offset, value)
tuple, and the program crashed with SIGSEGV.

`hide` selects the decoder at run time so the bytes fusion reifier
(compiler/src/Compiler/GenerateMlir/BytesFusion/Reify.elm) cannot resolve it; the
CHECK-MLIR-NOT line asserts no fused `bf.read` appears. The GC-pressure and repeated-failure
lines would surface a leaked kernel root-stack record or scratch entry as a crash or a wrong
value.

-}

-- CHECK: bad: []
-- CHECK: map_oob: "ok"
-- CHECK: map2_first_oob: "ok"
-- CHECK: map2_second_oob: "ok"
-- CHECK: map3_last_oob: "ok"
-- CHECK: map4_last_oob: "ok"
-- CHECK: map5_last_oob: "ok"
-- CHECK: andThen_first_oob: "ok"
-- CHECK: andThen_second_oob: "ok"
-- CHECK: loop_body_oob: "ok"
-- CHECK: fail_in_map2: "ok"
-- CHECK: fail_in_map: "ok"
-- CHECK: fail_from_callback: "ok"
-- CHECK: fail_in_loop_step: "ok"
-- CHECK: string_invalid_in_map2: "ok"
-- CHECK: string_trunc_in_loop: "ok"
-- CHECK: nested_inner_fails: "ok"
-- CHECK: nested_outer_fails_after_inner_ok: "ok"
-- CHECK: ok_map2: "ok"
-- CHECK: ok_map5: "ok"
-- CHECK: ok_loop: "ok"
-- CHECK: ok_callback: "ok"
-- CHECK: ok_nested: "ok"
-- CHECK: gc_pressure_failures: 400
-- CHECK: repeated_failures: 5000
-- CHECK: after_failures_ok: "ok"
-- CHECK-MLIR-NOT: bf.read

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


bs : List Int -> Bytes
bs xs =
    E.encode (E.sequence (List.map E.unsignedInt8 xs))


{-| Returns `d` unchanged, by way of a list lookup whose index depends on the
width of `b`. The index is always 0, but the decoder handed to `decode` is
chosen at run time rather than written out at the call.
-}
hide : Bytes -> D.Decoder a -> D.Decoder a
hide b d =
    case List.drop (modBy 7 (Bytes.width b) // 7) [ d ] of
        x :: _ ->
            x

        [] ->
            D.fail


run : D.Decoder a -> Bytes -> Maybe a
run d b =
    D.decode (hide b d) b


verdict : Maybe a -> Maybe a -> String
verdict actual expected =
    if actual == expected then
        "ok"

    else
        "BAD got " ++ Debug.toString actual


u16 : D.Decoder Int
u16 =
    D.unsignedInt16 Bytes.LE


countLoop : Int -> D.Decoder a -> D.Decoder (List a)
countLoop count item =
    D.loop ( count, [] )
        (\( n, acc ) ->
            if n <= 0 then
                D.succeed (D.Done (List.reverse acc))

            else
                D.map (\x -> D.Loop ( n - 1, x :: acc )) item
        )


{-| Returns the length of the comma-separated numbers from `seed` to
`seed + 3000`, so that calling it inside a decoder callback allocates heavily.
-}
churn : Int -> Int
churn seed =
    List.range 0 3000
        |> List.map (\i -> String.fromInt (i + seed))
        |> String.join ","
        |> String.length


main =
    let
        results =
            [ ( "map_oob", verdict (run (D.map (\x -> x + 1) D.unsignedInt8) (bs [])) Nothing )
            , ( "map2_first_oob", verdict (run (D.map2 Tuple.pair u16 D.unsignedInt8) (bs [ 1 ])) Nothing )
            , ( "map2_second_oob", verdict (run (D.map2 Tuple.pair D.unsignedInt8 D.unsignedInt8) (bs [ 1 ])) Nothing )
            , ( "map3_last_oob", verdict (run (D.map3 (\a b c -> a + b + c) D.unsignedInt8 D.unsignedInt8 D.unsignedInt8) (bs [ 1, 2 ])) Nothing )
            , ( "map4_last_oob", verdict (run (D.map4 (\a b c d -> a + b + c + d) D.unsignedInt8 D.unsignedInt8 D.unsignedInt8 D.unsignedInt8) (bs [ 1, 2, 3 ])) Nothing )
            , ( "map5_last_oob", verdict (run (D.map5 (\a b c d e -> a + b + c + d + e) D.unsignedInt8 D.unsignedInt8 D.unsignedInt8 D.unsignedInt8 D.unsignedInt8) (bs [ 1, 2, 3, 4 ])) Nothing )
            , ( "andThen_first_oob", verdict (run (u16 |> D.andThen (\_ -> D.unsignedInt8)) (bs [ 1 ])) Nothing )
            , ( "andThen_second_oob", verdict (run (D.unsignedInt8 |> D.andThen (\n -> D.bytes n) |> D.map Bytes.width) (bs [ 5, 1 ])) Nothing )
            , ( "loop_body_oob", verdict (run (countLoop 3 D.unsignedInt8) (bs [ 1, 2 ])) Nothing )
            , ( "fail_in_map2", verdict (run (D.map2 Tuple.pair D.unsignedInt8 D.fail) (bs [ 1 ])) Nothing )
            , ( "fail_in_map", verdict (run (D.map (\x -> x + 1) D.fail) (bs [ 1 ])) Nothing )
            , ( "fail_from_callback"
              , verdict
                    (run
                        (D.unsignedInt8
                            |> D.andThen
                                (\n ->
                                    if n == 0 then
                                        D.fail

                                    else
                                        D.succeed n
                                )
                            |> D.map (\n -> n * 2)
                        )
                        (bs [ 0 ])
                    )
                    Nothing
              )
            , ( "fail_in_loop_step"
              , verdict
                    (run
                        (countLoop 3
                            (D.unsignedInt8
                                |> D.andThen
                                    (\n ->
                                        if n == 9 then
                                            D.fail

                                        else
                                            D.succeed n
                                    )
                            )
                        )
                        (bs [ 1, 9, 2 ])
                    )
                    Nothing
              )
            , ( "string_invalid_in_map2", verdict (run (D.map2 Tuple.pair (D.string 1) D.unsignedInt8) (bs [ 0x80, 7 ])) Nothing )
            , ( "string_trunc_in_loop", verdict (run (countLoop 2 (D.unsignedInt8 |> D.andThen (\n -> D.string n))) (bs [ 2, 0x68, 0x69, 1, 0xC3 ])) Nothing )
            , ( "nested_inner_fails"
              , verdict
                    (run (D.unsignedInt8 |> D.andThen (\n -> D.succeed (run u16 (bs [ n ])))) (bs [ 7 ]))
                    (Just Nothing)
              )
            , ( "nested_outer_fails_after_inner_ok"
              , verdict
                    (run (D.map2 Tuple.pair (D.unsignedInt8 |> D.andThen (\n -> D.succeed (run D.unsignedInt8 (bs [ n ])))) D.unsignedInt8) (bs [ 7 ]))
                    Nothing
              )
            , ( "ok_map2", verdict (run (D.map2 Tuple.pair D.unsignedInt8 D.unsignedInt8) (bs [ 1, 2 ])) (Just ( 1, 2 )) )
            , ( "ok_map5", verdict (run (D.map5 (\a b c d e -> [ a, b, c, d, e ]) D.unsignedInt8 D.unsignedInt8 D.unsignedInt8 D.unsignedInt8 D.unsignedInt8) (bs [ 1, 2, 3, 4, 5 ])) (Just [ 1, 2, 3, 4, 5 ]) )
            , ( "ok_loop", verdict (run (countLoop 3 D.unsignedInt8) (bs [ 1, 2, 3 ])) (Just [ 1, 2, 3 ]) )
            , ( "ok_callback"
              , verdict
                    (run
                        (D.unsignedInt8
                            |> D.andThen
                                (\n ->
                                    if n == 0 then
                                        D.fail

                                    else
                                        D.succeed n
                                )
                        )
                        (bs [ 3 ])
                    )
                    (Just 3)
              )
            , ( "ok_nested"
              , verdict
                    (run (D.unsignedInt8 |> D.andThen (\n -> D.succeed (run D.unsignedInt8 (bs [ n ])))) (bs [ 7 ]))
                    (Just (Just 7))
              )
            ]

        -- 400 decodes that allocate heavily in map callbacks and then fail:
        -- two bytes are given, three are needed.
        gcPressureFailures =
            List.range 1 400
                |> List.map
                    (\i ->
                        run
                            (D.map2 (\a b -> a + b)
                                (D.map (\x -> churn (x + i)) D.unsignedInt8)
                                (D.map (\x -> churn x) u16)
                            )
                            (bs [ modBy 256 i, 1 ])
                    )
                |> List.filter ((==) Nothing)
                |> List.length

        -- 5000 failures through nested combinators: four steps of three bytes
        -- each are asked of a three-byte sequence.
        repeatedFailures =
            List.range 1 5000
                |> List.map (\i -> run (countLoop 4 (D.map2 Tuple.pair D.unsignedInt8 u16)) (bs [ modBy 256 i, 1, 2 ]))
                |> List.filter ((==) Nothing)
                |> List.length

        afterFailuresOk =
            if repeatedFailures > 0 && churn 1 > 0 then
                verdict
                    (run (countLoop 2 (D.map2 Tuple.pair D.unsignedInt8 u16)) (bs [ 1, 2, 0, 3, 4, 0 ]))
                    (Just [ ( 1, 2 ), ( 3, 4 ) ])

            else
                "BAD guard"

        _ =
            Debug.log "bad" (List.map Tuple.first (List.filter (\( _, v ) -> v /= "ok") results))

        _ =
            List.map (\( l, v ) -> Debug.log l v) results

        _ =
            Debug.log "gc_pressure_failures" gcPressureFailures

        _ =
            Debug.log "repeated_failures" repeatedFailures

        _ =
            Debug.log "after_failures_ok" afterFailuresOk
    in
    text "done"
