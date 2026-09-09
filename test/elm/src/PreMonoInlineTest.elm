module PreMonoInlineTest exposing (main)

{-| Runtime differential for the PRE-monomorphization inliner
(`plans/pre-mono-inline-simplify.md` §6).

The pin must print the SAME numbers in both position arms:

  - arm LATE — defaults: `preMono=0`, `postMono=1`
  - arm EARLY — `ECO_INLINE_PRE_MONO=1 ECO_INLINE_POST_MONO=0`

**What makes this a real test and not a smoke test.** `InlineSimplify` copies a
callee's body BEFORE monomorphization, so the copy still carries the callee's
POLYMORPHIC types and its solver variables. If two call sites at different
types share one copied body's type nodes, the two sites collapse onto a single
instantiation — a wrong ANSWER, silently, and one that only shows up when a
polymorphic function is used at more than one type in the same program.

So every helper below is deliberately used at two or more DIFFERENT types:

  - `apply` at `Int -> Int` and at `String -> String`;
  - `swap` at `( Int, String )` and at `( String, Int )`;
  - `firstOr` at `Int` and at `Bool`;
  - `twice` at `Int` and at `List Int`.

Results are reduced to Ints (or to a String's length) before logging, so a
CHECK line does not depend on how `Debug.log` renders a container.

`List.map run inputs` is load-bearing, as in `PapFastStampTest`: a single
monomorphic use lets a later pass fold the question away.

-}

import Html exposing (text)



-- CHECK: applyInt: [9, 10, 11]
-- CHECK: applyStr: [5, 6, 7]
-- CHECK: swapA: [12, 15, 18]
-- CHECK: swapB: [16, 20, 24]
-- CHECK: firstOrInt: [4, 5, 6]
-- CHECK: firstOrBool: [1, 0, 1]
-- CHECK: twiceInt: [32, 40, 48]
-- CHECK: twiceList: [16, 20, 24]


apply : (a -> b) -> a -> b
apply f x =
    f x


swap : ( a, b ) -> ( b, a )
swap ( a, b ) =
    ( b, a )


firstOr : a -> List a -> a
firstOr fallback xs =
    case xs of
        first :: _ ->
            first

        [] ->
            fallback


twice : (a -> a) -> a -> a
twice f x =
    f (f x)


double : Int -> Int
double n =
    n * 2


addOne : Int -> Int
addOne n =
    n + 1


shout : String -> String
shout s =
    s ++ "!"


appendSelf : List Int -> List Int
appendSelf xs =
    xs ++ xs


run : Int -> { applyInt : Int, applyStr : Int, swapA : Int, swapB : Int, firstOrInt : Int, firstOrBool : Int, twiceInt : Int, twiceList : Int }
run n =
    let
        -- swap at ( Int, String ) then at ( String, Int )
        ( sa, sb ) =
            swap ( n, String.repeat n "x" )

        ( sc, sd ) =
            swap ( String.repeat n "y", n * 2 )
    in
    { applyInt = apply addOne (n + 4)
    , applyStr = String.length (apply shout (String.repeat n "z"))
    , swapA = String.length sa + sb * 2
    , swapB = sc + 2 * String.length sd
    , firstOrInt = firstOr 0 [ n, n + 1 ]
    , firstOrBool =
        if firstOr False [ modBy 2 n == 0, False ] then
            1

        else
            0
    , twiceInt = twice double (n * 2)
    , twiceList = List.sum (twice appendSelf [ n ])
    }


inputs : List Int
inputs =
    [ 4, 5, 6 ]


main =
    let
        results =
            List.map run inputs

        _ =
            Debug.log "applyInt" (List.map .applyInt results)

        _ =
            Debug.log "applyStr" (List.map .applyStr results)

        _ =
            Debug.log "swapA" (List.map .swapA results)

        _ =
            Debug.log "swapB" (List.map .swapB results)

        _ =
            Debug.log "firstOrInt" (List.map .firstOrInt results)

        _ =
            Debug.log "firstOrBool" (List.map .firstOrBool results)

        _ =
            Debug.log "twiceInt" (List.map .twiceInt results)

        _ =
            Debug.log "twiceList" (List.map .twiceList results)
    in
    text "done"
