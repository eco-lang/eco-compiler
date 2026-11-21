module TaggedUnionConstantPayloadTest exposing (main)

{-| Tagged unions (`TaggedUnions`, HEAP_086) whose bare constructor's field can be a
constant word: `""`, `[]`, `True`/`False`, `()`, and a record holding `""`, with
the bare constructor declared first or between two nullary ones. Each value is
printed and matched with `case`.

Expected output from elm make + node.

-}

-- CHECK: t1: ([J1 "",J1 "x",N1,O1],["J1 ","J1 x","N1","O1"])
-- CHECK: t2: ([J2 "",J2 "x",N2,O2],["J2 ","J2 x","N2","O2"])
-- CHECK: t3: ([J3 [],J3 [1],N3,O3],["J3 0","J3 1","N3","O3"])
-- CHECK: t4: ([J4 True,J4 False,N4,O4],["J4 T","J4 F","N4","O4"])
-- CHECK: t5: ([J5 (),N5,O5],["J5","N5","O5"])
-- CHECK: t6: ([J6 { a = "" },N6,O6],["J6 ","N6","O6"])

import Html exposing (text)


type T1
    = J1 String
    | N1
    | O1


type T2
    = N2
    | J2 String
    | O2


type T3
    = J3 (List Int)
    | N3
    | O3


type T4
    = J4 Bool
    | N4
    | O4


type T5
    = J5 ()
    | N5
    | O5


type T6
    = J6 { a : String }
    | N6
    | O6


s1 : T1 -> String
s1 t =
    case t of
        J1 s ->
            "J1 " ++ s

        N1 ->
            "N1"

        O1 ->
            "O1"


s2 : T2 -> String
s2 t =
    case t of
        J2 s ->
            "J2 " ++ s

        N2 ->
            "N2"

        O2 ->
            "O2"


s3 : T3 -> String
s3 t =
    case t of
        J3 l ->
            "J3 " ++ String.fromInt (List.length l)

        N3 ->
            "N3"

        O3 ->
            "O3"


s4 : T4 -> String
s4 t =
    case t of
        J4 b ->
            if b then
                "J4 T"

            else
                "J4 F"

        N4 ->
            "N4"

        O4 ->
            "O4"


s5 : T5 -> String
s5 t =
    case t of
        J5 () ->
            "J5"

        N5 ->
            "N5"

        O5 ->
            "O5"


s6 : T6 -> String
s6 t =
    case t of
        J6 r ->
            "J6 " ++ r.a

        N6 ->
            "N6"

        O6 ->
            "O6"


main =
    let
        _ =
            Debug.log "t1" ( [ J1 "", J1 "x", N1, O1 ], List.map s1 [ J1 "", J1 "x", N1, O1 ] )

        _ =
            Debug.log "t2" ( [ J2 "", J2 "x", N2, O2 ], List.map s2 [ J2 "", J2 "x", N2, O2 ] )

        _ =
            Debug.log "t3" ( [ J3 [], J3 [ 1 ], N3, O3 ], List.map s3 [ J3 [], J3 [ 1 ], N3, O3 ] )

        _ =
            Debug.log "t4" ( [ J4 True, J4 False, N4, O4 ], List.map s4 [ J4 True, J4 False, N4, O4 ] )

        _ =
            Debug.log "t5" ( [ J5 (), N5, O5 ], List.map s5 [ J5 (), N5, O5 ] )

        _ =
            Debug.log "t6" ( [ J6 { a = "" }, N6, O6 ], List.map s6 [ J6 { a = "" }, N6, O6 ] )
    in
    text ""
