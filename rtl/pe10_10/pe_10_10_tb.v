`timescale 1ns/1ps
module pe_10_10_tb;

`timescale 1ns/1ps

`define K_3x3;


`ifdef  K_2x2
  `define K_KH   2
  `define K_KW   2
  `define K_WAIT 2
`elsif K_1x2
  `define K_KH   1
  `define K_KW   2
  `define K_WAIT 0
`elsif K_2x1
  `define K_KH   2
  `define K_KW   1
  `define K_WAIT 0
`elsif K_1x3
  `define K_KH   1
  `define K_KW   3
  `define K_WAIT 1
`elsif K_3x1
  `define K_KH   3
  `define K_KW   1
  `define K_WAIT 1
`elsif K_3x2
  `define K_KH   3
  `define K_KW   2
  `define K_WAIT 4
`elsif K_2x3
  `define K_KH   2
  `define K_KW   3
  `define K_WAIT 4
`elsif K_3x3
  `define K_KH   3
  `define K_KW   3
  `define K_WAIT 7
`else
  // 默认走 3x3
  `define K_KH   3
  `define K_KW   3
  `define K_WAIT 7
`endif
  localparam integer KH      = `K_KH;
  localparam integer KW      = `K_KW;
  localparam integer WAIT    = `K_WAIT;
  localparam integer P       = KH*KW;

  localparam integer KMAX_H  = 3;                
  localparam integer KMAX_W  = 3;                
  localparam integer FM_COLS = 10 + KMAX_W - 1;  
  localparam integer FM_ROWS = 10  + KMAX_H - 1;  
  localparam integer FM_N    = FM_COLS*FM_ROWS;  

  //Ports
  reg clk;
  reg rstn;
  reg op;
  reg acc_en_pw;
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
  pe_10_10  pe_10_10_inst (
    .clk(clk),
    .rstn(rstn),
    .op(op),
    .acc_en_pw(acc_en_pw),
    .right_a_in_last_line(right_a_in_last_line),
    .buttom_a_in_last_line(buttom_a_in_last_line),
    .load_a_in(load_a_in),
    .load_b_in(load_b_in),
    .kernel_width        (KW[2:0]),
    .kernel_height       (KH[2:0]),
    .load_a_in_opt(load_a_in_opt),
    .input_en(input_en),
    .PE_output(PE_output),
    .output_en(output_en)
  );

always #10  clk = ! clk ;

//-------------------------------------------------------------------------
  // 激励
  //-------------------------------------------------------------------------
  integer i;
initial begin
  clk=1'b0;rstn=1'b0;op=1;acc_en_pw=1'b0;
  for (i=0; i<100;i=i+1)begin
    load_b_in[i]=18'd1;
  end
  for (i=0; i<FM_N;i=i+1)begin
    wdata[i]=18'd0;
  end
  wdata_en=1'b0; start=1'b0;


  #100
  //拉高复位
  @(posedge clk)begin
    rstn<=1'b1;
  end

  //================ 第一次复用卷积 (数据 = i+1) ================
   @(posedge clk)begin
    op=1;
    wdata_en<=1'b1;    start<=1'b1;
    for (i=0; i<FM_N;i=i+1)begin
        wdata[i]<=i+1;
  end
  end
    @(posedge clk)begin
    wdata_en<=1'b0;   start<=1'b0;
    for (i=0; i<FM_N;i=i+1)begin
    wdata[i]<=18'd0;
    end
  end
  repeat(WAIT)begin              
    @(posedge clk);
  end

  //================ 第二次复用卷积 (数据 = i+2) ================
  @(posedge clk)begin
    op=1;
    start=1;wdata_en<=1'b1;
    for (i=0; i<FM_N;i=i+1)begin
    wdata[i]<=i+2;
    end
  end
    @(posedge clk)begin
    start=0;wdata_en<=1'b0;
    for (i=0; i<FM_N;i=i+1)begin
    wdata[i]<=18'd0;
    end
  end
  repeat(WAIT)begin
    @(posedge clk);
  end

  //================ 插入周期的不复用乘法 
  @(posedge clk)begin
    op=0;acc_en_pw=1'b1;//累加
    wdata_en<=1'b1;
    for (i=0; i<FM_N;i=i+1)begin
    wdata[i]<=i+3;
  end
  end
    @(posedge clk)begin
    op=0;acc_en_pw=1'b1;//累加
    wdata_en<=1'b1;
    for (i=0; i<FM_N;i=i+1)begin
    wdata[i]<=i+4;
  end
  end
    @(posedge clk)begin
    op=0;acc_en_pw=1'b0;//不累加
    wdata_en<=1'b1;
    for (i=0; i<FM_N;i=i+1)begin
    wdata[i]<=i+5;
  end
  end

  //================ 第三次复用卷积 
     @(posedge clk)begin
    op=1;start<=1'b1;
    wdata_en<=1'b1;
    for (i=0; i<FM_N;i=i+1)begin
    wdata[i]<=i+6;
  end
   end
    @(posedge clk)begin
    start<=1'b0;
    wdata_en<=1'b0;
    for (i=0; i<FM_N;i=i+1)begin
    wdata[i]<=18'd0;
  end
  end
  repeat(WAIT)begin
    @(posedge clk);
  end

  //================ 直接乘法 
   @(posedge clk)begin
    op=0;acc_en_pw=1'b1;//累加
    wdata_en<=1'b1;
    for (i=0; i<FM_N;i=i+1)begin
    wdata[i]<=i+7;
  end
   end
      @(posedge clk)begin
    op=0;acc_en_pw=1'b1;//累加
    wdata_en<=1'b1;
    for (i=0; i<FM_N;i=i+1)begin
    wdata[i]<=i+8;
  end
   end
      @(posedge clk)begin
    op=0;acc_en_pw=1'b1;//累加
    wdata_en<=1'b1;
    for (i=0; i<FM_N;i=i+1)begin
    wdata[i]<=i+9;
  end
   end
      @(posedge clk)begin
    op=0;acc_en_pw=1'b1;//累加
    wdata_en<=1'b1;
    for (i=0; i<FM_N;i=i+1)begin
    wdata[i]<=i+10;
  end
   end
      @(posedge clk)begin
    op=0;acc_en_pw=1'b0;//不累加
    wdata_en<=1'b1;
    for (i=0; i<FM_N;i=i+1)begin
    wdata[i]<=i+11;
  end
   end
      @(posedge clk)begin
    op=0;acc_en_pw=1'b0;//不累加
    wdata_en<=1'b1;
    for (i=0; i<FM_N;i=i+1)begin
    wdata[i]<=i+12;
  end
   end

  //================ 第四次复用卷积 
    @(posedge clk)begin
    op=1;start<=1'b1;
    wdata_en<=1'b1;
    for (i=0; i<FM_N;i=i+1)begin
    wdata[i]<=i+13;
  end
   end
    @(posedge clk)begin
    start<=1'b0;
    wdata_en<=1'b0;
    for (i=0; i<FM_N;i=i+1)begin
    wdata[i]<=18'd0;
  end
   end
  repeat(30)begin
    @(posedge clk);
  end

  $finish;
end

endmodule