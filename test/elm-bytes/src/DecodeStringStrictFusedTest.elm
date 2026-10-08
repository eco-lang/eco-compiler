module DecodeStringStrictFusedTest exposing (main)

{-| Bytes.Decode.string strictness — FUSED (bf.read.utf8 -> elm_utf8_decode).

Target semantics (shared by BOTH decode paths): `string n` succeeds only if
the n bytes at the cursor lie inside the buffer AND are complete, valid
UTF-8; it then advances exactly n. Anything else makes the whole decode
Nothing. No byte outside [offset, offset+n) is ever read — in particular
not past the end of the buffer, nor past the end of a slice into its
parent. The sibling DecodeStringStrictKernelTest runs the identical case
table through the kernel path; both must agree.

T1 truncated at buffer end, T2 truncated inside the range, T3 offset
discipline, T4 slices, T5 large buffers, T6 padding sweep, T7 malformed
UTF-8, T8 length-prefixed, T9 controls. Every line must say "ok".

NOTE (2026-10-08): with the current compiler `Bytes.Decode.string` never
fuses — the inliner expands `D.decode`/`D.string` into kernel calls
before bytes fusion runs, so no decode in this file reaches
bf.read.utf8 and the whole file exercises the kernel path. It is kept
WITHOUT CHECK-MLIR pins so it starts covering the fused path as soon as
string decodes fuse; the fused lowering itself is covered meanwhile by
test/bf-codegen/bf_read_utf8_strict.mlir and by K8d (kernel vs
elm_utf8_decode agreement).
-}

-- CHECK: bad: []
-- CHECK: t1_c3: "ok"
-- CHECK: t1_e2: "ok"
-- CHECK: t1_f0: "ok"
-- CHECK: t1_e2_82: "ok"
-- CHECK: t1_f0_9f: "ok"
-- CHECK: t1_f0_9f_98: "ok"
-- CHECK: t1_a_c3: "ok"
-- CHECK: t1_a_e2_82: "ok"
-- CHECK: t1_a_f0_9f_98: "ok"
-- CHECK: t2_c3a9_1: "ok"
-- CHECK: t2_smile_2: "ok"
-- CHECK: t2_smile_3: "ok"
-- CHECK: t3_cut_then_u8: "ok"
-- CHECK: t3_ok_then_u8: "ok"
-- CHECK: t3_cut_twice: "ok"
-- CHECK: t3_loop_cut: "ok"
-- CHECK: t3_loop_ok: "ok"
-- CHECK: t7_80: "ok"
-- CHECK: t7_bf: "ok"
-- CHECK: t7_f8: "ok"
-- CHECK: t7_ff: "ok"
-- CHECK: t7_80_abc: "ok"
-- CHECK: t7_overlong2: "ok"
-- CHECK: t7_overlong3: "ok"
-- CHECK: t7_overlong4: "ok"
-- CHECK: t7_surrogate: "ok"
-- CHECK: t7_gt10ffff: "ok"
-- CHECK: t7_badcont: "ok"
-- CHECK: t7_badcont_mid: "ok"
-- CHECK: t8_prefix_over: "ok"
-- CHECK: t8_prefix_cut: "ok"
-- CHECK: t8_prefix_ok: "ok"
-- CHECK: t9_e_acute: "ok"
-- CHECK: t9_smile: "ok"
-- CHECK: t9_smile_len: "ok"
-- CHECK: t9_mid_valid: "ok"
-- CHECK: t9_ascii: "ok"
-- CHECK: t9_zero: "ok"
-- CHECK: t9_too_long: "ok"
-- CHECK: t9_negative: "ok"
-- CHECK: t5_big_cut: "ok"
-- CHECK: t5_big_ascii: "ok"
-- CHECK: t5_big_ok: "ok"
-- CHECK: t4_slice_cut: "ok"
-- CHECK: t4_slice_off_cut: "ok"
-- CHECK: t4_slice_ok: "ok"
-- CHECK: t4_tiny_slice_cut: "ok"
-- CHECK: t5_big_slice_cut: "ok"
-- CHECK: t6_cut_sweep_bad: 0
-- CHECK: t6_ok_sweep_bad: 0

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


bs : List Int -> Bytes
bs xs =
    E.encode (E.sequence (List.map E.unsignedInt8 xs))


bigA : String
bigA =
    String.repeat 9000 "A"


big : List Int -> Bytes
big tail =
    E.encode (E.sequence (E.string bigA :: List.map E.unsignedInt8 tail))


verdict : Maybe a -> Maybe a -> String
verdict actual expected =
    if actual == expected then
        "ok"

    else
        "BAD got " ++ Debug.toString actual


