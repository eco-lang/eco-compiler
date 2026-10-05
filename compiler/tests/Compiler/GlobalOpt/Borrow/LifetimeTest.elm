module Compiler.GlobalOpt.Borrow.LifetimeTest exposing (suite)

{-| Tests for `Compiler.GlobalOpt.Borrow.Lifetime`, the lattice from which
borrow inference decides whether a resource is dead at a point. They guard
against `endsBefore` reporting a resource dead while it is still live,
`onBoundary` missing or inventing a last use, and `join` and `leq` ceasing to
agree with each other.

The fixture is the brute-force model in `Compiler.GlobalOpt.Borrow.SkelFuzz`,
whose docstring defines its terms: a _skeleton_ is a piece of code reduced to
sequences and alternatives, an _execution_ is one run through it, a _live set_
is the leaves at which a resource is used, and a _probe_ is a leaf path or a
proper prefix of one. `SkelFuzz.refEndsBefore` and `SkelFuzz.refOnBoundary`
answer the lattice's two questions by looking at every execution. Every
lifetime these tests build from a live set comes from `SkelFuzz.fromPaths`, so
it is `LEmpty` or `LLocal`, never `LParams`.

What the tests establish:

  - `batteryTest`: for every skeleton in `SkelFuzz.allSkels` (every skeleton of
    depth at most 2 with sequences of one or two children and alternatives of
    two arms), every subset of its leaves as a live set, and every probe,
    `endsBefore` and `onBoundary` give the same answers as the reference. It is
    a fixed enumeration, so it covers all of these however many fuzz runs are
    asked for.
  - The law tests in `lawsTests`, each over random `Sample`s: `join` is
    associative, commutative and idempotent; `join a LEmpty` is `a`; `leq a b`
    holds exactly when `join a b` is `eq` to `b`; `leq` is reflexive, and
    transitive on the triples where both premises hold; and `join a b` is
    `leq`-above both `a` and `b`. Where a law equates two lifetimes, they are
    compared with `eq`, not `==`.
  - Also in `lawsTests`: the same agreement with the reference as the battery,
    for one random live set and probe of a skeleton of depth at most 3 from
    `SkelFuzz.skelFuzzer`.
  - Also in `lawsTests`: `join (LParams {7}) a` is `eq` to `LParams {7}`, and
    for a probe `p`, `onBoundary (fromPath p) p` is `True` and
    `endsBefore (fromPath p) p` is `False`.
  - Pinned case 1: a resource used only on arm 0 of alternatives node 0 is dead
    at arm 1.
  - Pinned case 2: for uses in children 0 and 1 of sequence node 0, the
    resource is not dead at child 0 and child 0 is not on the boundary, while
    child 1 is.
  - Pinned case 3: a lifetime ending inside child 0 of sequence node 0 is dead
    at the empty path, the end of the whole body.
  - Pinned case 4: `endsBefore` is `True` for `LEmpty` and `False` for
    `LParams {3}` at each of `[]`, `[Seq 0 0]` and `[Arm 1 1]`.
  - Pinned case 5: joining the eight `fromPath` lifetimes that end on arms 0 to
    7 of node 0 in ascending and in descending order gives `eq` results, not
    dead at the end point on each of those arms, and dead on arm 8. The two orders build the arm
    `Dict` by different insertion sequences; whether its internal shape
    differs is not observable here, and Elm's `==` compares `Dict`s by
    contents, so this does not single out a dependence on `Dict` shape.

Among what is not tested: `joinAll`; no test states that `join LEmpty a` is
`a` (only `join a LEmpty`); `onBoundary` of `LParams`; any law over `LParams`
values except that `join (LParams {7}) a` is `LParams {7}`; a sequence step
meeting an alternatives step at the same position, which no skeleton here
produces; and `eq` itself, which the laws compare with and which is defined
from `leq`.

-}

import Compiler.GlobalOpt.Borrow.Lifetime as L exposing (Life(..), Lifetime(..), Path, Step(..))
import Compiler.GlobalOpt.Borrow.SkelFuzz as SF exposing (Skel)
import Expect
import Fuzz exposing (Fuzzer)
import Set
import Test exposing (Test)


{-| All the lifetime tests: the exhaustive battery, the fuzzed laws and the
pinned cases.
-}
suite : Test
suite =
    Test.describe "Borrow.Lifetime"
        [ batteryTest
        , lawsTests
        , regressions
        ]



-- EXHAUSTIVE BATTERY


{-| The exhaustive comparison of `endsBefore` and `onBoundary` with the
reference model over every skeleton in `SkelFuzz.allSkels`, as one test that
expects no disagreement and lists every one it finds.
-}
batteryTest : Test
batteryTest =
    Test.test "endsBefore/onBoundary match the brute-force reference over all depth-≤2 skeletons" <|
        \_ ->
            Expect.equal [] (List.concatMap checkSkel SF.allSkels)


