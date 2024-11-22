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
module e203_subsys_nice_core (
    // System	
    input                         nice_clk             ,
    input                         nice_rst_n	          ,
    output                        nice_active	      ,
    output                        nice_mem_holdup	  ,
//    output                        nice_rsp_err_irq	  ,
    // Control cmd_req
    input                         nice_req_valid       ,
    output                        nice_req_ready       ,
    input  [`E203_XLEN-1:0]       nice_req_inst        ,
    input  [`E203_XLEN-1:0]       nice_req_rs1         ,
    input  [`E203_XLEN-1:0]       nice_req_rs2         ,
    // Control cmd_rsp	
    output                        nice_rsp_valid       ,
    input                         nice_rsp_ready       ,
    output [`E203_XLEN-1:0]       nice_rsp_rdat        ,//协处理器的计算结果，发给主处理器，写数据到寄存器
    output                        nice_rsp_err    	  ,
    // Memory lsu_req	
    output                        nice_icb_cmd_valid   ,
    input                         nice_icb_cmd_ready   ,
    output [`E203_ADDR_SIZE-1:0]  nice_icb_cmd_addr    ,
    output                        nice_icb_cmd_read    ,
    output [`E203_XLEN-1:0]       nice_icb_cmd_wdata   ,  //协处理器发给主处理器的要写到存储器的数据
//    output [`E203_XLEN_MW-1:0]     nice_icb_cmd_wmask   ,  // 
    output [1:0]                  nice_icb_cmd_size    ,
    // Memory lsu_rsp	
    input                         nice_icb_rsp_valid   ,
    output                        nice_icb_rsp_ready   ,
    input  [`E203_XLEN-1:0]       nice_icb_rsp_rdata   , // 主处理器从存储器中读出来，发给协处理器的数据，从存储器读回来的数据
    input                         nice_icb_rsp_err	

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

  //====================================EAI指令译码================================================
   // decode
   wire [6:0] opcode      = {7{nice_req_valid}} & nice_req_inst[6:0];//提取opcode
   wire [2:0] rv32_func3  = {3{nice_req_valid}} & nice_req_inst[14:12];//提取func3
   wire [6:0] rv32_func7  = {7{nice_req_valid}} & nice_req_inst[31:25];//提取func7

  //   wire opcode_custom0 = (opcode == 7'b0001011); 
  //   wire opcode_custom1 = (opcode == 7'b0101011); 
  //   wire opcode_custom2 = (opcode == 7'b1011011); 
   wire opcode_custom3 = (opcode == 7'b1111011); //匹配opcode确认为custom3自定义指令

   wire rv32_func3_000 = (rv32_func3 == 3'b000); //匹配func3
   wire rv32_func3_001 = (rv32_func3 == 3'b001); 
   wire rv32_func3_010 = (rv32_func3 == 3'b010); 
   wire rv32_func3_011 = (rv32_func3 == 3'b011); 
   wire rv32_func3_100 = (rv32_func3 == 3'b100); 
   wire rv32_func3_101 = (rv32_func3 == 3'b101); 
   wire rv32_func3_110 = (rv32_func3 == 3'b110); 
   wire rv32_func3_111 = (rv32_func3 == 3'b111); 

   wire rv32_func7_0000000 = (rv32_func7 == 7'b0000000); //匹配func7
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
   wire custom3_lbuf     = opcode_custom3 & rv32_func3_010 & rv32_func7_0000001; //判断是否是custom3_lbuf指令
   wire custom3_sbuf     = opcode_custom3 & rv32_func3_010 & rv32_func7_0000010; 
   wire custom3_rowsum   = opcode_custom3 & rv32_func3_110 & rv32_func7_0000110; 
   //  multi-cyc op 
   wire custom_multi_cyc_op = custom3_lbuf | custom3_sbuf | custom3_rowsum;//判断是否是协处理器指令
   // need access memory
   wire custom_mem_op = custom3_lbuf | custom3_sbuf | custom3_rowsum;//判断是否需要访问内存
  //====================================EAI指令译码================================================


  
  //===================================NICE FSM相关信号定义===================================================
   //NICE状态机有四个状态，分别是一个空闲状态和三个指令状态
   parameter NICE_FSM_WIDTH = 2;                  //D触发器重载参数（DW）
   parameter IDLE     = 2'd0;                     //IDLE状态
   parameter LBUF     = 2'd1;                     //LBUF状态
   parameter SBUF     = 2'd2;                     //SBUF状态
   parameter ROWSUM   = 2'd3;                     //ROWSUM状态
 
   wire [NICE_FSM_WIDTH-1:0] state_r;             //当前状态，D触发器的输出状态（当前状态）
   wire [NICE_FSM_WIDTH-1:0] nxt_state;           //下一状态，D触发器的输入状态（下一状态）
   wire [NICE_FSM_WIDTH-1:0] state_idle_nxt;      //IDLE状态的下一状态
   wire [NICE_FSM_WIDTH-1:0] state_lbuf_nxt;      //LBUF状态的下一状态
   wire [NICE_FSM_WIDTH-1:0] state_sbuf_nxt;      //SBUF状态的下一状态
   wire [NICE_FSM_WIDTH-1:0] state_rowsum_nxt;    //ROWSUM状态的下一状态
 
   wire nice_req_hsked;                           //与cpu握手成功，协处理器已接cpu发来的指令
   wire nice_rsp_hsked;                           //与cpu握手成功，协处理器以及向cpu已发送计算结果
   wire nice_icb_rsp_hsked;                       //与memory握手成功，已接收反馈，有可能是读存储器反馈，可有可能是写存储器反馈
   wire illgel_instr = ~(custom_multi_cyc_op);    //0：代表是协处理器指令 1：代表非协处理器指令

  //定义状态离开使能信号
   wire state_idle_exit_ena;                      //退出IDLE状态使能信号
   wire state_lbuf_exit_ena;                      //退出LBUF状态使能信号
   wire state_sbuf_exit_ena;                      //退出SBUF状态使能信号
   wire state_rowsum_exit_ena;                     //退出ROWSUM状态使能信号
   wire state_ena;                                //D触发器的状态使能输入
  
  //定义当前正在处于什么状态的信号
   wire state_is_idle     = (state_r == IDLE);    //当前状态是IDLE状态
   wire state_is_lbuf     = (state_r == LBUF);    //当前状态是LBUF状态
   wire state_is_sbuf     = (state_r == SBUF);    //当前状态是SBUF状态
   wire state_is_rowsum   = (state_r == ROWSUM);  //当前状态是ROWSUM状态
  //===================================NICE FSM相关信号定义===================================================



  //===============================IDLE状态退出==================================================
   assign state_idle_exit_ena = state_is_idle & nice_req_hsked & ~illgel_instr; //如果当前状态是IDLE状态，与cpu握手成功，已接收指令，是协处理器指令，则使能退出IDLE状态
   assign state_idle_nxt =  custom3_lbuf    ? LBUF   :   //IDLE状态的下一状态是LBUF或SBUF或ROWSUM
                            custom3_sbuf    ? SBUF   :
                            custom3_rowsum  ? ROWSUM :
			                                        IDLE   ;
  //===============================IDLE状态退出==================================================



  //===============================LBUF状态退出===================================================
   wire lbuf_icb_rsp_hsked_last; //LBUF操作操作结束信号
   assign state_lbuf_exit_ena = state_is_lbuf & lbuf_icb_rsp_hsked_last; //如果当前状态是LBUF状态，LBUF指令操作结束信号为1, 则退出LBUF状态
   assign state_lbuf_nxt = IDLE;  //LBUF的下一状态是IDLE状态
  //===============================LBUF状态退出===================================================



  //================================SBUF状态退出====================================================
   wire sbuf_icb_rsp_hsked_last; //SBUF指令操作结束信号
   assign state_sbuf_exit_ena = state_is_sbuf & sbuf_icb_rsp_hsked_last; //如果当前状态是SBUF状态，SBUF指令操作结束信号为1,则退出SBUF状态
   assign state_sbuf_nxt = IDLE; //SBUF的下一状态是IDLE状态
  //================================SBUF状态退出====================================================



  //==============================ROWSUM状态退出======================================================
   wire rowsum_done; //ROWSUM指令操作结束信号
   assign state_rowsum_exit_ena = state_is_rowsum & rowsum_done; //如果当前是ROWSUM状态，ROWSUM操作结束,则退出ROWSUM状态
   assign state_rowsum_nxt = IDLE;  //ROWSUM下一状态是IDLE
  //==============================ROWSUM状态退出======================================================



  //================================决定下一状态=======================================================
  //D触发器的输入状态（下一状态），由当前退出的指令种类，以及退出指令指定的下一状态确定
   assign nxt_state =   ({NICE_FSM_WIDTH{state_idle_exit_ena   }} & state_idle_nxt   )
                      | ({NICE_FSM_WIDTH{state_lbuf_exit_ena   }} & state_lbuf_nxt   ) 
                      | ({NICE_FSM_WIDTH{state_sbuf_exit_ena   }} & state_sbuf_nxt   ) 
                      | ({NICE_FSM_WIDTH{state_rowsum_exit_ena }} & state_rowsum_nxt );
  //================================决定下一状态=======================================================



  //=================================触发器状态打拍===================================================
  //D触发器的状态使能输入由是否有指令退出使能决定
   assign state_ena =   state_idle_exit_ena | state_lbuf_exit_ena 
                      | state_sbuf_exit_ena | state_rowsum_exit_ena;
  //例化D触发器，重载参数DW，初始化状态为IDLE，当state_ena为1时，打一拍，nxt_state赋值给state_r，低电平复位（sirv_gnrl_dffs.v）
  //打拍的作用
   sirv_gnrl_dfflr #(NICE_FSM_WIDTH)   state_dfflr (state_ena, nxt_state, state_r, nice_clk, nice_rst_n);
  //=================================触发器状态打拍===================================================


  //=========================================指令EXU===============================================
  //=========================================指令EXU===============================================
  //=========================================指令EXU===============================================
   // instr EXU
   wire [ROW_IDX_W-1:0]  clonum = 2'b10;  // fixed clonum 计数到2
   //wire [COL_IDX_W-1:0]  rownum;

  //===============================LBUF指令控制信号生成==============================
   wire [ROWBUF_IDX_W-1:0] lbuf_cnt_r;    //D触发器的输出当前计数值
   wire [ROWBUF_IDX_W-1:0] lbuf_cnt_nxt;  //D触发器的输入下一计数值
   wire lbuf_cnt_clr;                     //清零标志
   wire lbuf_cnt_incr;                    //计数标志
   wire lbuf_cnt_ena;                     //D触发器的输入计数使能
   wire lbuf_cnt_last;                    //是否计到最后一个数
   wire lbuf_icb_rsp_hsked;               //IBUF状态下与memory握手成功，已接收反馈信号
   wire nice_rsp_valid_lbuf;              //IBUF状态的反馈cpu请求信号
   wire nice_icb_cmd_valid_lbuf;          //IBUF状态的读写memory请求信号

  //LBUF状态下，与memory握手成功，已接收存储器读反馈，表示已经开始读存储器数据
   assign lbuf_icb_rsp_hsked = state_is_lbuf & nice_icb_rsp_hsked;

  //计到最后一个数，IBUF状态下与memory握手成功，已接收反馈，使能LBUF指令操作结束信号，last, wait lbuf_cnt_last
  //使能LBUF指令操作结束信号，当前正在读存储器数据，并且已经读到所需的最后一个数据，可以结束读取
   assign lbuf_icb_rsp_hsked_last = lbuf_icb_rsp_hsked & lbuf_cnt_last;

  //D触发器的输出当前计数值=2,则计到最后一个数
   assign lbuf_cnt_last = (lbuf_cnt_r == clonum);

  //与cpu握手成功，接收指令，指令是custom3_lbuf，则清零, first
  //刚接收到lbuf指令，并且协处理器已经与主处理器握手成功后，首先将计数器清零，准备读存储器
   assign lbuf_cnt_clr = custom3_lbuf & nice_req_hsked;

  // IBUF状态下与memory握手成功，已接收反馈，但未计到最后一个数，则一直计数
  // 正在读存储器数据lbuf_icb_rsp_hsked=1，但是还没读到所需的数据数量时~lbuf_cnt_last=1，则继续计数
   assign lbuf_cnt_incr = lbuf_icb_rsp_hsked & ~lbuf_cnt_last;

  //D触发器的输入计数使能由清零信号和计数信号确定
  //清零表示准备开始计数，计数信号表示正在计数，均使能D触发器
   assign lbuf_cnt_ena = lbuf_cnt_clr | lbuf_cnt_incr;

  //D触发器的输入下一计数值由清零信号和计数信号确定，计数器在这里
   assign lbuf_cnt_nxt =   ({ROWBUF_IDX_W{lbuf_cnt_clr }} & {ROWBUF_IDX_W{1'b0}})
                         | ({ROWBUF_IDX_W{lbuf_cnt_incr}} & (lbuf_cnt_r + 1'b1) )
                         ;
  // 例化D触发器，重载参数DW，初始化数为0，当lbuf_cnt_ena为1时，打一拍，lbuf_cnt_nxt赋值给lbuf_cnt_r，低电平复位（sirv_gnrl_dffs.v）
  // 计数器需要时序逻辑
   sirv_gnrl_dfflr #(ROWBUF_IDX_W)   lbuf_cnt_dfflr (lbuf_cnt_ena, lbuf_cnt_nxt, lbuf_cnt_r, nice_clk, nice_rst_n);

  // nice_rsp_valid wait for nice_icb_rsp_valid in LBUF
  // LBUF状态下，与memory握手成功，已接收反馈，且计到最后一个数，则使能IBUF状态的反馈cpu请求信号,last, wait lbuf_cnt_last
  // 表示lbuf指令已经执行完毕，要向主处理器反馈指令执行完毕的情况，发出握手请求valid信号
   assign nice_rsp_valid_lbuf = state_is_lbuf & lbuf_cnt_last & nice_icb_rsp_valid;

  // nice_icb_cmd_valid sets when lbuf_cnt_r is not full in LBUF
  // LBUF状态下，D触发器的输出当前计数值小于最大值，则使能IBUF状态的读memory请求信号, first
  // 指令执行所需要的数据还没读完，继续使能读取存储器
   assign nice_icb_cmd_valid_lbuf = (state_is_lbuf & (lbuf_cnt_r < clonum));
  //===============================LBUF指令控制信号生成==============================





  //===============================SBUF指令控制信号生成==============================
   wire [ROWBUF_IDX_W-1:0] sbuf_cnt_r;      //D触发器的输出当前计数值
   wire [ROWBUF_IDX_W-1:0] sbuf_cnt_nxt;    //D触发器的输入下一计数值
   wire sbuf_cnt_clr;                       //清零标志
   wire sbuf_cnt_incr;                      //计数
   wire sbuf_cnt_ena;                       //D触发器的输入计数使能
   wire sbuf_cnt_last;                      //计到最后一个数
   wire sbuf_icb_cmd_hsked;                 //SBUF状态下与memory握手成功，已发送读写地址和数据信号
   wire sbuf_icb_rsp_hsked;                 //SBUF状态下与memory握手成功，已接收反馈信号
   wire nice_rsp_valid_sbuf;                //SBUF状态的反馈cpu请求信号
   wire nice_icb_cmd_valid_sbuf;            //SBUF状态的读写memory请求信号
   wire nice_icb_cmd_hsked;                 //与memory握手成功，已发送读写地址和数据，表示准备写存储器
  
  //SBUF状态下，与memory握手成功，已发送读写地址和数据，则使能SBUF状态下与memory握手成功，已发送读写地址和数据信号，second，第一个计数器开启
  // 表示sbuf指令的存储器命令通道握手成功，写存储器请求握手成功，当前正处于sbuf状态，或者处于idle状态但是已经译出sbuf指令，并且存储器写请求反馈成功（准备写存储器）
   assign sbuf_icb_cmd_hsked = (state_is_sbuf | (state_is_idle & custom3_sbuf)) & nice_icb_cmd_hsked;

  //SBUF状态下，与memory握手成功，已接收反馈，使能SBUF状态下与memory握手成功，已接收反馈信号，third，第二个计数器开启 
  //表示sbuf指令的存储器反馈通道握手成功，当前正在执行sbuf指令，并且已经写存储成功，可以开始写存储器
   assign sbuf_icb_rsp_hsked = state_is_sbuf & nice_icb_rsp_hsked;

  //计到最后一个数，SBUF状态下与memory握手成功，已接收反馈，使能SBUF指令操作结束信号, last, wait sbuf_cnt_last
  //表示写存储器指令结束，已经开始写存储器，并且已经写完最后一个数据
   assign sbuf_icb_rsp_hsked_last = sbuf_icb_rsp_hsked & sbuf_cnt_last;

  //D触发器的输出当前计数值=2, 则计到最后一个数
   assign sbuf_cnt_last = (sbuf_cnt_r == clonum);

  //assign sbuf_cnt_clr = custom3_sbuf & nice_req_hsked;
  //SBUF指令操作结束，则清零，last, wait sbuf_cnt_last
   assign sbuf_cnt_clr = sbuf_icb_rsp_hsked_last;

  //SBUF状态下与memory握手成功，已接收反馈，但未计到最后一个数，则一直计数
  //已经与存储器握手成功，可以开始写存储器，但是还没写完数据，继续使能计数
   assign sbuf_cnt_incr = sbuf_icb_rsp_hsked & ~sbuf_cnt_last;
  //D触发器的输入计数使能由清零信号和计数信号确定
   assign sbuf_cnt_ena = sbuf_cnt_clr | sbuf_cnt_incr;
  //D触发器的输入下一计数值由清零信号和计数信号确定
   assign sbuf_cnt_nxt =   ({ROWBUF_IDX_W{sbuf_cnt_clr }} & {ROWBUF_IDX_W{1'b0}})
                         | ({ROWBUF_IDX_W{sbuf_cnt_incr}} & (sbuf_cnt_r + 1'b1) );
                         
  //例化D触发器，重载参数DW，初始化数为0，当sbuf_cnt_ena为1时，打一拍，sbuf_cnt_nxt赋值给sbuf_cnt_r，低电平复位（sirv_gnrl_dffs.v）
  //将计数信号输入到DFF，采用时序逻辑计数
   sirv_gnrl_dfflr #(ROWBUF_IDX_W)   sbuf_cnt_dfflr (sbuf_cnt_ena, sbuf_cnt_nxt, sbuf_cnt_r, nice_clk, nice_rst_n);

  // nice_rsp_valid wait for nice_icb_rsp_valid in SBUF
  //SBUF状态下，与memory握手成功，已接收反馈，且计到最后一个数，则使能SBUF状态的反馈cpu请求信号,last, wait sbuf_cnt_last
  //向主处理器（存储器）反馈已经写完数据
   assign nice_rsp_valid_sbuf = state_is_sbuf & sbuf_cnt_last & nice_icb_rsp_valid;
  //===============================SBUF指令控制信号生成================================================












   wire [ROWBUF_IDX_W-1:0] sbuf_cmd_cnt_r;    //D触发器的输出当前计数值
   wire [ROWBUF_IDX_W-1:0] sbuf_cmd_cnt_nxt;  //D触发器的输入下一计数值
   wire sbuf_cmd_cnt_clr;                     //清零
   wire sbuf_cmd_cnt_incr;                    //计数
   wire sbuf_cmd_cnt_ena;                     //D触发器的输入计数使能
   wire sbuf_cmd_cnt_last;                    //计到最后一个数

  //D触发器的输出当前计数值=2,则计到最后一个数
   assign sbuf_cmd_cnt_last = (sbuf_cmd_cnt_r == clonum);
  //SBUF指令操作结束，则清零，last, wait sbuf_cnt_last
   assign sbuf_cmd_cnt_clr = sbuf_icb_rsp_hsked_last;
  //SBUF状态下与memory握手成功，已发送读写地址和数据信号，但未计到最后一个数，则一直计数
   assign sbuf_cmd_cnt_incr = sbuf_icb_cmd_hsked & ~sbuf_cmd_cnt_last;
  //D触发器的输入计数使能由清零信号和计数信号确定
   assign sbuf_cmd_cnt_ena = sbuf_cmd_cnt_clr | sbuf_cmd_cnt_incr;
  //D触发器的输入下一计数值由清零信号和计数信号确定
   assign sbuf_cmd_cnt_nxt =   ({ROWBUF_IDX_W{sbuf_cmd_cnt_clr }} & {ROWBUF_IDX_W{1'b0}})
                             | ({ROWBUF_IDX_W{sbuf_cmd_cnt_incr}} & (sbuf_cmd_cnt_r + 1'b1) )
                             ;
  //例化D触发器，重载参数DW，初始化数为0，当sbuf_cmd_cnt_ena为1时，打一拍，sbuf_cmd_cnt_nxt赋值给sbuf_cmd_cnt_r，低电平复位（sirv_gnrl_dffs.v）
   sirv_gnrl_dfflr #(ROWBUF_IDX_W)   sbuf_cmd_cnt_dfflr (sbuf_cmd_cnt_ena, sbuf_cmd_cnt_nxt, sbuf_cmd_cnt_r, nice_clk, nice_rst_n);

  // nice_icb_cmd_valid sets when sbuf_cmd_cnt_r is not full in SBUF
  //SBUF状态下，D触发器的输出当前计数值sbuf_cmd_cnt_r小于等于最大值，sbuf_cnt_r不等于最大值，则使能SBUF状态的读写memory请求信号,first，also last, wait sbuf_cnt_last
   assign nice_icb_cmd_valid_sbuf = (state_is_sbuf & (sbuf_cmd_cnt_r <= clonum) & (sbuf_cnt_r != clonum));


  //==================================ROWSUM指令控制信号生成==============================================
   //////////// 3. custom3_rowsum
   // rowbuf counter 跟前面一样，可以看成是ROWSUM状态下的第一个计数器
   wire [ROWBUF_IDX_W-1:0] rowbuf_cnt_r;      //D触发器的输出当前计数值
   wire [ROWBUF_IDX_W-1:0] rowbuf_cnt_nxt;    //D触发器的输入下一计数值
   wire rowbuf_cnt_clr;                       //清零
   wire rowbuf_cnt_incr;                      //计数
   wire rowbuf_cnt_ena;                       //D触发器的输入计数使能
   wire rowbuf_cnt_last;                      //计到最后一个数
   wire rowbuf_icb_rsp_hsked;                 //ROWSUM状态下与memory握手成功，已接收反馈信号
   wire rowbuf_rsp_hsked;                     //ROWSUM状态下与cpu握手成功，已发送结果信号
   wire nice_rsp_valid_rowsum;                //ROWSUM状态下的反馈cpu请求信号

  //ROWSUM状态下的反馈cpu请求，cpu接收反馈，则使能ROWSUM状态下与cpu握手成功，已发送结果信号，last
  //表示rowsum指令已经执行完毕，协处理器已经向主处理器反馈结果，主处理器接收结果成功
   assign rowbuf_rsp_hsked = nice_rsp_valid_rowsum & nice_rsp_ready;
  //ROWSUM状态下，与memory握手成功，已接收反馈，使能ROWSUM状态下与memory握手成功，已接收存储器读写反馈信号
   assign rowbuf_icb_rsp_hsked = state_is_rowsum & nice_icb_rsp_hsked;
  //D触发器的输出当前计数值=2,则计到最后一个数
   assign rowbuf_cnt_last = (rowbuf_cnt_r == clonum);
  //计到最后一个数，且ROWSUM状态下与memory握手成功，已接收反馈信号，则清零
   assign rowbuf_cnt_clr = rowbuf_icb_rsp_hsked & rowbuf_cnt_last;
  //ROWSUM状态下与memory握手成功，已接收反馈信号，但未计到最后一个数，则一直计数
   assign rowbuf_cnt_incr = rowbuf_icb_rsp_hsked & ~rowbuf_cnt_last;
  //D触发器的输入计数使能由清零信号和计数信号确定
   assign rowbuf_cnt_ena = rowbuf_cnt_clr | rowbuf_cnt_incr;
  //D触发器的输入下一计数值由清零信号和计数信号确定
   assign rowbuf_cnt_nxt =   ({ROWBUF_IDX_W{rowbuf_cnt_clr }} & {ROWBUF_IDX_W{1'b0}})
                           | ({ROWBUF_IDX_W{rowbuf_cnt_incr}} & (rowbuf_cnt_r + 1'b1))
                           ;
   //assign nice_icb_cmd_valid_rowbuf =   (state_is_idle & custom3_rowsum)
   //                                  | (state_is_rowsum & (rowbuf_cnt_r <= clonum) & (clonum != 0))
   //                                  ;
  //重载2,使能rowbuf_cnt_ena，打一拍，rowbuf_cnt_nxt赋值给rowbuf_cnt_r
   sirv_gnrl_dfflr #(ROWBUF_IDX_W)   rowbuf_cnt_dfflr (rowbuf_cnt_ena, rowbuf_cnt_nxt, rowbuf_cnt_r, nice_clk, nice_rst_n);
  //==================================ROWSUM指令控制信号生成==============================================





   // recieve data buffer, to make sure rowsum ops come from registers 
   wire rcv_data_buf_ena;
   wire rcv_data_buf_set;//ROWSUM状态下memory请求与反馈结束信号
   wire rcv_data_buf_clr;//ROWSUM状态下cpu请求与反馈结束信号
   wire rcv_data_buf_valid;
   wire [`E203_XLEN-1:0] rcv_data_buf; //从memory读回的操作数
   wire [ROWBUF_IDX_W-1:0] rcv_data_buf_idx; 
   wire [ROWBUF_IDX_W-1:0] rcv_data_buf_idx_nxt; 

   assign rcv_data_buf_set = rowbuf_icb_rsp_hsked;
   assign rcv_data_buf_clr = rowbuf_rsp_hsked;
   assign rcv_data_buf_ena = rcv_data_buf_clr | rcv_data_buf_set;
  //ROWSUM状态下memory请求与反馈结束，cpu请求与反馈未结束，则rcv_data_buf_idx_nxt等于rowbuf_cnt_r
   assign rcv_data_buf_idx_nxt =   ({ROWBUF_IDX_W{rcv_data_buf_clr}} & {ROWBUF_IDX_W{1'b0}})
                                 | ({ROWBUF_IDX_W{rcv_data_buf_set}} & rowbuf_cnt_r        );
  //重载1,使能1,打一拍，rcv_data_buf_ena赋值给rcv_data_buf_valid
   sirv_gnrl_dfflr #(1)   rcv_data_buf_valid_dfflr (1'b1, rcv_data_buf_ena, rcv_data_buf_valid, nice_clk, nice_rst_n);
  //重载32,使能rcv_data_buf_ena，打一拍，nice_icb_rsp_rdata赋值给rcv_data_buf
   sirv_gnrl_dfflr #(`E203_XLEN)   rcv_data_buf_dfflr (rcv_data_buf_ena, nice_icb_rsp_rdata, rcv_data_buf, nice_clk, nice_rst_n);
  //重载2,使能rcv_data_buf_ena，打一拍，rcv_data_buf_idx_nxt赋值给rcv_data_buf_idx
   sirv_gnrl_dfflr #(ROWBUF_IDX_W)   rowbuf_cnt_d_dfflr (rcv_data_buf_ena, rcv_data_buf_idx_nxt, rcv_data_buf_idx, nice_clk, nice_rst_n);

   // rowsum accumulator 
   wire [`E203_XLEN-1:0] rowsum_acc_r;       //当前操作数
   wire [`E203_XLEN-1:0] rowsum_acc_nxt;     //下一操作数
   wire [`E203_XLEN-1:0] rowsum_acc_adder;   //操作数和
   wire rowsum_acc_ena;
   wire rowsum_acc_set;                      //第一个操作数状态使能，表示目前刚读进来第一个操作数，也就是累加和只有第一个操作数本身
   wire rowsum_acc_flg;                      //非第一个操作数状态使能，已经不只有第一个操作数，累加和已经加了不止一个操作数了
   wire nice_icb_cmd_valid_rowsum;
   wire [`E203_XLEN-1:0] rowsum_res;         //操作数总和

  //刚从存储器读完数rcv_data_buf_valid=1，检测此时读出的操作数是否是第一个操作数
   assign rowsum_acc_set = rcv_data_buf_valid & (rcv_data_buf_idx == {ROWBUF_IDX_W{1'b0}});
   assign rowsum_acc_flg = rcv_data_buf_valid & (rcv_data_buf_idx != {ROWBUF_IDX_W{1'b0}});
  
   assign rowsum_acc_adder = rcv_data_buf + rowsum_acc_r;   //将从memory读回的操作数与当前操作数相加
   assign rowsum_acc_ena = rowsum_acc_set | rowsum_acc_flg; // 第一个操作数，或者非第一个操作，均使能累加

  //如果是第一个操作数，则rowsum_acc_nxt等于从memory读回的操作数，否则则等于目前的操作数和
  //因为刚读进来第一个操作数的时候，累加和还等于它本身
   assign rowsum_acc_nxt =   ({`E203_XLEN{rowsum_acc_set}} & rcv_data_buf)
                           | ({`E203_XLEN{rowsum_acc_flg}} & rowsum_acc_adder);

  //重载32,使能rowsum_acc_ena，打一拍，rowsum_acc_nxt赋值给rowsum_acc_r
   sirv_gnrl_dfflr #(`E203_XLEN)   rowsum_acc_dfflr (rowsum_acc_ena, rowsum_acc_nxt, rowsum_acc_r, nice_clk, nice_rst_n);

   assign rowsum_done = state_is_rowsum & nice_rsp_hsked; // ROWSUM指令操作结束
   assign rowsum_res  = rowsum_acc_r;                     // 操作数总和


   // rowsum finishes when the last acc data is added to rowsum_acc_r  
   // 操作完，nice_rsp_valid_rowsum打开准备反馈给cpu
   // 当前正在处于执行rowsum指令，并且已经计算完，指令没有执行完（或者数据没读完）的状态，准备向主处理器发出反馈请求，表示指令执行完毕
   assign nice_rsp_valid_rowsum = state_is_rowsum & (rcv_data_buf_idx == clonum) & ~rowsum_acc_flg;

   // nice_icb_cmd_valid sets when rcv_data_buf_idx is not full in LBUF
  // 还没从内存取完数，nice_icb_cmd_valid_rowsum一直打开
  // 当前正在处于执行rowsum指令，并且还没计算完，指令没有执行完（或者数据没读完）的状态，继续使能读存储器请求
   assign nice_icb_cmd_valid_rowsum = state_is_rowsum & (rcv_data_buf_idx < clonum) & ~rowsum_acc_flg;

   //////////// rowbuf //lbuf和rowsum写rowbuf，sbuf读rowbuf，rowsum写入rowbuf的是列加运算的结果
   // rowbuf access list:
   //  1. lbuf will write to rowbuf, write data comes from memory, data length is defined by clonum 
   //  2. sbuf will read from rowbuf, and store it to memory, data length is defined by clonum 
   //  3. rowsum will accumulate data, and store to rowbuf, data length is defined by clonum 
   // rowbuf，rowbuf是数据缓存，lbuf和rowsum会写入，sbuf会读出
   wire [`E203_XLEN-1:0] rowbuf_r [ROWBUF_DP-1:0];     //4个32位宽的读数据[31:0][3:0]
   wire [`E203_XLEN-1:0] rowbuf_wdat [ROWBUF_DP-1:0];  //4个32位宽的写数据
   wire [ROWBUF_DP-1:0]  rowbuf_we;                    //4位宽的数据,D触发器的使能信号
   wire [ROWBUF_IDX_W-1:0] rowbuf_idx_mux;             //rowbuf的序号选择
   wire [`E203_XLEN-1:0] rowbuf_wdat_mux;              //rowbuf写入数据选择
   wire rowbuf_wr_mux;                                 //rowbuf写入选择器的选择信号
   //wire [ROWBUF_IDX_W-1:0] sbuf_idx; 
   
   // lbuf write to rowbuf
   wire [ROWBUF_IDX_W-1:0] lbuf_idx = lbuf_cnt_r; //lbuf写入的序号选择，将读数据的计数值，表示当前正在载入第几个rowbuf
   wire lbuf_wr = lbuf_icb_rsp_hsked;             //lbuf写入使能，已经开始读存储器数据，可以将读来的数据写入rowbuf中
   wire [`E203_XLEN-1:0] lbuf_wdata = nice_icb_rsp_rdata;   // lbuf载入的数据，从存储器读来的数据

   // rowsum write to rowbuf(column accumulated data)
   wire [ROWBUF_IDX_W-1:0] rowsum_idx = rcv_data_buf_idx; //rowsum写入的序号，为rcv_data_buf_idx，当前的计数值，从0到2
   wire rowsum_wr = rcv_data_buf_valid;                   //rowsum写入的使能，写入使能，为rcv_data_buf-valid，是rcv_data_buf_ena缓冲一个时钟
   wire [`E203_XLEN-1:0] rowsum_wdata = rowbuf_r[rowsum_idx] + rcv_data_buf;//列加运算，每行元素分三个D触发器储存

   // rowbuf write mux
  //选择写入的数据，只有lbuf和rowsum会写rowbuf，所以只有他们两个
   assign rowbuf_wdat_mux =   ({`E203_XLEN{lbuf_wr  }} & lbuf_wdata  )
                            | ({`E203_XLEN{rowsum_wr}} & rowsum_wdata)
                            ;
  //写入rowbuf使能选择，只有lbuf和rowsum会写rowbuf，所以只有他们两个
   assign rowbuf_wr_mux   =  lbuf_wr | rowsum_wr;
  //写入rowbuf序号选择，只有lbuf和rowsum会写rowbuf，所以只有他们两个
   assign rowbuf_idx_mux  =   ({ROWBUF_IDX_W{lbuf_wr  }} & lbuf_idx  )
                            | ({ROWBUF_IDX_W{rowsum_wr}} & rowsum_idx)
                            ;  

   // rowbuf inst 
   //实例化4个32位D触发器作为rowbuf
   genvar i;
   generate 
     for (i=0; i<ROWBUF_DP; i=i+1) begin:gen_rowbuf
       //确定写入的序号和使能信号
       assign rowbuf_we[i] =   (rowbuf_wr_mux & (rowbuf_idx_mux == i[ROWBUF_IDX_W-1:0]))
                             ;
       //确定写入的数据
       assign rowbuf_wdat[i] =   ({`E203_XLEN{rowbuf_we[i]}} & rowbuf_wdat_mux   )
                               ;
       //生成触发器，并把数据写入，重载32,使能rowbuf_we[i]，打一拍，rowbuf_wdat[i]赋值给rowbuf_r[i]
       sirv_gnrl_dfflr #(`E203_XLEN) rowbuf_dfflr (rowbuf_we[i], rowbuf_wdat[i], rowbuf_r[i], nice_clk, nice_rst_n);
     end
   endgenerate

   //////////// mem aacess addr management
   //================================生成lbuf和sbuf访问存储器的控制信和地址值==========================================
   wire [`E203_XLEN-1:0] maddr_acc_r; 
   assign nice_icb_cmd_hsked = nice_icb_cmd_valid & nice_icb_cmd_ready; //与memory握手成功，已发送读写地址和数据
   // custom3_lbuf 
   //wire [`E203_XLEN-1:0] lbuf_maddr    = state_is_idle ? nice_req_rs1 : maddr_acc_r ; 
  //LBUF状态下，操作memory使能信号
   wire lbuf_maddr_ena    =   (state_is_idle & custom3_lbuf & nice_icb_cmd_hsked)
                            | (state_is_lbuf & nice_icb_cmd_hsked)
                            ;

   // custom3_sbuf 
   //wire [`E203_XLEN-1:0] sbuf_maddr    = state_is_idle ? nice_req_rs1 : maddr_acc_r ; 
  //SBUF状态下，操作memory使能信号
   wire sbuf_maddr_ena    =   (state_is_idle & custom3_sbuf & nice_icb_cmd_hsked)
                            | (state_is_sbuf & nice_icb_cmd_hsked)
                            ;

   // custom3_rowsum
   //wire [`E203_XLEN-1:0] rowsum_maddr  = state_is_idle ? nice_req_rs1 : maddr_acc_r ; 
  //ROWSUM状态下，操作memory使能信号
   wire rowsum_maddr_ena  =   (state_is_idle & custom3_rowsum & nice_icb_cmd_hsked)
                            | (state_is_rowsum & nice_icb_cmd_hsked)
                            ;

   // maddr acc 
   //wire  maddr_incr = lbuf_maddr_ena | sbuf_maddr_ena | rowsum_maddr_ena | rbuf_maddr_ena;
   wire  maddr_ena = lbuf_maddr_ena | sbuf_maddr_ena | rowsum_maddr_ena;
   
   wire  maddr_ena_idle = maddr_ena & state_is_idle;//当状态为IDLE时先取出第一个内存地址，即从指令读取的内存地址，因为指令中会给出数组头的内存地址
  

  //nice_req_rs1是从指令操作数1中读取的内存地址，之后从memory每取一个数，内存地址要加4,因为每一个数是32位，4字节
   wire [`E203_XLEN-1:0] maddr_acc_op1 = maddr_ena_idle ? nice_req_rs1 : maddr_acc_r; // not reused
   wire [`E203_XLEN-1:0] maddr_acc_op2 = maddr_ena_idle ? `E203_XLEN'h4 : `E203_XLEN'h4; 

   wire [`E203_XLEN-1:0] maddr_acc_next = maddr_acc_op1 + maddr_acc_op2; // 将内存地址加出来
   wire  maddr_acc_ena = maddr_ena; // 既然允许进行内存操作，也要允许内存地址计算

  //重载32,使能maddr_acc_ena，打一拍，maddr_acc_next赋值给maddr_acc_r
   sirv_gnrl_dfflr #(`E203_XLEN)   maddr_acc_dfflr (maddr_acc_ena, maddr_acc_next, maddr_acc_r, nice_clk, nice_rst_n);
  //================================生成lbuf和sbuf访问存储器的控制信和地址值==========================================



  //===========================================命令通道控制信号=================================================
  // Control cmd_req
  // 请求通道握手信号
   assign nice_req_hsked = nice_req_valid & nice_req_ready;//命令请求通道握手成功，表示主处理器向协处理器发送扩展指令处理请求，协处理器接收指令成功
  //nice发出的命令请求握手信号，当前状态是idle，且指令有效，则为nice_icb_cmd_ready，否则为1'b1
   assign nice_req_ready = state_is_idle & (custom_mem_op ? nice_icb_cmd_ready : 1'b1); // 

  // Control cmd_rsp
  // 反馈通道握手信号
   assign nice_rsp_hsked = nice_rsp_valid & nice_rsp_ready;             // 反馈通道握手成功
   assign nice_icb_rsp_hsked = nice_icb_rsp_valid & nice_icb_rsp_ready; // 存储器反馈通道握手成功，表示主处理器已经向协处理器反馈读存储器数据，并且协处理器表示接收存储器读数据成功；或者是主处理器向协处理器反馈写存储器结果信号，表示协处理器写存储器成功

  // 表示以下三种指令任一种指令当前已经执行完毕，准备通过命令反馈通道，向主处理器发出反馈请求信号 valid
   assign nice_rsp_valid = nice_rsp_valid_rowsum | nice_rsp_valid_sbuf | nice_rsp_valid_lbuf;
   assign nice_rsp_rdat  = {`E203_XLEN{state_is_rowsum}} & rowsum_res; //返回rowsum计算结果

  // memory access bus error
  //assign nice_rsp_err_irq  =   (nice_icb_rsp_hsked & nice_icb_rsp_err)
  //                          | (nice_req_hsked & illgel_instr)
  //                          ; 
   assign nice_rsp_err   =   (nice_icb_rsp_hsked & nice_icb_rsp_err);//与memory握手成功，并从memory接收的反馈即为给cpu的反馈

  // Memory lsu
  // memory access list:
  //  1. In IDLE, custom_mem_op will access memory(lbuf/sbuf/rowsum)
  //  2. In LBUF, it will read from memory as long as lbuf_cnt_r is not full
  //  3. In SBUF, it will write to memory as long as sbuf_cnt_r is not full
  //  3. In ROWSUM, it will read from memory as long as rowsum_cnt_r is not full
  //assign nice_icb_rsp_ready = state_is_ldst_rsp & nice_rsp_ready; 
  // rsp always ready
   assign nice_icb_rsp_ready = 1'b1; //时刻准备接收memory反馈
   wire [ROWBUF_IDX_W-1:0] sbuf_idx = sbuf_cmd_cnt_r; 
  //使能memory请求信号
   assign nice_icb_cmd_valid =   (state_is_idle & nice_req_valid & custom_mem_op)
                              |  nice_icb_cmd_valid_lbuf
                              |  nice_icb_cmd_valid_sbuf
                              |  nice_icb_cmd_valid_rowsum
                              ;
  //（状态idle且命令有效）为寄存器1，要么是第一个数据，否则为maddr_acc_r
   assign nice_icb_cmd_addr  = (state_is_idle & custom_mem_op) ? nice_req_rs1 :
                              maddr_acc_r;
  //（状态idle且为lbuf或rowsum指令，为1，为sbuf指令，为0），或者为sbuf状态为0，否则为1，0为写，1为读
  // 表示是否需要读存储器
   assign nice_icb_cmd_read  = (state_is_idle & custom_mem_op) ? (custom3_lbuf | custom3_rowsum) : 
                              state_is_sbuf ? 1'b0 : 
                              1'b1;
  //（状态idle，sbuf指令）或subf状态，为rowbuf_r[sbuf_idx]，否则为0
  // sbuf要写入存储器的数据
   assign nice_icb_cmd_wdata = (state_is_idle & custom3_sbuf) ? rowbuf_r[sbuf_idx] :
                              state_is_sbuf ? rowbuf_r[sbuf_idx] : 
                              `E203_XLEN'b0; 

   //assign nice_icb_cmd_wmask = {`sirv_XLEN_MW{custom3_sbuf}} & 4'b1111;
   assign nice_icb_cmd_size  = 2'b10;                                            //2: 代表4字节32位数据
   assign nice_mem_holdup    =  state_is_lbuf | state_is_sbuf | state_is_rowsum; //独占内存信号

   // nice_active status
   assign nice_active = state_is_idle ? nice_req_valid : 1'b1;//nice是否在工作

endmodule
`endif//}