main =
    let
        results =
            [ ( "t1_c3", verdict (D.decode (D.string 1) (bs [ 0xC3 ])) (Nothing) )
            , ( "t1_e2", verdict (D.decode (D.string 1) (bs [ 0xE2 ])) (Nothing) )
            , ( "t1_f0", verdict (D.decode (D.string 1) (bs [ 0xF0 ])) (Nothing) )
            , ( "t1_e2_82", verdict (D.decode (D.string 2) (bs [ 0xE2, 0x82 ])) (Nothing) )
            , ( "t1_f0_9f", verdict (D.decode (D.string 2) (bs [ 0xF0, 0x9F ])) (Nothing) )
            , ( "t1_f0_9f_98", verdict (D.decode (D.string 3) (bs [ 0xF0, 0x9F, 0x98 ])) (Nothing) )
            , ( "t1_a_c3", verdict (D.decode (D.string 2) (bs [ 0x41, 0xC3 ])) (Nothing) )
            , ( "t1_a_e2_82", verdict (D.decode (D.string 3) (bs [ 0x41, 0xE2, 0x82 ])) (Nothing) )
            , ( "t1_a_f0_9f_98", verdict (D.decode (D.string 4) (bs [ 0x41, 0xF0, 0x9F, 0x98 ])) (Nothing) )
            , ( "t2_c3a9_1", verdict (D.decode (D.string 1) (bs [ 0xC3, 0xA9 ])) (Nothing) )
            , ( "t2_smile_2", verdict (D.decode (D.string 2) (bs [ 0xF0, 0x9F, 0x98, 0x80 ])) (Nothing) )
            , ( "t2_smile_3", verdict (D.decode (D.string 3) (bs [ 0xF0, 0x9F, 0x98, 0x80 ])) (Nothing) )
            , ( "t3_cut_then_u8", verdict (D.decode (D.map2 Tuple.pair (D.string 1) D.unsignedInt8) (bs [ 0xC3, 0xA9, 0x07 ])) (Nothing) )
            , ( "t3_ok_then_u8", verdict (D.decode (D.map2 Tuple.pair (D.string 2) D.unsignedInt8) (bs [ 0xC3, 0xA9, 0x07 ])) (Just ( "\u{00E9}", 7 )) )
            , ( "t3_cut_twice", verdict (D.decode (D.map2 (++) (D.string 1) (D.string 1)) (bs [ 0xC3, 0xA9 ])) (Nothing) )
            , ( "t3_loop_cut", verdict (D.decode (D.loop ( 2, [] ) (\( n, acc ) -> if n <= 0 then D.succeed (D.Done (List.reverse acc)) else D.map (\s -> D.Loop ( n - 1, s :: acc )) (D.unsignedInt8 |> D.andThen (\len -> D.string len)))) (bs [ 2, 0x68, 0x69, 1, 0xC3 ])) (Nothing) )
            , ( "t3_loop_ok", verdict (D.decode (D.loop ( 2, [] ) (\( n, acc ) -> if n <= 0 then D.succeed (D.Done (List.reverse acc)) else D.map (\s -> D.Loop ( n - 1, s :: acc )) (D.unsignedInt8 |> D.andThen (\len -> D.string len)))) (bs [ 2, 0x68, 0x69, 2, 0xC3, 0xA9 ])) (Just [ "hi", "\u{00E9}" ]) )
            , ( "t7_80", verdict (D.decode (D.string 1) (bs [ 0x80 ])) (Nothing) )
            , ( "t7_bf", verdict (D.decode (D.string 1) (bs [ 0xBF ])) (Nothing) )
            , ( "t7_f8", verdict (D.decode (D.string 1) (bs [ 0xF8 ])) (Nothing) )
            , ( "t7_ff", verdict (D.decode (D.string 1) (bs [ 0xFF ])) (Nothing) )
            , ( "t7_80_abc", verdict (D.decode (D.string 4) (bs [ 0x80, 0x41, 0x42, 0x43 ])) (Nothing) )
            , ( "t7_overlong2", verdict (D.decode (D.string 2) (bs [ 0xC0, 0x80 ])) (Nothing) )
            , ( "t7_overlong3", verdict (D.decode (D.string 3) (bs [ 0xE0, 0x80, 0x80 ])) (Nothing) )
            , ( "t7_overlong4", verdict (D.decode (D.string 4) (bs [ 0xF0, 0x80, 0x80, 0x80 ])) (Nothing) )
            , ( "t7_surrogate", verdict (D.decode (D.string 3) (bs [ 0xED, 0xA0, 0x80 ])) (Nothing) )
            , ( "t7_gt10ffff", verdict (D.decode (D.string 4) (bs [ 0xF4, 0x90, 0x80, 0x80 ])) (Nothing) )
            , ( "t7_badcont", verdict (D.decode (D.string 2) (bs [ 0xC2, 0x00 ])) (Nothing) )
            , ( "t7_badcont_mid", verdict (D.decode (D.string 2) (bs [ 0xC3, 0x41 ])) (Nothing) )
            , ( "t8_prefix_over", verdict (D.decode (D.unsignedInt8 |> D.andThen (\n -> D.string n)) (bs [ 5, 0x68, 0x69 ])) (Nothing) )
            , ( "t8_prefix_cut", verdict (D.decode (D.unsignedInt8 |> D.andThen (\n -> D.string n)) (bs [ 1, 0xC3 ])) (Nothing) )
            , ( "t8_prefix_ok", verdict (D.decode (D.unsignedInt8 |> D.andThen (\n -> D.string n)) (bs [ 2, 0xC3, 0xA9 ])) (Just "\u{00E9}") )
            , ( "t9_e_acute", verdict (D.decode (D.string 2) (bs [ 0xC3, 0xA9 ])) (Just "\u{00E9}") )
            , ( "t9_smile", verdict (D.decode (D.string 4) (bs [ 0xF0, 0x9F, 0x98, 0x80 ])) (Just "\u{1F600}") )
            , ( "t9_smile_len", verdict (D.decode (D.map String.length (D.string 4)) (bs [ 0xF0, 0x9F, 0x98, 0x80 ])) (Just 2) )
            , ( "t9_mid_valid", verdict (D.decode (D.string 4) (bs [ 0x41, 0xC3, 0xA9, 0x42 ])) ("A\u{00E9}B" |> Just) )
            , ( "t9_ascii", verdict (D.decode (D.string 5) (E.encode (E.string "hello"))) (Just "hello") )
            , ( "t9_zero", verdict (D.decode (D.map (\s -> s == "" && String.isEmpty s && String.length s == 0) (D.string 0)) (bs [ 0x41 ])) (Just True) )
            , ( "t9_too_long", verdict (D.decode (D.string 2) (bs [ 0x41 ])) (Nothing) )
            , ( "t9_negative", verdict (D.decode (D.string (-1)) (bs [ 0x41 ])) (Nothing) )
            , ( "t5_big_cut", verdict (D.decode (D.string 9001) (big [ 0xC3 ])) (Nothing) )
            , ( "t5_big_ascii", verdict (D.decode (D.string 9000) (big [ 0xC3 ])) (Just bigA) )
            , ( "t5_big_ok", verdict (D.decode (D.string 9002) (big [ 0xC3, 0xA9 ])) (Just (bigA ++ "\u{00E9}")) )
            , ( "t4_slice_cut", verdict (D.decode (D.bytes 32) (bs (List.repeat 31 0x41 ++ [ 0xC3, 0xA9 ])) |> Maybe.andThen (\sub -> D.decode (D.string 32) sub)) (Nothing) )
            , ( "t4_slice_off_cut", verdict (D.decode (D.map2 (\_ b -> b) D.unsignedInt8 (D.bytes 32)) (bs (0x5A :: List.repeat 31 0x41 ++ [ 0xC3, 0xA9 ])) |> Maybe.andThen (\sub -> D.decode (D.string 32) sub)) (Nothing) )
            , ( "t4_slice_ok", verdict (D.decode (D.bytes 33) (bs (List.repeat 31 0x41 ++ [ 0xC3, 0xA9 ])) |> Maybe.andThen (\sub -> D.decode (D.string 33) sub)) (Just (String.repeat 31 "A" ++ "\u{00E9}")) )
            , ( "t4_tiny_slice_cut", verdict (D.decode (D.bytes 1) (bs [ 0xC3, 0xA9 ]) |> Maybe.andThen (\sub -> D.decode (D.string 1) sub)) (Nothing) )
            , ( "t5_big_slice_cut", verdict (D.decode (D.bytes 9001) (big [ 0xC3, 0xA9 ]) |> Maybe.andThen (\sub -> D.decode (D.string 9001) sub)) (Nothing) )
            ]

        -- T6: ASCII padding of 0..15 bytes then a lone 4-byte lead at the very
        -- end of the buffer (varies what lies after the payload in the heap).
        cutSweep =
            List.range 0 15
                |> List.map (\k -> verdict (D.decode (D.string (k + 1)) (bs (List.repeat k 0x41 ++ [ 0xF0 ]))) Nothing)

        okSweep =
            List.range 0 15
                |> List.map (\k -> verdict (D.decode (D.string (k + 4)) (bs (List.repeat k 0x41 ++ [ 0xF0, 0x9F, 0x98, 0x80 ]))) (Just (String.repeat k "A" ++ "\u{1F600}")))

        cutSweepBad =
            List.length (List.filter ((/=) "ok") cutSweep)

        okSweepBad =
            List.length (List.filter ((/=) "ok") okSweep)

        -- Summary FIRST: the harness shows only the first 500 chars of output.
        _ =
            Debug.log "bad"
                (List.map Tuple.first (List.filter (\( _, v ) -> v /= "ok") results)
                    ++ (if cutSweepBad > 0 then [ "t6_cut_sweep" ] else [])
                    ++ (if okSweepBad > 0 then [ "t6_ok_sweep" ] else [])
                )

        _ =
            List.map (\( l, v ) -> Debug.log l v) results

        _ =
            Debug.log "t6_cut_sweep_bad" cutSweepBad

        _ =
            Debug.log "t6_ok_sweep_bad" okSweepBad
    in
    text "done"
