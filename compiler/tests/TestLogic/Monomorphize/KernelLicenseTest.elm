module TestLogic.Monomorphize.KernelLicenseTest exposing (suite)

{-| LSS_022 — the kernel parametricity license
(`plans/kernel-parametricity-license.md`).

A `TypeFaithful` row asserts that a kernel's set flow is exactly its Elm
type's variable-sharing graph, and on the strength of that assertion BOTH
consumers skip the LSS_004 poison. The failure asymmetry is brutal and
one-directional: a missing license costs precision, a wrong one licenses a
false singleton and therefore a wrong direct-call stamp — a miscompile. So
these tests come in two kinds, and the second kind is the important one:

**Transport pins** (tests 1-2) — the license actually does something. A
licensed kernel's arrow positions carry the caller's members through the
boundary instead of reading ⊤. Pinned through observable graph state: the
annotations of the stored (keyed) demand types in the registry, the same
observation surface `LssSigFlowTest` and `MuTieTest` use.

**Containment pins** (tests 3-7) — the license does NOT do anything it
should not. The rejected classes stay unlicensed, unknown kernels stay
unlicensed, and every row carries the evidence and file pins the audit
discipline requires. A regression here is exactly how a miscompile would be
introduced, and unlike the transport pins these cost nothing to run.

Note on the negative transport control the plan sketches (§5 test 2): the
mock interface env only synthesizes kernel-alias nodes for kernels that are
REALLY eta-free aliases in elm/core (`TestPipeline.aliasedKernels`), and
every such kernel within reach of the test interfaces is licensed. Rather
than fake an alias — which would stop the mock env mirroring production —
the negative side is pinned at the table (tests 3-4) and behaviourally by
the E2E fixture `test/elm/src/KernelLicenseTest.elm`.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , binopsExpr
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
import Compiler.AST.Canonical as Can
import Compiler.Eco.Config as Config
import Compiler.MonoSolver.KernelSetFacts as KernelSetFacts
import Compiler.Type.KernelIntrinsics as KernelIntrinsics
import System.TypeCheck.IO as IO
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "LSS_022 kernel parametricity license"
        [ Test.test "1. transport pin: a PARTIALLY applied licensed kernel still transports (no arity rule)" <|
            \() ->
                -- `consInc = List.cons inc` applies 1 of `cons`'s 2 params.
                -- An arity-aligned POSITIONAL row would bail to LSS_004 full
                -- poison here and the element arrow would read `LTop`; a
                -- license has no positions to align, so `g|inc` survives
                -- (plan §1, "partial kernel application: no arity rule needed
                -- at all").
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
                -- `Inert` is the structural form of "this row is vacuous", and
                -- it is what makes the inference side skip the boundary
                -- outright. A row marked `Inert` whose audit actually found a
                -- function-capable position would skip transport that should
                -- have happened — precision loss, not unsoundness, but the two
                -- fields must not be allowed to drift apart silently.
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
                -- The drift guard. An `Inert` row asserts "this kernel's type
                -- has no function-capable position" — a claim about the ELM
                -- ANNOTATION, which the rot manifest cannot see because it
                -- hashes C++ only. If the annotation later grows an arrow or a
                -- type variable, `licenseApplies` must refuse and the consumer
                -- must fall back to LSS_004 poison rather than silently apply a
                -- claim nobody re-checked.
                Expect.all
                    [ \() -> Expect.equal True (KernelSetFacts.licenseApplies noScalars inertLicense (cFun cString cInt))
                    , \() -> Expect.equal True (KernelSetFacts.licenseApplies noScalars inertLicense (cFun cString (cCon "Task" [ cCon "Never" [], cUnit ])))

                    -- a bare variable anywhere — including a PHANTOM one, which
                    -- is exactly the nullary-carrier case
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars inertLicense (cFun cString (cVar "a")))
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars inertLicense (cFun cString (cCon "Task" [ cVar "x", cUnit ])))

                    -- an arrow in a non-spine position
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars inertLicense (cFun (cFun cInt cInt) cInt))
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars inertLicense (cFun cString (cCon "List" [ cFun cInt cInt ])))
                    ]
                    ()
        , Test.test "9b. verification: a SCALAR-constrained variable is not function-capable (ruling R1)" <|
            \() ->
                -- `Utils.compare : comparable -> comparable -> Order` and
                -- `Basics.add : number -> number -> number` have no
                -- function-capable position at all, but their occurrences
                -- inside a polymorphic caller are `TVar`s. Treating every
                -- `TVar` as function-capable refused their `Inert` licenses on
                -- the hottest kernels in the compiler; the super table says
                -- otherwise and is the typechecker's own truth.
                let
                    scalars name =
                        name == "comparable" || name == "number"
                in
                Expect.all
                    [ \() -> Expect.equal True (KernelSetFacts.licenseApplies scalars inertLicense (cFun (cVar "comparable") (cFun (cVar "comparable") (cCon "Order" []))))
                    , \() -> Expect.equal True (KernelSetFacts.licenseApplies scalars inertLicense (cFun (cVar "number") (cVar "number")))

                    -- an ordinary variable stays function-capable
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies scalars inertLicense (cFun (cVar "a") (cVar "a")))

                    -- and so does one reached through a container
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies scalars inertLicense (cFun (cCon "List" [ cVar "a" ]) cInt))
                    ]
                    ()
        , Test.test "9c. verification: a parameterised ALIAS is judged by its ARGS, not by its Holey body" <|
            \() ->
                -- Regression pin. `Task Never String` canonicalizes to a
                -- `Holey` alias whose body is `Platform.Task x a` — and `x`/`a`
                -- there are the alias's PARAMETERS, not free variables: their
                -- real content is the args. Counting them as function-capable
                -- refused every parameterised alias, which is how five eco IO
                -- kernels with entirely concrete types (`Task Never String`,
                -- `Task IOError String`) were being denied their Inert
                -- licenses.
                let
                    taskAlias err ok =
                        Can.TAlias testHome
                            "Task"
                            [ ( "x", err ), ( "a", ok ) ]
                            (Can.Holey (cCon "Task" [ cVar "x", cVar "a" ]))
                in
                Expect.all
                    [ \() -> Expect.equal True (KernelSetFacts.licenseApplies noScalars inertLicense (taskAlias (cCon "Never" []) cString))

                    -- a function-capable ARG is still caught
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars inertLicense (taskAlias (cCon "Never" []) (cFun cInt cInt)))
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars inertLicense (taskAlias (cVar "e") cString))

                    -- and an arrow in the BODY is still caught, since it is not
                    -- a parameter placeholder
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
                    -- `List.fromArray : Array a -> List a`
                    tunnel =
                        shapeLicense (KernelSetFacts.TsFun (KernelSetFacts.TsCon "Array" [ KernelSetFacts.TsVar "a" ]) (KernelSetFacts.TsCon "List" [ KernelSetFacts.TsVar "a" ]))
                in
                Expect.all
                    [ -- the real occurrence in elm/core's String.split
                      \() -> Expect.equal True (KernelSetFacts.licenseApplies noScalars tunnel (cFun (cCon "Array" [ cString ]) (cCon "List" [ cString ])))

                    -- still an instance at a functional element
                    , \() -> Expect.equal True (KernelSetFacts.licenseApplies noScalars tunnel (cFun (cCon "Array" [ cFun cInt cInt ]) (cCon "List" [ cFun cInt cInt ])))

                    -- TsVar CONSISTENCY is the whole point: the element must be
                    -- the SAME type on both sides, because that shared variable
                    -- IS the flow edge the license claims.
                    , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars tunnel (cFun (cCon "Array" [ cString ]) (cCon "List" [ cInt ])))

                    -- wrong direction / wrong constructor / wrong arity
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
                            [ -- `Json.Encode.list toStr xs` at a = String, the
                              -- shape the intrinsic annotation now pins.
                              \() -> Expect.equal True (KernelSetFacts.licenseApplies noScalars license (cFun (cFun cString value) (cFun cString (cFun value value))))

                            -- a = a function: still an instance, still licensed
                            , \() -> Expect.equal True (KernelSetFacts.licenseApplies noScalars license (cFun (cFun (cFun cInt cInt) value) (cFun (cFun cInt cInt) (cFun value value))))

                            -- SHARING is now load-bearing: the encoder's
                            -- argument and the folded element must be the SAME
                            -- `a`. Before the annotations solved these
                            -- positions this could not be asserted at all.
                            , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars license (cFun (cFun cString value) (cFun cInt (cFun value value))))

                            -- accumulator not a Value
                            , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars license (cFun (cFun cString value) (cFun cString (cFun cInt cInt))))

                            -- first parameter not an arrow
                            , \() -> Expect.equal False (KernelSetFacts.licenseApplies noScalars license (cFun cString (cFun cString (cFun value value))))
                            ]
                            ()

                    _ ->
                        Expect.fail "Json.addEntry should carry a TypeFaithful row with a declared shape"
        , Test.test "12. discipline: every TransportsAs row's shape is a function type" <|
            \() ->
                -- A declared shape that is not an arrow could never match a
                -- kernel occurrence, so the row would be silently dead.
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
                -- The two tables live in different subsystems (`MonoSolver` and
                -- `Type`) and would otherwise drift silently — the failure mode
                -- being a license that quietly stops applying, which no gate
                -- would catch. Pin them equal instead of syncing by hand.
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
                                                        -- No intrinsic row: the
                                                        -- shape is this table's
                                                        -- own claim, nothing to
                                                        -- sync against.
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
                -- `sameType` used to treat any two `TVar`s as equal, which made
                -- every repeated-variable claim vacuous. Occurrences are solved
                -- now, so identity is both checkable and required.
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


