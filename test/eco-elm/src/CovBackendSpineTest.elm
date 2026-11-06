module CovBackendSpineTest exposing (main)

{-| Checks functions that return a tuple chosen by a `case` or `if`, with the
result taken apart by a `let` pattern.

  - `pickB` returns a pair from a `case` on a `Bool`: `(3,6)` for `True 3`.
  - `pickBB` returns a pair from a `case` on a pair of `Bool`s with a wildcard
    branch: `(10,1)` for `False True 1`.
  - `tri` returns a triple from an `if` (`(5,6,7)`), and `triWrap` returns
    either a literal triple or the result of calling `tri`: `(0,0,0)` for `-1`
    and `(2,3,4)` for `2`.
  - `pickS` returns a pair from a `case` on a `String` with a wildcard branch,
    mapped over `"a"`, `"b"` and `"c"`.

Among what is not tested: the result of `sumPickS`, which is computed and
discarded without being logged.

## eco

Backend coverage for the result spines of `$sret` workers, functions returning a 2- or 3-tuple that are called in a let destructuring (compiler/src/Compiler/GenerateMlir/Expr.elm). `pickB` and `pickBB` have a `case` on Bool as the spine (a decision-tree chain with one result per tuple slot); `tri` and `triWrap` have a 3-tuple spine whose leaf calls another `$sret` function with the same slots (`trySretFreshLeaf`, `eco.make.tuple3`); `pickS` has a `case` on String (a string fan-out with one result per slot).

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
