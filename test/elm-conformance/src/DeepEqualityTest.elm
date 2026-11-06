module DeepEqualityTest exposing (main)

{-| `==` and `/=` give the exact answer on values nested more than 100 levels deep.

The fixtures are built by folding: `nat n` is `n` applications of `S` to `Z`, `nest n leaf` is
`n` `Wrap`s around `Leaf leaf`, and `chain n bottom` is `n` records linked through
`next = Just ...`, ending in one whose `v` is `bottom`.

  - `nat 150 vs 200`: two naturals of different depth are not equal.
  - `nat 150 vs 150`: two naturals of the same depth are equal.
  - `nest 120` and `nest 500 /=`: values that differ only in the leaf, 120 and 500 levels down,
    are not equal.
  - `record chain 300`: record chains that differ only in the innermost `v` are not equal.
  - `dict nest 150`: two Dicts whose values under key 1 differ 150 levels down are not equal.
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
