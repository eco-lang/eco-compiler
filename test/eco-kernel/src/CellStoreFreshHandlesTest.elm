module CellStoreFreshHandlesTest exposing (main)

{-| Two stores created in one function must not alias.

This is the pin against the CAF trap: `Eco.CellStore.new` takes an argument
precisely so it cannot be compiled to a memoised constant. If it ever were,
every "fresh" store would be the same object and the compiler's scratch scopes
would silently write through their own stash. The unit suite cannot catch
that — under the pure twin handles are values — so it has to be checked here,
against the real kernel.

Also pins that `disposeThen` is idempotent and returns its second argument,
and that `release` keeps the store it was told to keep.
-}

-- CHECK: CellStoreFreshHandlesTest: True

import Eco.CellStore as CS
import Platform


type alias Cell =
    { v : Int }


{-| Two stores built side by side in ONE function. Writing to one must not be
visible in the other.
-}
independent : Bool
independent =
    let
        a =
            CS.new 8 |> CS.push { v = 1 } |> CS.push { v = 2 }

        b =
            CS.new 8 |> CS.push { v = 100 }

        a2 =
            CS.set 0 { v = 42 } a
    in
    (CS.get 0 a2).v
        == 42
        && (CS.get 0 b).v
        == 100
        && CS.size a2
        == 2
        && CS.size b
        == 1


{-| A store created inside a loop body is a new store each time round.
-}
freshPerCall : Int -> Bool -> Bool
freshPerCall n ok =
    if n <= 0 then
        ok

    else
        let
            st =
                CS.new 4 |> CS.push { v = n }
        in
        -- size 1 every time: a shared store would keep growing
        freshPerCall (n - 1) (ok && CS.size st == 1)


disposal : Bool
disposal =
    let
        dead =
            CS.new 4 |> CS.push { v = 7 }

        keep =
            CS.new 4 |> CS.push { v = 9 }

        kept =
            CS.release dead keep

        twice =
            CS.disposeThen dead (CS.disposeThen dead "ok")
    in
    (CS.get 0 kept).v == 9 && twice == "ok"


result : Bool
result =
    independent && freshPerCall 200 True && disposal


init : () -> ( (), Cmd () )
init _ =
    let
        _ =
            Debug.log "CellStoreFreshHandlesTest" result
    in
    ( (), Cmd.none )


main : Program () () ()
main =
    Platform.worker
        { init = init
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
