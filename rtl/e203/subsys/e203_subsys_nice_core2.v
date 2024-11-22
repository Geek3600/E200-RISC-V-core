/*
e203_subsys_nice_core模块为协处理模块，由E203的cpu模块驱动完成数据交互。
NICE模块的信号主要由CPU内部的三个模块处理，分为别：
(1)e203_ifu:取指令单元（取指令以及生成PC）
(2)e203_exu:执行单元(完成执行、存储操作，并提交写回）
(3)e203_lsu:存储器访问单元
nice_req_inst则主要涉及(1)(2)两个部分。
部分(1)：在e203_ifu模块中由e203_ifu_ifetch向e203_ifu_ift2icb发送PC地址来获得指令。随后e203_ifu_ift2icb通过ifu_rsp_instr信号回传指令。

随后e203_ifu_ifetch通过ifu_o_ir回传指令到e203_core.v中的e203_ifu模块。并同时传递给e203_exu模块的i_ir。e203_exu将其传递给e203_exu_alu的i_instr，并最终传递给e203_exu_nice模块，由该模块输出nice_req_inst信号指令给e203_subsys_nice_core协处理器。
*/
/*                                                                      
 Copyright 2018-2020 Nuclei System Technology, Inc.                
                                                                         
 Licensed under the Apache License, Version 2.0 (the "License");         
 you may not use this file except in compliance with the License.        
 You may obtain a copy of the License at                                 
                                                                         
     http://www.apache.org/licenses/LICENSE-2.0                          
                                                                         
  Unless required by applicable law or agreed to in writing, software    
 distributed under the License is distributed on an "AS IS" BASIS,       
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and     
 limitations under the License.                                          
 */

