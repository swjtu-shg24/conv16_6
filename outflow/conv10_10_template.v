
// Efinity Top-level template
// Version: 2026.1.132
// Date: 2026-08-25 22:42

// Copyright (C) 2013 - 2026 Efinix Inc. All rights reserved.

// This file may be used as a starting point for Efinity synthesis top-level target.
// The port list here matches what is expected by Efinity constraint files generated
// by the Efinity Interface Designer.

// To use this:
//     #1)  Save this file with a different name to a different directory, where source files are kept.
//              Example: you may wish to save as conv10_10.v
//     #2)  Add the newly saved file into Efinity project as design file
//     #3)  Edit the top level entity in Efinity project to:  conv10_10
//     #4)  Insert design content.


module conv10_10
(
  (* syn_peri_port = 0 *) input sys_clk_24mhz,
  (* syn_peri_port = 0 *) input pll_inst1_LOCKED,
  (* syn_peri_port = 0 *) input pll_inst1_CLKOUT1,
  (* syn_peri_port = 0 *) input pll_inst1_CLKOUT0,
  (* syn_peri_port = 0 *) input pll_inst1_CLKOUT2,
  (* syn_peri_port = 0 *) output led
);


endmodule

