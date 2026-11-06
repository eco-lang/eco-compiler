module CovBackendTailSplitTest exposing (main)

{-| Checks tail-recursive functions whose accumulator is a tuple or a
single-constructor custom type, built in several ways before the recursive call.

  - `viaHelper` passes on either a `P` built directly or one returned by the
    function `mkP` (10).
  - `picky` passes on either a pair literal or, on one step, a let-bound pair
    returned by `flipT` (7).
  - `triple3` binds the next triple in a `let`, takes it apart with a pattern,
    and passes the bound triple on (`(3,6,"xxx")`).
  - `triple` passes on a let-bound triple (`(5,10,"xxxxx")`).
  - `escaping` passes on a let-bound pair that is also added to a list, and the
    list is returned (`(10,[(1,4),(2,7),(3,9),(4,10)])`).

## eco

Backend coverage for scalar splitting of tail-recursive parameters (`splitArgPolicy` and `compileSplitTailArg` in compiler/src/Compiler/GenerateMlir/TailRec.elm). In `viaHelper` and `picky` the tail argument is, on some path, a call's result rather than a constructor or literal, so the split is refused. `triple3` and `triple` pass a let-bound tuple3 literal. In `escaping` the tail argument is also stored in a list, so it is built on the heap and its fields are read back.

-}

-- CHECK: viahelper: 10
-- CHECK: picky: 7
-- CHECK: triple3: (3,6,"xxx")
-- CHECK: triple: (5,10,"xxxxx")
-- CHECK: escaping: (10,[(1,4),(2,7),(3,9),(4,10)])

import Html exposing (text)


type P
    = P Int Int


mkP : Int -> Int -> P
mkP a b =
    if a > 1000 then
        P 0 0

    else
        P (a + 1) (b + a)


viaHelper : Int -> P -> Int
viaHelper n p =
    case p of
        P a b ->
            if n <= 0 then
                a + b

            else if n == 2 then
                viaHelper (n - 1) (P (a + 1) b)

            else
                viaHelper (n - 1) (mkP a b)


flipT : Int -> Int -> ( Int, Int )
flipT x y =
    if x > 1000 then
        ( 0, 0 )

    else
        ( x, y )


picky : Int -> ( Int, Int ) -> Int
picky n p =
    case p of
        ( a, b ) ->
            if n <= 0 then
                a + b

            else if n == 3 then
                let
                    r =
                        flipT b a
                in
                if Tuple.first r > 100 then
                    0

                else
                    picky (n - 1) r

            else
                picky (n - 1) ( a + 1, b )


triple3 : Int -> ( Int, Int, String ) -> ( Int, Int, String )
triple3 n acc =
    case acc of
        ( a, b, s ) ->
            if n <= 0 then
                acc

            else
                let
                    nxt =
                        ( a + 1, b + 2, s ++ "x" )

                    ( x, _, _ ) =
                        nxt
                in
                if x > 99 then
                    ( 0, 0, "" )

                else
                    triple3 (n - 1) nxt


triple : Int -> ( Int, Int, String ) -> ( Int, Int, String )
triple n acc =
    case acc of
        ( a, b, s ) ->
            if n <= 0 then
                acc

            else
                let
                    nxt =
                        ( a + 1, b + 2, s ++ "x" )
                in
                triple (n - 1) nxt


escaping : Int -> ( Int, Int ) -> List ( Int, Int ) -> ( Int, List ( Int, Int ) )
escaping n acc seen =
    case acc of
        ( a, b ) ->
            if n <= 0 then
                ( b, List.reverse seen )

            else
                let
                    nxt =
                        ( a + 1, b + n )
                in
                escaping (n - 1) nxt (nxt :: seen)


main =
    let
        _ =
            Debug.log "viahelper" (viaHelper 3 (P 1 2))

        _ =
            Debug.log "picky" (picky 5 ( 1, 2 ))

        _ =
            Debug.log "triple3" (triple3 3 ( 0, 0, "" ))

        _ =
            Debug.log "triple" (triple 5 ( 0, 0, "" ))

        _ =
            Debug.log "escaping" (escaping 4 ( 0, 0 ) [])
    in
    text "done"
