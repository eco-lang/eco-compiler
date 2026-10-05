module TestLogic.LocalOpt.Typed.TypeEqTest exposing (suite)

{-| Tests for `TestLogic.LocalOpt.Typed.TypeEq.alphaEqStrict`, the
alpha-equivalence the typed-optimization checks compare types with. A check
built on it is only as good as the comparison, so each test pins one case the
comparison once got wrong, or the one it must keep refusing.

The types are built by hand as `Can.Type Name` values. `Id`, `G`, `R` and
`Tagged` are aliases in module `Test` of package `author/project`; `Msg` is a
custom type declared in two modules of that package.

What the tests establish:

  - Alpha-equivalence itself: `a -> b` matches `x -> y`, `a -> a` does not
    match `x -> y`, and a type variable does not match `Int`.
  - An alias against a bare type variable is expanded: `Id b` matches `b`.
  - A `Filled` alias body is not substituted into again: `G b a`, whose
    `Filled` body is `( b, a )`, matches `( b, a )`.
  - A `Holey` alias body has its arguments substituted for record extension
    variables: `R { y : Int }` matches `{ x : Int, y : Int }`.
  - Extension variables and type variables share one renaming:
    `{ r | x : Int } -> r` does not match `{ r | x : Int } -> s`.
  - A phantom alias parameter is not compared, as aliases are transparent:
    `Tagged Int` matches `Tagged String`.
  - Named types in different modules of one package differ: `A.Msg` does not
    match `B.Msg`.

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Dict
import Expect
import Test exposing (Test)
import TestLogic.LocalOpt.Typed.TypeEq exposing (alphaEqStrict)


{-| The cases described in the module docstring.
-}
suite : Test
suite =
    Test.describe "TypeEq.alphaEqStrict"
        [ Test.test "a -> b matches x -> y" <|
            \_ -> Expect.equal True (alphaEqStrict (arrow (v "a") (v "b")) (arrow (v "x") (v "y")))
        , Test.test "a -> a does not match x -> y" <|
            \_ -> Expect.equal False (alphaEqStrict (arrow (v "a") (v "a")) (arrow (v "x") (v "y")))
        , Test.test "a type variable does not match Int" <|
            \_ -> Expect.equal False (alphaEqStrict (v "a") int)
        , Test.test "Id b matches b" <|
            \_ ->
                Expect.equal True
                    (alphaEqStrict (alias "Id" [ ( "a", v "b" ) ] (Can.Holey (v "a"))) (v "b"))
        , Test.test "G b a with a Filled body matches ( b, a )" <|
            \_ ->
                Expect.equal True
                    (alphaEqStrict
                        (arrow (alias "G" [ ( "a", v "b" ), ( "b", v "a" ) ] (Can.Filled (Can.TTuple (v "b") (v "a") []))) (v "b"))
                        (arrow (Can.TTuple (v "b") (v "a") []) (v "b"))
                    )
        , Test.test "R { y : Int } matches { x : Int, y : Int }" <|
            \_ ->
                Expect.equal True
                    (alphaEqStrict
                        (alias "R" [ ( "a", record [ ( "y", int ) ] Nothing ) ] (Can.Holey (record [ ( "x", int ) ] (Just "a"))))
                        (record [ ( "x", int ), ( "y", int ) ] Nothing)
                    )
        , Test.test "{ r | x : Int } -> r does not match { r | x : Int } -> s" <|
            \_ ->
                Expect.equal False
                    (alphaEqStrict
                        (arrow (record [ ( "x", int ) ] (Just "r")) (v "r"))
                        (arrow (record [ ( "x", int ) ] (Just "r")) (v "s"))
                    )
        , Test.test "Tagged Int matches Tagged String (aliases are transparent)" <|
            \_ ->
                Expect.equal True
                    (alphaEqStrict
                        (alias "Tagged" [ ( "a", int ) ] (Can.Holey int))
                        (alias "Tagged" [ ( "a", Can.TType (home "String") "String" [] ) ] (Can.Holey int))
                    )
        , Test.test "A.Msg does not match B.Msg" <|
            \_ ->
                Expect.equal False
                    (alphaEqStrict (Can.TType (home "A") "Msg" []) (Can.TType (home "B") "Msg" []))
        ]


{-| The home of module `name` in package `author/project`.
-}
home : String -> ModuleName.Canonical
home name =
    ModuleName.Canonical ( "author", "project" ) name


{-| The type variable `name`.
-}
v : Name -> Can.Type Name
v =
    Can.TVar


{-| The type `Int`.
-}
int : Can.Type Name
int =
    Can.TType (ModuleName.Canonical ( "elm", "core" ) "Basics") "Int" []


{-| The function type `a -> b`.
-}
arrow : Can.Type Name -> Can.Type Name -> Can.Type Name
arrow =
    Can.tLambda


{-| The alias `name`, declared in module `Test`, applied to `args`, with body
`body`.
-}
alias : Name -> List ( Name, Can.Type Name ) -> Can.AliasType Name -> Can.Type Name
alias name args body =
    Can.TAlias (home "Test") name args body


{-| The record type with `fields`, in order, and extension variable `ext`.
-}
record : List ( Name, Can.Type Name ) -> Maybe Name -> Can.Type Name
record fields ext =
    Can.TRecord (Dict.fromList (List.indexedMap (\i ( n, t ) -> ( n, Can.FieldType i t )) fields)) ext
