module Compiler.LocalOpt.Typed.Expression exposing
    ( Cycle, Annotations
    , optimize, optimizePotentialTailCall
    , destructArgs
    )

{-| Monomorphization needs to know the type of every expression it specializes,
and this module lowers one expression of a definition into the typed optimized
AST of `Compiler.AST.TypedOptimized` with that type attached.

Every node it builds carries a _meta_: the node's `Can.Type`, and where one is
known, its _solver variable_, the type checker's variable for that expression.
Both come from two tables indexed by canonical node id, _exprTypes_ (each
expression's or pattern's solved type) and _exprVars_ (its solver variable), as
`Compiler.AST.TypedCanonical` describes. The typed canonical AST wraps only a
definition's top expression, so each sub-expression is wrapped with
`Compiler.TypedCanonical.Build.toTypedExpr` as it is reached. A type missing
from a table, a local name not in scope, or a top-level name with no annotation
crashes the compiler; there is no error value.

Most nodes take the type at the expression itself. The exceptions follow from
where a correct type can be found:

  - A local variable is typed by its binding, not its use: each binder (a
    function argument, a destructured name, a `let` or `let rec` name) is added
    to the local type environment of `Compiler.LocalOpt.Typed.Names` before its
    scope is lowered.
  - A reference to a name in the current `Cycle` is a `VarCycle` typed with the
    name's annotation.
  - A `Debug` function carries its annotation's generic type.
  - `Char` and `String` literals carry the fixed `Char` and `String` types.
  - A kernel reference, a number literal and an operator reference carry the
    type checker's type at the use. The kernel type environment is passed
    through the lowering functions but never read.

Four operators written as operators (a `Can.Binop`) are rewritten rather than
called. `&&` and `||` become an `If` with a synthesized `Bool` literal, so
that the right operand is evaluated only when needed. `|>` and `<|` become the
application they denote, so that a rewritten pipe is never a call to
`Basics.apR` or `Basics.apL`; they are only a way to avoid brackets. The same
operators used as values, as in `List.foldl (&&)`, stay references to
`Basics.and`, `Basics.or`, `Basics.apR` and `Basics.apL`.

A function definition's patterns are lowered by `destructArgs` to one named
argument each and a list of `Destructor`s that bind the names inside the
patterns. `optimizePotentialTailCall` lowers a definition whose body calls
itself in tail position to a `TailDef` whose tail-position self-calls with a
full set of arguments are `TailCall`s.

@docs Cycle, Annotations
@docs optimize, optimizePotentialTailCall
@docs destructArgs

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.TypeVars as Vars
import Compiler.AST.TypedCanonical as TCan exposing (ExprTypes, ExprVars)
import Compiler.AST.TypedOptimized as TOpt
import Compiler.AST.Utils.Shader as Shader
import Compiler.AST.Utils.Type as Type
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.LocalOpt.Typed.Case as Case
import Compiler.LocalOpt.Typed.Names as Names
import Compiler.Reporting.Annotation as A
import Compiler.Type.KernelTypes as KernelTypes
import Compiler.TypedCanonical.Build as TCanBuild
import Data.Map
import Data.Set as EverySet exposing (EverySet)
import Dict exposing (Dict)
import Utils.Crash
import Utils.Main as Utils



-- ====== TYPES ======


{-| The names of a recursive group of top-level definitions whose references
are lowered to `VarCycle`.

The caller decides which names are in it. A reference to a top-level name in
the set becomes a `VarCycle`, and so does a local variable whose name is in it.

-}
type alias Cycle =
    EverySet String Name.Name


{-| The type annotations of the module's top-level definitions, by name.

Here it gives the type of a `VarCycle` reference.

-}
type alias Annotations =
    Dict Name (Can.Annotation Name)



-- ====== TYPE HELPERS ======


{-| Returns the curried function type taking `argTypes` in order and returning
`resultType`.
-}
buildFunctionType : List (Can.Type Name) -> Can.Type Name -> Can.Type Name
buildFunctionType argTypes resultType =
    List.foldr Can.tLambda resultType argTypes


{-| Returns what is left of `tipe` after removing `n` argument types from the
front. It stops early, returning what remains, if `tipe` stops being a function
type.
-}
peelFunctionType : Int -> Can.Type Name -> Can.Type Name
peelFunctionType n tipe =
    if n <= 0 then
        tipe

    else
        case tipe of
            Can.TLambda _ _ result ->
                peelFunctionType (n - 1) result

            _ ->
                tipe


{-| The type `Basics.Bool`.
-}
boolType : Can.Type Name
boolType =
    Can.TType ModuleName.basics "Bool" []


{-| Builds a `Bool` literal of type `Bool` with solver variable `tv`. It is
used for the literal branch of a rewritten `&&` or `||`, given the variable of
the whole operator expression.
-}
boolLit : A.Region -> Bool -> Maybe Vars.Variable -> TOpt.Expr Name
boolLit region value tv =
    TOpt.Bool region value { tipe = boolType, tvar = tv }


{-| Returns the lowered function `optFn` applied to one more argument, `optArg`:
the lowering of `|>` and `<|`.

When `optFn` is already a `Call`, the argument is appended to its arguments, so
`x |> f a b` becomes the single call `f a b x`, the shape `f a b x` written
directly would give. A one-argument call of the call `f a b` would instead
extend a partial application where a direct call is available. A function that
is not a `Call` gets a new one-argument `Call` at `region`; an extended call
keeps its own region. Either way the call's meta is `tipe` and `tv`, the type
and variable of the whole operator expression.

-}
applyOneMore : A.Region -> Can.Type Name -> Maybe Vars.Variable -> TOpt.Expr Name -> TOpt.Expr Name -> TOpt.Expr Name
applyOneMore region tipe tv optFn optArg =
    case optFn of
        TOpt.Call callRegion callee callArgs _ ->
            TOpt.Call callRegion callee (callArgs ++ [ optArg ]) { tipe = tipe, tvar = tv }

        _ ->
            TOpt.Call region optFn [ optArg ] { tipe = tipe, tvar = tv }


{-| Returns the solver variable of the first `VarLocal targetName` in an
expression that has one recorded, or `Nothing` if no occurrence has one.
Record fields are searched in field-name order.

It is how a local function definition gets a solver variable for its function
type: the search runs over a `let` body for uses of the bound name, or over a
recursive definition's own body for a reference to its own name. The variable
found is the one recorded at that occurrence, so for a polymorphic `let`
function it is the variable of that one use. Canonical names cannot shadow
one another, so every occurrence found refers to the same binding.

-}
findVarLocalTvar : Name -> ExprVars -> Can.Expr -> Maybe Vars.Variable
findVarLocalTvar targetName exprVars (A.At _ info) =
    case info.node of
        Can.VarLocal name ->
            if name == targetName then
                Array.get info.id exprVars |> Maybe.andThen identity

            else
                Nothing

        Can.VarTopLevel _ _ ->
            Nothing

        Can.VarKernel _ _ _ ->
            Nothing

        Can.VarForeign _ _ _ ->
            Nothing

        Can.VarCtor _ _ _ _ _ ->
            Nothing

        Can.VarDebug _ _ _ ->
            Nothing

        Can.VarOperator _ _ _ _ ->
            Nothing

        Can.Chr _ ->
            Nothing

        Can.Str _ ->
            Nothing

        Can.Int _ ->
            Nothing

        Can.Float _ ->
            Nothing

        Can.Accessor _ ->
            Nothing

        Can.Unit ->
            Nothing

        Can.Shader _ _ ->
            Nothing

        Can.Negate e ->
            findVarLocalTvar targetName exprVars e

        Can.Lambda _ body ->
            findVarLocalTvar targetName exprVars body

        Can.Access recordExpr _ ->
            findVarLocalTvar targetName exprVars recordExpr

        Can.Binop _ _ _ _ left right ->
            firstJust2 targetName exprVars left right

        Can.Call func args ->
            case findVarLocalTvar targetName exprVars func of
                Just v ->
                    Just v

                Nothing ->
                    firstJustList targetName exprVars args

        Can.List entries ->
            firstJustList targetName exprVars entries

        Can.Tuple a b rest ->
            case findVarLocalTvar targetName exprVars a of
                Just v ->
                    Just v

                Nothing ->
                    case findVarLocalTvar targetName exprVars b of
                        Just v ->
                            Just v

                        Nothing ->
                            firstJustList targetName exprVars rest

        Can.Record fields ->
            firstJustList targetName exprVars (Data.Map.values fields)

        Can.Update recordExpr fieldUpdates ->
            case findVarLocalTvar targetName exprVars recordExpr of
                Just v ->
                    Just v

                Nothing ->
                    firstJustList targetName
                        exprVars
                        (List.map (\(Can.FieldUpdate _ e) -> e) (Data.Map.values fieldUpdates))

        Can.If branches final ->
            let
                tryBranch ( cond, branchExpr ) =
                    case findVarLocalTvar targetName exprVars cond of
                        Just v ->
                            Just v

                        Nothing ->
                            findVarLocalTvar targetName exprVars branchExpr
            in
            case firstJustMap tryBranch branches of
                Just v ->
                    Just v

                Nothing ->
                    findVarLocalTvar targetName exprVars final

        Can.Case scrutinee branches ->
            case findVarLocalTvar targetName exprVars scrutinee of
                Just v ->
                    Just v

                Nothing ->
                    firstJustMap
                        (\(Can.CaseBranch _ branchExpr) ->
                            findVarLocalTvar targetName exprVars branchExpr
                        )
                        branches

        -- Let expressions (no shadow concern — canonicalization forbids shadowing)
        Can.Let def body ->
            case findVarLocalTvarInDef targetName exprVars def of
                Just v ->
                    Just v

                Nothing ->
                    findVarLocalTvar targetName exprVars body

        Can.LetRec defs body ->
            case firstJustMap (findVarLocalTvarInDef targetName exprVars) defs of
                Just v ->
                    Just v

                Nothing ->
                    findVarLocalTvar targetName exprVars body

        Can.LetDestruct _ boundExpr body ->
            firstJust2 targetName exprVars boundExpr body


{-| Returns `findVarLocalTvar` over the body of a `let` definition.
-}
findVarLocalTvarInDef : Name -> ExprVars -> Can.Def -> Maybe Vars.Variable
findVarLocalTvarInDef targetName exprVars def =
    case def of
        Can.Def _ _ body ->
            findVarLocalTvar targetName exprVars body

        Can.TypedDef _ _ _ body _ ->
            findVarLocalTvar targetName exprVars body


{-| Returns the variable `findVarLocalTvar` finds in `a`, or else in `b`.
-}
firstJust2 : Name -> ExprVars -> Can.Expr -> Can.Expr -> Maybe Vars.Variable
firstJust2 targetName exprVars a b =
    case findVarLocalTvar targetName exprVars a of
        Just v ->
            Just v

        Nothing ->
            findVarLocalTvar targetName exprVars b


{-| Returns the variable `findVarLocalTvar` finds in the first expression of
`exprs` that has one.
-}
firstJustList : Name -> ExprVars -> List Can.Expr -> Maybe Vars.Variable
firstJustList targetName exprVars exprs =
    case exprs of
        [] ->
            Nothing

        e :: rest ->
            case findVarLocalTvar targetName exprVars e of
                Just v ->
                    Just v

                Nothing ->
                    firstJustList targetName exprVars rest


{-| Returns the first `Just` that `f` gives for an element of `list`, trying
them in order.
-}
firstJustMap : (a -> Maybe Vars.Variable) -> List a -> Maybe Vars.Variable
firstJustMap f list =
    case list of
        [] ->
            Nothing

        x :: rest ->
            case f x of
                Just v ->
                    Just v

                Nothing ->
                    firstJustMap f rest



-- ====== OPTIMIZE ======


{-| Lowers a typed canonical expression into a typed optimized expression,
recording its dependencies, field uses and new names in the tracker.

The result's own meta is the type and solver variable on the typed canonical
node, except where the module docstring says a node is typed otherwise.
`exprTypes` and `exprVars` type the sub-expressions. `home` is the module of a
`VarCycle` made from a local variable whose name is in `cycle`.

-}
optimize : KernelTypes.KernelTypeEnv -> Annotations -> ExprTypes -> ExprVars -> ModuleName.Canonical -> Cycle -> TCan.Expr -> Names.Tracker (TOpt.Expr Name)
optimize kernelEnv annotations exprTypes exprVars home cycle (A.At region texpr) =
    case texpr of
        TCan.TypedExpr { expr, tipe, tvar } ->
            optimizeExpr kernelEnv annotations exprTypes exprVars home cycle region tipe tvar expr


{-| Lowers the canonical expression `expr`, whose own type and solver variable
are `tipe` and `tvar`; `optimize` after unwrapping.
-}
optimizeExpr : KernelTypes.KernelTypeEnv -> Annotations -> ExprTypes -> ExprVars -> ModuleName.Canonical -> Cycle -> A.Region -> Can.Type Name -> Maybe Vars.Variable -> Can.Expr_ -> Names.Tracker (TOpt.Expr Name)
optimizeExpr kernelEnv annotations exprTypes exprVars home cycle region tipe tvar expr =
    case expr of
        Can.VarLocal name ->
            if EverySet.member identity name cycle then
                let
                    defType =
                        lookupAnnotationType name annotations
                in
                Names.pure (TOpt.VarCycle region home name { tipe = defType, tvar = tvar })

            else
                Names.lookupLocalType name
                    |> Names.map (\localType -> TOpt.TrackedVarLocal region name { tipe = localType, tvar = tvar })
                    |> catchMissing

        Can.VarTopLevel varHome name ->
            let
                defType =
                    lookupAnnotationType name annotations
            in
            if EverySet.member identity name cycle then
                Names.pure (TOpt.VarCycle region varHome name { tipe = defType, tvar = tvar })

            else
                Names.registerGlobal region varHome name tipe tvar

        Can.VarKernel kernelPrefix kernelHome name ->
            -- The use-site type, not one stored per kernel: a polymorphic kernel
            -- reached through several aliases has a different type at each.
            Names.registerKernel kernelHome (TOpt.VarKernel region kernelPrefix kernelHome name { tipe = tipe, tvar = tvar })

        Can.VarForeign foreignHome name _ ->
            Names.registerGlobal region foreignHome name tipe tvar

        Can.VarCtor opts ctorHome name index _ ->
            Names.registerCtor region ctorHome (A.At region name) index opts tipe tvar

        Can.VarDebug debugHome name (Can.Forall _ debugType) ->
            -- The annotation's generic type, not the type at this use.
            Names.registerDebug name debugHome region debugType tvar

        Can.VarOperator _ opHome name _ ->
            -- Typed at its use site like any other global reference, not with
            -- the operator's scheme: the scheme's variables (`number` for `*`)
            -- would be read as the enclosing definition's variables of the
            -- same name downstream.
            Names.registerGlobal region opHome name tipe tvar

        Can.Chr chr ->
            Names.registerKernel Name.utils (TOpt.Chr region chr { tipe = Can.TType ModuleName.char "Char" [], tvar = tvar })

        Can.Str str ->
            Names.pure (TOpt.Str region str { tipe = Can.TType ModuleName.string "String" [], tvar = tvar })

        Can.Int int ->
            Names.pure (TOpt.Int region int { tipe = tipe, tvar = tvar })

        Can.Float float ->
            Names.pure (TOpt.Float region float { tipe = tipe, tvar = tvar })

        Can.List entries ->
            Names.traverse (optimize kernelEnv annotations exprTypes exprVars home cycle << TCanBuild.toTypedExpr exprTypes exprVars) entries
                |> Names.andThen (\optEntries -> Names.registerKernel Name.list (TOpt.List region optEntries { tipe = tipe, tvar = tvar }))

        Can.Negate subExpr ->
            let
                negateType =
                    buildFunctionType [ tipe ] tipe
            in
            Names.registerGlobal region ModuleName.basics Name.negate negateType Nothing
                |> Names.andThen
                    (\func ->
                        optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars subExpr)
                            |> Names.map (\optSub -> TOpt.Call region func [ optSub ] { tipe = tipe, tvar = tvar })
                    )

        -- `&&`, `||`, `|>` and `<|` are rewritten as the module docstring
        -- describes. Each specialization of `apR` or `apL` would be a copy of
        -- `\x f -> f x` or `\f x -> f x`; the JavaScript backend does the
        -- same rewrite in its code generator.
        Can.Binop _ binopHome name _ left right ->
            let
                optimizeArg =
                    optimize kernelEnv annotations exprTypes exprVars home cycle << TCanBuild.toTypedExpr exprTypes exprVars

                lowerShortCircuit buildBranch =
                    optimizeArg left
                        |> Names.andThen
                            (\optLeft ->
                                optimizeArg right
                                    |> Names.map
                                        (\optRight ->
                                            let
                                                ( cond, thenE, elseE ) =
                                                    buildBranch optLeft optRight
                                            in
                                            TOpt.If [ ( cond, thenE ) ] elseE { tipe = tipe, tvar = tvar }
                                        )
                            )
            in
            if binopHome == ModuleName.basics && name == "and" then
                -- a && b  ==>  if a then b else False
                lowerShortCircuit
                    (\l r -> ( l, r, boolLit region False tvar ))

            else if binopHome == ModuleName.basics && name == "or" then
                -- a || b  ==>  if a then True else b
                lowerShortCircuit
                    (\l r -> ( l, boolLit region True tvar, r ))

            else if binopHome == ModuleName.basics && (name == "apR" || name == "apL") then
                -- a |> f  ==>  f a        f <| a  ==>  f a
                let
                    ( fnSide, argSide ) =
                        if name == "apR" then
                            ( right, left )

                        else
                            ( left, right )
                in
                optimizeArg fnSide
                    |> Names.andThen
                        (\optFn ->
                            optimizeArg argSide
                                |> Names.map (applyOneMore region tipe tvar optFn)
                        )

            else
                -- The operator reference is typed at this use, from the type
                -- checker's types for the two operand occurrences and the
                -- result type, as every other global reference is; its scheme
                -- (`number -> number -> number` for `*`) names variables that
                -- downstream passes would read as the enclosing definition's
                -- variables of the same name. The operand types come from the
                -- typed canonical nodes, not the optimized operands: a
                -- let-bound polymorphic local's optimized reference carries
                -- the local's generalized type, not its type at this use.
                let
                    useType =
                        Can.tLambda (typedExprType left) (Can.tLambda (typedExprType right) tipe)

                    typedExprType operand =
                        case TCanBuild.toTypedExpr exprTypes exprVars operand of
                            A.At _ (TCan.TypedExpr typed) ->
                                typed.tipe
                in
                optimizeArg left
                    |> Names.andThen
                        (\optLeft ->
                            optimizeArg right
                                |> Names.andThen
                                    (\optRight ->
                                        Names.registerGlobal region binopHome name useType Nothing
                                            |> Names.map
                                                (\optFunc ->
                                                    TOpt.Call region optFunc [ optLeft, optRight ] { tipe = tipe, tvar = tvar }
                                                )
                                    )
                        )

        Can.Lambda args body ->
            destructArgs exprTypes exprVars args
                |> Names.andThen
                    (\( argNamesWithTypes, destructors ) ->
                        let
                            argBindings =
                                List.map (\( A.At _ n, t ) -> ( n, t )) argNamesWithTypes

                            destructorBindings =
                                List.map (\(TOpt.Destructor n _ meta) -> ( n, meta.tipe )) destructors

                            allBindings =
                                argBindings ++ destructorBindings

                            bodyType =
                                peelFunctionType (List.length args) tipe
                        in
                        Names.withVarTypes allBindings
                            (optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars body))
                            |> Names.map
                                (\obody ->
                                    let
                                        wrappedBody =
                                            List.foldr (wrapDestruct bodyType) obody destructors
                                    in
                                    TOpt.TrackedFunction Nothing argNamesWithTypes wrappedBody { tipe = tipe, tvar = tvar }
                                )
                    )

        Can.Call func args ->
            let
                optimizeArg =
                    optimize kernelEnv annotations exprTypes exprVars home cycle << TCanBuild.toTypedExpr exprTypes exprVars
            in
            optimizeArg func
                |> Names.andThen
                    (\optFunc ->
                        Names.traverse optimizeArg args
                            |> Names.map (\optArgs -> TOpt.Call region optFunc optArgs { tipe = tipe, tvar = tvar })
                    )

        Can.If branches final ->
            let
                optimizeBranch : ( Can.Expr, Can.Expr ) -> Names.Tracker ( TOpt.Expr Name, TOpt.Expr Name )
                optimizeBranch ( condition, thenExpr ) =
                    let
                        optCond =
                            optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars condition)

                        optThen =
                            optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars thenExpr)
                    in
                    optCond
                        |> Names.andThen (\c -> optThen |> Names.map (\t -> ( c, t )))
            in
            Names.traverse optimizeBranch branches
                |> Names.andThen
                    (\optBranches ->
                        optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars final)
                            |> Names.map (\optFinal -> TOpt.If optBranches optFinal { tipe = tipe, tvar = tvar })
                    )

        Can.Let def body ->
            let
                ( defName, defType ) =
                    getDefNameAndType exprTypes def

                defNodeTvar =
                    findVarLocalTvar defName exprVars body
            in
            Names.withVarTypes [ ( defName, defType ) ]
                (optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars body))
                |> Names.andThen (optimizeDef kernelEnv annotations exprTypes exprVars home cycle def tipe defNodeTvar)

        Can.LetRec defs body ->
            -- Every name of the group is in scope in every definition and the body.
            let
                defBindings =
                    List.map (getDefNameAndType exprTypes) defs
            in
            case defs of
                [ def ] ->
                    Names.withVarTypes defBindings
                        (optimizePotentialTailCallDef kernelEnv annotations exprTypes exprVars home cycle def)
                        |> Names.andThen
                            (\tailCallDef ->
                                Names.withVarTypes defBindings
                                    (optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars body))
                                    |> Names.map (\obody -> TOpt.Let tailCallDef obody { tipe = tipe, tvar = tvar })
                            )

                _ ->
                    Names.withVarTypes defBindings
                        (List.foldl
                            (\def bod ->
                                Names.andThen (optimizeDef kernelEnv annotations exprTypes exprVars home cycle def tipe Nothing) bod
                            )
                            (optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars body))
                            defs
                        )

        Can.LetDestruct pattern boundExpr body ->
            destruct exprTypes exprVars pattern
                |> Names.andThen
                    (\( ( A.At nameRegion name, patternType ), destructs ) ->
                        optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars boundExpr)
                            |> Names.andThen
                                (\oBoundExpr ->
                                    let
                                        destructorBindings =
                                            List.map (\(TOpt.Destructor n _ meta) -> ( n, meta.tipe )) destructs

                                        allBindings =
                                            ( name, patternType ) :: destructorBindings
                                    in
                                    Names.withVarTypes allBindings
                                        (optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars body))
                                        |> Names.map
                                            (\obody ->
                                                let
                                                    boundExprType =
                                                        TOpt.typeOf oBoundExpr
                                                in
                                                TOpt.Let
                                                    (TOpt.Def nameRegion name oBoundExpr boundExprType)
                                                    (List.foldr (wrapDestruct tipe) obody destructs)
                                                    { tipe = tipe, tvar = tvar }
                                            )
                                )
                    )

        Can.Case scrutinee branches ->
            let
                optimizeBranch : Name -> Can.CaseBranch -> Names.Tracker ( Can.Pattern, TOpt.Expr Name )
                optimizeBranch root (Can.CaseBranch pattern branch) =
                    destructCase exprTypes exprVars root pattern
                        |> Names.andThen
                            (\destructors ->
                                let
                                    destructorBindings =
                                        List.map (\(TOpt.Destructor n _ meta) -> ( n, meta.tipe )) destructors
                                in
                                Names.withVarTypes destructorBindings
                                    (optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars branch))
                                    |> Names.map
                                        (\obranch ->
                                            ( pattern, List.foldr (wrapDestruct tipe) obranch destructors )
                                        )
                            )
            in
            Names.generate
                |> Names.andThen
                    (\temp ->
                        optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars scrutinee)
                            |> Names.andThen
                                (\optScrutinee ->
                                    case optScrutinee of
                                        TOpt.VarLocal root _ ->
                                            Names.traverse (optimizeBranch root) branches
                                                |> Names.map (\optBranches -> Case.optimize temp root optBranches tipe tvar)

                                        TOpt.TrackedVarLocal _ root _ ->
                                            Names.traverse (optimizeBranch root) branches
                                                |> Names.map (\optBranches -> Case.optimize temp root optBranches tipe tvar)

                                        _ ->
                                            Names.traverse (optimizeBranch temp) branches
                                                |> Names.map
                                                    (\optBranches ->
                                                        let
                                                            scrutineeType =
                                                                TOpt.typeOf optScrutinee
                                                        in
                                                        TOpt.Let
                                                            (TOpt.Def region temp optScrutinee scrutineeType)
                                                            (Case.optimize temp temp optBranches tipe tvar)
                                                            { tipe = tipe, tvar = tvar }
                                                    )
                                )
                    )

        Can.Accessor field ->
            Names.registerField field (TOpt.Accessor region field { tipe = tipe, tvar = tvar })

        Can.Access recordExpr (A.At _ field) ->
            optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars recordExpr)
                |> Names.andThen
                    (\optRecord ->
                        Names.registerField field (TOpt.Access optRecord region field { tipe = tipe, tvar = tvar })
                    )

        Can.Update recordExpr fieldUpdates ->
            let
                optimizeFieldUpdate : ( A.Located Name, Can.FieldUpdate ) -> Names.Tracker ( A.Located Name, TOpt.Expr Name )
                optimizeFieldUpdate ( locName, Can.FieldUpdate _ fieldExpr ) =
                    optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars fieldExpr)
                        |> Names.map (\optExpr -> ( locName, optExpr ))

                fieldUpdateList =
                    Data.Map.toList fieldUpdates
            in
            optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars recordExpr)
                |> Names.andThen
                    (\optRecord ->
                        Names.traverse optimizeFieldUpdate fieldUpdateList
                            |> Names.andThen
                                (\optUpdates ->
                                    let
                                        optUpdatesDict =
                                            Data.Map.fromList A.toValue optUpdates
                                    in
                                    Names.registerFieldDict (Utils.dictMapKeys A.toValue fieldUpdates)
                                        (TOpt.Update region optRecord optUpdatesDict { tipe = tipe, tvar = tvar })
                                )
                    )

        Can.Record fields ->
            let
                optimizeField : ( A.Located Name, Can.Expr ) -> Names.Tracker ( A.Located Name, TOpt.Expr Name )
                optimizeField ( locName, fieldExpr ) =
                    optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars fieldExpr)
                        |> Names.map (\optExpr -> ( locName, optExpr ))

                fieldList : List ( A.Located Name, Can.Expr )
                fieldList =
                    Data.Map.toList fields
            in
            Names.traverse optimizeField fieldList
                |> Names.andThen
                    (\optFields ->
                        let
                            optFieldsDict =
                                Data.Map.fromList A.toValue optFields
                        in
                        Names.registerFieldDict (Utils.dictMapKeys A.toValue fields) (TOpt.TrackedRecord region optFieldsDict { tipe = tipe, tvar = tvar })
                    )

        Can.Unit ->
            Names.registerKernel Name.utils (TOpt.Unit { tipe = Can.TUnit, tvar = tvar })

        Can.Tuple a b cs ->
            let
                optimizeArg =
                    optimize kernelEnv annotations exprTypes exprVars home cycle << TCanBuild.toTypedExpr exprTypes exprVars
            in
            optimizeArg a
                |> Names.andThen
                    (\optA ->
                        optimizeArg b
                            |> Names.andThen
                                (\optB ->
                                    Names.traverse optimizeArg cs
                                        |> Names.andThen
                                            (\optCs ->
                                                Names.registerKernel Name.utils (TOpt.Tuple region optA optB optCs { tipe = tipe, tvar = tvar })
                                            )
                                )
                    )

        Can.Shader src (Shader.Types attributes uniforms _) ->
            Names.pure (TOpt.Shader src (EverySet.fromList identity (Data.Map.keys attributes)) (EverySet.fromList identity (Data.Map.keys uniforms)) { tipe = tipe, tvar = tvar })


