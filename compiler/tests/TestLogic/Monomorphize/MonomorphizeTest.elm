module TestLogic.Monomorphize.MonomorphizeTest exposing (suite)

{-| Unit tests for Kernel ABI type derivation in monomorphization.

These tests verify that the `deriveKernelAbiMode` function correctly classifies
kernels into their ABI modes, and that the type converters produce the expected
MonoTypes.

The expected ABI types are derived from the actual C signatures in:
elm-kernel-cpp/src/KernelExports.h

Key mapping from C types to MLIR/MonoType:

  - uint64\_t → eco.value (MVar with CEcoValue, or boxed pointer)
  - int64\_t → I64 (MInt)
  - double → F64 (MFloat)
  - bool → I1 (MBool)
  - uint16\_t → I16 (MChar)

-}

import Compiler.AST.CanonicalBuilder
    exposing
        ( boolType
        , charType
        , floatType
        , intType
        , listType
        , stringType
        , tFunc
        , varType
        )
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeIds as TypeIds
import Compiler.Data.Id as Id
import Compiler.Data.Name exposing (Name)
import Compiler.Monomorphize.AssignMVarIds as AssignMVarIds
import Compiler.Monomorphize.KernelAbi as KernelAbi
import Compiler.Monomorphize.State as State
import Dict
import Expect
import Test exposing (Test)


{-| Build the nth sequential MVarId (0-indexed).
-}
nthMVarId : Int -> TypeIds.MVarId
nthMVarId n =
    nthMVarIdHelp n Id.first


nthMVarIdHelp : Int -> TypeIds.MVarId -> TypeIds.MVarId
nthMVarIdHelp remaining current =
    if remaining <= 0 then
        current

    else
        nthMVarIdHelp (remaining - 1) (Id.succ current)


{-| Helper to construct an MVar with a specific sequential ID.
Use id=0 for the first type variable, id=1 for the second, etc.
-}
testMVarN : Int -> Mono.Constraint -> Mono.MonoType
testMVarN n constraint =
    Mono.MVar (nthMVarId n) constraint


{-| Convert a Can.Type Name to Can.Type MVarId for testing.
Returns the converted type and an MVarEnv initialized with the constraints.
-}
convertForTest : Can.Type Name -> ( Can.Type TypeIds.MVarId, State.MVarEnv )
convertForTest canType =
    let
        ( converted, finalState ) =
            AssignMVarIds.assignIdsToType canType
    in
    ( converted, State.initMVarEnv finalState.nextId finalState.constraints )


{-| Look up the constraint recorded in the side table for the nth MVarId.
-}
constraintOf : Int -> State.MVarEnv -> Maybe Mono.Constraint
constraintOf n env =
    State.lookupConstraint (nthMVarId n) env


{-| Helper to call canTypeToMonoType\_preserveVars, converting from Can.Type Name.
-}
preserveVars : Can.Type Name -> Mono.MonoType
preserveVars canType =
    let
        ( converted, env ) =
            convertForTest canType

        ( result, _ ) =
            KernelAbi.canTypeToMonoType_preserveVars env converted
    in
    result


{-| Like preserveVars but also returns the MVarEnv so tests can inspect the
constraint side table.
-}
preserveVarsWithEnv : Can.Type Name -> ( Mono.MonoType, State.MVarEnv )
preserveVarsWithEnv canType =
    let
        ( converted, env ) =
            convertForTest canType

        ( result, _ ) =
            KernelAbi.canTypeToMonoType_preserveVars env converted
    in
    ( result, env )


{-| Helper to call canTypeToMonoType\_numberBoxed, converting from Can.Type Name.
-}
numberBoxed : Can.Type Name -> Mono.MonoType
numberBoxed canType =
    let
        ( converted, env ) =
            convertForTest canType

        ( result, _ ) =
            KernelAbi.canTypeToMonoType_numberBoxed env converted
    in
    result


{-| Like numberBoxed but also returns the MVarEnv so tests can inspect the
constraint side table.
-}
numberBoxedWithEnv : Can.Type Name -> ( Mono.MonoType, State.MVarEnv )
numberBoxedWithEnv canType =
    let
        ( converted, env ) =
            convertForTest canType

        ( result, _ ) =
            KernelAbi.canTypeToMonoType_numberBoxed env converted
    in
    ( result, env )


