module Compiler.GlobalOpt.CafDedupe exposing (Stats, emptyStats, renderStats, run)

{-| Top-level CAF spec dedupe (`ECO_CAF_DEDUPE=1`,
design\_docs/caf-memoization-design.md §12 follow-on; measured as Run Y).

Monomorphization and LSS keying can mint multiple specs whose `MonoDefine`
bodies and types are STRUCTURALLY IDENTICAL — each currently gets its own
slot, guard, first evaluation, and cached copy. FORBID\_OPT\_003 forbids
sharing across DIFFERENT layouts; identical `(body, type)` pairs have
identical layouts by construction, so aliasing every reference to one
canonical spec is sound.

Equality is EXACT: region-zeroed structural equality on bodies
(`CafHoist.zeroRegions` — collision-impossible) plus `==` on the define
type. Bodies containing `MonoClosure` never merge in practice (lambdaIds
are minted fresh per clone and participate in `==` — which is exactly the
LSS\_009/017-safe behavior; no special-casing needed). Lambda-set
annotation differences in types also block merging (conservative: anno
mismatches are reported nowhere near worth the LSS-soundness analysis).

Victims' node entries become `Nothing` (the Prune gap convention — every
emission path skips gaps), so dead duplicates vanish from the output.
`registry`/`nextId`/array lengths are UNTOUCHED (CafHoist's drift
assertion still holds). References are remapped everywhere they can live:
node expressions (including closure bodies/captures and decider leaves),
`ports[].decoderSpecId`, `flagsDecoder`, and `main`.

Runs to a FIXPOINT (capped): merging group A can make two other bodies
equal (they referenced different-but-now-merged specs), so the pass
iterates until a round removes nothing.

Deterministic: ascending-specId grouping, canonical = smallest specId.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.GlobalOpt.CafHoist as CafHoist
import Dict exposing (Dict)


type alias Stats =
    { rounds : Int
    , groups : Int -- equal-classes with >1 member (across all rounds)
    , removed : Int -- victim specs nulled out
    , refsRewritten : Int -- MonoVarGlobal references redirected
    }


emptyStats : Stats
emptyStats =
    { rounds = 0, groups = 0, removed = 0, refsRewritten = 0 }


renderStats : Stats -> String
renderStats s =
    "caf-dedupe: rounds="
        ++ String.fromInt s.rounds
        ++ " groups="
        ++ String.fromInt s.groups
        ++ " removed="
        ++ String.fromInt s.removed
        ++ " refsRewritten="
        ++ String.fromInt s.refsRewritten


run : Mono.MonoGraph -> ( Mono.MonoGraph, Stats )
run graph =
    fixpoint 5 graph emptyStats


fixpoint : Int -> Mono.MonoGraph -> Stats -> ( Mono.MonoGraph, Stats )
fixpoint fuel graph stats =
    let
        ( graph1, roundStats ) =
            oneRound graph

        merged =
            { rounds = stats.rounds + 1
            , groups = stats.groups + roundStats.groups
            , removed = stats.removed + roundStats.removed
            , refsRewritten = stats.refsRewritten + roundStats.refsRewritten
            }
    in
    if roundStats.removed == 0 || fuel <= 1 then
        ( graph1, merged )

    else
        fixpoint (fuel - 1) graph1 merged


