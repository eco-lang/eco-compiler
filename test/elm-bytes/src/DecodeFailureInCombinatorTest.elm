module DecodeFailureInCombinatorTest exposing (main)

{-| A decode failure BELOW a combinator must make the whole decode Nothing,
never crash (plans/bytes-decode-failure-unwind.md).

Non-fused (kernel) path: a failing primitive read or `Decode.fail` throws a
C++ BytesDecodeFailure that Elm_Kernel_Bytes_decode catches, the way elm/bytes'
JS throws and `_Bytes_decode` catches. Before that, the read returned the
Nothing constant where map/map2/andThen/loop destructure an (offset, value)
tuple: SIGSEGV.

Every decoder goes through `run`, which selects it at run time so the bytes
fusion reifier cannot resolve it (CHECK-MLIR-NOT pins that). Covers every
combinator position, `fail`, invalid UTF-8 under a combinator, nested decodes,
failures interleaved with heavy allocation (GCs while the decoder is live), and
thousands of repeated failures followed by successful decodes — a leaked
kernel root-stack record or scratch entry would surface there as a crash or
wrong value. Every line must say "ok".
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


{-| Runtime selection the fusion reifier cannot see through (the index is
always 0, but only at run time), forcing the kernel decode path.
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


{-| Allocation-heavy work inside a decoder callback: forces minor GCs while
the decoder (and the apply trampolines' rooted arguments) are live.
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

        -- 400 decodes that allocate heavily in map callbacks (forcing GCs with
        -- the decoder live) and then fail in the next read.
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

        -- 5000 failures through nested combinators, then successful decodes and
        -- more allocation: leaked root-stack records would be scanned here.
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
