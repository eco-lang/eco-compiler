module CovBackendSpineTest exposing (main)

{-| Coverage (backend, round 4): result spines of `$sret` workers (functions
returning a 2- or 3-tuple that are called in a let destructuring).

  - `pickB`, `pickBB`: the spine is a `case` on a Bool (a decision-tree Chain),
    so the Bool chain is generated with one result per tuple slot.
  - `tri`, `triWrap`: a 3-tuple spine whose leaf is a call of another `$sret`
    function with the same slots (`trySretFreshLeaf`, `eco.make.tuple3`).
  - `pickS`: the spine is a `case` on a String (a string fan-out with one
    result per slot).

-}

-- CHECK: boolchain: (3,6)
-- CHECK: boolchain2: (10,1)
-- CHECK: tri: (5,6,7)
-- CHECK: triwrap: (0,0,0)
-- CHECK: triwrap2: (2,3,4)
-- CHECK: strcase: [(1,2),(3,4),(0,0)]

import Html exposing (text)


pickB : Bool -> Int -> ( Int, Int )
pickB b n =
    case b of
        True ->
            ( n, n * 2 )

        False ->
            ( n * 10, 1 )


pickBB : Bool -> Bool -> Int -> ( Int, Int )
pickBB a b n =
    case ( a, b ) of
        ( True, True ) ->
            ( n, n * 2 )

        ( False, _ ) ->
            ( n * 10, 1 )

        _ ->
            ( 0, 0 )


tri : Int -> ( Int, Int, Int )
tri n =
    if n > 100 then
        ( 0, 0, n )

    else
        ( n, n + 1, n + 2 )


triWrap : Int -> ( Int, Int, Int )
triWrap n =
    if n < 0 then
        ( 0, 0, 0 )

    else
        tri n


pickS : String -> ( Int, Int )
pickS s =
    case s of
        "a" ->
            ( 1, 2 )

        "b" ->
            ( 3, 4 )

        _ ->
            ( 0, 0 )


sumPickS : String -> Int
sumPickS s =
    let
        ( u, v ) =
            pickS s
    in
    u * 10 + v


main =
    let
        ( a1, b1 ) =
            pickB True 3

        _ =
            Debug.log "boolchain" ( a1, b1 )

        ( a2, b2 ) =
            pickBB False True 1

        _ =
            Debug.log "boolchain2" ( a2, b2 )

        ( x, y, z ) =
            tri 5

        _ =
            Debug.log "tri" ( x, y, z )

        ( p, q, r ) =
            triWrap -1

        _ =
            Debug.log "triwrap" ( p, q, r )

        ( p2, q2, r2 ) =
            triWrap 2

        _ =
            Debug.log "triwrap2" ( p2, q2, r2 )

        _ =
            Debug.log "strcase" (List.map pickS [ "a", "b", "c" ])

        _ =
            sumPickS "a"
    in
    text "done"
