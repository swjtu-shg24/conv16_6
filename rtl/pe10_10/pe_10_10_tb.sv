`timescale 1ns/1ps
module pe_10_10_tb;

  // Parameters
  localparam  KERNEL_SIZE = 3;

  //Ports
  reg clk;
  reg rstn;
  reg op;
  reg  [17:0] wdata[0:143];
  reg         wdata_en;
  wire [17:0] right_a_in_last_line[0:9];
  wire [17:0] buttom_a_in_last_line[0:9];
  wire [17:0] load_a_in[0:99];
  reg [17:0] load_b_in[0:99];
  reg  start;
  wire load_a_in_opt;
  wire input_en;
  wire [35:0] PE_output[0:99];
  wire output_en;

  feature_map_12_12  feature_map_12_12_inst (
    .clk(clk),
    .rstn(rstn),
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
    .KERNEL_SIZE(KERNEL_SIZE)
  )
  pe_10_10_inst (
    .clk(clk),
    .rstn(rstn),
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

always #10  clk = ! clk ;

initial begin
  clk=1'b0;rstn=1'b0;op=1;
  for (integer i=0; i<100;i++)begin
    load_b_in[i]=18'd1;
  end
  #100 
  @(posedge clk)begin
    rstn<=1'b1;
  end
   @(posedge clk)begin
    wdata_en<=1'b1;    start<=1'b1;
    for (integer i=0; i<144;i++)begin
    wdata[i]<=i+1;

  end
  end
    @(posedge clk)begin
    wdata_en<=1'b0;   start<=1'b0;
    for (integer i=0; i<144;i++)begin
    wdata[i]<=18'd0;
    end
  end
  repeat(7)begin
    @(posedge clk);
  end
  @(posedge clk)begin

    start=1;wdata_en<=1'b1;
    for (integer i=0; i<144;i++)begin
    wdata[i]<=i+2;
    end
  end
    @(posedge clk)begin
    start=0;wdata_en<=1'b0;
  end
  repeat(7)begin
    @(posedge clk);
  end
  @(posedge clk)begin
    op=0;
    wdata_en<=1'b1;   
    for (integer i=0; i<144;i++)begin
    wdata[i]<=i+3;
  end
   end
     @(posedge clk)begin
    op=1;start<=1'b1;
    wdata_en<=1'b1;   
    for (integer i=0; i<144;i++)begin
    wdata[i]<=i+4;
  end
   end
    @(posedge clk)begin
    start<=1'b0;
    wdata_en<=1'b0;   
    for (integer i=0; i<144;i++)begin
    wdata[i]<=18'd0;
  end
   end


  
end

endmodule
