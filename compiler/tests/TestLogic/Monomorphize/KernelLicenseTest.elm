module TestLogic.Monomorphize.KernelLicenseTest exposing (suite)

{-| Tests for the kernel license table in `Compiler.MonoSolver.KernelSetFacts`,
where a wrong entry can miscompile a program. They check that a licensed call to
`List.cons` can leave a function-typed position with a single known function,
that the table refuses the kernels it must refuse, that every row carries its
evidence, and that `licenseApplies` refuses an occurrence whose type the license
does not fit.

The solver's lambda-set specialization (LSS) records, for each function-typed
position, the set of functions that can reach it, its _members_. A position
whose set has exactly one member can be called directly. In the monomorphized
graph each function type carries an annotation for its set: among other forms,
an `LSet` lists known members and an `LTop` stands for unknown ones. A kernel is
a runtime function written outside Elm, so the solver cannot see how function
values pass through one. A _license_ is a `TypeFaithful` row in
`KernelSetFacts`: the claim that function values pass through the kernel only
along the type variables its Elm type shares, so that members may be carried
across the call. The rules for rows and their scopes are stated in
`KernelSetFacts`. What matters here is that a missing license costs precision,
while a wrong one can produce a one-member set naming the wrong function, and so
a direct call to it.

Tests 1 and 2 compile a small program each (`partialKernelModule`,
`consFunctionModule`) with `run`, and read the lambda-set annotations on the
types the result's registry records for the specializations of globals named
`cons`. Both programs pass the global `inc : Int -> Int` to `List.cons`, which
the test pipeline defines as an alias of the `List.cons` kernel. The other
tests read the table directly, or call `licenseApplies` on canonical types
built in this module. Except in test 11, which uses `Json.addEntry`'s own
license, the licenses are made here with a placeholder file and empty evidence,
and the scalar test is `noScalars` unless a test says otherwise.

What the tests establish:

  - Test 1: with `consInc = List.cons inc` applying `List.cons` to one
    argument, at least one annotation on the specialization types recorded for
    `cons` is an `LSet` with exactly one member.
  - Test 2: the same, for `List.cons inc []`.
  - Test 3: no kernel in `neverLicensable` has a row.
  - Test 4: `factFor` gives `Nothing` for a home and name that no kernel has.
  - Test 5: every `TypeFaithful` row has a non-empty `files`.
  - Test 6: every `TypeFaithful` row's evidence contains each of `class:`,
    `entry:`, `type:`, `B1:`, `B2:`, `B3:` and `audited:`, and every
    `Positional` row's contains `entry:`. Only the markers' presence is
    checked.
  - Test 7: a `TypeFaithful` row's scope is `Inert` exactly when its evidence
    contains `class: vacuous`.
  - Test 8: `licensedFiles` is non-empty and sorted, has no duplicates, and
    every path in it contains a `/` and does not start with one.
  - Test 9: an `Inert` license is accepted for `String -> Int` and for
    `String -> Task Never ()`, and refused when an argument or the final result
    is or contains a type variable (`String -> a`, `String -> Task x ()`) or an
    arrow (`(Int -> Int) -> Int`, `String -> List (Int -> Int)`).
  - Test 9b: with `comparable` and `number` treated as scalars, an `Inert`
    license is accepted for `comparable -> comparable -> Order` and
    `number -> number`, and refused for `a -> a` and `List a -> Int`.
  - Test 9c: an `Inert` license is accepted for an alias `Task Never String`
    whose `Holey` body is `Task x a`, refused when an alias argument is an
    arrow or a type variable, and refused for an alias whose body is an arrow.
  - Test 10: a `TransportsAs` license with the shape `Array a -> List a`
    accepts `Array String -> List String` and
    `Array (Int -> Int) -> List (Int -> Int)`, and refuses different element
    types on the two sides, the constructors swapped, `Set` for `Array`, and
    `String`.
  - Test 11: `Json.addEntry` has a `TypeFaithful` row, and its license accepts
    `(String -> Value) -> String -> Value -> Value` and the same with
    `Int -> Int` for `String`, and refuses a different type for the encoder's
    argument and the element, an `Int` accumulator, and a first parameter that
    is not an arrow.
  - Test 12: every `TransportsAs` shape is a function shape.
  - Test 13: every `TransportsAs` shape equals the shape of the kernel's
    annotation in `Compiler.Type.KernelIntrinsics`, where `intrinsicShapeFor`
    finds one.
  - Test 14: a `TransportsAs` license with the shape `a -> a` accepts `p -> p`
    and refuses `p -> q`.

Among what is not tested: that the one-member set in tests 1 and 2 holds
`inc`'s member, or which arrow carries it; the transport of a kernel with no
license, since the test pipeline builds alias nodes only for `List.cons` and
`List.map2`, and both are licensed; a `Transports` license, which
`licenseApplies` accepts at any occurrence; whether any row's evidence is true;
and a `TransportsAs` row whose intrinsic annotation `shapeOfAnnotation` cannot
express, which test 13 skips.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , intExpr
        , listExpr
        , makeModuleWithTypedDefs
        , pVar
        , qualVarExpr
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Eco.Config as Config
import Compiler.Elm.ModuleName as ModuleName
import Compiler.MonoSolver.KernelSetFacts as KernelSetFacts
import Compiler.Type.KernelIntrinsics as KernelIntrinsics
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The kernel license tests, as the module docstring lists them.
-}
suite : Test
suite =
    Test.describe "LSS_022 kernel parametricity license"
        [ Test.test "1. transport pin: a PARTIALLY applied licensed kernel still transports (no arity rule)" <|
            \() ->
                -- A license has no per-parameter positions to align with the
                -- call's arity, so it applies to this partial application too.
                case run partialKernelModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        let
                            annos =
                                allAnnos "cons" graph
                        in
                        if List.isEmpty annos then
                            Expect.fail "no List.cons demand reached the registry — the fixture is not exercising the kernel boundary"

                        else if List.any (annoHasSize 1) annos then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected `inc`'s member to survive the partially applied boundary, got: "
                                    ++ describeAnnos annos
                                )
        , Test.test "2. transport pin: the licensed cheap-class `List.cons` transports its element too" <|
            \() ->
                case run consFunctionModule of
                    Err msg ->
                        Expect.fail msg

                    Ok graph ->
                        let
                            annos =
                                allAnnos "cons" graph
                        in
                        if List.isEmpty annos then
                            Expect.fail "no List.cons demand reached the registry — the fixture is not exercising the kernel boundary"

                        else if List.any (annoHasSize 1) annos then
                            Expect.pass

                        else
                            Expect.fail
                                ("expected a singleton LSet on some List.cons demand arrow, got: "
                                    ++ describeAnnos annos
                                )
        , Test.test "3. containment: the REJECTED classes are not licensed" <|
            \() ->
                let
                    licensed =
                        List.filter (\( home, name ) -> KernelSetFacts.factFor home name /= Nothing)
                            neverLicensable
                in
                if List.isEmpty licensed then
                    Expect.pass

                else
                    Expect.fail
                        ("these kernels are on the never-license list but carry a row: "
                            ++ String.join ", " (List.map (\( h, n ) -> h ++ "." ++ n) licensed)
                        )
        , Test.test "4. containment: an unaudited kernel has no row (LSS_004 full poison is the default)" <|
            \() ->
                Expect.equal Nothing (KernelSetFacts.factFor "NoSuchHome" "noSuchKernel")
        , Test.test "5. discipline: every TypeFaithful row pins at least one C++ file" <|
            \() ->
                let
                    unpinned =
                        List.filterMap
                            (\( key, fact ) ->
                                case fact of
                                    KernelSetFacts.TypeFaithful license ->
                                        if List.isEmpty license.files then
                                            Just (keyName key)

                                        else
                                            Nothing

                                    KernelSetFacts.Positional _ ->
                                        Nothing
                            )
                            KernelSetFacts.rows
                in
                if List.isEmpty unpinned then
                    Expect.pass

                else
                    Expect.fail
                        ("licensed rows with an empty `files` list (unguarded by the rot manifest): "
                            ++ String.join ", " unpinned
                        )
        , Test.test "6. discipline: every row's evidence carries the §2.6 markers" <|
            \() ->
                let
                    bad =
                        List.filterMap
                            (\( key, fact ) ->
                                let
                                    ( evidence, required ) =
                                        case fact of
                                            KernelSetFacts.TypeFaithful license ->
                                                ( license.evidence, [ "class:", "entry:", "type:", "B1:", "B2:", "B3:", "audited:" ] )

                                            KernelSetFacts.Positional plan ->
                                                ( plan.evidence, [ "entry:" ] )

                                    missing =
                                        List.filter (\marker -> not (String.contains marker evidence)) required
                                in
                                if List.isEmpty missing then
                                    Nothing

                                else
                                    Just (keyName key ++ " (missing " ++ String.join " " missing ++ ")")
                            )
                            KernelSetFacts.rows
                in
                if List.isEmpty bad then
                    Expect.pass

                else
                    Expect.fail ("rows with malformed evidence: " ++ String.join "; " bad)
        , Test.test "7. discipline: `scope` agrees with the evidence's class token" <|
            \() ->
                -- `Inert` is the scope for the audit class `vacuous`, and the
                -- two are written separately in each row.
                let
                    disagreeing =
                        List.filterMap
                            (\( key, fact ) ->
                                case fact of
                                    KernelSetFacts.TypeFaithful license ->
                                        let
                                            saysVacuous =
                                                String.contains "class: vacuous" license.evidence

                                            isInert =
                                                license.scope == KernelSetFacts.Inert
                                        in
                                        if saysVacuous == isInert then
                                            Nothing

                                        else
                                            Just (keyName key)

                                    KernelSetFacts.Positional _ ->
                                        Nothing
                            )
                            KernelSetFacts.rows
                in
                if List.isEmpty disagreeing then
                    Expect.pass

                else
                    Expect.fail
                        ("rows whose `scope` contradicts their evidence class: "
                            ++ String.join ", " disagreeing
                        )
        , Test.test "8. discipline: licensedFiles is non-empty, sorted and deduplicated" <|
            \() ->
                let
                    files =
                        KernelSetFacts.licensedFiles
                in
                Expect.all
                    [ \() ->
                        if List.isEmpty files then
                            Expect.fail "licensedFiles is empty — no kernel is licensed, so the manifest guards nothing"

                        else
                            Expect.pass
                    , \() -> Expect.equal (List.sort files) files
                    , \() -> Expect.equal (List.length (dedupe (List.sort files))) (List.length files)
                    , \() ->
                        if List.all (\f -> not (String.startsWith "/" f) && String.contains "/" f) files then
                            Expect.pass

                        else
                            Expect.fail ("licensedFiles must be repo-relative paths, got: " ++ String.join ", " files)
                    ]
                    ()
        , Test.test "9. verification: an Inert license is REFUSED at a function-capable occurrence" <|
            \() ->
                -- An `Inert` row claims that the kernel's type has no position
                -- able to hold a function. `licenseApplies` checks that claim
                -- again against each occurrence's type.
                Expect.all
                    [ \() -> Expect.equal True (KernelSetFacts.licenseApplies noScalars inertLicense (cFun cString cInt))
                    , \() -> Expect.equal True (KernelSetFacts.licenseApplies noScalars inertLicense (cFun cString (cCon "Task" [ cCon "Never" [], cUnit ])))

                    -- A type variable, bare or as a type argument, is refused.
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars inertLicense (cFun cString (cVar "a")))
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars inertLicense (cFun cString (cCon "Task" [ cVar "x", cUnit ])))

                    -- So is an arrow off the top-level spine.
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars inertLicense (cFun (cFun cInt cInt) cInt))
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars inertLicense (cFun cString (cCon "List" [ cFun cInt cInt ])))
                    ]
                    ()
        , Test.test "9b. verification: a SCALAR-constrained variable is not function-capable (ruling R1)" <|
            \() ->
                -- `comparable` and `number` range only over types that cannot
                -- hold a function.
                let
                    scalars name =
                        name == "comparable" || name == "number"
                in
                Expect.all
                    [ \() -> Expect.equal True (KernelSetFacts.licenseApplies scalars inertLicense (cFun (cVar "comparable") (cFun (cVar "comparable") (cCon "Order" []))))
                    , \() -> Expect.equal True (KernelSetFacts.licenseApplies scalars inertLicense (cFun (cVar "number") (cVar "number")))

                    -- An ordinary variable stays function-capable.
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies scalars inertLicense (cFun (cVar "a") (cVar "a")))

                    -- So does one reached through a container.
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies scalars inertLicense (cFun (cCon "List" [ cVar "a" ]) cInt))
                    ]
                    ()
        , Test.test "9c. verification: a parameterised ALIAS is judged by its ARGS, not by its Holey body" <|
            \() ->
                -- In the `Holey` body `Task x a`, `x` and `a` are the alias's
                -- parameters, standing for its arguments, not free variables.
                let
                    taskAlias err ok =
                        Can.TAlias testHome
                            "Task"
                            [ ( "x", err ), ( "a", ok ) ]
                            (Can.Holey (cCon "Task" [ cVar "x", cVar "a" ]))
                in
                Expect.all
                    [ \() -> Expect.equal True (KernelSetFacts.licenseApplies noScalars inertLicense (taskAlias (cCon "Never" []) cString))

                    -- An argument that can hold a function is refused.
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars inertLicense (taskAlias (cCon "Never" []) (cFun cInt cInt)))
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars inertLicense (taskAlias (cVar "e") cString))

                    -- So is an arrow in the alias's body.
                    , \() ->
                        Expect.equal False
                            (KernelSetFacts.licenseApplies noScalars
                                inertLicense
                                (Can.TAlias testHome "Handler" [ ( "a", cString ) ] (Can.Holey (cFun (cVar "a") cInt)))
                            )
                    ]
                    ()
        , Test.test "10. verification: a declared shape matches only its instances" <|
            \() ->
                let
                    tunnel =
                        shapeLicense (KernelSetFacts.TsFun (KernelSetFacts.TsCon "Array" [ KernelSetFacts.TsVar "a" ]) (KernelSetFacts.TsCon "List" [ KernelSetFacts.TsVar "a" ]))
                in
                Expect.all
                    [ -- An instance of the shape matches.
                      \() -> Expect.equal True (KernelSetFacts.licenseApplies noScalars tunnel (cFun (cCon "Array" [ cString ]) (cCon "List" [ cString ])))

                    -- So does an instance whose element is a function.
                    , \() -> Expect.equal True (KernelSetFacts.licenseApplies noScalars tunnel (cFun (cCon "Array" [ cFun cInt cInt ]) (cCon "List" [ cFun cInt cInt ])))

                    -- `a` must be the same type on both sides: the shared
                    -- variable is the path the license claims a value takes.
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars tunnel (cFun (cCon "Array" [ cString ]) (cCon "List" [ cInt ])))

                    -- Swapped constructors, a wrong constructor and a non-function type do not match.
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars tunnel (cFun (cCon "List" [ cString ]) (cCon "Array" [ cString ])))
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars tunnel (cFun (cCon "Set" [ cString ]) (cCon "List" [ cString ])))
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars tunnel cString)
                    ]
                    ()
        , Test.test "11. verification: Json.addEntry's shipped shape accepts its real use and rejects drift" <|
            \() ->
                case KernelSetFacts.factFor "Json" "addEntry" of
                    Just (KernelSetFacts.TypeFaithful license) ->
                        let
                            value =
                                cCon "Value" []
                        in
                        Expect.all
                            [ -- The row's shape is `(a -> Value) -> a -> Value -> Value`;
                              -- here `a` is `String`.
                              \() -> Expect.equal True (KernelSetFacts.licenseApplies noScalars license (cFun (cFun cString value) (cFun cString (cFun value value))))

                            -- Here `a` is a function type.
                            , \() -> Expect.equal True (KernelSetFacts.licenseApplies noScalars license (cFun (cFun (cFun cInt cInt) value) (cFun (cFun cInt cInt) (cFun value value))))

                            -- Refused: the encoder's argument and the element differ.
                            , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars license (cFun (cFun cString value) (cFun cInt (cFun value value))))

                            -- Refused: the accumulator is not a `Value`.
                            , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars license (cFun (cFun cString value) (cFun cString (cFun cInt cInt))))

                            -- Refused: the first parameter is not an arrow.
                            , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars license (cFun cString (cFun cString (cFun value value))))
                            ]
                            ()

                    _ ->
                        Expect.fail "Json.addEntry should carry a TypeFaithful row with a declared shape"
        , Test.test "12. discipline: every TransportsAs row's shape is a function type" <|
            \() ->
                let
                    bad =
                        List.filterMap
                            (\( key, fact ) ->
                                case fact of
                                    KernelSetFacts.TypeFaithful license ->
                                        case license.scope of
                                            KernelSetFacts.TransportsAs (KernelSetFacts.TsFun _ _) ->
                                                Nothing

                                            KernelSetFacts.TransportsAs _ ->
                                                Just (keyName key)

                                            _ ->
                                                Nothing

                                    KernelSetFacts.Positional _ ->
                                        Nothing
                            )
                            KernelSetFacts.rows
                in
                Expect.equal [] bad
        , Test.test "13. sync: every declared shape EQUALS the kernel's intrinsic annotation" <|
            \() ->
                -- The two tables are written separately, and a shape that
                -- differs from the annotation can stop the license applying at
                -- the kernel's occurrences.
                let
                    mismatched =
                        List.filterMap
                            (\( ( home, name ), fact ) ->
                                case fact of
                                    KernelSetFacts.TypeFaithful license ->
                                        case license.scope of
                                            KernelSetFacts.TransportsAs shape ->
                                                case intrinsicShapeFor home name of
                                                    Nothing ->
                                                        -- No annotation, or one shapes cannot express.
                                                        Nothing

                                                    Just annotationShape ->
                                                        if annotationShape == shape then
                                                            Nothing

                                                        else
                                                            Just (keyName ( home, name ))

                                            _ ->
                                                Nothing

                                    KernelSetFacts.Positional _ ->
                                        Nothing
                            )
                            KernelSetFacts.rows
                in
                Expect.equal [] mismatched
        , Test.test "14. a TsVar claim is load-bearing: two DIFFERENT variables do not satisfy it" <|
            \() ->
                -- Two type variables are the same type only when they are the
                -- same variable.
                let
                    tunnel =
                        shapeLicense (KernelSetFacts.TsFun (KernelSetFacts.TsVar "a") (KernelSetFacts.TsVar "a"))
                in
                Expect.all
                    [ \() -> Expect.equal True (KernelSetFacts.licenseApplies noScalars tunnel (cFun (cVar "p") (cVar "p")))
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars tunnel (cFun (cVar "p") (cVar "q")))
                    ]
                    ()
        ]


