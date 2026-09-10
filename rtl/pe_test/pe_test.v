`timescale 1ns/1ps

module pe_test (
    input  wire               clk,
    input  wire               rstn,  
    input  wire               ce,    
    input  wire               acc_clr,   
    input  wire               acc_en,    
    input  wire        [17:0] a_in,      
    input  wire        [17:0] b_in,      
    output wire signed [47:0] dsp_o,     
    output wire               ovfl       
    
);
            //reg

reg  [1:0]  acc_en_reg;
always @(posedge clk ) begin
    acc_en_reg<={acc_en_reg[0],acc_en};
end
wire acc_en_fact =acc_en_reg[0]&&acc_en_reg[1];

            //inatance
EFX_DSP48 #(
    .MODE        ("NORMAL"),
    .SIGNED      (1'b1),      
    .A_REG       (1'b1),      
    .B_REG       (1'b1),
    .P_REG       (1'b0),
    .M_SEL       ("P"),       
    .N_SEL       ("CASCIN"),  
    .W_REG       (1'b0),      
    .W_SEL       ("X"),       
    .O_REG       (1'b1),      
    .OP_REG      (1'b1),
    .CASCOUT_SEL ("W"),
    .RST_SYNC    (1'b0),      
    .W_REG_USE_RST(1'b0),     
    .A_REG_USE_RST (1'b0),   
    .B_REG_USE_RST (1'b0),
    .P_REG_USE_RST (1'b0),
    .OP_REG_USE_RST(1'b0),
    .O_REG_USE_RST (1'b1),
    .CLK_POLARITY(1'b1),     
    .CE_POLARITY (1'b1),     
    .RST_POLARITY(1'b1)      
) u_dsp (
    .A          ({1'b0, a_in}),
    .B          (b_in),          
    .C          (18'd0),      
    .OP         (2'b00),      
    .SHIFT_ENA  (1'b0),       
    .CLK        (clk),
    .CE         (ce),
    .RST        (~rstn | acc_clr),  
    .O          (dsp_o),  
    .OVFL       (ovfl),       
    .CASCIN     (acc_en_fact ? dsp_o : 48'd0),
    .CASCOUT    ()         
);






endmodule //pe_test