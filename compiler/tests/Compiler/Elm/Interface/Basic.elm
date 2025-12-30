module Compiler.Elm.Interface.Basic exposing (testIfaces)

{-| Shared test infrastructure for emulating the interface of elm/core Basics.
-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Utils.Binop as Binop
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.Interface as I
import Compiler.Elm.Interface.List as ListInterface
import Compiler.Elm.Interface.Maybe as MaybeInterface
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
        , values = Dict.empty
        , unions = basicsUnions
        , aliases = Dict.empty
        , binops = standardBinops
        }


{-| Basic unions: Bool (True/False) and Int.
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
    in
    Dict.fromList identity
        [ ( "Bool", I.OpenUnion boolUnion )
        , ( "Int", I.ClosedUnion intUnion )
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

        -- Common types
        boolType =
            Can.TType ModuleName.basics "Bool" []

        listA =
            Can.TType ModuleName.list "List" [ aVar ]

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

        -- a -> List a -> List a
        consType =
            Can.TLambda aVar (Can.TLambda listA listA)

        -- Bool -> Bool -> Bool
        boolBinType =
            Can.TLambda boolType (Can.TLambda boolType boolType)
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

        -- Cons (precedence 5)
        , binop "::" "cons" consType Binop.Right 5
        ]


{-| Test environment with Basics, List, and Maybe module interfaces.
-}
testIfaces : Dict String Name I.Interface
testIfaces =
    Dict.fromList identity
        [ ( "Basics", basicsInterface )
        , ( "List", ListInterface.listInterface )
        , ( "Maybe", MaybeInterface.maybeInterface )
        ]
