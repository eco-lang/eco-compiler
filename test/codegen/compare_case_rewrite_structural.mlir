// RUN: %ecoc %s -emit=mlir-eco 2>&1 | %FileCheck %s
//
// EcoCompareCaseRewrite (plans/string-cmp-order-intrinsic-and-postmono-compare-rewrite.md):
// a single-use compare producer feeding a 3-arm case on Order is rewritten to
// direct comparisons + nested bool cases, deleting the Order round-trip.
//
// Every function here is rewritable, so the CHECK-NOTs (which this harness
// evaluates against the WHOLE output) assert that no Order producer survives.
// Bail cases live in compare_case_rewrite_bails.mlir; behavior is pinned by
// compare_case_rewrite_jit.mlir.

module {
  func.func private @Elm_Kernel_Utils_compare(%a: !eco.value, %b: !eco.value) -> !eco.value attributes {is_kernel = true}

  // Int producer: cmp_order disappears entirely, and with it the three
  // getOrder calls its lowering would have emitted per execution.
  func.func private @rw_int(%k: i64, %nk: i64, %l: !eco.value, %r: !eco.value) -> !eco.value {
    %o = eco.int.cmp_order %k, %nk : i64
    %res = eco.case %o : !eco.value [0, 1, 2] -> (!eco.value) {case_kind = "ctor"} {
      eco.yield %l : !eco.value
    }, {
      %e = eco.constant Empty : !eco.value
      eco.yield %e : !eco.value
    }, {
      eco.yield %r : !eco.value
    }
    eco.return %res : !eco.value
  }
  // CHECK-LABEL: @rw_int
  // CHECK: eco.int.lt %arg0, %arg1
  // CHECK: eco.int.gt %arg0, %arg1

  // String producer: becomes ONE eco.string.cmp3 plus integer sign tests
  // against zero (the sign is UNCLAMPED — never compared to +/-1).
  func.func private @rw_str(%k: !eco.value, %nk: !eco.value, %l: !eco.value, %r: !eco.value) -> !eco.value {
    %o = eco.string.cmp_order %k, %nk : !eco.value
    %res = eco.case %o : !eco.value [0, 1, 2] -> (!eco.value) {case_kind = "ctor"} {
      eco.yield %l : !eco.value
    }, {
      %e = eco.constant Empty : !eco.value
      eco.yield %e : !eco.value
    }, {
      eco.yield %r : !eco.value
    }
    eco.return %res : !eco.value
  }
  // CHECK-LABEL: @rw_str
  // CHECK: eco.string.cmp3
  // CHECK: arith.constant 0 : i64

  // Boxed kernel root: becomes a call to the Order-free sibling, whose
  // declaration the pass inserts (UndefinedFunction/CGEN_011 runs after it).
  func.func private @rw_boxed(%a: !eco.value, %b: !eco.value, %l: !eco.value, %r: !eco.value) -> !eco.value {
    %o = "eco.call"(%a, %b) {callee = @Elm_Kernel_Utils_compare} : (!eco.value, !eco.value) -> !eco.value
    %res = eco.case %o : !eco.value [0, 1, 2] -> (!eco.value) {case_kind = "ctor"} {
      eco.yield %l : !eco.value
    }, {
      %e = eco.constant Empty : !eco.value
      eco.yield %e : !eco.value
    }, {
      eco.yield %r : !eco.value
    }
    eco.return %res : !eco.value
  }
  // CHECK-LABEL: @rw_boxed
  // CHECK: callee = @Elm_Kernel_Utils_cmp3
  // CHECK: func.func private @Elm_Kernel_Utils_cmp3(!eco.value, !eco.value) -> i64

  // Tag order is data, not position: region i handles tags[i]. These regions
  // are in GT, LT, EQ order and must be re-nested accordingly.
  func.func private @rw_permuted(%k: i64, %nk: i64, %l: !eco.value, %r: !eco.value) -> !eco.value {
    %o = eco.int.cmp_order %k, %nk : i64
    %res = eco.case %o : !eco.value [2, 0, 1] -> (!eco.value) {case_kind = "ctor"} {
      eco.yield %r : !eco.value
    }, {
      eco.yield %l : !eco.value
    }, {
      %e = eco.constant Empty : !eco.value
      eco.yield %e : !eco.value
    }
    eco.return %res : !eco.value
  }
  // CHECK-LABEL: @rw_permuted

  // Nothing anywhere in the output still materializes an Order and cases on
  // its constructor tag.
  // CHECK-NOT: cmp_order
  // CHECK-NOT: callee = @Elm_Kernel_Utils_compare}
  // CHECK-NOT: [0, 1, 2]
}