{-| Returns the shape of the annotation `Compiler.Type.KernelIntrinsics` holds
for the kernel `home`.`name`, looking under the `Elm` prefix and then under
`Eco`. It is `Nothing` when neither has a row, and also when the annotation has
a form `shapeOfAnnotation` cannot express.
-}
intrinsicShapeFor : String -> String -> Maybe KernelSetFacts.TypeShape
intrinsicShapeFor home name =
    [ "Elm", "Eco" ]
        |> List.filterMap (\prefix -> KernelIntrinsics.lookup prefix home name)
        |> List.head
        |> Maybe.andThen (\row -> KernelSetFacts.shapeOfAnnotation (annotationType row.annotation))


{-| Returns the type inside an annotation, without its set of quantified
variables.
-}
annotationType : Can.Annotation String -> Can.Type String
annotationType (Can.Forall _ tipe) =
    tipe



-- ====== Can.Type FIXTURES (for the pure verification tests) ======


{-| The module, `Test` in the package `elm/core`, given as the home of every
type `cCon` builds and of the aliases in test 9c. `licenseApplies` compares
type constructors by name alone, so the home does not affect any result.
-}
testHome : ModuleName.Canonical
testHome =
    ModuleName.Canonical ( "elm", "core" ) "Test"


{-| Builds the type variable with the given name.
-}
cVar : String -> Can.Type String
cVar =
    Can.TVar


