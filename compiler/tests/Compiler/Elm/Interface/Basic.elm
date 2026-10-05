module Compiler.Elm.Interface.Basic exposing (testIfaces)

{-| A test program has to be canonicalized against the interfaces of the
modules it imports, and the test suite has no compiled elm/core, elm/json,
elm/html, elm/virtual-dom or elm/bytes to take them from. This module builds
stand-ins for those interfaces by hand and collects them in `testIfaces`.

An interface is what a compiled module offers its importers: its values with
their type annotations, its unions, its aliases and its operators, together
with the package the module belongs to (`Compiler.Elm.Interface`). `testIfaces`
keys each interface by module name, and the canonicalizer pairs that name with
the interface's package to give the module's home. A test module can import
only the modules named there: importing any other module crashes
canonicalization, because the name is looked up with `Utils.Main.dictFind`.
The exception is a kernel module imported without `as` by a module of a kernel
package (one authored by `elm`, `elm-explorations` or `eco`); the canonicalizer
drops such imports.

Most of the file is the `Basics` interface, the only one built here with real
content. The other interfaces built here (`String`, `Char`, `Array`,
`Json.Encode`, `Json.Decode`, `Platform.Cmd`, `Platform.Sub`) each declare one
type with no constructors, and nothing else. The rest come from the sibling
modules `Compiler.Elm.Interface.List`, `.Maybe`, `.JsArray`, `.Bitwise`,
`.Tuple`, `.Html` and `.Bytes`.

Every annotation built here quantifies over all the type variables in its
type. Where elm/core uses a constrained type variable, the annotation uses one
named `number`, `comparable` or `appendable`; the type checker knows the
constraint from the name alone, as `Compiler.Data.Name` describes.

These interfaces are not elm/core 1.0.5 or elm/json, and a test that passes
against them says nothing about the places where they differ:

  - `::` is not in `Basics`; it is in the `List` interface.
  - `Basics` has only the values listed in `basicsValues`, and no `Never`
    type.
  - `Json.Decode.Value` is a separate type from `Json.Encode.Value`; elm/json
    makes the first an alias of the second.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Utils.Binop as Binop
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.Interface.Bitwise as BitwiseInterface
import Compiler.Elm.Interface.Bytes as BytesInterface
import Compiler.Elm.Interface.Html as HtmlInterface
import Compiler.Elm.Interface.JsArray as JsArrayInterface
import Compiler.Elm.Interface.List as ListInterface
import Compiler.Elm.Interface.Maybe as MaybeInterface
import Compiler.Elm.Interface.Tuple as TupleInterface
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Dict exposing (Dict)



-- ============================================================================
-- TEST ENVIRONMENT
-- ============================================================================


{-| The interface of elm/core's `Basics` as test programs see it: the unions of
`basicsUnions`, the values of `basicsValues` and the operators of
`standardBinops`, with no aliases.
-}
basicsInterface : I.Interface
basicsInterface =
    I.Interface
        { home = Pkg.core
        , values = basicsValues
        , unions = basicsUnions
        , aliases = Dict.empty
        , binops = standardBinops
        }


{-| The unions of the mock `Basics`, keyed by type name.

`Bool` and `Order` are open, so an importer can use their constructors, and
both are enumerations (`Can.Enum`). `Bool`'s constructors are `True` (index 0)
and `False` (index 1), as elm/core declares them; `Order`'s are `LT`, `EQ` and `GT`, indexed 0 to 2.

`Int` and `Float` are closed and have no constructors at all, so an importer
can name the types but has no constructor to build or match one with.

`String` and `Char` are not here; each has its own interface.

-}
basicsUnions : Dict Name I.Union
basicsUnions =
    let
        trueC =
            Can.Ctor { name = "True", index = Index.first, numArgs = 0, args = [] }

        falseC =
            Can.Ctor { name = "False", index = Index.second, numArgs = 0, args = [] }

        boolUnion =
            Can.Union
                { vars = []
                , alts = [ trueC, falseC ]
                , numAlts = 2
                , opts = Can.Enum
                }

        intUnion =
            Can.Union
                { vars = []
                , alts = []
                , numAlts = 0
                , opts = Can.Normal
                }

        floatUnion =
            Can.Union
                { vars = []
                , alts = []
                , numAlts = 0
                , opts = Can.Normal
                }

        ltC =
            Can.Ctor { name = "LT", index = Index.first, numArgs = 0, args = [] }

        eqC =
            Can.Ctor { name = "EQ", index = Index.second, numArgs = 0, args = [] }

        gtC =
            Can.Ctor { name = "GT", index = Index.third, numArgs = 0, args = [] }

        orderUnion =
            Can.Union
                { vars = []
                , alts = [ ltC, eqC, gtC ]
                , numAlts = 3
                , opts = Can.Enum
                }
    in
    Dict.fromList
        [ ( "Bool", I.OpenUnion boolUnion )
        , ( "Int", I.ClosedUnion intUnion )
        , ( "Float", I.ClosedUnion floatUnion )
        , ( "Order", I.OpenUnion orderUnion )
        ]


{-| Returns the names of the type variables in `tipe`: every `TVar`, every
record extension variable, and, for an alias, those of its arguments. An
alias's body is not searched, as in `Compiler.Canonicalize.Type`: a `Holey`
body names the alias's own parameters, which the alias binds.
-}
collectFreeVars : Can.Type Name -> Can.FreeVars
collectFreeVars tipe =
    case tipe of
        Can.TLambda _ a b ->
            Dict.union (collectFreeVars a) (collectFreeVars b)

        Can.TVar name ->
            Dict.singleton name ()

        Can.TType _ _ args ->
            List.foldl (\arg acc -> Dict.union (collectFreeVars arg) acc) Dict.empty args

        Can.TRecord fields maybeExt ->
            let
                fieldVars =
                    Dict.foldl (\_ (Can.FieldType _ t) acc -> Dict.union (collectFreeVars t) acc) Dict.empty fields

                extVar =
                    case maybeExt of
                        Just name ->
                            Dict.singleton name ()

                        Nothing ->
                            Dict.empty
            in
            Dict.union fieldVars extVar

        Can.TUnit ->
            Dict.empty

        Can.TTuple a b cs ->
            List.foldl (\t acc -> Dict.union (collectFreeVars t) acc)
                (Dict.union (collectFreeVars a) (collectFreeVars b))
                cs

        Can.TAlias _ _ args _ ->
            List.foldl (\( _, t ) acc -> Dict.union (collectFreeVars t) acc) Dict.empty args


{-| The operators of the mock `Basics`, keyed by operator symbol. Each names the
`Basics` function it stands for and carries an annotation, an associativity and
a precedence.

Names, types, precedences and associativities are elm/core 1.0.5's, and
elm/core has no other operators in `Basics`.

-}
standardBinops : Dict Name I.Binop
standardBinops =
    let
        numberVar =
            Can.TVar "number"

        appendableVar =
            Can.TVar "appendable"

        comparableVar =
            Can.TVar "comparable"

        aVar =
            Can.TVar "a"

        bVar =
            Can.TVar "b"

        boolType =
            Can.TType ModuleName.basics "Bool" []

        binop op funcName tipe assoc prec =
            ( op
            , I.Binop
                { name = funcName
                , annotation = Can.Forall (collectFreeVars tipe) tipe
                , associativity = assoc
                , precedence = prec
                }
            )

        -- number -> number -> number
        numBinType =
            Can.tLambda numberVar (Can.tLambda numberVar numberVar)

        intType =
            Can.TType ModuleName.basics "Int" []

        floatType =
            Can.TType ModuleName.basics "Float" []

        -- Int -> Int -> Int (for //)
        intBinType =
            Can.tLambda intType (Can.tLambda intType intType)

        -- Float -> Float -> Float (for /)
        floatBinType =
            Can.tLambda floatType (Can.tLambda floatType floatType)

        -- a -> a -> Bool
        eqType =
            Can.tLambda aVar (Can.tLambda aVar boolType)

        -- comparable -> comparable -> Bool
        compType =
            Can.tLambda comparableVar (Can.tLambda comparableVar boolType)

        -- appendable -> appendable -> appendable
        appendType =
            Can.tLambda appendableVar (Can.tLambda appendableVar appendableVar)

        -- Bool -> Bool -> Bool
        boolBinType =
            Can.tLambda boolType (Can.tLambda boolType boolType)

        -- a -> (a -> b) -> b (for |>)
        pipeRType =
            Can.tLambda aVar (Can.tLambda (Can.tLambda aVar bVar) bVar)

        -- (a -> b) -> a -> b (for <|)
        pipeLType =
            Can.tLambda (Can.tLambda aVar bVar) (Can.tLambda aVar bVar)

        cVar =
            Can.TVar "c"

        -- (a -> b) -> (b -> c) -> (a -> c) (for >>)
        composeRType =
            Can.tLambda (Can.tLambda aVar bVar) (Can.tLambda (Can.tLambda bVar cVar) (Can.tLambda aVar cVar))

        -- (b -> c) -> (a -> b) -> (a -> c) (for <<)
        composeLType =
            Can.tLambda (Can.tLambda bVar cVar) (Can.tLambda (Can.tLambda aVar bVar) (Can.tLambda aVar cVar))
    in
    Dict.fromList
        [ -- Arithmetic
          binop "+" "add" numBinType Binop.Left 6
        , binop "-" "sub" numBinType Binop.Left 6
        , binop "*" "mul" numBinType Binop.Left 7
        , binop "/" "fdiv" floatBinType Binop.Left 7
        , binop "//" "idiv" intBinType Binop.Left 7
        , binop "^" "pow" numBinType Binop.Right 8

        -- Comparison
        , binop "==" "eq" eqType Binop.Non 4
        , binop "/=" "neq" eqType Binop.Non 4
        , binop "<" "lt" compType Binop.Non 4
        , binop ">" "gt" compType Binop.Non 4
        , binop "<=" "le" compType Binop.Non 4
        , binop ">=" "ge" compType Binop.Non 4

        -- Boolean
        , binop "&&" "and" boolBinType Binop.Right 3
        , binop "||" "or" boolBinType Binop.Right 2

        -- Append
        , binop "++" "append" appendType Binop.Right 5

        -- Pipe
        , binop "|>" "apR" pipeRType Binop.Left 0
        , binop "<|" "apL" pipeLType Binop.Right 0

        -- Composition
        , binop ">>" "composeR" composeRType Binop.Right 9
        , binop "<<" "composeL" composeLType Binop.Left 9
        ]


{-| The interface of elm/core's `String`: the closed type `String`, with no
constructors, values or operators.
-}
stringInterface : I.Interface
stringInterface =
    let
        stringUnion =
            Can.Union
                { vars = []
                , alts = []
                , numAlts = 0
                , opts = Can.Normal
                }
    in
    I.Interface
        { home = Pkg.core
        , values = Dict.empty
        , unions = Dict.singleton "String" (I.ClosedUnion stringUnion)
        , aliases = Dict.empty
        , binops = Dict.empty
        }


{-| The interface of elm/core's `Char`: the closed type `Char`, with no
constructors, values or operators.
-}
charInterface : I.Interface
charInterface =
    let
        charUnion =
            Can.Union
                { vars = []
                , alts = []
                , numAlts = 0
                , opts = Can.Normal
                }
    in
    I.Interface
        { home = Pkg.core
        , values = Dict.empty
        , unions = Dict.singleton "Char" (I.ClosedUnion charUnion)
        , aliases = Dict.empty
        , binops = Dict.empty
        }


{-| The interface of elm/core's `Array`: the closed type `Array a`, with no
constructors, values or operators.
-}
arrayInterface : I.Interface
arrayInterface =
    let
        arrayUnion =
            Can.Union
                { vars = [ "a" ]
                , alts = []
                , numAlts = 0
                , opts = Can.Normal
                }
    in
    I.Interface
        { home = Pkg.core
        , values = Dict.empty
        , unions = Dict.singleton "Array" (I.ClosedUnion arrayUnion)
        , aliases = Dict.empty
        , binops = Dict.empty
        }


{-| The interface of elm/json's `Json.Encode`: the closed type `Value`, with no
constructors, values or operators.
-}
jsonEncodeInterface : I.Interface
jsonEncodeInterface =
    let
        valueUnion =
            Can.Union
                { vars = []
                , alts = []
                , numAlts = 0
                , opts = Can.Normal
                }
    in
    I.Interface
        { home = Pkg.json
        , values = Dict.empty
        , unions = Dict.singleton "Value" (I.ClosedUnion valueUnion)
        , aliases = Dict.empty
        , binops = Dict.empty
        }


{-| The interface of elm/json's `Json.Decode`: a closed type `Value` of its own,
with no constructors, values or operators.

This `Value` is a different type from `Json.Encode`'s, so a value of one is
rejected where the other is expected. In elm/json `Json.Decode.Value` is an
alias of `Json.Encode.Value`.

-}
jsonDecodeInterface : I.Interface
jsonDecodeInterface =
    let
        valueUnion =
            Can.Union
                { vars = []
                , alts = []
                , numAlts = 0
                , opts = Can.Normal
                }
    in
    I.Interface
        { home = Pkg.json
        , values = Dict.empty
        , unions = Dict.singleton "Value" (I.ClosedUnion valueUnion)
        , aliases = Dict.empty
        , binops = Dict.empty
        }


{-| The interface of elm/core's `Platform.Cmd`: the closed type `Cmd msg`, with
no constructors, values or operators.
-}
platformCmdInterface : I.Interface
platformCmdInterface =
    let
        cmdUnion =
            Can.Union
                { vars = [ "msg" ]
                , alts = []
                , numAlts = 0
                , opts = Can.Normal
                }
    in
    I.Interface
        { home = Pkg.core
        , values = Dict.empty
        , unions = Dict.singleton "Cmd" (I.ClosedUnion cmdUnion)
        , aliases = Dict.empty
        , binops = Dict.empty
        }


{-| The interface of elm/core's `Platform.Sub`: the closed type `Sub msg`, with
no constructors, values or operators.
-}
platformSubInterface : I.Interface
platformSubInterface =
    let
        subUnion =
            Can.Union
                { vars = [ "msg" ]
                , alts = []
                , numAlts = 0
                , opts = Can.Normal
                }
    in
    I.Interface
        { home = Pkg.core
        , values = Dict.empty
        , unions = Dict.singleton "Sub" (I.ClosedUnion subUnion)
        , aliases = Dict.empty
        , binops = Dict.empty
        }


{-| The interfaces test programs are canonicalized against, keyed by the module
name an import uses.

There are eighteen: `Basics`, `List`, `Maybe`, `Elm.JsArray`, `Bitwise`,
`Tuple`, `String`, `Char`, `Array`, `Json.Encode`, `Json.Decode`,
`Platform.Cmd`, `Platform.Sub`, `VirtualDom`, `Html`, `Bytes`, `Bytes.Encode`
and `Bytes.Decode`. Each interface names its own package, which together with
the key gives the module's home. Modules such as `Debug`, `Result`, `Platform`
and `Dict` are absent, and a test module that imports one crashes
canonicalization.

-}
testIfaces : Dict Name I.Interface
testIfaces =
    Dict.fromList
        [ ( "Basics", basicsInterface )
        , ( "List", ListInterface.listInterface )
        , ( "Maybe", MaybeInterface.maybeInterface )
        , ( "Elm.JsArray", JsArrayInterface.jsArrayInterface )
        , ( "Bitwise", BitwiseInterface.bitwiseInterface )
        , ( "Tuple", TupleInterface.tupleInterface )
        , ( "String", stringInterface )
        , ( "Char", charInterface )
        , ( "Array", arrayInterface )
        , ( "Json.Encode", jsonEncodeInterface )
        , ( "Json.Decode", jsonDecodeInterface )
        , ( "Platform.Cmd", platformCmdInterface )
        , ( "Platform.Sub", platformSubInterface )
        , ( "VirtualDom", HtmlInterface.virtualDomInterface )
        , ( "Html", HtmlInterface.htmlInterface )
        , ( "Bytes", BytesInterface.bytesInterface )
        , ( "Bytes.Encode", BytesInterface.bytesEncodeInterface )
        , ( "Bytes.Decode", BytesInterface.bytesDecodeInterface )
        ]


{-| Makes an annotation for `tipe` that quantifies over every type variable in
it, as `collectFreeVars` finds them.
-}
mkAnnotation : Can.Type Name -> Can.Annotation Name
mkAnnotation tipe =
    Can.Forall (collectFreeVars tipe) tipe


{-| The functions and constants of the mock `Basics`, keyed by name, with their
annotations. Each annotation has the type elm/core gives that value.

These are the only `Basics` values a test program can use. Among those absent
are `xor`, `degrees`, `radians`, `turns`, `toPolar`, `fromPolar` and
`never`.

-}
basicsValues : Dict Name (Can.Annotation Name)
basicsValues =
    let
        numberVar =
            Can.TVar "number"

        aVar =
            Can.TVar "a"

        bVar =
            Can.TVar "b"

        intType =
            Can.TType ModuleName.basics "Int" []

        floatType =
            Can.TType ModuleName.basics "Float" []

        boolType =
            Can.TType ModuleName.basics "Bool" []
    in
    Dict.fromList
        [ -- modBy : Int -> Int -> Int
          ( "modBy"
          , mkAnnotation (Can.tLambda intType (Can.tLambda intType intType))
          )

        -- remainderBy : Int -> Int -> Int
        , ( "remainderBy"
          , mkAnnotation (Can.tLambda intType (Can.tLambda intType intType))
          )

        -- ceiling : Float -> Int
        , ( "ceiling"
          , mkAnnotation (Can.tLambda floatType intType)
          )

        -- floor : Float -> Int
        , ( "floor"
          , mkAnnotation (Can.tLambda floatType intType)
          )

        -- logBase : Float -> Float -> Float
        , ( "logBase"
          , mkAnnotation (Can.tLambda floatType (Can.tLambda floatType floatType))
          )

        -- toFloat : Int -> Float
        , ( "toFloat"
          , mkAnnotation (Can.tLambda intType floatType)
          )

        -- always : a -> b -> a
        , ( "always"
          , mkAnnotation (Can.tLambda aVar (Can.tLambda bVar aVar))
          )

        -- max : comparable -> comparable -> comparable
        , ( "max"
          , let
                comparableVar =
                    Can.TVar "comparable"
            in
            mkAnnotation (Can.tLambda comparableVar (Can.tLambda comparableVar comparableVar))
          )

        -- identity : a -> a
        , ( "identity"
          , mkAnnotation (Can.tLambda aVar aVar)
          )

        -- not : Bool -> Bool
        , ( "not"
          , mkAnnotation (Can.tLambda boolType boolType)
          )

        -- negate : number -> number
        , ( "negate"
          , mkAnnotation (Can.tLambda numberVar numberVar)
          )

        -- abs : number -> number
        , ( "abs"
          , mkAnnotation (Can.tLambda numberVar numberVar)
          )

        -- pi : Float
        , ( "pi"
          , mkAnnotation floatType
          )

        -- e : Float
        , ( "e"
          , mkAnnotation floatType
          )

        -- sqrt : Float -> Float
        , ( "sqrt"
          , mkAnnotation (Can.tLambda floatType floatType)
          )

        -- sin : Float -> Float
        , ( "sin"
          , mkAnnotation (Can.tLambda floatType floatType)
          )

        -- cos : Float -> Float
        , ( "cos"
          , mkAnnotation (Can.tLambda floatType floatType)
          )

        -- tan : Float -> Float
        , ( "tan"
          , mkAnnotation (Can.tLambda floatType floatType)
          )

        -- asin : Float -> Float
        , ( "asin"
          , mkAnnotation (Can.tLambda floatType floatType)
          )

        -- acos : Float -> Float
        , ( "acos"
          , mkAnnotation (Can.tLambda floatType floatType)
          )

        -- atan : Float -> Float
        , ( "atan"
          , mkAnnotation (Can.tLambda floatType floatType)
          )

        -- atan2 : Float -> Float -> Float
        , ( "atan2"
          , mkAnnotation (Can.tLambda floatType (Can.tLambda floatType floatType))
          )

        -- round : Float -> Int
        , ( "round"
          , mkAnnotation (Can.tLambda floatType intType)
          )

        -- truncate : Float -> Int
        , ( "truncate"
          , mkAnnotation (Can.tLambda floatType intType)
          )

        -- isNaN : Float -> Bool
        , ( "isNaN"
          , mkAnnotation (Can.tLambda floatType boolType)
          )

        -- isInfinite : Float -> Bool
        , ( "isInfinite"
          , mkAnnotation (Can.tLambda floatType boolType)
          )

        -- min : comparable -> comparable -> comparable
        , ( "min"
          , let
                comparableVar =
                    Can.TVar "comparable"
            in
            mkAnnotation (Can.tLambda comparableVar (Can.tLambda comparableVar comparableVar))
          )

        -- clamp : number -> number -> number -> number
        , ( "clamp"
          , mkAnnotation (Can.tLambda numberVar (Can.tLambda numberVar (Can.tLambda numberVar numberVar)))
          )

        -- compare : comparable -> comparable -> Order
        , ( "compare"
          , let
                comparableVar =
                    Can.TVar "comparable"

                orderType =
                    Can.TType ModuleName.basics "Order" []
            in
            mkAnnotation (Can.tLambda comparableVar (Can.tLambda comparableVar orderType))
          )
        ]