{-| Returns a message for each disagreement with the reference model in `skel`.
For every subset of its leaves as a live set and every probe, there is one
message when `endsBefore` differs from `refEndsBefore` and one when
`onBoundary` differs from `refOnBoundary`, so the list is empty when all agree.
-}
checkSkel : Skel -> List String
checkSkel skel =
    let
        leaves =
            SF.leafPaths skel

        execs =
            SF.executions skel

        probes =
            SF.allProbes skel
    in
    List.concatMap
        (\s ->
            let
                lt =
                    SF.fromPaths s
            in
            List.concatMap
                (\p ->
                    let
                        eb =
                            L.endsBefore lt p

                        rb =
                            SF.refEndsBefore execs s p

                        ob =
                            L.onBoundary lt p

                        rob =
                            SF.refOnBoundary execs s p
                    in
                    (if eb == rb then
                        []

                     else
                        [ "endsBefore S=" ++ pathsStr s ++ " p=" ++ pathStr p ++ " got=" ++ boolStr eb ++ " ref=" ++ boolStr rb ]
                    )
                        ++ (if ob == rob then
                                []

                            else
                                [ "onBoundary S=" ++ pathsStr s ++ " p=" ++ pathStr p ++ " got=" ++ boolStr ob ++ " ref=" ++ boolStr rob ]
                           )
                )
                probes
        )
        (SF.subsets leaves)



-- FUZZED LAWS


{-| One random case for the law tests: a skeleton, three lifetimes built from
sets of its leaves, and a probe of it.

`s` is the list of leaves `a` is built from.

-}
type alias Sample =
    { skel : Skel
    , a : Lifetime
    , b : Lifetime
    , cc : Lifetime
    , s : List Path
    , p : Path
    }


{-| Produces a fuzzer of sublists of `items`, each item kept or dropped at
random, in their original order.
-}
subsetFuzzer : List a -> Fuzzer (List a)
subsetFuzzer items =
    Fuzz.map
        (\bools ->
            List.map2 Tuple.pair bools items
                |> List.filter Tuple.first
                |> List.map Tuple.second
        )
        (Fuzz.listOfLength (List.length items) Fuzz.bool)


{-| A fuzzer of `Sample`s over skeletons of depth at most 3 from
`SkelFuzz.skelFuzzer`, with three leaf subsets chosen independently and a probe
chosen from all of the skeleton's probes.
-}
sampleFuzzer : Fuzzer Sample
sampleFuzzer =
    SF.skelFuzzer 3
        |> Fuzz.andThen
            (\skel ->
                let
                    leaves =
                        SF.leafPaths skel

                    probes =
                        SF.allProbes skel
                in
                Fuzz.map4
                    (\sA sB sC p -> mkSample skel sA sB sC p)
                    (subsetFuzzer leaves)
                    (subsetFuzzer leaves)
                    (subsetFuzzer leaves)
                    (Fuzz.oneOfValues probes)
            )


{-| Builds a `Sample` from `skel`, the leaf subsets `sA`, `sB` and `sC` (the
live sets of `a`, `b` and `cc`; `sA` is also kept as `s`), and probe `p`.
-}
mkSample : Skel -> List Path -> List Path -> List Path -> Path -> Sample
mkSample skel sA sB sC p =
    { skel = skel
    , a = SF.fromPaths sA
    , b = SF.fromPaths sB
    , cc = SF.fromPaths sC
    , s = sA
    , p = p
    }


{-| The fuzzed tests: the lattice laws of `join` and `leq`, agreement with the
reference model on skeletons of depth at most 3, `LParams` absorbing a
lifetime, and `fromPath p` ending exactly at `p`.
-}
lawsTests : Test
lawsTests =
    Test.describe "lattice laws (checked with eq, never ==)"
        [ Test.fuzz sampleFuzzer "join associative" <|
            \{ a, b, cc } ->
                expectEq (L.join (L.join a b) cc) (L.join a (L.join b cc))
        , Test.fuzz sampleFuzzer "join commutative" <|
            \{ a, b } -> expectEq (L.join a b) (L.join b a)
        , Test.fuzz sampleFuzzer "join idempotent" <|
            \{ a } -> expectEq (L.join a a) a
        , Test.fuzz sampleFuzzer "LEmpty is join identity" <|
            \{ a } -> expectEq (L.join a LEmpty) a
        , Test.fuzz sampleFuzzer "absorption: leq a b == eq (join a b) b" <|
            \{ a, b } ->
                Expect.equal (L.leq a b) (L.eq (L.join a b) b)
        , Test.fuzz sampleFuzzer "leq reflexive" <|
            \{ a } -> Expect.equal True (L.leq a a)
        , Test.fuzz sampleFuzzer "leq transitive on holding triples" <|
            \{ a, b, cc } ->
                if L.leq a b && L.leq b cc then
                    Expect.equal True (L.leq a cc)

                else
                    Expect.pass
        , Test.fuzz sampleFuzzer "join is an upper bound: a ≤ a⊔b and b ≤ a⊔b" <|
            \{ a, b } ->
                Expect.equal ( True, True )
                    ( L.leq a (L.join a b), L.leq b (L.join a b) )
        , Test.fuzz sampleFuzzer "endsBefore/onBoundary agree with the reference (depth 3)" <|
            \{ skel, s, p } ->
                let
                    execs =
                        SF.executions skel

                    lt =
                        SF.fromPaths s
                in
                Expect.equal
                    ( L.endsBefore lt p, L.onBoundary lt p )
                    ( SF.refEndsBefore execs s p, SF.refOnBoundary execs s p )
        , Test.fuzz sampleFuzzer "LParams absorbs any LLocal/LEmpty" <|
            \{ a } ->
                let
                    lp =
                        LParams (Set.singleton 7)
                in
                expectEq (L.join lp a) lp
        , Test.fuzz sampleFuzzer "fromPath p: onBoundary True, endsBefore False at p" <|
            \{ p } ->
                Expect.equal ( True, False )
                    ( L.onBoundary (L.fromPath p) p, L.endsBefore (L.fromPath p) p )
        ]