{-| Builds a type constructor, homed in `testHome`, applied to the given
arguments.
-}
cCon : String -> List (Can.Type String) -> Can.Type String
cCon =
    Can.TType testHome


{-| Builds the function type from an argument type to a result type.
-}
cFun : Can.Type String -> Can.Type String -> Can.Type String
cFun =
    Can.tLambda


{-| The unit type.
-}
cUnit : Can.Type String
cUnit =
    Can.TUnit


{-| The type `Int`, homed in `testHome`.
-}
cInt : Can.Type String
cInt =
    cCon "Int" []


{-| The type `String`, homed in `testHome`.
-}
cString : Can.Type String
cString =
    cCon "String" []


{-| Answers `False` for every type variable, so that `licenseApplies` treats
every variable as able to hold a function. The solver's own calls pass
`Compiler.MonoSolver.Engine.isScalarVar` instead, which answers `True` for a
`number` or `comparable` variable.
-}
noScalars : String -> Bool
noScalars _ =
    False


{-| An `Inert` license with a placeholder file and empty evidence.
-}
inertLicense : KernelSetFacts.License
inertLicense =
    { scope = KernelSetFacts.Inert, files = [ "x.cpp" ], evidence = "" }


{-| Builds a `TransportsAs` license for `shape`, with a placeholder file and
empty evidence.
-}
shapeLicense : KernelSetFacts.TypeShape -> KernelSetFacts.License
shapeLicense shape =
    { scope = KernelSetFacts.TransportsAs shape, files = [ "x.cpp" ], evidence = "" }



