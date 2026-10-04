module TestLogic.Monomorphize.MonomorphizeTest exposing (suite)

{-| Tests of how monomorphization types a kernel function, a function the
runtime implements rather than Elm code. They check particular cases of the two
decisions `Compiler.Monomorphize.KernelAbi` makes about a kernel's type.

`Compiler.Monomorphize.KernelAbi` describes the two kernel ABI modes and how
`deriveKernelAbiMode` chooses between them. A kernel whose home is `Debug`
gets `PreserveVars`; any other gets `UseSubstitution` when no type variable
appears in its type and `PreserveVars` otherwise. The tests expect
`UseSubstitution` for every kernel type here that has no type variable, and
`PreserveVars` for every one that has. `canTypeToMonoType_preserveVars` is the
conversion of a kernel's type for `PreserveVars` mode. It turns every type
variable into `MVar id CEcoValue`, a value that is always boxed; it turns the
`elm/core` types `Int`, `Float`, `Bool`, `String` and `List` into `MInt`,
`MFloat`, `MBool`, `MString` and `mList`; and it turns each arrow into a
function of one parameter annotated `topAbi`.

The fixture is a canonical type per test, built with
`Compiler.AST.CanonicalBuilder` with named type variables. `convertForTest`
numbers them with `AssignMVarIds.assignIdsToType`, which gives the variables
ids from 0 in the order it first meets them and gives a repeated name the same
id, so `nthMVarId 0` is the first variable. That function also records a super
constraint for each variable whose name starts with `number`, `comparable`,
`appendable` or `compappend`, so in these tests the side table is filled from
the names. A kernel is passed as a (home, name) pair, and the name in a test's
label is only a label: `deriveKernelAbiMode` looks at the home and the type,
not the name.

What the tests establish:

  - `abiModeTests`: `Int -> Int -> Int` gives `UseSubstitution`; the types of
    `List.cons`, of `Basics.add` (`number -> number -> number`) and of
    `Debug.log` (`String -> a -> a`) give `PreserveVars`.
  - `monomorphicKernelTests`: `canTypeToMonoType_preserveVars` converts three
    types with no variable to their concrete MonoTypes, one parameter per
    function.
  - `polymorphicKernelTests` and `debugKernelTests`: every occurrence of the
    variable `a` converts to `MVar 0 CEcoValue`, and `Bool` and `String` next
    to it to `MBool` and `MString`. One test also converts `Int -> Int`, which
    has no variable, to `MInt` types.
  - `kernelExportsAbiTests`: the mode of seventeen kernels grouped by home
    module, and the converted types of `List.cons` and `Utils.equal`.
  - `kernelAbiPreservationTests`: the types of `List.cons` and `Utils.equal`
    convert with `MVar 0 CEcoValue` for every variable; a lone variable
    converts to `MVar 0 CEcoValue` even when it is a number variable, which
    the side table still records; and `List.cons` has mode `PreserveVars` and
    no `MInt` inside a function or list type of its converted type.
  - `superConstraintExportTests`: each of the four super constraints is
    recorded for a variable of that name, only `number` makes a number
    variable, and a plain variable has none.

Among what is not tested: a `Debug` kernel whose type has no type variable, the
one case where the home decides the mode; any use of a kernel at concrete types,
since every test converts the kernel's own type; how the monomorphizers turn the
mode into a call's type; the conversion of `Char`, records, tuples, unit,
custom types and aliases; and super constraints that come from a type
checker's solved variables rather than from names.

-}

import Compiler.AST.Canonical as Can
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
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeIds as TypeIds
import Compiler.Data.Id as Id
import Compiler.Data.Name exposing (Name)
import Compiler.Monomorphize.AssignMVarIds as AssignMVarIds
import Compiler.Monomorphize.KernelAbi as KernelAbi
import Compiler.Monomorphize.State as State
import Compiler.Type.Vars as Vars
import Dict
import Expect
import Test exposing (Test)


