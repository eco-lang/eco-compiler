module Common.FormatTests exposing (suite)

{-| Tests for `Common.Format.format`, the built-in Elm source formatter. Without
them, a change in what the formatter prints for these two inputs would go
unnoticed: each test compares the whole output with an exact expected string.

The input is built by `generateModule` from a `GenerateModuleConfig`: a module
header, a documentation slot, imports, infix declarations and top-level
declarations, joined with newlines. `defaultModule` is the module
`module Main exposing (..)` with the single declaration `fn = ()`. Both tests
format as the package `elm/core`.

What the tests establish:

  - "Header": `defaultModule` formats to the header, two blank lines, and
    `fn =` with `()` on the next line indented four spaces, ending in a newline.
  - "Records": a declaration whose record literal has a block comment
    (`{- C1 -}` to `{- C8 -}`) before each field name, between name and `=`,
    between `=` and value, and after each value, formats with each field
    starting a line of its own and the closing brace on its own line. The
    comments before and inside a field (`C1` to `C3`, `C5` to `C7`) stay where
    they were, and each comment after a value (`C4`, `C8`) moves to a line of
    its own after a blank line, before the next comma or the closing brace.

Among what is not tested: input that fails to parse, any project type other
than the `elm/core` package, module documentation, imports, infix declarations,
more than one declaration, and every other kind of expression or declaration.

-}

import Common.Format
import Compiler.Elm.Package as Pkg
import Compiler.Parse.Module as M
import Expect
import Test exposing (Test)


{-| The two formatter tests, "Header" and "Records".
-}
suite : Test
suite =
    Test.describe "Common.Format.format"
        [ Test.describe "fromByteString"
            [ (\_ ->
                Common.Format.format (M.Package Pkg.core) (generateModule defaultModule)
                    |> Expect.equal (Ok "module Main exposing (..)\n\n\nfn =\n    ()\n")
              )
                |> Test.test "Header"
            , (\_ ->
                Common.Format.format
                    (M.Package Pkg.core)
                    (generateModule
                        { defaultModule
                            | declarations =
                                [ "fn = { {- C1 -} a {- C2 -} = {- C3 -} 1 {- C4 -}, {- C5 -} b {- C6 -} = {- C7 -} 2 {- C8 -} }"
                                ]
                        }
                    )
                    |> Expect.equal (Ok "module Main exposing (..)\n\n\nfn =\n    { {- C1 -} a {- C2 -} = {- C3 -} 1\n\n    {- C4 -}\n    , {- C5 -} b {- C6 -} = {- C7 -} 2\n\n    {- C8 -}\n    }\n")
              )
                |> Test.test "Records"
            ]
        ]


{-| The parts of an Elm module's source text, in the order `generateModule`
writes them.

`docs` is raw source text placed between the header and the imports, not
prose to be wrapped in a comment. Each entry of `imports`, `infixes` and
`declarations` is one or more lines of source.

-}
type alias GenerateModuleConfig =
    { header : String
    , docs : String
    , imports : List String
    , infixes : List String
    , declarations : List String
    }


{-| The smallest module the tests use: `module Main exposing (..)` with the one
declaration `fn = ()`, and no documentation, imports or infix declarations.
-}
defaultModule : GenerateModuleConfig
defaultModule =
    { header = "module Main exposing (..)"
    , docs = ""
    , imports = []
    , infixes = []
    , declarations = [ "fn = ()" ]
    }


{-| Returns the source text of the module the configuration describes: the
header, the documentation text, the imports, the infix declarations and the
declarations, each section separated from the next by one newline and the
entries within a section joined by newlines. An empty section still contributes
its separator, so `defaultModule` has three blank lines between its header and
`fn = ()`.
-}
generateModule : GenerateModuleConfig -> String
generateModule { header, docs, imports, infixes, declarations } =
    String.join "\n"
        [ header
        , docs
        , String.join "\n" imports
        , String.join "\n" infixes
        , String.join "\n" declarations
        ]