{-| Helper to derive kernel ABI mode, converting from Can.Type Name.
-}
testDeriveAbiMode : ( String, String ) -> Can.Type Name -> KernelAbi.KernelAbiMode
testDeriveAbiMode kernelId canType =
    let
        ( converted, env ) =
            convertForTest canType
    in
    KernelAbi.deriveKernelAbiMode kernelId converted env


suite : Test
suite =
    Test.describe "Monomorphize.KernelAbi"
        [ abiModeTests
        , monomorphicKernelTests
        , polymorphicKernelTests
        , numberBoxedKernelTests
        , debugKernelTests
        , kernelExportsAbiTests
        , kernelAbiPreservationTests
        ]



-- ============================================================================
-- ABI MODE TESTS
-- ============================================================================


abiModeTests : Test
abiModeTests =
    Test.describe "deriveKernelAbiMode"
        [ Test.test "Monomorphic kernel returns UseSubstitution" <|
            \_ ->
                let
                    canType =
                        tFunc [ intType, intType ] intType

                    result =
                        testDeriveAbiMode ( "Basics", "modBy" ) canType
                in
                Expect.equal result KernelAbi.UseSubstitution
        , Test.test "Polymorphic kernel returns PreserveVars" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "a", listType (varType "a") ] (listType (varType "a"))

                    result =
                        testDeriveAbiMode ( "List", "cons" ) canType
                in
                Expect.equal result KernelAbi.PreserveVars
        , Test.test "Number-boxed kernel in whitelist returns NumberBoxed" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "number", varType "number" ] (varType "number")

                    result =
                        testDeriveAbiMode ( "Basics", "add" ) canType
                in
                Expect.equal result KernelAbi.NumberBoxed
        , Test.test "Debug kernel returns PreserveVars" <|
            \_ ->
                let
                    canType =
                        tFunc [ stringType, varType "a" ] (varType "a")

                    result =
                        testDeriveAbiMode ( "Debug", "log" ) canType
                in
                Expect.equal result KernelAbi.PreserveVars
        ]



-- ============================================================================
-- MONOMORPHIC KERNEL TESTS
-- ============================================================================


monomorphicKernelTests : Test
monomorphicKernelTests =
    Test.describe "Monomorphic kernels"
        [ Test.test "Basics.modBy : Int -> Int -> Int" <|
            \_ ->
                let
                    canType =
                        tFunc [ intType, intType ] intType

                    result =
                        preserveVars canType
                in
                Expect.equal result
                    (Mono.MFunction [ Mono.MInt ] (Mono.MFunction [ Mono.MInt ] Mono.MInt))
        , Test.test "Basics.isInfinite : Float -> Bool" <|
            \_ ->
                let
                    canType =
                        tFunc [ floatType ] boolType

                    result =
                        preserveVars canType
                in
                Expect.equal result
                    (Mono.MFunction [ Mono.MFloat ] Mono.MBool)
        , Test.test "String.lines : String -> List String" <|
            \_ ->
                let
                    canType =
                        tFunc [ stringType ] (listType stringType)

                    result =
                        preserveVars canType
                in
                Expect.equal result
                    (Mono.MFunction [ Mono.MString ] (Mono.MList Mono.MString))
        ]



-- ============================================================================
-- POLYMORPHIC KERNEL TESTS
-- ============================================================================


polymorphicKernelTests : Test
polymorphicKernelTests =
    Test.describe "Polymorphic kernels"
        [ Test.test "List.cons : a -> List a -> List a (preserves vars)" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "a", listType (varType "a") ] (listType (varType "a"))

                    result =
                        preserveVars canType
                in
                Expect.equal result
                    (Mono.MFunction
                        [ testMVarN 0 Mono.CEcoValue ]
                        (Mono.MFunction
                            [ Mono.MList (testMVarN 0 Mono.CEcoValue) ]
                            (Mono.MList (testMVarN 0 Mono.CEcoValue))
                        )
                    )
        , Test.test "Utils.equal : a -> a -> Bool (preserves vars)" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "a", varType "a" ] boolType

                    result =
                        preserveVars canType
                in
                Expect.equal result
                    (Mono.MFunction
                        [ testMVarN 0 Mono.CEcoValue ]
                        (Mono.MFunction
                            [ testMVarN 0 Mono.CEcoValue ]
                            Mono.MBool
                        )
                    )
        , Test.test "Polymorphic preserveVars converts Int to MInt" <|
            \_ ->
                let
                    -- Even in preserveVars mode, concrete types should be converted
                    canType =
                        tFunc [ intType ] intType

                    result =
                        preserveVars canType
                in
                Expect.equal result
                    (Mono.MFunction [ Mono.MInt ] Mono.MInt)
        ]