-- ====== THE NEVER-LICENSE LIST ======


{-| Kernels, as home and name, that must have no row in `KernelSetFacts`. Test
3 fails if any of them has one. The comment above each group gives the reason
that group is refused.
-}
neverLicensable : List ( String, String )
neverLicensable =
    [ -- `Scheduler.binding` builds a runtime closure that lands where no type
      -- variable names it; it has not been audited. `Platform.sendToApp` and
      -- `sendToSelf` push a message into a process mailbox, and a different
      -- call receives it.
      ( "Scheduler", "binding" )
    , ( "Platform", "sendToApp" )
    , ( "Platform", "sendToSelf" )

    -- Each stores a tagger or callback that is applied at a later, unconnected
    -- call.
    , ( "Platform", "map" )
    , ( "Time", "setInterval" )

    -- The kernel's implementation takes a function argument that its Elm type,
    -- `Task x Posix`, does not mention.
    , ( "Time", "now" )

    -- A value one call puts into an MVar is handed back by a different call,
    -- with no type variable joining the two.
    , ( "MVar", "put" )
    , ( "MVar", "read" )
    , ( "MVar", "take" )

    -- The boundary with the embedding host. VirtualDom keeps its nodes, and
    -- the taggers `map` is given, in runtime storage.
    , ( "Browser", "application" )
    , ( "Browser", "element" )
    , ( "VirtualDom", "node" )
    , ( "VirtualDom", "on" )
    , ( "VirtualDom", "map" )
    , ( "VirtualDom", "lazy" )

    -- Retypes an arbitrary value as the opaque `Value`.
    , ( "Json", "wrap" )

    -- `a -> b` with the two variables unshared, so no flow can be stated.
    , ( "Debugger", "unsafeCoerce" )

    -- The compiler supplies a type descriptor and lowers these specially.
    , ( "Debug", "toString" )
    , ( "Debug", "log" )
    ]