{-| Returns `tracker` unchanged. A missing local type is not caught: the
lookup it wraps crashes instead.
-}
catchMissing : Names.Tracker a -> Names.Tracker a
catchMissing tracker =
    tracker


{-| Returns the type in `name`'s annotation, without its quantifier. It
crashes if `name` has no annotation.
-}
lookupAnnotationType : Name -> Annotations -> Can.Type Name
lookupAnnotationType name annotations =
    case Dict.get name annotations of
        Just (Can.Forall _ tipe) ->
            tipe

        Nothing ->
            Utils.Crash.crash "Expression.lookupAnnotationType: no annotation"



-- ====== TAIL CALL OPTIMIZATION ======


{-| Lowers an expression in tail position of the definition `rootName`, whose
parameters are `argNames` and whose body type is `resultType`.

A call in tail position whose function is the name `rootName` and whose
argument count equals the parameter count becomes a `TailCall` pairing each
parameter with its new value, typed `resultType`. Tail position passes through
`if` branches, `case` branches and the bodies of `let`, `let rec` and `let`
destructuring; every other expression, and every non-tail part of these, is
lowered by `optimize`.

-}
optimizeTail :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> ExprVars
    -> ModuleName.Canonical
    -> Cycle
    -> Name
    -> List ( A.Located Name, Can.Type Name )
    -> Can.Type Name
    -> TCan.Expr
    -> Names.Tracker (TOpt.Expr Name)
