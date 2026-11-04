module SourceIR.CanonicalizeFailsCases exposing (expectRejectedSuite, expectSuite)

{-| Programs that canonicalization must reject, each with the report it must
be rejected with: the canonicalization module of the negative catalogue
(`SourceIR.Suite.RejectedSuites`), apart from the size limits, which are in
`SourceIR.LimitFailsCases`.

`expectRejectedSuite` gives a check each program with its
`SourceIR.Suite.Rejection.Rejection`, the title of the first report and a
fragment of its text, usually the name it is about;
`TestLogic.Reporting.ExpectedRejectionTest` checks that canonicalization
rejects each program with that report, and the name-clash oracle
(`TestLogic.Canonicalize.NameClashesTest`) that it rejects the clashing
names it reads from the program itself. `expectSuite` gives a check only the
programs.

The cases, by group:

  - "Duplicate declarations": a top-level value declared twice (with equal and
    with different bodies), two type aliases, two custom types, and an alias
    and a custom type of one name, a constructor twice in one custom type and
    once in each of two, from the former
    `Compiler.Canonicalize.DuplicateDeclsTest`; and two arguments of one
    function, two `let` bindings and two fields of one record literal sharing a
    name. Each is a `NAME CLASH` naming it.
  - "Shadowing": a `let` binding, a lambda argument and a `case` pattern that
    rebind a function's argument (from `DuplicateDeclsTest`), and a `let`
    binding and an argument that rebind a top-level value. Each is a
    `SHADOWING` naming it. They are written as source, so the two bindings are
    on different lines; on one line, as in a `Compiler.AST.SourceBuilder`
    program, whose regions are all the same, the report does not repeat the
    name.
  - "Recursive aliases": a type alias defined in terms of itself, an `ALIAS
    PROBLEM` that prints the alias's body as written, from the former
    `Compiler.Reporting.Render.TypePrintingCoverageTest`.
  - "Other naming errors": a top-level value defined by itself (`CYCLIC
    DEFINITION`), a `let` value defined by itself (`CYCLIC VALUE`), an unknown
    variable (`NAMING ERROR`) and operator (`UNKNOWN OPERATOR`), a constructor
    pattern with too many and too few arguments (`TOO MANY ARGS`, `TOO FEW
    ARGS`), and a tuple of four (`BAD TUPLE`).

Among what is not tested: errors in imports, exports, ports and effect
managers, ambiguous names, and the errors only `--optimize` reports.

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import SourceIR.Suite.Rejection
    exposing
        ( RejectedCase
        , Rejection
        , expectRejectedSuiteOf
        , expectSuiteOf
        , fromModule
        , fromSource
        , rejectedWithFragment
        )
import Test exposing (Test)


{-| Creates a group of tests, named "Canonicalization failure tests " followed
by `condStr`, with one test per group of cases (see `groups`). Each test
applies `expectFn` to the program of every case of its group in order, under
`Compiler.BulkCheck.bulkCheck`, so it passes only if every case passes, and a
failure names only the first failing case.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe ("Canonicalization failure tests " ++ condStr)
        (List.map (\( name, cases ) -> expectSuiteOf (name ++ " " ++ condStr) cases expectFn) groups)


{-| `expectSuite`, giving `expectFn` the `Rejection` each case records as well.
-}
expectRejectedSuite : (Src.Module -> Rejection -> Expectation) -> String -> Test
expectRejectedSuite expectFn condStr =
    Test.describe ("Canonicalization failure tests " ++ condStr)
        (List.map (\( name, cases ) -> expectRejectedSuiteOf (name ++ " " ++ condStr) cases expectFn) groups)


{-| Every case in this module, by group, each group under the name its test
gets.
-}
groups : List ( String, List RejectedCase )
groups =
    [ ( "Duplicate declarations", duplicateCases )
    , ( "Shadowing", shadowingCases )
    , ( "Recursive aliases", aliasCases )
    , ( "Other naming errors", otherCases )
    ]



-- ============================================================================
-- DUPLICATE DECLARATIONS
-- ============================================================================


{-| Two top-level values, two types or two constructors of one name, and a
name bound twice in one pattern or one record, each a `NAME CLASH` whose
message names it.
-}
duplicateCases : List RejectedCase
duplicateCases =
    [ fromModule "duplicate value declaration"
        (rejectedWithFragment "NAME CLASH" "multiple `foo` declarations")
        (\() -> duplicateValueModule "foo" (SB.intExpr 1) (SB.intExpr 1))
    , fromModule "duplicate value declaration with different bodies"
        (rejectedWithFragment "NAME CLASH" "multiple `bar` declarations")
        (\() -> duplicateValueModule "bar" (SB.intExpr 1) (SB.intExpr 2))
    , fromModule "duplicate type alias"
        (rejectedWithFragment "NAME CLASH" "multiple `MyAlias` types")
        (\() ->
            SB.makeModuleWithTypedDefsUnionsAliases "DupAlias"
                []
                []
                [ SB.AliasDef "MyAlias" [] (SB.tType "Int" [])
                , SB.AliasDef "MyAlias" [] (SB.tType "String" [])
                ]
        )
    , fromModule "duplicate union type"
        (rejectedWithFragment "NAME CLASH" "multiple `MyUnion` types")
        (\() ->
            SB.makeModuleWithTypedDefsUnionsAliases "DupUnion"
                []
                [ SB.UnionDef "MyUnion" [] [ SB.UnionCtor "A" [] ]
                , SB.UnionDef "MyUnion" [] [ SB.UnionCtor "B" [] ]
                ]
                []
        )
    , fromModule "alias and union with same name"
        (rejectedWithFragment "NAME CLASH" "multiple `Conflict` types")
        (\() ->
            SB.makeModuleWithTypedDefsUnionsAliases "AliasUnionConflict"
                []
                [ SB.UnionDef "Conflict" [] [ SB.UnionCtor "C" [] ] ]
                [ SB.AliasDef "Conflict" [] (SB.tType "Int" []) ]
        )
    , fromModule "duplicate constructor in same union"
        (rejectedWithFragment "NAME CLASH" "multiple `Dup` type constructors")
        (\() ->
            SB.makeModuleWithTypedDefsUnionsAliases "DupCtorSame"
                []
                [ SB.UnionDef "MyType"
                    []
                    [ SB.UnionCtor "Dup" []
                    , SB.UnionCtor "Dup" [ SB.tType "Int" [] ]
                    ]
                ]
                []
        )
    , fromModule "duplicate constructor across unions"
        (rejectedWithFragment "NAME CLASH" "multiple `Shared` type constructors")
        (\() ->
            SB.makeModuleWithTypedDefsUnionsAliases "DupCtorAcross"
                []
                [ SB.UnionDef "Type1" [] [ SB.UnionCtor "Shared" [] ]
                , SB.UnionDef "Type2" [] [ SB.UnionCtor "Shared" [] ]
                ]
                []
        )
    , fromSource "two arguments of one name"
        (rejectedWithFragment "NAME CLASH" "multiple `a` arguments")
        """
pick a a =
    a


testValue =
    pick 1 2
"""
    , fromSource "two let bindings of one name"
        (rejectedWithFragment "NAME CLASH" "`y`")
        """
testValue =
    let
        y =
            1

        y =
            2
    in
    y
"""
    , fromSource "a record field given twice"
        (rejectedWithFragment "NAME CLASH" "multiple `a` fields")
        """
testValue =
    { a = 1, a = 2 }
"""
    ]


{-| A module `DupValue` that declares the top-level value `name` twice, with the
bodies `first` and `second`.
-}
duplicateValueModule : String -> Src.Expr -> Src.Expr -> Src.Module
duplicateValueModule name first second =
    SB.makeModuleWithDefs "DupValue"
        [ ( name, [], first )
        , ( name, [], second )
        ]



-- ============================================================================
-- SHADOWING
-- ============================================================================


{-| A local binding that reuses a name an enclosing scope of the module already
binds, each a `SHADOWING` report naming it. The outer binding is an argument
of a top-level function or a top-level value. These are written as source, so
the two bindings are on different lines and the report, which then quotes
each, names the variable.
-}
shadowingCases : List RejectedCase
shadowingCases =
    [ fromSource "shadowing in let binding"
        (rejectedWithFragment "SHADOWING" "The name `x` is first defined here")
        """
test x =
    let
        x =
            1
    in
    x
"""
    , fromSource "shadowing in lambda"
        (rejectedWithFragment "SHADOWING" "The name `y` is first defined here")
        """
test y =
    \\y ->
        y
"""
    , fromSource "shadowing in case pattern"
        (rejectedWithFragment "SHADOWING" "The name `z` is first defined here")
        """
test z =
    case 1 of
        z ->
            z
"""
    , fromSource "a let binding shadowing a top-level value"
        (rejectedWithFragment "SHADOWING" "The name `limit` is first defined here")
        """
limit =
    10


testValue =
    let
        limit =
            20
    in
    limit
"""
    , fromSource "an argument shadowing a top-level value"
        (rejectedWithFragment "SHADOWING" "The name `scale` is first defined here")
        """
scale =
    2


double scale =
    scale * 2


testValue =
    double 3
"""
    ]



-- ============================================================================
-- RECURSIVE ALIASES
-- ============================================================================


{-| A type alias defined in terms of itself, an `ALIAS PROBLEM` whose report
suggests a `type` declaration holding the alias's body, printed as written
(`Compiler.Reporting.Render.Type.srcToDoc`). The second body uses an extensible
record, the unit type, a tuple, a function and a parenthesized type. From the
former `Compiler.Reporting.Render.TypePrintingCoverageTest`.
-}
aliasCases : List RejectedCase
aliasCases =
    [ fromSource "qualified type"
        (rejectedWithFragment "ALIAS PROBLEM" "Maybe.Maybe (List A)")
        "type alias A = Maybe.Maybe (List A)\n"
    , fromSource "extensible record, unit, tuple and function"
        (rejectedWithFragment "ALIAS PROBLEM" "{ r | f : ( (), A r, Int -> A r ) }")
        "type alias A r = { r | f : ( (), ( {- A -} A r ), Int -> A r ) }\n"
    ]



-- ============================================================================
-- OTHER NAMING ERRORS
-- ============================================================================


{-| A cyclic top-level value, a cyclic `let` value, an unknown variable and an
unknown operator, constructor patterns with too many and too few arguments,
and a tuple of four.
-}
otherCases : List RejectedCase
otherCases =
    [ fromSource "a top-level value defined by itself"
        (rejectedWithFragment "CYCLIC DEFINITION" "`loop`")
        """
loop =
    loop + 1


testValue =
    loop
"""
    , fromSource "a let value defined by itself"
        (rejectedWithFragment "CYCLIC VALUE" "`y`")
        """
testValue =
    let
        y =
            y + 1
    in
    y
"""
    , fromSource "an unknown variable"
        (rejectedWithFragment "NAMING ERROR" "`undefinedName`")
        """
testValue =
    undefinedName + 1
"""
    , fromSource "an unknown operator"
        (rejectedWithFragment "UNKNOWN OPERATOR" "(<=>)")
        """
testValue =
    1 <=> 2
"""
    , fromSource "a constructor pattern with too many arguments"
        (rejectedWithFragment "TOO MANY ARGS" "`Just`")
        """
f m =
    case m of
        Just a b ->
            a

        Nothing ->
            0


testValue =
    f (Just 1)
"""
    , fromSource "a constructor pattern with too few arguments"
        (rejectedWithFragment "TOO FEW ARGS" "`Pair`")
        """
type Pair
    = Pair Int Int


first (Pair a) =
    a


testValue =
    first (Pair 1 2)
"""
    , fromSource "a tuple of four"
        (rejectedWithFragment "BAD TUPLE" "two or three items")
        """
testValue =
    ( 1, 2, 3, 4 )
"""
    ]
