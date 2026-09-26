module Compiler.Type.KernelIntrinsics exposing (Row, lookup, rows, auditedFiles)

{-| Compiler-internal type annotations for `Elm.Kernel.*` / `Eco.Kernel.*`
references (`plans/kernel-intrinsic-annotations.md`).

**The hole this fills.** A kernel reference generates NO type constraint —
`Can.VarKernel _ _ _ -> IO.pure CTrue` in
`Compiler.Type.Constrain.Typed.Expression`. A kernel with an eta-free aliasing
def (`map2 = Elm.Kernel.List.map2`) is bounded indirectly, through the alias's
annotation; a kernel used INLINE is bounded by nothing at all. `toArray` does
not behave as `List a -> Array a`: it behaves as `α -> β` with the two sides
never connected, because nothing ever equates them. Measured — the occurrence
of `Elm.Kernel.List.fromArray` inside `String.split` is `β -> List String` with
β unsolved.

A row here makes the constraint generator emit a real `CForeign`, so the
annotation is INSTANTIATED FRESH per occurrence and unified with the context
exactly as a foreign function's is. Absent a row the behaviour is unchanged
(`CTrue`), so this table is strictly opt-in, kernel by kernel.


## The annotation is a REPRESENTATION claim, and the C++ contract wins

Solved types flow into `KernelAbi` derivation and into monomorphization's spec
keys, so an annotation is not documentation — it tells the rest of the compiler
what heap values inhabit each position. The type in the upstream JS package can
be a LIE about this backend, and where they disagree the C++ is right.

`List.fromArray` is the standing example. Its JS type is `Array a -> List a`,
because in JS it converts a JS array to a cons list. In eco it is a
PASS-THROUGH: `Elm_Kernel_String_split` already returns a real cons list
(`StringOps::split` builds `alloc::cons` chains), and `fromArray` returns
Cons/Nil inputs by identity. Annotating the JS type would make `String.split`'s
intermediate value statically an `Array String` — a four-field custom type —
while dynamically a cons list, which is a layout lie aimed straight at any
consumer that trusts the type. So the row says `List a -> List a`.

Every row therefore carries `evidence` citing the C++ that establishes its heap
contract, and `files` naming the bodies it depends on, pinned by sha256 in
`kernel-license-manifest.txt` (`test/scripts/check-kernel-license-manifest.sh`
harvests this module alongside `KernelSetFacts.elm`).


## This is FAIL-STOP — the opposite of a KernelSetFacts license

A wrong license costs precision. A wrong annotation is a TYPE ERROR in package
code, and the typechecker sees DEAD code too. The standing counterexample is
`Bytes.write_*`: elm/bytes 1.0.8 contains a dead, unexposed `write` helper that
calls them JS-style (3-4 args, `Int` results) while eco's C++ builds 1-2-arg
`Encoder` nodes. ANY honest annotation for that family stops elm/bytes
compiling. It is therefore unannotatable without patching vendored source, and
sits on the rejected list below.

Consequently a row REQUIRES `useSites`: every syntactic occurrence, in every
installed package, enumerated and checked to be an instance of the annotation.
The set is closed and small — `Elm.Kernel.*` syntax is legal only inside
kernel-package source, so no user program can add one.

**Footgun.** `srcTypeToVariable` maps annotation variables BY NAME
(`Compiler.Type.Solve`): a variable literally named `number`, `comparable`,
`appendable` or `compappend` instantiates as the corresponding `FlexSuper`, not
as a plain flex var. Useful (`number -> String` is expressible); silent if
unintended. Name ordinary variables `a`, `b`, `x`, ….

**Keyed by (prefix, home, name), and the prefix is load-bearing.** Its sibling
`Compiler.MonoSolver.KernelSetFacts` is keyed `(home, name)` and genuinely
collides — `Elm.Kernel.File.size : File -> Int` versus
`Eco.Kernel.File.size : Handle -> Task IOError Int`. A license tolerates that
(one row, both vacuous); an ANNOTATION cannot, because the two types are
different and unifying occurrences of one against the other is a type error at
best and a representation lie at worst.


## REJECTED — do not annotate these

  - **`Bytes.write_*`** (the whole family) — see the fail-stop paragraph: the
    installed package contains contradicting dead code.
  - **`Debug.*`** — `Debug.toString`'s export takes a compiler-injected
    `type_id` operand it then routes on, so its Elm-visible arity and its real
    one differ; `Debug` is additionally special-cased in `KernelAbi`,
    `Translate` and `Expr` lowering.
  - Anything whose C++ contract is not established by reading the body. The
    default (`CTrue`) is always available and always safe.

@docs Row, lookup, rows, auditedFiles

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Dict exposing (Dict)


{-| One audited kernel annotation.

`useSites` is not a comment: it is the fail-stop evidence (every occurrence in
every installed package, verified to instantiate the annotation). `evidence`
cites the C++ that fixes the heap contract. `files` feeds the rot manifest.

-}
type alias Row =
    { annotation : Can.Annotation Name
    , useSites : String
    , evidence : String
    , files : List String
    }


{-| The annotation for a kernel reference, or `Nothing` — which means the
constraint generator keeps emitting `CTrue` and nothing changes.
-}
lookup : Name -> Name -> Name -> Maybe Row
lookup prefix home name =
    Dict.get ( prefix, home, name ) intrinsics


{-| Every row, for tests and tooling.
-}
rows : List ( ( Name, Name, Name ), Row )
rows =
    Dict.toList intrinsics


{-| Every C++ path any row depends on, deduplicated and sorted — the source of
truth the license-rot manifest is generated from and checked against.
-}
auditedFiles : List String
auditedFiles =
    intrinsics
        |> Dict.values
        |> List.concatMap .files
        |> List.sort
        |> dedupeSorted


dedupeSorted : List String -> List String
dedupeSorted xs =
    case xs of
        a :: b :: rest ->
            if a == b then
                dedupeSorted (b :: rest)

            else
                a :: dedupeSorted (b :: rest)

        _ ->
            xs



-- ====== THE TABLE ======


intrinsics : Dict ( Name, Name, Name ) Row
intrinsics =
    Dict.fromList
        [ ( ( "Elm", "Json", "addEntry" )
          , { annotation =
                -- (a -> Value) -> a -> Value -> Value
                forall [ "a" ]
                    (Can.tLambda (Can.tLambda (tVar "a") tValue)
                        (Can.tLambda (tVar "a") (Can.tLambda tValue tValue))
                    )
            , useSites = "elm/json 1.1.3+1.1.4 Json/Encode.elm:162 (list), :170 (array), :178 (set) -- all `List/Array/Set.foldl (addEntry func) (emptyArray ()) entries` with func : a -> Value from the enclosing annotation; b unifies to Value, which emptyArray/wrap absorb (both CTrue). No other reference in any installed package."
            , evidence = "JsonExports.cpp:Elm_Kernel_Json_addEntry:1761-1793 applies func to entry via eco_apply_closure :1772 and conses the RETURN onto the accumulator's list :1782, rebuilding an ENC_ARRAY Custom :1786-1791; the accumulator IS the Value representation (emptyArray :1745-1754 allocates ctor=ENC_ARRAY). audited: 2026-08-20 | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged"
            , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
            }
          )
        , ( ( "Elm", "Json", "addField" )
          , { annotation =
                -- String -> Value -> Value -> Value
                forall []
                    (Can.tLambda tString
                        (Can.tLambda tValue (Can.tLambda tValue tValue))
                    )
            , useSites = "elm/json 1.1.3+1.1.4 Json/Encode.elm:202 (object), :224 (dict) -- both `foldl (\\k v obj -> addField k v obj) (emptyObject ()) ...` where k is String (object destructures List (String, Value); dict applies toKey : k -> String) and v is Value (the pair's second, or toValue : v -> Value). The accumulator unifies to Value, which emptyObject/wrap absorb (both CTrue). No other reference in any installed package."
            , evidence = "JsonExports.cpp:Elm_Kernel_Json_addField:1795-1840 builds a (key, value) Tuple2 :1810-1819 and conses it onto the object's field list, rebuilding an ENC_OBJECT Custom; key is a String, value is an already-encoded Value, and the accumulator/result are the ENC_OBJECT representation of Value (emptyObject :1735-1744 allocates ctor=ENC_OBJECT). audited: 2026-08-20 | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged"
            , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
            }
          )
        , ( ( "Elm", "List", "fromArray" )
          , { annotation =
                -- List a -> List a  (NOT the JS `Array a -> List a`)
                forall [ "a" ] (Can.tLambda (tList (tVar "a")) (tList (tVar "a")))
            , useSites = "elm/core 1.0.5 String.elm:191 (split) only -- `fromArray (Elm.Kernel.String.split sep string)` at a = String. No other reference in any installed package."
            , evidence = "ListExports.cpp:Elm_Kernel_List_fromArray:306-354 is a PASS-THROUGH in eco: embedded constants :309-313 and Tag_Cons/Tag_ConsChunk :326-330 return the ARGUMENT by identity, and its own comment :321-325 records that Elm_Kernel_String_split already returns a proper list -- StringOps::split builds alloc::cons chains (StringOps.cpp:839-853). The JS type Array a -> List a would be a layout lie here. audited: 2026-08-20"
            , files = [ "elm-kernel-cpp/src/core/ListExports.cpp" ]
            }
          )
        , ( ( "Elm", "List", "toArray" )
          , { annotation =
                -- List a -> List a  (NOT the JS `List a -> Array a`)
                forall [ "a" ] (Can.tLambda (tList (tVar "a")) (tList (tVar "a")))
            , useSites = "elm/core 1.0.5 String.elm:202 (join) only -- `Elm.Kernel.String.join sep (toArray chunks)` at a = String. No other reference in any installed package."
            , evidence = "ListExports.cpp:Elm_Kernel_List_toArray:356-392 is a PASS-THROUGH in eco: embedded constants :362-366 and Tag_Cons/Tag_ConsChunk :369-374 return the ARGUMENT by identity, and the consumer StringOps::join takes a cons list (StringOps.cpp:659). audited: 2026-08-20"
            , files = [ "elm-kernel-cpp/src/core/ListExports.cpp" ]
            }
          )
        ]



-- ====== TYPE BUILDERS ======


forall : List Name -> Can.Type Name -> Can.Annotation Name
forall vars tipe =
    Can.Forall (Dict.fromList (List.map (\v -> ( v, () )) vars)) tipe


tVar : Name -> Can.Type Name
tVar =
    Can.TVar


tList : Can.Type Name -> Can.Type Name
tList el =
    Can.TType ModuleName.list "List" [ el ]


tString : Can.Type Name
tString =
    Can.TType ModuleName.string "String" []


tValue : Can.Type Name
tValue =
    Can.TType ModuleName.jsonEncode "Value" []