optimizeTail kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType (A.At region texpr) =
    case texpr of
        TCan.TypedExpr { expr, tipe, tvar } ->
            optimizeTailExpr kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType region tipe tvar expr


{-| Lowers the canonical expression `expr` in tail position; `optimizeTail` after
unwrapping.
-}
optimizeTailExpr :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> ExprVars
    -> ModuleName.Canonical
    -> Cycle
    -> Name
    -> List ( A.Located Name, Can.Type Name )
    -> Can.Type Name
    -> A.Region
    -> Can.Type Name
    -> Maybe Vars.Variable
    -> Can.Expr_
    -> Names.Tracker (TOpt.Expr Name)
optimizeTailExpr kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType region tipe tvar expr =
    case expr of
        Can.Call func callArgs ->
            let
                optimizeArg =
                    optimize kernelEnv annotations exprTypes exprVars home cycle << TCanBuild.toTypedExpr exprTypes exprVars
            in
            Names.traverse optimizeArg callArgs
                |> Names.andThen
                    (\oargs ->
                        let
                            isMatchingName =
                                case (A.toValue func).node of
                                    Can.VarLocal n ->
                                        rootName == n

                                    Can.VarTopLevel _ n ->
                                        rootName == n

                                    _ ->
                                        False
                        in
                        if isMatchingName then
                            case Index.indexedZipWith (\_ ( locName, _ ) arg -> ( A.toValue locName, arg )) argNames oargs of
                                Index.LengthMatch pairs ->
                                    Names.pure (TOpt.TailCall rootName pairs { tipe = resultType, tvar = tvar })

                                Index.LengthMismatch _ _ ->
                                    optimizeArg func
                                        |> Names.map (\ofunc -> TOpt.Call region ofunc oargs { tipe = tipe, tvar = tvar })

                        else
                            optimizeArg func
                                |> Names.map (\ofunc -> TOpt.Call region ofunc oargs { tipe = tipe, tvar = tvar })
                    )

        Can.If branches final ->
            let
                optimizeBranch ( condition, branch ) =
                    optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars condition)
                        |> Names.andThen
                            (\optCond ->
                                optimizeTail kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType (TCanBuild.toTypedExpr exprTypes exprVars branch)
                                    |> Names.map (\optBranch -> ( optCond, optBranch ))
                            )
            in
            Names.traverse optimizeBranch branches
                |> Names.andThen
                    (\optBranches ->
                        optimizeTail kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType (TCanBuild.toTypedExpr exprTypes exprVars final)
                            |> Names.map (\optFinal -> TOpt.If optBranches optFinal { tipe = tipe, tvar = tvar })
                    )

        Can.Let def body ->
            let
                ( defName, defType ) =
                    getDefNameAndType exprTypes def

                defNodeTvar =
                    findVarLocalTvar defName exprVars body
            in
            Names.withVarTypes [ ( defName, defType ) ]
                (optimizeTail kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType (TCanBuild.toTypedExpr exprTypes exprVars body))
                |> Names.andThen (optimizeDef kernelEnv annotations exprTypes exprVars home cycle def tipe defNodeTvar)

        Can.LetRec defs body ->
            -- Every name of the group is in scope in every definition and the body.
            let
                defBindings =
                    List.map (getDefNameAndType exprTypes) defs
            in
            case defs of
                [ def ] ->
                    Names.withVarTypes defBindings
                        (optimizePotentialTailCallDef kernelEnv annotations exprTypes exprVars home cycle def)
                        |> Names.andThen
                            (\tailCallDef ->
                                Names.withVarTypes defBindings
                                    (optimizeTail kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType (TCanBuild.toTypedExpr exprTypes exprVars body))
                                    |> Names.map (\obody -> TOpt.Let tailCallDef obody { tipe = tipe, tvar = tvar })
                            )

                _ ->
                    Names.withVarTypes defBindings
                        (List.foldl
                            (\def bod ->
                                Names.andThen (optimizeDef kernelEnv annotations exprTypes exprVars home cycle def tipe Nothing) bod
                            )
                            (optimizeTail kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType (TCanBuild.toTypedExpr exprTypes exprVars body))
                            defs
                        )

        Can.LetDestruct pattern boundExpr body ->
            destruct exprTypes exprVars pattern
                |> Names.andThen
                    (\( ( A.At nameRegion name, patternType ), destructs ) ->
                        optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars boundExpr)
                            |> Names.andThen
                                (\oBoundExpr ->
                                    let
                                        destructorBindings =
                                            List.map (\(TOpt.Destructor n _ meta) -> ( n, meta.tipe )) destructs

                                        allBindings =
                                            ( name, patternType ) :: destructorBindings
                                    in
                                    Names.withVarTypes allBindings
                                        (optimizeTail kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType (TCanBuild.toTypedExpr exprTypes exprVars body))
                                        |> Names.map
                                            (\obody ->
                                                let
                                                    boundExprType =
                                                        TOpt.typeOf oBoundExpr
                                                in
                                                TOpt.Let
                                                    (TOpt.Def nameRegion name oBoundExpr boundExprType)
                                                    (List.foldr (wrapDestruct tipe) obody destructs)
                                                    { tipe = tipe, tvar = tvar }
                                            )
                                )
                    )

        Can.Case scrutinee branches ->
            let
                optimizeBranch root (Can.CaseBranch pattern branch) =
                    destructCase exprTypes exprVars root pattern
                        |> Names.andThen
                            (\destructors ->
                                let
                                    destructorBindings =
                                        List.map (\(TOpt.Destructor n _ meta) -> ( n, meta.tipe )) destructors
                                in
                                Names.withVarTypes destructorBindings
                                    (optimizeTail kernelEnv annotations exprTypes exprVars home cycle rootName argNames resultType (TCanBuild.toTypedExpr exprTypes exprVars branch))
                                    |> Names.map
                                        (\obranch ->
                                            ( pattern, List.foldr (wrapDestruct tipe) obranch destructors )
                                        )
                            )
            in
            Names.generate
                |> Names.andThen
                    (\temp ->
                        optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars scrutinee)
                            |> Names.andThen
                                (\optScrutinee ->
                                    case optScrutinee of
                                        TOpt.VarLocal root _ ->
                                            Names.traverse (optimizeBranch root) branches
                                                |> Names.map (\optBranches -> Case.optimize temp root optBranches tipe tvar)

                                        TOpt.TrackedVarLocal _ root _ ->
                                            Names.traverse (optimizeBranch root) branches
                                                |> Names.map (\optBranches -> Case.optimize temp root optBranches tipe tvar)

                                        _ ->
                                            Names.traverse (optimizeBranch temp) branches
                                                |> Names.map
                                                    (\optBranches ->
                                                        let
                                                            scrutineeType =
                                                                TOpt.typeOf optScrutinee
                                                        in
                                                        TOpt.Let
                                                            (TOpt.Def region temp optScrutinee scrutineeType)
                                                            (Case.optimize temp temp optBranches tipe tvar)
                                                            { tipe = tipe, tvar = tvar }
                                                    )
                                )
                    )

        _ ->
            optimizeExpr kernelEnv annotations exprTypes exprVars home cycle region tipe tvar expr