{-| The shape denoted by a kernel's INTRINSIC annotation, if it has one.
-}
intrinsicShapeFor : String -> String -> Maybe KernelSetFacts.TypeShape
intrinsicShapeFor home name =
    [ "Elm", "Eco" ]
        |> List.filterMap (\prefix -> KernelIntrinsics.lookup prefix home name)
        |> List.head
        |> Maybe.andThen (\row -> KernelSetFacts.shapeOfAnnotation (annotationType row.annotation))


annotationType : Can.Annotation String -> Can.Type String
annotationType (Can.Forall _ tipe) =
    tipe


-- ====== Can.Type FIXTURES (for the pure verification tests) ======


testHome : IO.Canonical
testHome =
    IO.Canonical ( "elm", "core" ) "Test"


cVar : String -> Can.Type String
cVar =
    Can.TVar


cCon : String -> List (Can.Type String) -> Can.Type String
cCon =
    Can.TType testHome


cFun : Can.Type String -> Can.Type String -> Can.Type String
cFun =
    Can.tLambda


cUnit : Can.Type String
cUnit =
    Can.TUnit


cInt : Can.Type String
cInt =
    cCon "Int" []


cString : Can.Type String
cString =
    cCon "String" []


{-| Conservative default for the pure tests: no variable is known scalar, so
every `TVar` counts as function-capable. The production consumers read the
solver's super table instead (`Engine.isScalarVar`).
-}
noScalars : String -> Bool
noScalars _ =
    False