{-| Returns the `n`th MVarId counting from 0, the id `convertForTest` gives the
`n`th distinct type variable it meets. A negative `n` gives the first.
-}
nthMVarId : Int -> TypeIds.MVarId
nthMVarId n =
    nthMVarIdHelp n Id.first


{-| Returns `current` advanced by `remaining` ids, or `current` itself when
`remaining` is zero or less.
-}
nthMVarIdHelp : Int -> TypeIds.MVarId -> TypeIds.MVarId
nthMVarIdHelp remaining current =
    if remaining <= 0 then
        current

    else
        nthMVarIdHelp (remaining - 1) (Id.succ current)


{-| Returns the type variable with the `n`th MVarId and `constraint`, for
writing an expected MonoType.
-}
testMVarN : Int -> Mono.Constraint -> Mono.MonoType
testMVarN n constraint =
    Mono.MVar (nthMVarId n) constraint


{-| Returns `canType` with its type variables numbered by
`AssignMVarIds.assignIdsToType`, and an `MVarEnv` whose side table holds the
super constraint that function recorded for each variable, read from its name.
-}
convertForTest : Can.Type Name -> ( Can.Type TypeIds.MVarId, State.MVarEnv )
convertForTest canType =
    let
        ( converted, finalState ) =
            AssignMVarIds.assignIdsToType canType
    in
    ( converted, State.initMVarEnv finalState.nextId finalState.superVars )


{-| Reports whether `env` records the `n`th MVarId as a number variable.
-}
isNumberVar : Int -> State.MVarEnv -> Bool
isNumberVar n env =
    State.isNumberVar (nthMVarId n) env


{-| Returns the super constraint `env` records for the `n`th MVarId, or
`Nothing` when it records none.
-}
superOfNthVar : Int -> State.MVarEnv -> Maybe Vars.SuperType
superOfNthVar n env =
    Dict.get (Id.toComparable (nthMVarId n)) env.superVars