-- ====== LET DEFINITIONS ======


{-| Returns the name a `let` definition binds and the type to put in scope for
it: the function type from its argument types to its body type.

An annotated definition takes these from its annotation; an unannotated one from
the types of its argument patterns and body in `exprTypes`, crashing if one is
missing.

-}
getDefNameAndType : ExprTypes -> Can.Def -> ( Name, Can.Type Name )
getDefNameAndType exprTypes def =
    case def of
        Can.Def (A.At _ name) args (A.At _ bodyInfo) ->
            let
                argTypes =
                    List.map
                        (\(A.At _ patInfo) ->
                            case Array.get patInfo.id exprTypes |> Maybe.andThen identity of
                                Just t ->
                                    t

                                Nothing ->
                                    Utils.Crash.crash "Expression.extractDefNameAndType: arg type"
                        )
                        args

                bodyType =
                    case Array.get bodyInfo.id exprTypes |> Maybe.andThen identity of
                        Just t ->
                            t

                        Nothing ->
                            Utils.Crash.crash "Expression.extractDefNameAndType: body type"
            in
            ( name, buildFunctionType argTypes bodyType )

        Can.TypedDef (A.At _ name) _ typedArgs _ resultType ->
            let
                argTypes =
                    List.map Tuple.second typedArgs
            in
            ( name, buildFunctionType argTypes resultType )