inertLicense : KernelSetFacts.License
inertLicense =
    { scope = KernelSetFacts.Inert, files = [ "x.cpp" ], evidence = "" }


shapeLicense : KernelSetFacts.TypeShape -> KernelSetFacts.License
shapeLicense shape =
    { scope = KernelSetFacts.TransportsAs shape, files = [ "x.cpp" ], evidence = "" }



-- ====== THE NEVER-LICENSE LIST ======


{-| Kernels whose functional payload lands in a type-opaque position or in
runtime storage. The plan's §1 floor, made executable: if any of these ever
acquires a row, the audit discipline has failed and this test is the
tripwire. Each entry is a REJECTED verdict from the 2026-08-20 survey.
-}
neverLicensable : List ( String, String )
neverLicensable =
    [ -- Task / Process / effect managers.
      --
      -- NARROWED 2026-08-25. This list used to read "the callback lands in
      -- the Task object (Scheduler.cpp allocTask)" and included
      -- `succeed`/`fail`/`andThen`/`onError`. That reasoning was wrong:
      -- storing into the Task you RETURN is not retention the set analysis
      -- cares about — the scheduler reads the value back out of THAT SAME
      -- Task, and the type's shared variables describe the edge exactly
      -- (`a -> Task x a`, `(a -> Task x b) -> Task x a -> Task x b`). It is
      -- `JsArray.singleton`, which has been licensed since the first audit.
      -- Those four now carry `Transports` rows; see the CROSS-CALL predicate
      -- in `KernelSetFacts`'s REJECTED section.
      --
      -- What stays here stays for a REASON, not by inertia:
      --   binding/spawn  — mint a C++ closure through TaskBinding.hpp
      --                    `makeBinding`. OPEN, not decided: the minted
      --                    closure lands where no type variable names it, so
      --                    predicate 3 fires mechanically rather than on a
      --                    demonstrated hazard. Audit before licensing.
      --   sendToApp/Self — genuinely CROSS-CALL: `rawSend` pushes the message
      --                    into a process mailbox (Scheduler.cpp:476-484) and
      --                    a DIFFERENT call's `update`/`onSelfMsg` receives
      --                    it. `msg` does not appear in the result type at
      --                    all. `sendToApp` also fails A3 (declared `void`).
      --   Process.sleep  — unaudited.
      -- NARROWED AGAIN 2026-08-25 (Groups 1-4). `Scheduler.spawn` came off:
      -- its `a` is ABSENT from the result (`Task x a -> Task y Id`), so the
      -- type's flow obligation is EMPTY and there is nothing a licence can get
      -- wrong. `Process.sleep` came off: it captures a BOXED FLOAT, not a
      -- closure. `Scheduler.binding` stays — it is not a `TOpt.VarKernel` on
      -- any reachable Elm surface, so it is a guard against a future row
      -- rather than a live refusal.
      ( "Scheduler", "binding" )
    , ( "Platform", "sendToApp" )
    , ( "Platform", "sendToSelf" )

    -- `Platform.map` STORES A TAGGER in a Sub that the effect manager applies
    -- at a later, unconnected call; `Time.setInterval` does the same. Both are
    -- cross-call. `Platform.batch` is NOT here: it only collects, so it is
    -- List.cons-shaped and is licensed.
    , ( "Platform", "map" )
    , ( "Time", "setInterval" )

    -- `Time.now`'s C++ takes `millisToPosix` — a FUNCTION — and applies it at
    -- scheduler-step time, but its Elm annotation is `Task x Posix`, arity 0.
    -- A3 arity mismatch: a function argument the type does not mention.
    , ( "Time", "now" )

    -- MVar carries values ACROSS CALLS and the Bytes codec does NOT launder
    -- them: `read decoder (MVar id) = Eco.Kernel.MVar.read id` — the decoder
    -- is IGNORED and the raw value is returned from the store, so a function
    -- put in by one call is handed back by another with no type edge.
    -- `MVar.new`/`drop` are licensed: neither carries a value.
    , ( "MVar", "put" )
    , ( "MVar", "read" )
    , ( "MVar", "take" )

    -- The embedding / host boundary.
    , ( "Browser", "application" )
    , ( "Browser", "element" )
    , ( "VirtualDom", "node" )
    , ( "VirtualDom", "on" )
    , ( "VirtualDom", "map" )
    , ( "VirtualDom", "lazy" )

    -- Phantom / opaque type parameters: `type Decoder a = Decoder` has no
    -- field backing `a`, so a stored callback is invisible to the type.
    -- Json NARROWED 2026-08-25: the combinators store their callback verbatim
    -- into a Decoder that `Json.run`/`runOnString` then consume AS AN ARGUMENT,
    -- driving the decode in that same call — argument-threaded, no cross-call
    -- edge. `wrap` is the one that stays: it retypes an arbitrary value into
    -- the opaque `Value`, which is type ERASURE, not transport.
    , ( "Json", "wrap" )

    -- Inexpressible by construction: `a -> b` with unshared variables.
    , ( "Debugger", "unsafeCoerce" )

    -- Compiler-injected type descriptor + bespoke lowering.
    , ( "Debug", "toString" )
    , ( "Debug", "log" )
    ]



