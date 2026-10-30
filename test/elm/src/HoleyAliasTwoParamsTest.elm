module HoleyAliasTwoParamsTest exposing (main)

{-| Regression: multi-parameter Holey type alias in a constructor field.

Analysis.convertCanTypeNameToMVarId used to bind every alias formal parameter
to the one dummy id TypeIds.firstMVarId, so the ctor-shape table resolved
every parameter of `Pair a b` to the same (last) argument: `Pair Int String`
became `( String, String )`. Each formal now gets its own id by position.
`GBox` crosses the parameters (`Pair x y`, `Rec y x`).

-}

import Html exposing (text)


-- CHECK: pairInt: 42
-- CHECK: pairStr: "hi"
-- CHECK: recFloat: 2.5
-- CHECK: recInt: 7
-- CHECK: box: Box (42,"hi")
-- CHECK: rbox: RBox { first = 7, second = 2.5 }


type alias Pair a b =
    ( a, b )


type alias Rec a b =
    { first : a, second : b }


type Box
    = Box (Pair Int String)


type RBox
    = RBox (Rec Int Float)


type GBox x y
    = GBox (Pair x y) (Rec y x)


unbox : Box -> ( Int, String )
unbox (Box ( n, s )) =
    ( n + 0, s ++ "" )


runbox : RBox -> ( Float, Int )
runbox (RBox r) =
    ( r.second * 1.0, r.first * 1 )


gfirst : GBox Int Float -> Int
gfirst (GBox ( a, _ ) _) =
    a + 0


main =
    let
        ( n, s ) =
            unbox (Box ( 42, "hi" ))

        ( f, i ) =
            runbox (RBox { first = 7, second = 2.5 })

        _ =
            Debug.log "pairInt" n

        _ =
            Debug.log "pairStr" s

        _ =
            Debug.log "recFloat" f

        _ =
            Debug.log "recInt" (i + gfirst (GBox ( 0, 1.5 ) { first = 1.5, second = 0 }))

        _ =
            Debug.log "box" (Box ( 42, "hi" ))

        _ =
            Debug.log "rbox" (RBox { first = 7, second = 2.5 })
    in
    text "done"
