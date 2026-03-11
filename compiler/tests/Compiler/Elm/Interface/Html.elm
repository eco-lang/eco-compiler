module Compiler.Elm.Interface.Html exposing (htmlInterface, virtualDomInterface)

{-| Mock interfaces for Html and VirtualDom modules used by test infrastructure.

The typed optimizer requires `main` to have type `VirtualDom.Node msg` (aka `Html msg`).
These interfaces provide the minimal types needed for test modules to define a `main`
function via `Html.text`.

-}

import Compiler.AST.Canonical as Can
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Dict


{-| VirtualDom module interface - exports the Node type.
-}
virtualDomInterface : I.Interface
virtualDomInterface =
    let
        -- Node msg is an opaque type with one type parameter
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


{-| Html module interface - exports Html type alias and text function.

Html msg is an alias for VirtualDom.Node msg.

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


{-| text : String -> Html msg
-}
textAnnotation : Can.Annotation
textAnnotation =
    let
        stringType =
            Can.TType ModuleName.string "String" []

        htmlType =
            Can.TType ModuleName.virtualDom "Node" [ Can.TVar "msg" ]
    in
    Can.Forall (Dict.singleton "msg" ()) (Can.TLambda stringType htmlType)
