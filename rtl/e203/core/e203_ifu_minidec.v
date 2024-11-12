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
//  The mini-decode module to decode the instruction in IFU 
//
// ====================================================================
`include "e203_defines.v" 

// 在取指阶段，用于对取回的指令进行部分译码
// 不需要译出所有信息，只需要译出ifu需要的信息：指令类型，分支预测信息
module e203_ifu_minidec(

  //////////////////////////////////////////////////////////////
  // The IR stage to Decoder
  input  [`E203_INSTR_SIZE-1:0] instr, // 取回的指令
  
  //////////////////////////////////////////////////////////////
  // The Decoded Info-Bus


  output dec_rs1en, // 源寄存器1使能
  output dec_rs2en, // 源寄存器2使能
  output [`E203_RFIDX_WIDTH-1:0] dec_rs1idx, // 源寄存器1索引
  output [`E203_RFIDX_WIDTH-1:0] dec_rs2idx, // 源寄存器2索引

  output dec_mulhsu,//是否属于mulhsu指令，高位有符号无符号乘
  output dec_mul   ,//是否属于mul指令，乘
  output dec_div   ,//是否属于div指令，除
  output dec_rem   ,//是否属于rem指令，求余数
  output dec_divu  ,//是否属于divu指令，无符号除
  output dec_remu  ,//是否属于remu指令，无符号求余数

  output dec_rv32,  // 指示当前指令是16位还是32位
  output dec_bjp,   // 指示当前指令是普通指令还是分支指令
  output dec_jal,   // 是否属于jal指令，无条件直接跳转
  output dec_jalr,  // 是否属于jalr指令，无条件间接跳转
  output dec_bxx,   // 是否属于条件跳转指令 BXX(BEQ,BNE)
  output [`E203_RFIDX_WIDTH-1:0] dec_jalr_rs1idx, // 无条件间接跳转指令的基址寄存器索引
  output [`E203_XLEN-1:0] dec_bjp_imm // 有条件跳转的立即数偏移量

  );

  // 例化一个完整的译码模块，但是将不相关的输入口接0，输出口悬空，使得综合工具将完整的decode模块中的无关逻辑优化掉，成为一个mini-decode
  e203_exu_decode u_e203_exu_decode(

  .i_instr(instr),
  .i_pc(`E203_PC_SIZE'b0), // 不相关输入信号接0
  .i_prdt_taken(1'b0), // 不相关输入信号接0
  .i_muldiv_b2b(1'b0), // 不相关输入信号接0

  .i_misalgn (1'b0),// 不相关输入信号接0
  .i_buserr  (1'b0),// 不相关输入信号接0

  .dbg_mode  (1'b0),// 不相关输入信号接0

  .dec_misalgn(),// 不相关输出信号悬空
  .dec_buserr(),// 不相关输出信号悬空
  .dec_ilegl(),// 不相关输出信号悬空

  .dec_rs1x0(),// 不相关输出信号悬空
  .dec_rs2x0(),// 不相关输出信号悬空
  .dec_rs1en(dec_rs1en),
  .dec_rs2en(dec_rs2en),
  .dec_rdwen(),
  .dec_rs1idx(dec_rs1idx),
  .dec_rs2idx(dec_rs2idx),
  .dec_rdidx(),
  .dec_info(),  
  .dec_imm(),
  .dec_pc(),

  
  .dec_mulhsu(dec_mulhsu),
  .dec_mul   (dec_mul   ),
  .dec_div   (dec_div   ),
  .dec_rem   (dec_rem   ),
  .dec_divu  (dec_divu  ),
  .dec_remu  (dec_remu  ),

  .dec_rv32(dec_rv32),
  .dec_bjp (dec_bjp ),
  .dec_jal (dec_jal ),
  .dec_jalr(dec_jalr),
  .dec_bxx (dec_bxx ),

  .dec_jalr_rs1idx(dec_jalr_rs1idx),
  .dec_bjp_imm    (dec_bjp_imm    )  
  );


endmodule
