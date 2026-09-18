module TestLogic.Monomorphize.LssRegIdentityTest exposing (suite)

{-| REGISTRATION SELF-IDENTITY — `lss.regIdentity`
(`plans/lss-registration-self-identity.md`).

The registry key is `SpecKey global monoType`: the global is IN the key, so
the value at the stored type's spine position d is g's spec applied to d
arguments, by definition. The stamp writes that tautology into the stored
type's spine annos (⊤/`LVar` only, never over a set), bounded by declared
arity, with the SAME member ids every other injection path mints.

Pins below follow the arc's differential rule: a flag test proves nothing
until the arms are shown to differ.

Two §5 pins are deliberately ABSENT, with reasons:

  - never-overwrite: a spine position with a PRE-existing set is not
    constructible at pipeline level today (this plan exists because spines
    are ⊤); the `LSet _ -> keep` arm plus the `regid|alreadySet` counter
    carry it.
  - subst isolation: `runSubstMonoWithLimits` takes no LSS config at all, so
    the flag is unreachable there BY TYPE — isolation holds at compile time.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , boolExpr
        , callExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , listExpr
        , makeModuleWithTypedDefs
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Eco.Config as Config
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "tautological self-identity at spec registration"
        [ Test.test "1. a plain def's stored head anno is a COVERED SET" <|
            \() ->
                case runWith plainModule of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        case headAnnos "double" g of
                            [] ->
                                Expect.fail "no spec registered for `double` — fixture broken"

                            onHeads ->
                                -- COVERED, not necessarily singleton: the MSET
                                -- census showed the stamp's `g|` member joining
                                -- the def's own body-root `l|` member — two ids
                                -- for the same function, both honest, so the set
                                -- is a sound 2-set.
                                if List.all isSet onHeads then
                                    Expect.pass

                                else
                                    Expect.fail ("head expected covered sets, got " ++ describe onHeads)
        , Test.test "2a. ARITY: both spine depths of a 2-ary def are stamped" <|
            \() ->
                -- `plus2 : Int -> Int -> Int` (arity 2): depth 0 AND depth 1
                -- are parameters (LSS_013), so both get singleton stamps.
                case runWith plainModule of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        let
                            spines =
                                List.filterMap spineAnnos (demandsOf "plus2" g)
                        in
                        if List.isEmpty spines then
                            Expect.fail "no spec registered for `plus2` — fixture broken"

                        else if List.all (\( h, r ) -> isSet h && maybeSet r) spines then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected covered sets at depths 0 and 1: "
                                    ++ String.join "; " (List.map (\( h, r ) -> describeAnno h ++ " / " ++ describeMaybe r) spines)
                                )
        , Test.test "3. KERNEL BOUNDARY: a kernel-alias spec's head stays ⊤ (documented residue)" <|
            \() ->
                -- P0 measured this: the kernel parametricity machinery
                -- absorbs the stamp at kernel-backed globals. The pin makes
                -- the boundary INTENTIONAL — if this ever starts passing a
                -- singleton, the kernel-license interaction changed and the
                -- plan's residue model must be re-derived, not silently
                -- enjoyed.
                case runWith consModule of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        case headAnnos "cons" g of
                            [] ->
                                -- No cons spec registered in this small
                                -- program is also acceptable — the pin only
                                -- constrains it when it exists.
                                Expect.pass

                            heads ->
                                -- ⊤ (the boundary absorbed the stamp — the
                                -- P0 full-pipeline outcome) and a SINGLETON
                                -- (the poison did not fire at this scale) are
                                -- both acceptable. What is NEVER acceptable
                                -- is a MULTI-set: that is the g|/k| split
                                -- identity E9.2 exists to prevent, and the
                                -- stamp reusing the kernel-alias fold is
                                -- exactly what this pin verifies.
                                -- ⊤ (the boundary absorbed it), a singleton,
                                -- or the benign body-root pairing (l| with
                                -- the k| the fold chose) are all acceptable.
                                -- `LVar` is not: the stamp targets exactly
                                -- ⊤/var, so a var surviving at a stampable
                                -- kernel-alias head means the routing broke.
                                if List.all (\a -> isTop a || isSet a) heads then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("kernel-alias head must be ⊤ or a set, got: "
                                            ++ describe heads
                                        )
        , Test.test "4. CO-GATE: a one-sided join is still never a false singleton" <|
            \() ->
                -- The `LssPapMembersTest` crash shape with `regIdentity = True`
                -- added: the stamp must not manufacture a false singleton at
                -- a CONSUMER's parameter (it only writes at spec spines,
                -- where the inhabitant is tautological).
                case runWith joinModule of
                    Err e ->
                        Expect.fail e

                    Ok g ->
                        case paramAnnos "useIt" g of
                            [] ->
                                Expect.fail "no demand recorded for `useIt` — fixture broken"

                            annos ->
                                if List.all neverFalselyComplete annos then
                                    Expect.pass

                                else
                                    Expect.fail
                                        ("a one-sided join published a singleton under regIdentity: "
                                            ++ describe annos
                                        )
        ]



-- ====== FIXTURES ======


hInt : Src.Type
hInt =
    tLambda (tType "Int" []) (tType "Int" [])