{-| kernel-opt-11 Phase 4 note (no behaviour change). This round merges
structurally equal `MonoDefine` specs with **no purity check at all** -- the
justification is not that kernel calls are pure, but that merging two identical
whole-spec DEFINITIONS does not change how many times either is EVALUATED, so
design\_docs/debug-log-ordering-policy.md D-2 (which forbids merging two
occurrences of a logging EXPRESSION) is not engaged. If this pass is ever
widened from spec-level to expression-level merging, D-2 applies immediately and
a `KernelFacts.hoistable` test becomes mandatory.
-}
oneRound : Mono.MonoGraph -> ( Mono.MonoGraph, Stats )
oneRound ((Mono.MonoGraph g) as graph) =
    let
        -- Pass A: group MonoDefine specs by exact (zeroed body, type).
        -- Bucketed by a cheap fingerprint; equality within a bucket is `==`.
        ( buckets, _ ) =
            Array.foldl
                (\maybeNode ( acc, sid ) ->
                    case maybeNode of
                        Just (Mono.MonoDefine expr ty) ->
                            let
                                zeroed =
                                    CafHoist.zeroRegions expr

                                fp =
                                    CafHoist.fingerprintOf expr ty
                            in
                            ( Dict.insert fp
                                (( zeroed, ty, sid )
                                    :: Maybe.withDefault [] (Dict.get fp acc)
                                )
                                acc
                            , sid + 1
                            )

                        _ ->
                            ( acc, sid + 1 )
                )
                ( Dict.empty, 0 )
                g.nodes

        -- Equal-classes per bucket; members are in DESCENDING specId order
        -- (cons-prepended during the ascending fold), so the class
        -- representative (canonical) is the LAST member = smallest specId.
        ( remap, groupCount ) =
            Dict.foldl
                (\_ members acc ->
                    classify members acc
                )
                ( Dict.empty, 0 )
                buckets
    in
    if Dict.isEmpty remap then
        ( graph, emptyStats )

    else
        applyRemap remap groupCount graph


{-| Partition one bucket into equal-classes and record victim→canonical
edges. `members` is descending by specId.
-}
classify :
    List ( Mono.MonoExpr, Mono.MonoType, Int )
    -> ( Dict Int Int, Int )
    -> ( Dict Int Int, Int )
classify members acc =
    case members of
        [] ->
            acc

        ( z, ty, sid ) :: rest ->
            let
                ( same, different ) =
                    List.partition (\( z2, ty2, _ ) -> z2 == z && ty2 == ty) rest

                ( remap0, groups0 ) =
                    acc
            in
            case same of
                [] ->
                    classify rest acc

                _ ->
                    let
                        -- descending order ⇒ the smallest specId in this
                        -- class is the LAST of (sid :: same-sids).
                        classIds =
                            sid :: List.map (\( _, _, s ) -> s) same

                        canonical =
                            List.foldl min sid classIds

                        remap1 =
                            List.foldl
                                (\s d ->
                                    if s == canonical then
                                        d

                                    else
                                        Dict.insert s canonical d
                                )
                                remap0
                                classIds
                    in
                    classify different ( remap1, groups0 + 1 )


applyRemap : Dict Int Int -> Int -> Mono.MonoGraph -> ( Mono.MonoGraph, Stats )
applyRemap remap groupCount (Mono.MonoGraph g) =
    let
        remapId sid =
            Maybe.withDefault sid (Dict.get sid remap)

        ( newNodesRev, _, ( refsRewritten, removed ) ) =
            Array.foldl
                (\maybeNode ( acc, sid, ( refs, gone ) ) ->
                    case maybeNode of
                        Just node ->
                            if Dict.member sid remap then
                                ( Nothing :: acc, sid + 1, ( refs, gone + 1 ) )

                            else
                                let
                                    ( node1, refs1 ) =
                                        remapNode remap node
                                in
                                ( Just node1 :: acc, sid + 1, ( refs + refs1, gone ) )

                        Nothing ->
                            ( Nothing :: acc, sid + 1, ( refs, gone ) )
                )
                ( [], 0, ( 0, 0 ) )
                g.nodes

        newNodes =
            Array.fromList (List.reverse newNodesRev)

        ports1 =
            List.map
                (\p -> { p | decoderSpecId = Maybe.map remapId p.decoderSpecId })
                g.ports

        flagsDecoder1 =
            Maybe.map remapId g.flagsDecoder

        main1 =
            Maybe.map (\(Mono.StaticMain sid) -> Mono.StaticMain (remapId sid)) g.main
    in
    ( Mono.MonoGraph
        { g
            | nodes = newNodes
            , ports = ports1
            , flagsDecoder = flagsDecoder1
            , main = main1
        }
    , { rounds = 1, groups = groupCount, removed = removed, refsRewritten = refsRewritten }
    )