-- ====== HARNESS ======


{-| Monomorphizes `srcModule` through the test pipeline with the solver engine,
the default specialization limits and the default LSS configuration, without
global optimization. The update `enabled = True` changes nothing, since
`Config.defaultLss` already has it.
-}
run : Src.Module -> Result String Mono.MonoGraph
run srcModule =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits
        Config.defaultLimits
        { defaults | enabled = True }
        srcModule


{-| Renders a row's key as `Home.name`, for failure messages.
-}
keyName : ( String, String ) -> String
keyName ( home, name ) =
    home ++ "." ++ name


{-| Returns `xs` with each run of equal adjacent elements cut to one, which
removes every duplicate from a sorted list.
-}
dedupe : List String -> List String
dedupe xs =
    case xs of
        a :: b :: rest ->
            if a == b then
                dedupe (b :: rest)

            else
                a :: dedupe (b :: rest)

        _ ->
            xs


{-| Returns the type of every specialization the graph's registry records for a
global named `target`, in any module, as its reverse mapping holds it.
-}
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


{-| Returns the lambda-set annotation of every function type within `t`,
looking inside function arguments and results, list elements, tuple elements,
record fields and custom-type arguments. Any other type contributes none.
-}
annosOf : Mono.MonoType -> List Mono.LambdaSetAnno
annosOf t =
    case t of
        Mono.MFunction _ anno args ret ->
            anno :: (List.concatMap annosOf args ++ annosOf ret)

        Mono.MList _ el ->
            annosOf el

        Mono.MTuple _ els ->
            List.concatMap annosOf els

        Mono.MRecord _ fields ->
            Dict.foldl (\_ ft acc -> acc ++ annosOf ft) [] fields

        Mono.MCustom _ _ _ args ->
            List.concatMap annosOf args

        _ ->
            []


