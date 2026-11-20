module Compiler.MonoOpt.KnownCtorCase exposing
    ( Stats, run, renderStats
    )

{-| Case of a known constructor (plans/constructor-representation-levels.md §8,
units K0 and K1): a `case x of ...` where `x` is bound, earlier in the same
function, to a saturated constructor call `C a b` (or to a nullary constructor)
picks its branch at compile time, and the branch's destructuring of `x` reads
the constructor's arguments directly. Inlining creates many such sites; folding
them saves the allocation of `x` when nothing else uses it, and the tag test
always.

A site is folded only when

  - every argument of the constructor call is trivial (a local variable, a
    global, a literal or unit), so that using it in place of a field read
    repeats no work and moves no evaluation;
  - every test the decision tree reaches from its root is on the scrutinee
    itself, so the constructor alone decides it (a test on a field, such as
    `Just (Just _)`, is left alone); and
  - no binding between the constructor call and the `case` rebinds `x` or a
    variable among the arguments.

After folding, a binding `x = C ...` that nothing uses any more is dropped.

`run` always counts the sites (the K0 census: `sites`, `trivialArgs`,
`rootOnly`) and folds them only when `fold` is set.

@docs Stats, run, renderStats

-}

import Array
import Compiler.IR.DecisionTree.Test as Test
import Compiler.IR.Mono as Mono exposing (MonoExpr(..))
import Compiler.IR.Mono.Traverse as Traverse
import Data.NonEmptyList as NE
import Dict exposing (Dict)
import Set
import System.Crash


{-| The census of known-constructor `case` sites, and the folds made.
-}
type alias Stats =
    { sites : Int
    , trivialArgs : Int
    , rootOnly : Int
    , folded : Int
    , bindingsDropped : Int
    }


emptyStats : Stats
emptyStats =
    { sites = 0, trivialArgs = 0, rootOnly = 0, folded = 0, bindingsDropped = 0 }


{-| The statistics as one line for the inline report.
-}
renderStats : Stats -> String
renderStats s =
    "known-ctor-case: sites="
        ++ String.fromInt s.sites
        ++ " trivialArgs="
        ++ String.fromInt s.trivialArgs
        ++ " rootOnly="
        ++ String.fromInt s.rootOnly
        ++ " folded="
        ++ String.fromInt s.folded
        ++ " bindingsDropped="
        ++ String.fromInt s.bindingsDropped


{-| A constructor whose node is known: its name and number of fields.
-}
type alias KnownCtor =
    { name : String, arity : Int }


{-| A local bound to a known constructor's value: the constructor and its
arguments.
-}
type alias Known =
    { ctor : String, args : List MonoExpr }


{-| Counts, and with `fold` folds, the known-constructor `case` sites of
`graph`.
-}
run : { fold : Bool } -> Mono.MonoGraph -> ( Mono.MonoGraph, Stats )
run opts (Mono.MonoGraph g) =
    let
        ctors : Dict Int KnownCtor
        ctors =
            Array.foldl
                (\maybeNode ( acc, i ) ->
                    case maybeNode of
                        Just (Mono.MonoCtor _ shape _) ->
                            ( Dict.insert i { name = shape.name, arity = List.length shape.fieldTypes } acc, i + 1 )

                        Just (Mono.MonoEnum _ name _ _) ->
                            ( Dict.insert i { name = name, arity = 0 } acc, i + 1 )

                        _ ->
                            ( acc, i + 1 )
                )
                ( Dict.empty, 0 )
                g.nodes
                |> Tuple.first

        env0 =
            { ctors = ctors, fold = opts.fold }

        ( nodes1, stats ) =
            Array.foldl
                (\maybeNode ( acc, st ) ->
                    case maybeNode of
                        Just node ->
                            let
                                ( node1, st1 ) =
                                    rewriteNode env0 node st
                            in
                            ( Array.push (Just node1) acc, st1 )

                        Nothing ->
                            ( Array.push Nothing acc, st )
                )
                ( Array.empty, emptyStats )
                g.nodes
    in
    if opts.fold && stats.folded > 0 then
        ( Mono.MonoGraph { g | nodes = nodes1, callEdges = Traverse.collectSpecEdges nodes1 }, stats )

    else
        ( Mono.MonoGraph g, stats )


