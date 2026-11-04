module CovBackendTailSplitTest exposing (main)

{-| Coverage (backend, round 4): tail-recursive functions whose tuple or
single-constructor parameters are candidates for scalar splitting
(`TailRec.splitArgPolicy`, `compileSplitTailArg`).

  - `viaHelper`: the tail argument for a constructor parameter is a call of an
    ordinary function returning the constructor, not the constructor itself,
    so the split is refused.
  - `picky`: the tail argument for a tuple parameter is, on one path, a
    let-bound variable holding a call's result, so the split is refused.
  - `triple3`: a let-bound tuple3 literal that is read by a destructuring and
    passed as the tail argument.
  - `triple`: a tuple3 accumulator passed on through a let-bound tuple literal.
  - `escaping`: a let-bound tuple literal that is both the tail argument and
    stored in a list, so it is built on the heap and its fields are read back.

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
