# elm-mlir

Build [MLIR](https://mlir.llvm.org) programs in Elm, and write them out as MLIR's generic text or as
MLIR bytecode, the binary form MLIR tools load directly. Nothing outside Elm is needed: no LLVM,
no MLIR library, no ports.

It is the MLIR library of the eco Elm compiler, whose native back end builds its whole output with
it.

## An example

A function that returns the 64-bit integer 42, written as text and as bytecode:

```elm
import Bytes exposing (Bytes)
import Dict
import Mlir.Bytecode.StreamEncode as StreamEncode
import Mlir.Loc as Loc
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirRegion(..), MlirType(..))
import Mlir.Pretty as Pretty
import OrderedDict


op : String -> MlirOp
op name =
    { name = name
    , id = ""
    , operands = []
    , results = []
    , attrs = Dict.empty
    , regions = []
    , isTerminator = False
    , loc = Loc.unknown
    , successors = []
    }


answer : MlirOp
answer =
    let
        ( constantOp, returnOp, funcOp ) =
            ( op "arith.constant", op "func.return", op "func.func" )

        constant =
            { constantOp
                | results = [ ( "%c", I64 ) ]
                , attrs = Dict.fromList [ ( "value", IntAttr (Just I64) 42 ) ]
            }

        return =
            { returnOp | operands = [ "%c" ], isTerminator = True }
    in
    { funcOp
        | attrs =
            Dict.fromList
                [ ( "sym_name", StringAttr "answer" )
                , ( "function_type", TypeAttr (FunctionType { inputs = [], results = [ I64 ] }) )
                ]
        , regions =
            [ MlirRegion
                { entry = { args = [], body = [ constant ], terminator = return }
                , blocks = OrderedDict.empty
                }
            ]
    }


text : String
text =
    Pretty.ppModuleHeader ++ Pretty.ppTopLevelOp answer ++ Pretty.ppModuleFooter


bytecode : Bytes
bytecode =
    StreamEncode.assembleModule
        (StreamEncode.collectAndEncodeOps [ answer ] StreamEncode.emptyStreamTables)
        Loc.unknown
```

`mlir-opt` reads either form, so `mlir-opt answer.mlirbc` prints the module back as text.

## The model

`Mlir.Mlir` is a generic model of MLIR: an operation is its name (`dialect.op`), the names of the
SSA values it reads and defines, a dictionary of attributes, its regions and its location. Nothing
here knows which operations a dialect has, so any dialect can be written, and nothing checks that an
operation makes sense. That is MLIR's verifier's job when it reads the output.

The attributes and types are a fixed set: integers, floats, strings, booleans, types, arrays and
dense arrays, dictionaries, symbol references and unit attributes; signless and signed integer,
index, float and function types. Anything else is written as its text: a dialect's type by its
name, as `NamedStruct "llvm.ptr"` is written `!llvm.ptr`, and any other attribute as
`OpaqueAttr "#mosh<ape[2]> : !mosh.ape"`. MLIR parses that text when it reads the program.

`Mlir.Mlir.mlirOp` and `opBuilder` build an operation step by step, drawing its `id` from an
environment the caller threads through.

## Text and bytecode

- `Mlir.Pretty` prints MLIR's generic form, which MLIR reads for any dialect without knowing its
  custom syntax.
- `Mlir.Bytecode.StreamEncode` writes bytecode (format version 4) and takes the operations a batch
  at a time, so a large program need not be held in memory at once: each batch is encoded as soon
  as it is added.

The same output is read by MLIR from LLVM 21 to at least LLVM 24: bytecode carries its own format
version, which MLIR reads back to version 0, and the builtin attribute and type encodings written
here are the same across those releases. What changes between LLVM releases is the dialects
themselves (operation names and attributes), which is a matter for the program being built.

## Limits

- Locations are carried but only file, line and column locations and the unknown location are
  written; the text printer writes none.
- The bytecode writer must know which regions are isolated from the values around them, and goes by
  the operation's name: `func.func` and `builtin.module`, and any operation named with
  `StreamEncode.isolating`, such as a dialect's own function operation.
- Lookups are not checked: an operand that names no value, or an attribute missing from the
  writer's tables, gives a corrupt file rather than an error.