{-| Returns every lambda-set annotation within the specialization types the
graph's registry records for globals named `target`.
-}
allAnnos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
allAnnos target graph =
    List.concatMap annosOf (demandsOf target graph)


{-| Tells whether `anno` is an `LSet` with exactly `n` members. An `LTop`, an
`LVar` or an `LPartial` never is.
-}
annoHasSize : Int -> Mono.LambdaSetAnno -> Bool
annoHasSize n anno =
    case anno of
        Mono.LSet members ->
            List.length members == n

        Mono.LTop _ ->
            False

        Mono.LVar _ ->
            False

        Mono.LPartial _ ->
            False


{-| Renders annotations as a comma-separated list, such as `LTop, LSet[3,7]`, for
failure messages.
-}
describeAnnos : List Mono.LambdaSetAnno -> String
describeAnnos annos =
    String.join ", "
        (List.map
            (\anno ->
                case anno of
                    Mono.LTop _ ->
                        "LTop"

                    Mono.LVar n ->
                        "LVar" ++ String.fromInt n

                    Mono.LSet ms ->
                        "LSet[" ++ String.join "," (List.map String.fromInt ms) ++ "]"

                    Mono.LPartial ms ->
                        "LPartial[" ++ String.join "," (List.map String.fromInt ms) ++ "]"
            )
            annos
        )



