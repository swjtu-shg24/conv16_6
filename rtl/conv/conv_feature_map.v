module conv_feature_map(
    input  wire          clk,
    input  wire          rstn,
    input  wire  [7:0]  wdata    [0:143],
    input  wire          wdata_en,
    input  wire          op,
    input  wire          start,   //复用数据卷积首位开始信�?只能9周期拉高一次，不复用数据该信号拉低
    
    output wire  [7:0]  right_a_in_last_line[0:9],
    output wire  [7:0]  buttom_a_in_last_line[0:9],//a为数�?
    output wire  [7:0]  load_a_in[0:99],
    output wire          load_a_in_opt, 
    output wire          input_en
);
            //reg   feature_map 
reg [7:0]  feature_map [0:143];
reg [8: 0]  start_reg;
reg         input_en_reg;
reg         op_reg;
            //wire
wire [5:0]  right_a_in_opt;
wire [1:0]  buttom_a_in_opt;
            //asign
assign      load_a_in_opt=start_reg[0]||!op_reg;  
assign      right_a_in_opt={start_reg[8:7],start_reg[5:4],start_reg[2:1]}; 
assign      buttom_a_in_opt={start_reg[6],start_reg[3]};
assign      input_en=input_en_reg;
generate
    for (genvar i=0;i<100;i++)begin
        assign load_a_in[i]=feature_map[(i/10)*12+i%10];
    end
endgenerate  
generate
    for (genvar i=0;i<10;i++)begin
        assign buttom_a_in_last_line[i]=
            (buttom_a_in_opt==2'd1)?feature_map[120+i]:
            (buttom_a_in_opt==2'd2)?feature_map[132+i]:
            8'd0;
    end
endgenerate
generate
    for(genvar i=0;i<10;i++)begin
        assign right_a_in_last_line[i]=
                (right_a_in_opt==6'b000001)?feature_map[12*i+10]:
                (right_a_in_opt==6'b000010)?feature_map[12*i+11]:
                (right_a_in_opt==6'b000100)?feature_map[12*i+22]:
                (right_a_in_opt==6'b001000)?feature_map[12*i+23]:
                (right_a_in_opt==6'b010000)?feature_map[12*i+34]:
                (right_a_in_opt==6'b100000)?feature_map[12*i+35]:
                8'd0;
    end
endgenerate
    
            //always
//feature_map
always @(posedge clk ) begin
    if (!rstn) begin
        for(int i=0;i<144;i++)begin
            feature_map[i]<=8'd0;
        end
    end else if (wdata_en) begin
        for(int i=0;i<144;i++)begin
            feature_map[i]<=wdata[i];
        end
    end
        else
        for(int i=0;i<144;i++)begin
            feature_map[i]<=feature_map[i];
        end   
end
//start_reg;
always @(posedge clk ) begin
    if (!rstn) begin
        start_reg<=9'd0;
    end else if(start)begin
        start_reg<=9'd1;
    end
    else begin
        start_reg<={start_reg[7:0],1'b0};
    end        
end
//input_en_reg
always @(posedge clk ) begin
    if (!rstn) begin
        input_en_reg<=1'b0;
    end else if ((start&&op)||(!op)) begin
        input_en_reg<=1'b1;
    end else if (right_a_in_opt[5])begin
        input_en_reg<=1'b0;
    end
end
//op_reg;
always @(posedge clk ) begin
   op_reg<=op;
end





endmodule
