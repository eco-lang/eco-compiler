module TestLogic.Monomorphize.LssLocalMultiUseInjectTest exposing (suite)

{-| Checks that when a let-bound function is passed as an argument to a
global, the global's specialization records exactly which function it
receives.

Unless the solver writes the passed function's member id at the call, the
callee's parameter carries an unwritten lambda set. That set names no
function, so a call through the parameter cannot be made direct and goes
through generic dispatch.

A few terms. With lambda-set specialization (LSS) on, each arrow in a
monomorphized type carries a `Mono.LambdaSetAnno`, and `LSet ms` lists the
_member ids_ of the function values that can reach it. The solver engine
gives a let-bound function that is not tail-recursive one _instance_ per
distinct type it is used at: a separate binding named `f`, `f$1`, `f$2` and so
on. A tail-recursive one is translated only once. When the binding's
right-hand side is a lambda, the instance's closure holds its member id in
`lssMember`; when it is a partial application of a global, the member is a
PAP member that `lssMemberOrigins` records as `OriginPap`. A _registry row_ is
one specialization of a global: an entry of the graph registry's
`reverseMapping`, holding the global and its specialized type. The _callback
annotation_ of a callee is the annotation on the head arrow of its first
parameter's type, read from each of its registry rows. Callback annotations
_match_ a function's instances when there is at least one annotation, every
annotation is a singleton `LSet [m]` whose `m` is the member id of one of the
instances, and every instance's member id is named by some annotation.

Each fixture is compiled with `runWith` or `runWithPap`: the solver engine
with LSS enabled and default specialization limits, stopping at the
monomorphized graph. Three fixtures are used. In `twoInstances`, `ident x = x`
is passed to `applyI` with an `Int` and to `applyS` with a `String`. In
`selfReference`, `go` passes itself to `applyI` both from its own body and from
the let body. In `papRhs`, `h = apply2 inc` is a partial application, and `h`
is passed to `useF`, which passes it on to `applyI`.

The tests are numbered 2, 3, 4 and 7 in their names. They establish:

  - Test 2: `twoInstances` yields exactly two instances of `ident`, and the
    callback annotations of every `applyI` and `applyS` row match them.
  - Test 3: the member ids of the instances of `ident` in `twoInstances`
    include exactly two distinct values.
  - Test 4: `selfReference` yields at least one instance of `go`, and the
    callback annotations of every `applyI` row match them.
  - Test 7: `papRhs` yields exactly one `useF` row, its callback annotation is
    a singleton, and `lssMemberOrigins` records that member as `OriginPap` of
    a global named `apply2` with one argument supplied.

Among what is not tested: annotations on any arrow other than the head of the
first parameter; a local function whose binding is a tail-recursive definition
or is not bound directly to a closure, which `instanceMembers` does not find;
the module of the callee or of `apply2`, since rows are matched by name only;
and anything after monomorphization, such as whether a call is devirtualized.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , define
        , ifExpr
        , intExpr
        , letExpr
        , makeModuleWithTypedDefs
        , pVar
        , strExpr
        , tLambda
        , tTuple
        , tType
        , tupleExpr
        , varExpr
        )
import Compiler.Eco.Config as Config
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The four tests described in the module docstring.
-}
suite : Test
suite =
    Test.describe "F2 local-multi use-site member injection"
        [ Test.test "2. both instances — each callee's callback is the SINGLETON of ITS instance closure" <|
            \() ->
                case runWith twoInstances of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        let
                            heads =
                                calleeHeads [ "applyI", "applyS" ] g

                            instances =
                                instanceMembers "ident" g
                        in
                        if List.length instances /= 2 then
                            Expect.fail ("fixture broken: expected 2 instances of `ident`, got " ++ describeInstances instances)

                        else
                            expectJoin heads instances
        , Test.test "3. the two instances carry DISTINCT ids (ordinal 1 is tagged)" <|
            \() ->
                case runWith twoInstances of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        let
                            ids =
                                List.map Tuple.second (instanceMembers "ident" g)
                        in
                        if List.length (distinct ids) == 2 then
                            Expect.pass

                        else
                            Expect.fail ("expected 2 distinct instance ids, got " ++ describeInts ids)
        , Test.test "4. F2.b: a self-reference inside the instance RHS names the instance too" <|
            \() ->
                case runWith selfReference of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        let
                            heads =
                                calleeHeads [ "applyI" ] g

                            instances =
                                instanceMembers "go" g
                        in
                        if List.isEmpty instances then
                            Expect.fail "fixture broken: no instance of `go`"

                        else
                            expectJoin heads instances
        , Test.test "7. F2.c: a local whose RHS is a PARTIAL APPLICATION names the PAP member at its use" <|
            \() ->
                case runWithPap papRhs of
                    Err e ->
                        Expect.fail e

                    Ok ((Mono.MonoGraph g) as graph) ->
                        case calleeHeads [ "useF" ] graph of
                            [ ( _, Mono.LSet [ m ] ) ] ->
                                case Dict.get m g.lssMemberOrigins of
                                    Just (Mono.OriginPap (Mono.Global _ gname) 1) ->
                                        if gname == "apply2" then
                                            Expect.pass

                                        else
                                            Expect.fail ("PAP member names the wrong global: " ++ gname)

                                    other ->
                                        Expect.fail ("expected a p|apply2|1 origin for member " ++ String.fromInt m ++ ", got " ++ Debug.toString other)

                            heads ->
                                Expect.fail ("expected one useF spec with a singleton callback, got " ++ describeHeads heads)
        ]


