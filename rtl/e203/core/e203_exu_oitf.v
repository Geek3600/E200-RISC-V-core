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
//  The OITF (Oustanding Instructions Track FIFO) to hold all the non-ALU long
//  pipeline instruction's status and information
//
// ====================================================================


`include "e203_defines.v"
// 在蜂鸟e200中，正在派遣的指令只可能与尚未执行完毕的长指令之间产生RAW和WAW指令
// 该模块用于检测出与长指令的RAW和WAW相关性
// oitf：Outstanding Instructions Track FIFO
// 本质上是一个fifo 
module e203_exu_oitf (
  output dis_ready,

  input  dis_ena, // 已派遣一个长指令的使能信号，该信号用于分配一个OITF表项
  input  ret_ena, // 已写回一个长指令的使能信号，该信号用于移除一个OITF表项

  output [`E203_ITAG_WIDTH-1:0] dis_ptr,
  output [`E203_ITAG_WIDTH-1:0] ret_ptr,

  output [`E203_RFIDX_WIDTH-1:0] ret_rdidx,
  output ret_rdwen,
  output ret_rdfpu,
  output [`E203_PC_SIZE-1:0] ret_pc,

  // 以下为派遣的长指令相关信息，有的会被存储与OITF表项中，有的会用于RAW和WAW判断
  input  disp_i_rs1en,   // 当前派遣的指令是否需要读取第一个源操作数寄存器
  input  disp_i_rs2en,   // 当前派遣的指令是否需要读取第二个源操作数寄存器
  input  disp_i_rs3en,   // 当前派遣的指令是否需要读取第三个源操作数寄存器（只有浮点指令才会使用三个源操作数）
  
  input  disp_i_rdwen,   // 当前派遣的指令是否需要写入目的寄存器
  input  disp_i_rs1fpu,  // 当前派遣的指令第一个源操作数是否要读取浮点通用寄存器组
  input  disp_i_rs2fpu,  // 当前派遣的指令第二个源操作数是否要读取浮点通用寄存器组
  input  disp_i_rs3fpu,  // 当前派遣的指令第三个源操作数是否要读取浮点通用寄存器组
  input  disp_i_rdfpu,   // 当前派遣的指令是否要写回浮点通用寄存器组
  input  [`E203_RFIDX_WIDTH-1:0] disp_i_rs1idx, // 当前派遣指令的第一个源操作数寄存器索引
  input  [`E203_RFIDX_WIDTH-1:0] disp_i_rs2idx, // 当前派遣指令的第二个源操作数寄存器索引
  input  [`E203_RFIDX_WIDTH-1:0] disp_i_rs3idx, // 当前派遣指令的第三个源操作数寄存器索引
  input  [`E203_RFIDX_WIDTH-1:0] disp_i_rdidx,  // 当前派遣指令的目的操作数寄存器索引
  input  [`E203_PC_SIZE    -1:0] disp_i_pc,     // 当前派遣指令的pc值

  output oitfrd_match_disprs1, // 当前派遣的指令的源寄存器1与OITF中任一表项中的结果寄存器相同，即当前派遣指令与正在执行的长指令存在RAW相关
  output oitfrd_match_disprs2, // 当前派遣的指令的源寄存器2与OITF中任一表项中的结果寄存器相同，即当前派遣指令与正在执行的长指令存在RAW相关
  output oitfrd_match_disprs3, // 当前派遣的指令的源寄存器3与OITF中任一表项中的结果寄存器相同，即当前派遣指令与正在执行的长指令存在RAW相关
  output oitfrd_match_disprd, // 当前派遣的指令的目的寄存器与OITF中任一表项中的结果寄存器相同，即当前派遣指令与正在执行的长指令存在WAW相关

  output oitf_empty,
  input  clk,
  input  rst_n
);

  wire [`E203_OITF_DEPTH-1:0] vld_set;
  wire [`E203_OITF_DEPTH-1:0] vld_clr;
  wire [`E203_OITF_DEPTH-1:0] vld_ena;
  wire [`E203_OITF_DEPTH-1:0] vld_nxt;
  wire [`E203_OITF_DEPTH-1:0] vld_r;    // 各表项中是否存放了有效指令的指示信号
  wire [`E203_OITF_DEPTH-1:0] rdwen_r;  // 各表项中指令是否要写回结果寄存器
  wire [`E203_OITF_DEPTH-1:0] rdfpu_r;  // 各表项中指令写回的结果寄存器是否属于浮点
  wire [`E203_RFIDX_WIDTH-1:0] rdidx_r[`E203_OITF_DEPTH-1:0]; // 各表项中指令的结果寄存器索引
  // The PC here is to be used at wback stage to track out the
  //  PC of exception of long-pipe instruction
  wire [`E203_PC_SIZE-1:0] pc_r[`E203_OITF_DEPTH-1:0]; // 各表项中指令的pc值

  // OITF本质上是一个FIFO，因此需要生成FIFO的读写指针
  wire alc_ptr_ena = dis_ena; // 将派遣一个长指令的使能信号，作为写指针使能信号。派遣一条长指令，说明了要添加一个OITF表项
  wire ret_ptr_ena = ret_ena; // 将写回一个长指令的使能信号，作为读指针使能信号。一条长指令写回，说明需要移除一个OITF表项

  wire oitf_full ;
  
  wire [`E203_ITAG_WIDTH-1:0] alc_ptr_r;
  wire [`E203_ITAG_WIDTH-1:0] ret_ptr_r;

  generate
  if(`E203_OITF_DEPTH > 1) begin: depth_gt1
      // 与常规的FIFO设计一样，为了方便维护空满标志，为写指针增加一个额外的标志位
      wire alc_ptr_flg_r;
      wire alc_ptr_flg_nxt = ~alc_ptr_flg_r;
      wire alc_ptr_flg_ena = (alc_ptr_r == ($unsigned(`E203_OITF_DEPTH-1))) & alc_ptr_ena;
      sirv_gnrl_dfflr #(1) alc_ptr_flg_dfflrs(alc_ptr_flg_ena, alc_ptr_flg_nxt, alc_ptr_flg_r, clk, rst_n);
      wire [`E203_ITAG_WIDTH-1:0] alc_ptr_nxt; 
      
      // 每次分配一个表项，写指针自增1，如果达到FIFO的深度值，写指针归零
      assign alc_ptr_nxt = alc_ptr_flg_ena ? `E203_ITAG_WIDTH'b0 : (alc_ptr_r + 1'b1);
      sirv_gnrl_dfflr #(`E203_ITAG_WIDTH) alc_ptr_dfflrs(alc_ptr_ena, alc_ptr_nxt, alc_ptr_r, clk, rst_n);
      
      // 与常规的FIFO设计一样，为了方便维护空满标志，为读指针增加一个额外的标志位
      wire ret_ptr_flg_r;
      wire ret_ptr_flg_nxt = ~ret_ptr_flg_r;
      wire ret_ptr_flg_ena = (ret_ptr_r == ($unsigned(`E203_OITF_DEPTH-1))) & ret_ptr_ena;
      sirv_gnrl_dfflr #(1) ret_ptr_flg_dfflrs(ret_ptr_flg_ena, ret_ptr_flg_nxt, ret_ptr_flg_r, clk, rst_n);
      wire [`E203_ITAG_WIDTH-1:0] ret_ptr_nxt; 
      
      // 每次移除一个表项，读指针自增1，如果达到FIFO的深度值，读指针归零
      assign ret_ptr_nxt = ret_ptr_flg_ena ? `E203_ITAG_WIDTH'b0 : (ret_ptr_r + 1'b1);
      sirv_gnrl_dfflr #(`E203_ITAG_WIDTH) ret_ptr_dfflrs(ret_ptr_ena, ret_ptr_nxt, ret_ptr_r, clk, rst_n);

      // 生成OITF的空满标志
      assign oitf_empty = (ret_ptr_r == alc_ptr_r) &   (ret_ptr_flg_r == alc_ptr_flg_r);
      assign oitf_full  = (ret_ptr_r == alc_ptr_r) & (~(ret_ptr_flg_r == alc_ptr_flg_r));
  end


  else begin: depth_eq1
      assign alc_ptr_r = 1'b0;
      assign ret_ptr_r = 1'b0;
      assign oitf_empty = ~vld_r[0];
      assign oitf_full  = vld_r[0];
  end
  endgenerate

  assign ret_ptr = ret_ptr_r;
  assign dis_ptr = alc_ptr_r;


 // To cut down the loop between ALU write-back valid --> oitf_ret_ena --> oitf_ready ---> dispatch_ready --- > alu_i_valid
 //   we exclude the ret_ena from the ready signal
 assign dis_ready = (~oitf_full);
  
  wire [`E203_OITF_DEPTH-1:0] rd_match_rs1idx;
  wire [`E203_OITF_DEPTH-1:0] rd_match_rs2idx;
  wire [`E203_OITF_DEPTH-1:0] rd_match_rs3idx;
  wire [`E203_OITF_DEPTH-1:0] rd_match_rdidx;


  // 使用参数化的generate语法实现OITF FIFO主体部分
  genvar i;
  generate  
      for (i=0; i<`E203_OITF_DEPTH; i=i+1) begin:oitf_entries//{
  
        // 生成各表项中是否存放了有效指令的指示信号
        // 每次分配一个表项时，且写指针与当前表项的编号一样，则将该表项的有效信号设置为高，示该表项已经被成功分配
        assign vld_set[i] = alc_ptr_ena & (alc_ptr_r == i);

        // 每次移除一个表项时，且读指针与当前表项编号一样，则将该表项的有效信号设置为低，表示该表项已移除
        assign vld_clr[i] = ret_ptr_ena & (ret_ptr_r == i);
        assign vld_ena[i] = vld_set[i] |   vld_clr[i];
        assign vld_nxt[i] = vld_set[i] | (~vld_clr[i]);
  
        sirv_gnrl_dfflr #(1) vld_dfflrs(vld_ena[i], vld_nxt[i], vld_r[i], clk, rst_n);

        //Payload only set, no need to clear
        // 其他的表项信息，均可视为该表项的载荷，只需要在表项分配时写入，在表项移除的时候无需清除（为了节省动态功耗）
        sirv_gnrl_dffl #(`E203_RFIDX_WIDTH) rdidx_dfflrs(vld_set[i], disp_i_rdidx, rdidx_r[i], clk); // 各表项中指令的结果寄存器索引
        sirv_gnrl_dffl #(`E203_PC_SIZE    ) pc_dfflrs   (vld_set[i], disp_i_pc   , pc_r[i]   , clk); // 各表项中的指令PC
        sirv_gnrl_dffl #(1)                 rdwen_dfflrs(vld_set[i], disp_i_rdwen, rdwen_r[i], clk); // 各表项中指令是否需要写回结果寄存器
        sirv_gnrl_dffl #(1)                 rdfpu_dfflrs(vld_set[i], disp_i_rdfpu, rdfpu_r[i], clk); // 各表项中指令写回的结果寄存器是否属于浮点寄存器

        // 将正在派遣的指令的源操作数寄存器索引和各表项中的结果寄存器索引进行比较，即查看是否存在RAW相关
        assign rd_match_rs1idx[i] = vld_r[i] & rdwen_r[i] & disp_i_rs1en & (rdfpu_r[i] == disp_i_rs1fpu) & (rdidx_r[i] == disp_i_rs1idx);
        assign rd_match_rs2idx[i] = vld_r[i] & rdwen_r[i] & disp_i_rs2en & (rdfpu_r[i] == disp_i_rs2fpu) & (rdidx_r[i] == disp_i_rs2idx);
        assign rd_match_rs3idx[i] = vld_r[i] & rdwen_r[i] & disp_i_rs3en & (rdfpu_r[i] == disp_i_rs3fpu) & (rdidx_r[i] == disp_i_rs3idx);
        
        // 将正在派遣的指令的目的寄存器索引和各表项中的结果寄存器索引进行比较，即查看是否存在WAW相关
        assign rd_match_rdidx [i] = vld_r[i] & rdwen_r[i] & disp_i_rdwen & (rdfpu_r[i] == disp_i_rdfpu ) & (rdidx_r[i] == disp_i_rdidx );
  
      end
  endgenerate

  // 正在派遣的指令的源操作数1寄存器索引和OITF任一表项中的结果寄存器相同，表示存在RAW相关
  assign oitfrd_match_disprs1 = |rd_match_rs1idx;
  // 正在派遣的指令的源操作数2寄存器索引和OITF任一表项中的结果寄存器相同，表示存在RAW相关
  assign oitfrd_match_disprs2 = |rd_match_rs2idx;
  // 正在派遣的指令的源操作数3寄存器索引和OITF任一表项中的结果寄存器相同，表示存在RAW相关
  assign oitfrd_match_disprs3 = |rd_match_rs3idx;
  // 正在派遣的指令的目的寄存器索引和OITF任一表项中的结果寄存器相同，表示存在WAW相关
  assign oitfrd_match_disprd  = |rd_match_rdidx ;

  assign ret_rdidx = rdidx_r[ret_ptr];
  assign ret_pc    = pc_r [ret_ptr];
  assign ret_rdwen = rdwen_r[ret_ptr];
  assign ret_rdfpu = rdfpu_r[ret_ptr];

endmodule


