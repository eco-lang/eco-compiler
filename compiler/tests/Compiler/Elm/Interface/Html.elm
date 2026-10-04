module Compiler.Elm.Interface.Html exposing (htmlInterface, virtualDomInterface)

{-| Hand-built interfaces for the `VirtualDom` and `Html` modules, holding just
enough for a test program to define `main` as `Html.text "..."`.

The typed optimizer, `Compiler.LocalOpt.Typed.Module`, accepts as a `main` a
value whose type expands to `VirtualDom.Node` applied to one type, among others;
a test program type-checked against these interfaces gets such a `main` without
elm/virtual-dom or elm/html being compiled.

Each interface declares one function, `text`, of type
`String -> VirtualDom.Node msg`. `VirtualDom` adds the type `Node msg`, and
`Html` adds the alias `Html msg` for it.

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Dict


{-| The mock `VirtualDom` interface, homed in the elm/virtual-dom package.

`Node msg` is a closed union, one exported without its constructors, and it
has no constructors to export. A test program can name the type, but can make
a `Node` only through `text` and cannot match on one.

-}
virtualDomInterface : I.Interface
virtualDomInterface =
    let
        nodeUnion =
            Can.Union
                { vars = [ "msg" ]
                , alts = []
                , numAlts = 0
                , opts = Can.Normal
                }
    in
    I.Interface
        { home = Pkg.virtualDom
        , values =
            Dict.fromList
                [ ( "text", textAnnotation )
                ]
        , unions = Dict.singleton "Node" (I.ClosedUnion nodeUnion)
        , aliases = Dict.empty
        , binops = Dict.empty
        }


{-| The mock `Html` interface, homed in the elm/html package, holding `text` and
the public alias `Html msg` for `VirtualDom.Node msg`.
-}
htmlInterface : I.Interface
htmlInterface =
    I.Interface
        { home = Pkg.html
        , values =
            Dict.fromList
                [ ( "text", textAnnotation )
                ]
        , unions = Dict.empty
        , aliases =
            Dict.singleton "Html"
                (I.PublicAlias
                    (Can.Alias [ "msg" ]
                        (Can.TType ModuleName.virtualDom "Node" [ Can.TVar "msg" ])
                    )
                )
        , binops = Dict.empty
        }


{-| The annotation of `text` in both interfaces: `String -> VirtualDom.Node msg`,
quantified over `msg`. It names `VirtualDom.Node` directly rather than the
`Html` alias, which expands to the same type.
-}
textAnnotation : Can.Annotation Name
textAnnotation =
    let
        stringType =
            Can.TType ModuleName.string "String" []

        htmlType =
            Can.TType ModuleName.virtualDom "Node" [ Can.TVar "msg" ]
    in
    Can.Forall (Dict.singleton "msg" ()) (Can.tLambda stringType htmlType)
