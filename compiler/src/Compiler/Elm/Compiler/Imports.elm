module Compiler.Elm.Compiler.Imports exposing (defaults)

{-| An Elm module can use names from several `elm/core` modules without importing
them, and this module writes down those _default imports_ so that the rest of
the compiler can treat them like imports the module wrote itself.

The default imports are the same as these lines of source:

    import Basics exposing (..)
    import Debug
    import List exposing ((::))
    import Maybe exposing (Maybe(..))
    import Result exposing (Result(..))
    import String exposing (String)
    import Char exposing (Char)
    import Tuple
    import Platform exposing (Program)
    import Platform.Cmd as Cmd exposing (Cmd)
    import Platform.Sub as Sub exposing (Sub)

They are built as `Src.Import` values, the form the parser gives an `import`
line. Since no source text holds them, every region in them is `A.zero` and
every group of comments is empty. `Compiler.Parse.Module` adds them to the
imports of every module it parses, unless the module belongs to the `elm/core`
package itself.

The `List` type is not exposed by these imports: `List` exposes only `(::)`.
The type is in scope without them because canonicalization starts every
module's environment with it, in `Compiler.Canonicalize.Environment.Foreign`.

@docs defaults

-}

import Compiler.AST.Source as Src
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A



-- ====== DEFAULTS ======


{-| The default imports listed in the module docstring, in that order, each
paired with an empty group of comments.
-}
defaults : List (Src.C1 Src.Import)
defaults =
    [ ( [], import_ ModuleName.basics Nothing (Src.Open [] []) )
    , ( [], import_ ModuleName.debug Nothing closed )
    , ( [], import_ ModuleName.list Nothing (operator "::") )
    , ( [], import_ ModuleName.maybe Nothing (typeOpen Name.maybe) )
    , ( [], import_ ModuleName.result Nothing (typeOpen Name.result) )
    , ( [], import_ ModuleName.string Nothing (typeClosed Name.string) )
    , ( [], import_ ModuleName.char Nothing (typeClosed Name.char) )
    , ( [], import_ ModuleName.tuple Nothing closed )
    , ( [], import_ ModuleName.platform Nothing (typeClosed Name.program) )
    , ( [], import_ ModuleName.cmd (Just Name.cmd) (typeClosed Name.cmd) )
    , ( [], import_ ModuleName.sub (Just Name.sub) (typeClosed Name.sub) )
    ]


{-| Builds an import of the module a canonical name names, under the alias
`maybeAlias` if there is one, exposing `exposing_`.

Only the module's own name is kept; the package half of the canonical name is
dropped, because an import names a module as source does. The name's region is
`A.zero` and every group of comments is empty.

-}
import_ : ModuleName.Canonical -> Maybe Name -> Src.Exposing -> Src.Import
import_ (ModuleName.Canonical _ name) maybeAlias exposing_ =
    Src.Import ( [], A.At A.zero name ) (Maybe.map (\alias_ -> ( ( [], [] ), alias_ )) maybeAlias) ( ( [], [] ), exposing_ )



-- ====== EXPOSING ======


{-| An exposing list with nothing in it, the form an import written without
`exposing` takes.
-}
closed : Src.Exposing
closed =
    Src.Explicit (A.At A.zero [])


{-| Builds an exposing list holding only the type `name` and its constructors,
as `exposing (Maybe(..))` writes it.
-}
typeOpen : Name -> Src.Exposing
typeOpen name =
    Src.Explicit (A.At A.zero [ ( ( [], [] ), Src.Upper (A.At A.zero name) ( [], Src.Public A.zero ) ) ])


{-| Builds an exposing list holding only the type `name`, without its
constructors, as `exposing (String)` writes it.
-}
typeClosed : Name -> Src.Exposing
typeClosed name =
    Src.Explicit (A.At A.zero [ ( ( [], [] ), Src.Upper (A.At A.zero name) ( [], Src.Private ) ) ])


{-| Builds an exposing list holding only the operator `op`, as
`exposing ((::))` writes it.
-}
operator : Name -> Src.Exposing
operator op =
    Src.Explicit (A.At A.zero [ ( ( [], [] ), Src.Operator A.zero op ) ])