//=====================================================================
//
// Designer   : LZB
//
// Description:
//  The Module to realize a simple NICE core
//
// ====================================================================
`include "e203_defines.v"

`ifdef E203_HAS_NICE//{
module e203_subsysk_nice_core (
    // System	
    input                         nice_clk            ,
    input                         nice_rst_n	      ,
    output                        nice_active	      ,
    output                        nice_mem_holdup     ,//avoid memory read or write by other devices
//    output                      nice_rsp_err_irq,
    // Control cmd_req
    input                         nice_req_valid       ,//E203 send a nice request
    output                        nice_req_ready       ,//nice can receive request
    input  [`E203_XLEN-1:0]       nice_req_inst        ,//custom instruction
    input  [`E203_XLEN-1:0]       nice_req_rs1         ,//the register 1
    input  [`E203_XLEN-1:0]       nice_req_rs2         ,//the register 2
    // Control cmd_rsp	
    output                        nice_rsp_valid       ,//nice send response
    input                         nice_rsp_ready       ,//e203 can receive response
     //NICE接口信号中，有两个数据传输信号： nice_rsp_rdat 和 nice_icb_cmd_wdata。这两个信号对应不同的寄存器。
    output [`E203_XLEN-1:0]       nice_rsp_rdat        ,//compute result ,nice_rsp_rdat对应每一行的相加结果，且每次ROWSUM计算完成后均通过nice_rsp_rdat上传结果，这是通过RD寄存器，不会涉及memory的操作
    output                        nice_rsp_err         ,//nice has error
    // Memory lsu_req	
    output                        nice_icb_cmd_valid   ,//nice send a memory request
    input                         nice_icb_cmd_ready   ,//e203 can receive memory request
    output [`E203_ADDR_SIZE-1:0]  nice_icb_cmd_addr    ,//memory request address
    output                        nice_icb_cmd_read    ,//0:write 1:read
    output [`E203_XLEN-1:0]       nice_icb_cmd_wdata   ,//write data request，是NICE与memory之间传输的数据，首先读取RS寄存器中存储的内存地址，随后完成对应内存地址的数据读写
//    output [`E203_XLEN_MW-1:0]  nice_icb_cmd_wmask   ,
    output [1:0]                  nice_icb_cmd_size    ,//00:byte 01:half-word 10:word
    // Memory lsu_rsp	
    input                         nice_icb_rsp_valid   ,//e203 send memory response
    output                        nice_icb_rsp_ready   ,//nice can receive memory
    input  [`E203_XLEN-1:0]       nice_icb_rsp_rdata   ,//the data read from memory
    input                         nice_icb_rsp_err      //error during memory access

);

   localparam ROWBUF_DP = 4;
   localparam ROWBUF_IDX_W = 2;
   localparam ROW_IDX_W = 2;
   localparam COL_IDX_W = 4;
   localparam PIPE_NUM = 3;


// here we only use custom3: 
// CUSTOM0 = 7'h0b, R type
// CUSTOM1 = 7'h2b, R tpye
// CUSTOM2 = 7'h5b, R type
// CUSTOM3 = 7'h7b, R type

// RISC-V format  
//	.insn r  0x33,  0,  0, a0, a1, a2       0:  00c58533[ 	]+add [ 	]+a0,a1,a2
//	.insn i  0x13,  0, a0, a1, 13           4:  00d58513[ 	]+addi[ 	]+a0,a1,13
//	.insn i  0x67,  0, a0, 10(a1)           8:  00a58567[ 	]+jalr[ 	]+a0,10 (a1)
//	.insn s   0x3,  0, a0, 4(a1)            c:  00458503[ 	]+lb  [ 	]+a0,4(a1)
//	.insn sb 0x63,  0, a0, a1, target       10: feb508e3[ 	]+beq [ 	]+a0,a1,0 target
//	.insn sb 0x23,  0, a0, 4(a1)            14: 00a58223[ 	]+sb  [ 	]+a0,4(a1)
//	.insn u  0x37, a0, 0xfff                18: 00fff537[ 	]+lui [ 	]+a0,0xfff
//	.insn uj 0x6f, a0, target               1c: fe5ff56f[ 	]+jal [ 	]+a0,0 target
//	.insn ci 0x1, 0x0, a0, 4                20: 0511    [ 	]+addi[ 	]+a0,a0,4
//	.insn cr 0x2, 0x8, a0, a1               22: 852e    [ 	]+mv  [ 	]+a0,a1
//	.insn ciw 0x0, 0x0, a1, 1               24: 002c    [ 	]+addi[ 	]+a1,sp,8
//	.insn cb 0x1, 0x6, a1, target           26: dde9    [ 	]+beqz[ 	]+a1,0 target
//	.insn cj 0x1, 0x5, target               28: bfe1    [ 	]+j   [ 	]+0 targe

   
   // decode
   
   wire [6:0] opcode      = {7{nice_req_valid}} & nice_req_inst[6:0]; //opcode是前7位
   wire [2:0] rv32_func3  = {3{nice_req_valid}} & nice_req_inst[14:12];//rv32_func3为{14->12}
   wire [6:0] rv32_func7  = {7{nice_req_valid}} & nice_req_inst[31:25];//rv32_func7为{31->25}

//   wire opcode_custom0 = (opcode == 7'b0001011); 
//   wire opcode_custom1 = (opcode == 7'b0101011); 
//   wire opcode_custom2 = (opcode == 7'b1011011); 
   wire opcode_custom3 = (opcode == 7'b1111011); //NICE使用了custom3型的RISC-V指令

   wire rv32_func3_000 = (rv32_func3 == 3'b000); //func3相关
   wire rv32_func3_001 = (rv32_func3 == 3'b001); 
   wire rv32_func3_010 = (rv32_func3 == 3'b010); 
   wire rv32_func3_011 = (rv32_func3 == 3'b011); 
   wire rv32_func3_100 = (rv32_func3 == 3'b100); 
   wire rv32_func3_101 = (rv32_func3 == 3'b101); 
   wire rv32_func3_110 = (rv32_func3 == 3'b110); 
   wire rv32_func3_111 = (rv32_func3 == 3'b111); 

   wire rv32_func7_0000000 = (rv32_func7 == 7'b0000000); //func7相关
   wire rv32_func7_0000001 = (rv32_func7 == 7'b0000001); 
   wire rv32_func7_0000010 = (rv32_func7 == 7'b0000010); 
   wire rv32_func7_0000011 = (rv32_func7 == 7'b0000011); 
   wire rv32_func7_0000100 = (rv32_func7 == 7'b0000100); 
   wire rv32_func7_0000101 = (rv32_func7 == 7'b0000101); 
   wire rv32_func7_0000110 = (rv32_func7 == 7'b0000110); 
   wire rv32_func7_0000111 = (rv32_func7 == 7'b0000111); 

   
   // custom3:
   // Supported format: only R type here
   // Supported instr:
   //  1. custom3 lbuf: load data(in memory) to row_buf
   //     lbuf (a1)
   //     .insn r opcode, func3, func7, rd, rs1, rs2    
   //  2. custom3 sbuf: store data(in row_buf) to memory
   //     sbuf (a1)
   //     .insn r opcode, func3, func7, rd, rs1, rs2    
   //  3. custom3 acc rowsum: load data from memory(@a1), accumulate row datas and write back 
   //     rowsum rd, a1, x0
   //     .insn r opcode, func3, func7, rd, rs1, rs2    
   
   //定义三条自定义指令在custom3情况下与func3、func7的关系
   wire custom3_lbuf     = opcode_custom3 & rv32_func3_010 & rv32_func7_0000001; //lbuf读取rs1
   wire custom3_sbuf     = opcode_custom3 & rv32_func3_010 & rv32_func7_0000010; //lbuf读取rs1
   wire custom3_rowsum   = opcode_custom3 & rv32_func3_110 & rv32_func7_0000110; //lbuf读取rs1，写回rd

   
   //  multi-cyc op 
   //定义两个信号，分别代表协处理器指令和需要访问memory
   
   wire custom_multi_cyc_op = custom3_lbuf | custom3_sbuf | custom3_rowsum;
   // need access memory
   wire custom_mem_op = custom3_lbuf | custom3_sbuf | custom3_rowsum;
 
   
   // NICE FSM ，NICE内部对指令的调度使用状态机，有四个状态，空闲和三个指令状态
   
   parameter NICE_FSM_WIDTH = 2; //初始化状态
   parameter IDLE     = 2'd0; 
   parameter LBUF     = 2'd1; 
   parameter SBUF     = 2'd2; 
   parameter ROWSUM   = 2'd3; 

   //现态和次态
   wire [NICE_FSM_WIDTH-1:0] state_r;          //状态指针
   wire [NICE_FSM_WIDTH-1:0] nxt_state;        //下一状态
   wire [NICE_FSM_WIDTH-1:0] state_idle_nxt;   //下一状态为初始化IDLE
   wire [NICE_FSM_WIDTH-1:0] state_lbuf_nxt;   //下一状态为lbuf
   wire [NICE_FSM_WIDTH-1:0] state_sbuf_nxt;   //下一状态为sbuf
   wire [NICE_FSM_WIDTH-1:0] state_rowsum_nxt; //下一状态为rowsum行累加

   wire nice_req_hsked;    //与cpu握手信号，cpu发送指令
   wire nice_rsp_hsked;    //与cpu握手信号，向cpu发送结果
   wire nice_icb_rsp_hsked;//与memory握手信号
   wire illgel_instr = ~(custom_multi_cyc_op);//为1，没有输入指令；illgel_instr为0代表是协处理器指令，为1代表不是
     
   //定义状态离开使能信号，四个状态的和真实状态的，共5个
   wire state_idle_exit_ena;  //退出初始化状态使能
   wire state_lbuf_exit_ena;  //退出lbuf状态使能 
   wire state_sbuf_exit_ena;  //退出sbuf状态使能  
   wire state_rowsum_exit_ena;//退出rowsum行累加状态使能 
   wire state_ena;            //状态使能

   //定义现在是什么状态的四个信号
   wire state_is_idle     = (state_r == IDLE);  //state是idle时，当前状态是初始化
   wire state_is_lbuf     = (state_r == LBUF);  //state是lbuf时，当前状态是lbuf状态 
   wire state_is_sbuf     = (state_r == SBUF);  //state是sbuf时，当前状态是sbuf状态
   wire state_is_rowsum   = (state_r == ROWSUM);//state是rowsum时，当前状态是行累加状态 
   
   //状态转换
   //当前状态是初始化状态，且cpu请求握手成功，且当前没有指令在操作，则退出初始化状态
   assign state_idle_exit_ena = state_is_idle & nice_req_hsked & ~illgel_instr; 
   //判断初始化状态的下一个状态，输入指令是lbuf，进入LBUF状态。。。否则保持初始化。三个指令状态的次态，都为IDLE
   assign state_idle_nxt =  custom3_lbuf    ? LBUF   : 
                            custom3_sbuf    ? SBUF   :
                            custom3_rowsum  ? ROWSUM :
			    IDLE;

   wire lbuf_icb_rsp_hsked_last;//lbuf操作结束信号 
   //当前状态是lbuf，lbuf操作完成，则退出lbuf状态使能为1
   //给状态离开使能信号赋值，当现态为IDLE，并且（nice_req_hsked)，并且当前为三指令之一，state_idle_exit_ena为高
   assign state_lbuf_exit_ena = state_is_lbuf & lbuf_icb_rsp_hsked_last; 
   //现态为lbuf，并且(lbuf_icb_rsp_hsked_last)，state_lbuf_exit_ena为高
   assign state_lbuf_nxt = IDLE;//lbuf下一状态是idle，以下类似
   wire sbuf_icb_rsp_hsked_last; 
   assign state_sbuf_exit_ena = state_is_sbuf & sbuf_icb_rsp_hsked_last; 
   assign state_sbuf_nxt = IDLE;
   wire rowsum_done; 
   assign state_rowsum_exit_ena = state_is_rowsum & rowsum_done; 
   assign state_rowsum_nxt = IDLE;

   //次态赋值，当退出相应操作结束时状态使能为1时，下一个状态切换至IDLE初始化
   assign nxt_state =   ({NICE_FSM_WIDTH{state_idle_exit_ena   }} & state_idle_nxt   )
                      | ({NICE_FSM_WIDTH{state_lbuf_exit_ena   }} & state_lbuf_nxt   ) 
                      | ({NICE_FSM_WIDTH{state_sbuf_exit_ena   }} & state_sbuf_nxt   ) 
                      | ({NICE_FSM_WIDTH{state_rowsum_exit_ena }} & state_rowsum_nxt ) 
                      ;
   //状态转换使能，为四个使能的或。当退出相应操作使能为1时，将状态使能置为1
   assign state_ena =   state_idle_exit_ena | state_lbuf_exit_ena 
                      | state_sbuf_exit_ena | state_rowsum_exit_ena;
   //时序状态机，调用sirv_gnrl_dfflr，D触发器，实现状态机
   //该模块是一个buffer，当状态切换至使能为1时，输入下一个状态，打一拍后从state_r输出
   sirv_gnrl_dfflr #(NICE_FSM_WIDTH)   state_dfflr (state_ena, nxt_state, state_r, nice_clk, nice_rst_n);

   
   // instr EXU
   
   wire [ROW_IDX_W-1:0]  clonum = 2'b10;  // fixed clonum///01
   //wire [COL_IDX_W-1:0]  rownum;

    1. custom3_lbuf
   ///这里是一个lbuf的计数器
   wire [ROWBUF_IDX_W-1:0] lbuf_cnt_r;   //现在计数值，3个
   wire [ROWBUF_IDX_W-1:0] lbuf_cnt_nxt; //下一个计数值
   wire lbuf_cnt_clr;                    //计数清零，使能
   wire lbuf_cnt_incr;                   //计数增加，使能
   wire lbuf_cnt_ena;                    //计数，D触发器，使能
   wire lbuf_cnt_last;                   //计数到最后值
   wire lbuf_icb_rsp_hsked;              //状态机为lbuf，并且储存响应握手成功
   wire nice_rsp_valid_lbuf;             //状态机为lbuf，计数到最后值，E203发出储存响应信号
   wire nice_icb_cmd_valid_lbuf;         //状态机为lbuf，计数值小于最后值

   //信号赋值，
   //已知assign nice_icb_rsp_hsked = nice_icb_rsp_valid & nice_icb_rsp_ready;并且nice_icb_rsp_ready is 1'b1 always，所以nice_icb_rsp_hsked = nice_icb_rsp_valid
   assign lbuf_icb_rsp_hsked = state_is_lbuf & nice_icb_rsp_hsked; //当前状态为lbuf，储存响应握手
   assign lbuf_icb_rsp_hsked_last = lbuf_icb_rsp_hsked & lbuf_cnt_last; //，当前状态为lbuf，储存响应握手，计数为最后值
   assign lbuf_cnt_last = (lbuf_cnt_r == clonum); //即计数到最后值，也就是lbuf_cnt_r为clonum2‘b10
   //已知assign nice_req_hsked = nice_req_valid & nice_req_ready;所以lbuf_cnt_clr含义为当前指令为lbuf，命令请求握手
   assign lbuf_cnt_clr = custom3_lbuf & nice_req_hsked;
   assign lbuf_cnt_incr = lbuf_icb_rsp_hsked & ~lbuf_cnt_last;//当前状态为lbuf，储存响应握手，计数值不是最后值
   assign lbuf_cnt_ena = lbuf_cnt_clr | lbuf_cnt_incr;//当前指令为lbuf，命令请求握手；或者当前状态lbuf，储存指令握手，计数值不是最后值
   //当前指令lbuf，命令请求握手，lbuf_cnt_nxt归零；当前状态lbuf，储存响应握手，计数值不是最后值，lbuf_cnt_nxt为lbuf_cnt_r+1
   assign lbuf_cnt_nxt =   ({ROWBUF_IDX_W{lbuf_cnt_clr }} & {ROWBUF_IDX_W{1'b0}})
                         | ({ROWBUF_IDX_W{lbuf_cnt_incr}} & (lbuf_cnt_r + 1'b1) )
                         ;
   //D触发器构成时序计数器，时钟：nice_clk ; 复位信号：nice_rst_n ; 使能信号：lbuf_cnt_ena ;，输入数据lbuf_cnt_nxt ； 输出数据：lbuf_cnt_r
   sirv_gnrl_dfflr #(ROWBUF_IDX_W)   lbuf_cnt_dfflr (lbuf_cnt_ena, lbuf_cnt_nxt, lbuf_cnt_r, nice_clk, nice_rst_n);

   // nice_rsp_valid wait for nice_icb_rsp_valid in LBUF
   assign nice_rsp_valid_lbuf = state_is_lbuf & lbuf_cnt_last & nice_icb_rsp_valid;//当前状态为lbuf，计数值为最后值，E203发出储存响应信号

   // nice_icb_cmd_valid sets when lbuf_cnt_r is not full in LBUF
   assign nice_icb_cmd_valid_lbuf = (state_is_lbuf & (lbuf_cnt_r < clonum));//当前状态为lbuf，且现计数值小于最后值

   // 2. custom3_sbuf
   wire [ROWBUF_IDX_W-1:0] sbuf_cnt_r;   //当前计数值
   wire [ROWBUF_IDX_W-1:0] sbuf_cnt_nxt; //下个计数值
   wire sbuf_cnt_clr;
   wire sbuf_cnt_incr;                   //sbuf_cnt增加，使能
   wire sbuf_cnt_ena;                    //D触发器，使能
   wire sbuf_cnt_last;                   //当前计数值为最后值
   wire sbuf_icb_cmd_hsked;              //当前状态为sbuf，或(状态为IDLE且指令为sbuf)，储存握手成功
   wire sbuf_icb_rsp_hsked;              //当前状态为sbuf，储存响应握手成功
   wire nice_rsp_valid_sbuf;             //状态机为sbuf，计数到最后值，E203发出储存响应信号
   wire nice_icb_cmd_valid_sbuf;         //状态为sbuf，sbuf_cmd_cnt_r小于等于最后值，sbuf_cnt不是最后值
   wire nice_icb_cmd_hsked;              //储存请求握手成功

   assign sbuf_icb_cmd_hsked = (state_is_sbuf | (state_is_idle & custom3_sbuf)) & nice_icb_cmd_hsked;//当前状态为sbuf，或（idle状态指令为sbuf)，储存请求握手成功
   assign sbuf_icb_rsp_hsked = state_is_sbuf & nice_icb_rsp_hsked;//当前状态sbuf，储存响应握手
   assign sbuf_icb_rsp_hsked_last = sbuf_icb_rsp_hsked & sbuf_cnt_last;//当前状态sbuf，储存响应握手，计数值为最后值
   assign sbuf_cnt_last = (sbuf_cnt_r == clonum);//计数值为最后值
   //assign sbuf_cnt_clr = custom3_sbuf & nice_req_hsked;
   assign sbuf_cnt_clr = sbuf_icb_rsp_hsked_last;//就是sbuf_icb_rsp_hsked_last，当前状态sbuf，储存响应握手，计数值为最后值
   assign sbuf_cnt_incr = sbuf_icb_rsp_hsked & ~sbuf_cnt_last;//当前状态sbuf，储存响应握手，计数值不是最后值
   assign sbuf_cnt_ena = sbuf_cnt_clr | sbuf_cnt_incr; //当前状态sbuf，储存响应握手、
   //当前状态sbuf，储存响应握手，（计数值为最后值则为2'b00；否则为现在计数值+1）
   assign sbuf_cnt_nxt =   ({ROWBUF_IDX_W{sbuf_cnt_clr }} & {ROWBUF_IDX_W{1'b0}})
                         | ({ROWBUF_IDX_W{sbuf_cnt_incr}} & (sbuf_cnt_r + 1'b1) )
                         ;
   //D触发器构成时序计数器
   sirv_gnrl_dfflr #(ROWBUF_IDX_W)   sbuf_cnt_dfflr (sbuf_cnt_ena, sbuf_cnt_nxt, sbuf_cnt_r, nice_clk, nice_rst_n);

   // nice_rsp_valid wait for nice_icb_rsp_valid in SBUF
   //当前状态sbuf，计数值为最后值，E203发出储存响应信号
   assign nice_rsp_valid_sbuf = state_is_sbuf & sbuf_cnt_last & nice_icb_rsp_valid;
   
   //sbuf_cmd计数器
   wire [ROWBUF_IDX_W-1:0] sbuf_cmd_cnt_r;  //sbuf_cmd现计数值
   wire [ROWBUF_IDX_W-1:0] sbuf_cmd_cnt_nxt;//sbuf_cmd下个计数值 
   wire sbuf_cmd_cnt_clr;                   //当前状态sbuf，储存响应握手，sbuf计数值为最后值
   wire sbuf_cmd_cnt_incr;                  //当前状态为sbuf，或（idle状态指令为sbuf)，储存请求握手成功，subf_cmd计数值不是最后值
   wire sbuf_cmd_cnt_ena;                   //（当前状态sbuf，储存响应握手，sbuf计数值为最后值）或（当前状态为sbuf，或（idle状态指令为sbuf)，储存请求握手成功，subf_cmd计数值不是最后值）
   wire sbuf_cmd_cnt_last;                  //sbuf_cmd计数值为最后值

   assign sbuf_cmd_cnt_last = (sbuf_cmd_cnt_r == clonum); //sbuf_cmd计数值为最后值
   assign sbuf_cmd_cnt_clr = sbuf_icb_rsp_hsked_last;     //当前状态sbuf，储存响应握手，sbuf计数值为最后值
   assign sbuf_cmd_cnt_incr = sbuf_icb_cmd_hsked & ~sbuf_cmd_cnt_last;//当前状态为sbuf，或（idle状态指令为sbuf)，储存请求握手成功，subf_cmd计数值不是最后值
   assign sbuf_cmd_cnt_ena = sbuf_cmd_cnt_clr | sbuf_cmd_cnt_incr;//（当前状态sbuf，储存响应握手，sbuf计数值为最后值）或（当前状态为sbuf，或（idle状态指令为sbuf)，储存请求握手成功，subf_cmd计数值不是最后值）
   //当前状态sbuf，储存响应握手，sbuf计数为最后值，为2'b00；当前状态为sbuf，或（idle状态指令为sbuf)，储存请求握手成功，sbuf_cmd计数值不是最后值，为sbuf_cmd_cnt_r+1
   assign sbuf_cmd_cnt_nxt =   ({ROWBUF_IDX_W{sbuf_cmd_cnt_clr }} & {ROWBUF_IDX_W{1'b0}})
                             | ({ROWBUF_IDX_W{sbuf_cmd_cnt_incr}} & (sbuf_cmd_cnt_r + 1'b1) )
   
   //D触发器构成时序计数器                          ;
   sirv_gnrl_dfflr #(ROWBUF_IDX_W)   sbuf_cmd_cnt_dfflr (sbuf_cmd_cnt_ena, sbuf_cmd_cnt_nxt, sbuf_cmd_cnt_r, nice_clk, nice_rst_n);

   // nice_icb_cmd_valid sets when sbuf_cmd_cnt_r is not full in SBUF
   //当前状态sbuf，sbuf_cmd小于等于最后值，sbuf不等于最后值
   assign nice_icb_cmd_valid_sbuf = (state_is_sbuf & (sbuf_cmd_cnt_r <= clonum) & (sbuf_cnt_r != clonum));


    //3. custom3_rowsum
   // rowbuf counter 
   wire [ROWBUF_IDX_W-1:0] rowbuf_cnt_r; 
   wire [ROWBUF_IDX_W-1:0] rowbuf_cnt_nxt; 
   wire rowbuf_cnt_clr;
   wire rowbuf_cnt_incr;
   wire rowbuf_cnt_ena;
   wire rowbuf_cnt_last;
   wire rowbuf_icb_rsp_hsked;
   wire rowbuf_rsp_hsked;
   wire nice_rsp_valid_rowsum;

   //信号赋值
   assign rowbuf_rsp_hsked = nice_rsp_valid_rowsum & nice_rsp_ready;
   assign rowbuf_icb_rsp_hsked = state_is_rowsum & nice_icb_rsp_hsked;
   assign rowbuf_cnt_last = (rowbuf_cnt_r == clonum);
   assign rowbuf_cnt_clr = rowbuf_icb_rsp_hsked & rowbuf_cnt_last;
   assign rowbuf_cnt_incr = rowbuf_icb_rsp_hsked & ~rowbuf_cnt_last;
   assign rowbuf_cnt_ena = rowbuf_cnt_clr | rowbuf_cnt_incr;
   assign rowbuf_cnt_nxt =   ({ROWBUF_IDX_W{rowbuf_cnt_clr }} & {ROWBUF_IDX_W{1'b0}})
                           | ({ROWBUF_IDX_W{rowbuf_cnt_incr}} & (rowbuf_cnt_r + 1'b1))
                           ;
   //assign nice_icb_cmd_valid_rowbuf =   (state_is_idle & custom3_rowsum)
   //                                  | (state_is_rowsum & (rowbuf_cnt_r <= clonum) & (clonum != 0))
   //                                  ;

   //D触发器构成时序计数器
   sirv_gnrl_dfflr #(ROWBUF_IDX_W)   rowbuf_cnt_dfflr (rowbuf_cnt_ena, rowbuf_cnt_nxt, rowbuf_cnt_r, nice_clk, nice_rst_n);
  
   //rowsum的recieve data buffer
   // recieve data buffer, to make sure rowsum ops come from registers 
   wire rcv_data_buf_ena;
   wire rcv_data_buf_set;
   wire rcv_data_buf_clr;
   wire rcv_data_buf_valid;
   wire [`E203_XLEN-1:0] rcv_data_buf; 
   wire [ROWBUF_IDX_W-1:0] rcv_data_buf_idx; 
   wire [ROWBUF_IDX_W-1:0] rcv_data_buf_idx_nxt; 

   //信号赋值
   assign rcv_data_buf_set = rowbuf_icb_rsp_hsked;
   assign rcv_data_buf_clr = rowbuf_rsp_hsked;
   assign rcv_data_buf_ena = rcv_data_buf_clr | rcv_data_buf_set;
   assign rcv_data_buf_idx_nxt =   ({ROWBUF_IDX_W{rcv_data_buf_clr}} & {ROWBUF_IDX_W{1'b0}})
                                 | ({ROWBUF_IDX_W{rcv_data_buf_set}} & rowbuf_cnt_r        );

   //D触发器构成时序计数器，第一个是使能信号的一个时钟延迟，第二个是输入数据的缓冲，第三个是对rowbuf写入的序号
   sirv_gnrl_dfflr #(1)   rcv_data_buf_valid_dfflr (1'b1, rcv_data_buf_ena, rcv_data_buf_valid, nice_clk, nice_rst_n);
   sirv_gnrl_dfflr #(`E203_XLEN)   rcv_data_buf_dfflr (rcv_data_buf_ena, nice_icb_rsp_rdata, rcv_data_buf, nice_clk, nice_rst_n);
   sirv_gnrl_dfflr #(ROWBUF_IDX_W)   rowbuf_cnt_d_dfflr (rcv_data_buf_ena, rcv_data_buf_idx_nxt, rcv_data_buf_idx, nice_clk, nice_rst_n);

   // rowsum的累加器模块
   // rowsum accumulator 
   wire [`E203_XLEN-1:0] rowsum_acc_r;
   wire [`E203_XLEN-1:0] rowsum_acc_nxt;
   wire [`E203_XLEN-1:0] rowsum_acc_adder;
   wire rowsum_acc_ena;
   wire rowsum_acc_set;
   wire rowsum_acc_flg;
   wire nice_icb_cmd_valid_rowsum;
   wire [`E203_XLEN-1:0] rowsum_res;

   //rowsum的累加，信号赋值
   //rowsum_acc_flg，rcv_data_buf_idx非零，且上个周期的状态为rowsum时（储存响应握手或E203发出nice_rsp_ready信号）
   assign rowsum_acc_set = rcv_data_buf_valid & (rcv_data_buf_idx == {ROWBUF_IDX_W{1'b0}});//32'b0
   assign rowsum_acc_flg = rcv_data_buf_valid & (rcv_data_buf_idx != {ROWBUF_IDX_W{1'b0}});
   assign rowsum_acc_adder = rcv_data_buf + rowsum_acc_r; **************最重要的加法运算；assign <寄存器类型变量> = <赋值表达式>；****//
   assign rowsum_acc_ena = rowsum_acc_set | rowsum_acc_flg;
   assign rowsum_acc_nxt =   ({`E203_XLEN{rowsum_acc_set}} & rcv_data_buf)
                           | ({`E203_XLEN{rowsum_acc_flg}} & rowsum_acc_adder)
                           ;
   //D触发器构成时序，累加的时序操作
   sirv_gnrl_dfflr #(`E203_XLEN)   rowsum_acc_dfflr (rowsum_acc_ena, rowsum_acc_nxt, rowsum_acc_r, nice_clk, nice_rst_n);

   assign rowsum_done = state_is_rowsum & nice_rsp_hsked;
   assign rowsum_res  = rowsum_acc_r;  //rowsum finishes when the last acc data is added to rowsum_acc_r  

    nice_icb_cmd_valid sets when rcv_data_buf_idx is not full in LBUF 
   assign nice_rsp_valid_rowsum = state_is_rowsum & (rcv_data_buf_idx == clonum) & ~rowsum_acc_flg;

   // nice_icb_cmd_valid sets when rcv_data_buf_idx is not full in LBUF
   assign nice_icb_cmd_valid_rowsum = state_is_rowsum & (rcv_data_buf_idx < clonum) & ~rowsum_acc_flg;

   // rowbuf，rowbuf是数据缓存，lbuf和rowsum会写入，sbuf会读出
   // rowbuf access list:
   //  1. lbuf will write to rowbuf, write data comes from memory, data length is defined by clonum 
   //  2. sbuf will read from rowbuf, and store it to memory, data length is defined by clonum 
   //  3. rowsum will accumulate data, and store to rowbuf, data length is defined by clonum 
   wire [`E203_XLEN-1:0] rowbuf_r [ROWBUF_DP-1:0];   //4个32位的数据
   wire [`E203_XLEN-1:0] rowbuf_wdat [ROWBUF_DP-1:0];//4个32位的数据
   wire [ROWBUF_DP-1:0]  rowbuf_we;                  //4位宽的数据
   wire [ROWBUF_IDX_W-1:0] rowbuf_idx_mux;           //rowbuf的序号选择
   wire [`E203_XLEN-1:0] rowbuf_wdat_mux;            //rowbuf的写入数据选择
   wire rowbuf_wr_mux;                               //rowbuf的写入信号选择
   //wire [ROWBUF_IDX_W-1:0] sbuf_idx; 
   
   // lbuf write to rowbuf
   wire [ROWBUF_IDX_W-1:0] lbuf_idx = lbuf_cnt_r;          //lbuf写入的序号，写入序号选择，为lbuf_cnt_r，即lbuf计数的时序输出，当前的计数值，从0到2
   wire lbuf_wr = lbuf_icb_rsp_hsked;                      //lbuf写入的使能，写入使能，为lbuf_icb_rsp_hsked，即当前状态为lbuf，储存响应握手
   wire [`E203_XLEN-1:0] lbuf_wdata = nice_icb_rsp_rdata;  //lbuf写入的数据，写入数据，外部输入的从memory读取的数据

   // rowsum write to rowbuf(column accumulated data)
   wire [ROWBUF_IDX_W-1:0] rowsum_idx = rcv_data_buf_idx;  //rowsum写入的序号，写入序号选择，为rcv_data_buf_idx，当前的计数值，从0到2
   wire rowsum_wr = rcv_data_buf_valid;                    //rowsum写入的使能，写入使能，为rcv_data_buf-valid，是rcv_data_buf_ena缓冲一个时钟
   wire [`E203_XLEN-1:0] rowsum_wdata = rowbuf_r[rowsum_idx] + rcv_data_buf; //	rowsum写入的数据，写入数据，为rowbuf_r当前数据与rcv_data_buf的加和

   // rowbuf write mux
   //写入数据选择
   assign rowbuf_wdat_mux =   ({`E203_XLEN{lbuf_wr  }} & lbuf_wdata  )
                            | ({`E203_XLEN{rowsum_wr}} & rowsum_wdata)
                            ;
   //写入使能选择，lbuf_wr与rowsum_wr的或
   assign rowbuf_wr_mux   =  lbuf_wr | rowsum_wr;
   //写入序号选择，若lbuf_wr为高，则为luf_idx，若rowsum_wr为高，则为rowsum_dix
   assign rowbuf_idx_mux  =   ({ROWBUF_IDX_W{lbuf_wr  }} & lbuf_idx  )
                            | ({ROWBUF_IDX_W{rowsum_wr}} & rowsum_idx)
                            ;  
   
   //D触发器构成时序
   //实例化4个输入的32位的D触发器
   // rowbuf inst
   genvar i;
   generate 
     for (i=0; i<ROWBUF_DP; i=i+1) begin:gen_rowbuf
       //rowbuf_we为使能信号，为rowbuf_wr_mux与一个表达式的与，i的低2位与rowbuf_idx_mux相等才可以
       assign rowbuf_we[i] =   (rowbuf_wr_mux & (rowbuf_idx_mux == i[ROWBUF_IDX_W-1:0]))
                             ;
       //rowbuf_wdat为输入数据，使能时为rowbuf_wdat_mux
       assign rowbuf_wdat[i] =   ({`E203_XLEN{rowbuf_we[i]}} & rowbuf_wdat_mux   )
                               ;
  
       sirv_gnrl_dfflr #(`E203_XLEN) rowbuf_dfflr (rowbuf_we[i], rowbuf_wdat[i], rowbuf_r[i], nice_clk, nice_rst_n);
     end
   endgenerate

    //mem aacess addr management，memory的地址
   wire [`E203_XLEN-1:0] maddr_acc_r; 
   assign nice_icb_cmd_hsked = nice_icb_cmd_valid & nice_icb_cmd_ready;   //储存请求握手
   // custom3_lbuf，lbuf，访问memory的使能
   //（当前状态为idle，命令为lbuf，并且储存请求握手）或（当前状态lbuf，储存请求握手）
   //wire [`E203_XLEN-1:0] lbuf_maddr    = state_is_idle ? nice_req_rs1 : maddr_acc_r ; 
   wire lbuf_maddr_ena    =   (state_is_idle & custom3_lbuf & nice_icb_cmd_hsked)
                            | (state_is_lbuf & nice_icb_cmd_hsked)
                            ;

   // custom3_sbuf ，sbuf，访问memory的使能
   //（当前状态为idle，命令为sbuf，并且储存请求握手）或（当前状态sbuf，储存请求握手）
   //wire [`E203_XLEN-1:0] sbuf_maddr    = state_is_idle ? nice_req_rs1 : maddr_acc_r ; 
   wire sbuf_maddr_ena    =   (state_is_idle & custom3_sbuf & nice_icb_cmd_hsked)
                            | (state_is_sbuf & nice_icb_cmd_hsked)
                            ;

   // custom3_rowsum，	rowsum，访问memory的使能
   //（当前状态为idle，命令为rowsum，并且储存请求握手）或（当前状态rowsum，储存请求握手）
   //wire [`E203_XLEN-1:0] rowsum_maddr  = state_is_idle ? nice_req_rs1 : maddr_acc_r ; 
   wire rowsum_maddr_ena  =   (state_is_idle & custom3_rowsum & nice_icb_cmd_hsked)
                            | (state_is_rowsum & nice_icb_cmd_hsked)
                            ;

   // maddr acc 
   //wire  maddr_incr = lbuf_maddr_ena | sbuf_maddr_ena | rowsum_maddr_ena | rbuf_maddr_ena;
   //（当前状态为idle，命令有效，并且储存请求握手）或（当前状态非idle，储存请求握手）
   wire  maddr_ena = lbuf_maddr_ena | sbuf_maddr_ena | rowsum_maddr_ena;//访问memory的使能
   //当前状态为idle，命令为有效，并且储存请求握手
   wire  maddr_ena_idle = maddr_ena & state_is_idle;//访问memory的使能，且当前状态为idle
  
  //当前状态为idle，命令为有效，并且储存请求握手，为寄存器1值，否则为maddr_acc_r.且每次读写的内存地址逐次加4
//maddr_acc_r即为rs1寄存器地址每次加4，这是因为32/8=4，对于32位数据，在memory中需要占据4个字节。
   wire [`E203_XLEN-1:0] maddr_acc_op1 = maddr_ena_idle ? nice_req_rs1 : maddr_acc_r; // not reused
   //32/8 = 4，所以每次要加4
   wire [`E203_XLEN-1:0] maddr_acc_op2 = maddr_ena_idle ? `E203_XLEN'h4 : `E203_XLEN'h4; 
   //下一个地址，为当前地址+4
   wire [`E203_XLEN-1:0] maddr_acc_next = maddr_acc_op1 + maddr_acc_op2;//操作数1，操作数2
   wire  maddr_acc_ena = maddr_ena;  //	访问memory的使能，为（当前状态为idle，命令有效，并且储存请求握手）或（当前状态非idle，储存请求握手）
   
   //D触发器，使能信号：maddr_acc_ena，输入数据：maddr_acc_next，输出：maddr_acc_r
   sirv_gnrl_dfflr #(`E203_XLEN)   maddr_acc_dfflr (maddr_acc_ena, maddr_acc_next, maddr_acc_r, nice_clk, nice_rst_n);

   
   // Control cmd_req
   
   assign nice_req_hsked = nice_req_valid & nice_req_ready;//命令请求握手
   //nice发出的命令请求握手信号，当前状态是idle，且指令有效，则为nice_icb_cmd_ready，否则为1'b1
   assign nice_req_ready = state_is_idle & (custom_mem_op ? nice_icb_cmd_ready : 1'b1);

   
   // Control cmd_rsp
   
   assign nice_rsp_hsked = nice_rsp_valid & nice_rsp_ready; //命令响应握手
   assign nice_icb_rsp_hsked = nice_icb_rsp_valid & nice_icb_rsp_ready;//储存响应握手
   //（当前状态lbuf，lbuf计数值为最后值，E203发出储存响应信号）或（当前状态sbuf，sbuf计数值为最后值，E203发出储存响应信号）或（当前状态rowsum，rcv_data_buf_idx计数值为最后值，rowsum_acc_flg为低）或（rcv_data_buf_idx非零，且上个周期的状态为rowsum时（储存响应握手或E203发出nice_rsp_ready信号））
   assign nice_rsp_valid = nice_rsp_valid_rowsum | nice_rsp_valid_sbuf | nice_rsp_valid_lbuf;
   assign nice_rsp_rdat  = {`E203_XLEN{state_is_rowsum}} & rowsum_res;//当前状态为rowsum时为rowsum_res

   // memory access bus error
   //assign nice_rsp_err_irq  =   (nice_icb_rsp_hsked & nice_icb_rsp_err)
   //                          | (nice_req_hsked & illgel_instr)
   //                          ; 
   assign nice_rsp_err   =   (nice_icb_rsp_hsked & nice_icb_rsp_err);//储存响应握手且在访问memory时出错

   
   // Memory lsu，memory相关
   
   // memory access list:
   //  1. In IDLE, custom_mem_op will access memory(lbuf/sbuf/rowsum)
   //  2. In LBUF, it will read from memory as long as lbuf_cnt_r is not full
   //  3. In SBUF, it will write to memory as long as sbuf_cnt_r is not full
   //  3. In ROWSUM, it will read from memory as long as rowsum_cnt_r is not full
   //assign nice_icb_rsp_ready = state_is_ldst_rsp & nice_rsp_ready; 
   // rsp always ready
   assign nice_icb_rsp_ready = 1'b1; //始终为1'b1
   wire [ROWBUF_IDX_W-1:0] sbuf_idx = sbuf_cmd_cnt_r; 

   //（当前状态为idle且E203发出nice_req_valid且指令有效）或（状态lbuf，lbuf计数值小于最后值）或（状态sbuf，sbuf_cmd小于等于最后值且sbuf计数值不是最后值）或（状态rowsum，rcv_data_buf计数值小于最后值，且（rcv_data_buf_idx非零，且上个周期的状态为rowsum时（储存响应握手或E203发出nice_rsp_ready信号））
   assign nice_icb_cmd_valid =   (state_is_idle & nice_req_valid & custom_mem_op)
                              | nice_icb_cmd_valid_lbuf
                              | nice_icb_cmd_valid_sbuf
                              | nice_icb_cmd_valid_rowsum
                              ;
   assign nice_icb_cmd_addr  = (state_is_idle & custom_mem_op) ? nice_req_rs1 :
                              maddr_acc_r;//（状态idle且命令有效）为寄存器1，否则为maddr_acc_r
   assign nice_icb_cmd_read  = (state_is_idle & custom_mem_op) ? (custom3_lbuf | custom3_rowsum) : 
                              state_is_sbuf ? 1'b0 : 
                              1'b1;//（状态idle且为lbuf或rowsumz指令，为1，为sbuf指令，为0），或者为sbuf状态为0，否则为1
   assign nice_icb_cmd_wdata = (state_is_idle & custom3_sbuf) ? rowbuf_r[sbuf_idx] :
                              state_is_sbuf ? rowbuf_r[sbuf_idx] : 
                              `E203_XLEN'b0; //（状态idle，sbuf指令）或subf状态，为rowbuf_r[sbuf_idx]，否则为0

   //assign nice_icb_cmd_wmask = {`sirv_XLEN_MW{custom3_sbuf}} & 4'b1111;
   assign nice_icb_cmd_size  = 2'b10;//为2，代表4字节32位宽数据
   assign nice_mem_holdup    =  state_is_lbuf | state_is_sbuf | state_is_rowsum; //为非idle状态，访问memory锁

   
   // nice_active
   
   assign nice_active = state_is_idle ? nice_req_valid : 1'b1;

endmodule
`endif//}