{-| Returns the already lowered `body` inside a `Let` binding the lowered
definition `def`, typed `resultType`.

`defNodeTvar`, when given, is the solver variable of a function definition.

-}
optimizeDef :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> ExprVars
    -> ModuleName.Canonical
    -> Cycle
    -> Can.Def
    -> Can.Type Name
    -> Maybe Vars.Variable
    -> TOpt.Expr Name
    -> Names.Tracker (TOpt.Expr Name)
optimizeDef kernelEnv annotations exprTypes exprVars home cycle def resultType defNodeTvar body =
    case def of
        Can.Def (A.At region name) args expr ->
            optimizeDefHelp kernelEnv annotations exprTypes exprVars home cycle region name args expr resultType defNodeTvar body

        Can.TypedDef (A.At region name) _ typedArgs expr _ ->
            optimizeDefHelp kernelEnv annotations exprTypes exprVars home cycle region name (List.map Tuple.first typedArgs) expr resultType defNodeTvar body


{-| Builds the `Let` for `optimizeDef` from a definition's parts.

A definition with no arguments binds its lowered expression. One with arguments
binds a `TrackedFunction` whose type is built from the argument types and the
lowered body's type. The function's solver variable is `defNodeTvar` if given,
else that of a reference to its own name found in `expr`, else `expr`'s own
variable. The `Let` takes the variable of `body`.

-}
optimizeDefHelp :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> ExprVars
    -> ModuleName.Canonical
    -> Cycle
    -> A.Region
    -> Name
    -> List Can.Pattern
    -> Can.Expr
    -> Can.Type Name
    -> Maybe Vars.Variable
    -> TOpt.Expr Name
    -> Names.Tracker (TOpt.Expr Name)