{-| Returns the MonoType `canTypeToMonoType_preserveVars` gives `canType` once
`convertForTest` has numbered its type variables.
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


{-| Returns the MonoType `preserveVars` gives `canType`, together with the
`MVarEnv` from `convertForTest`, so that a test can read its side table.
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


{-| Returns the kernel ABI mode `deriveKernelAbiMode` chooses for the kernel
`kernelId`, a (home, name) pair, given `canType` with its type variables
numbered by `convertForTest`.
-}
testDeriveAbiMode : ( String, String ) -> Can.Type Name -> KernelAbi.KernelAbiMode
testDeriveAbiMode kernelId canType =
    let
        ( converted, env ) =
            convertForTest canType
    in
    KernelAbi.deriveKernelAbiMode kernelId converted env


{-| Every test in this module, in the groups the module docstring lists.
-}
suite : Test
suite =
    Test.describe "Monomorphize.KernelAbi"
        [ abiModeTests
        , monomorphicKernelTests
        , polymorphicKernelTests
        , debugKernelTests
        , kernelExportsAbiTests
        , kernelAbiPreservationTests
        , superConstraintExportTests
        ]


{-| Tests of the side table `convertForTest` builds for a single type variable.

For a variable named `number`, `comparable`, `appendable` and `compappend`,
each test checks that the table records `Number`, `Comparable`, `Appendable` and
`CompAppend` respectively, and that `isNumberVar` is true only for `number`. For
a variable named `a` it checks that the table records nothing and `isNumberVar`
is false.

-}
superConstraintExportTests : Test
superConstraintExportTests =
    Test.describe "super constraint export (TYPE_SUPER_001)"
        [ Test.test "number var records Number and is a CNumber var" <|
            \_ ->
                let
                    ( _, env ) =
                        convertForTest (varType "number")
                in
                Expect.equal ( superOfNthVar 0 env, isNumberVar 0 env )
                    ( Just Vars.Number, True )
        , Test.test "comparable var records Comparable and is not a CNumber var" <|
            \_ ->
                let
                    ( _, env ) =
                        convertForTest (varType "comparable")
                in
                Expect.equal ( superOfNthVar 0 env, isNumberVar 0 env )
                    ( Just Vars.Comparable, False )
        , Test.test "appendable var records Appendable and is not a CNumber var" <|
            \_ ->
                let
                    ( _, env ) =
                        convertForTest (varType "appendable")
                in
                Expect.equal ( superOfNthVar 0 env, isNumberVar 0 env )
                    ( Just Vars.Appendable, False )
        , Test.test "compappend var records CompAppend and is not a CNumber var" <|
            \_ ->
                let
                    ( _, env ) =
                        convertForTest (varType "compappend")
                in
                Expect.equal ( superOfNthVar 0 env, isNumberVar 0 env )
                    ( Just Vars.CompAppend, False )
        , Test.test "plain type variable carries no super constraint" <|
            \_ ->
                let
                    ( _, env ) =
                        convertForTest (varType "a")
                in
                Expect.equal ( superOfNthVar 0 env, isNumberVar 0 env )
                    ( Nothing, False )
        ]



-- ============================================================================
-- ABI MODE TESTS
-- ============================================================================


{-| Tests of `deriveKernelAbiMode` on four kernels. `Basics.modBy` with
`Int -> Int -> Int` gives `UseSubstitution`. `List.cons` with
`a -> List a -> List a`, `Basics.add` with `number -> number -> number` and
`Debug.log` with `String -> a -> a` give `PreserveVars`.
-}
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
        , Test.test "Basics.add (suffix-selecting) returns PreserveVars" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "number", varType "number" ] (varType "number")

                    result =
                        testDeriveAbiMode ( "Basics", "add" ) canType
                in
                Expect.equal result KernelAbi.PreserveVars
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


{-| Tests of `canTypeToMonoType_preserveVars` on three types with no type
variable. `Int -> Int -> Int` gives a function from `MInt` to a function from
`MInt` to `MInt`, `Float -> Bool` gives a function from `MFloat` to `MBool`,
and `String -> List String` gives a function from `MString` to a list of
`MString`. Every function is annotated `topAbi`.
-}
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
                    (Mono.mFunction Mono.topAbi [ Mono.MInt ] (Mono.mFunction Mono.topAbi [ Mono.MInt ] Mono.MInt))
        , Test.test "Basics.isInfinite : Float -> Bool" <|
            \_ ->
                let
                    canType =
                        tFunc [ floatType ] boolType

                    result =
                        preserveVars canType
                in
                Expect.equal result
                    (Mono.mFunction Mono.topAbi [ Mono.MFloat ] Mono.MBool)
        , Test.test "String.lines : String -> List String" <|
            \_ ->
                let
                    canType =
                        tFunc [ stringType ] (listType stringType)

                    result =
                        preserveVars canType
                in
                Expect.equal result
                    (Mono.mFunction Mono.topAbi [ Mono.MString ] (Mono.mList Mono.MString))
        ]



-- ============================================================================
-- POLYMORPHIC KERNEL TESTS
-- ============================================================================


