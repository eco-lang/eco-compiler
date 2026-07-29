module Compiler.GlobalOpt.Borrow.SkelFuzz exposing
    ( Skel(..)
    , skelFuzzer, allSkels
    , leafPaths, allProbes, executions, fromPaths
    , refEndsBefore, refOnBoundary
    , subsets
    )

{-| Brute-force reference / arbiter model for the lifetime lattice
(borrow-inference Phase 1, §U1.3). Helper module — exposes no `Test`.

A `Skel` is an abstract evaluation skeleton (SLeaf / SSeq / SAlts). Node ids
are assigned by pre-order numbering (`renumber`). `leafPaths` enumerates the
root-to-leaf paths; `executions` enumerates the run-throughs (one arm chosen
per `SAlts`, all `SSeq` children visited in order). The reference predicates
define lifetime deadness/boundary directly over executions and are the
arbiter for `Lifetime.endsBefore`/`onBoundary`.

`refEndsBefore`/`refOnBoundary` take the skeleton's `executions` explicitly
(the plan's 2-arg signature is under-specified — the executions come from the
skeleton, not from the live-set `S`).

Interior-probe semantics (LOAD-BEARING — `endsBefore` is used at interior
scope paths, e.g. design §9): an execution `E` is a list of leaf paths.
"`E` contains `p`" ⟺ some leaf in `E` has `p` as a prefix. `pos_E(p)` = index
of the LAST leaf in `E` with `p` as a prefix (subtree completion). For a leaf
`q ∈ S ∩ E`, `pos_E(q)` is `q`'s own leaf index.

-}

import Compiler.GlobalOpt.Borrow.Lifetime as L exposing (Lifetime, Path, Step(..))
import Fuzz exposing (Fuzzer)


type Skel
    = SLeaf
    | SSeq Int (List Skel)
    | SAlts Int (List Skel)



-- PRE-ORDER RENUMBERING


renumber : Skel -> Skel
renumber skel =
    Tuple.first (renumberGo 0 skel)


renumberGo : Int -> Skel -> ( Skel, Int )
renumberGo n skel =
    case skel of
        SLeaf ->
            ( SLeaf, n )

        SSeq _ kids ->
            let
                ( kids2, n2 ) =
                    renumberList (n + 1) kids
            in
            ( SSeq n kids2, n2 )

        SAlts _ kids ->
            let
                ( kids2, n2 ) =
                    renumberList (n + 1) kids
            in
            ( SAlts n kids2, n2 )


renumberList : Int -> List Skel -> ( List Skel, Int )
renumberList n kids =
    case kids of
        [] ->
            ( [], n )

        k :: rest ->
            let
                ( k2, n2 ) =
                    renumberGo n k

                ( rest2, n3 ) =
                    renumberList n2 rest
            in
            ( k2 :: rest2, n3 )



-- ENUMERATION


leafPaths : Skel -> List Path
leafPaths skel =
    case skel of
        SLeaf ->
            [ [] ]

        SSeq n kids ->
            List.concat
                (List.indexedMap
                    (\i kid -> List.map (\p -> Seq n i :: p) (leafPaths kid))
                    kids
                )

        SAlts n kids ->
            List.concat
                (List.indexedMap
                    (\i kid -> List.map (\p -> Arm n i :: p) (leafPaths kid))
                    kids
                )


{-| One execution per arm-choice vector. `SSeq` visits all children in order
(cartesian product of their executions, concatenated); `SAlts` picks exactly
one arm (disjoint union).
-}
executions : Skel -> List (List Path)
executions skel =
    case skel of
        SLeaf ->
            [ [ [] ] ]

        SSeq n kids ->
            let
                perChild =
                    List.indexedMap
                        (\i kid ->
                            List.map (List.map (\p -> Seq n i :: p)) (executions kid)
                        )
                        kids
            in
            List.map List.concat (cartesian perChild)

        SAlts n kids ->
            List.concat
                (List.indexedMap
                    (\i kid ->
                        List.map (List.map (\p -> Arm n i :: p)) (executions kid)
                    )
                    kids
                )


cartesian : List (List a) -> List (List a)
cartesian lists =
    case lists of
        [] ->
            [ [] ]

        xs :: rest ->
            let
                restProd =
                    cartesian rest
            in
            List.concatMap (\x -> List.map (\r -> x :: r) restProd) xs


fromPaths : List Path -> Lifetime
fromPaths paths =
    List.foldl (\p acc -> L.join (L.fromPath p) acc) L.LEmpty paths



-- PROBES (leaf paths ∪ proper prefixes)


allProbes : Skel -> List Path
allProbes skel =
    let
        leaves =
            leafPaths skel

        prefixes =
            List.concatMap properPrefixes leaves
    in
    dedupe (leaves ++ prefixes)


properPrefixes : Path -> List Path
properPrefixes path =
    let
        len =
            List.length path
    in
    List.filter (\p -> List.length p < len) (inits path)