optimizeDefHelp kernelEnv annotations exprTypes exprVars home cycle region name args expr resultType defNodeTvar body =
    let
        defBodyTvar : Maybe Vars.Variable
        defBodyTvar =
            Array.get (A.toValue expr).id exprVars |> Maybe.andThen identity

        funcTvar : Maybe Vars.Variable
        funcTvar =
            case defNodeTvar of
                Just _ ->
                    defNodeTvar

                Nothing ->
                    case findVarLocalTvar name exprVars expr of
                        Just v ->
                            Just v

                        Nothing ->
                            defBodyTvar

        letTvar : Maybe Vars.Variable
        letTvar =
            TOpt.tvarOf body
    in
    case args of
        [] ->
            optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars expr)
                |> Names.map
                    (\oexpr ->
                        let
                            exprType =
                                TOpt.typeOf oexpr
                        in
                        TOpt.Let (TOpt.Def region name oexpr exprType) body { tipe = resultType, tvar = letTvar }
                    )

        _ ->
            destructArgs exprTypes exprVars args
                |> Names.andThen
                    (\( argNamesWithTypes, destructors ) ->
                        let
                            argBindings =
                                List.map (\( A.At _ n, t ) -> ( n, t )) argNamesWithTypes

                            destructorBindings =
                                List.map (\(TOpt.Destructor n _ meta) -> ( n, meta.tipe )) destructors

                            allBindings =
                                argBindings ++ destructorBindings
                        in
                        Names.withVarTypes allBindings
                            (optimize kernelEnv annotations exprTypes exprVars home cycle (TCanBuild.toTypedExpr exprTypes exprVars expr))
                            |> Names.map
                                (\oexpr ->
                                    let
                                        bodyType =
                                            TOpt.typeOf oexpr

                                        argTypes =
                                            List.map Tuple.second argNamesWithTypes

                                        funcType =
                                            buildFunctionType argTypes bodyType

                                        wrappedBody =
                                            List.foldr (wrapDestruct bodyType) oexpr destructors

                                        ofunc =
                                            TOpt.TrackedFunction Nothing argNamesWithTypes wrappedBody { tipe = funcType, tvar = funcTvar }
                                    in
                                    TOpt.Let (TOpt.Def region name ofunc funcType) body { tipe = resultType, tvar = letTvar }
                                )
                    )


{-| Lowers the one definition of a `let rec` with `optimizePotentialTailCall`.

For an unannotated definition the type passed on is the function type
`getDefNameAndType` builds. For an annotated one it is the annotation's result
type as the `TypedDef` holds it, after the argument types. Its solver variable
is that of a reference to its own name found in its body, else the body's
variable.

-}
optimizePotentialTailCallDef :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> ExprVars
    -> ModuleName.Canonical
    -> Cycle
    -> Can.Def
    -> Names.Tracker (TOpt.Def Name)
optimizePotentialTailCallDef kernelEnv annotations exprTypes exprVars home cycle def =
    case def of
        Can.Def (A.At region name) args body ->
            let
                ( _, defType ) =
                    getDefNameAndType exprTypes def

                localAnnotationVars =
                    case findVarLocalTvar name exprVars body of
                        Just v ->
                            Dict.singleton name v

                        Nothing ->
                            Dict.empty
            in
            optimizePotentialTailCall kernelEnv annotations exprTypes exprVars home cycle region name args (TCanBuild.toTypedExpr exprTypes exprVars body) defType localAnnotationVars

        Can.TypedDef (A.At region name) _ typedArgs body _ ->
            let
                ( _, defType ) =
                    getDefNameAndType exprTypes def

                localAnnotationVars =
                    case findVarLocalTvar name exprVars body of
                        Just v ->
                            Dict.singleton name v

                        Nothing ->
                            Dict.empty
            in
            optimizePotentialTailCall kernelEnv annotations exprTypes exprVars home cycle region name (List.map Tuple.first typedArgs) (TCanBuild.toTypedExpr exprTypes exprVars body) defType localAnnotationVars



-- ====== DEFINITIONS ======


{-| Lowers the definition `name` with parameter patterns `args`, body `body` and
type `defType`.

If the lowered body contains a `TailCall` to `name` in tail position, the
result is a `TailDef`; otherwise it is a `Def` of a `TrackedFunction`. Either
way the stored type is `defType` as given, and its `TailCall`s and
destructuring wrappers are typed `defType` with one argument type removed per
pattern. The solver variable is `name`'s entry in `annotationVars`, or else the
body's.

-}
optimizePotentialTailCall :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> ExprVars
    -> ModuleName.Canonical
    -> Cycle
    -> A.Region
    -> Name
    -> List Can.Pattern
    -> TCan.Expr
    -> Can.Type Name
    -> Dict Name Vars.Variable
    -> Names.Tracker (TOpt.Def Name)
optimizePotentialTailCall kernelEnv annotations exprTypes exprVars home cycle region name args body defType annotationVars =
    let
        bodyTvar : Maybe Vars.Variable
        bodyTvar =
            case A.toValue body of
                TCan.TypedExpr info ->
                    info.tvar

        nodeTvar : Maybe Vars.Variable
        nodeTvar =
            case Dict.get name annotationVars of
                Just var ->
                    Just var

                Nothing ->
                    bodyTvar
    in
    destructArgs exprTypes exprVars args
        |> Names.andThen
            (\( argNamesWithTypes, destructors ) ->
                let
                    argBindings =
                        List.map (\( A.At _ n, t ) -> ( n, t )) argNamesWithTypes

                    destructorBindings =
                        List.map (\(TOpt.Destructor n _ meta) -> ( n, meta.tipe )) destructors

                    allBindings =
                        argBindings ++ destructorBindings

                    bodyType =
                        peelFunctionType (List.length args) defType
                in
                Names.withVarTypes allBindings
                    (optimizeTail kernelEnv annotations exprTypes exprVars home cycle name argNamesWithTypes bodyType body)
                    |> Names.map
                        (\obody ->
                            let
                                wrappedBody =
                                    List.foldr (wrapDestruct bodyType) obody destructors
                            in
                            if hasTailCall name obody then
                                TOpt.TailDef region name argNamesWithTypes wrappedBody defType nodeTvar

                            else
                                TOpt.Def region name (TOpt.TrackedFunction Nothing argNamesWithTypes wrappedBody { tipe = defType, tvar = nodeTvar }) defType
                        )
            )


{-| Tells whether `expr` has a `TailCall` to `funcName` in tail position: in
an `if` or `case` branch, including every `case` jump, or the body of a `Let`
or `Destruct`.
-}
hasTailCall : Name -> TOpt.Expr Name -> Bool
hasTailCall funcName expr =
    case expr of
        TOpt.TailCall callName _ _ ->
            callName == funcName

        TOpt.If branches final _ ->
            List.any (\( _, branch ) -> hasTailCall funcName branch) branches
                || hasTailCall funcName final

        TOpt.Let _ body _ ->
            hasTailCall funcName body

        TOpt.Destruct _ body _ ->
            hasTailCall funcName body

        TOpt.Case _ _ decider jumps _ ->
            decidecHasTailCall funcName decider || List.any (\( _, branch ) -> hasTailCall funcName branch) jumps

        _ ->
            False