{-| Tests of `canTypeToMonoType_preserveVars` on three types.
`a -> List a -> List a` gives `MVar 0 CEcoValue` for every `a`, `a -> a -> Bool`
gives `MVar 0 CEcoValue` for both arguments and `MBool` for the result, and
`Int -> Int`, which has no variable, gives a function from `MInt` to `MInt`.
-}
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
                    (Mono.mFunction Mono.topAbi
                        [ testMVarN 0 Mono.CEcoValue ]
                        (Mono.mFunction Mono.topAbi
                            [ Mono.mList (testMVarN 0 Mono.CEcoValue) ]
                            (Mono.mList (testMVarN 0 Mono.CEcoValue))
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
                    (Mono.mFunction Mono.topAbi
                        [ testMVarN 0 Mono.CEcoValue ]
                        (Mono.mFunction Mono.topAbi
                            [ testMVarN 0 Mono.CEcoValue ]
                            Mono.MBool
                        )
                    )
        , Test.test "Polymorphic preserveVars converts Int to MInt" <|
            \_ ->
                let
                    canType =
                        tFunc [ intType ] intType

                    result =
                        preserveVars canType
                in
                Expect.equal result
                    (Mono.mFunction Mono.topAbi [ Mono.MInt ] Mono.MInt)
        ]



-- ============================================================================
-- DEBUG KERNEL TESTS
-- ============================================================================


{-| Tests of `canTypeToMonoType_preserveVars` on the types of `Debug.log`,
`String -> a -> a`, and `Debug.todo`, `String -> a`. `String` converts to
`MString` and each `a` to `MVar 0 CEcoValue`. No kernel home is involved, so
these do not test the rule for `Debug` kernels.
-}
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
                    (Mono.mFunction Mono.topAbi
                        [ Mono.MString ]
                        (Mono.mFunction Mono.topAbi
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
                    (Mono.mFunction Mono.topAbi
                        [ Mono.MString ]
                        (testMVarN 0 Mono.CEcoValue)
                    )
        ]



-- ============================================================================
-- KERNEL EXPORTS ABI TESTS
-- ============================================================================


{-| Tests of the kernel ABI mode of kernels of five home modules, one group per
home, with two tests of converted types among them.
-}
kernelExportsAbiTests : Test
kernelExportsAbiTests =
    Test.describe "KernelExports.h ABI compatibility"
        [ basicsModuleTests
        , listModuleTests
        , utilsModuleTests
        , stringModuleTests
        , charModuleTests
        ]


{-| Tests of the mode of seven `Basics` kernels. `modBy` (`Int -> Int -> Int`),
`floor` (`Float -> Int`), `toFloat` (`Int -> Float`) and `isNaN`
(`Float -> Bool`) give `UseSubstitution`. `add`, `mul` and `pow`, each
`number -> number -> number`, give `PreserveVars`. The mode does not depend on a
kernel's name, so those three tests differ only in names the mode ignores.
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
        , Test.test "add: number -> number -> number (suffix-selecting)" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "number", varType "number" ] (varType "number")

                    mode =
                        testDeriveAbiMode ( "Basics", "add" ) canType
                in
                Expect.equal mode KernelAbi.PreserveVars
        , Test.test "mul: number -> number -> number (suffix-selecting)" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "number", varType "number" ] (varType "number")

                    mode =
                        testDeriveAbiMode ( "Basics", "mul" ) canType
                in
                Expect.equal mode KernelAbi.PreserveVars
        , Test.test "pow: number -> number -> number (suffix-selecting)" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "number", varType "number" ] (varType "number")

                    mode =
                        testDeriveAbiMode ( "Basics", "pow" ) canType
                in
                Expect.equal mode KernelAbi.PreserveVars
        ]


{-| Tests of `List.cons` with `a -> List a -> List a`: its mode is
`PreserveVars`, and its converted type has `MVar 0 CEcoValue` for every `a`.
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
                Expect.equal result
                    (Mono.mFunction Mono.topAbi
                        [ testMVarN 0 Mono.CEcoValue ]
                        (Mono.mFunction Mono.topAbi
                            [ Mono.mList (testMVarN 0 Mono.CEcoValue) ]
                            (Mono.mList (testMVarN 0 Mono.CEcoValue))
                        )
                    )
        ]


