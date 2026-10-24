// RUN: %ecoc %s -emit=mlir 2>&1 | %FileCheck %s
//
// SD-20 pin: the six reference-counting placeholder ops are kept for future
// Perceus-style memory management. This fixture keeps their definitions in
// Ops.td from rotting: each must still parse, pass its verifier and print back.
// The *_rejected.mlir fixtures pin what the pipeline does with them today.

module {
  func.func @main() -> i64 {
    %c42 = arith.constant 42 : i64
    %boxed = eco.box %c42 : i64 -> !eco.value

    // CHECK: "eco.incref"(%{{.*}}) <{amount = 1 : i64}> : (!eco.value) -> ()
    "eco.incref"(%boxed) {amount = 1 : i64} : (!eco.value) -> ()
    // CHECK: "eco.decref"(%{{.*}}) : (!eco.value) -> ()
    "eco.decref"(%boxed) : (!eco.value) -> ()
    // CHECK: "eco.decref_shallow"(%{{.*}}) : (!eco.value) -> ()
    "eco.decref_shallow"(%boxed) : (!eco.value) -> ()
    // CHECK: "eco.free"(%{{.*}}) : (!eco.value) -> ()
    "eco.free"(%boxed) : (!eco.value) -> ()
    // CHECK: = "eco.reset"(%{{.*}}) : (!eco.value) -> !eco.value
    %r = "eco.reset"(%boxed) : (!eco.value) -> !eco.value
    // CHECK: = "eco.reset_ref"(%{{.*}}) : (!eco.value) -> !eco.value
    %rr = "eco.reset_ref"(%boxed) : (!eco.value) -> !eco.value

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
