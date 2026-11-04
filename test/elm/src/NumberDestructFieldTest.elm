module NumberDestructFieldTest exposing (main)

{-| Number values destructured through compound constructor fields (finding
F2). Each `let`-bound value has a `number` variable inside a tuple, list,
record or `Maybe` field of a constructor, is destructured with a constructor
pattern, and is used at `Float`; the nested tuple pair is used at both `Float`
and `Int`. Before the fix the destructured names kept the `Int` default and
compilation failed on a kernel signature mismatch.
-}

-- CHECK: tuple field: 2.5
-- CHECK: list field: 1.25
-- CHECK: record field: 4.5
-- CHECK: maybe field: 5.5
-- CHECK: nested: (3.5,4)

import Html exposing (text)


type T a
    = T ( a, Int ) Int


type L a
    = L (List a) Int


type R a
    = R { v : a } Int


type M a
    = M (Maybe a) Int


type N a b
    = N ( ( a, a ), b )


main =
    let
        tt =
            T ( 2, 3 ) 0

        (T ( t, _ ) _) =
            tt

        ll =
            L [ 1 ] 0

        (L xs _) =
            ll

        rr =
            R { v = 4 } 0

        (R r _) =
            rr

        mm =
            M (Just 5) 0

        (M m _) =
            mm

        n =
            N ( ( 1, 2 ), 3 )

        (N ( ( a, b ), c )) =
            n

        _ =
            Debug.log "tuple field" (t + 0.5)

        _ =
            Debug.log "list field" (List.foldl (+) 0.25 xs)

        _ =
            Debug.log "record field" (r.v + 0.5)

        _ =
            Debug.log "maybe field"
                (case m of
                    Just z ->
                        z + 0.5

                    Nothing ->
                        0.5
                )

        _ =
            Debug.log "nested" ( a + b + 0.5, c + 1 )
    in
    text "done"
