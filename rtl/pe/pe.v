module pe 
(
    input        clk,
    input        rstn,

    input   [2:0]     kernel_width,  
    input   [2:0]     kernel_height,

    input        op,//0为pe_output=b_in*a_in;1为卷积数据复用模式
    input        acc_en_pw, //在op为1时默认开启累加，但是在op为0时如需要累加需拉高acc_en_dw, 
    input        acc_clr,
    input [17:0] right_a_in,
    input [17:0] buttom_a_in,//a为数据
    input [17:0] load_a_in,
    input [17:0] load_b_in,       //b为参数
    input        load_a_in_opt, 
    input        input_en,

    output [17:0] left_a_out,
    output [17:0] top_a_out,

    output [47:0] PE_output,
    output        output_en
);
            //reg
reg [17:0]  input_reg_a[0:4];   // 垂直重用链，深度需 ≥ KMAX_W（最大抽头 kernel_width-1）
reg [17:0]  input_reg_b;
reg  [23:0]  load_a_in_opt_reg;
reg  [3:0]  acc_en_pw_reg;
reg  [3:0]  acc_clr_reg;
reg         buttom_a_in_opt;
reg         ce_reg1;
reg         ce_reg2;
reg         input_en_reg1;
reg         input_en_reg2;
reg  [4:0]  op_reg;
            //wire
wire         right_a_in_opt;
wire [47:0]  dsp_o;//DSP48 48-bit 主输出
            //assign
assign       right_a_in_opt=(op_reg[0]==1'b1)&&(!load_a_in_opt)&&(!buttom_a_in_opt);
assign       left_a_out=(right_a_in_opt==1'b1)?input_reg_a[0]:18'd0;
assign       top_a_out=(buttom_a_in_opt==1'b1)?input_reg_a[kernel_width-3'd1]:18'd0;
assign       output_en=input_en_reg2;

wire   [4:0] layer_en;
assign  layer_en[0]=kernel_height>=3'd2;
assign  layer_en[1]=kernel_height>=3'd3;
assign  layer_en[2]=kernel_height>=3'd4;
assign  layer_en[3]=kernel_height>=3'd5;
            //always
//right_a_in_opt


always @(posedge clk ) begin
     load_a_in_opt_reg<=  {load_a_in_opt_reg[22:0],load_a_in_opt&&op_reg[0]};
     acc_en_pw_reg    <={acc_en_pw_reg[2:0],acc_en_pw&&!op};
     acc_clr_reg<={acc_clr_reg[2:0],acc_clr};

end

wire load_opt_m0 = (kernel_width >= 3'd2) ? load_a_in_opt_reg[kernel_width-3'd2]
                                          : load_a_in_opt;

always @(posedge clk ) begin
    buttom_a_in_opt<= (layer_en[0]&&load_opt_m0)||
                      (layer_en[1]&&load_a_in_opt_reg[2*kernel_width-3'd2])||
                      (layer_en[2]&&load_a_in_opt_reg[3*kernel_width-3'd2])||
                      (layer_en[3]&&load_a_in_opt_reg[4*kernel_width-3'd2]);
end
//input_en_reg;op_reg[0]    

always @(posedge clk ) begin
    input_en_reg1<=input_en;
    input_en_reg2<=input_en_reg1;
    op_reg<={op_reg[3:0],op};
end

//input_reg_a[0];
always @(posedge clk ) begin
    if (!rstn) begin
        input_reg_a[0]<=18'd0;
    end else if (op_reg[0]) begin
        if(load_a_in_opt)begin
            input_reg_a[0]<=load_a_in;
        end else if(buttom_a_in_opt)begin
            input_reg_a[0]<=buttom_a_in;
        end else if(right_a_in_opt)begin
            input_reg_a[0]<=right_a_in;
        end
    end else begin
        if(load_a_in_opt)begin
            input_reg_a[0]<=load_a_in;
        end
        else 
            input_reg_a[0]<=18'd0;
    end
end
//input_reg_a[1:4]; 垂直重用链：每拍上移一级
integer m;
always @(posedge clk ) begin
    for (m=4; m>=1; m=m-1) input_reg_a[m]<=input_reg_a[m-1];
end

//input_reg_a
always @(posedge clk ) begin
    input_reg_b<=load_b_in;
end

//ce;
always @(posedge clk) begin
    ce_reg1<=input_en;
    ce_reg2<=ce_reg1;
end

            //inatance
EFX_DSP48 #(
    .MODE        ("NORMAL"),
    .SIGNED      (1'b1),      // 1=有符号 0=无符号
    .A_REG       (1'b1),      // 输入打拍，按需
    .B_REG       (1'b1),
    .P_REG       (1'b0),
    .M_SEL       ("P"),       // 加法器 A = 乘法结果
    .N_SEL       ("CONST0"),       // 加法器 B = 上一拍累加结果（反馈）
    .W_REG       (1'b0),      // ★ 累加寄存器使能（必须为1）
    .W_SEL       ("P"),       // 移位器输入取 W_p（累加结果）
    .O_REG       (1'b0),      // 输出是否再打一拍
    .OP_REG      (1'b1),
    .CASCOUT_SEL ("P"),
    .RST_SYNC    (1'b0),      // 0=异步复位 1=同步复位
    .W_REG_USE_RST(1'b1),     // 允许 RST 清零累加器
    .A_REG_USE_RST (1'b0),   // A/B/P/OP 不受 RST 影响，流水继续
    .B_REG_USE_RST (1'b0),
    .P_REG_USE_RST (1'b0),
    .OP_REG_USE_RST(1'b0),
    .CLK_POLARITY(1'b1),      // 上升沿
    .CE_POLARITY (1'b1),      // CE 高有效
    .RST_POLARITY(1'b1)       // RST 高有效
) u_dsp (
    .A          ({input_reg_a[0][17],input_reg_a[0]}),          // 19-bit 乘数
    .B          (input_reg_b),          // 18-bit 乘数
    .C          (18'd0),     
    .OP         (2'b00),      // 00=加（01=减）
    .SHIFT_ENA  (1'b0),       // 不锁存移位量
    .CLK        (clk),
    .CE         (ce_reg1),         // 累加使能（低=保持）
    .RST        (~rstn),        // 高有效，清零累加器
    .O          (dsp_o),    // 48-bit 累加结果
    .OVFL       (),       // 溢出标志
    .CASCIN     (48'd0),
    .CASCOUT    ()         // 不级联,悬空(VDB-9045要求CASCOUT只能悬空或接CASCIN)
);

reg signed [47:0] acc;
wire signed [48:0] sum ={acc[47],acc}+{dsp_o[47],dsp_o};
wire acc_en=(op_reg[2]&&!load_a_in_opt_reg[1])||(acc_en_pw_reg[2]&acc_en_pw_reg[3]);
always @(posedge clk ) begin
    if (!rstn) begin
        acc<=48'sd0;    
    end else if (acc_clr_reg[2]) begin
        acc<=dsp_o;
    end else if(acc_en)
        acc<=sum[47:0];
        else acc<=dsp_o;
end

assign PE_output=acc;




endmodule //pe