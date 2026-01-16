module Compiler.Elm.Interface.Basic exposing (testIfaces)

{-| Shared test infrastructure for emulating the interface of elm/core Basics.
-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Utils.Binop as Binop
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.Interface.Bitwise as BitwiseInterface
import Compiler.Elm.Interface.JsArray as JsArrayInterface
import Compiler.Elm.Interface.List as ListInterface
import Compiler.Elm.Interface.Maybe as MaybeInterface
import Compiler.Elm.Interface.Tuple as TupleInterface
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Data.Map as Dict exposing (Dict)



-- ============================================================================
-- TEST ENVIRONMENT
-- ============================================================================


{-| The Basics module interface containing Bool (True/False), Int, and standard operators.
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


{-| Basic unions: Bool (True/False), Int, and Float.
String and Char are in their own modules (String.String, Char.Char).
-}
basicsUnions : Dict String Name I.Union
basicsUnions =
    let
        -- Bool type
        falseC =
            Can.Ctor { name = "False", index = Index.first, numArgs = 0, args = [] }

        trueC =
            Can.Ctor { name = "True", index = Index.second, numArgs = 0, args = [] }

        boolUnion =
            Can.Union
                { vars = []
                , alts = [ falseC, trueC ]
                , numAlts = 2
                , opts = Can.Enum
                }

        -- Int type (opaque, no constructors exposed)
        intUnion =
            Can.Union
                { vars = []
                , alts = []
                , numAlts = 0
                , opts = Can.Normal
                }

        -- Float type (opaque, no constructors exposed)
        floatUnion =
            Can.Union
                { vars = []
                , alts = []
                , numAlts = 0
                , opts = Can.Normal
                }
    in
    Dict.fromList identity
        [ ( "Bool", I.OpenUnion boolUnion )
        , ( "Int", I.ClosedUnion intUnion )
        , ( "Float", I.ClosedUnion floatUnion )
        ]


{-| Collect all free type variables from a canonical type.
-}
collectFreeVars : Can.Type -> Can.FreeVars
collectFreeVars tipe =
    case tipe of
        Can.TLambda a b ->
            Dict.union (collectFreeVars a) (collectFreeVars b)

        Can.TVar name ->
            Dict.singleton identity name ()

        Can.TType _ _ args ->
            List.foldl (\arg acc -> Dict.union (collectFreeVars arg) acc) Dict.empty args

        Can.TRecord fields maybeExt ->
            let
                fieldVars =
                    Dict.foldl compare (\_ (Can.FieldType _ t) acc -> Dict.union (collectFreeVars t) acc) Dict.empty fields

                extVar =
                    case maybeExt of
                        Just name ->
                            Dict.singleton identity name ()

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

        Can.TAlias _ _ args aliasType ->
            let
                argVars =
                    List.foldl (\( _, t ) acc -> Dict.union (collectFreeVars t) acc) Dict.empty args
            in
            case aliasType of
                Can.Holey t ->
                    Dict.union argVars (collectFreeVars t)

                Can.Filled t ->
                    Dict.union argVars (collectFreeVars t)


{-| Standard binary operators from Basics.
-}
standardBinops : Dict String Name I.Binop
standardBinops =
    let
        -- Type variables
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

        -- Common types
        boolType =
            Can.TType ModuleName.basics "Bool" []

        -- Helper to create a binop
        binop op funcName tipe assoc prec =
            ( op
            , I.Binop
                { name = funcName
                , annotation = Can.Forall (collectFreeVars tipe) tipe
                , associativity = assoc
                , precedence = prec
                }
            )

        -- Number -> Number -> Number
        numBinType =
            Can.TLambda numberVar (Can.TLambda numberVar numberVar)

        -- a -> a -> Bool
        eqType =
            Can.TLambda aVar (Can.TLambda aVar boolType)

        -- comparable -> comparable -> Bool
        compType =
            Can.TLambda comparableVar (Can.TLambda comparableVar boolType)

        -- appendable -> appendable -> appendable
        appendType =
            Can.TLambda appendableVar (Can.TLambda appendableVar appendableVar)

        -- Bool -> Bool -> Bool
        boolBinType =
            Can.TLambda boolType (Can.TLambda boolType boolType)

        -- a -> (a -> b) -> b (for |>)
        pipeRType =
            Can.TLambda aVar (Can.TLambda (Can.TLambda aVar bVar) bVar)

        -- (a -> b) -> a -> b (for <|)
        pipeLType =
            Can.TLambda (Can.TLambda aVar bVar) (Can.TLambda aVar bVar)
    in
    Dict.fromList identity
        [ -- Arithmetic (precedence 6-7)
          binop "+" "add" numBinType Binop.Left 6
        , binop "-" "sub" numBinType Binop.Left 6
        , binop "*" "mul" numBinType Binop.Left 7
        , binop "/" "fdiv" numBinType Binop.Left 7
        , binop "//" "idiv" numBinType Binop.Left 7
        , binop "^" "pow" numBinType Binop.Right 8
        , binop "%" "modBy" numBinType Binop.Left 7

        -- Comparison (precedence 4)
        , binop "==" "eq" eqType Binop.Non 4
        , binop "/=" "neq" eqType Binop.Non 4
        , binop "<" "lt" compType Binop.Non 4
        , binop ">" "gt" compType Binop.Non 4
        , binop "<=" "le" compType Binop.Non 4
        , binop ">=" "ge" compType Binop.Non 4

        -- Boolean (precedence 3)
        , binop "&&" "and" boolBinType Binop.Right 3
        , binop "||" "or" boolBinType Binop.Right 2

        -- Append (precedence 5)
        , binop "++" "append" appendType Binop.Right 5

        -- Note: :: (cons) is defined in List interface only.
        -- Test modules should import List to use it.
        -- Pipe (precedence 0)
        , binop "|>" "apR" pipeRType Binop.Left 0
        , binop "<|" "apL" pipeLType Binop.Right 0
        ]


{-| String module interface - exports the String type.
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
        , unions = Dict.singleton identity "String" (I.ClosedUnion stringUnion)
        , aliases = Dict.empty
        , binops = Dict.empty
        }


{-| Char module interface - exports the Char type.
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
        , unions = Dict.singleton identity "Char" (I.ClosedUnion charUnion)
        , aliases = Dict.empty
        , binops = Dict.empty
        }


{-| Test environment with Basics, List, Maybe, JsArray, Bitwise, Tuple, String, and Char module interfaces.
-}
testIfaces : Dict String Name I.Interface
testIfaces =
    Dict.fromList identity
        [ ( "Basics", basicsInterface )
        , ( "List", ListInterface.listInterface )
        , ( "Maybe", MaybeInterface.maybeInterface )
        , ( "Elm.JsArray", JsArrayInterface.jsArrayInterface )
        , ( "Bitwise", BitwiseInterface.bitwiseInterface )
        , ( "Tuple", TupleInterface.tupleInterface )
        , ( "String", stringInterface )
        , ( "Char", charInterface )
        ]


{-| Helper to create a value annotation with collected free vars.
-}
mkAnnotation : Can.Type -> Can.Annotation
mkAnnotation tipe =
    Can.Forall (collectFreeVars tipe) tipe


{-| Basics module function values needed by Array.elm.
-}
basicsValues : Dict String Name Can.Annotation
basicsValues =
    let
        -- Type variables
        numberVar =
            Can.TVar "number"

        aVar =
            Can.TVar "a"

        bVar =
            Can.TVar "b"

        -- Common types
        intType =
            Can.TType ModuleName.basics "Int" []

        floatType =
            Can.TType ModuleName.basics "Float" []

        boolType =
            Can.TType ModuleName.basics "Bool" []
    in
    Dict.fromList identity
        [ -- remainderBy : Int -> Int -> Int
          ( "remainderBy"
          , mkAnnotation (Can.TLambda intType (Can.TLambda intType intType))
          )

        -- ceiling : Float -> Int
        , ( "ceiling"
          , mkAnnotation (Can.TLambda floatType intType)
          )

        -- floor : Float -> Int
        , ( "floor"
          , mkAnnotation (Can.TLambda floatType intType)
          )

        -- logBase : Float -> Float -> Float
        , ( "logBase"
          , mkAnnotation (Can.TLambda floatType (Can.TLambda floatType floatType))
          )

        -- toFloat : Int -> Float
        , ( "toFloat"
          , mkAnnotation (Can.TLambda intType floatType)
          )

        -- always : a -> b -> a
        , ( "always"
          , mkAnnotation (Can.TLambda aVar (Can.TLambda bVar aVar))
          )

        -- max : comparable -> comparable -> comparable
        , ( "max"
          , let
                comparableVar =
                    Can.TVar "comparable"
            in
            mkAnnotation (Can.TLambda comparableVar (Can.TLambda comparableVar comparableVar))
          )

        -- identity : a -> a
        , ( "identity"
          , mkAnnotation (Can.TLambda aVar aVar)
          )

        -- not : Bool -> Bool
        , ( "not"
          , mkAnnotation (Can.TLambda boolType boolType)
          )

        -- negate : number -> number
        , ( "negate"
          , mkAnnotation (Can.TLambda numberVar numberVar)
          )

        -- abs : number -> number
        , ( "abs"
          , mkAnnotation (Can.TLambda numberVar numberVar)
          )

        -- Float constants and math functions
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
          , mkAnnotation (Can.TLambda floatType floatType)
          )

        -- sin : Float -> Float
        , ( "sin"
          , mkAnnotation (Can.TLambda floatType floatType)
          )

        -- cos : Float -> Float
        , ( "cos"
          , mkAnnotation (Can.TLambda floatType floatType)
          )

        -- tan : Float -> Float
        , ( "tan"
          , mkAnnotation (Can.TLambda floatType floatType)
          )

        -- asin : Float -> Float
        , ( "asin"
          , mkAnnotation (Can.TLambda floatType floatType)
          )

        -- acos : Float -> Float
        , ( "acos"
          , mkAnnotation (Can.TLambda floatType floatType)
          )

        -- atan : Float -> Float
        , ( "atan"
          , mkAnnotation (Can.TLambda floatType floatType)
          )

        -- atan2 : Float -> Float -> Float
        , ( "atan2"
          , mkAnnotation (Can.TLambda floatType (Can.TLambda floatType floatType))
          )

        -- round : Float -> Int
        , ( "round"
          , mkAnnotation (Can.TLambda floatType intType)
          )

        -- truncate : Float -> Int
        , ( "truncate"
          , mkAnnotation (Can.TLambda floatType intType)
          )

        -- isNaN : Float -> Bool
        , ( "isNaN"
          , mkAnnotation (Can.TLambda floatType boolType)
          )

        -- isInfinite : Float -> Bool
        , ( "isInfinite"
          , mkAnnotation (Can.TLambda floatType boolType)
          )

        -- min : comparable -> comparable -> comparable
        , ( "min"
          , let
                comparableVar =
                    Can.TVar "comparable"
            in
            mkAnnotation (Can.TLambda comparableVar (Can.TLambda comparableVar comparableVar))
          )

        -- clamp : number -> number -> number -> number
        , ( "clamp"
          , mkAnnotation (Can.TLambda numberVar (Can.TLambda numberVar (Can.TLambda numberVar numberVar)))
          )
        ]
