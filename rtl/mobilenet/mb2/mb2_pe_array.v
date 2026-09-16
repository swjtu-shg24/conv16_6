//===========================================================================
// mb2_pe_array.v —— 10x10 PE 阵列（复用现有 rtl/pe/pe.v，48bit 输出）
//   连线与 rtl/pe10_10/pe_10_10.v 完全一致：
//     水平：右邻居的 left_a_out -> 本 PE 的 right_a_in；最右列由窗口注入
//     垂直：下邻居的 top_a_out  -> 本 PE 的 buttom_a_in；最下行由窗口注入
//===========================================================================
module mb2_pe_array (
    input  wire          clk,
    input  wire          rstn,
    input  wire          op,
    input  wire [17:0]   right_a_in_last_line [0:9],
    input  wire [17:0]   buttom_a_in_last_line[0:9],
    input  wire [17:0]   load_a_in            [0:99],
    input  wire [17:0]   load_b_in            [0:99],
    input  wire          load_a_in_opt,
    input  wire          input_en,
    output wire [47:0]   PE_output            [0:99],
    output wire          output_en
);

    wire [17:0] right_a_in  [0:99];
    wire [17:0] buttom_a_in [0:99];
    wire [17:0] left_a_out  [0:99];
    wire [17:0] top_a_out   [0:99];

    generate
        for (genvar i = 0; i < 100; i = i + 1) begin : g_lnk
            if (i % 10 == 9)
                assign right_a_in[i] = right_a_in_last_line[i/10];
            else
                assign right_a_in[i] = left_a_out[i+1];

            if (i < 90)
                assign buttom_a_in[i] = top_a_out[i+10];
            else
                assign buttom_a_in[i] = buttom_a_in_last_line[i-90];
        end
    endgenerate

    generate
        for (genvar i = 0; i < 100; i = i + 1) begin : g_pe
            pe u_pe (
                .clk            (clk),
                .rstn           (rstn),
                .kernel_width   (3'd3),
                .kernel_height  (3'd3),
                .op             (op),
                .right_a_in     (right_a_in[i]),
                .buttom_a_in    (buttom_a_in[i]),
                .load_a_in      (load_a_in[i]),
                .load_b_in      (load_b_in[i]),
                .load_a_in_opt  (load_a_in_opt),
                .input_en       (input_en),
                .left_a_out     (left_a_out[i]),
                .top_a_out      (top_a_out[i]),
                .PE_output      (PE_output[i]),
                .output_en      ()
            );
        end
    endgenerate

    assign output_en = 1'b0;   // 由 feature_map 的 input_en 直接观察即可

endmodule