inits : List a -> List (List a)
inits xs =
    case xs of
        [] ->
            [ [] ]

        x :: rest ->
            [] :: List.map (\r -> x :: r) (inits rest)


dedupe : List Path -> List Path
dedupe =
    List.foldr
        (\x acc ->
            if List.member x acc then
                acc

            else
                x :: acc
        )
        []


subsets : List a -> List (List a)
subsets list =
    case list of
        [] ->
            [ [] ]

        x :: rest ->
            let
                s =
                    subsets rest
            in
            s ++ List.map (\sub -> x :: sub) s



-- REFERENCE PREDICATES (arbiter)


refEndsBefore : List (List Path) -> List Path -> Path -> Bool
refEndsBefore execs s p =
    List.all
        (\e ->
            if containsPath e p then
                let
                    pp =
                        lastPos e p

                    -- A completion path's point is STRICTLY AFTER its subtree's
                    -- last leaf, so a death at that last leaf is *before* it
                    -- (use `<=`). A leaf probe's point is the leaf itself, so a
                    -- death there is *not* before it (strict `<`).
                    isLeafP =
                        List.member p e
                in
                List.all
                    (\q ->
                        case leafIndex e q of
                            Nothing ->
                                True

                            Just qi ->
                                if isLeafP then
                                    qi < pp

                                else
                                    qi <= pp
                    )
                    s

            else
                True
        )
        execs


refOnBoundary : List (List Path) -> List Path -> Path -> Bool
refOnBoundary execs s p =
    List.member p s
        && List.all
            (\e ->
                if containsPath e p then
                    let
                        pp =
                            lastPos e p
                    in
                    List.all
                        (\q ->
                            case leafIndex e q of
                                Nothing ->
                                    True

                                Just qi ->
                                    qi <= pp
                        )
                        s

                else
                    True
            )
            execs


containsPath : List Path -> Path -> Bool
containsPath e p =
    List.any (\leaf -> isPrefix p leaf) e


{-| Index of the LAST leaf in `e` with `p` as a prefix; -1 if none.
-}
lastPos : List Path -> Path -> Int
lastPos e p =
    List.foldl
        (\( idx, leaf ) best ->
            if isPrefix p leaf then
                idx

            else
                best
        )
        -1
        (List.indexedMap Tuple.pair e)


{-| Index of the first exact-match `q` in `e` (q is a leaf claim).
-}
leafIndex : List Path -> Path -> Maybe Int
leafIndex e q =
    indexOf 0 e q


indexOf : Int -> List Path -> Path -> Maybe Int
indexOf i e q =
    case e of
        [] ->
            Nothing

        leaf :: rest ->
            if leaf == q then
                Just i

            else
                indexOf (i + 1) rest q


isPrefix : Path -> Path -> Bool
isPrefix pre full =
    case ( pre, full ) of
        ( [], _ ) ->
            True

        ( _, [] ) ->
            False

        ( a :: ar, b :: br ) ->
            a == b && isPrefix ar br



-- SKELETON GENERATORS


{-| All skeletons of depth ≤ 2 (SSeq width 1-2, SAlts exactly 2 arms),
pre-order renumbered. Deterministic — the `--fuzz 1` gate coverage.
-}
allSkels : List Skel
allSkels =
    List.map renumber (skelsUpToDepth 2)


skelsUpToDepth : Int -> List Skel
skelsUpToDepth d =
    if d <= 0 then
        [ SLeaf ]

    else
        let
            sub =
                skelsUpToDepth (d - 1)

            seq1 =
                List.map (\k -> SSeq 0 [ k ]) sub

            seq2 =
                List.concatMap (\a -> List.map (\b -> SSeq 0 [ a, b ]) sub) sub

            alts2 =
                List.concatMap (\a -> List.map (\b -> SAlts 0 [ a, b ]) sub) sub
        in
        SLeaf :: (seq1 ++ seq2 ++ alts2)


skelFuzzer : Int -> Fuzzer Skel
skelFuzzer d =
    Fuzz.map renumber (skelFuzzerRaw d)


skelFuzzerRaw : Int -> Fuzzer Skel
skelFuzzerRaw d =
    if d <= 0 then
        Fuzz.constant SLeaf

    else
        Fuzz.oneOf
            [ Fuzz.constant SLeaf
            , Fuzz.intRange 1 3
                |> Fuzz.andThen
                    (\w ->
                        Fuzz.map (SSeq 0)
                            (Fuzz.listOfLength w (Fuzz.lazy (\_ -> skelFuzzerRaw (d - 1))))
                    )
            , Fuzz.intRange 2 3
                |> Fuzz.andThen
                    (\w ->
                        Fuzz.map (SAlts 0)
                            (Fuzz.listOfLength w (Fuzz.lazy (\_ -> skelFuzzerRaw (d - 1))))
                    )
            ]
