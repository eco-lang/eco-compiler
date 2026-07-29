module Compiler.GlobalOpt.Borrow.LifetimeTest exposing (suite)

{-| Borrow-inference Phase 1 (§U1.3): the lifetime lattice against a
brute-force reference model, fuzzed lattice laws, and pinned regressions.
The deterministic exhaustive battery is the real `--fuzz 1` gate coverage.
-}

import Compiler.GlobalOpt.Borrow.Lifetime as L exposing (Life(..), Lifetime(..), Path, Step(..))
import Compiler.GlobalOpt.Borrow.SkelFuzz as SF exposing (Skel)
import Expect
import Fuzz exposing (Fuzzer)
import Set
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Borrow.Lifetime"
        [ batteryTest
        , lawsTests
        , regressions
        ]



-- EXHAUSTIVE BATTERY (deterministic; the --fuzz 1 gate coverage)


batteryTest : Test
batteryTest =
    Test.test "endsBefore/onBoundary match the brute-force reference over all depth-≤2 skeletons" <|
        \_ ->
            Expect.equal [] (List.concatMap checkSkel SF.allSkels)


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



-- FUZZED LAWS (smoke at --fuzz 1; deep at dev --fuzz 200)


type alias Sample =
    { skel : Skel
    , a : Lifetime
    , b : Lifetime
    , cc : Lifetime
    , s : List Path
    , p : Path
    }


subsetFuzzer : List a -> Fuzzer (List a)
subsetFuzzer items =
    Fuzz.map
        (\bools ->
            List.map2 Tuple.pair bools items
                |> List.filter Tuple.first
                |> List.map Tuple.second
        )
        (Fuzz.listOfLength (List.length items) Fuzz.bool)


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
                Fuzz.map2
                    (\subs p -> mkSample skel subs p)
                    (Fuzz.listOfLength 3 (subsetFuzzer leaves))
                    (Fuzz.oneOfValues probes)
            )


mkSample : Skel -> List (List Path) -> Path -> Sample
mkSample skel subs p =
    case subs of
        sA :: sB :: sC :: _ ->
            { skel = skel
            , a = SF.fromPaths sA
            , b = SF.fromPaths sB
            , cc = SF.fromPaths sC
            , s = sA
            , p = p
            }

        _ ->
            { skel = skel, a = LEmpty, b = LEmpty, cc = LEmpty, s = [], p = p }


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



-- PINNED REGRESSIONS


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
        , Test.test "5: Dict-shape independence (join arms in either order)" <|
            \_ ->
                let
                    x =
                        L.fromPath [ Arm 0 0, Seq 1 0 ]

                    y =
                        L.fromPath [ Arm 0 1, Seq 2 0 ]
                in
                Expect.equal True (L.eq (L.join x y) (L.join y x))
        ]



-- HELPERS


expectEq : Lifetime -> Lifetime -> Expect.Expectation
expectEq a b =
    if L.eq a b then
        Expect.pass

    else
        Expect.fail ("not eq: " ++ ltStr a ++ " vs " ++ ltStr b)


boolStr : Bool -> String
boolStr b =
    if b then
        "T"

    else
        "F"


stepStr : Step -> String
stepStr step =
    case step of
        Seq n i ->
            "S" ++ String.fromInt n ++ "." ++ String.fromInt i

        Arm n i ->
            "A" ++ String.fromInt n ++ "." ++ String.fromInt i


pathStr : Path -> String
pathStr p =
    "[" ++ String.join "," (List.map stepStr p) ++ "]"


pathsStr : List Path -> String
pathsStr ps =
    "{" ++ String.join ";" (List.map pathStr ps) ++ "}"


ltStr : Lifetime -> String
ltStr lt =
    case lt of
        LEmpty ->
            "LEmpty"

        LParams s ->
            "LParams{" ++ String.join "," (List.map String.fromInt (Set.toList s)) ++ "}"

        LLocal _ ->
            "LLocal(..)"