{-| Tells whether a branch inlined in a `case` decision tree has a `TailCall`
to `funcName`. Branches held as jumps are checked by `hasTailCall`.
-}
decidecHasTailCall : Name -> TOpt.Decider (TOpt.Choice Name) -> Bool
decidecHasTailCall funcName decider =
    case decider of
        TOpt.Leaf choice ->
            case choice of
                TOpt.Inline expr ->
                    hasTailCall funcName expr

                TOpt.Jump _ ->
                    False

        TOpt.Chain _ success failure ->
            decidecHasTailCall funcName success || decidecHasTailCall funcName failure

        TOpt.FanOut _ tests fallback ->
            decidecHasTailCall funcName fallback || List.any (Tuple.second >> decidecHasTailCall funcName) tests


{-| Wraps `expr` in a `Destruct` applying `destructor`, typed `bodyType` and
taking `expr`'s solver variable.
-}
wrapDestruct : Can.Type Name -> TOpt.Destructor Name -> TOpt.Expr Name -> TOpt.Expr Name
wrapDestruct bodyType destructor expr =
    TOpt.Destruct destructor expr { tipe = bodyType, tvar = TOpt.tvarOf expr }



-- ====== DESTRUCTURING ======


{-| Returns the type of the pattern with id `patId` from `exprTypes`. It
crashes, naming `location`, for a negative id (a pattern built during
optimization) or an id with no type.
-}
lookupPatternType : ExprTypes -> Int -> String -> Can.Type Name
lookupPatternType exprTypes patId location =
    if patId < 0 then
        Utils.Crash.crash (location ++ ": synthetic")

    else
        case Array.get patId exprTypes |> Maybe.andThen identity of
            Just t ->
                t

            Nothing ->
                Utils.Crash.crash (location ++ ": not in exprTypes")


{-| Returns the solver variable of the pattern with id `patId`, or `Nothing`
for a negative id or a pattern without one.
-}
lookupPatternVar : ExprVars -> Int -> Maybe Vars.Variable
lookupPatternVar exprVars patId =
    if patId < 0 then
        Nothing

    else
        Array.get patId exprVars |> Maybe.andThen identity


{-| Returns the meta for a destructor of the pattern with id `patId`: `tipe`
and the pattern's solver variable.
-}
makeDestructorMeta : ExprVars -> Int -> Can.Type Name -> TOpt.Meta Name
makeDestructorMeta exprVars patId tipe =
    { tipe = tipe, tvar = lookupPatternVar exprVars patId }


{-| Lowers function argument patterns to one named, typed argument per pattern
and the `Destructor`s, in order, that bind the names inside them.

A variable pattern or an alias pattern names the argument itself. Any other
pattern gets a generated name, and its destructors read from that name. An
argument's type is its pattern's type in `exprTypes`; a missing type crashes.

-}
destructArgs : ExprTypes -> ExprVars -> List Can.Pattern -> Names.Tracker ( List ( A.Located Name, Can.Type Name ), List (TOpt.Destructor Name) )
destructArgs exprTypes exprVars args =
    Names.traverse (destruct exprTypes exprVars) args
        |> Names.map List.unzip
        |> Names.map
            (\( argNamesWithTypes, destructorLists ) ->
                ( argNamesWithTypes, List.concat destructorLists )
            )


{-| Lowers one argument or `let` pattern to its name and type and the
`Destructor`s, in order, that bind the names inside it.
-}
destruct : ExprTypes -> ExprVars -> Can.Pattern -> Names.Tracker ( ( A.Located Name, Can.Type Name ), List (TOpt.Destructor Name) )
destruct exprTypes exprVars ((A.At region patternInfo) as pattern) =
    case patternInfo.node of
        Can.PVar name ->
            let
                patType =
                    lookupPatternType exprTypes patternInfo.id "Expression.destruct: PVar"
            in
            Names.pure ( ( A.At region name, patType ), [] )

        Can.PAlias subPattern name ->
            let
                patType =
                    lookupPatternType exprTypes patternInfo.id "Expression.destruct: PAlias"
            in
            destructHelp exprTypes exprVars (TOpt.Root name) subPattern []
                |> Names.map (\revDs -> ( ( A.At region name, patType ), List.reverse revDs ))

        _ ->
            Names.generate
                |> Names.andThen
                    (\name ->
                        let
                            patType =
                                lookupPatternType exprTypes patternInfo.id "Expression.destruct: generated"
                        in
                        destructHelp exprTypes exprVars (TOpt.Root name) pattern []
                            |> Names.map
                                (\revDs ->
                                    ( ( A.At region name, patType ), List.reverse revDs )
                                )
                    )


{-| Prepends to `revDs`, in reverse order, the destructors that bind the names in
`pattern` read from `path`.
-}
destructHelp : ExprTypes -> ExprVars -> TOpt.Path -> Can.Pattern -> List (TOpt.Destructor Name) -> Names.Tracker (List (TOpt.Destructor Name))
destructHelp exprTypes exprVars path pattern revDs =
    destructHelpWithType exprTypes exprVars Nothing Nothing path pattern revDs


{-| Like `destructHelp`, but a pattern built during optimization (negative id) is
typed through `parentPatId`, the pattern it was built from.
-}
destructHelpWithParent : ExprTypes -> ExprVars -> Int -> TOpt.Path -> Can.Pattern -> List (TOpt.Destructor Name) -> Names.Tracker (List (TOpt.Destructor Name))
destructHelpWithParent exprTypes exprVars parentPatId path pattern revDs =
    destructHelpWithType exprTypes exprVars (Just parentPatId) Nothing path pattern revDs


