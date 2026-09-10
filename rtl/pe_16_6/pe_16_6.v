module pe_16_6#(
   parameter  KERNEL_SIZE=3
)(
    input        clk,
    input        rstn,
    input        op,//0为pe_output=b_in*a_in;1为卷积数据复用模式
    input [17:0] right_a_in_last_line[0:5],
    input [17:0] buttom_a_in_last_line[0:15],//a为数据
    input [17:0] load_a_in[0:95],
    input [17:0] load_b_in[0:95],       //b为参数
    input        load_a_in_opt, 
    input        input_en,

    output [35:0] PE_output[0:95],
    output        out_type,
    output        output_en 
);
//|00|01|02|03|04|05|06|07|08|09|
//|10|11|12|13|14|15|16|17|18|19|
            //reg
reg         input_en_reg1;
reg         input_en_reg2;
reg         input_en_reg3;

reg  [2:0]  op_reg ;


            //wire
wire [17:0] right_a_in[0:95];
wire [17:0] buttom_a_in[0:95];
wire [17:0] left_a_out [0:95];
wire [17:0] top_a_out [0:95];
            //alwys
always @(posedge clk ) begin
    op_reg<={op_reg[1:0],op};
end
            //assign
assign output_en=input_en_reg2;
assign out_type=op_reg[2];
//right_a_in
generate
    for(genvar i=0;i<96;i++)begin
        if(i%16==15)begin
        assign   right_a_in[i]=right_a_in_last_line[i/16];
        end else begin
        assign  right_a_in[i]=left_a_out[i+1];
        end
    end
endgenerate
//buttom_a_in
generate
    for(genvar i=0;i<96;i++)begin
        if(i<80)begin
        assign  buttom_a_in[i]=top_a_out[i+16];
        end else begin
        assign  buttom_a_in[i]=buttom_a_in_last_line[i-80];
        end
    end
endgenerate
//input_en_reg;
always @(posedge clk ) begin
    input_en_reg1<=input_en;
    input_en_reg2<=input_en_reg1;
    input_en_reg3<=input_en_reg2;
end
generate
  for (genvar i = 0; i < 96; i++) begin : pe_gen
    pe #(
      .KERNEL_SIZE(KERNEL_SIZE)
    ) pe_inst (
      .clk             (clk),
      .rstn            (rstn),
      .op              (op),
      .right_a_in      (right_a_in[i]),
      .buttom_a_in     (buttom_a_in[i]),
      .load_a_in      (load_a_in[i]),
      .load_b_in      (load_b_in[i]),
      .load_a_in_opt  (load_a_in_opt),   
      .input_en        (input_en),
      .left_a_out      (left_a_out[i]),
      .top_a_out       (top_a_out[i]),
      .PE_output       (PE_output[i]),
      .output_en       ()
    );
  end
endgenerate

endmodule 