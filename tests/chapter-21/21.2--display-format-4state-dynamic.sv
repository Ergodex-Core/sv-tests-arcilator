// Copyright (C) 2019-2021  The SymbiFlow Authors.
//
// Use of this source code is governed by a ISC-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/ISC
//
// SPDX-License-Identifier: ISC

/*
:name: display_format_4state_dynamic
:description: $display/$sformatf formatting for dynamic 4-state integers
:tags: 21.2
:type: simulation elaboration parsing
:unsynthesizable: 1
*/
module top();

  logic [7:0] a;
  int t;
  int idx;

  initial begin
    // Force a dynamic (non-constant-foldable) value dependency.
    t = $time;
    if (t != 0)
      a = 8'h00;
    else
      a = 8'hAA;

    // Use a dynamic index so bit selects flow through dyn_extract_ref.
    idx = t;
    a[idx + 3] = 1'bx;
    a[idx + 2] = 1'bz;

    // `$display` formatting should preserve X/Z for dynamic values.
    $display(":assert: ('%b' == '1010xz10')", a);
    $display(":assert: ('%h' == 'ax')", a);
    $display(":assert: ('%o' == '2xx')", a);
    $display(":assert: ('%d' == 'x')", a);

    // `$sformatf` uses the same underlying formatting DAGs; keep it covered.
    $display(":assert: ('%s' == '1010xz10')", $sformatf("%b", a));
    $display(":assert: ('%s' == 'ax')", $sformatf("%h", a));
    $display(":assert: ('%s' == '2xx')", $sformatf("%o", a));
    $display(":assert: ('%s' == 'x')", $sformatf("%d", a));

    $finish;
  end

endmodule