-- ====== HARNESS ======


run : Src.Module -> Result String Mono.MonoGraph
run srcModule =
    let
        defaults =
            Config.defaultLss
    in
    Pipeline.runSolverMonoWithLimits
        Config.defaultLimits
        -- The license is DEFAULT-PATH behaviour: no flag arm exists. `keyed`
        -- is what stores annotated demands in the registry at all.
        -- sigFlow PINNED OFF: LSS_021/022 kernel-boundary pins in isolation —
        -- the LSS_023 tunnel selector changes boundary behavior under sigFlow
        -- (default-on since 2026-08-21).
        { defaults | enabled = True, keyed = True, sigFlow = False }
        srcModule


keyName : ( String, String ) -> String
keyName ( home, name ) =
    home ++ "." ++ name


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


{-| Every stored (keyed) demand type for the named global, from the
registry's reverse mapping (the `LssSigFlowTest`/`MuTieTest` precedent).
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


allAnnos : String -> Mono.MonoGraph -> List Mono.LambdaSetAnno
allAnnos target graph =
    List.concatMap annosOf (demandsOf target graph)


annoHasSize : Int -> Mono.LambdaSetAnno -> Bool
annoHasSize n anno =
    case anno of
        Mono.LSet members ->
            List.length members == n

        Mono.LTop ->
            False

        Mono.LVar _ ->
            False


describeAnnos : List Mono.LambdaSetAnno -> String
describeAnnos annos =
    String.join ", "
        (List.map
            (\anno ->
                case anno of
                    Mono.LTop ->
                        "LTop"

                    Mono.LVar n ->
                        "LVar" ++ String.fromInt n

                    Mono.LSet ms ->
                        "LSet[" ++ String.join "," (List.map String.fromInt ms) ++ "]"
            )
            annos
        )



-- ====== FIXTURES ======


tInt : Src.Type
tInt =
    tType "Int" []


hInt : Src.Type
hInt =
    tLambda tInt tInt


tListOf : Src.Type -> Src.Type
tListOf el =
    tType "List" [ el ]


{-| Test 1: `consInc = List.cons inc` applies ONE of `cons`'s two params.
Positional rows are arity-aligned, so a boundary in this shape falls back to
LSS_004 full poison; a license has no positions to align, so unification
against however many args are present carries `g|inc` through anyway.

`inc` is a NAMED GLOBAL in direct argument position on purpose. Members are
injected per argument EXPRESSION (`Translate.injectArgLambdaMember` via
`argUnifyVar`), so a global nested inside a list literal contributes nothing
and could not pin anything.
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


{-| Test 2: the cheap class — `List.cons : a -> List a -> List a` at
`a = Int -> Int`. Nothing is applied; the license rests entirely on "the
element moves along the shared `a`".
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