-- ============================================================================
-- NUMBER-BOXED KERNEL TESTS
-- ============================================================================


numberBoxedKernelTests : Test
numberBoxedKernelTests =
    Test.describe "Number-boxed kernels"
        [ Test.test "Basics.add : number -> number -> number (in whitelist)" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "number", varType "number" ] (varType "number")

                    ( result, env ) =
                        numberBoxedWithEnv canType
                in
                Expect.all
                    [ \_ ->
                        Expect.equal result
                            (Mono.MFunction
                                [ testMVarN 0 Mono.CEcoValue ]
                                (Mono.MFunction
                                    [ testMVarN 0 Mono.CEcoValue ]
                                    (testMVarN 0 Mono.CEcoValue)
                                )
                            )
                    , \_ ->
                        -- Side table must record the original CNumber constraint
                        Expect.equal (constraintOf 0 env) (Just Mono.CNumber)
                    ]
                    ()
        , Test.test "Basics.sub : number -> number -> number (in whitelist)" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "number", varType "number" ] (varType "number")

                    ( result, env ) =
                        numberBoxedWithEnv canType
                in
                Expect.all
                    [ \_ ->
                        Expect.equal result
                            (Mono.MFunction
                                [ testMVarN 0 Mono.CEcoValue ]
                                (Mono.MFunction
                                    [ testMVarN 0 Mono.CEcoValue ]
                                    (testMVarN 0 Mono.CEcoValue)
                                )
                            )
                    , \_ ->
                        -- Side table must record the original CNumber constraint
                        Expect.equal (constraintOf 0 env) (Just Mono.CNumber)
                    ]
                    ()
        , Test.test "numberBoxed converts concrete Int to MInt" <|
            \_ ->
                let
                    -- Concrete types should still be converted
                    canType =
                        tFunc [ intType ] intType

                    result =
                        numberBoxed canType
                in
                Expect.equal result
                    (Mono.MFunction [ Mono.MInt ] Mono.MInt)
        ]



-- ============================================================================
-- DEBUG KERNEL TESTS
-- ============================================================================


debugKernelTests : Test
debugKernelTests =
    Test.describe "Debug kernels (always polymorphic)"
        [ Test.test "Debug.log : String -> a -> a" <|
            \_ ->
                let
                    canType =
                        tFunc [ stringType, varType "a" ] (varType "a")

                    result =
                        preserveVars canType
                in
                Expect.equal result
                    (Mono.MFunction
                        [ Mono.MString ]
                        (Mono.MFunction
                            [ testMVarN 0 Mono.CEcoValue ]
                            (testMVarN 0 Mono.CEcoValue)
                        )
                    )
        , Test.test "Debug.todo : String -> a" <|
            \_ ->
                let
                    canType =
                        tFunc [ stringType ] (varType "a")

                    result =
                        preserveVars canType
                in
                Expect.equal result
                    (Mono.MFunction
                        [ Mono.MString ]
                        (testMVarN 0 Mono.CEcoValue)
                    )
        ]



-- ============================================================================
-- KERNEL EXPORTS ABI TESTS
-- Tests derived from actual C signatures in KernelExports.h
-- ============================================================================


kernelExportsAbiTests : Test
kernelExportsAbiTests =
    Test.describe "KernelExports.h ABI compatibility"
        [ basicsModuleTests
        , listModuleTests
        , utilsModuleTests
        , stringModuleTests
        , charModuleTests
        ]


