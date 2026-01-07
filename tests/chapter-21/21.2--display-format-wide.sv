// Copyright (C) 2019-2021  The SymbiFlow Authors.
//
// Use of this source code is governed by a ISC-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/ISC
//
// SPDX-License-Identifier: ISC

/*
:name: display_format_wide
:description: $display formatting for wide integers
:tags: 21.2
:type: simulation elaboration parsing
:unsynthesizable: 1
*/
module top();

initial begin
  bit [127:0] x;
  int t;

  // Force a dynamic (non-constant-foldable) value dependency.
  t = $time;
  if (t != 0)
    x = 128'h0;
  else
    x = 128'h0123_4567_89ab_cdef_fedc_ba98_7654_3210;

  $display(":assert: ('%h' == '0123456789abcdeffedcba9876543210')", x);
  $display(":assert: ('%0h' == '123456789abcdeffedcba9876543210')", x);
end

endmodule