-- ====== FIXTURES ======


{-| The source type `Int`.
-}
tInt : Src.Type
tInt =
    tType "Int" []


{-| The source type `Int -> Int`, the type of `inc` in both programs.
-}
hInt : Src.Type
hInt =
    tLambda tInt tInt


{-| Builds the source type `List el`.
-}
tListOf : Src.Type -> Src.Type
tListOf el =
    tType "List" [ el ]


{-| The program for test 1. `inc` adds one to an `Int`, `consInc` is
`List.cons inc`, which applies `List.cons` to one of its two arguments, and
`testValue` is `consInc []`.

`inc` is the call's argument itself, not an element of a list literal.
`Compiler.MonoSolver.Translate.injectArgLambdaMember`, which gives a call's
parameter the member of the function passed to it, adds a global's member when
the argument expression is that global, and adds nothing for a list literal.

-}
partialKernelModule : Src.Module
partialKernelModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "inc"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)
          }
        , { name = "consInc"
          , args = []
          , tipe = tLambda (tListOf hInt) (tListOf hInt)
          , body = callExpr (qualVarExpr "List" "cons") [ varExpr "inc" ]
          }
        , { name = "testValue"
          , args = []
          , tipe = tListOf hInt
          , body = callExpr (varExpr "consInc") [ listExpr [] ]
          }
        ]


{-| The program for test 2. `inc` adds one to an `Int`, and `testValue` is
`List.cons inc []`, which applies `List.cons` to both of its arguments with
`Int -> Int` as the element type.
-}
consFunctionModule : Src.Module
consFunctionModule =
    makeModuleWithTypedDefs "Test"
        [ { name = "inc"
          , args = [ pVar "x" ]
          , tipe = hInt
          , body = binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1)
          }
        , { name = "testValue"
          , args = []
          , tipe = tListOf hInt
          , body =
                callExpr (qualVarExpr "List" "cons")
                    [ varExpr "inc"
                    , listExpr []
                    ]
          }
        ]
