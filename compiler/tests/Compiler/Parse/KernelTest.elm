module Compiler.Parse.KernelTest exposing (suite)

{-| Tests of `Compiler.Parse.Kernel.fromByteString`: a valid kernel file gives
its chunks, and every way a kernel file can be wrong gives its
`Compiler.Parse.Error.Kernel` problem instead of crashing the compiler or being
accepted.

Each case is a kernel file of the package `elm/foo`, with no foreign modules,
whose header line is line 3 and whose body starts on line 7, so an import's
module name, after `import`, starts at line 3, column 8.

  - "a valid file": a header importing `Elm.Kernel.Utils exposing (eq)` and a
    body using `__Utils_eq` gives the JavaScript around the tag and the tag's
    `JsVar`.
  - The five header imports the Elm import syntax allows but a kernel file does
    not: `as` on a kernel import, a dotted module without `as`,
    `exposing (..)`, `Maybe(..)` and `(+)`. Each gives its problem at the
    region of the import's module name.
  - "an unknown tag": `__Nope_x` in the body, with no import naming it, gives
    `KernelUnknownTag` at the position of its leading `__`.
  - "no header" and "an unfinished import": a file that does not open with
    `/*`, and a header whose `import` has no module name, give
    `KernelHeaderSyntax`.

These problems used to crash the compiler (the five imports) or make
`fromByteString` return `Nothing`, which `Builder.Build` ignored
(plans/dead-code-report.md, b2-parse).

-}

import Compiler.Core.Annotation as A
import Compiler.IR.Kernel.Chunk exposing (Chunk(..), Content(..))
import Compiler.Parse.Error as E
import Compiler.Parse.Kernel as Kernel
import Dict
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Compiler.Parse.Kernel.fromByteString"
        [ Test.test "a valid file" <|
            \_ ->
                parse "import Elm.Kernel.Utils exposing (eq)" "var a = __Utils_eq;\n"
                    |> Result.map (\(Content _ chunks) -> chunks)
                    |> Expect.equal (Ok [ JS "\n\nvar a = ", JsVar "Elm" "Utils" "eq", JS ";\n" ])
        , Test.test "`as` on a kernel import" <|
            \_ ->
                parse "import Elm.Kernel.Utils as U exposing (eq)" ""
                    |> Expect.equal (Err (E.KernelImportAlias (nameAt 16) "Elm.Kernel.Utils"))
        , Test.test "a dotted module without `as`" <|
            \_ ->
                parse "import Json.Decode exposing (field)" ""
                    |> Expect.equal (Err (E.KernelDottedWithoutAlias (nameAt 11) "Json.Decode"))
        , Test.test "`exposing (..)`" <|
            \_ ->
                parse "import Maybe exposing (..)" ""
                    |> Expect.equal (Err (E.KernelExposingAll (nameAt 5) "Maybe"))
        , Test.test "a type exposed with its constructors" <|
            \_ ->
                parse "import Maybe exposing (Maybe(..))" ""
                    |> Expect.equal (Err (E.KernelExposingCtors (nameAt 5) "Maybe" "Maybe"))
        , Test.test "an operator" <|
            \_ ->
                parse "import Basics exposing ((+))" ""
                    |> Expect.equal (Err (E.KernelExposingOperator (nameAt 6) "Basics" "+"))
        , Test.test "an unknown tag" <|
            \_ ->
                parse "" "var a = __Nope_x;\n"
                    |> Expect.equal (Err (E.KernelUnknownTag 7 9 "Nope_x"))
        , Test.test "no header" <|
            \_ ->
                Kernel.fromByteString ( "elm", "foo" ) Dict.empty "var a = 1;\n"
                    |> Expect.equal (Err (E.KernelHeaderSyntax 1 1))
        , Test.test "an unfinished import" <|
            \_ ->
                case parse "import" "" of
                    Err (E.KernelHeaderSyntax _ _) ->
                        Expect.pass

                    other ->
                        Expect.fail ("expected KernelHeaderSyntax, got " ++ Debug.toString other)
        ]


{-| Parses a kernel file of `elm/foo` whose header holds `header` on line 3 and
whose body, from line 7, is `body`.
-}
parse : String -> String -> Result E.Kernel Content
parse header body =
    Kernel.fromByteString ( "elm", "foo" ) Dict.empty ("/*\n\n" ++ header ++ "\n\n*/\n\n" ++ body)


{-| The region of an import's module name of `width` characters on line 3.
-}
nameAt : Int -> A.Region
nameAt width =
    A.Region (A.Position 3 8) (A.Position 3 (8 + width))