remapNode : Dict Int Int -> Mono.MonoNode -> ( Mono.MonoNode, Int )
remapNode remap node =
    case node of
        Mono.MonoDefine expr ty ->
            let
                ( e1, n ) =
                    remapExpr remap expr
            in
            ( Mono.MonoDefine e1 ty, n )

        Mono.MonoTailFunc params expr ty ->
            let
                ( e1, n ) =
                    remapExpr remap expr
            in
            ( Mono.MonoTailFunc params e1 ty, n )

        Mono.MonoPortIncoming expr ty ->
            let
                ( e1, n ) =
                    remapExpr remap expr
            in
            ( Mono.MonoPortIncoming e1 ty, n )

        Mono.MonoPortOutgoing expr ty ->
            let
                ( e1, n ) =
                    remapExpr remap expr
            in
            ( Mono.MonoPortOutgoing e1 ty, n )

        _ ->
            ( node, 0 )


remapList : Dict Int Int -> List Mono.MonoExpr -> ( List Mono.MonoExpr, Int )
remapList remap exprs =
    let
        ( rev, n ) =
            List.foldl
                (\e ( acc, c ) ->
                    let
                        ( e1, c1 ) =
                            remapExpr remap e
                    in
                    ( e1 :: acc, c + c1 )
                )
                ( [], 0 )
                exprs
    in
    ( List.reverse rev, n )


