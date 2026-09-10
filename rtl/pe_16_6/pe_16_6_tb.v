`timescale 1ns/1ps
module pe_16_6_tb;

  //Ports
  reg clk;
  reg rstn;
  reg op;
  reg  [17:0] wdata[0:143];
  reg         wdata_en;
  wire [17:0] right_a_in_last_line[0:5];
  wire [17:0] buttom_a_in_last_line[0:15];
  wire [17:0] load_a_in[0:95];
  reg [17:0] load_b_in[0:95];
  reg  start;
  wire load_a_in_opt;
  wire input_en;
  wire [47:0] PE_output[0:95];
  wire output_en;
  wire out_type;

  feature_map_18_8  feature_map_18_8_inst (
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
  pe_16_6 pe_16_6_inst (
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
    .out_type(out_type),
    .output_en(output_en)
  );

always #10  clk = ! clk ;
//op拉高为复用数据，拉低为直接相乘
//关闭阵列：op拉高，不发start位
//完成一次复用卷积:op拉高，发送一次start脉冲，计算过程中，op不能拉低，start不能重复发送脉冲
//完成一次直接相乘： op拉低,需要同时加载计算数据(放在左上的16*6区域)
//数据可以加载与start位同时变换
initial begin
  clk=1'b0;rstn=1'b0;op=1;
  for (integer i=0; i<96;i++)begin
    load_b_in[i]=18'd1;
  end
  #100 
  //拉高复位
  @(posedge clk)begin
    rstn<=1'b1;
  end
  //第一次复用卷积
   @(posedge clk)begin
    op=1;
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
  //第二次复用卷积
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
  //插入一周期的不复用乘法
  @(posedge clk)begin
    op=0;
    wdata_en<=1'b1;   
    for (integer i=0; i<144;i++)begin
    wdata[i]<=i+3;
  end
  //第三次复用卷积
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
  repeat(10)begin
    @(posedge clk);
  end
  //直接乘法
   @(posedge clk)begin
    op=0;
    wdata_en<=1'b1;   
    for (integer i=0; i<144;i++)begin
    wdata[i]<=i+5;
  end
   end
      @(posedge clk)begin
    op=0;
    wdata_en<=1'b1;   
    for (integer i=0; i<144;i++)begin
    wdata[i]<=i+6;
  end
   end
      @(posedge clk)begin
    op=0;
    wdata_en<=1'b1;   
    for (integer i=0; i<144;i++)begin
    wdata[i]<=i+7;
  end
   end
      @(posedge clk)begin
    op=0;
    wdata_en<=1'b1;   
    for (integer i=0; i<144;i++)begin
    wdata[i]<=i+8;
  end
   end
      @(posedge clk)begin
    op=0;
    wdata_en<=1'b1;   
    for (integer i=0; i<144;i++)begin
    wdata[i]<=i+9;
  end
   end
      @(posedge clk)begin
    op=0;
    wdata_en<=1'b1;   
    for (integer i=0; i<144;i++)begin
    wdata[i]<=i+10;
  end
   end

  repeat(10)begin
    @(posedge clk);
  end
//第四次复用卷积
    @(posedge clk)begin
    op=1;start<=1'b1;
    wdata_en<=1'b1;   
    for (integer i=0; i<144;i++)begin
    wdata[i]<=i+11;
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
  end

endmodule