{-| Prepends to `revDs`, in reverse order, the destructors that bind the names in
a pattern read from `path`.

A pattern built during optimization has a negative id; with `maybeParentPatId`
it is typed by that pattern instead. Such a pattern is the tail of a list
pattern, and has the same list type as the pattern it was built from.

`maybeType`, when given, is the type of a variable pattern, used instead of a
lookup. A constructor argument is passed its own pattern type this way.

When `path` is not a `Root`, a tuple, list, cons or multi-argument constructor
pattern first binds it to a generated name, so that the inner destructors read
from a root. A tuple of more than three elements crashes.

-}
destructHelpWithType : ExprTypes -> ExprVars -> Maybe Int -> Maybe (Can.Type Name) -> TOpt.Path -> Can.Pattern -> List (TOpt.Destructor Name) -> Names.Tracker (List (TOpt.Destructor Name))
destructHelpWithType exprTypes exprVars maybeParentPatId maybeType path (A.At region patternInfo) revDs =
    let
        effectivePatId =
            if patternInfo.id < 0 then
                Maybe.withDefault patternInfo.id maybeParentPatId

            else
                patternInfo.id
    in
    case patternInfo.node of
        Can.PAnything ->
            Names.pure revDs

        Can.PVar name ->
            let
                varType =
                    case maybeType of
                        Just t ->
                            t

                        Nothing ->
                            lookupPatternType exprTypes effectivePatId "Expression.destructHelpWithType: PVar"
            in
            Names.pure (TOpt.Destructor name path (makeDestructorMeta exprVars effectivePatId varType) :: revDs)

        Can.PRecord fields ->
            let
                toDestruct : Name -> TOpt.Destructor Name
                toDestruct name =
                    let
                        fieldType =
                            case Maybe.map Type.iteratedDealias (Array.get effectivePatId exprTypes |> Maybe.andThen identity) of
                                Just (Can.TRecord fieldDict _) ->
                                    case Dict.get name fieldDict of
                                        Just (Can.FieldType _ t) ->
                                            t

                                        Nothing ->
                                            Utils.Crash.crash ("Expression.destructHelpWithType: PRecord field " ++ name ++ " not in type")

                                _ ->
                                    lookupPatternType exprTypes effectivePatId ("Expression.destructHelpWithType: PRecord " ++ name)
                    in
                    TOpt.Destructor name (TOpt.Field name path) { tipe = fieldType, tvar = Nothing }
            in
            Names.registerFieldList fields (List.map toDestruct fields ++ revDs)

        Can.PAlias subPattern name ->
            let
                aliasType =
                    lookupPatternType exprTypes effectivePatId "Expression.destructHelpWithType: PAlias"
            in
            (TOpt.Destructor name path (makeDestructorMeta exprVars effectivePatId aliasType) :: revDs) |> destructHelp exprTypes exprVars (TOpt.Root name) subPattern

        Can.PUnit ->
            Names.pure revDs

        Can.PTuple a b [] ->
            destructTwo exprTypes exprVars effectivePatId TOpt.HintTuple2 path a b revDs

        Can.PTuple a b [ c ] ->
            case path of
                TOpt.Root _ ->
                    destructHelp exprTypes exprVars (TOpt.Index Index.first TOpt.HintTuple3 path) a revDs
                        |> Names.andThen (destructHelp exprTypes exprVars (TOpt.Index Index.second TOpt.HintTuple3 path) b)
                        |> Names.andThen (destructHelp exprTypes exprVars (TOpt.Index Index.third TOpt.HintTuple3 path) c)

                _ ->
                    Names.generate
                        |> Names.andThen
                            (\name ->
                                let
                                    newRoot =
                                        TOpt.Root name

                                    genType =
                                        lookupPatternType exprTypes effectivePatId "Expression.destructHelpWithType: PTuple3 gen"
                                in
                                destructHelp exprTypes exprVars (TOpt.Index Index.first TOpt.HintTuple3 newRoot) a (TOpt.Destructor name path (makeDestructorMeta exprVars effectivePatId genType) :: revDs)
                                    |> Names.andThen (destructHelp exprTypes exprVars (TOpt.Index Index.second TOpt.HintTuple3 newRoot) b)
                                    |> Names.andThen (destructHelp exprTypes exprVars (TOpt.Index Index.third TOpt.HintTuple3 newRoot) c)
                            )

        Can.PTuple _ _ _ ->
            Utils.Crash.crash "Expression.destructHelpWithType: PTuple with more than 3 elements is not supported in Elm"

        Can.PList [] ->
            Names.pure revDs

        Can.PList (hd :: tl) ->
            -- The tail pattern is built here, with id -1, and typed through this pattern.
            destructTwo exprTypes exprVars effectivePatId TOpt.HintList path hd (A.At region { id = -1, node = Can.PList tl }) revDs

        Can.PCons hd tl ->
            destructTwo exprTypes exprVars effectivePatId TOpt.HintList path hd tl revDs

        Can.PChr _ ->
            Names.pure revDs

        Can.PStr _ _ ->
            Names.pure revDs

        Can.PInt _ ->
            Names.pure revDs

        Can.PBool _ _ ->
            Names.pure revDs

        Can.PCtor { union, name, args } ->
            case args of
                [ Can.PatternCtorArg _ _ arg ] ->
                    let
                        (Can.Union unionData) =
                            union

                        -- The pattern's own type, not the constructor's declared argument type.
                        patternId =
                            (A.toValue arg).id

                        actualType =
                            case Array.get patternId exprTypes |> Maybe.andThen identity of
                                Just t ->
                                    Just t

                                Nothing ->
                                    Utils.Crash.crash
                                        ("destructHelpWithType PCtor singleton: Pattern ID "
                                            ++ String.fromInt patternId
                                            ++ " not found in exprTypes for constructor "
                                            ++ name
                                            ++ ". This is a compiler bug."
                                        )
                    in
                    case unionData.opts of
                        Can.Normal ->
                            destructHelpWithType exprTypes exprVars Nothing actualType (TOpt.Index Index.first (TOpt.HintCustom name) path) arg revDs

                        Can.Unbox ->
                            destructHelpWithType exprTypes exprVars Nothing actualType (TOpt.Unbox path) arg revDs

                        Can.Enum ->
                            destructHelpWithType exprTypes exprVars Nothing actualType (TOpt.Index Index.first (TOpt.HintCustom name) path) arg revDs

                _ ->
                    case path of
                        TOpt.Root _ ->
                            List.foldl (\arg -> Names.andThen (\revDs_ -> destructCtorArg exprTypes exprVars name path revDs_ arg))
                                (Names.pure revDs)
                                args

                        _ ->
                            Names.generate
                                |> Names.andThen
                                    (\genName ->
                                        let
                                            genType =
                                                lookupPatternType exprTypes effectivePatId "Expression.destructHelpWithType: PCtor gen"
                                        in
                                        List.foldl (\arg -> Names.andThen (\revDs_ -> destructCtorArg exprTypes exprVars name (TOpt.Root genName) revDs_ arg))
                                            (Names.pure (TOpt.Destructor genName path (makeDestructorMeta exprVars effectivePatId genType) :: revDs))
                                            args
                                    )


{-| Prepends the destructors for the two parts `a` and `b` of a pair or a cons
pattern read from `path`, with container `hint`. `parentPatId` is the whole
pattern's id, which types the generated name a non-root `path` is bound to.
-}
destructTwo : ExprTypes -> ExprVars -> Int -> TOpt.ContainerHint -> TOpt.Path -> Can.Pattern -> Can.Pattern -> List (TOpt.Destructor Name) -> Names.Tracker (List (TOpt.Destructor Name))
destructTwo exprTypes exprVars parentPatId hint path a b revDs =
    case path of
        TOpt.Root _ ->
            destructHelpWithParent exprTypes exprVars parentPatId (TOpt.Index Index.first hint path) a revDs
                |> Names.andThen (destructHelpWithParent exprTypes exprVars parentPatId (TOpt.Index Index.second hint path) b)

        _ ->
            Names.generate
                |> Names.andThen
                    (\name ->
                        let
                            newRoot =
                                TOpt.Root name

                            genType =
                                lookupPatternType exprTypes parentPatId "Expression.destructTwo: generated"
                        in
                        destructHelpWithParent exprTypes exprVars parentPatId (TOpt.Index Index.first hint newRoot) a (TOpt.Destructor name path (makeDestructorMeta exprVars parentPatId genType) :: revDs)
                            |> Names.andThen (destructHelpWithParent exprTypes exprVars parentPatId (TOpt.Index Index.second hint newRoot) b)
                    )


{-| Prepends the destructors for one argument of the constructor `ctorName`, read
from its index under `path` and typed by its own pattern type.
-}
destructCtorArg : ExprTypes -> ExprVars -> Name -> TOpt.Path -> List (TOpt.Destructor Name) -> Can.PatternCtorArg -> Names.Tracker (List (TOpt.Destructor Name))
destructCtorArg exprTypes exprVars ctorName path revDs (Can.PatternCtorArg index _ arg) =
    let
        patternId =
            (A.toValue arg).id

        actualType =
            case Array.get patternId exprTypes |> Maybe.andThen identity of
                Just t ->
                    Just t

                Nothing ->
                    Utils.Crash.crash
                        ("destructCtorArg: Pattern ID "
                            ++ String.fromInt patternId
                            ++ " not found in exprTypes for constructor "
                            ++ ctorName
                            ++ ". This is a compiler bug."
                        )
    in
    destructHelpWithType exprTypes exprVars Nothing actualType (TOpt.Index index (TOpt.HintCustom ctorName) path) arg revDs


{-| Returns, in order, the destructors that bind the names in a `case` branch
pattern, read from the variable `rootName`.
-}
destructCase : ExprTypes -> ExprVars -> Name -> Can.Pattern -> Names.Tracker (List (TOpt.Destructor Name))
destructCase exprTypes exprVars rootName pattern =
    destructHelp exprTypes exprVars (TOpt.Root rootName) pattern []
        |> Names.map List.reverse
