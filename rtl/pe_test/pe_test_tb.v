`timescale 1ns/1ps
module pe_test_tb;

  // Parameters

  //Ports
  reg  clk;
  reg  rstn;
  reg  acc_clr;
  reg  acc_en;
  reg [17:0] a_in;
  reg [17:0] b_in;
  reg input_en;
  wire signed [47:0] dsp_o;
  wire  ovfl;

  pe_test  pe_test_inst (
    .clk(clk),
    .rstn(rstn),
    .acc_clr(acc_clr),
    .acc_en(acc_en),
    .a_in(a_in),
    .ce(input_en),
    .b_in(b_in),
    .dsp_o(dsp_o),
    .ovfl(ovfl)
  );

always #10  clk = ! clk ;

initial begin
    a_in<=18'd0;
    b_in<=18'd0;
    clk=1'b0;
    input_en<=1'b0;
    rstn=1'b0;
    acc_clr=1'b1;
    acc_en=1'b1;
end

initial begin
    repeat(10) @(posedge clk);
    @(posedge clk)begin
        rstn<=1'b1;
        acc_clr=1'b1;
    end
    @(posedge clk)begin
        rstn<=1'b1;
        acc_clr=1'b0;
    end
    repeat(5) @(posedge clk);
    @(posedge clk)begin
        input_en<=1'b1;
        a_in<=18'd1;
        b_in<=18'd2;
    end
    @(posedge clk)begin
        input_en<=1'b1;
        a_in<=18'd2;
        b_in<=18'd2;
    end
    @(posedge clk)begin
        input_en<=1'b1;
        a_in<=18'd3;
        b_in<=18'd2;
    end
    @(posedge clk)begin
        a_in<=18'd4;
        b_in<=18'd2;
    end
        @(posedge clk)begin
        acc_en<=1'b0;
        a_in<=18'd5;
        b_in<=18'd2;
    end
    @(posedge clk)begin

        a_in<=18'd6;
        b_in<=18'd2;
    end
    @(posedge clk)begin
         acc_en<=1'b1;
        a_in<=18'd7;
        b_in<=18'd2;
    end
    @(posedge clk)begin
        a_in<=18'd8;
        b_in<=18'd2;
    end



end


endmodule