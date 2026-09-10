module feature_map_18_8(
    input  wire          clk,
    input  wire          rstn,
    input  wire  [17:0]  wdata    [0:143],
    input  wire          wdata_en,
    input  wire          op,
    input   [2:0]     kernel_width,  
    input   [2:0]     kernel_height,  
    input  wire          start,   //脉冲
    
    output wire  [17:0]  right_a_in_last_line[0:5],
    output wire  [17:0]  buttom_a_in_last_line[0:15],//a为数据
    output wire  [17:0]  load_a_in[0:95],
    output wire          load_a_in_opt, 
    output wire          input_en
);
            //reg   feature_map 
reg [17:0]  feature_map [0:143];
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
    for (genvar i=0;i<96;i++)begin
        assign load_a_in[i]=feature_map[(i/16)*18+i%16];
    end
endgenerate  
generate
    for (genvar i=0;i<16;i++)begin
        assign buttom_a_in_last_line[i]=
            (buttom_a_in_opt==2'd1)?feature_map[108+i]:
            (buttom_a_in_opt==2'd2)?feature_map[126+i]:
            18'd0;
    end
endgenerate
generate
    for(genvar i=0;i<6;i++)begin
        assign right_a_in_last_line[i]=
                (right_a_in_opt==6'b000001)?feature_map[18*i+16]:
                (right_a_in_opt==6'b000010)?feature_map[18*i+17]:
                (right_a_in_opt==6'b000100)?feature_map[18*i+34]:
                (right_a_in_opt==6'b001000)?feature_map[18*i+35]:
                (right_a_in_opt==6'b010000)?feature_map[18*i+52]:
                (right_a_in_opt==6'b100000)?feature_map[18*i+53]:
                18'd0;
    end
endgenerate
    
            //always
//feature_map
always @(posedge clk ) begin
    if (!rstn) begin
        for(int i=0;i<144;i++)begin
            feature_map[i]<=18'd0;
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