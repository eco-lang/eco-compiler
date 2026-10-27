module Compiler.GlobalOpt.CafDedupe exposing
    ( run
    , Stats, emptyStats, renderStats
    )

{-| Monomorphization can produce several top-level constant specs whose
definitions are identical, and each one is then evaluated and cached
separately. This module merges them so that each distinct constant exists once.

A CAF (constant applicative form) here is a `MonoDefine` node: a top-level
definition with no parameters. Two of them are _equal_ when their bodies are
equal under `==` once every source region is zeroed (`CafHoist.zeroRegions`),
and their types are equal under `==`. Closure `lambdaId`s and lambda-set
annotations in types take part in that comparison, so bodies holding
different closures, or types differing only in their lambda sets, do not
merge. Equal definitions have equal layouts, so one can stand for the other.

Each class of equal specs keeps its smallest SpecId as the _canonical_ spec;
the others are _victims_. A victim's node becomes `Nothing` rather than being
removed, so no SpecId moves and the node array, registry and `nextId` keep
their sizes. Every `MonoVarGlobal` naming a victim, in any node body including
closure captures and decision-tree leaves, is pointed at the canonical spec,
as are port decoders, `flagsDecoder` and `main`. Nothing else is rewritten: a
`CallInfo`'s `fastEvaluatorSpec`, `callEdges`, `specHasEffects` and
`specValueUsed` are left as they were.

Merging can make further specs equal, because two bodies that named different
victims now name the same canonical spec. So `run` repeats the round until one
removes nothing, up to five rounds.

Merging is done with no purity check. It merges whole definitions, so it does
not change how many times either definition is evaluated; merging repeated
expressions inside bodies would need one.

@docs run
@docs Stats, emptyStats, renderStats

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.GlobalOpt.CafHoist as CafHoist
import Dict exposing (Dict)


{-| Counters for one `run`, summed over its rounds.

`rounds` includes the last round, which removed nothing unless the five-round
limit was reached, so a graph with nothing to merge gives 1. `refsRewritten`
counts only `MonoVarGlobal` references, not the port, flags and `main` entries.

-}
type alias Stats =
    { rounds : Int
    , groups : Int -- classes of equal specs with more than one member
    , removed : Int
    , refsRewritten : Int
    }


{-| Counters with every field at zero.
-}
emptyStats : Stats
emptyStats =
    { rounds = 0, groups = 0, removed = 0, refsRewritten = 0 }


{-| Renders the counters as a single `caf-dedupe:` report line.
-}
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


{-| Returns `graph` with equal CAF specs merged into their canonical spec,
repeating rounds until one removes nothing or five have run, together with the
counters summed over those rounds.
-}
run : Mono.MonoGraph -> ( Mono.MonoGraph, Stats )
run graph =
    fixpoint 5 graph emptyStats


{-| Runs rounds on `graph` while each removes something and `fuel` lasts,
adding each round's counters to `stats`. At least one round always runs.
-}
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


{-| Runs one round of merging over `graph`: finds every class of equal
`MonoDefine` specs and rewrites the graph as `applyRemap` does. Returns `graph`
unchanged with zero counters when no class has more than one member.
-}
oneRound : Mono.MonoGraph -> ( Mono.MonoGraph, Stats )
oneRound ((Mono.MonoGraph g) as graph) =
    let
        -- Bucketed by kind tag, then by type; only members of one bucket
        -- are compared with `==`.
        ( buckets, _ ) =
            Array.foldl
                (\maybeNode ( acc, sid ) ->
                    case maybeNode of
                        Just (Mono.MonoDefine expr ty) ->
                            let
                                zeroed =
                                    CafHoist.zeroRegions expr

                                tag =
                                    CafHoist.kindTagOf expr

                                inner =
                                    Maybe.withDefault Mono.specMapEmpty (Dict.get tag acc)

                                prev =
                                    Maybe.withDefault [] (Mono.specMapGet ty inner)
                            in
                            ( Dict.insert tag
                                (Mono.specMapInsert ty (( zeroed, ty, sid ) :: prev) inner)
                                acc
                            , sid + 1
                            )

                        _ ->
                            ( acc, sid + 1 )
                )
                ( Dict.empty, 0 )
                g.nodes

        -- Each bucket's members are in descending SpecId order.
        ( remap, groupCount ) =
            Dict.foldl
                (\_ inner acc ->
                    Mono.specMapFoldl (\_ members a -> classify members a) acc inner
                )
                ( Dict.empty, 0 )
                buckets
    in
    if Dict.isEmpty remap then
        ( graph, emptyStats )

    else
        applyRemap remap groupCount graph


{-| Adds one bucket's victims to the accumulated map from victim SpecId to
canonical SpecId, and adds one to the group count for each class of equal
members that has more than one member. A member equal to no other is left out.
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


{-| Returns the graph with every victim in `remap` set to `Nothing` and every
reference to one pointed at its canonical spec, in node bodies, port decoders,
`flagsDecoder` and `main`, together with that round's counters. `groupCount`
is passed through to the counters.
-}
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


{-| Returns `node` with its body's references remapped, and the number
rewritten. Nodes without a body are returned unchanged.
-}
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


{-| Returns each expression remapped, in order, and the total rewritten.
-}
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


{-| Returns `expr` with every `MonoVarGlobal` naming a victim pointed at its
canonical spec, and the number of such references. Region, type and
`CallInfo` are kept as they are.
-}
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


{-| Returns the decision tree with the expressions in its `Inline` leaves
remapped, and the number rewritten. `Jump` leaves hold no expression.
-}
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
