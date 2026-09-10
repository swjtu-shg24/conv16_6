module pe_16_6_conv_top(

  input pll_inst1_LOCKED,
  input pll_inst1_CLKOUT1,//200m
  input pll_inst1_CLKOUT0,//100m
  input pll_inst1_CLKOUT2, //9.23m
  
  output led

);
            //reg
reg  op;
reg  [17:0] wdata[0:143];
reg         wdata_en;
reg [17:0] load_b_in[0:99];
reg  start;
reg  rstn_reg;

            //wire
wire sys_clk_100mhz,sys_clk_200mhz,sys_clk_locked;
wire sys_rstn;
wire  rstn_rise;
  
wire [17:0] right_a_in_last_line[0:9];
wire [17:0] buttom_a_in_last_line[0:9];
wire [17:0] load_a_in[0:99];
  
wire load_a_in_opt;
wire input_en;
(* syn_keep = "true" *) wire [35:0] PE_output[0:99];
wire output_en;
            //assign
assign sys_clk_100mhz=pll_inst1_CLKOUT0;
assign sys_clk_200mhz=pll_inst1_CLKOUT1;
assign sys_clk_locked=pll_inst1_LOCKED;
assign led=PE_output[0][0]&&PE_output[1][0];
assign rstn_rise=sys_rstn&&!rstn_reg;
            //instace
  generate_resetn # (
    .P_RESET_CYCLE(10)
  )
  generate_resetn_inst (
    .i_sys_clk(sys_clk_200mhz),
    .i_pll_lock(sys_clk_locked),
    .o_sys_reset_n(sys_rstn)
  );


  feature_map_12_12  feature_map_12_12_inst (
    .clk(sys_clk_200mhz),
    .rstn(sys_rstn),
    .wdata(wdata),
    .wdata_en(wdata_en),
    .op(op),
    .start(start),
    .right_a_in_last_line(right_a_in_last_line),
    .buttom_a_in_last_line(buttom_a_in_last_line),
    .load_a_in(load_a_in),
    .load_a_in_opt(load_a_in_opt),
    .input_en(input_en)
  );
  pe_10_10 # (
    .KERNEL_SIZE(3)
  )
  pe_10_10_inst (
    .clk(sys_clk_200mhz),
    .rstn(sys_rstn),
    .op(op),
    .right_a_in_last_line(right_a_in_last_line),
    .buttom_a_in_last_line(buttom_a_in_last_line),
    .load_a_in(load_a_in),
    .load_b_in(load_b_in),
    .load_a_in_opt(load_a_in_opt),
    .input_en(input_en),
    .PE_output(PE_output),
    .output_en(output_en)
  );
// reg  op;
// reg  [17:0] wdata[0:143];
// reg         wdata_en;
// reg [17:0] load_b_in[0:99];
// reg  start;
always @(posedge sys_clk_200mhz ) begin
    if (!sys_rstn) begin
        op=1'b0;
        for(integer i=0;i<144;i++)begin
            wdata[i]<=18'd0;
        end
        wdata_en=1'b0;
        for(integer i=0;i<100;i++)begin
            load_b_in[i]<=18'd0;
        end
    end else if (rstn_rise) begin
        op=1'b1;
        for(integer i=0;i<144;i++)begin
            wdata[i]<=i+1'b1;
        end
        wdata_en=1'b1;
        for(integer i=0;i<100;i++)begin
            load_b_in[i]<=18'd1;
        end
    end else begin
        for(integer i=0;i<144;i++)begin
            wdata[i]<=18'b0;
        end
        wdata_en=1'b0;
    end
end
//rstn_reg
always @(posedge sys_clk_200mhz) begin
    rstn_reg<=sys_rstn;
end

endmodule