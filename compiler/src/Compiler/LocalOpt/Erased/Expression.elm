module Compiler.LocalOpt.Erased.Expression exposing
    ( Cycle
    , optimize, optimizePotentialTailCall
    , destructArgs
    )

{-| Optimizes canonical expressions into optimized expressions.

This module transforms the canonical AST produced by type checking into an
optimized representation suitable for code generation. Key optimizations include:

  - Inlining constructors and simple operations
  - Tracking global dependencies and field usage
  - Pattern destructuring for efficient field access
  - Tail call detection and optimization for recursive functions


# Core Types

@docs Cycle


# Optimization

@docs optimize, optimizePotentialTailCall


# Helpers

@docs destructArgs

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Optimized as Opt
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.LocalOpt.Erased.Case as Case
import Compiler.LocalOpt.Erased.Names as Names
import Compiler.Reporting.Annotation as A
import Data.Map as Dict
import Data.Set as EverySet exposing (EverySet)
import Utils.Main as Utils



-- ====== OPTIMIZE ======


{-| Set of names that participate in a recursive definition cycle.
Used to identify which variables need special cycle-breaking handling during optimization.
-}
type alias Cycle =
    EverySet String Name.Name


{-| Transforms a canonical expression into an optimized expression.

This is the main entry point for expression optimization. It recursively processes
the canonical AST, performing optimizations such as:

  - Tracking global variable and constructor usage
  - Registering field accesses for record optimization
  - Converting pattern matches to efficient destructuring operations
  - Detecting and preserving tail call opportunities

The function works within the Names.Tracker monad to collect dependency information
while transforming the expression tree.

-}
optimize : Cycle -> Can.Expr -> Names.Tracker Opt.Expr
optimize cycle (A.At region exprInfo) =
    case exprInfo.node of
        Can.VarLocal name ->
            Names.pure (Opt.TrackedVarLocal region name)

        Can.VarTopLevel home name ->
            if EverySet.member identity name cycle then
                Names.pure (Opt.VarCycle region home name)

            else
                Names.registerGlobal region home name

        Can.VarKernel kernelPrefix home name ->
            Names.registerKernel home (Opt.VarKernel region kernelPrefix home name)

        Can.VarForeign home name _ ->
            Names.registerGlobal region home name

        Can.VarCtor opts home name index _ ->
            Names.registerCtor region home (A.At region name) index opts

        Can.VarDebug home name _ ->
            Names.registerDebug name home region

        Can.VarOperator _ home name _ ->
            Names.registerGlobal region home name

        Can.Chr chr ->
            Names.registerKernel Name.utils (Opt.Chr region chr)

        Can.Str str ->
            Names.pure (Opt.Str region str)

        Can.Int int ->
            Names.pure (Opt.Int region int)

        Can.Float float ->
            Names.pure (Opt.Float region float)

        Can.List entries ->
            Names.traverse (optimize cycle) entries
                |> Names.andThen (Names.registerKernel Name.list << Opt.List region)

        Can.Negate expr ->
            Names.registerGlobal region ModuleName.basics Name.negate
                |> Names.andThen
                    (\func ->
                        optimize cycle expr
                            |> Names.map
                                (\arg ->
                                    Opt.Call region func [ arg ]
                                )
                    )

        Can.Binop _ home name _ left right ->
            Names.registerGlobal region home name
                |> Names.andThen
                    (\optFunc ->
                        optimize cycle left
                            |> Names.andThen
                                (\optLeft ->
                                    optimize cycle right
                                        |> Names.map
                                            (\optRight ->
                                                Opt.Call region optFunc [ optLeft, optRight ]
                                            )
                                )
                    )

        Can.Lambda args body ->
            destructArgs args
                |> Names.andThen
                    (\( argNames, destructors ) ->
                        optimize cycle body
                            |> Names.map
                                (\obody ->
                                    Opt.TrackedFunction argNames (List.foldr Opt.Destruct obody destructors)
                                )
                    )

        Can.Call func args ->
            optimize cycle func
                |> Names.andThen
                    (\optimizeExpr ->
                        Names.traverse (optimize cycle) args
                            |> Names.map (Opt.Call region optimizeExpr)
                    )

        Can.If branches finally ->
            let
                optimizeBranch : ( Can.Expr, Can.Expr ) -> Names.Tracker ( Opt.Expr, Opt.Expr )
                optimizeBranch ( condition, branch ) =
                    optimize cycle condition
                        |> Names.andThen
                            (\expr ->
                                optimize cycle branch
                                    |> Names.map (Tuple.pair expr)
                            )
            in
            Names.traverse optimizeBranch branches
                |> Names.andThen
                    (\optimizedBranches ->
                        optimize cycle finally
                            |> Names.map (Opt.If optimizedBranches)
                    )

        Can.Let def body ->
            optimize cycle body
                |> Names.andThen (optimizeDef cycle def)

        Can.LetRec defs body ->
            case defs of
                [ def ] ->
                    optimizePotentialTailCallDef cycle def
                        |> Names.andThen
                            (\tailCallDef ->
                                optimize cycle body
                                    |> Names.map (Opt.Let tailCallDef)
                            )

                _ ->
                    List.foldl
                        (\def bod ->
                            Names.andThen (optimizeDef cycle def) bod
                        )
                        (optimize cycle body)
                        defs

        Can.LetDestruct pattern expr body ->
            destruct pattern
                |> Names.andThen
                    (\( A.At nameRegion name, destructs ) ->
                        optimize cycle expr
                            |> Names.andThen
                                (\oexpr ->
                                    optimize cycle body
                                        |> Names.map
                                            (\obody ->
                                                Opt.Let (Opt.Def nameRegion name oexpr) (List.foldr Opt.Destruct obody destructs)
                                            )
                                )
                    )

        Can.Case expr branches ->
            let
                optimizeBranch : Name.Name -> Can.CaseBranch -> Names.Tracker ( Can.Pattern, Opt.Expr )
                optimizeBranch root (Can.CaseBranch pattern branch) =
                    destructCase root pattern
                        |> Names.andThen
                            (\destructors ->
                                optimize cycle branch
                                    |> Names.map
                                        (\obranch ->
                                            ( pattern, List.foldr Opt.Destruct obranch destructors )
                                        )
                            )
            in
            Names.generate
                |> Names.andThen
                    (\temp ->
                        optimize cycle expr
                            |> Names.andThen
                                (\oexpr ->
                                    case oexpr of
                                        Opt.VarLocal root ->
                                            Names.traverse (optimizeBranch root) branches
                                                |> Names.map (Case.optimize temp root)

                                        Opt.TrackedVarLocal _ root ->
                                            Names.traverse (optimizeBranch root) branches
                                                |> Names.map (Case.optimize temp root)

                                        _ ->
                                            Names.traverse (optimizeBranch temp) branches
                                                |> Names.map
                                                    (\obranches ->
                                                        Opt.Let (Opt.Def region temp oexpr) (Case.optimize temp temp obranches)
                                                    )
                                )
                    )

        Can.Accessor field ->
            Names.registerField field (Opt.Accessor region field)

        Can.Access record (A.At fieldPosition field) ->
            optimize cycle record
                |> Names.andThen
                    (\optRecord ->
                        Names.registerField field (Opt.Access optRecord fieldPosition field)
                    )

        Can.Update record updates ->
            Names.mapTraverse A.toValue A.compareLocated (optimizeUpdate cycle) updates
                |> Names.andThen
                    (\optUpdates ->
                        optimize cycle record
                            |> Names.andThen
                                (\optRecord ->
                                    Names.registerFieldDict (Utils.mapMapKeys identity A.compareLocated A.toValue updates) (Opt.Update region optRecord optUpdates)
                                )
                    )

        Can.Record fields ->
            Names.mapTraverse A.toValue A.compareLocated (optimize cycle) fields
                |> Names.andThen
                    (\optFields ->
                        Names.registerFieldDict (Utils.mapMapKeys identity A.compareLocated A.toValue fields) (Opt.TrackedRecord region optFields)
                    )

        Can.Unit ->
            Names.registerKernel Name.utils Opt.Unit

        Can.Tuple a b cs ->
            optimize cycle a
                |> Names.andThen
                    (\optA ->
                        optimize cycle b
                            |> Names.andThen
                                (\optB ->
                                    Names.traverse (optimize cycle) cs
                                        |> Names.andThen (Names.registerKernel Name.utils << Opt.Tuple region optA optB)
                                )
                    )

        Can.Shader src (Shader.Types attributes uniforms _) ->
            Names.pure (Opt.Shader src (EverySet.fromList identity (Dict.keys compare attributes)) (EverySet.fromList identity (Dict.keys compare uniforms)))



-- ====== UPDATE ======


optimizeUpdate : Cycle -> Can.FieldUpdate -> Names.Tracker Opt.Expr
optimizeUpdate cycle (Can.FieldUpdate _ expr) =
    optimize cycle expr



-- ====== DEFINITION ======


optimizeDef : Cycle -> Can.Def -> Opt.Expr -> Names.Tracker Opt.Expr
optimizeDef cycle def body =
    case def of
        Can.Def (A.At region name) args expr ->
            optimizeDefHelp cycle region name args expr body

        Can.TypedDef (A.At region name) _ typedArgs expr _ ->
            optimizeDefHelp cycle region name (List.map Tuple.first typedArgs) expr body


optimizeDefHelp : Cycle -> A.Region -> Name.Name -> List Can.Pattern -> Can.Expr -> Opt.Expr -> Names.Tracker Opt.Expr
optimizeDefHelp cycle region name args expr body =
    case args of
        [] ->
            optimize cycle expr
                |> Names.map (\oexpr -> Opt.Let (Opt.Def region name oexpr) body)

        _ ->
            optimize cycle expr
                |> Names.andThen
                    (\oexpr ->
                        destructArgs args
                            |> Names.map
                                (\( argNames, destructors ) ->
                                    let
                                        ofunc : Opt.Expr
                                        ofunc =
                                            Opt.TrackedFunction argNames (List.foldr Opt.Destruct oexpr destructors)
                                    in
                                    Opt.Let (Opt.Def region name ofunc) body
                                )
                    )



-- ====== DESTRUCTURING ======


{-| Converts a list of function argument patterns into argument names and destructuring operations.

For each pattern in the argument list, this generates a simple variable name and creates
Destructor operations to extract any nested values. This allows function arguments to use
complex patterns (like tuples or records) while maintaining efficient compiled code.

Returns a tuple of:

  - List of argument names (one per pattern)
  - List of destructors to extract nested values from those arguments

-}
destructArgs : List Can.Pattern -> Names.Tracker ( List (A.Located Name.Name), List Opt.Destructor )
destructArgs args =
    Names.traverse destruct args
        |> Names.map List.unzip
        |> Names.map
            (\( argNames, destructorLists ) ->
                ( argNames, List.concat destructorLists )
            )


destructCase : Name.Name -> Can.Pattern -> Names.Tracker (List Opt.Destructor)
destructCase rootName pattern =
    destructHelp (Opt.Root rootName) pattern []
        |> Names.map List.reverse


destruct : Can.Pattern -> Names.Tracker ( A.Located Name.Name, List Opt.Destructor )
destruct ((A.At region patternInfo) as pattern) =
    case patternInfo.node of
        Can.PVar name ->
            Names.pure ( A.At region name, [] )

        Can.PAlias subPattern name ->
            destructHelp (Opt.Root name) subPattern []
                |> Names.map (\revDs -> ( A.At region name, List.reverse revDs ))

        _ ->
            Names.generate
                |> Names.andThen
                    (\name ->
                        destructHelp (Opt.Root name) pattern []
                            |> Names.map
                                (\revDs ->
                                    ( A.At region name, List.reverse revDs )
                                )
                    )


destructHelp : Opt.Path -> Can.Pattern -> List Opt.Destructor -> Names.Tracker (List Opt.Destructor)
destructHelp path (A.At region patternInfo) revDs =
    case patternInfo.node of
        Can.PAnything ->
            Names.pure revDs

        Can.PVar name ->
            Names.pure (Opt.Destructor name path :: revDs)

        Can.PRecord fields ->
            let
                toDestruct : Name.Name -> Opt.Destructor
                toDestruct name =
                    Opt.Destructor name (Opt.Field name path)
            in
            Names.registerFieldList fields (List.map toDestruct fields ++ revDs)

        Can.PAlias subPattern name ->
            (Opt.Destructor name path :: revDs) |> destructHelp (Opt.Root name) subPattern

        Can.PUnit ->
            Names.pure revDs

        Can.PTuple a b [] ->
            destructTwo path a b revDs

        Can.PTuple a b [ c ] ->
            case path of
                Opt.Root _ ->
                    destructHelp (Opt.Index Index.first path) a revDs
                        |> Names.andThen (destructHelp (Opt.Index Index.second path) b)
                        |> Names.andThen (destructHelp (Opt.Index Index.third path) c)

                _ ->
                    Names.generate
                        |> Names.andThen
                            (\name ->
                                let
                                    newRoot : Opt.Path
                                    newRoot =
                                        Opt.Root name
                                in
                                destructHelp (Opt.Index Index.first newRoot) a (Opt.Destructor name path :: revDs)
                                    |> Names.andThen (destructHelp (Opt.Index Index.second newRoot) b)
                                    |> Names.andThen (destructHelp (Opt.Index Index.third newRoot) c)
                            )

        Can.PTuple a b cs ->
            case path of
                Opt.Root _ ->
                    List.foldl (\( index, arg ) -> Names.andThen (destructHelp (Opt.ArrayIndex index (Opt.Field "cs" path)) arg))
                        (destructHelp (Opt.Index Index.first path) a revDs
                            |> Names.andThen (destructHelp (Opt.Index Index.second path) b)
                        )
                        (List.indexedMap Tuple.pair cs)

                _ ->
                    Names.generate
                        |> Names.andThen
                            (\name ->
                                let
                                    newRoot : Opt.Path
                                    newRoot =
                                        Opt.Root name
                                in
                                List.foldl (\( index, arg ) -> Names.andThen (destructHelp (Opt.ArrayIndex index (Opt.Field "cs" newRoot)) arg))
                                    (destructHelp (Opt.Index Index.first newRoot) a (Opt.Destructor name path :: revDs)
                                        |> Names.andThen (destructHelp (Opt.Index Index.second newRoot) b)
                                    )
                                    (List.indexedMap Tuple.pair cs)
                            )

        Can.PList [] ->
            Names.pure revDs

        Can.PList (hd :: tl) ->
            -- Use placeholder ID (-1) for synthesized patterns
            destructTwo path hd (A.At region { id = -1, node = Can.PList tl }) revDs

        Can.PCons hd tl ->
            destructTwo path hd tl revDs

        Can.PChr _ ->
            Names.pure revDs

        Can.PStr _ _ ->
            Names.pure revDs

        Can.PInt _ ->
            Names.pure revDs

        Can.PBool _ _ ->
            Names.pure revDs

        Can.PCtor { union, args } ->
            case args of
                [ Can.PatternCtorArg _ _ arg ] ->
                    let
                        (Can.Union unionData) =
                            union
                    in
                    case unionData.opts of
                        Can.Normal ->
                            destructHelp (Opt.Index Index.first path) arg revDs

                        Can.Unbox ->
                            destructHelp (Opt.Unbox path) arg revDs

                        Can.Enum ->
                            destructHelp (Opt.Index Index.first path) arg revDs

                _ ->
                    case path of
                        Opt.Root _ ->
                            List.foldl (\arg -> Names.andThen (\revDs_ -> destructCtorArg path revDs_ arg))
                                (Names.pure revDs)
                                args

                        _ ->
                            Names.generate
                                |> Names.andThen
                                    (\name ->
                                        List.foldl (\arg -> Names.andThen (\revDs_ -> destructCtorArg (Opt.Root name) revDs_ arg))
                                            (Names.pure (Opt.Destructor name path :: revDs))
                                            args
                                    )


destructTwo : Opt.Path -> Can.Pattern -> Can.Pattern -> List Opt.Destructor -> Names.Tracker (List Opt.Destructor)
destructTwo path a b revDs =
    case path of
        Opt.Root _ ->
            destructHelp (Opt.Index Index.first path) a revDs
                |> Names.andThen (destructHelp (Opt.Index Index.second path) b)

        _ ->
            Names.generate
                |> Names.andThen
                    (\name ->
                        let
                            newRoot : Opt.Path
                            newRoot =
                                Opt.Root name
                        in
                        destructHelp (Opt.Index Index.first newRoot) a (Opt.Destructor name path :: revDs)
                            |> Names.andThen (destructHelp (Opt.Index Index.second newRoot) b)
                    )


destructCtorArg : Opt.Path -> List Opt.Destructor -> Can.PatternCtorArg -> Names.Tracker (List Opt.Destructor)
destructCtorArg path revDs (Can.PatternCtorArg index _ arg) =
    destructHelp (Opt.Index index path) arg revDs



-- ====== TAIL CALL ======


{-| Optimizes a recursive definition to use tail calls where possible.

This is the entry point for tail call optimization of definitions. It analyzes the
definition to detect tail-recursive calls and converts them to efficient TailCall
nodes that can be compiled to loops instead of recursive function calls.

-}
optimizePotentialTailCallDef : Cycle -> Can.Def -> Names.Tracker Opt.Def
optimizePotentialTailCallDef cycle def =
    case def of
        Can.Def (A.At region name) args expr ->
            optimizePotentialTailCall cycle region name args expr

        Can.TypedDef (A.At region name) _ typedArgs expr _ ->
            optimizePotentialTailCall cycle region name (List.map Tuple.first typedArgs) expr


{-| Analyzes a function definition for tail call optimization opportunities.

Given a function's region, name, arguments, and body expression, this function:

1.  Destructures the argument patterns into simple names
2.  Analyzes the body for tail-recursive calls to the same function
3.  Converts tail calls into TailCall nodes for efficient compilation
4.  Returns either a TailDef (if tail calls found) or regular Def

This enables recursive functions to be compiled as loops when they are tail-recursive,
avoiding stack overflow and improving performance.

-}
optimizePotentialTailCall : Cycle -> A.Region -> Name.Name -> List Can.Pattern -> Can.Expr -> Names.Tracker Opt.Def
optimizePotentialTailCall cycle region name args expr =
    destructArgs args
        |> Names.andThen
            (\( argNames, destructors ) ->
                optimizeTail cycle name argNames expr
                    |> Names.map (toTailDef region name argNames destructors)
            )


optimizeTail : Cycle -> Name.Name -> List (A.Located Name.Name) -> Can.Expr -> Names.Tracker Opt.Expr
optimizeTail cycle rootName argNames ((A.At region exprInfo) as locExpr) =
    case exprInfo.node of
        Can.Call func args ->
            Names.traverse (optimize cycle) args
                |> Names.andThen
                    (\oargs ->
                        let
                            isMatchingName : Bool
                            isMatchingName =
                                case (A.toValue func).node of
                                    Can.VarLocal name ->
                                        rootName == name

                                    Can.VarTopLevel _ name ->
                                        rootName == name

                                    _ ->
                                        False
                        in
                        if isMatchingName then
                            case Index.indexedZipWith (\_ a b -> ( A.toValue a, b )) argNames oargs of
                                Index.LengthMatch pairs ->
                                    Names.pure (Opt.TailCall rootName pairs)

                                Index.LengthMismatch _ _ ->
                                    optimize cycle func
                                        |> Names.map (\ofunc -> Opt.Call region ofunc oargs)

                        else
                            optimize cycle func
                                |> Names.map (\ofunc -> Opt.Call region ofunc oargs)
                    )

        Can.If branches finally ->
            let
                optimizeBranch : ( Can.Expr, Can.Expr ) -> Names.Tracker ( Opt.Expr, Opt.Expr )
                optimizeBranch ( condition, branch ) =
                    optimize cycle condition
                        |> Names.andThen
                            (\optimizeCondition ->
                                optimizeTail cycle rootName argNames branch
                                    |> Names.map (Tuple.pair optimizeCondition)
                            )
            in
            Names.traverse optimizeBranch branches
                |> Names.andThen
                    (\obranches ->
                        optimizeTail cycle rootName argNames finally
                            |> Names.map (Opt.If obranches)
                    )

        Can.Let def body ->
            optimizeTail cycle rootName argNames body
                |> Names.andThen (optimizeDef cycle def)

        Can.LetRec defs body ->
            case defs of
                [ def ] ->
                    optimizePotentialTailCallDef cycle def
                        |> Names.andThen
                            (\obody ->
                                optimizeTail cycle rootName argNames body
                                    |> Names.map (Opt.Let obody)
                            )

                _ ->
                    List.foldl
                        (\def bod ->
                            Names.andThen (optimizeDef cycle def) bod
                        )
                        (optimize cycle body)
                        defs

        Can.LetDestruct pattern expr body ->
            destruct pattern
                |> Names.andThen
                    (\( A.At dregion dname, destructors ) ->
                        optimize cycle expr
                            |> Names.andThen
                                (\oexpr ->
                                    optimizeTail cycle rootName argNames body
                                        |> Names.map
                                            (\obody ->
                                                Opt.Let (Opt.Def dregion dname oexpr) (List.foldr Opt.Destruct obody destructors)
                                            )
                                )
                    )

        Can.Case expr branches ->
            let
                optimizeBranch : Name.Name -> Can.CaseBranch -> Names.Tracker ( Can.Pattern, Opt.Expr )
                optimizeBranch root (Can.CaseBranch pattern branch) =
                    destructCase root pattern
                        |> Names.andThen
                            (\destructors ->
                                optimizeTail cycle rootName argNames branch
                                    |> Names.map
                                        (\obranch ->
                                            ( pattern, List.foldr Opt.Destruct obranch destructors )
                                        )
                            )
            in
            Names.generate
                |> Names.andThen
                    (\temp ->
                        optimize cycle expr
                            |> Names.andThen
                                (\oexpr ->
                                    case oexpr of
                                        Opt.VarLocal root ->
                                            Names.traverse (optimizeBranch root) branches
                                                |> Names.map (Case.optimize temp root)

                                        Opt.TrackedVarLocal _ root ->
                                            Names.traverse (optimizeBranch root) branches
                                                |> Names.map (Case.optimize temp root)

                                        _ ->
                                            Names.traverse (optimizeBranch temp) branches
                                                |> Names.map
                                                    (\obranches ->
                                                        Opt.Let (Opt.Def region temp oexpr) (Case.optimize temp temp obranches)
                                                    )
                                )
                    )

        _ ->
            optimize cycle locExpr



-- ====== DETECT TAIL CALLS ======


toTailDef : A.Region -> Name.Name -> List (A.Located Name.Name) -> List Opt.Destructor -> Opt.Expr -> Opt.Def
toTailDef region name argNames destructors body =
    if hasTailCall body then
        Opt.TailDef region name argNames (List.foldr Opt.Destruct body destructors)

    else
        Opt.Def region name (Opt.TrackedFunction argNames (List.foldr Opt.Destruct body destructors))


hasTailCall : Opt.Expr -> Bool
hasTailCall expression =
    case expression of
        Opt.TailCall _ _ ->
            True

        Opt.If branches finally ->
            hasTailCall finally || List.any (Tuple.second >> hasTailCall) branches

        Opt.Let _ body ->
            hasTailCall body

        Opt.Destruct _ body ->
            hasTailCall body

        Opt.Case _ _ decider jumps ->
            decidecHasTailCall decider || List.any (Tuple.second >> hasTailCall) jumps

        _ ->
            False


decidecHasTailCall : Opt.Decider Opt.Choice -> Bool
decidecHasTailCall decider =
    case decider of
        Opt.Leaf choice ->
            case choice of
                Opt.Inline expr ->
                    hasTailCall expr

                Opt.Jump _ ->
                    False

        Opt.Chain _ success failure ->
            decidecHasTailCall success || decidecHasTailCall failure

        Opt.FanOut _ tests fallback ->
            decidecHasTailCall fallback || List.any (Tuple.second >> decidecHasTailCall) tests