type alias Env =
    { ctors : Dict Int KnownCtor, fold : Bool }


rewriteNode : Env -> Mono.MonoNode -> Stats -> ( Mono.MonoNode, Stats )
rewriteNode env node st =
    case node of
        Mono.MonoDefine expr t ->
            Tuple.mapFirst (\e -> Mono.MonoDefine e t) (walk env Dict.empty expr st)

        Mono.MonoTailFunc params expr t ->
            Tuple.mapFirst (\e -> Mono.MonoTailFunc params e t) (walk env Dict.empty expr st)

        _ ->
            ( node, st )


isTrivial : MonoExpr -> Bool
isTrivial e =
    case e of
        MonoVarLocal _ _ ->
            True

        MonoVarGlobal _ _ _ ->
            True

        MonoLiteral _ _ ->
            True

        MonoUnit ->
            True

        _ ->
            False


{-| The known constructor value `e` builds, if it is a saturated constructor
call or a nullary constructor.
-}
knownOf : Env -> MonoExpr -> Maybe Known
knownOf env e =
    case e of
        MonoCall _ (MonoVarGlobal _ specId _) args _ _ ->
            case Dict.get specId env.ctors of
                Just c ->
                    if c.arity == List.length args && c.arity > 0 then
                        Just { ctor = c.name, args = args }

                    else
                        Nothing

                Nothing ->
                    Nothing

        MonoVarGlobal _ specId _ ->
            case Dict.get specId env.ctors of
                Just c ->
                    if c.arity == 0 then
                        Just { ctor = c.name, args = [] }

                    else
                        Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| The local names `known` refers to.
-}
argNames : Known -> List String
argNames known =
    List.filterMap
        (\a ->
            case a of
                MonoVarLocal n _ ->
                    Just n

                _ ->
                    Nothing
        )
        known.args


{-| `knowns` without the entries a new binding of `names` would invalidate:
an entry for one of the names, and an entry whose arguments mention one.
-}
shadow : List String -> Dict String Known -> Dict String Known
shadow names knowns =
    if List.isEmpty names || Dict.isEmpty knowns then
        knowns

    else
        let
            ns =
                Set.fromList names
        in
        Dict.filter (\x k -> not (Set.member x ns) && not (List.any (\a -> Set.member a ns) (argNames k))) knowns


