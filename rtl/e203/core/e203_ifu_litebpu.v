 /*                                                                      
 Copyright 2018 Nuclei System Technology, Inc.                
                                                                         
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
// Designer   : Bob Hu
//
// Description:
//  The Lite-BPU module to handle very simple branch predication at IFU
//
// ====================================================================
`include "e203_defines.v"

//对取回的指令进行minidecode之后进行分支预测
//采用最简单的静态分支预测
//该模块并没有直接生成分支预测之后的PC，只是预测，最终要需要借助其他模块才能得到预测的PC值
module e203_ifu_litebpu(

  // Current PC
  input  [`E203_PC_SIZE-1:0] pc, // 当前指令的PC值

  // The mini-decoded info 
  input  dec_jal,  // 是否为jal指令
  input  dec_jalr, // 是否为jalr指令
  input  dec_bxx, // 是否为bxx指令
  input  [`E203_XLEN-1:0] dec_bjp_imm,  // 跳转偏移量
  input  [`E203_RFIDX_WIDTH-1:0] dec_jalr_rs1idx, // 当前指令中源寄存器1的索引，可能是基址寄存器

  // The IR index and OITF status to be used for checking dependency
  input  oitf_empty,
  input  ir_empty,
  input  ir_rs1en,
  input  jalr_rs1idx_cam_irrdidx,
  
  // The add op to next-pc adder
  output bpu_wait,     // 存在RAW依赖，需要等待
  output prdt_taken,    // 预测是否跳转标志位
  output [`E203_PC_SIZE-1:0] prdt_pc_add_op1,  // 将确定的基地址送出去，给加法器计算跳转目标地址
  output [`E203_PC_SIZE-1:0] prdt_pc_add_op2,  // 将确定的偏移量送出去，给加法器计算跳转目标地址

  input  dec_i_valid,

  // The RS1 to read regfile
  output bpu2rf_rs1_ena,   // 使能Regfile去读取rs1中的值的标志位
  input  ir_valid_clr,
  input  [`E203_XLEN-1:0] rf2bpu_x1,
  input  [`E203_XLEN-1:0] rf2bpu_rs1,

  input  clk,
  input  rst_n
  );


  // BPU of E201 utilize very simple static branch prediction logics
  //   * JAL: The target address of JAL is calculated based on current PC value
  //          and offset, and JAL is unconditionally always jump
  //   * JALR with rs1 == x0: The target address of JALR is calculated based on
  //          x0+offset, and JALR is unconditionally always jump
  //   * JALR with rs1 = x1: The x1 register value is directly wired from regfile
  //          when the x1 have no dependency with ongoing instructions by checking
  //          two conditions:
  //            ** (1) The OTIF in EXU must be empty 
  //            ** (2) The instruction in IR have no x1 as destination register
  //          * If there is dependency, then hold up IFU until the dependency is cleared
  //   * JALR with rs1 != x0 or x1: The target address of JALR need to be resolved
  //          at EXU stage, hence have to be forced halted, wait the EXU to be
  //          empty and then read the regfile to grab the value of xN.
  //          This will exert 1 cycle performance lost for JALR instruction
  //   * Bxxx: Conditional branch is always predicted as taken if it is backward
  //          jump, and not-taken if it is forward jump. The target address of JAL
  //          is calculated based on current PC value and offset

  
  // 预测是否跳转标志位
  // 如果为无条件跳转指令jal、jalr，一定跳转；如果为有条件跳转bxx，并且偏移量bjp_imm为负数（向后跳），查看最高符号位是否为1，也跳转
  assign prdt_taken   = (dec_jal | dec_jalr | (dec_bxx & dec_bjp_imm[`E203_XLEN-1]));  
  
  

  //判断间接跳转指令中源寄存器1中的索引是哪一种寄存器
  //判断rs1中的索引是否是x0
  wire dec_jalr_rs1x0 = (dec_jalr_rs1idx == `E203_RFIDX_WIDTH'd0);
  //判断rs1中的索引是否是x1
  wire dec_jalr_rs1x1 = (dec_jalr_rs1idx == `E203_RFIDX_WIDTH'd1);
  // 判断rs1中的索引既不是x0也不是x1
  wire dec_jalr_rs1xn = (~dec_jalr_rs1x0) & (~dec_jalr_rs1x1);

  // 表示如果输入指令有效（dec_i_valid=1），并且是jalr指令（dec_jalr=1），并且rs1中的索引是x1（dec_jalr_rs1x1=1），并且有长指令正在执行
  //（~oitf_empty=1）（可能会写x1，也可能不会，但是在此保守估计），或者IR寄存器中的指令的写回寄存器为x1（jalr_rs1idx_cam_irrdidx=1）
  wire jalr_rs1x1_dep = dec_i_valid & dec_jalr & dec_jalr_rs1x1 & ((~oitf_empty) | (jalr_rs1idx_cam_irrdidx));

  // 表示如果输入指令有效（dec_i_valid=1），并且是jalr指令（dec_jalr=1），并且rs1中的索引既不是x0也不是x1（dec_jalr_rs1xn=1），并且有长指令正在执行
  //（~oitf_empty=1）（可能会写x1，也可能不会，但是在此保守估计），或者IR寄存器中的指令可能写回寄存器为xn（~ir_empty=1）（同样是保守估计）
  wire jalr_rs1xn_dep = dec_i_valid & dec_jalr & dec_jalr_rs1xn & ((~oitf_empty) | (~ir_empty));

  //TODO
  wire jalr_rs1xn_dep_ir_clr = (jalr_rs1xn_dep & oitf_empty & (~ir_empty)) & (ir_valid_clr | (~ir_rs1en));

  wire rs1xn_rdrf_r;// Regfile的输出

  // rs1xn_rdrf_set：拉高表示Regfile的第一个读端口正在处于征用状态
  //TODO
  wire rs1xn_rdrf_set = (~rs1xn_rdrf_r) & dec_i_valid & dec_jalr & dec_jalr_rs1xn & ((~jalr_rs1xn_dep) | jalr_rs1xn_dep_ir_clr);
  wire rs1xn_rdrf_clr = rs1xn_rdrf_r;
  wire rs1xn_rdrf_ena = rs1xn_rdrf_set |   rs1xn_rdrf_clr;
  wire rs1xn_rdrf_nxt = rs1xn_rdrf_set | (~rs1xn_rdrf_clr);

  //带load使能的D触发器，不是Regfile，暂时不知有什么作用，打一拍？
  //TODO
  sirv_gnrl_dfflr #(1) rs1xn_rdrf_dfflrs(rs1xn_rdrf_ena, rs1xn_rdrf_nxt, rs1xn_rdrf_r, clk, rst_n);

  // bpu2rf_rs1_ena：拉高表示Regfile的第一个读端口正在处于征用状态
  assign bpu2rf_rs1_ena = rs1xn_rdrf_set;

  // 如果x1存在RAW相关（jalr_rs1x1_dep=1），则bpu_wait拉高，IFU进入等待状态，停止计算下一个PC值
  // 如果xn存在RAW相关（jalr_rs1xn_dep=1），则bpu_wait拉高，IFU进入等待状态，停止计算下一个PC值
  // 如果Regfile的第一个读端口正在处于征用状态（rs1xn_rdrf_set=1），说明正在读取xn中的基地址值，需要等待读取完毕
  assign bpu_wait = jalr_rs1x1_dep | jalr_rs1xn_dep | rs1xn_rdrf_set;


  //=====================================================================================
  // 确定计算跳转目标地址的两个加数，基地址+偏移量
  // 确定基地址
  // 如果是bxx，jal指令，均使用当前PC值作为基地址
  // 如果是jalr指令，它所使用的基地址还需要索引通用寄存器组Regfile，为了加快速度，根据rs1中的索引值分情况讨论
  //    1. 如果rs1中的通用寄存器索引是x0，x0是零寄存器，直接使用常数0，无需再访问Regfile
  //    2. 如果rs1中的通用寄存器索引是x1，x1常作为链接寄存器存储函数返回跳转地址，可以直接从EXU中将x1取出，但可能存在RAW冒险
  //            dec_jalr & dec_jalr_rs1x0：表示如果是jalr指令并且rs1中的索引是x0
  //            dec_jalr & dec_jalr_rs1x1：表示如果是jalr指令并且rs1中的索引是x1
  assign prdt_pc_add_op1 = (dec_bxx | dec_jal) ? pc[`E203_PC_SIZE-1:0]
                         : (dec_jalr & dec_jalr_rs1x0) ? `E203_PC_SIZE'b0
                         : (dec_jalr & dec_jalr_rs1x1) ?  rf2bpu_x1[`E203_PC_SIZE-1:0] // 如果是jalr指令并且rs1中为x1，则使用从Regfile中硬连线出来得到的值
                         : rf2bpu_rs1[`E203_PC_SIZE-1:0];  
  // 确定偏移量
  assign prdt_pc_add_op2 = dec_bjp_imm[`E203_PC_SIZE-1:0];  
 //=========================================================================================
endmodule