{-| Passes when `heads` is not empty, every annotation in `heads` is a
singleton `LSet [m]` whose `m` is the member id of one of `instances`, and every
member id in `instances` is named by some annotation in `heads`.

An empty `heads` fails as a broken fixture. An `LSet` with no members or with
more than one fails like any other annotation that is not a singleton.

-}
expectJoin : List ( String, Mono.LambdaSetAnno ) -> List ( String, Int ) -> Expect.Expectation
expectJoin heads instances =
    let
        ids =
            List.map Tuple.second instances

        bad =
            List.filter
                (\( _, anno ) ->
                    case anno of
                        Mono.LSet [ m ] ->
                            not (List.member m ids)

                        _ ->
                            True
                )
                heads

        named =
            List.filterMap
                (\( _, anno ) ->
                    case anno of
                        Mono.LSet [ m ] ->
                            Just m

                        _ ->
                            Nothing
                )
                heads
    in
    if List.isEmpty heads then
        Expect.fail "fixture broken: no callee spec"

    else if not (List.isEmpty bad) then
        Expect.fail ("callee callback annotations not the instance singleton: " ++ describeHeads bad ++ "; instances " ++ describeInstances instances)

    else if List.any (\m -> not (List.member m named)) ids then
        Expect.fail ("an instance is named by no callee: instances " ++ describeInstances instances ++ ", callees " ++ describeHeads heads)

    else
        Expect.pass



-- ====== FIXTURES ======


{-| The source type `Int -> Int`.
-}
hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


{-| The source type `String -> String`.
-}
hStr : Src.Type
hStr =
    tLambda (tType "String" []) (tType "String" [])


{-| A program in which `testValue` binds `ident x = x` in a `let` and passes it
to `applyI` with `3` and to `applyS` with `"a"`, so `ident` is used at
`Int -> Int` and at `String -> String`. `applyI` and `applyS` apply their first
argument to their second.
-}
twoInstances : Src.Module
twoInstances =
    makeModuleWithTypedDefs "Test"
        [ { name = "applyI"
          , args = [ pVar "f", pVar "n" ]
          , tipe = tLambda hInt hInt
          , body = callExpr (varExpr "f") [ varExpr "n" ]
          }
        , { name = "applyS"
          , args = [ pVar "f", pVar "s" ]
          , tipe = tLambda hStr hStr
          , body = callExpr (varExpr "f") [ varExpr "s" ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tTuple (tType "Int" []) (tType "String" [])
          , body =
                letExpr
                    [ define "ident" [ pVar "x" ] (varExpr "x") ]
                    (tupleExpr
                        (callExpr (varExpr "applyI") [ varExpr "ident", intExpr 3 ])
                        (callExpr (varExpr "applyS") [ varExpr "ident", strExpr "a" ])
                    )
          }
        ]


{-| A program in which `testValue` binds
`go n = if n > 0 then applyI go (n - 1) else n` in a `let` and evaluates
`applyI go 3`, so `go` is passed to `applyI` from inside its own body as well
as from the `let` body. `applyI` applies its first argument to its second.
-}
selfReference : Src.Module
selfReference =
    makeModuleWithTypedDefs "Test"
        [ { name = "applyI"
          , args = [ pVar "f", pVar "n" ]
          , tipe = tLambda hInt hInt
          , body = callExpr (varExpr "f") [ varExpr "n" ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                letExpr
                    [ define "go"
                        [ pVar "n" ]
                        (ifExpr (binopsExpr [ ( varExpr "n", ">" ) ] (intExpr 0))
                            (callExpr (varExpr "applyI") [ varExpr "go", binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1) ])
                            (varExpr "n")
                        )
                    ]
                    (callExpr (varExpr "applyI") [ varExpr "go", intExpr 3 ])
          }
        ]


{-| A program in which `testValue` binds `h = apply2 inc` in a `let` and
evaluates `useF h`. `apply2` takes two arguments, so `h` is a partial
application of it. `useF g` evaluates `applyI g 3`, and `apply2` and `applyI`
both apply their first argument to their second.
-}
papRhs : Src.Module
papRhs =
    makeModuleWithTypedDefs "Test"
        [ { name = "inc", args = [ pVar "x" ], tipe = hInt, body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1) }
        , { name = "apply2", args = [ pVar "f", pVar "n" ], tipe = tLambda hInt hInt, body = callExpr (varExpr "f") [ varExpr "n" ] }
        , { name = "applyI", args = [ pVar "f", pVar "n" ], tipe = tLambda hInt hInt, body = callExpr (varExpr "f") [ varExpr "n" ] }
        , { name = "useF", args = [ pVar "g" ], tipe = tLambda hInt (tType "Int" []), body = callExpr (varExpr "applyI") [ varExpr "g", intExpr 3 ] }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                letExpr
                    [ define "h" [] (callExpr (varExpr "apply2") [ varExpr "inc" ]) ]
                    (callExpr (varExpr "useF") [ varExpr "h" ])
          }
        ]



-- ====== HARNESS ======


{-| Compiles a fixture with the solver engine, lambda-set specialization
enabled and default specialization limits, and returns the monomorphized graph
or the error message the pipeline returns. It does exactly what `runWith` does.
-}
runWithPap : Src.Module -> Result String Mono.MonoGraph
runWithPap srcModule =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        { defaults | enabled = True }
        srcModule


{-| Compiles a fixture with the solver engine, lambda-set specialization
enabled and default specialization limits, and returns the monomorphized graph
or the error message the pipeline returns.
-}
runWith : Src.Module -> Result String Mono.MonoGraph
runWith srcModule =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits Config.defaultLimits
        { defaults | enabled = True }
        srcModule



-- ====== READERS ======


{-| Returns the name and callback annotation of every registry row whose
global is named in `targets`: the annotation on the head arrow of the row's
first parameter type.

Globals are matched by name alone, whatever their module. A row with no
parameters, or whose type is not a function, is left out.

-}
calleeHeads : List String -> Mono.MonoGraph -> List ( String, Mono.LambdaSetAnno )
calleeHeads targets (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, Mono.MFunction _ _ (p0 :: _) _ ) ->
                    if List.member name targets then
                        ( name, Mono.headAnno p0 ) :: acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


{-| Returns the binding name and member id of every instance of the let-bound
function `defName` found in the bodies of the graph's nodes.

An instance is found only where a `MonoDef` binds a closure directly, under
`defName` or a name starting with `defName` followed by `$`, and the closure
has an `lssMember`. Only `MonoDefine` and `MonoTailFunc` nodes are searched.

-}
instanceMembers : String -> Mono.MonoGraph -> List ( String, Int )
instanceMembers defName (Mono.MonoGraph g) =
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just node ->
                    List.foldl (collectInstances defName) acc (nodeExprsOf node)

                Nothing ->
                    acc
        )
        []
        g.nodes


{-| Adds to `acc` the binding name and member id of every instance of `defName`
in `expr`, as `instanceMembers` defines an instance.
-}
collectInstances : String -> Mono.MonoExpr -> List ( String, Int ) -> List ( String, Int )
collectInstances defName expr acc =
    MonoTraverse.foldExpr
        (\e a ->
            case e of
                Mono.MonoLet (Mono.MonoDef n (Mono.MonoClosure info _ _)) _ _ ->
                    if n == defName || String.startsWith (defName ++ "$") n then
                        case info.lssMember of
                            Just m ->
                                ( n, m ) :: a

                            Nothing ->
                                a

                    else
                        a

                _ ->
                    a
        )
        acc
        expr


{-| Returns the body of a `MonoDefine` or `MonoTailFunc` node, and nothing for
any other kind of node.
-}
nodeExprsOf : Mono.MonoNode -> List Mono.MonoExpr
nodeExprsOf node =
    case node of
        Mono.MonoDefine e _ ->
            [ e ]

        Mono.MonoTailFunc _ e _ ->
            [ e ]

        _ ->
            []


{-| Tells whether an annotation is an `LSet`, including one with no members.
Nothing in this module calls it.
-}
isSet : Mono.LambdaSetAnno -> Bool
isSet anno =
    case anno of
        Mono.LSet _ ->
            True

        _ ->
            False


{-| Returns each value of a list once, in reverse order of first occurrence.
-}
distinct : List Int -> List Int
distinct =
    List.foldl
        (\x acc ->
            if List.member x acc then
                acc

            else
                x :: acc
        )
        []


{-| Renders a list of numbers as `[1,2]`, for failure messages.
-}
describeInts : List Int -> String
describeInts xs =
    "[" ++ String.join "," (List.map String.fromInt xs) ++ "]"


{-| Renders instances as `[name=member, ...]`, for failure messages.
-}
describeInstances : List ( String, Int ) -> String
describeInstances xs =
    "[" ++ String.join ", " (List.map (\( n, m ) -> n ++ "=" ++ String.fromInt m) xs) ++ "]"


{-| Renders callback annotations as `[callee:annotation, ...]`, for failure
messages.
-}
describeHeads : List ( String, Mono.LambdaSetAnno ) -> String
describeHeads xs =
    "[" ++ String.join ", " (List.map (\( n, a ) -> n ++ ":" ++ describeAnno a) xs) ++ "]"


{-| Renders an annotation as its constructor name followed by its payload, for
failure messages.
-}
describeAnno : Mono.LambdaSetAnno -> String
describeAnno anno =
    case anno of
        Mono.LSet ms ->
            "LSet" ++ describeInts ms

        Mono.LVar v ->
            "LVar" ++ String.fromInt v

        Mono.LTop k ->
            "LTop" ++ String.fromInt k

        Mono.LPartial ms ->
            "LPartial" ++ describeInts ms