walk : Env -> Dict String Known -> MonoExpr -> Stats -> ( MonoExpr, Stats )
walk env knowns expr st =
    case expr of
        MonoLet (Mono.MonoDef name bound) body t ->
            let
                ( bound1, st1 ) =
                    walk env knowns bound st

                knowns1 =
                    shadow [ name ] knowns
                        |> (case knownOf env bound1 of
                                Just k ->
                                    Dict.insert name k

                                Nothing ->
                                    identity
                           )

                ( body1, st2 ) =
                    walk env knowns1 body st1
            in
            -- A constructor value is pure: once no case or other use reads it, the binding goes.
            if env.fold && knownOf env bound1 /= Nothing && st2.folded > st1.folded && not (usesName name body1) then
                ( body1, { st2 | bindingsDropped = st2.bindingsDropped + 1 } )

            else
                ( MonoLet (Mono.MonoDef name bound1) body1 t, st2 )

        MonoLet (Mono.MonoTailDef name params bound) body t ->
            let
                inner =
                    shadow (name :: List.map Tuple.first params) knowns

                ( bound1, st1 ) =
                    walk env inner bound st

                ( body1, st2 ) =
                    walk env (shadow [ name ] knowns) body st1
            in
            ( MonoLet (Mono.MonoTailDef name params bound1) body1 t, st2 )

        MonoDestruct ((Mono.MonoDestructor name _ _) as d) inner t ->
            let
                ( inner1, st1 ) =
                    walk env (shadow [ name ] knowns) inner st
            in
            ( MonoDestruct d inner1 t, st1 )

        MonoClosure info body t ->
            -- A closure body runs later, with its own bindings; nothing is assumed inside it.
            let
                ( captures1, st1 ) =
                    List.foldr
                        (\( n, e, b ) ( acc, s ) ->
                            let
                                ( e1, s1 ) =
                                    walk env knowns e s
                            in
                            ( ( n, e1, b ) :: acc, s1 )
                        )
                        ( [], st )
                        info.captures

                ( body1, st2 ) =
                    walk env Dict.empty body st1
            in
            ( MonoClosure { info | captures = captures1 } body1 t, st2 )

        MonoCase label scrut decider jumps t ->
            case Dict.get scrut knowns of
                Just known ->
                    let
                        trivial =
                            List.all isTrivial known.args

                        decided =
                            evalDecider scrut known.ctor decider

                        st1 =
                            { st
                                | sites = st.sites + 1
                                , trivialArgs =
                                    if trivial then
                                        st.trivialArgs + 1

                                    else
                                        st.trivialArgs
                                , rootOnly =
                                    if decided /= Nothing then
                                        st.rootOnly + 1

                                    else
                                        st.rootOnly
                            }
                    in
                    case ( env.fold && trivial, decided ) of
                        ( True, Just choice ) ->
                            let
                                chosen =
                                    case choice of
                                        Mono.Inline e ->
                                            Just e

                                        Mono.Jump i ->
                                            List.filter (\( j, _ ) -> j == i) jumps |> List.head |> Maybe.map Tuple.second
                            in
                            case chosen of
                                Just e ->
                                    walk env knowns (bindFields scrut known e) { st1 | folded = st1.folded + 1 }

                                Nothing ->
                                    walkCaseChildren env knowns label scrut decider jumps t st1

                        _ ->
                            walkCaseChildren env knowns label scrut decider jumps t st1

                Nothing ->
                    walkCaseChildren env knowns label scrut decider jumps t st

        _ ->
            walkChildren env knowns expr st


walkCaseChildren : Env -> Dict String Known -> String -> String -> Mono.Decider Mono.MonoChoice -> List ( Int, MonoExpr ) -> Mono.MonoType -> Stats -> ( MonoExpr, Stats )
walkCaseChildren env knowns label scrut decider jumps t st =
    let
        ( decider1, st1 ) =
            walkDecider env knowns decider st

        ( jumps1, st2 ) =
            List.foldr
                (\( i, e ) ( acc, s ) ->
                    let
                        ( e1, s1 ) =
                            walk env knowns e s
                    in
                    ( ( i, e1 ) :: acc, s1 )
                )
                ( [], st1 )
                jumps
    in
    ( MonoCase label scrut decider1 jumps1 t, st2 )


walkDecider : Env -> Dict String Known -> Mono.Decider Mono.MonoChoice -> Stats -> ( Mono.Decider Mono.MonoChoice, Stats )
walkDecider env knowns decider st =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            Tuple.mapFirst (\e1 -> Mono.Leaf (Mono.Inline e1)) (walk env knowns e st)

        Mono.Leaf (Mono.Jump _) ->
            ( decider, st )

        Mono.Chain tests s f ->
            let
                ( s1, st1 ) =
                    walkDecider env knowns s st

                ( f1, st2 ) =
                    walkDecider env knowns f st1
            in
            ( Mono.Chain tests s1 f1, st2 )

        Mono.FanOut path edges fallback ->
            let
                ( edges1, st1 ) =
                    NE.foldr
                        (\( test, d ) ( acc, s ) ->
                            let
                                ( d1, s1 ) =
                                    walkDecider env knowns d s
                            in
                            ( ( test, d1 ) :: acc, s1 )
                        )
                        ( [], st )
                        edges

                ( fallback1, st2 ) =
                    walkDecider env knowns fallback st1
            in
            case edges1 of
                first :: rest ->
                    ( Mono.FanOut path (NE.Nonempty first rest) fallback1, st2 )

                [] ->
                    ( decider, st )


