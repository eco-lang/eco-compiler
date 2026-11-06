module PreMonoInlineTest exposing (main)

{-| Small polymorphic functions each used at two different types in one program give the right result at every type.

Each helper is called at two types: `apply` at `Int -> Int` and at `String -> String`,
`swap` at `( Int, String )` and at `( String, Int )`, `firstOr` at `Int` and at `Bool`,
and `twice` at `Int` and at `List Int`. A compiler that resolved both uses of one helper to
a single type would print wrong numbers or fail.

`run` computes every case for one input, reducing each result to an `Int` (a `String` to its
length, a `Bool` to 1 or 0, a list to its sum), and `main` maps it over the inputs 4, 5 and 6
and logs one list per case.

## eco

Runtime differential for the pre-monomorphization inliner
(plans/pre-mono-inline-simplify.md,
compiler/src/Compiler/PreMono/InlineSimplify.elm). It must print the same
numbers with the defaults (post-mono inlining) and with
`ECO_INLINE_PRE_MONO=1 ECO_INLINE_POST_MONO=0`. The pre-mono inliner copies a
callee's body while it still has polymorphic types and solver variables; if two
call sites at different types shared one copy's type nodes they would collapse
onto one instantiation and silently compute wrong answers. Hence every helper
is used at two types. `List.map run inputs` is load-bearing, as in
test/eco-elm/src/PapFastStampTest.elm: a single monomorphic use lets a later
pass fold the question away.

-}

import Html exposing (text)



-- CHECK: applyInt: [9,10,11]
-- CHECK: applyStr: [5,6,7]
-- CHECK: swapA: [12,15,18]
-- CHECK: swapB: [16,20,24]
-- CHECK: firstOrInt: [4,5,6]
-- CHECK: firstOrBool: [1,0,1]
-- CHECK: twiceInt: [32,40,48]
-- CHECK: twiceList: [16,20,24]


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