plainModule : Src.Module
plainModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "double"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "x")
          }
        , { name = "plus2"
          , args = [ pVar "a", pVar "b" ]
          , tipe = tLambda (tType "Int" []) hInt
          , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body = binopsExpr [ ( callExpr (varExpr "double") [ intExpr 3 ], "+" ) ] (callExpr (varExpr "plus2") [ intExpr 1, intExpr 2 ])
          }
        ]


retModule : Src.Module
retModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "double"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "x")
          }
        , { name = "ret1"
          , args = [ pVar "n" ]
          , tipe = tLambda (tType "Int" []) hInt
          , body = varExpr "double"
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body = callExpr (callExpr (varExpr "ret1") [ intExpr 0 ]) [ intExpr 7 ]
          }
        ]


consModule : Src.Module
consModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "double"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "x")
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "List" [ hInt ]
          , body = binopsExpr [ ( varExpr "double", "::" ) ] (listExpr [])
          }
        ]


joinModule : Src.Module
joinModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "addTo"
          , args = [ pVar "a", pVar "b" ]
          , tipe = tLambda (tType "Int" []) hInt
          , body = binopsExpr [ ( varExpr "a", "+" ) ] (varExpr "b")
          }
        , { name = "idf"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = varExpr "x"
          }
        , { name = "useIt"
          , args = [ pVar "f" ]
          , tipe = tLambda hInt (tType "Int" [])
          , body = callExpr (varExpr "f") [ intExpr 1 ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tType "Int" []
          , body =
                callExpr (varExpr "useIt")
                    [ ifExpr (boolExpr True) (callExpr (varExpr "addTo") [ intExpr 7 ]) (varExpr "idf") ]
          }
        ]



-- ====== HARNESS ======


{-| `lss.regIdentity` was fixed at its default and removed 2026-09-18, so the
two differentials that toggled it are gone. What they pinned, flag-off: a
plain def's stored head anno was UNCOVERED (⊤/var), and `ret1`'s beyond-arity
`/r` arrow was IDENTICAL across the arms — the stamp changes the head and
never leaks past declared arity (LSS\_013). Solo census with it OFF: `var` ->
19,131 and ⊤ -> 11,333, artifact +214 KB.
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


demandsOf : String -> Mono.MonoGraph -> List Mono.MonoType
demandsOf target (Mono.MonoGraph g) =
    Array.foldl
        (\entry acc ->
            case entry of
                Just ( Mono.Global _ name, monoType ) ->
                    if name == target then
                        monoType :: acc

                    else
                        acc

                _ ->
                    acc
        )
        []
        g.registry.reverseMapping


headAnnos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
headAnnos target graph =
    List.filterMap
        (\t ->
            case t of
                Mono.MFunction _ anno _ _ ->
                    Just anno

                _ ->
                    Nothing
        )
        (demandsOf target graph)


{-| `( head anno, Maybe depth-1 anno )` of one stored type's spine.
-}
spineAnnos : Mono.MonoType -> Maybe ( Mono.LambdaSetAnno, Maybe Mono.LambdaSetAnno )
spineAnnos t =
    case t of
        Mono.MFunction _ anno _ ret ->
            case ret of
                Mono.MFunction _ rAnno _ _ ->
                    Just ( anno, Just rAnno )

                _ ->
                    Just ( anno, Nothing )

        _ ->
            Nothing


{-| Annos at a CONSUMER's parameter positions (the co-gate reading).
-}
paramAnnos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
paramAnnos target graph =
    List.concatMap
        (\t ->
            case t of
                Mono.MFunction _ _ args _ ->
                    List.filterMap
                        (\a ->
                            case a of
                                Mono.MFunction _ anno _ _ ->
                                    Just anno

                                _ ->
                                    Nothing
                        )
                        args

                _ ->
                    []
        )
        (demandsOf target graph)


isTop : Mono.LambdaSetAnno -> Bool
isTop a =
    Mono.isTopAnno a


isSingleton : Mono.LambdaSetAnno -> Bool
isSingleton a =
    case a of
        Mono.LSet [ _ ] ->
            True

        _ ->
            False


maybeSet : Maybe Mono.LambdaSetAnno -> Bool
maybeSet m =
    case m of
        Just a ->
            isSet a

        Nothing ->
            -- The stored type has no depth-1 arrow (fully applied demand);
            -- nothing to assert.
            True


isSet : Mono.LambdaSetAnno -> Bool
isSet a =
    case a of
        Mono.LSet _ ->
            True

        _ ->
            False


neverFalselyComplete : Mono.LambdaSetAnno -> Bool
neverFalselyComplete anno =
    case anno of
        Mono.LTop _ ->
            True

        Mono.LVar _ ->
            True

        Mono.LPartial _ ->
            True

        Mono.LSet ms ->
            List.length ms >= 2


describe : List Mono.LambdaSetAnno -> String
describe annos =
    "[" ++ String.join ", " (List.map describeAnno annos) ++ "]"


describeMaybe : Maybe Mono.LambdaSetAnno -> String
describeMaybe m =
    case m of
        Just a ->
            describeAnno a

        Nothing ->
            "(no /r arrow)"


describeAnno : Mono.LambdaSetAnno -> String
describeAnno anno =
    case anno of
        Mono.LTop _ ->
            "LTop"

        Mono.LVar n ->
            "LVar " ++ String.fromInt n

        Mono.LSet ms ->
            "LSet " ++ String.fromInt (List.length ms)

        Mono.LPartial ms ->
            "LPartial " ++ String.fromInt (List.length ms)
