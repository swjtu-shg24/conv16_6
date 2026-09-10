module pe_test_top(
    input sys_clk_96m,
    input sys_pll_lock,

    output led

);
wire sys_rstn;
generate_resetn # (
    .P_RESET_CYCLE(50)
  )
  generate_resetn_inst (
    .i_sys_clk(sys_clk_96m),
    .i_pll_lock(sys_pll_lock),
    .o_sys_reset_n(sys_rstn)
  );

reg   acc_clr;
reg   [17:0] a_in;
reg   [17:0] b_in;

reg   input_en;
reg   acc_en;  

reg [31:0] cnt;
always @(posedge sys_clk_96m ) begin
    if (!sys_rstn) begin
        cnt<=32'd0;
        acc_clr<=1'b0;
    end else begin
        acc_clr<=1'b0;
        cnt<=cnt+1'b1;
        acc_en<=cnt[0];
        a_in<=cnt[17:0];
        b_in<=cnt[17:0];
        input_en<=1'b1;
    end
end


wire  [47:0]    dsp_o;

assign led=dsp_o[0];
  pe_test  pe_test_inst (
    .clk(sys_clk_96m),
    .rstn(sys_rstn),
    .acc_clr(acc_clr),
    .acc_en(acc_en),
    .a_in(a_in),
    .ce(input_en),
    .b_in(b_in),
    .dsp_o(dsp_o),
    .ovfl()
  );

endmodule
