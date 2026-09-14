module pe_16_6_conv_top(

  input pll_inst1_LOCKED,
  input pll_inst1_CLKOUT1,//200m
  input pll_inst1_CLKOUT0,//100m
  input pll_inst1_CLKOUT2, //9.23m

  output led

);
            //reg
reg  op;
reg  [17:0]   wdata[0:143];
reg           wdata_en;
// reg  [17:0]   load_b_in[0:95];       // 16x6 = 96 个 PE（旧版 100）
reg           start;
reg  [2:0]    kernel_width;
reg  [2:0]    kernel_height;

            //wire
wire sys_clk_100mhz,sys_clk_200mhz,sys_clk_locked;
wire sys_rstn;
wire start_ready;
wire busy;
reg   [17:0]  kernel_data [0:8];  // 3x3 = 9 个权重（旧版 36）


wire [17:0] right_a_in_last_line[0:5];    // 6 行（旧版 10）
wire [17:0] buttom_a_in_last_line[0:15];  // 16 列（旧版 10）
wire [17:0] load_a_in[0:95];              // 96 个 PE（旧版 100）

// wire load_a_in_opt;
// wire input_en;
// (* syn_keep = "true" *) wire [47:0] PE_output[0:95];   // 48bit（旧版 36bit）
(* syn_keep = "true" *) wire [47:0] result_data[0:95];   // 48bit（旧版 36bit）
// wire output_en;
// wire out_type;
            //assign