{-| Walks every child of `expr` with the same known bindings. Binding forms
are handled by `walk`; every other expression binds nothing.
-}
walkChildren : Env -> Dict String Known -> MonoExpr -> Stats -> ( MonoExpr, Stats )
walkChildren =
    walkShallow


{-| Rewrites the nearest binding forms and cases below `expr` (not `expr`
itself) with `walk`, leaving everything else as it is.
-}
walkShallow : Env -> Dict String Known -> MonoExpr -> Stats -> ( MonoExpr, Stats )
walkShallow env knowns expr st =
    case expr of
        MonoCall r f args t ci ->
            let
                ( f1, s1 ) =
                    walk env knowns f st

                ( args1, s2 ) =
                    walkList env knowns args s1
            in
            ( MonoCall r f1 args1 t ci, s2 )

        MonoTailCall n args t ->
            let
                ( es, s1 ) =
                    walkList env knowns (List.map Tuple.second args) st
            in
            ( MonoTailCall n (List.map2 (\( an, _ ) e -> ( an, e )) args es) t, s1 )

        MonoIf branches final t ->
            let
                ( conds, s1 ) =
                    walkList env knowns (List.map Tuple.first branches) st

                ( thens, s2 ) =
                    walkList env knowns (List.map Tuple.second branches) s1

                ( final1, s3 ) =
                    walk env knowns final s2
            in
            ( MonoIf (List.map2 Tuple.pair conds thens) final1 t, s3 )

        MonoList r items t ->
            Tuple.mapFirst (\es -> MonoList r es t) (walkList env knowns items st)

        MonoRecordCreate fields t ->
            let
                ( es, s1 ) =
                    walkList env knowns (List.map Tuple.second fields) st
            in
            ( MonoRecordCreate (List.map2 (\( n, _ ) e -> ( n, e )) fields es) t, s1 )

        MonoRecordAccess inner n t ->
            Tuple.mapFirst (\e -> MonoRecordAccess e n t) (walk env knowns inner st)

        MonoRecordUpdate record updates t ->
            let
                ( record1, s1 ) =
                    walk env knowns record st

                ( es, s2 ) =
                    walkList env knowns (List.map Tuple.second updates) s1
            in
            ( MonoRecordUpdate record1 (List.map2 (\( n, _ ) e -> ( n, e )) updates es) t, s2 )

        MonoTupleCreate r elems t ->
            let
                ( es, s1 ) =
                    walkList env knowns (Mono.tupleToList elems) st
            in
            ( MonoTupleCreate r (rebuildTuple elems es) t, s1 )

        _ ->
            ( expr, st )


rebuildTuple : Mono.TupleShape a -> List b -> Mono.TupleShape b
rebuildTuple shape es =
    case ( shape, es ) of
        ( Mono.T2 _ _, [ a, b ] ) ->
            Mono.T2 a b

        ( _, [ a, b, c ] ) ->
            Mono.T3 a b c

        ( _, a :: b :: _ ) ->
            Mono.T2 a b

        _ ->
            System.Crash.crash "KnownCtorCase.rebuildTuple: arity"


walkList : Env -> Dict String Known -> List MonoExpr -> Stats -> ( List MonoExpr, Stats )
walkList env knowns es st =
    List.foldr
        (\e ( acc, s ) ->
            let
                ( e1, s1 ) =
                    walk env knowns e s
            in
            ( e1 :: acc, s1 )
        )
        ( [], st )
        es


{-| The branch the decision tree takes for a value built by `ctor`, when every
test reached is on the scrutinee `scrut` itself.
-}
evalDecider : String -> String -> Mono.Decider Mono.MonoChoice -> Maybe Mono.MonoChoice
evalDecider scrut ctor decider =
    case decider of
        Mono.Leaf choice ->
            Just choice

        Mono.Chain tests success failure ->
            let
                results =
                    NE.toList tests |> List.map (\( p, test ) -> testResult scrut ctor p test)
            in
            if List.any ((==) (Just False)) results then
                evalDecider scrut ctor failure

            else if List.all ((==) (Just True)) results then
                evalDecider scrut ctor success

            else
                Nothing

        Mono.FanOut path edges fallback ->
            if isRoot scrut path then
                let
                    hit =
                        NE.toList edges
                            |> List.filter
                                (\( test, _ ) ->
                                    case test of
                                        Test.FCtor _ name _ _ _ ->
                                            name == ctor

                                        _ ->
                                            False
                                )
                            |> List.head
                in
                case hit of
                    Just ( _, d ) ->
                        evalDecider scrut ctor d

                    Nothing ->
                        evalDecider scrut ctor fallback

            else
                Nothing


