module WideClosureGcTest exposing (main)

{-| 200 arity-28 closures (typed kinds at slots 20..27) live across a minor and a
major GC, then saturated. Green at P2.
-}

-- CHECK: WideClosureGcTest minor: 1
-- CHECK: WideClosureGcTest major: 1
-- CHECK: WideClosureGcTest value: 8956201

import Eco.GC as GC
import Platform
import Task


big : Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int
big a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17 a18 a19 a20 a21 a22 a23 a24 a25 a26 a27 =
    a0 * 1 + a1 * 2 + a2 * 3 + a3 * 4 + a4 * 5 + a5 * 6 + a6 * 7 + a7 * 8 + a8 * 9 + a9 * 10 + a10 * 11 + a11 * 12 + a12 * 13 + a13 * 14 + a14 * 15 + a15 * 16 + a16 * 17 + a17 * 18 + a18 * 19 + a19 * 20 + a20 * 21 + a21 * 22 + a22 * 23 + a23 * 24 + a24 * 25 + a25 * 26 + a26 * 27 + a27 * 28


mk : Int -> (Int -> Int)
mk k =
    let
        h =
            big (k + 0) (k + 1) (k + 2) (k + 3) (k + 4) (k + 5) (k + 6) (k + 7) (k + 8) (k + 9) (k + 10) (k + 11) (k + 12) (k + 13) (k + 14) (k + 15) (k + 16) (k + 17) (k + 18) (k + 19)
    in
    h (k + 20) (k + 21) (k + 22) (k + 23) (k + 24) (k + 25) (k + 26)


type Msg
    = Done Int Int Int


churn : Int -> Int
churn k =
    List.range 1 (20000 + k) |> List.map String.fromInt |> List.length


init : () -> ( (), Cmd Msg )
init _ =
    let
        base =
            1 + List.length [ () ] - 1

        objs =
            List.map mk (List.range base 200)

        task =
            GC.minorGC
                |> Task.andThen (\mi -> GC.majorGC |> Task.map (\ma -> ( mi.collected, ma.collected )))
                |> Task.map (\( mi, ma ) -> Done mi ma (churn mi + List.sum (List.map (\g -> g 5) objs)))
    in
    ( (), Task.perform identity task )


update : Msg -> () -> ( (), Cmd Msg )
update msg _ =
    case msg of
        Done mi ma v ->
            let
                _ =
                    Debug.log "WideClosureGcTest minor" mi

                _ =
                    Debug.log "WideClosureGcTest major" ma

                _ =
                    Debug.log "WideClosureGcTest value" v
            in
            ( (), Cmd.none )


main : Program () () Msg
main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }
