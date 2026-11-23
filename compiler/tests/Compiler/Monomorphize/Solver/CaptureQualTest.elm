module Compiler.Monomorphize.Solver.CaptureQualTest exposing (suite)

{-| Checks the capture signatures that the solver engine adds to the keys of
lambda members (plans/lss-capture-qualified-members.md): how a signature is
rendered, that one lambda instance gets one id wherever it is minted, and that
monomorphization still terminates when recursion wraps lambdas in lambdas.

Under lambda-set specialization every function arrow carries an annotation
naming the function values (_members_) that can flow through it. A lambda
translated inside a specialization (spec) gets a member id interned from a key.
The key starts with the lambda's _family key_, `l|<raw lambda id>|<widened
key>`, and, when the lambda's body uses function values it does not bind, ends
with a _capture signature_: for each such free local, in name order, its name
and the annotations of the arrows in its type. A captured lambda member is
written by its family number, `f<n>`, never by its own id. ⊤ and a set
variable are both written `?`.

**Rendering.** `Engine.renderCaptureSig` and `Engine.withCaptureSig` are
tested directly, with no pipeline.

**Agreement.** One lambda instance is minted at several places: where it is
passed as an argument, where it is translated, at each use of a local-multi
function whose right-hand side it is, and where a recursive `let` function
refers to itself. The callee's demand gets the id from the first place and the
closure from the second, so they must agree, or a call could be stamped with
another closure's code. `argMembersAgree` checks every call to a global in a
monomorphized graph: where argument `i` is a closure carrying member `m`, or a
local variable a `let` binds to such a closure, the
callee's parameter `i` must be an arrow whose annotation is ⊤, a set variable,
a partial set, or a set containing `m`. Four fixtures exercise the four places.

**Termination.** A lambda's key names the families of the lambdas it captures,
so keys nest one level deep and the set of keys is finite. The μ-tie alone
does not stop the two fixtures here, where recursion alternates between two
lambdas, or two functions each wrap the other's function. They run with the
default unlimited per-global budget (so no spec is widened) and with the spec
watchdog lowered to 64 (`specBreadth`), so a run that does not terminate fails
with the watchdog's error instead of running on.

The tests establish:

  - An empty pair list, or pairs whose types have no arrow, render the empty
    signature, and `withCaptureSig` leaves a key unchanged for it.
  - Members are written sorted and once; a member with a family as `f<n>`; ⊤
    and a set variable alike as `?`; a partial set as `~[...]`; a function's own
    annotation before those in its argument types; names joined with `;` in
    the order given.
  - In each agreement fixture, every closure passed straight to a global has
    its member in the callee's parameter set, and at least one such closure is
    checked.
  - The alternating fixture finishes with at most 5 specs of `alt` (the trace
    in the plan's §3.2 gives exactly 5), and the mutual fixture with at most 3
    specs each of `ping` and `pong`.

Among what is not tested: calls through local functions; the order in which
the four mint sites are reached; the stamps AbiCloning gives; and the
substitution engine.

-}

import Array
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
        , callExpr
        , define
        , ifExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , makeModuleWithTypedDefs
        , pVar
        , strExpr
        , tLambda
        , tTuple
        , tType
        , tVar
        , tupleExpr
        , varExpr
        )
import Compiler.Config as Config
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Traverse as MonoTraverse
import Compiler.IR.Source as Src
import Compiler.Monomorphize.Solver.Engine as Engine
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The tests of capture signatures: rendering, agreement across mint sites,
and termination.
-}
suite : Test
suite =
    Test.describe "Capture-qualified members"
        [ Test.describe "rendering" renderPins
        , Test.describe "one id per lambda instance across mint sites" agreementPins
        , Test.describe "termination under recursion that wraps lambdas" terminationPins
        ]



-- ====== 1. RENDERING ======


{-| `Int -> Int` with `anno` on its arrow.
-}
intFn : Mono.LambdaSetAnno -> Mono.MonoType
intFn anno =
    Mono.mFunction anno [ Mono.MInt ] Mono.MInt


{-| The tests of `Engine.renderCaptureSig` and `Engine.withCaptureSig`.
-}
renderPins : List Test
renderPins =
    [ Test.test "no pairs render the empty signature" <|
        \() -> Expect.equal "" (Engine.renderCaptureSig Dict.empty [])
    , Test.test "a name whose type has no arrow is left out" <|
        \() -> Expect.equal "" (Engine.renderCaptureSig Dict.empty [ ( "x", Mono.MInt ), ( "s", Mono.MString ) ])
    , Test.test "members are sorted and written once" <|
        \() -> Expect.equal "f=[3,5]" (Engine.renderCaptureSig Dict.empty [ ( "f", intFn (Mono.LSet [ 5, 3, 3 ]) ) ])
    , Test.test "top and a set variable render alike" <|
        \() ->
            Expect.equal
                (Engine.renderCaptureSig Dict.empty [ ( "f", intFn Mono.topLegacy ) ])
                (Engine.renderCaptureSig Dict.empty [ ( "f", intFn (Mono.LVar 4) ) ])
    , Test.test "top renders as ?" <|
        \() -> Expect.equal "f=?" (Engine.renderCaptureSig Dict.empty [ ( "f", intFn Mono.topLegacy ) ])
    , Test.test "a partial set renders with ~" <|
        \() -> Expect.equal "f=~[7]" (Engine.renderCaptureSig Dict.empty [ ( "f", intFn (Mono.LPartial [ 7 ]) ) ])
    , Test.test "a lambda member renders by its family, members of one family once" <|
        \() ->
            Expect.equal "f=[4,f2]"
                (Engine.renderCaptureSig (Dict.fromList [ ( 9, 2 ), ( 10, 2 ) ])
                    [ ( "f", intFn (Mono.LSet [ 10, 9, 4 ]) ) ]
                )
    , Test.test "a function's own annotation comes before those in its arguments" <|
        \() ->
            Expect.equal "f=[2],[1]"
                (Engine.renderCaptureSig Dict.empty
                    [ ( "f", Mono.mFunction (Mono.LSet [ 2 ]) [ intFn (Mono.LSet [ 1 ]) ] Mono.MInt ) ]
                )
    , Test.test "names are joined with ; in the order given, arrowless ones left out" <|
        \() ->
            Expect.equal "a=[1];c=[2]"
                (Engine.renderCaptureSig Dict.empty
                    [ ( "a", intFn (Mono.LSet [ 1 ]) ), ( "b", Mono.MInt ), ( "c", intFn (Mono.LSet [ 2 ]) ) ]
                )
    , Test.test "withCaptureSig leaves a key unchanged for the empty signature" <|
        \() -> Expect.equal "l|1|A(I->I)" (Engine.withCaptureSig "l|1|A(I->I)" "")
    , Test.test "withCaptureSig appends |c: and the signature" <|
        \() -> Expect.equal "l|1|A(I->I)|c:f=[1]" (Engine.withCaptureSig "l|1|A(I->I)" "f=[1]")
    ]



-- ====== 2. AGREEMENT ======


{-| Runs the solver engine with the default lambda-set settings over `m`.
-}
runMono : Config.SpecLimits -> Src.Module -> Result String Mono.MonoGraph
runMono limits m =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithReport limits { defaults | enabled = True } m
        |> Result.map Tuple.first


{-| Returns the parameter types of `t` over as many stages as it takes to
reach `count` parameters, or all of them if there are fewer.
-}
paramsUpTo : Int -> Mono.MonoType -> List Mono.MonoType
paramsUpTo count t =
    if count <= 0 then
        []

    else
        case t of
            Mono.MFunction _ _ params ret ->
                List.take count params ++ paramsUpTo (count - List.length params) ret

            _ ->
                []


{-| Returns how many closure arguments of calls to globals in `graph` were
checked, and a description of each one whose member is missing from the
callee's parameter set.
-}
argMembersAgree : Mono.MonoGraph -> ( Int, List String )
argMembersAgree (Mono.MonoGraph g) =
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just (Mono.MonoDefine body _) ->
                    checkExpr body acc

                Just (Mono.MonoTailFunc _ body _) ->
                    checkExpr body acc

                _ ->
                    acc
        )
        ( 0, [] )
        g.nodes


{-| Adds the closure arguments of every call to a global in `expr` to the
count, and a description of each disagreeing one to the list. An argument that
is a local variable bound by a `let` in `expr` to a closure counts as that
closure.
-}
checkExpr : Mono.MonoExpr -> ( Int, List String ) -> ( Int, List String )
checkExpr expr acc0 =
    let
        letClosures =
            MonoTraverse.foldExpr
                (\e acc ->
                    case e of
                        Mono.MonoLet (Mono.MonoDef name (Mono.MonoClosure info _ _)) _ _ ->
                            case info.lssMember of
                                Just m ->
                                    Dict.insert name m acc

                                Nothing ->
                                    acc

                        _ ->
                            acc
                )
                Dict.empty
                expr
    in
    MonoTraverse.foldExpr
        (\e acc ->
            case e of
                Mono.MonoCall _ (Mono.MonoVarGlobal _ specId calleeType) args _ _ ->
                    List.foldl (checkArg letClosures specId) acc (List.map2 Tuple.pair args (paramsUpTo (List.length args) calleeType))

                _ ->
                    acc
        )
        acc0
        expr


{-| Returns the member of the closure an argument is: a closure's own, or the
member of the closure a local variable is bound to by a `let`.
-}
argMember : Dict.Dict String Int -> Mono.MonoExpr -> Maybe Int
argMember letClosures arg =
    case arg of
        Mono.MonoClosure info _ _ ->
            info.lssMember

        Mono.MonoVarLocal name _ ->
            Dict.get name letClosures

        _ ->
            Nothing


{-| Checks one argument against its parameter type, as `argMembersAgree`
describes.
-}
checkArg : Dict.Dict String Int -> Int -> ( Mono.MonoExpr, Mono.MonoType ) -> ( Int, List String ) -> ( Int, List String )
checkArg letClosures specId ( arg, param ) ( checked, bad ) =
    case param of
        Mono.MFunction _ anno _ _ ->
            case argMember letClosures arg of
                Just m ->
                    case anno of
                        Mono.LSet ms ->
                            if List.member m ms then
                                ( checked + 1, bad )

                            else
                                ( checked + 1
                                , ("callee spec " ++ String.fromInt specId ++ ": closure member " ++ String.fromInt m ++ " not in parameter set " ++ Debug.toString ms) :: bad
                                )

                        _ ->
                            ( checked + 1, bad )

                Nothing ->
                    ( checked, bad )

        _ ->
            ( checked, bad )


{-| Returns the names that `let`s in the graph's node bodies bind to closures.
-}
letClosureNames : Mono.MonoGraph -> List String
letClosureNames (Mono.MonoGraph g) =
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just (Mono.MonoDefine body _) ->
                    MonoTraverse.foldExpr
                        (\e a ->
                            case e of
                                Mono.MonoLet (Mono.MonoDef name (Mono.MonoClosure _ _ _)) _ _ ->
                                    name :: a

                                _ ->
                                    a
                        )
                        acc
                        body

                _ ->
                    acc
        )
        []
        g.nodes


{-| Passes when `m` monomorphizes, at least one closure argument is checked,
and none disagrees.
-}
expectAgreement : Src.Module -> Expect.Expectation
expectAgreement m =
    case runMono Config.defaultLimits m of
        Err msg ->
            Expect.fail msg

        Ok graph ->
            case argMembersAgree graph of
                ( 0, _ ) ->
                    Expect.fail "no closure argument to a global was checked"

                ( _, [] ) ->
                    Expect.pass

                ( _, bad ) ->
                    Expect.fail (String.join "\n" bad)


{-| The agreement tests, one per mint site.
-}
agreementPins : List Test
agreementPins =
    [ Test.test "an argument lambda (injection and translation) — the split fixture" <|
        \() -> expectAgreement (splitModule threeCallsNo)
    , Test.test "three callers of one function, one passing a lambda" <|
        \() -> expectAgreement (splitModule threeCallsYes)
    , Test.test "a local-multi function capturing a function, used at two types" <|
        \() -> expectAgreement localMultiModule
    , Test.test "the local-multi fixture really has two let-bound instances of g" <|
        \() ->
            case runMono Config.defaultLimits localMultiModule of
                Err msg ->
                    Expect.fail msg

                Ok graph ->
                    Expect.equal [ "g", "g$1" ] (List.sort (List.filter (String.startsWith "g") (letClosureNames graph)))
    , Test.test "a recursive let function capturing a function, passed to a global" <|
        \() -> expectAgreement recursiveLetModule
    ]



-- ====== 3. TERMINATION ======


{-| Counts the specs in the graph's registry whose global is named `name`.
-}
specCount : String -> Mono.MonoGraph -> Int
specCount name (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ n, _ ) ->
                    if n == name then
                        acc + 1

                    else
                        acc

                _ ->
                    acc
        )
        0
        g.registry.reverseMapping


{-| The default limits with the per-global spec watchdog lowered to 64, so a
run that does not terminate fails fast.
-}
tightLimits : Config.SpecLimits
tightLimits =
    let
        d =
            Config.defaultLimits
    in
    { d | specBreadth = 64 }


{-| Passes when `m` monomorphizes under `tightLimits` with at most `bound`
specs of each global in `names`.
-}
expectBounded : Src.Module -> List ( String, Int ) -> Expect.Expectation
expectBounded m bounds =
    case runMono tightLimits m of
        Err msg ->
            Expect.fail msg

        Ok graph ->
            Expect.all
                (List.map
                    (\( name, bound ) _ ->
                        let
                            n =
                                specCount name graph
                        in
                        if n >= 1 && n <= bound then
                            Expect.pass

                        else
                            Expect.fail (name ++ ": expected 1.." ++ String.fromInt bound ++ " specs, got " ++ String.fromInt n)
                    )
                    bounds
                )
                ()


{-| The termination tests.
-}
terminationPins : List Test
terminationPins =
    [ Test.test "recursion alternating two wrapping lambdas closes (alt)" <|
        \() -> expectBounded alternatingModule [ ( "alt", 5 ) ]
    , Test.test "mutual recursion wrapping each other's function closes (ping/pong)" <|
        \() -> expectBounded mutualModule [ ( "ping", 3 ), ( "pong", 3 ) ]
    ]



-- ====== FIXTURES ======


{-| `Int -> Int`.
-}
intToInt : Src.Type
intToInt =
    tLambda (tType "Int" []) (tType "Int" [])


{-| `inc x = x + 1`.
-}
incDef : TypedDef
incDef =
    { name = "inc", args = [ pVar "x" ], tipe = intToInt, body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1) }


{-| `dec x = x - 1`.
-}
decDef : TypedDef
decDef =
    { name = "dec", args = [ pVar "x" ], tipe = intToInt, body = binopsExpr [ ( varExpr "x", "-" ) ] (intExpr 1) }


{-| `applyHof g y = g y`.
-}
applyHofDef : TypedDef
applyHofDef =
    { name = "applyHof"
    , args = [ pVar "g", pVar "y" ]
    , tipe = tLambda intToInt intToInt
    , body = callExpr (varExpr "g") [ varExpr "y" ]
    }


{-| Whether the split fixture's `testValue` makes a third call of `mid`, with
a lambda.
-}
type ThirdCall
    = ThirdCall Bool


{-| No third call.
-}
threeCallsNo : ThirdCall
threeCallsNo =
    ThirdCall False


{-| A third call, `mid (\x -> x * 3) 3`.
-}
threeCallsYes : ThirdCall
threeCallsYes =
    ThirdCall True


{-| The split fixture of `LayoutQualTest`: `mid f x = applyHof (\v -> f (v + x)) x`,
with `testValue = mid inc 1 + mid dec 2`, plus `mid (\x -> x * 3) 3` when
asked.
-}
splitModule : ThirdCall -> Src.Module
splitModule (ThirdCall third) =
    let
        twoCalls =
            binopsExpr
                [ ( callExpr (varExpr "mid") [ varExpr "inc", intExpr 1 ], "+" ) ]
                (callExpr (varExpr "mid") [ varExpr "dec", intExpr 2 ])
    in
    makeModuleWithTypedDefs "Test"
        [ incDef
        , decDef
        , applyHofDef
        , { name = "mid"
          , args = [ pVar "f", pVar "x" ]
          , tipe = tLambda intToInt intToInt
          , body =
                callExpr (varExpr "applyHof")
                    [ lambdaExpr [ pVar "v" ]
                        (callExpr (varExpr "f") [ binopsExpr [ ( varExpr "v", "+" ) ] (varExpr "x") ])
                    , varExpr "x"
                    ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                if third then
                    binopsExpr
                        [ ( twoCalls, "+" ) ]
                        (callExpr (varExpr "mid")
                            [ lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "*" ) ] (intExpr 3))
                            , intExpr 3
                            ]
                        )

                else
                    twoCalls
          }
        ]


{-| `apply h z = h z`, `wrap f = let g y = ( f 1, y ) in ( apply g 1, apply g "s" )`
and `testValue = wrap inc`. `g` captures `f` and is used at `Int` and at
`String`, so it is a local-multi function with two instances.
-}
localMultiModule : Src.Module
localMultiModule =
    makeModuleWithTypedDefs "Test"
        [ incDef
        , { name = "apply"
          , args = [ pVar "h", pVar "z" ]
          , tipe = tLambda (tLambda (tVar "a") (tVar "b")) (tLambda (tVar "a") (tVar "b"))
          , body = callExpr (varExpr "h") [ varExpr "z" ]
          }
        , { name = "wrap"
          , args = [ pVar "f" ]
          , tipe =
                tLambda intToInt
                    (tTuple (tTuple (tType "Int" []) (tType "Int" []))
                        (tTuple (tType "Int" []) (tType "String" []))
                    )
          , body =
                letExpr
                    [ define "g" [ pVar "y" ] (tupleExpr (callExpr (varExpr "f") [ intExpr 1 ]) (varExpr "y")) ]
                    (tupleExpr
                        (callExpr (varExpr "apply") [ varExpr "g", intExpr 1 ])
                        (callExpr (varExpr "apply") [ varExpr "g", strExpr "s" ])
                    )
          }
        , { name = "testValue"
          , args = []
          , tipe =
                tTuple (tTuple (tType "Int" []) (tType "Int" []))
                    (tTuple (tType "Int" []) (tType "String" []))
          , body = callExpr (varExpr "wrap") [ varExpr "inc" ]
          }
        ]


{-| `rec f n = let go k = if k <= 0 then f 0 else 1 + go (k - 1) in applyHof go n`
and `testValue = rec inc 3 + rec dec 4`. `go` captures `f` and refers to itself
outside tail position.
-}
recursiveLetModule : Src.Module
recursiveLetModule =
    makeModuleWithTypedDefs "Test"
        [ incDef
        , decDef
        , applyHofDef
        , { name = "rec"
          , args = [ pVar "f", pVar "n" ]
          , tipe = tLambda intToInt intToInt
          , body =
                letExpr
                    [ define "go"
                        [ pVar "k" ]
                        (ifExpr
                            (binopsExpr [ ( varExpr "k", "<=" ) ] (intExpr 0))
                            (callExpr (varExpr "f") [ intExpr 0 ])
                            (binopsExpr [ ( intExpr 1, "+" ) ]
                                (callExpr (varExpr "go") [ binopsExpr [ ( varExpr "k", "-" ) ] (intExpr 1) ])
                            )
                        )
                    ]
                    (callExpr (varExpr "applyHof") [ varExpr "go", varExpr "n" ])
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                binopsExpr
                    [ ( callExpr (varExpr "rec") [ varExpr "inc", intExpr 3 ], "+" ) ]
                    (callExpr (varExpr "rec") [ varExpr "dec", intExpr 4 ])
          }
        ]


{-| `alt n f = if n <= 0 then f 0 else alt (n - 1) (\x -> f x + 1) + alt (n - 2) (\x -> f x * 2)`
and `testValue = alt 3 (\x -> x)`: each level passes on one of two lambdas that
wrap its own `f`.
-}
alternatingModule : Src.Module
alternatingModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "alt"
          , args = [ pVar "n", pVar "f" ]
          , tipe = tLambda (tType "Int" []) (tLambda intToInt (tType "Int" []))
          , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
                    (callExpr (varExpr "f") [ intExpr 0 ])
                    (binopsExpr
                        [ ( callExpr (varExpr "alt")
                                [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                                , lambdaExpr [ pVar "x" ]
                                    (binopsExpr [ ( callExpr (varExpr "f") [ varExpr "x" ], "+" ) ] (intExpr 1))
                                ]
                          , "+"
                          )
                        ]
                        (callExpr (varExpr "alt")
                            [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 2)
                            , lambdaExpr [ pVar "x" ]
                                (binopsExpr [ ( callExpr (varExpr "f") [ varExpr "x" ], "*" ) ] (intExpr 2))
                            ]
                        )
                    )
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body = callExpr (varExpr "alt") [ intExpr 3, lambdaExpr [ pVar "x" ] (varExpr "x") ]
          }
        ]


{-| `ping n f = if n <= 0 then f 0 else pong (n - 1) (\x -> f x + 1)`,
`pong n g = if n <= 0 then g 0 else ping (n - 1) (\y -> g y * 2)` and
`testValue = ping 4 inc`: each function wraps the other's function.
-}
mutualModule : Src.Module
mutualModule =
    let
        wrapper self other fName wrapped op =
            { name = self
            , args = [ pVar "n", pVar fName ]
            , tipe = tLambda (tType "Int" []) (tLambda intToInt (tType "Int" []))
            , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
                    (callExpr (varExpr fName) [ intExpr 0 ])
                    (callExpr (varExpr other)
                        [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                        , lambdaExpr [ pVar wrapped ]
                            (binopsExpr [ ( callExpr (varExpr fName) [ varExpr wrapped ], op ) ] (intExpr 2))
                        ]
                    )
            }
    in
    makeModuleWithTypedDefs "Test"
        [ incDef
        , wrapper "ping" "pong" "f" "x" "+"
        , wrapper "pong" "ping" "g" "y" "*"
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body = callExpr (varExpr "ping") [ intExpr 4, varExpr "inc" ]
          }
        ]