{-| Tests for Basics module kernels.

From KernelExports.h:

  - int64\_t Elm\_Kernel\_Basics\_modBy(int64\_t modulus, int64\_t x)
  - int64\_t Elm\_Kernel\_Basics\_floor(double x)
  - double Elm\_Kernel\_Basics\_toFloat(int64\_t x)
  - uint64\_t Elm\_Kernel\_Basics\_add(uint64\_t a, uint64\_t b) -- number-boxed
  - bool Elm\_Kernel\_Basics\_isNaN(double x)

-}
basicsModuleTests : Test
basicsModuleTests =
    Test.describe "Basics module"
        [ Test.test "modBy: Int -> Int -> Int (monomorphic)" <|
            \_ ->
                let
                    canType =
                        tFunc [ intType, intType ] intType

                    mode =
                        testDeriveAbiMode ( "Basics", "modBy" ) canType
                in
                Expect.equal mode KernelAbi.UseSubstitution
        , Test.test "floor: Float -> Int (monomorphic)" <|
            \_ ->
                let
                    canType =
                        tFunc [ floatType ] intType

                    mode =
                        testDeriveAbiMode ( "Basics", "floor" ) canType
                in
                Expect.equal mode KernelAbi.UseSubstitution
        , Test.test "toFloat: Int -> Float (monomorphic)" <|
            \_ ->
                let
                    canType =
                        tFunc [ intType ] floatType

                    mode =
                        testDeriveAbiMode ( "Basics", "toFloat" ) canType
                in
                Expect.equal mode KernelAbi.UseSubstitution
        , Test.test "isNaN: Float -> Bool (monomorphic)" <|
            \_ ->
                let
                    canType =
                        tFunc [ floatType ] boolType

                    mode =
                        testDeriveAbiMode ( "Basics", "isNaN" ) canType
                in
                Expect.equal mode KernelAbi.UseSubstitution
        , Test.test "add: number -> number -> number (number-boxed)" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "number", varType "number" ] (varType "number")

                    mode =
                        testDeriveAbiMode ( "Basics", "add" ) canType
                in
                Expect.equal mode KernelAbi.NumberBoxed
        , Test.test "mul: number -> number -> number (number-boxed)" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "number", varType "number" ] (varType "number")

                    mode =
                        testDeriveAbiMode ( "Basics", "mul" ) canType
                in
                Expect.equal mode KernelAbi.NumberBoxed
        , Test.test "pow: number -> number -> number (number-boxed)" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "number", varType "number" ] (varType "number")

                    mode =
                        testDeriveAbiMode ( "Basics", "pow" ) canType
                in
                Expect.equal mode KernelAbi.NumberBoxed
        ]


{-| Tests for List module kernels.

From KernelExports.h:

  - uint64\_t Elm\_Kernel\_List\_cons(uint64\_t head, uint64\_t tail)
    C ABI: (eco.value, eco.value) -> eco.value

-}
listModuleTests : Test
listModuleTests =
    Test.describe "List module"
        [ Test.test "cons: a -> List a -> List a (polymorphic)" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "a", listType (varType "a") ] (listType (varType "a"))

                    mode =
                        testDeriveAbiMode ( "List", "cons" ) canType
                in
                Expect.equal mode KernelAbi.PreserveVars
        , Test.test "cons ABI type has all eco.value args" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "a", listType (varType "a") ] (listType (varType "a"))

                    result =
                        preserveVars canType
                in
                -- Expected C ABI: uint64_t cons(uint64_t head, uint64_t tail)
                -- All args should be eco.value (MVar with CEcoValue)
                Expect.equal result
                    (Mono.MFunction
                        [ testMVarN 0 Mono.CEcoValue ]
                        (Mono.MFunction
                            [ Mono.MList (testMVarN 0 Mono.CEcoValue) ]
                            (Mono.MList (testMVarN 0 Mono.CEcoValue))
                        )
                    )
        ]


