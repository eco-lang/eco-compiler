module DeepEqualityTest exposing (main)

{-| UTILS-05 (plans/kernel-lib-bug-fixes.md): `==` on values nested deeper than 100 levels.
elm/core's `_Utils_eqHelp` defers a pair it meets past depth 100 to an explicit stack and
compares it later, so the answer is always exact. eco's `eqHelp` (elm-kernel-cpp
src/core/Utils.cpp) returned `true` at depth > 100 instead, so every unequal row below answered
True; it now defers the pair the same way. Expected values recorded from Elm on node.
test/elm/src/EqDepthCutoffTest.elm pins the same boundary.

-}

-- CHECK: nat 150 vs 200: "False"
-- CHECK: nat 150 vs 150: "True"
-- CHECK: nest 120: "False"
-- CHECK: nest 500 /=: "True"
-- CHECK: record chain 300: "False"
-- CHECK: dict nest 150: "False"

import ConformanceHelp exposing (logAll, worker)
import Dict


type Nat
    = Z
    | S Nat


nat : Int -> Nat
nat n =
    List.foldl (\_ acc -> S acc) Z (List.range 1 n)


type Nest
    = Leaf Int
    | Wrap Nest


nest : Int -> Int -> Nest
nest n leaf =
    List.foldl (\_ acc -> Wrap acc) (Leaf leaf) (List.range 1 n)


type Chain
    = Chain { next : Maybe Chain, v : Int }


chain : Int -> Int -> Chain
chain n bottom =
    List.foldl (\_ acc -> Chain { next = Just acc, v = 0 }) (Chain { next = Nothing, v = bottom }) (List.range 1 n)


bool : Bool -> String
bool b =
    if b then
        "True"

    else
        "False"


report : ()
report =
    logAll
        [ ( "nat 150 vs 200", bool (nat 150 == nat 200) )
        , ( "nat 150 vs 150", bool (nat 150 == nat 150) )
        , ( "nest 120", bool (nest 120 1 == nest 120 2) )
        , ( "nest 500 /=", bool (nest 500 1 /= nest 500 2) )
        , ( "record chain 300", bool (chain 300 1 == chain 300 2) )
        , ( "dict nest 150"
          , bool
                (Dict.fromList [ ( 1, nest 150 1 ), ( 2, Leaf 0 ) ]
                    == Dict.fromList [ ( 1, nest 150 2 ), ( 2, Leaf 0 ) ]
                )
          )
        ]


main : Program () () ()
main =
    worker report