remapExpr : Dict Int Int -> Mono.MonoExpr -> ( Mono.MonoExpr, Int )
remapExpr remap expr =
    case expr of
        Mono.MonoVarGlobal region sid ty ->
            case Dict.get sid remap of
                Just canonical ->
                    ( Mono.MonoVarGlobal region canonical ty, 1 )

                Nothing ->
                    ( expr, 0 )

        Mono.MonoLiteral _ _ ->
            ( expr, 0 )

        Mono.MonoVarLocal _ _ ->
            ( expr, 0 )

        Mono.MonoVarKernel _ _ _ _ _ ->
            ( expr, 0 )

        Mono.MonoUnit ->
            ( expr, 0 )

        Mono.MonoAccessorValue _ _ _ ->
            ( expr, 0 )

        Mono.MonoList region items ty ->
            let
                ( items1, n ) =
                    remapList remap items
            in
            ( Mono.MonoList region items1 ty, n )

        Mono.MonoClosure info body ty ->
            let
                ( capturesRev, cn ) =
                    List.foldl
                        (\( name, ce, b ) ( acc, c ) ->
                            let
                                ( ce1, c1 ) =
                                    remapExpr remap ce
                            in
                            ( ( name, ce1, b ) :: acc, c + c1 )
                        )
                        ( [], 0 )
                        info.captures

                ( body1, bn ) =
                    remapExpr remap body
            in
            ( Mono.MonoClosure { info | captures = List.reverse capturesRev } body1 ty
            , cn + bn
            )

        Mono.MonoCall region func args ty callInfo ->
            let
                ( func1, fn ) =
                    remapExpr remap func

                ( args1, an ) =
                    remapList remap args
            in
            ( Mono.MonoCall region func1 args1 ty callInfo, fn + an )

        Mono.MonoTailCall name args ty ->
            let
                ( argsRev, n ) =
                    List.foldl
                        (\( an, ae ) ( acc, c ) ->
                            let
                                ( ae1, c1 ) =
                                    remapExpr remap ae
                            in
                            ( ( an, ae1 ) :: acc, c + c1 )
                        )
                        ( [], 0 )
                        args
            in
            ( Mono.MonoTailCall name (List.reverse argsRev) ty, n )

        Mono.MonoIf branches final ty ->
            let
                ( branchesRev, bn ) =
                    List.foldl
                        (\( c, t ) ( acc, cnt ) ->
                            let
                                ( c1, n1 ) =
                                    remapExpr remap c

                                ( t1, n2 ) =
                                    remapExpr remap t
                            in
                            ( ( c1, t1 ) :: acc, cnt + n1 + n2 )
                        )
                        ( [], 0 )
                        branches

                ( final1, fn ) =
                    remapExpr remap final
            in
            ( Mono.MonoIf (List.reverse branchesRev) final1 ty, bn + fn )

        Mono.MonoLet def body ty ->
            let
                ( def1, dn ) =
                    case def of
                        Mono.MonoDef n e ->
                            let
                                ( e1, c ) =
                                    remapExpr remap e
                            in
                            ( Mono.MonoDef n e1, c )

                        Mono.MonoTailDef n params e ->
                            let
                                ( e1, c ) =
                                    remapExpr remap e
                            in
                            ( Mono.MonoTailDef n params e1, c )

                ( body1, bn ) =
                    remapExpr remap body
            in
            ( Mono.MonoLet def1 body1 ty, dn + bn )

        Mono.MonoDestruct d body ty ->
            let
                ( body1, n ) =
                    remapExpr remap body
            in
            ( Mono.MonoDestruct d body1 ty, n )

        Mono.MonoCase s1 s2 decider branches ty ->
            let
                ( decider1, dn ) =
                    remapDecider remap decider

                ( branchesRev, bn ) =
                    List.foldl
                        (\( idx, e ) ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    remapExpr remap e
                            in
                            ( ( idx, e1 ) :: acc, c + c1 )
                        )
                        ( [], 0 )
                        branches
            in
            ( Mono.MonoCase s1 s2 decider1 (List.reverse branchesRev) ty, dn + bn )

        Mono.MonoRecordCreate fields ty ->
            let
                ( fieldsRev, n ) =
                    List.foldl
                        (\( name, e ) ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    remapExpr remap e
                            in
                            ( ( name, e1 ) :: acc, c + c1 )
                        )
                        ( [], 0 )
                        fields
            in
            ( Mono.MonoRecordCreate (List.reverse fieldsRev) ty, n )

        Mono.MonoRecordAccess rec field ty ->
            let
                ( rec1, n ) =
                    remapExpr remap rec
            in
            ( Mono.MonoRecordAccess rec1 field ty, n )

        Mono.MonoRecordUpdate rec updates ty ->
            let
                ( rec1, rn ) =
                    remapExpr remap rec

                ( updatesRev, un ) =
                    List.foldl
                        (\( name, e ) ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    remapExpr remap e
                            in
                            ( ( name, e1 ) :: acc, c + c1 )
                        )
                        ( [], 0 )
                        updates
            in
            ( Mono.MonoRecordUpdate rec1 (List.reverse updatesRev) ty, rn + un )

        Mono.MonoTupleCreate region items ty ->
            let
                ( items1, n ) =
                    remapList remap items
            in
            ( Mono.MonoTupleCreate region items1 ty, n )


remapDecider : Dict Int Int -> Mono.Decider Mono.MonoChoice -> ( Mono.Decider Mono.MonoChoice, Int )
remapDecider remap decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            let
                ( e1, n ) =
                    remapExpr remap e
            in
            ( Mono.Leaf (Mono.Inline e1), n )

        Mono.Leaf (Mono.Jump j) ->
            ( Mono.Leaf (Mono.Jump j), 0 )

        Mono.Chain tests succ fail ->
            let
                ( succ1, sn ) =
                    remapDecider remap succ

                ( fail1, fn ) =
                    remapDecider remap fail
            in
            ( Mono.Chain tests succ1 fail1, sn + fn )

        Mono.FanOut path edges fallback ->
            let
                ( edgesRev, en ) =
                    List.foldl
                        (\( t, d ) ( acc, c ) ->
                            let
                                ( d1, c1 ) =
                                    remapDecider remap d
                            in
                            ( ( t, d1 ) :: acc, c + c1 )
                        )
                        ( [], 0 )
                        edges

                ( fallback1, fn ) =
                    remapDecider remap fallback
            in
            ( Mono.FanOut path (List.reverse edgesRev) fallback1, en + fn )