assign sys_clk_100mhz=pll_inst1_CLKOUT0;
assign sys_clk_200mhz=pll_inst1_CLKOUT1;
assign sys_clk_locked=pll_inst1_LOCKED;
// assign led=PE_output[0][0]|PE_output[1][0];
assign led=result_data[0][0]|result_data[1][0];
            //instace
  generate_resetn # (
    .P_RESET_CYCLE(10)
  )
  generate_resetn_inst (
    .i_sys_clk(sys_clk_200mhz),
    .i_pll_lock(sys_clk_locked),
    .o_sys_reset_n(sys_rstn)
  );

  // feature_map_param # (
  //   .ARRAY_ROWS(6), .ARRAY_COLS(16), .KMAX_H(3), .KMAX_W(3)
  // )
  // feature_map_inst (
  //   .clk(sys_clk_200mhz),
  //   .rstn(sys_rstn),
  //   .wdata(wdata),
  //   .wdata_en(wdata_en),
  //   .op(op),
  //   .kernel_width(kernel_width),
  //   .kernel_height(kernel_height),
  //   .start(start),
  //   .right_a_in_last_line(right_a_in_last_line),
  //   .buttom_a_in_last_line(buttom_a_in_last_line),
  //   .load_a_in(load_a_in),
  //   .load_a_in_opt(load_a_in_opt),
  //   .input_en(input_en)
  // );

  // pe_16_6 # (
  //   .KERNEL_SIZE(3),
  //   .KERNEL_H(3),      // 阵列支持的最大核高
  //   .KERNEL_W(3)       // 阵列支持的最大核宽
  // )
  // pe_16_6_inst (
  //   .clk(sys_clk_200mhz),
  //   .rstn(sys_rstn),
  //   .op(op),
  //   .right_a_in_last_line(right_a_in_last_line),
  //   .buttom_a_in_last_line(buttom_a_in_last_line),
  //   .load_a_in(load_a_in),
  //   .load_b_in(load_b_in),
  //   .kernel_width(kernel_width),
  //   .kernel_height(kernel_height),
  //   .load_a_in_opt(load_a_in_opt),
  //   .input_en(input_en),
  //   .PE_output(PE_output),
  //   .out_type(out_type),
  //   .output_en(output_en)
  // );

  localparam [2:0] 
      S_PREPARE   = 3'd0, 
      S_SEND      = 3'd1, 
      S_RECEIVE   = 3'd2, 
      S_DONE      = 3'd3;
      
    reg  [2:0]  state,
                next_state;

  wire result_valid;
  wire result_ready = 1'b1; // always ready to accept results 

  reg [17:0] saved_data [0:95];
  reg done;

  integer i;

  always @(posedge sys_clk_200mhz, negedge sys_rstn) begin
    if (!sys_rstn) begin
      state <= S_PREPARE;

      start         <= 1'b0;
      op            <= 1'b1;
      kernel_width  <= 3'd3;
      kernel_height <= 3'd3;
      done          <= 1'b0;

      for (i=0;i<144;i=i+1) wdata[i]     <= 18'd0;
      for (i=0;i<9;i=i+1) kernel_data[i] <= 17'd0;
      for (i=0;i<96;i=i+1) saved_data[i] <= 18'd0;
    end else begin
      state <= next_state;

      case (state)
        S_PREPARE: begin
          for (i=0;i<144;i=i+1) wdata[i]     <= i + 1;
          for (i=0;i<9;i=i+1) kernel_data[i] <= 18'd1;
          op            <= 1'b1;
          kernel_width  <= 3'd3;
          kernel_height <= 3'd3;
          start <= 1'b1;
        end
        S_SEND:
          start <= 1'b0;
        S_RECEIVE: begin
          if (result_valid && result_ready) begin
            for (i=0;i<96;i=i+1) saved_data[i] <= result_data[i];
            done <= 1'b1;
          end 
        end
        S_DONE: 
          done <= 1'b0;
        default: begin
          start <= 1'b0;
          done  <= 1'b0;
        end
      endcase
    end
  end

  always_comb begin : state_transition
    case (state) 
      S_PREPARE: begin
        next_state = S_SEND;
      end
      S_SEND: begin
        if (start && start_ready) 
          next_state = S_RECEIVE;
      end
      S_RECEIVE: begin
        if (result_valid && result_ready)
          next_state = S_DONE;
      end
      S_DONE: begin
        next_state = S_DONE;
      end
      default: begin
        next_state = S_PREPARE;
      end
    endcase
  end

  conv16_6_core  conv16_6_core_inst (
    .clk(sys_clk_200mhz),
    .rstn(sys_rstn),
    .start(start),
    .op(op),
    .start_ready(start_ready),
    .busy(busy),
    .kernel_height(kernel_height),
    .kernel_width(kernel_width),
    .tile_data(wdata),
    .kernel_data(kernel_data),
    .result_data(result_data),
    .result_valid(result_valid),
    .result_ready(result_ready)
  );




// integer i;
// always @(posedge sys_clk_200mhz) begin
//   if (!sys_rstn) begin
//     state         <= 3'd0;
//     op            <= 1'b1;
//     wdata_en      <= 1'b0;
//     start         <= 1'b0;
//     kernel_width  <= 3'd3;
//     kernel_height <= 3'd3;
//     for (i=0;i<144;i=i+1) wdata[i]     <= 18'd0;
//     // for (i=0;i<96;i=i+1)  load_b_in[i] <= 18'd0;
//     for (i=0;i<9;i=i+1)  kernel_data[i] <= 18'd0;
//   end else begin
//     case (state)
//       3'd0: begin
//         op         <= 1'b1;
//         wdata_en   <= 1'b1;
//         start      <= 1'b0;
//         for (i=0;i<144;i=i+1) wdata[i]     <= i + 1;
//         // for (i=0;i<96;i=i+1)  load_b_in[i] <= 18'd1;
//         for (i=0;i<9;i=i+1)  kernel_data[i] <= 18'd1;
//         state      <= 3'd1;
//       end
//       3'd1: begin
//         start <= 1'b1;
//         state <= 3'd2;
//       end
//       3'd2: begin
//         start <= 1'b0;
//         state <= 3'd3;
//       end
//       default: begin
//         start    <= 1'b0;
//         wdata_en <= 1'b1;
//       end
//     endcase
//   end
// end

endmodule
