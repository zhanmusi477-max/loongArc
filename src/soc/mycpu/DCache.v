//0
`timescale 1ns / 1ps

`include "defines.vh"

module DCache (
    input  wire         cpu_rstn,       // low active
    input  wire         cpu_clk,
    // Interface to CPU
    input  wire [ 3:0]  data_ren,
    input  wire [31:0]  data_raddr,
    input  wire [31:0]  data_addr,
    output reg          data_valid,
    output reg  [31:0]  data_rdata,
    input  wire [ 3:0]  data_wen,
    input  wire [31:0]  data_wdata,
    output reg          data_wresp,
    output wire         data_waccept,
    input  wire         early_read_valid,
    input  wire [31:0]  early_read_addr,
    input  wire         cacheop_inv,
    input  wire [31:0]  cacheop_addr,
    // Interface to Write Bus
    input  wire         dev_wrdy,       // device ready to be written (device: main memory or peripherals)
    output reg  [ 3:0]  cpu_wen,        // cpu write enable
    output reg  [31:0]  cpu_waddr,      // cpu write data address
    output reg          cpu_wperipheral,// registered address class for write bridge
    output reg  [31:0]  cpu_wdata,      // cpu write data
    // Interface to Read Bus
    input  wire         dev_rrdy,       // device ready to be read
    output reg  [ 3:0]  cpu_ren,        // cpu read mask
    output reg  [31:0]  cpu_raddr,      // cpu read data address
    // Address-only view for the Store->Load ordering query.  It is equal to
    // cpu_raddr whenever cpu_ren is asserted, but bypasses the request-state
    // output mux so the shadow CAM is not placed after that mux.
    output wire [31:0]  cpu_order_addr,
    output reg          cpu_rshort,     // one demanded word instead of a line
    input  wire         dev_rvalid,     // device data valid
    input  wire [31:0]  dev_rdata       // data to be read
);

