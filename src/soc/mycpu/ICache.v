`timescale 1ns / 1ps

`include "defines.vh"

module ICache (
    input  wire         cpu_rstn,       // low active
    input  wire         cpu_clk,
    // Interface to CPU
    input  wire         inst_rreq,
    input  wire         inst_start_req,
    input  wire         inst_chain_ready,
    input  wire [31:0]  inst_addr,
    output reg          inst_valid,
    output reg  [31:0]  inst_out,
    output reg          inst_r2_use_rd,
    input  wire         pred_error,
    input  wire         cacheop_inv,
    input  wire [31:0]  cacheop_addr,
    // Interface to Read Bus
    input  wire         dev_rrdy,       // device ready to be read
    output reg  [ 3:0]  cpu_ren,        // cpu read mask
    output reg  [31:0]  cpu_raddr,      // cpu read data address
    input  wire         dev_rvalid,     // device data valid
    input  wire [31:0]  dev_rdata,      // data to be read
    input  wire         dev_r2_use_rd
);

    // ID needs only this one opcode-derived bit before its register-file
    // address mux.  Compute it in parallel with instruction selection so a
    // CWF/tag decision never sits in front of a 32-bit mux and decoder.
    function r2_use_rd_decode;
        input [31:0] inst;
        begin
            r2_use_rd_decode =
                (inst[31:24] == 8'h04) ||
                ((inst[31:24] == 8'h29) &&
                 !(inst[23] && inst[22])) ||
                (inst[31:27] == 5'b01011) ||
                (inst[31:28] == 4'b0110);
        end
    endfunction

`ifdef ENABLE_ICACHE

    // -------------------------------------------------------------------------
    // Cache参数和地址拆分
    // -------------------------------------------------------------------------
    localparam INDEX_WID  = $clog2(`CACHE_BLK_NUM);
    localparam OFFSET_WID = $clog2(`CACHE_BLK_LEN) + 2;
    localparam TAG_WID    = 32 - INDEX_WID - OFFSET_WID;
    localparam BLK_WID    = `CACHE_BLK_SIZE + TAG_WID + 1;

    reg [31:0] inst_addr_r;
    wire       pending_refill_req;

    localparam IDLE      = 2'b00;
    localparam TAG_CHECK = 2'b01;
    localparam RD_MEM    = 2'b10;
    localparam REFILL    = 2'b11;
    reg [1:0] current_state, next_state;

    // -------------------------------------------------------------------------
    // CPU取指请求锁存
    // -------------------------------------------------------------------------
    always @(posedge cpu_clk)
        if (!cpu_rstn)      inst_addr_r <= `PC_INIT_VAL;
        else if (inst_rreq) inst_addr_r <= inst_addr;

    wire [TAG_WID-1:0] tag_from_cpu = inst_addr_r[31:OFFSET_WID+INDEX_WID];
    // Pre-read the live IF PC without putting inst_rreq (and therefore the
    // EX-stage mispredict decision) on the BRAM address path.  During a refill
    // cwf_new_req denotes the one request already captured in inst_addr_r; it
    // must retain priority until the refill hands that request back to normal
    // TAG_CHECK.  Both choices now originate from registers, while the normal
    // one-cycle hit pipeline is unchanged.
    wire [INDEX_WID-1:0] cache_index = pending_refill_req
        ? inst_addr_r[OFFSET_WID+INDEX_WID-1:OFFSET_WID]
        : inst_addr[OFFSET_WID+INDEX_WID-1:OFFSET_WID];
    wire [$clog2(`CACHE_BLK_LEN)-1:0] offset = inst_addr_r[OFFSET_WID-1:2];

    wire [BLK_WID-1:0] cache_line_r;
    reg [`CACHE_BLK_NUM-1:0] valid_bits;
    // Keep the tag metadata in a small asynchronous shadow beside the wide
    // cache-line BRAM.  The BRAM still supplies instruction data, but its
    // comparatively slow clock-to-out delay no longer sits in front of the
    // tag comparison and the high-fanout fetch-advance enables.  Do not reset
    // this array: valid_bits qualifies every lookup and the single write point
    // below keeps the shadow aligned with each completed refill.
    (* ram_style = "distributed" *)
    reg [TAG_WID-1:0] tag_shadow [0:`CACHE_BLK_NUM-1];
    // One eager bit per cached instruction word.  It is filled beside each
    // line and read using the same synchronous lookup index as the data BRAM.
    (* ram_style = "distributed" *)
    reg [`CACHE_BLK_LEN-1:0] r2_meta_shadow [0:`CACHE_BLK_NUM-1];
    // Mirror the synchronous read transaction of the wide line BRAM.  Reading
    // tag_shadow directly with inst_addr_r is not equivalent around a
    // redirect/refill boundary: cache_line_r belongs to the address sampled
    // on the preceding edge, while inst_addr_r may already name a different
    // request.  This output register samples the exact BRAM address and uses
    // an explicit WRITE_FIRST bypass, so tag and instruction data always
    // describe the same transaction without putting BRAM clock-to-out delay
    // back on the hit/control path.
    reg [TAG_WID-1:0] tag_lookup_r;
    reg [`CACHE_BLK_LEN-1:0] r2_meta_lookup_r;
    wire [INDEX_WID-1:0] index_from_cpu = inst_addr_r[OFFSET_WID+INDEX_WID-1:OFFSET_WID];
    wire [INDEX_WID-1:0] cacheop_index = cacheop_addr[OFFSET_WID+INDEX_WID-1:OFFSET_WID];
    wire valid_bit = valid_bits[index_from_cpu];
    wire [TAG_WID-1:0] tag_from_cache = tag_lookup_r;
    wire [`CACHE_BLK_SIZE-1:0] cache_data = cache_line_r[`CACHE_BLK_SIZE-1:0];
    reg [OFFSET_WID:0] recv_cnt;
    wire [$clog2(`CACHE_BLK_LEN)-1:0] recv_word_index =
        recv_cnt[$clog2(`CACHE_BLK_LEN)-1:0];
    reg [`CACHE_BLK_SIZE-1:0] cache_line_data;
    reg [`CACHE_BLK_SIZE-1:0] cache_line_data_w;
    reg [`CACHE_BLK_LEN-1:0] r2_meta_refill;
    reg [`CACHE_BLK_LEN-1:0] r2_meta_refill_w;
    // -------------------------------------------------------------------------
    // Critical-word-first命中判断
    // -------------------------------------------------------------------------
    //新增定义
    wire [$clog2(`CACHE_BLK_LEN)-1:0] cwf_offset =inst_addr_r[OFFSET_WID-1:2];
    wire        cwf_word_valid =(cwf_offset < recv_cnt) ||(dev_rvalid && (cwf_offset == recv_cnt));
    reg  [TAG_WID  -1:0] tag_from_cpu_wr;       // 缓存块标签
    reg  [INDEX_WID-1:0] cache_idx_wr;          // 缓存Cache块索引
    reg         cwf_new_req;           // 该信号有效表示REFILL状态下收到了CPU的取指请求
    wire        cwf_tag_match = inst_addr_r[31:OFFSET_WID+INDEX_WID] == tag_from_cpu_wr;     // REFILL状态下收到的取指请求发生Cache块标签匹配
    wire        cwf_idx_match = inst_addr_r[OFFSET_WID+INDEX_WID-1:OFFSET_WID] == cache_idx_wr;     // REFILL状态下收到的取指请求发生Cache块索引匹配
    assign pending_refill_req = cwf_new_req;
    wire cwf_blk_hit =
    (current_state == REFILL) &&
    cwf_new_req &&
    cwf_tag_match &&
    cwf_idx_match;     // REFILL状态下收到的取指请求在"半成品"Cache块中发生命中
    wire        cwf_hit       = cwf_blk_hit && cwf_word_valid && !pred_error;     // 生成"半成品"Cache块的命中信号: 命中的前提是总线已返回对应的指令
    wire [31:0] cwf_inst      = (dev_rvalid && (cwf_offset == recv_cnt)) ? dev_rdata : cache_line_data[cwf_offset*32 +: 32];     // 根据偏移量返回命中的指令: 考虑实验原理的情形2、情形3分别怎么返回指令
    wire cwf_req_left = (cwf_new_req && !cwf_hit) || (current_state == REFILL && inst_rreq);     // REFILL状态下未命中，或缺失处理完成但仍有请求未能处理
    
    
    wire cwf_live_word = dev_rvalid && (cwf_offset == recv_cnt);
    wire cwf_r2_use_rd = cwf_live_word ?
        dev_r2_use_rd : r2_meta_refill[cwf_offset];
    wire cache_r2_use_rd = r2_meta_lookup_r[offset];

    wire hit;
    assign hit = current_state == TAG_CHECK && !pred_error &&
                 valid_bit && tag_from_cache == tag_from_cpu;

    // -------------------------------------------------------------------------
    // 返回CPU的取指结果
    // -------------------------------------------------------------------------
    always @(*) begin
        inst_valid = hit | cwf_hit;
        // Payload is observable only when inst_valid is set.  Select it by the
        // registered state rather than cwf_hit, so refill tag comparison stays
        // exclusively in the valid/control cone and cannot reach IBUF D pins.
        inst_out = (current_state == REFILL) ?
                   cwf_inst : cache_data[offset*32 +: 32];
        inst_r2_use_rd = (current_state == REFILL) ?
                         cwf_r2_use_rd : cache_r2_use_rd;
    end

    // -------------------------------------------------------------------------
    // Refill数据缓冲
    // -------------------------------------------------------------------------
    always @(*) begin
        cache_line_data_w = cache_line_data;
        if (current_state == REFILL && dev_rvalid)
            cache_line_data_w[recv_cnt*32 +: 32] = dev_rdata;
    end

    always @(*) begin
        r2_meta_refill_w = r2_meta_refill;
        if (current_state == REFILL && dev_rvalid)
            r2_meta_refill_w[recv_word_index] = dev_r2_use_rd;
    end

    always @(posedge cpu_clk) begin
        if (!cpu_rstn || current_state == RD_MEM) begin
            recv_cnt        <= 0;
            cache_line_data <= 0;
            r2_meta_refill  <= 0;
        end else if (current_state == REFILL && dev_rvalid) begin
            recv_cnt        <= recv_cnt + 1'b1;
            cache_line_data <= cache_line_data_w;
            r2_meta_refill  <= r2_meta_refill_w;
        end
    end

    wire refill_done = current_state == REFILL && dev_rvalid &&
                       recv_cnt == `CACHE_BLK_LEN - 1;
    wire cache_we = refill_done;
    wire [BLK_WID-1:0] cache_line_w = {1'b1, tag_from_cpu_wr, cache_line_data_w};

    always @(posedge cpu_clk) begin
        if (!cpu_rstn)
            valid_bits <= {`CACHE_BLK_NUM{1'b0}};
        else begin
            if (cache_we)
                valid_bits[cache_idx_wr] <= 1'b1;
            if (cacheop_inv)
                valid_bits[cacheop_index] <= 1'b0;
        end
    end

    // Independent, reset-free single write port keeps this array inferable as
    // LUTRAM in Vivado 2019.2.  A reset clears valid_bits, so stale tag storage
    // can never qualify a hit.
    always @(posedge cpu_clk) begin
        if (cpu_rstn && cache_we) begin
            tag_shadow[cache_idx_wr] <= tag_from_cpu_wr;
            r2_meta_shadow[cache_idx_wr] <= r2_meta_refill_w;
        end
    end

    // blk_mem_gen_0 port A is WRITE_FIRST and has no extra output register.
    // Keep this reset-free just like the inferred RAM output: valid_bits
    // masks the value until a line has been installed.
    always @(posedge cpu_clk) begin
        if (cache_we) begin
            tag_lookup_r <= tag_from_cpu_wr;
            r2_meta_lookup_r <= r2_meta_refill_w;
        end else begin
            tag_lookup_r <= tag_shadow[cache_index];
            r2_meta_lookup_r <= r2_meta_shadow[cache_index];
        end
    end
    
    // -------------------------------------------------------------------------
    // Refill期间的新请求记录
    // -------------------------------------------------------------------------
    //新添加的总线优化的部分
    
    always @(posedge cpu_clk) begin
        if (current_state == RD_MEM && dev_rrdy && !pred_error) tag_from_cpu_wr <= inst_addr_r[31:OFFSET_WID+INDEX_WID];
        if (current_state == RD_MEM && dev_rrdy && !pred_error) cache_idx_wr    <= inst_addr_r[OFFSET_WID+INDEX_WID-1:OFFSET_WID];
    end
    wire refill_start = current_state == RD_MEM && dev_rrdy && !pred_error;
    always @(posedge cpu_clk) begin
        if (!cpu_rstn)
            cwf_new_req <= 1'b0;
        else if (refill_start)
            cwf_new_req <= 1'b1;
        else if (current_state == REFILL && inst_rreq)
            cwf_new_req <= 1'b1;
        else if (cwf_hit && !inst_rreq)
            cwf_new_req <= 1'b0;
        else if (current_state != REFILL)
            cwf_new_req <= 1'b0;
    end
    
      
        
    // -------------------------------------------------------------------------
    // Cache RAM
    // -------------------------------------------------------------------------
    blk_mem_gen_0 U_isram (
        .clka   (cpu_clk),
        .wea    (cache_we),
        .addra  (cache_we ? cache_idx_wr : cache_index),
        .dina   (cache_line_w),
        .douta  (cache_line_r)
    );

    // -------------------------------------------------------------------------
    // 主状态机
    // -------------------------------------------------------------------------
    always @(posedge cpu_clk)
        if (!cpu_rstn) current_state <= IDLE;
        else           current_state <= next_state;

    always @(*) begin
        case (current_state)
            // Normal hit-chain requests are meaningful only in TAG_CHECK or
            // REFILL. IDLE starts from the independent first/resume/redirect
            // event (or a request retained across refill). This is
            // Boolean-equivalent in IDLE and prevents synthesis from merging
            // BRAM hit feedback back into current_state.
            IDLE: next_state = (inst_start_req || cwf_req_left) ?
                               TAG_CHECK : IDLE;
            // On a hit, IF issues the next sequential/predicted request iff
            // the IBUF has credit.  Use that independent credit directly
            // instead of inst_rreq: inst_rreq contains inst_valid/hit, and
            // feeding it back here creates BRAM->hit->IF/PC->ICache state.
            TAG_CHECK: next_state = pred_error ? TAG_CHECK :
                                    hit ? (inst_chain_ready ? TAG_CHECK : IDLE) :
                                          RD_MEM;
            RD_MEM   : next_state = pred_error ? TAG_CHECK :
                                    dev_rrdy ? REFILL : RD_MEM;
            REFILL: next_state = refill_done ? IDLE : REFILL;
            default  : next_state = IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // 下游读总线请求
    // -------------------------------------------------------------------------
    always @(*) begin
        cpu_ren   = 4'h0;
        cpu_raddr = {inst_addr_r[31:OFFSET_WID], {OFFSET_WID{1'b0}}};
        if (current_state == RD_MEM && dev_rrdy && !pred_error)
            cpu_ren = 4'hF;
    end

`ifndef SYNTHESIS
    always @(posedge cpu_clk) begin
        if (cpu_rstn && inst_valid &&
            (inst_r2_use_rd !== r2_use_rd_decode(inst_out)))
            $fatal(1, "ICache r2 metadata differs from returned instruction");
    end
`endif

`else

    // -------------------------------------------------------------------------
    // 未启用ICache时的直通取指路径
    // -------------------------------------------------------------------------
    localparam IDLE  = 2'b00;
    localparam STAT0 = 2'b01;
    localparam STAT1 = 2'b11;
    reg [1:0] state, nstat;
    reg       dev_rvalid_r;
    wire      dev_rvalid_pos = !dev_rvalid_r & dev_rvalid;

    always @(posedge cpu_clk) begin
        state        <= !cpu_rstn ? IDLE : nstat;
        dev_rvalid_r <= !cpu_rstn ? 1'b0 : dev_rvalid;
    end

    always @(*) begin
        case (state)
            IDLE   : nstat = inst_rreq ? (dev_rrdy ? STAT1 : STAT0) : IDLE;
            STAT0  : nstat = dev_rrdy ? STAT1 : STAT0;
            STAT1  : nstat = inst_rreq ? (dev_rrdy ? STAT1 : STAT0) : (dev_rvalid_pos ? IDLE : STAT1);
            default: nstat = IDLE;
        endcase
    end

    reg cpu_ren0;
    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            inst_valid <= 1'b0;
            inst_r2_use_rd <= 1'b0;
            cpu_ren0   <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    inst_valid <= 1'b0;
                    cpu_ren0   <= (inst_rreq & dev_rrdy) ? 1'b1 : 1'b0;
                    cpu_raddr  <= inst_rreq ? inst_addr : 32'h0;
                end
                STAT0: begin
                    cpu_ren0   <= dev_rrdy ? 1'b1 : 1'b0;
                end
                STAT1: begin
                    cpu_ren0   <= (inst_rreq & dev_rrdy) ? 1'b1 : 1'b0;
                    cpu_raddr  <= inst_rreq ? inst_addr : 32'h0;
                    inst_valid <= dev_rvalid_pos ? 1'b1 : 1'b0;
                    inst_out   <= dev_rvalid_pos ? dev_rdata[31:0] : 32'h0;
                    inst_r2_use_rd <= dev_rvalid_pos ?
                        dev_r2_use_rd : 1'b0;
                end
                default: begin
                    inst_valid <= 1'b0;
                    cpu_ren0   <= 1'b0;
                end
            endcase
        end
    end

    always @(*) cpu_ren = {4{cpu_ren0 & !inst_rreq}};

`ifndef SYNTHESIS
    always @(posedge cpu_clk) begin
        if (cpu_rstn && inst_valid &&
            (inst_r2_use_rd !== r2_use_rd_decode(inst_out)))
            $fatal(1, "uncached fetch r2 metadata differs from instruction");
    end
`endif

`endif

endmodule