isRoot : String -> Mono.MonoDtPath -> Bool
isRoot scrut path =
    case path of
        Mono.DtRoot name _ ->
            name == scrut

        _ ->
            False


testResult : String -> String -> Mono.MonoDtPath -> Test.Test -> Maybe Bool
testResult scrut ctor path test =
    if isRoot scrut path then
        case test of
            Test.IsCtor _ name _ _ _ ->
                Just (name == ctor)

            _ ->
                Nothing

    else
        Nothing


{-| `e` with each destructuring of a field of `scrut` replaced by a binding of
the constructor's argument for it: `MonoIndex k` of `scrut` reads argument `k`.
A deeper path through such a field is re-rooted on the argument when the
argument is a local variable.
-}
bindFields : String -> Known -> MonoExpr -> MonoExpr
bindFields scrut known e =
    Traverse.mapExpr
        (\sub ->
            case sub of
                MonoDestruct (Mono.MonoDestructor name path ty) inner t ->
                    case path of
                        Mono.MonoIndex k (Mono.CustomContainer _) _ (Mono.MonoRoot root _) ->
                            if root == scrut then
                                case List.drop k known.args |> List.head of
                                    Just arg ->
                                        Just (MonoLet (Mono.MonoDef name arg) inner t)

                                    Nothing ->
                                        Nothing

                            else
                                Nothing

                        _ ->
                            case rerootPath scrut known path of
                                Just path1 ->
                                    Just (MonoDestruct (Mono.MonoDestructor name path1 ty) inner t)

                                Nothing ->
                                    Nothing

                _ ->
                    Nothing
        )
        e


rerootPath : String -> Known -> Mono.MonoPath -> Maybe Mono.MonoPath
rerootPath scrut known path =
    case path of
        Mono.MonoIndex k (Mono.CustomContainer _) _ (Mono.MonoRoot root _) ->
            if root == scrut then
                case List.drop k known.args |> List.head of
                    Just (MonoVarLocal n t) ->
                        Just (Mono.MonoRoot n t)

                    _ ->
                        Nothing

            else
                Nothing

        Mono.MonoIndex i kind ty inner ->
            Maybe.map (Mono.MonoIndex i kind ty) (rerootPath scrut known inner)

        Mono.MonoField n ty inner ->
            Maybe.map (Mono.MonoField n ty) (rerootPath scrut known inner)

        Mono.MonoUnbox ty inner ->
            Maybe.map (Mono.MonoUnbox ty) (rerootPath scrut known inner)

        Mono.MonoRoot _ _ ->
            Nothing


{-| Whether `name` occurs in `e` as a variable, a destructuring root or a
decision-tree root.
-}
usesName : String -> MonoExpr -> Bool
usesName name e =
    Traverse.foldExpr
        (\sub found ->
            found
                || (case sub of
                        MonoVarLocal n _ ->
                            n == name

                        MonoDestruct (Mono.MonoDestructor _ path _) _ _ ->
                            pathRoot path == name

                        MonoCase _ scrut _ _ _ ->
                            scrut == name

                        MonoClosure info _ _ ->
                            List.any (\( n, _, _ ) -> n == name) info.captures

                        MonoTailCall n _ _ ->
                            n == name

                        _ ->
                            False
                   )
        )
        False
        e


pathRoot : Mono.MonoPath -> String
pathRoot path =
    case path of
        Mono.MonoRoot n _ ->
            n

        Mono.MonoIndex _ _ _ inner ->
            pathRoot inner

        Mono.MonoField _ _ inner ->
            pathRoot inner

        Mono.MonoUnbox _ inner ->
            pathRoot inner