{-| Tests for Utils module kernels.

From KernelExports.h:

  - bool Elm\_Kernel\_Utils\_equal(uint64\_t a, uint64\_t b)
  - bool Elm\_Kernel\_Utils\_lt(uint64\_t a, uint64\_t b)
  - uint64\_t Elm\_Kernel\_Utils\_compare(uint64\_t a, uint64\_t b)
  - uint64\_t Elm\_Kernel\_Utils\_append(uint64\_t a, uint64\_t b)

All polymorphic - take eco.value args.

-}
utilsModuleTests : Test
utilsModuleTests =
    Test.describe "Utils module"
        [ Test.test "equal: a -> a -> Bool (polymorphic)" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "a", varType "a" ] boolType

                    mode =
                        testDeriveAbiMode ( "Utils", "equal" ) canType
                in
                Expect.equal mode KernelAbi.PreserveVars
        , Test.test "equal ABI type has eco.value args" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "a", varType "a" ] boolType

                    result =
                        preserveVars canType
                in
                -- Expected C ABI: bool equal(uint64_t a, uint64_t b)
                Expect.equal result
                    (Mono.MFunction
                        [ testMVarN 0 Mono.CEcoValue ]
                        (Mono.MFunction
                            [ testMVarN 0 Mono.CEcoValue ]
                            Mono.MBool
                        )
                    )
        , Test.test "lt: comparable -> comparable -> Bool (polymorphic)" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "comparable", varType "comparable" ] boolType

                    mode =
                        testDeriveAbiMode ( "Utils", "lt" ) canType
                in
                Expect.equal mode KernelAbi.PreserveVars
        , Test.test "compare: comparable -> comparable -> Order (polymorphic)" <|
            \_ ->
                let
                    -- Order is a custom type, represented as eco.value in return
                    orderType =
                        varType "Order"

                    canType =
                        tFunc [ varType "comparable", varType "comparable" ] orderType

                    mode =
                        testDeriveAbiMode ( "Utils", "compare" ) canType
                in
                Expect.equal mode KernelAbi.PreserveVars
        , Test.test "append: appendable -> appendable -> appendable (polymorphic)" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "appendable", varType "appendable" ] (varType "appendable")

                    mode =
                        testDeriveAbiMode ( "Utils", "append" ) canType
                in
                Expect.equal mode KernelAbi.PreserveVars
        ]


{-| Tests for String module kernels.

From KernelExports.h:

  - int64\_t Elm\_Kernel\_String\_length(uint64\_t str)
  - uint64\_t Elm\_Kernel\_String\_append(uint64\_t a, uint64\_t b)

String is passed as uint64\_t (eco.value pointer to String object).

-}
stringModuleTests : Test
stringModuleTests =
    Test.describe "String module"
        [ Test.test "length: String -> Int (monomorphic)" <|
            \_ ->
                let
                    canType =
                        tFunc [ stringType ] intType

                    mode =
                        testDeriveAbiMode ( "String", "length" ) canType
                in
                Expect.equal mode KernelAbi.UseSubstitution
        , Test.test "append: String -> String -> String (monomorphic)" <|
            \_ ->
                let
                    canType =
                        tFunc [ stringType, stringType ] stringType

                    mode =
                        testDeriveAbiMode ( "String", "append" ) canType
                in
                Expect.equal mode KernelAbi.UseSubstitution
        , Test.test "lines: String -> List String (monomorphic)" <|
            \_ ->
                let
                    canType =
                        tFunc [ stringType ] (listType stringType)

                    mode =
                        testDeriveAbiMode ( "String", "lines" ) canType
                in
                Expect.equal mode KernelAbi.UseSubstitution
        ]


{-| Tests for Char module kernels.

From KernelExports.h:

  - uint16\_t Elm\_Kernel\_Char\_fromCode(int64\_t code)
  - int64\_t Elm\_Kernel\_Char\_toCode(uint16\_t c)

-}
charModuleTests : Test
charModuleTests =
    Test.describe "Char module"
        [ Test.test "fromCode: Int -> Char (monomorphic)" <|
            \_ ->
                let
                    canType =
                        tFunc [ intType ] charType

                    mode =
                        testDeriveAbiMode ( "Char", "fromCode" ) canType
                in
                Expect.equal mode KernelAbi.UseSubstitution
        , Test.test "toCode: Char -> Int (monomorphic)" <|
            \_ ->
                let
                    canType =
                        tFunc [ charType ] intType

                    mode =
                        testDeriveAbiMode ( "Char", "toCode" ) canType
                in
                Expect.equal mode KernelAbi.UseSubstitution
        ]



