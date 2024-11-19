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
//
// Designer   : Bob Hu
//
// Description:
//  The Write-Back module to arbitrate the write-back request to regfile
//
// ====================================================================

`include "e203_defines.v"


// 
module e203_exu_wbck(

  //////////////////////////////////////////////////////////////
  // The ALU Write-Back Interface
  // 所有单周期指令的写回
  input  alu_wbck_i_valid, // 写回握手请求信号 Handshake valid
  output alu_wbck_i_ready, // 写回握手反馈信号 Handshake ready
  input  [`E203_XLEN-1:0] alu_wbck_i_wdat, // 写回的数据值
  input  [`E203_RFIDX_WIDTH-1:0] alu_wbck_i_rdidx, // 写回的寄存器索引值
  // If ALU have error, it will not generate the wback_valid to wback module
      // so we dont need the alu_wbck_i_err here

  //////////////////////////////////////////////////////////////
  // The Longp Write-Back Interface
  // 所有长指令的写回
  input  longp_wbck_i_valid, // 写回握手请求信号 Handshake valid
  output longp_wbck_i_ready, // 写回握手反馈信号 Handshake ready
  input  [`E203_FLEN-1:0] longp_wbck_i_wdat, //写回数据值
  input  [5-1:0] longp_wbck_i_flags, 
  input  [`E203_RFIDX_WIDTH-1:0] longp_wbck_i_rdidx, // 写回的寄存器索引值
  input  longp_wbck_i_rdfpu,

  //////////////////////////////////////////////////////////////
  // The Final arbitrated Write-Back Interface to Regfile
  // 仲裁后写回Regfile的接口
  output  rf_wbck_o_ena,                           // 写使能
  output  [`E203_XLEN-1:0] rf_wbck_o_wdat,         // 写回的数据值
  output  [`E203_RFIDX_WIDTH-1:0] rf_wbck_o_rdidx, // 写回的寄存器索引值


  
  input  clk,
  input  rst_n
  );


  // The ALU instruction can write-back only when there is no any 
  //  long pipeline instruction writing-back
  //    * Since ALU is the 1 cycle instructions, it have lowest 
  //      priority in arbitration
  // 使用优先级仲裁，如果两种指令同时写回，长指令具有更高优先级
  wire wbck_ready4alu = (~longp_wbck_i_valid);
  wire wbck_sel_alu = alu_wbck_i_valid & wbck_ready4alu; // 短指令写回请求，一旦长指令需要写回，短指令请求肯定无效
  // The Long-pipe instruction can always write-back since it have high priority 
  wire wbck_ready4longp = 1'b1;
  wire wbck_sel_longp = longp_wbck_i_valid & wbck_ready4longp; // 长指令写回请求



  //////////////////////////////////////////////////////////////
  // The Final arbitrated Write-Back Interface
  wire rf_wbck_o_ready = 1'b1; // Regfile is always ready to be write because it just has 1 w-port

  wire wbck_i_ready;
  wire wbck_i_valid;
  wire [`E203_FLEN-1:0] wbck_i_wdat;
  wire [5-1:0] wbck_i_flags;
  wire [`E203_RFIDX_WIDTH-1:0] wbck_i_rdidx;
  wire wbck_i_rdfpu;

  // 写回请求，两者不会同时有效，长指令写回请求一旦有效，短指令请求肯定无效；但是短指令请求不会影响长指令请求
  assign alu_wbck_i_ready   = wbck_ready4alu   & wbck_i_ready; // 短指令写回请求
  assign longp_wbck_i_ready = wbck_ready4longp & wbck_i_ready; // 长指令写回请求

  assign wbck_i_valid = wbck_sel_alu ? alu_wbck_i_valid : longp_wbck_i_valid;
  `ifdef E203_FLEN_IS_32//{
  assign wbck_i_wdat  = wbck_sel_alu ? alu_wbck_i_wdat  : longp_wbck_i_wdat;
  `else//}{
  assign wbck_i_wdat  = wbck_sel_alu ? {{`E203_FLEN-`E203_XLEN{1'b0}},alu_wbck_i_wdat}  : longp_wbck_i_wdat;
  `endif//}
  assign wbck_i_flags = wbck_sel_alu ? 5'b0  : longp_wbck_i_flags;
  assign wbck_i_rdidx = wbck_sel_alu ? alu_wbck_i_rdidx : longp_wbck_i_rdidx;
  assign wbck_i_rdfpu = wbck_sel_alu ? 1'b0 : longp_wbck_i_rdfpu;

  // If it have error or non-rdwen it will not be send to this module
  //   instead have been killed at EU level, so it is always need to 
  //   write back into regfile at here
  assign wbck_i_ready  = rf_wbck_o_ready;
  wire rf_wbck_o_valid = wbck_i_valid;

  wire wbck_o_ena   = rf_wbck_o_valid & rf_wbck_o_ready;

  assign rf_wbck_o_ena   = wbck_o_ena & (~wbck_i_rdfpu);
  assign rf_wbck_o_wdat  = wbck_i_wdat[`E203_XLEN-1:0];
  assign rf_wbck_o_rdidx = wbck_i_rdidx;


endmodule                                      
                                               
                                               
                                               