{-| Tests of four `Utils` kernels. `equal` (`a -> a -> Bool`), `lt`
(`comparable -> comparable -> Bool`), `compare` and `append`
(`appendable -> appendable -> appendable`) give `PreserveVars`, and the
converted type of `equal` has `MVar 0 CEcoValue` for both arguments and
`MBool` for the result.

The `compare` test's result type is a type variable named `Order`, not the
`Order` type, so its type is `comparable -> comparable -> Order`, with two
type variables.

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
                Expect.equal result
                    (Mono.mFunction Mono.topAbi
                        [ testMVarN 0 Mono.CEcoValue ]
                        (Mono.mFunction Mono.topAbi
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


{-| Tests of the mode of three `String` kernels: `length` (`String -> Int`),
`append` (`String -> String -> String`) and `lines` (`String -> List String`)
give `UseSubstitution`.
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


{-| Tests of the mode of two `Char` kernels: `fromCode` (`Int -> Char`) and
`toCode` (`Char -> Int`) give `UseSubstitution`.
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
-- ============================================================================


{-| Tests that a polymorphic kernel's converted type keeps a boxed value for each
type variable.

The first two convert the types of `List.cons` and `Utils.equal` and expect
`MVar 0 CEcoValue` for every variable. Their labels speak of uses at particular
types, but no use is built: each converts only the kernel's own type, as
`polymorphicKernelTests` does.

The next two convert a lone variable. Named `a`, it gives `MVar 0 CEcoValue`
and is not a number variable. Named `number`, it also gives `MVar 0 CEcoValue`,
not a `CNumber` variable, while the side table records it as a number variable.

The last checks that `List.cons` with `a -> List a -> List a` has mode
`PreserveVars` and that its converted type has no `MInt` inside a function or
list type.

-}
kernelAbiPreservationTests : Test
kernelAbiPreservationTests =
    Test.describe "Kernel ABI type preservation"
        [ Test.test "List.cons ABI is same whether called with Int or String" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "a", listType (varType "a") ] (listType (varType "a"))

                    abiType =
                        preserveVars canType
                in
                Expect.equal abiType
                    (Mono.mFunction Mono.topAbi
                        [ testMVarN 0 Mono.CEcoValue ]
                        (Mono.mFunction Mono.topAbi
                            [ Mono.mList (testMVarN 0 Mono.CEcoValue) ]
                            (Mono.mList (testMVarN 0 Mono.CEcoValue))
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
                Expect.equal abiType
                    (Mono.mFunction Mono.topAbi
                        [ testMVarN 0 Mono.CEcoValue ]
                        (Mono.mFunction Mono.topAbi
                            [ testMVarN 0 Mono.CEcoValue ]
                            Mono.MBool
                        )
                    )
        , Test.test "PreserveVars mode always produces CEcoValue for type vars" <|
            \_ ->
                let
                    canType =
                        varType "a"

                    ( result, env ) =
                        preserveVarsWithEnv canType
                in
                Expect.all
                    [ \_ -> Expect.equal result (testMVarN 0 Mono.CEcoValue)
                    , \_ -> Expect.equal (isNumberVar 0 env) False
                    ]
                    ()
        , Test.test "PreserveVars mode produces CEcoValue even for 'number' var" <|
            \_ ->
                let
                    canType =
                        varType "number"

                    ( result, env ) =
                        preserveVarsWithEnv canType
                in
                Expect.all
                    [ \_ -> Expect.equal result (testMVarN 0 Mono.CEcoValue)
                    , \_ -> Expect.equal (isNumberVar 0 env) True
                    ]
                    ()
        , Test.test "Polymorphic kernel ABI must NOT contain MInt even when used at Int type" <|
            \_ ->
                let
                    canType =
                        tFunc [ varType "a", listType (varType "a") ] (listType (varType "a"))

                    mode =
                        testDeriveAbiMode ( "List", "cons" ) canType

                    abiType =
                        preserveVars canType

                    -- Looks inside function and list types only.
                    containsMInt monoType =
                        case monoType of
                            Mono.MInt ->
                                True

                            Mono.MFunction _ _ args ret ->
                                List.any containsMInt args || containsMInt ret

                            Mono.MList _ inner ->
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