-- PINNED CASES


{-| Five hand-written cases, each pinning answers of `endsBefore`, `onBoundary`
or `join` on small lifetimes.
-}
regressions : Test
regressions =
    Test.describe "pinned regressions"
        [ Test.test "1: untouched arm is dead (L ≺ p is NOT ¬(p ≤ L))" <|
            \_ ->
                Expect.equal True
                    (L.endsBefore (SF.fromPaths [ [ Arm 0 0 ] ]) [ Arm 0 1 ])
        , Test.test "2: later sibling erases earlier branch" <|
            \_ ->
                let
                    lt =
                        SF.fromPaths [ [ Seq 0 0 ], [ Seq 0 1 ] ]
                in
                Expect.equal
                    { ebLeft = False, obLeft = False, obRight = True }
                    { ebLeft = L.endsBefore lt [ Seq 0 0 ]
                    , obLeft = L.onBoundary lt [ Seq 0 0 ]
                    , obRight = L.onBoundary lt [ Seq 0 1 ]
                    }
        , Test.test "3: interior death vs node completion" <|
            \_ ->
                Expect.equal True
                    (L.endsBefore (LLocal (InSeq 0 0 Star)) [])
        , Test.test "4: LEmpty dead everywhere, LParams live everywhere" <|
            \_ ->
                let
                    probes =
                        [ [], [ Seq 0 0 ], [ Arm 1 1 ] ]

                    lp =
                        LParams (Set.singleton 3)
                in
                Expect.equal ( True, False )
                    ( List.all (\p -> L.endsBefore LEmpty p) probes
                    , List.any (\p -> L.endsBefore lp p) probes
                    )
        , Test.test "5: join of eight arms is independent of the order they are joined in" <|
            \_ ->
                let
                    point i =
                        [ Arm 0 i, Seq (i + 1) 0 ]

                    arm i =
                        L.fromPath (point i)

                    joinAllOf is =
                        List.foldl (\i acc -> L.join (arm i) acc) LEmpty is

                    up =
                        joinAllOf (List.range 0 7)

                    down =
                        joinAllOf (List.reverse (List.range 0 7))
                in
                Expect.equal ( True, True, True )
                    ( L.eq up down
                    , L.endsBefore up (point 8)
                    , List.all (\i -> not (L.endsBefore up (point i))) (List.range 0 7)
                    )
        ]



-- HELPERS


{-| Returns a pass when `a` and `b` are `eq`, and otherwise a failure showing
both. A local lifetime is shown only as `LLocal(..)`, so the message does not
say how two local lifetimes differ.
-}
expectEq : Lifetime -> Lifetime -> Expect.Expectation
expectEq a b =
    if L.eq a b then
        Expect.pass

    else
        Expect.fail ("not eq: " ++ ltStr a ++ " vs " ++ ltStr b)


{-| Returns `"T"` or `"F"`, for failure messages.
-}
boolStr : Bool -> String
boolStr b =
    if b then
        "T"

    else
        "F"


{-| Returns `step` in short form for failure messages: `S` for a sequence step
or `A` for an arm step, then the node id and the index separated by a dot.
-}
stepStr : Step -> String
stepStr step =
    case step of
        Seq n i ->
            "S" ++ String.fromInt n ++ "." ++ String.fromInt i

        Arm n i ->
            "A" ++ String.fromInt n ++ "." ++ String.fromInt i


{-| Returns `p` as its steps in `stepStr` form, comma-separated in brackets.
-}
pathStr : Path -> String
pathStr p =
    "[" ++ String.join "," (List.map stepStr p) ++ "]"


{-| Returns `ps` as paths in `pathStr` form, semicolon-separated in braces.
-}
pathsStr : List Path -> String
pathsStr ps =
    "{" ++ String.join ";" (List.map pathStr ps) ++ "}"


{-| Returns `lt` in short form for failure messages. `LParams` shows its set of
positions; `LLocal` is shown as `LLocal(..)`, with nothing of its `Life`.
-}
ltStr : Lifetime -> String
ltStr lt =
    case lt of
        LEmpty ->
            "LEmpty"

        LParams s ->
            "LParams{" ++ String.join "," (List.map String.fromInt (Set.toList s)) ++ "}"

        LLocal _ ->
            "LLocal(..)"