`ifdef ENABLE_DCACHE

    // -------------------------------------------------------------------------
    // Cache参数、状态编码和请求锁存
    // -------------------------------------------------------------------------
    localparam INDEX_WID  = $clog2(`CACHE_BLK_NUM);
    localparam OFFSET_WID = $clog2(`CACHE_BLK_LEN) + 2;
    localparam TAG_WID    = 32 - INDEX_WID - OFFSET_WID;
    localparam WORD_WID   = $clog2(`CACHE_BLK_LEN);
    // Two physical word banks are reserved for every architectural line.
    // A refill streams into the inactive bank and atomically publishes the
    // completed line by flipping active_bank[index].  With 32 lines and eight
    // words per line this is one 512x32 true-dual-port RAM.
    localparam CACHE_RAM_ADDR_WID = INDEX_WID + 1 + WORD_WID;
    localparam CACHE_RAM_WORDS = `CACHE_BLK_NUM * 2 * `CACHE_BLK_LEN;

    localparam IDLE      = 2'b00;
    localparam TAG_CHECK = 2'b01;
    localparam RD_MEM    = 2'b10;
    localparam REFILL    = 2'b11;
    reg [1:0] current_state, next_state;

    localparam W_IDLE      = 2'b00;
    localparam W_TAG_CHECK = 2'b01;
    localparam W_STAT0     = 2'b10;
    localparam W_STAT1     = 2'b11;
    reg [1:0] w_state, w_nstat;

    reg [31:0] data_addr_r;
    reg [ 3:0] data_ren_r;
    reg        read_req_valid;
    reg        pending_refill_same_line_r;
    reg [31:0] data_waddr_r;
    reg [ 3:0] data_wen_r;
    reg [31:0] data_wdata_r;
    // Physical word selected on the Store request edge.  A refill of another
    // tag at the same direct-mapped index may commit before W_TAG_CHECK; using
    // active_bank again then would redirect the Store into the newly published
    // line.  The old-bank address and its synchronous q must stay paired.
    reg [CACHE_RAM_ADDR_WID-1:0] store_ram_addr_r;

    reg [`CACHE_BLK_NUM-1:0] valid_bits;
    reg [`CACHE_BLK_NUM-1:0] active_bank;
    // Tags stay in a small asynchronous shadow.  The word RAM contains data
    // only, so a hit no longer fans a wide BRAM line through an 8:1 word mux.
    // The shadow and active bank change together only at refill commit.
    (* ram_style = "distributed" *)
    reg [TAG_WID-1:0] tag_shadow [0:`CACHE_BLK_NUM-1];
    (* ram_style = "block" *)
    reg [31:0] cache_word_mem [0:CACHE_RAM_WORDS-1];
    reg [31:0] cache_word_r;

    wire [TAG_WID-1:0] tag_from_cpu = data_addr_r[31:OFFSET_WID+INDEX_WID];
    wire [INDEX_WID-1:0] index_from_cpu = data_addr_r[OFFSET_WID+INDEX_WID-1:OFFSET_WID];
    wire [INDEX_WID-1:0] index_from_write = data_waddr_r[OFFSET_WID+INDEX_WID-1:OFFSET_WID];
    wire [TAG_WID-1:0] live_write_tag =
                              data_addr[31:OFFSET_WID+INDEX_WID];
    wire [INDEX_WID-1:0] live_write_index =
                              data_addr[OFFSET_WID+INDEX_WID-1:OFFSET_WID];
    wire [INDEX_WID-1:0] live_read_index =
                              data_raddr[OFFSET_WID+INDEX_WID-1:OFFSET_WID];
    wire [INDEX_WID-1:0] cacheop_index = cacheop_addr[OFFSET_WID+INDEX_WID-1:OFFSET_WID];
    wire valid_bit = valid_bits[index_from_cpu];
    wire [$clog2(`CACHE_BLK_LEN)-1:0] word_offset = data_addr_r[OFFSET_WID-1:2];

    // -------------------------------------------------------------------------
    // 命中和uncached访问判断
    // -------------------------------------------------------------------------
    wire rd_uncached = (data_addr_r[31:16] == 16'h1F00) ||
                       (data_addr_r[31:16] == 16'hBFD0);
    wire wr_uncached_from_addr =
                       (data_waddr_r[31:16] == 16'h1F00) ||
                       (data_waddr_r[31:16] == 16'hBFD0);
    // cpu_wperipheral is captured beside data_waddr_r/cpu_waddr on the
    // request edge.  Reuse that registered class throughout the write path so
    // the bridge ready signal does not decode the 32-bit address and feed the
    // result back through Store retirement into the next read probe.
    wire wr_uncached = cpu_wperipheral;
    wire live_write_uncached = (data_addr[31:16] == 16'h1F00) ||
                               (data_addr[31:16] == 16'hBFD0);
    // The live Store index is already on the single-port BRAM address before
    // the request-capture edge.  Resolve and register its tag hit on that same
    // edge, alongside address/data.  W_TAG_CHECK then uses this one-bit result;
    // the registered address no longer traverses LUTRAM tag read, compare and
    // the 279-bit BRAM input mux in one cycle.
    wire live_store_hit = (|data_wen) && !live_write_uncached &&
                          valid_bits[live_write_index] &&
                          (tag_shadow[live_write_index] == live_write_tag);
    reg store_hit_r;
    wire [31:0] cache_word = cache_word_r;
    reg [OFFSET_WID:0] recv_cnt;
    reg [$clog2(`CACHE_BLK_LEN)-1:0] refill_start_offset;
    reg [INDEX_WID-1:0] refill_index;
    reg [TAG_WID-1:0] refill_tag;
    reg refill_uncached;
    reg refill_short;
    reg refill_killed;
    reg [`CACHE_BLK_LEN-1:0] refill_word_valid;

    // A store to the line currently being refilled invalidates the buffered
    // image.  The registered refill_killed bit protects later responses and
    // the eventual BRAM commit without putting the store-buffer address CAM
    // on the same-cycle Load response path.
    wire store_during_refill = current_state == REFILL && (|data_wen);
    wire store_same_refill_line = store_during_refill &&
                                  data_addr[31:OFFSET_WID] ==
                                  {refill_tag, refill_index};

    // Adaptive refill policy.  Normal line mode is the reset/default mode.
    // Thirty-two consecutive cached misses with no intervening hit identify
    // a streaming-through-random-data phase such as CRYPTONIGHT and switch
    // subsequent misses to one-word, no-allocate requests.  Five spatially
    // local reads switch back to full-line allocation, so a later sequential
    // phase cannot remain trapped in the short mode.
    localparam [5:0] ADAPT_MISS_THRESHOLD = 6'd31;
    localparam [2:0] ADAPT_LOCAL_THRESHOLD = 3'd3;
    reg        adaptive_word_mode;
    reg [ 5:0] adaptive_miss_streak;
    reg [ 2:0] adaptive_local_streak;
    reg [31:0] adaptive_prev_read_addr;
    reg        adaptive_prev_read_valid;

    // 512 KiB direct-mapped Random Word Cache.  It is used only after the
    // normal DCache has positively identified a random single-word phase.
    // Query is synchronous from EX to M1; therefore neither its BRAM data nor
    // tag compare can feed ID2, branch resolution, or front-end control.
    localparam RWC_INDEX_WID = 17;
    localparam RWC_TAG_WID   = 32 - RWC_INDEX_WID - 2;
    localparam RWC_GEN_WID   = 6;
    localparam RWC_META_WID  = RWC_TAG_WID + RWC_GEN_WID;
    localparam RWC_ENTRIES   = (1 << RWC_INDEX_WID);
    // A monolithic 128Kx19 metadata RAM maps each bit through four deep
    // RAMB36 entries.  Its cascaded clock-to-out plus the full tag comparison
    // was the direct-route WNS path.  Split only the metadata array into four
    // 32K banks using the already-registered EX query index.  Each bit then
    // fits one RAMB36 without a depth cascade; the registered bank selector
    // preserves the original one-cycle EX->M1 lookup and adds no stall.
    localparam RWC_META_BANK_WID = 2;
    localparam RWC_META_ROW_WID  = RWC_INDEX_WID - RWC_META_BANK_WID;
    localparam RWC_META_BANK_ENTRIES = (1 << RWC_META_ROW_WID);
    (* ram_style = "block" *)
    reg [31:0] rwc_data_mem [0:RWC_ENTRIES-1];
    (* ram_style = "block" *)
    reg [RWC_META_WID-1:0] rwc_meta_mem_b0 [0:RWC_META_BANK_ENTRIES-1];
    (* ram_style = "block" *)
    reg [RWC_META_WID-1:0] rwc_meta_mem_b1 [0:RWC_META_BANK_ENTRIES-1];
    (* ram_style = "block" *)
    reg [RWC_META_WID-1:0] rwc_meta_mem_b2 [0:RWC_META_BANK_ENTRIES-1];
    (* ram_style = "block" *)
    reg [RWC_META_WID-1:0] rwc_meta_mem_b3 [0:RWC_META_BANK_ENTRIES-1];
    reg [31:0] rwc_query_mem_data_r;
    reg [RWC_META_WID-1:0] rwc_meta_bank0_q;
    reg [RWC_META_WID-1:0] rwc_meta_bank1_q;
    reg [RWC_META_WID-1:0] rwc_meta_bank2_q;
    reg [RWC_META_WID-1:0] rwc_meta_bank3_q;
    reg [RWC_META_BANK_WID-1:0] rwc_query_meta_bank_r;
    reg        rwc_query_bypass_valid_r;
    reg [31:0] rwc_query_bypass_data_r;
    reg [RWC_META_WID-1:0] rwc_query_bypass_meta_r;
    reg [31:0] rwc_query_addr_r;
    reg        rwc_query_valid_r;
    // Keep the large RWC BRAM/tag-compare cone local to DCache.  The M1 hit
    // decision and word are captured here; only these flops drive the CPU
    // result/extension path on the following cycle.  This intentionally costs
    // one cycle per RWC hit, but prevents a 128K-deep cascaded BRAM output from
    // crossing the DCache boundary and the M2 load-extension mux in one cycle.
    reg        rwc_hit_pending_r;
    // Physically independent copy used only by the retained-miss request
    // launcher.  The architectural hit flag fans out through response data,
    // state and refill bookkeeping; routing that same high-fanout Q across the
    // device to the CPU->SRAM request mailbox dominated the 150 MHz route.
    // Both copies capture the identical comparison on the same edge, so this
    // is a placement boundary only and does not add a request cycle.
    (* keep = "true", dont_touch = "true", max_fanout = 8 *)
    reg        rwc_hit_request_r;
    reg [31:0] rwc_hit_data_r;
    reg        rwc_ready;
    reg        rwc_clearing;
    reg        rwc_clear_drain_r;
    reg [RWC_INDEX_WID-1:0] rwc_clear_index;
    // Generation 0 is reserved for physically-cleared/INIT contents.  CACOP
    // normally advances this generation and invalidates every old entry in a
    // single cycle.  Only the rare generation wrap invokes background clear.
    reg [RWC_GEN_WID-1:0] rwc_generation = {{(RWC_GEN_WID-1){1'b0}}, 1'b1};
    // Xilinx configuration initializes BRAM contents to zero.  The first
    // board reset may therefore use the empty RWC immediately instead of
    // spending 131K CPU cycles rewriting zeros.  This INIT-backed bit is not
    // reset: any later runtime reset takes the conservative clear path.
    reg        rwc_runtime_started = 1'b0;
    reg        rwc_fill_pending;
    reg [31:0] rwc_fill_addr;
    reg        rwc_data_we;
    reg        rwc_meta_we;
    reg [RWC_INDEX_WID-1:0] rwc_write_index;
    reg [31:0] rwc_write_data;
    reg [RWC_META_WID-1:0] rwc_write_meta;
    // Final BRAM write command.  Keep the wide/deep RAM enable, address and
    // data nets sourced by DCache-local flops so the placer can replicate
    // them next to the RAM columns instead of routing a MEM-stage cone across
    // the device.
    reg rwc_data_we_r;
    reg rwc_meta_we_r;
    reg [RWC_INDEX_WID-1:0] rwc_write_index_r;
    reg [31:0] rwc_write_data_r;
    reg [RWC_META_WID-1:0] rwc_write_meta_r;
    // One-entry Store capture.  A following Load is forwarded from this
    // entry while the final BRAM command is being formed.
    reg        rwc_store_pending_r;
    reg [31:0] rwc_store_addr_r;
    reg [31:0] rwc_store_data_r;
    reg [ 3:0] rwc_store_wen_r;

`ifndef SYNTHESIS
    // Keep generic RTL/lint simulation aligned with the all-zero BRAM
    // INIT used by the FPGA bitstream.  It is intentionally excluded from
    // synthesis so the canonical RAM inference template remains unchanged.
    integer rwc_sim_init_i;
    initial begin
        for (rwc_sim_init_i = 0;
             rwc_sim_init_i < RWC_META_BANK_ENTRIES;
             rwc_sim_init_i = rwc_sim_init_i + 1) begin
            rwc_meta_mem_b0[rwc_sim_init_i] = {RWC_META_WID{1'b0}};
            rwc_meta_mem_b1[rwc_sim_init_i] = {RWC_META_WID{1'b0}};
            rwc_meta_mem_b2[rwc_sim_init_i] = {RWC_META_WID{1'b0}};
            rwc_meta_mem_b3[rwc_sim_init_i] = {RWC_META_WID{1'b0}};
        end
    end
`endif

    wire [RWC_INDEX_WID-1:0] rwc_query_index =
                                      early_read_addr[RWC_INDEX_WID+1:2];
    wire [RWC_INDEX_WID-1:0] rwc_store_index =
                                      rwc_store_addr_r[RWC_INDEX_WID+1:2];
    wire [RWC_INDEX_WID-1:0] rwc_fill_index =
                                      rwc_fill_addr[RWC_INDEX_WID+1:2];
    wire [RWC_META_BANK_WID-1:0] rwc_query_meta_bank =
        rwc_query_index[RWC_INDEX_WID-1 -: RWC_META_BANK_WID];
    wire [RWC_META_ROW_WID-1:0] rwc_query_meta_row =
        rwc_query_index[RWC_META_ROW_WID-1:0];
    wire [RWC_META_BANK_WID-1:0] rwc_write_meta_bank =
        rwc_write_index_r[RWC_INDEX_WID-1 -: RWC_META_BANK_WID];
    wire [RWC_META_ROW_WID-1:0] rwc_write_meta_row =
        rwc_write_index_r[RWC_META_ROW_WID-1:0];
    wire [RWC_TAG_WID-1:0] rwc_store_tag =
                                      rwc_store_addr_r[31:RWC_INDEX_WID+2];
    wire [RWC_TAG_WID-1:0] rwc_fill_tag =
                                      rwc_fill_addr[31:RWC_INDEX_WID+2];
    wire [31:0] rwc_query_data = rwc_query_bypass_valid_r
                                ? rwc_query_bypass_data_r
                                : rwc_query_mem_data_r;
    wire [RWC_META_WID-1:0] rwc_expected_meta = {
        rwc_generation, data_raddr[31:RWC_INDEX_WID+2]
    };
    // Compare beside each physical metadata BRAM, then select one match bit.
    // The former 19-bit bank mux pulled four dispersed BRAM outputs into one
    // central comparator and was placement-sensitive at 150 MHz.
    (* keep = "true" *) wire rwc_meta_bank0_match =
        rwc_meta_bank0_q == rwc_expected_meta;
    (* keep = "true" *) wire rwc_meta_bank1_match =
        rwc_meta_bank1_q == rwc_expected_meta;
    (* keep = "true" *) wire rwc_meta_bank2_match =
        rwc_meta_bank2_q == rwc_expected_meta;
    (* keep = "true" *) wire rwc_meta_bank3_match =
        rwc_meta_bank3_q == rwc_expected_meta;
    wire rwc_query_mem_match =
        (rwc_query_meta_bank_r == 2'd0) ? rwc_meta_bank0_match :
        (rwc_query_meta_bank_r == 2'd1) ? rwc_meta_bank1_match :
        (rwc_query_meta_bank_r == 2'd2) ? rwc_meta_bank2_match :
                                          rwc_meta_bank3_match;
    wire rwc_query_meta_match = rwc_query_bypass_valid_r
        ? (rwc_query_bypass_meta_r == rwc_expected_meta)
        : rwc_query_mem_match;
    wire rwc_lookup_active = adaptive_word_mode && rwc_ready;
    wire rwc_m1_hit = rwc_lookup_active && !cacheop_inv &&
                      rwc_query_valid_r &&
                      (|data_ren) &&
                      rwc_query_meta_match;

`ifndef SYNTHESIS
    wire [RWC_META_WID-1:0] rwc_query_mem_meta_reference =
        (rwc_query_meta_bank_r == 2'd0) ? rwc_meta_bank0_q :
        (rwc_query_meta_bank_r == 2'd1) ? rwc_meta_bank1_q :
        (rwc_query_meta_bank_r == 2'd2) ? rwc_meta_bank2_q :
                                          rwc_meta_bank3_q;
    wire [RWC_META_WID-1:0] rwc_query_meta_reference =
        rwc_query_bypass_valid_r ? rwc_query_bypass_meta_r
                                 : rwc_query_mem_meta_reference;
    always @(posedge cpu_clk) begin
        if (cpu_rstn &&
            (rwc_query_meta_match !==
             (rwc_query_meta_reference == rwc_expected_meta)))
            $fatal(1, "RWC bank-local metadata match differs from reference");
    end
`endif

    wire live_read_uncached = (data_raddr[31:16] == 16'h1F00) ||
                              (data_raddr[31:16] == 16'hBFD0);
    // In random/one-word mode a tag lookup cannot produce useful locality:
    // short refills are deliberately no-allocate.  Launch a cached short
    // request directly from IDLE, using either the live M1 pulse or the one
    // buffered request retained while a preceding refill completed.  Normal
    // line mode and uncached/peripheral accesses keep the original
    // IDLE->TAG_CHECK->RD_MEM sequencing.
    // In normal line mode preserve the live M1 launch.  In adaptive word mode
    // the RWC hit/miss decision comes from a deep cascaded BRAM; retain a miss
    // in read_req_valid and launch it on the following cycle.  This prevents
    // BRAM -> tag compare -> external-request/CDC from becoming one path.
    wire        fast_read_live = (|data_ren) && !rwc_lookup_active;
    // Only a registered miss may leave the RWC lookup path.  Keeping the hit
    // result out of the external request cone prevents a local hit from also
    // launching a duplicate memory transaction.
    // The RWC compare is captured in rwc_hit_pending_r.  A request is retained
    // unconditionally at the M1 edge, then this registered hit bit suppresses
    // the external miss path on the following cycle.  Consequently the deep
    // RWC metadata BRAM no longer drives read_req_valid directly.
    wire        rwc_miss_pending = read_req_valid &&
                                   !rwc_hit_request_r;
    wire        fast_read_pending = fast_read_live || rwc_miss_pending;
    // A retained request is older than any live M1 candidate and therefore
    // owns the single pending slot.  Select the address with the registered
    // pending bit, not with data_ren: Store->Load blocking is allowed to gate
    // the request pulse, but must not ripple through the address, store-shadow
    // CAM and CDC strict-order payload.  In the normal direct path
    // read_req_valid is clear and data_raddr is selected exactly as before.
    wire [31:0] fast_read_addr =
        rwc_miss_pending ? data_addr_r : data_raddr;
    wire        fast_read_uncached =
                     (fast_read_addr[31:16] == 16'h1F00) ||
                     (fast_read_addr[31:16] == 16'hBFD0);
    wire        fast_short_candidate = current_state == IDLE &&
                     adaptive_word_mode && fast_read_pending &&
                     !fast_read_uncached;
    wire        fast_short_accept = fast_short_candidate && dev_rrdy;
    assign cpu_order_addr = (current_state == RD_MEM) ? data_addr_r :
                                                         fast_read_addr;
    wire adaptive_local_read = adaptive_prev_read_valid &&
                              ((data_raddr[31:5] == adaptive_prev_read_addr[31:5]) ||
                               (data_raddr == adaptive_prev_read_addr + 32'd4));
    wire cached_miss_accept = current_state == RD_MEM && dev_rrdy &&
                              !rd_uncached;

    wire rwc_store_capture = (|data_wen) && !live_write_uncached;
    wire rwc_store_event = rwc_store_pending_r;
    wire rwc_fill_event = rwc_fill_pending &&
                          (current_state == REFILL) && refill_short &&
                          !refill_uncached && dev_rvalid;

    // Canonical simple-dual-port RAM template for the 128Kx32 data array.
    // Keep every bypass decision out of this process so Vivado 2019.2 can
    // infer the intended RAMB36 primitives.
    always @(posedge cpu_clk) begin
        rwc_query_mem_data_r <= rwc_data_mem[rwc_query_index];
        if (rwc_data_we_r)
            rwc_data_mem[rwc_write_index_r] <= rwc_write_data_r;
    end

    // Four independent synchronous metadata banks.  Only the addressed bank
    // updates its read output; rwc_query_meta_bank_r selects that same output
    // after the edge.  Read/write collisions remain covered by the existing
    // registered write-forward path below, exactly as in the monolithic RAM.
    always @(posedge cpu_clk) begin
        rwc_query_meta_bank_r <= rwc_query_meta_bank;
        case (rwc_query_meta_bank)
            2'd0: rwc_meta_bank0_q <= rwc_meta_mem_b0[rwc_query_meta_row];
            2'd1: rwc_meta_bank1_q <= rwc_meta_mem_b1[rwc_query_meta_row];
            2'd2: rwc_meta_bank2_q <= rwc_meta_mem_b2[rwc_query_meta_row];
            default:
                  rwc_meta_bank3_q <= rwc_meta_mem_b3[rwc_query_meta_row];
        endcase

        if (rwc_meta_we_r) begin
            case (rwc_write_meta_bank)
                2'd0: rwc_meta_mem_b0[rwc_write_meta_row] <= rwc_write_meta_r;
                2'd1: rwc_meta_mem_b1[rwc_write_meta_row] <= rwc_write_meta_r;
                2'd2: rwc_meta_mem_b2[rwc_write_meta_row] <= rwc_write_meta_r;
                default:
                      rwc_meta_mem_b3[rwc_write_meta_row] <= rwc_write_meta_r;
            endcase
        end
    end

    // Deterministic write-forward for a query colliding with a Store update.
    // This is a small registered mux after the BRAM, not another RAM read or
    // write port.
    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            rwc_query_addr_r         <= 32'b0;
            rwc_query_valid_r        <= 1'b0;
            rwc_query_bypass_valid_r <= 1'b0;
            rwc_query_bypass_data_r  <= 32'b0;
            rwc_query_bypass_meta_r  <= {RWC_META_WID{1'b0}};
        end else begin
            rwc_query_addr_r  <= early_read_addr;
            rwc_query_valid_r <= early_read_valid;
            // The pending Store is newer than the command currently reaching
            // BRAM and therefore has priority on a same-index collision.
            rwc_query_bypass_valid_r <=
                (rwc_store_event &&
                 (rwc_store_index == rwc_query_index)) ||
                (rwc_meta_we_r &&
                 (rwc_write_index_r == rwc_query_index));
            if (rwc_store_event &&
                (rwc_store_index == rwc_query_index)) begin
                rwc_query_bypass_data_r <= rwc_store_data_r;
                rwc_query_bypass_meta_r <= (rwc_store_wen_r == 4'hf)
                                         ? {rwc_generation, rwc_store_tag}
                                         : {RWC_META_WID{1'b0}};
            end else begin
                rwc_query_bypass_data_r <= rwc_write_data_r;
                rwc_query_bypass_meta_r <= rwc_write_meta_r;
            end
        end
    end

    // Register both sides of the RWC write protocol.  Consecutive Stores are
    // accepted one per cycle: the older pending Store becomes the final RAM
    // command while the new Store replaces the pending entry.
    always @(posedge cpu_clk) begin
        if (!cpu_rstn || cacheop_inv) begin
            rwc_store_pending_r  <= 1'b0;
            rwc_store_addr_r     <= 32'b0;
            rwc_store_data_r     <= 32'b0;
            rwc_store_wen_r      <= 4'b0;
            rwc_data_we_r        <= 1'b0;
            rwc_meta_we_r        <= 1'b0;
            rwc_write_index_r    <= {RWC_INDEX_WID{1'b0}};
            rwc_write_data_r     <= 32'b0;
            rwc_write_meta_r     <= {RWC_META_WID{1'b0}};
        end else begin
            if (rwc_clearing) begin
                rwc_store_pending_r <= 1'b0;
            end else begin
                rwc_store_pending_r <= rwc_store_capture;
                if (rwc_store_capture) begin
                    rwc_store_addr_r <= data_addr;
                    rwc_store_data_r <= data_wdata;
                    rwc_store_wen_r  <= data_wen;
                end
            end
            rwc_data_we_r        <= rwc_data_we;
            rwc_meta_we_r        <= rwc_meta_we;
            rwc_write_index_r    <= rwc_write_index;
            rwc_write_data_r     <= rwc_write_data;
            rwc_write_meta_r     <= rwc_write_meta;
        end
    end

    // RWC result boundary (M1 hit decision -> registered DCache response).
    // A cache operation invalidates both the array contents and any response
    // that was produced from the pre-invalidation epoch.
    always @(posedge cpu_clk) begin
        if (!cpu_rstn || cacheop_inv) begin
            rwc_hit_pending_r <= 1'b0;
            rwc_hit_request_r <= 1'b0;
            rwc_hit_data_r    <= 32'b0;
        end else begin
            rwc_hit_pending_r <= rwc_m1_hit;
            rwc_hit_request_r <= rwc_m1_hit;
            // Sample every cycle so the tag compare drives only the 1-bit
            // pending result, not 32 data-register clock-enables.  This also
            // lets Vivado absorb the data register into the BRAM output stage.
            rwc_hit_data_r <= rwc_query_data;
        end
    end

    // Build the single write-port payload separately from the RAM template.
    always @(*) begin
        rwc_data_we     = 1'b0;
        rwc_meta_we     = 1'b0;
        rwc_write_index = {RWC_INDEX_WID{1'b0}};
        rwc_write_data  = 32'b0;
        rwc_write_meta  = {RWC_META_WID{1'b0}};
        if (cpu_rstn && !cacheop_inv) begin
            if (rwc_clearing) begin
                rwc_meta_we     = 1'b1;
                rwc_write_index = rwc_clear_index;
            end else if (rwc_store_event) begin
                rwc_meta_we     = 1'b1;
                rwc_write_index = rwc_store_index;
                if (rwc_store_wen_r == 4'hf) begin
                    rwc_data_we    = 1'b1;
                    rwc_write_data = rwc_store_data_r;
                    rwc_write_meta = {rwc_generation, rwc_store_tag};
                end
            end else if (rwc_fill_event && !refill_killed) begin
                rwc_data_we     = 1'b1;
                rwc_meta_we     = 1'b1;
                rwc_write_index = rwc_fill_index;
                rwc_write_data  = dev_rdata;
                rwc_write_meta  = {rwc_generation, rwc_fill_tag};
            end
        end
    end

    // Write/maintenance port.  A full Store allocates the exact new word; a
    // partial Store conservatively invalidates its direct-mapped slot.  This
    // keeps byte/half Stores correct without a second same-cycle read port.
    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            rwc_ready        <= !rwc_runtime_started;
            rwc_clearing     <= rwc_runtime_started;
            rwc_clear_drain_r<= 1'b0;
            rwc_clear_index  <= {RWC_INDEX_WID{1'b0}};
            rwc_fill_pending <= 1'b0;
            rwc_fill_addr    <= 32'b0;
        end else if (cacheop_inv && !rwc_clearing && !rwc_clear_drain_r) begin
            rwc_clear_index  <= {RWC_INDEX_WID{1'b0}};
            rwc_fill_pending <= 1'b0;
            if (&rwc_generation) begin
                // Wrap cannot reuse generation 0/1 while old matching entries
                // remain.  Disable hits and physically clear once per 63
                // logical invalidations.
                rwc_generation <= {{(RWC_GEN_WID-1){1'b0}}, 1'b1};
                rwc_ready      <= 1'b0;
                rwc_clearing   <= 1'b1;
                rwc_clear_drain_r <= 1'b0;
            end else begin
                rwc_generation <= rwc_generation + 1'b1;
                rwc_ready      <= 1'b1;
                rwc_clearing   <= 1'b0;
                rwc_clear_drain_r <= 1'b0;
            end
        end else begin
            rwc_runtime_started <= 1'b1;
            if (rwc_clearing) begin
                if (rwc_clear_index == RWC_ENTRIES-1) begin
                    rwc_clear_index <= {RWC_INDEX_WID{1'b0}};
                    rwc_clearing    <= 1'b0;
                    rwc_clear_drain_r <= 1'b1;
                    rwc_ready       <= 1'b0;
                end else begin
                    rwc_clear_index <= rwc_clear_index + 1'b1;
                end
            end else if (rwc_clear_drain_r) begin
                // The final clear command reaches BRAM on this edge.  Hits
                // become legal only after that command has completed.
                rwc_clear_drain_r <= 1'b0;
                rwc_ready         <= 1'b1;
            end

            if (fast_short_accept) begin
                rwc_fill_pending <= rwc_ready;
                rwc_fill_addr    <= fast_read_addr;
            end else if (rwc_fill_event) begin
                rwc_fill_pending <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    // The one-entry request protocol never presents a different live request
    // while a retained request is waiting in IDLE.  Make that invariant
    // executable so the registered-priority timing cut cannot hide a dropped
    // request in simulation.
    always @(posedge cpu_clk) begin
        if (cpu_rstn &&
            (rwc_hit_request_r !== rwc_hit_pending_r))
            $fatal(1, "DCache request-local RWC hit copy diverged");
        if (cpu_rstn && current_state == IDLE && adaptive_word_mode &&
            rwc_miss_pending && fast_read_live &&
            (data_addr_r != data_raddr))
            $fatal(1, "DCache live request collided with retained request");

        // EX supplies the synchronous RWC index exactly one pipeline boundary
        // before the matching M1 request.  Stalls hold both payloads, so an
        // active lookup may never be consumed by a different index.  Keep the
        // protocol invariant executable instead of rebuilding a 17-bit carry
        // comparator after the deep BRAM output on every hit/miss decision.
        if (cpu_rstn && rwc_lookup_active && rwc_query_valid_r &&
            (|data_ren) &&
            (data_raddr[RWC_INDEX_WID+1:2] !=
             rwc_query_addr_r[RWC_INDEX_WID+1:2]))
            $fatal(1, "RWC EX probe index does not match M1 Load index");
    end
`endif

    wire hit_r = current_state == TAG_CHECK && (|data_ren_r) && !rd_uncached &&
                 valid_bit && tag_shadow[index_from_cpu] == tag_from_cpu;
    (* max_fanout = 24 *) wire hit_w =
                 w_state == W_TAG_CHECK && (|data_wen_r) && !wr_uncached &&
                 store_hit_r;

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            data_addr_r    <= 32'h0;
            data_ren_r     <= 4'h0;
            read_req_valid <= 1'b0;
            pending_refill_same_line_r <= 1'b0;
            data_waddr_r   <= 32'h0;
            data_wen_r     <= 4'h0;
            data_wdata_r   <= 32'h0;
            store_ram_addr_r <= {CACHE_RAM_ADDR_WID{1'b0}};
            store_hit_r    <= 1'b0;
        end else begin
            // MEM_REQ pulses data_ren for one cycle.  After an early miss
            // response, retain one following read until this refill finishes.
            if (|data_ren) begin
                data_addr_r    <= data_raddr;
                data_ren_r     <= data_ren;
                // Retain every request at this boundary.  The registered
                // rwc_hit_pending_r bit gates the following-cycle miss launch,
                // keeping the deep metadata compare off this D input.
                read_req_valid <= 1'b1;
                // A hit-under-refill request is already forced through the
                // registered pending slot.  Capture its line relationship on
                // that same edge so refill tag/index cannot later feed the
                // 32-bit response-data mux in the Load-result cycle.
                pending_refill_same_line_r <=
                    (current_state == REFILL) &&
                    !refill_uncached && !refill_short &&
                    !refill_killed &&
                    (data_raddr[31:OFFSET_WID] ==
                     {refill_tag, refill_index});
            end else if (data_valid) begin
                read_req_valid <= 1'b0;
                pending_refill_same_line_r <= 1'b0;
            end

            // A later store must not overwrite an in-progress read refill.
            if (|data_wen) begin
                data_waddr_r <= data_addr;
                data_wen_r   <= data_wen;
                data_wdata_r <= data_wdata;
                store_ram_addr_r <= {
                    live_write_index,
                    active_bank[live_write_index],
                    data_addr[OFFSET_WID-1:2]
                };
                store_hit_r  <= live_store_hit;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 返回CPU的读结果
    // -------------------------------------------------------------------------
    // Return the requested word first, while the remaining words keep filling.
    wire critical_rvalid = current_state == REFILL && !refill_uncached &&
                           dev_rvalid && recv_cnt == 0;
    wire uncached_rvalid = current_state == REFILL && refill_uncached && dev_rvalid;

    // -------------------------------------------------------------------------
    // Refill数据缓冲和写命中合并
    // -------------------------------------------------------------------------
    reg [`CACHE_BLK_SIZE-1:0] cache_line_data;
    reg [`CACHE_BLK_SIZE-1:0] cache_line_data_w;
    wire [$clog2(`CACHE_BLK_LEN)-1:0] refill_word_offset =
                                      refill_start_offset + recv_cnt;
    wire [$clog2(`CACHE_BLK_LEN)-1:0] write_word_offset =
                                      data_waddr_r[OFFSET_WID-1:2];

    // Hit-under-refill is intentionally restricted to the registered pending
    // request.  There is no live M1-address -> response combinational path.
    // A word may be consumed from an earlier refill beat, or bypassed from the
    // beat arriving on this cycle.  Short/no-allocate and killed refills retain
    // their original blocking behaviour.
    wire [$clog2(`CACHE_BLK_LEN)-1:0] pending_refill_word_offset =
                                      data_addr_r[OFFSET_WID-1:2];
    wire pending_refill_same_line = current_state == REFILL &&
                                    rwc_miss_pending && (|data_ren_r) &&
                                    !refill_uncached && !refill_short &&
                                    !refill_killed &&
                                    pending_refill_same_line_r;
    wire refill_hit_current_beat = pending_refill_same_line && dev_rvalid &&
                                   pending_refill_word_offset ==
                                   refill_word_offset;
    wire refill_hit_buffered_word = pending_refill_same_line &&
                                    refill_word_valid[
                                      pending_refill_word_offset];
    wire refill_hit_rvalid = refill_hit_current_beat |
                             refill_hit_buffered_word;
    wire [31:0] refill_hit_word = refill_hit_current_beat
                                ? dev_rdata
                                : cache_line_data[
                                    pending_refill_word_offset*32 +: 32];

    always @(*) begin
        data_valid = rwc_hit_pending_r | hit_r | critical_rvalid | uncached_rvalid |
                     refill_hit_rvalid;
        // Every legal architectural Load enters DCache with data_ren=4'hf;
        // byte/half selection and sign extension use the registered address
        // metadata at the CPU result boundary.  Reapplying that constant mask
        // here inserted an otherwise redundant LUT level between BRAM and the
        // load-result register.
        data_rdata = rwc_hit_pending_r ? rwc_hit_data_r :
                     critical_rvalid ? dev_rdata :
                     uncached_rvalid ? dev_rdata :
                     refill_hit_rvalid ? refill_hit_word : cache_word;
    end

    always @(*) begin
        cache_line_data_w = cache_line_data;
        if (current_state == REFILL && dev_rvalid && !refill_uncached)
            cache_line_data_w[refill_word_offset*32 +: 32] = dev_rdata;
    end

    wire refill_done = current_state == REFILL && !refill_uncached && dev_rvalid &&
                       (refill_short ? (recv_cnt == 0) :
                                       (recv_cnt == `CACHE_BLK_LEN - 1));
    // A Store captured just before the read FSM entered REFILL is no longer a
    // live data_wen pulse, but it can still race the incoming line.  Treat its
    // registered write transaction as a conflict as well.  Stores to another
    // line are safe: port A updates that line's active bank while port B fills
    // this line's inactive bank.
    wire registered_store_during_refill = current_state == REFILL &&
                         ((w_state == W_TAG_CHECK) || (w_state == W_STAT0)) &&
                         (|data_wen_r);
    wire registered_store_same_refill_line =
                         registered_store_during_refill &&
                         (data_waddr_r[31:OFFSET_WID] ==
                          {refill_tag, refill_index});
    wire refill_store_conflict = store_same_refill_line |
                                 registered_store_same_refill_line;
    // CACOP wins over an in-flight refill of the same direct-mapped index.
    // In particular, a last-beat CACOP must not let commit revalidate the line
    // or publish the just-invalidated inactive bank.
    wire cacheop_same_refill_index = current_state == REFILL && cacheop_inv &&
                                     (cacheop_index == refill_index);
    wire refill_kill_event = refill_store_conflict |
                             cacheop_same_refill_index;
    // A one-word refill remains deliberately no-allocate: publishing it as a
    // full line would turn seven unread words into false hits.  A killed full
    // refill may finish writing scratch data, but never flips active_bank.
    wire refill_commit = refill_done && !refill_short && !refill_killed &&
                         !refill_kill_event;

    always @(posedge cpu_clk) begin
        if (refill_commit)
            tag_shadow[refill_index] <= refill_tag;
    end

    // Preserve the former request-port arbitration exactly.  A Store hit owns
    // port A for its merged full-word write and keeps a simultaneous Load pending for one
    // cycle; otherwise live requests pre-read the next lookup word.
    wire [INDEX_WID-1:0] live_index = (|data_wen) ? live_write_index :
                                                     live_read_index;
    wire [WORD_WID-1:0] live_word_offset = (|data_wen)
                                      ? data_addr[OFFSET_WID-1:2]
                                      : data_raddr[OFFSET_WID-1:2];
    wire [INDEX_WID-1:0] cache_lookup_index =
                                      (|data_ren || |data_wen) ? live_index :
                                      ((w_state == W_TAG_CHECK)
                                         ? index_from_write : index_from_cpu);
    wire [WORD_WID-1:0] cache_lookup_word =
                                      (|data_ren || |data_wen) ? live_word_offset :
                                      ((w_state == W_TAG_CHECK)
                                         ? write_word_offset : word_offset);
    wire [CACHE_RAM_ADDR_WID-1:0] cache_lookup_addr = {
        cache_lookup_index,
        active_bank[cache_lookup_index],
        cache_lookup_word
    };
    // Whole-address priority is deliberate: an older Store hit writes the
    // exact physical word read on its request edge, even if a same-index,
    // different-tag refill has since flipped active_bank.
    wire [CACHE_RAM_ADDR_WID-1:0] cache_port_a_addr = hit_w
                                      ? store_ram_addr_r : cache_lookup_addr;
    wire cache_port_a_we = hit_w;
    reg [31:0] cache_store_word_w;
    integer cache_store_byte;
    always @(*) begin
        cache_store_word_w = cache_word_r;
        for (cache_store_byte = 0; cache_store_byte < 4;
             cache_store_byte = cache_store_byte + 1) begin
            if (data_wen_r[cache_store_byte])
                cache_store_word_w[cache_store_byte*8 +: 8] =
                    data_wdata_r[cache_store_byte*8 +: 8];
        end
    end

    wire cache_refill_we = current_state == REFILL && dev_rvalid &&
                           !refill_uncached && !refill_short;
    wire cache_refill_bank = ~active_bank[refill_index];
    wire [CACHE_RAM_ADDR_WID-1:0] cache_port_b_addr = {
        refill_index, cache_refill_bank, refill_word_offset
    };

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            valid_bits <= {`CACHE_BLK_NUM{1'b0}};
            active_bank <= {`CACHE_BLK_NUM{1'b0}};
        end else begin
            if (refill_commit) begin
                valid_bits[refill_index] <= 1'b1;
                active_bank[refill_index] <= ~active_bank[refill_index];
            end
            if (cacheop_inv)
                valid_bits[cacheop_index] <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // 512x32 ping-pong true-dual-port Cache RAM
    // -------------------------------------------------------------------------
    // Port A is the normal synchronous lookup plus a full-word Store-hit
    // update.  The live Store address is presented one cycle earlier, so its
    // old word is already in cache_word_r during W_TAG_CHECK; byte/half Stores
    // merge locally and still issue one 32-bit RAM write.  Keeping both ports
    // full-word avoids four replicated byte-lane BRAMs in Vivado 2019.2.
    // Port B streams full refill words into the inactive bank.
    always @(posedge cpu_clk) begin
        cache_word_r <= cache_word_mem[cache_port_a_addr];
        if (cache_port_a_we)
            cache_word_mem[cache_port_a_addr] <= cache_store_word_w;
    end

    always @(posedge cpu_clk) begin
        if (cache_refill_we)
            cache_word_mem[cache_port_b_addr] <= dev_rdata;
    end

`ifndef SYNTHESIS
    integer cache_assert_line;
    reg [`CACHE_BLK_NUM-1:0] cache_active_bank_prev;
    reg cache_bank_check_armed;
    reg cache_refill_commit_prev;
    reg [INDEX_WID-1:0] cache_refill_index_prev;
    reg [TAG_WID-1:0] cache_refill_tag_prev;
    reg [CACHE_RAM_ADDR_WID-1:0] cache_port_a_addr_r;
    reg cache_post_commit_load_r;
    reg [INDEX_WID-1:0] cache_post_commit_index_r;
    reg [WORD_WID-1:0] cache_post_commit_word_r;

    // Executable invariants for the ping-pong protocol.  These checks are
    // simulation-only and therefore cannot alter BRAM inference or timing.
    always @(posedge cpu_clk) begin
        cache_port_a_addr_r <= cache_port_a_addr;
        if (!cpu_rstn) begin
            cache_active_bank_prev   <= {`CACHE_BLK_NUM{1'b0}};
            cache_bank_check_armed   <= 1'b0;
            cache_refill_commit_prev <= 1'b0;
            cache_refill_index_prev  <= {INDEX_WID{1'b0}};
            cache_refill_tag_prev    <= {TAG_WID{1'b0}};
            cache_post_commit_load_r <= 1'b0;
            cache_post_commit_index_r<= {INDEX_WID{1'b0}};
            cache_post_commit_word_r <= {WORD_WID{1'b0}};
        end else begin
            // The CPU memory-request buffer serializes these combinations.
            // The word-RAM port priorities rely on that public protocol, so
            // keep the assumptions executable instead of silently selecting
            // and dropping one request.  CACOP during REFILL is supported and
            // kills a same-index refill; TAG_CHECK/RD_MEM overlap is forbidden
            // by the upstream global cache-operation serialization.
            if ((|data_wen) && (w_state != W_IDLE))
                $fatal(1, "DCache Store request arrived while write slot busy");
            if ((|data_wen) && (|data_ren))
                $fatal(1, "DCache simultaneous live Load and Store unsupported");
            if (hit_w && (|data_wen))
                $fatal(1, "DCache old Store write collided with new Store lookup");
            if (cacheop_inv &&
                ((current_state == TAG_CHECK) || (current_state == RD_MEM)))
                $fatal(1, "DCache CACOP overlapped serialized read lookup/request");

            if (cache_bank_check_armed) begin
                for (cache_assert_line = 0;
                     cache_assert_line < `CACHE_BLK_NUM;
                     cache_assert_line = cache_assert_line + 1) begin
                    if (active_bank[cache_assert_line] !==
                        (cache_active_bank_prev[cache_assert_line] ^
                         (cache_refill_commit_prev &&
                          (cache_refill_index_prev ==
                           cache_assert_line[INDEX_WID-1:0]))))
                        $fatal(1, "DCache active bank changed without refill commit");
                end
                if (cache_refill_commit_prev) begin
                    if (!valid_bits[cache_refill_index_prev])
                        $fatal(1, "DCache refill commit did not validate line");
                    if (tag_shadow[cache_refill_index_prev] !==
                        cache_refill_tag_prev)
                        $fatal(1, "DCache tag and active-bank commit diverged");
                end
            end

            if (hit_r &&
                (cache_port_a_addr_r !==
                 {index_from_cpu, active_bank[index_from_cpu], word_offset}))
                $fatal(1, "DCache hit data came from wrong line/bank/word");
            if (hit_w &&
                (cache_port_a_addr_r !==
                 store_ram_addr_r))
                $fatal(1, "DCache Store merge read wrong line/bank/word");

            if (refill_commit && !cache_refill_we)
                $fatal(1, "DCache commit without final inactive-bank write");
            if (refill_commit &&
                (cache_port_b_addr[WORD_WID] ===
                 active_bank[refill_index]))
                $fatal(1, "DCache refill wrote active bank");
            if (cache_port_a_we &&
                (cache_port_a_addr !== store_ram_addr_r))
                $fatal(1, "DCache Store did not use request-edge physical address");
            if (cache_port_a_we && cache_refill_we &&
                (cache_port_a_addr == cache_port_b_addr))
                $fatal(1, "DCache dual-port writes collided");
            if (refill_done && (refill_killed || refill_kill_event) &&
                refill_commit)
                $fatal(1, "DCache killed refill changed architectural bank");
            if (cacheop_same_refill_index && refill_commit)
                $fatal(1, "DCache CACOP lost priority over refill commit");

            // A Load arriving on the final refill beat is captured as pending.
            // Once port A is free, it must be reissued against the bank that
            // was just published, never against the pre-commit bank address.
            if (cache_post_commit_load_r && !hit_w) begin
                if (cache_port_a_addr !==
                    {cache_post_commit_index_r,
                     active_bank[cache_post_commit_index_r],
                     cache_post_commit_word_r})
                    $fatal(1, "DCache pending Load did not re-read committed bank");
                cache_post_commit_load_r <= 1'b0;
            end
            if (refill_commit && (|data_ren) &&
                (data_raddr[31:OFFSET_WID] ==
                 {refill_tag, refill_index})) begin
                cache_post_commit_load_r  <= 1'b1;
                cache_post_commit_index_r <=
                    data_raddr[OFFSET_WID+INDEX_WID-1:OFFSET_WID];
                cache_post_commit_word_r <= data_raddr[OFFSET_WID-1:2];
            end

            cache_active_bank_prev   <= active_bank;
            cache_bank_check_armed   <= 1'b1;
            cache_refill_commit_prev <= refill_commit;
            cache_refill_index_prev  <= refill_index;
            cache_refill_tag_prev    <= refill_tag;
        end
    end
`endif

    always @(posedge cpu_clk) begin
        if (!cpu_rstn)
            current_state <= IDLE;
        else
            current_state <= next_state;
    end

    always @(*) begin
        // 读请求主状态机
        case (current_state)
            // Port A preserves the former single-lookup contract.  A Store hit
            // owns it for its byte write, so a new cached Load presented on the
            // same cycle remains in read_req_valid for one cycle.  Store misses
            // do not write the RAM and therefore do not block the lookup.
            IDLE:      next_state = fast_short_candidate
                                   ? (dev_rrdy ? REFILL : IDLE)
                                   : (fast_read_pending
                                      ? (hit_w ? IDLE : TAG_CHECK)
                                      : IDLE);
            TAG_CHECK: next_state = hit_r ? ((|data_ren) ? TAG_CHECK : IDLE) : RD_MEM;
            RD_MEM:    next_state = dev_rrdy ? REFILL : RD_MEM;
            REFILL:    next_state = refill_uncached
                                   ? (dev_rvalid ? IDLE : REFILL)
                                   : (refill_done ? IDLE : REFILL);
            default:   next_state = IDLE;
        endcase
    end

    always @(*) begin
        cpu_ren   = 4'h0;
        cpu_rshort = 1'b1;
        // Keep the requested word offset; the bridge wraps the rest of the
        // burst within the same cache line.
        cpu_raddr = data_addr_r;
        if (fast_short_candidate) begin
            cpu_raddr = fast_read_addr;
            if (dev_rrdy)
                cpu_ren = 4'hF;
        end else if (current_state == RD_MEM && dev_rrdy) begin
            cpu_ren = rd_uncached ? data_ren_r : 4'hF;
            cpu_rshort = rd_uncached | adaptive_word_mode;
        end
    end

    always @(posedge cpu_clk) begin
        if (!cpu_rstn || current_state == RD_MEM || fast_short_accept) begin
            recv_cnt        <= 0;
            cache_line_data <= 0;
            refill_word_valid <= {`CACHE_BLK_LEN{1'b0}};
        end else if (current_state == REFILL && dev_rvalid && !refill_uncached) begin
            recv_cnt        <= recv_cnt + 1'b1;
            cache_line_data <= cache_line_data_w;
            if (!refill_short)
                refill_word_valid[refill_word_offset] <= 1'b1;
        end
    end

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            refill_start_offset <= 0;
            refill_index        <= 0;
            refill_tag          <= 0;
            refill_uncached     <= 1'b0;
            refill_short        <= 1'b1;
            refill_killed       <= 1'b0;
        end else begin
            if (fast_short_accept) begin
                refill_start_offset <= fast_read_addr[OFFSET_WID-1:2];
                refill_index        <= fast_read_addr[OFFSET_WID+INDEX_WID-1:OFFSET_WID];
                refill_tag          <= fast_read_addr[31:OFFSET_WID+INDEX_WID];
                refill_uncached     <= 1'b0;
                refill_short        <= 1'b1;
                refill_killed       <= 1'b0;
            end else if (current_state == RD_MEM && dev_rrdy) begin
                refill_start_offset <= word_offset;
                refill_index        <= index_from_cpu;
                refill_tag          <= tag_from_cpu;
                refill_uncached     <= rd_uncached;
                refill_short        <= rd_uncached | adaptive_word_mode;
                refill_killed       <= 1'b0;
            end else if (refill_kill_event) begin
                // A same-line Store may be live or may have been captured just
                // before REFILL began.  In either case the arriving memory
                // image can be stale relative to the write-through Store, so
                // keep the old bank active.  A same-index CACOP has the same
                // priority.  Other-line Stores use the second RAM port and do
                // not discard a useful refill.
                refill_killed <= 1'b1;
            end
        end
    end

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            adaptive_word_mode      <= 1'b0;
            adaptive_miss_streak    <= 6'd0;
            adaptive_local_streak   <= 3'd0;
            adaptive_prev_read_addr <= 32'd0;
            adaptive_prev_read_valid<= 1'b0;
        end else begin
            if (!adaptive_word_mode) begin
                adaptive_local_streak <= 3'd0;
                // A same-line hit served by the active refill buffer is real
                // spatial reuse even though it never reaches TAG_CHECK.  Count
                // it like a BRAM hit, otherwise the faster path makes a
                // locality-heavy workload look like a stream of cold misses
                // and incorrectly switches the cache into one-word mode.
                if (hit_r || (refill_hit_rvalid && !critical_rvalid))
                    adaptive_miss_streak <= 6'd0;
                else if (cached_miss_accept) begin
                    if (adaptive_miss_streak == ADAPT_MISS_THRESHOLD) begin
                        adaptive_word_mode   <= 1'b1;
                        adaptive_miss_streak <= 6'd0;
                    end else begin
                        adaptive_miss_streak <= adaptive_miss_streak + 1'b1;
                    end
                end
            end else begin
                adaptive_miss_streak <= 6'd0;
            end

            if ((|data_ren) && !live_read_uncached) begin
                adaptive_prev_read_addr  <= data_raddr;
                adaptive_prev_read_valid <= 1'b1;
                if (adaptive_word_mode) begin
                    if (adaptive_local_read) begin
                        if (adaptive_local_streak == ADAPT_LOCAL_THRESHOLD) begin
                            adaptive_word_mode    <= 1'b0;
                            adaptive_local_streak <= 3'd0;
                        end else begin
                            adaptive_local_streak <= adaptive_local_streak + 1'b1;
                        end
                    end else begin
                        adaptive_local_streak <= 3'd0;
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // 写请求状态机
    // -------------------------------------------------------------------------
    // The write bridge accepts the request on this edge.  Its FIFO is the
    // architectural completion point for ordinary SRAM stores, so there is no
    // need to spend another cycle waiting for cpu_wen to return to zero.
    // Peripheral writes remain strongly ordered and complete only after the
    // bridge becomes ready again following the real bus transaction.
    // Tag lookup and write-buffer enqueue run in parallel.  The address/data
    // are already registered when W_TAG_CHECK starts, so the bridge can accept
    // an ordinary store on the same edge that updates a cache hit.
    wire wr_issue_state = (w_state == W_TAG_CHECK) || (w_state == W_STAT0);
    wire wr_accept = wr_issue_state && dev_wrdy && (|data_wen_r);
    wire wr_mem_done = wr_accept && !wr_uncached;
    wire wr_peripheral_done = (w_state == W_STAT1) && wr_uncached &&
                              dev_wrdy && (cpu_wen == 4'h0);
    wire wr_resp = wr_mem_done || wr_peripheral_done;
    // Local completion point for an ordinary write-through Store: its full
    // payload is now resident in the ordered CDC write FIFO.  Export this
    // combinational event only to the CPU store-buffer retirement flop; the
    // registered data_wresp remains the externally visible completion pulse
    // and MMIO keeps its strong bus-completion semantics.
    assign data_waccept = wr_mem_done;

    always @(posedge cpu_clk) begin
        if (!cpu_rstn)
            w_state <= W_IDLE;
        else
            w_state <= w_nstat;
    end

    always @(*) begin
        case (w_state)
            W_IDLE:      w_nstat = (|data_wen) ? W_TAG_CHECK : W_IDLE;
            W_TAG_CHECK: w_nstat = !dev_wrdy ? W_STAT0 :
                                         (wr_uncached ? W_STAT1 : W_IDLE);
            W_STAT0:     w_nstat = !dev_wrdy ? W_STAT0 :
                                         (wr_uncached ? W_STAT1 : W_IDLE);
            W_STAT1:     w_nstat = wr_resp ? W_IDLE : W_STAT1;
            default:     w_nstat = W_IDLE;
        endcase
    end

    always @(*) begin
        cpu_wen = 4'h0;
        if (wr_issue_state && dev_wrdy)
            cpu_wen = data_wen_r;
    end

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            data_wresp <= 1'b0;
            cpu_waddr  <= 32'h0;
            cpu_wperipheral <= 1'b0;
            cpu_wdata  <= 32'h0;
        end else begin
            // Ordinary stores complete through data_waccept on the FIFO
            // enqueue edge.  Keep the registered response exclusively for
            // strongly ordered peripheral stores so one request cannot
            // produce two architectural completion events.
            data_wresp <= wr_peripheral_done;
            if ((w_state == W_IDLE) && (|data_wen)) begin
                cpu_waddr <= data_addr;
                cpu_wperipheral <= live_write_uncached;
                cpu_wdata <= data_wdata;
            end
        end
    end
`ifndef SYNTHESIS
    always @(posedge cpu_clk) begin
        if (cpu_rstn && wr_issue_state &&
            (cpu_wperipheral !== wr_uncached_from_addr))
            $fatal(1, "DCache registered Store address class mismatch");
    end
`endif
`else

    assign data_waccept = 1'b0;
    assign cpu_order_addr = cpu_raddr;

    // -------------------------------------------------------------------------
    // 未启用DCache时的直通读写路径
    // -------------------------------------------------------------------------
    localparam R_IDLE  = 2'b00;
    localparam R_STAT0 = 2'b01;
    localparam R_STAT1 = 2'b11;
    reg [1:0] r_state, r_nstat;
    reg [3:0] ren_r;

    always @(posedge cpu_clk) begin
        r_state <= !cpu_rstn ? R_IDLE : r_nstat;
    end

    always @(*) begin
        case (r_state)
            R_IDLE:  r_nstat = (|data_ren) ? (dev_rrdy ? R_STAT1 : R_STAT0) : R_IDLE;
            R_STAT0: r_nstat = dev_rrdy ? R_STAT1 : R_STAT0;
            R_STAT1: r_nstat = dev_rvalid ? R_IDLE : R_STAT1;
            default: r_nstat = R_IDLE;
        endcase
    end

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            data_valid <= 1'b0;
            cpu_ren    <= 4'h0;
            cpu_rshort <= 1'b1;
        end else begin
            case (r_state)
                R_IDLE: begin
                    data_valid <= 1'b0;

                    if (|data_ren) begin
                        if (dev_rrdy)
                            cpu_ren <= data_ren;
                        else
                            ren_r   <= data_ren;

                        cpu_raddr <= data_raddr;
                        cpu_rshort <= 1'b1;
                    end else
                        cpu_ren   <= 4'h0;
                end
                R_STAT0: begin
                    cpu_ren    <= dev_rrdy ? ren_r : 4'h0;
                    cpu_rshort <= 1'b1;
                end   
                R_STAT1: begin
                    cpu_ren    <= 4'h0;
                    data_valid <= dev_rvalid ? 1'b1 : 1'b0;
                    data_rdata <= dev_rvalid ? dev_rdata : 32'h0;
                end
                default: begin
                    data_valid <= 1'b0;
                    cpu_ren    <= 4'h0;
                end 
            endcase
        end
    end

    localparam W_IDLE  = 2'b00;
    localparam W_STAT0 = 2'b01;
    localparam W_STAT1 = 2'b11;
    reg  [1:0] w_state, w_nstat;
    reg  [3:0] wen_r;
    wire       wr_resp = dev_wrdy & (cpu_wen == 4'h0) ? 1'b1 : 1'b0;

    always @(posedge cpu_clk) begin
        w_state <= !cpu_rstn ? W_IDLE : w_nstat;
    end

    always @(*) begin
        case (w_state)
            W_IDLE:  w_nstat = (|data_wen) ? (dev_wrdy ? W_STAT1 : W_STAT0) : W_IDLE;
            W_STAT0: w_nstat = dev_wrdy ? W_STAT1 : W_STAT0;
            W_STAT1: w_nstat = wr_resp ? W_IDLE : W_STAT1;
            default: w_nstat = W_IDLE;
        endcase
    end

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            data_wresp <= 1'b0;
            cpu_wen    <= 4'h0;
            cpu_wperipheral <= 1'b0;
        end else begin
            case (w_state)
                W_IDLE: begin
                    data_wresp <= 1'b0;

                    if (|data_wen) begin
                        if (dev_wrdy)
                            cpu_wen <= data_wen;
                        else
                            wen_r   <= data_wen;
                        
                        cpu_waddr  <= data_addr;
                        cpu_wperipheral <=
                            (data_addr[31:16] == 16'h1F00) ||
                            (data_addr[31:16] == 16'hBFD0);
                        cpu_wdata  <= data_wdata;
                    end else
                        cpu_wen    <= 4'h0;
                end
                W_STAT0: begin
                    cpu_wen    <= dev_wrdy ? wen_r : 4'h0;
                end
                W_STAT1: begin
                    cpu_wen    <= 4'h0;
                    data_wresp <= wr_resp ? 1'b1 : 1'b0;
                end
                default: begin
                    data_wresp <= 1'b0;
                    cpu_wen    <= 4'h0;
                end
            endcase
        end
    end

`endif

endmodule