-- ============================================================================
-- KERNEL ABI TYPE PRESERVATION TESTS
-- These tests verify that kernel ABI types are consistent regardless of
-- call-site instantiation. This catches bugs where the ABI type gets
-- incorrectly replaced with the instantiated type.
--
-- Bug that was caught: In ensureCallableTopLevel, MonoVarKernel was being
-- reconstructed with `monoType` (the instantiated type) instead of preserving
-- the original `kernelAbiType`. This caused List.cons to sometimes have
-- signature [I64, eco.value] -> eco.value instead of always having
-- [eco.value, eco.value] -> eco.value.
-- ============================================================================


kernelAbiPreservationTests : Test
kernelAbiPreservationTests =
    Test.describe "Kernel ABI type preservation"
        [ Test.test "List.cons ABI is same whether called with Int or String" <|
            \_ ->
                let
                    -- The canonical type is always polymorphic
                    canType =
                        tFunc [ varType "a", listType (varType "a") ] (listType (varType "a"))

                    -- Regardless of call-site, ABI should be the same
                    abiType =
                        preserveVars canType
                in
                -- The ABI type should have MVar with CEcoValue, NOT MInt or MString
                Expect.equal abiType
                    (Mono.MFunction
                        [ testMVarN 0 Mono.CEcoValue ]
                        (Mono.MFunction
                            [ Mono.MList (testMVarN 0 Mono.CEcoValue) ]
                            (Mono.MList (testMVarN 0 Mono.CEcoValue))
                        )
                    )
        , Test.test "Utils.equal ABI is same whether called with Int or custom type" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "a", varType "a" ] boolType

                    abiType =
                        preserveVars canType
                in
                -- Should NOT have MInt even if called at Int type
                Expect.equal abiType
                    (Mono.MFunction
                        [ testMVarN 0 Mono.CEcoValue ]
                        (Mono.MFunction
                            [ testMVarN 0 Mono.CEcoValue ]
                            Mono.MBool
                        )
                    )
        , Test.test "PreserveVars mode always produces CEcoValue for type vars" <|
            \_ ->
                let
                    -- Even a simple type var should become CEcoValue
                    canType =
                        varType "a"

                    ( result, env ) =
                        preserveVarsWithEnv canType
                in
                Expect.all
                    [ \_ -> Expect.equal result (testMVarN 0 Mono.CEcoValue)
                    , \_ -> Expect.equal (constraintOf 0 env) (Just Mono.CEcoValue)
                    ]
                    ()
        , Test.test "PreserveVars mode produces CEcoValue even for 'number' var" <|
            \_ ->
                let
                    -- In preserveVars mode, even 'number' becomes CEcoValue (not CNumber)
                    -- but the side table should record it as CNumber
                    canType =
                        varType "number"

                    ( result, env ) =
                        preserveVarsWithEnv canType
                in
                Expect.all
                    [ \_ -> Expect.equal result (testMVarN 0 Mono.CEcoValue)
                    , \_ -> Expect.equal (constraintOf 0 env) (Just Mono.CNumber)
                    ]
                    ()
        , Test.test "Polymorphic kernel ABI must NOT contain MInt even when used at Int type" <|
            \_ ->
                let
                    -- This test documents the invariant that was violated:
                    -- When List.cons is used at type Int -> List Int -> List Int,
                    -- the KERNEL ABI type must still be a -> List a -> List a with CEcoValue,
                    -- NOT Int -> List Int -> List Int with MInt.
                    canType =
                        tFunc [ varType "a", listType (varType "a") ] (listType (varType "a"))

                    mode =
                        testDeriveAbiMode ( "List", "cons" ) canType

                    abiType =
                        preserveVars canType

                    -- Verify the ABI type does not contain MInt anywhere
                    containsMInt monoType =
                        case monoType of
                            Mono.MInt ->
                                True

                            Mono.MFunction args ret ->
                                List.any containsMInt args || containsMInt ret

                            Mono.MList inner ->
                                containsMInt inner

                            _ ->
                                False
                in
                Expect.all
                    [ \_ -> Expect.equal mode KernelAbi.PreserveVars
                    , \_ -> Expect.equal (containsMInt abiType) False
                    ]
                    ()
        ]
