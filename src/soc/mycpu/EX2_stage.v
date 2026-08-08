`timescale 1ns / 1ps

`include "defines.vh"

// EX2 is the seven-stage M1 (memory-request) stage.  Besides registering the
// EX result it performs alignment checking, byte-lane formatting and emits a
// single request pulse while the stage is allowed to advance.
module EX2_stage (
    input  wire        cpu_rstn,
    input  wire        cpu_clk,
    input  wire        pl_suspend,
    input  wire        m1_read_block,
    input  wire        m1_write_block,
    input  wire        ex_valid,
    input  wire [31:0] ex_pc,
    input  wire [31:0] ex_rD2,
    input  wire [31:0] ex_ext,
    input  wire [31:0] ex_alu_C,
    input  wire [31:0] ex_mem_addr,
    input  wire [31:0] ex_wd,
    input  wire        ex_late_mul_arch_valid,
    input  wire [31:0] ex_late_mul_arch_wd,
    input  wire        ex_rf_we,
    input  wire [ 4:0] ex_wR,
    input  wire [ 1:0] ex_wd_sel,
    input  wire [ 3:0] ex_ram_we,
    input  wire [ 2:0] ex_ram_ext_op,
    input  wire        ex_ldst_unalign,
    // A Load immediately before a Store may produce only the Store data
    // operand.  The address is already final in EX, so carry that dependency
    // into M1 and fill the data from the registered Load-result boundary.
    input  wire        ex_store_data_load_dep,
    input  wire        load_result_valid,
    input  wire [31:0] load_result_data,
    output reg         x2_valid,
    output reg  [31:0] x2_pc,
    output reg  [31:0] x2_rD2,
    output reg  [31:0] x2_ext,
    output reg  [31:0] x2_alu_C,
    output reg  [31:0] x2_wd,
    output reg         x2_rf_we,
    output reg  [ 4:0] x2_wR,
    output reg  [ 1:0] x2_wd_sel,
    output reg  [ 3:0] x2_ram_we,
    output reg  [ 2:0] x2_ram_ext_op,
    output wire        x2_ldst_unalign,
    output wire        m1_load_predec,
    output wire        m1_store_predec,
    // One stage-early, alignment-checked Load probe.  The CPU top applies
    // ordering/backpressure gates and translates the address before DCache
    // may use it to launch an adaptive single-word request.
    output wire        ex_load_probe_valid,
    output wire [31:0] ex_load_probe_addr,
    output reg  [ 3:0] m1_daccess_ren,
    output wire [31:0] m1_daccess_addr,
    output reg  [ 3:0] m1_daccess_wen,
    output reg  [31:0] m1_daccess_wdata
);

    reg x2_store_data_load_dep;

    // The registered Load result can become valid on the same edge that the
    // dependent Store finally crosses EX->M1.  Consume it at that boundary;
    // otherwise the Store would enter M1 one cycle after the one-cycle result
    // pulse and its write request would be suppressed as stale.
    wire ex_store_load_ready = ex_store_data_load_dep && load_result_valid;
    wire [31:0] ex_store_data_capture = ex_store_load_ready ?
                                        load_result_data : ex_rD2;
    wire [31:0] ex_arch_result_capture = ex_late_mul_arch_valid ?
                                         ex_late_mul_arch_wd : ex_alu_C;

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            x2_valid      <= 1'b0;
            x2_pc         <= 32'b0;
            x2_rD2        <= 32'b0;
            x2_ext        <= 32'b0;
            x2_alu_C      <= 32'b0;
            x2_wd         <= 32'b0;
            x2_rf_we      <= 1'b0;
            x2_wR         <= 5'b0;
            x2_wd_sel     <= 2'b0;
            x2_ram_we     <= 4'b0;
            x2_ram_ext_op <= 3'b0;
            x2_store_data_load_dep <= 1'b0;
        end else if (!pl_suspend) begin
            x2_valid      <= ex_valid;
            x2_pc         <= ex_pc;
            x2_rD2        <= ex_store_data_capture;
            x2_ext        <= ex_ext;
            // OF/AG_BR already generated the final memory address.  Keep that
            // registered value for alignment and Load-result extension.
            x2_alu_C      <= (ex_wd_sel == `WD_RAM) ?
                             ex_mem_addr : ex_arch_result_capture;
            x2_wd         <= ex_late_mul_arch_valid ?
                             ex_late_mul_arch_wd : ex_wd;
            x2_rf_we      <= ex_rf_we & ex_valid;
            x2_wR         <= ex_wR;
            x2_wd_sel     <= ex_wd_sel;
            x2_ram_we     <= ex_ram_we & {4{ex_valid}};
            x2_ram_ext_op <= ex_ram_ext_op;
            x2_store_data_load_dep <= ex_store_data_load_dep & ex_valid &
                                      !load_result_valid;
        end else if (x2_store_data_load_dep && load_result_valid) begin
            // If Store-buffer backpressure outlives the one-cycle result-valid
            // pulse, retain the corrected architectural Store operand locally.
            x2_rD2 <= load_result_data;
            x2_store_data_load_dep <= 1'b0;
        end
    end

`ifndef SYNTHESIS
    // Data equivalence is checked at the parallel candidate generators in
    // OF_stage.  At this boundary, assert that the dedicated architectural
    // result can only override an ALU writeback instruction.
    always @(posedge cpu_clk) begin
        if (cpu_rstn && !pl_suspend && ex_valid &&
            ex_late_mul_arch_valid && (ex_wd_sel != `WD_ALU))
            $fatal(1, "late-MUL architectural bypass used outside ALU result");
    end
`endif

    wire [1:0] offset = x2_alu_C[1:0];
    wire load_half_unalign = (x2_ram_we == `RAM_WE_N) &&
                             ((x2_ram_ext_op == `RAM_EXT_H) ||
                              (x2_ram_ext_op == `RAM_EXT_HU)) && offset[0];
    wire load_word_unalign = (x2_ram_we == `RAM_WE_N) &&
                             (x2_ram_ext_op == `RAM_EXT_N) && (offset != 2'b0);
    wire store_half_unalign = (x2_ram_we == `RAM_WE_H) && offset[0];
    wire store_word_unalign = (x2_ram_we == `RAM_WE_W) && (offset != 2'b0);
    assign x2_ldst_unalign = x2_valid && (x2_wd_sel == `WD_RAM) &&
                             (load_half_unalign | load_word_unalign |
                              store_half_unalign | store_word_unalign);
    (* keep = "true" *) reg [31:0] m1_addr_predec;
    assign m1_daccess_addr = m1_addr_predec;

    // Predecode the memory request on the same EX->M1 edge which captures the
    // rest of the M1 payload.  The final read/write pulses use equivalent,
    // type-local block terms.  Keeping the mutually exclusive store-full term
    // out of the read gate prevents a false store-control -> read-FIFO path.
    wire [1:0] ex_offset = ex_mem_addr[1:0];
    wire ex_load_half_unalign = (ex_ram_we == `RAM_WE_N) &&
                                ((ex_ram_ext_op == `RAM_EXT_H) ||
                                 (ex_ram_ext_op == `RAM_EXT_HU)) &&
                                ex_offset[0];
    wire ex_load_word_unalign = (ex_ram_we == `RAM_WE_N) &&
                                (ex_ram_ext_op == `RAM_EXT_N) &&
                                (ex_offset != 2'b0);
    wire ex_store_half_unalign = (ex_ram_we == `RAM_WE_H) && ex_offset[0];
    wire ex_store_word_unalign = (ex_ram_we == `RAM_WE_W) &&
                                 (ex_offset != 2'b0);
    wire ex_m1_ldst_unalign = ex_valid && (ex_wd_sel == `WD_RAM) &&
                               (ex_load_half_unalign |
                                ex_load_word_unalign |
                                ex_store_half_unalign |
                                ex_store_word_unalign);
    wire ex_m1_issue = ex_valid && (ex_wd_sel == `WD_RAM) &&
                       !ex_m1_ldst_unalign;
    wire ex_load_type_valid = (ex_ram_ext_op == `RAM_EXT_B)  ||
                              (ex_ram_ext_op == `RAM_EXT_BU) ||
                              (ex_ram_ext_op == `RAM_EXT_H)  ||
                              (ex_ram_ext_op == `RAM_EXT_HU) ||
                              (ex_ram_ext_op == `RAM_EXT_N);
    assign ex_load_probe_valid = ex_m1_issue &&
                                 (ex_ram_we == `RAM_WE_N) &&
                                 ex_load_type_valid;
    assign ex_load_probe_addr  = ex_mem_addr;

    // Keep this as a real EX->M1 register boundary.  Without KEEP, Vivado can
    // prove it equivalent to the x2 control/address registers and rebuild the
    // load type/alignment decode after the boundary, recreating the long
    // x2_wd_sel -> DCache -> ordered-read-FIFO setup path.
    (* keep = "true" *) reg [ 3:0] m1_ren_predec;
    (* keep = "true" *) reg [ 3:0] m1_wen_predec;
    reg [31:0] m1_wdata_predec;

    // Store byte-lane formatting is wiring only.  Selecting the already
    // registered load_result_data here creates the intended boundary:
    // DCache -> load_result register -> M1 Store data -> Store-buffer register.
    reg [31:0] m1_load_forward_wdata;
    always @(*) begin
        case (x2_ram_we)
            `RAM_WE_B: m1_load_forward_wdata = {4{load_result_data[7:0]}};
            `RAM_WE_H: m1_load_forward_wdata = {2{load_result_data[15:0]}};
            `RAM_WE_W: m1_load_forward_wdata = load_result_data;
            default:   m1_load_forward_wdata = 32'b0;
        endcase
    end

    // Raw, registered request class for local backpressure.  These deliberately
    // exclude the final pl_suspend gate so myCPU does not decode the x2 payload
    // again and feed that long result back into this stage's request pulse.
    assign m1_load_predec  = |m1_ren_predec;
    assign m1_store_predec = |m1_wen_predec;

    always @(posedge cpu_clk) begin
        if (!cpu_rstn) begin
            m1_ren_predec   <= 4'b0;
            m1_wen_predec   <= 4'b0;
            m1_wdata_predec <= 32'b0;
            m1_addr_predec  <= 32'b0;
        end else if (!pl_suspend) begin
            m1_ren_predec   <= 4'b0;
            m1_wen_predec   <= 4'b0;
            m1_wdata_predec <= ex_store_data_capture;
            m1_addr_predec  <= ex_mem_addr;
            if (ex_m1_issue && (ex_ram_we == `RAM_WE_N)) begin
                case (ex_ram_ext_op)
                `RAM_EXT_B, `RAM_EXT_BU,
                `RAM_EXT_H, `RAM_EXT_HU,
                    `RAM_EXT_N: begin
                        // A younger pipelined multiply no longer freezes M1,
                        // so the registered request can issue normally.
                        m1_ren_predec <= 4'hf;
                    end
                    default: m1_ren_predec <= 4'b0;
                endcase
            end else if (ex_m1_issue) begin
                case (ex_ram_we)
                `RAM_WE_B: begin
                        m1_wen_predec <= 4'b0001 << ex_offset;
                        m1_wdata_predec <= {4{ex_store_data_capture[7:0]}};
                    end
                    `RAM_WE_H: begin
                        m1_wen_predec <= ex_offset[1] ? 4'b1100 : 4'b0011;
                        m1_wdata_predec <= {2{ex_store_data_capture[15:0]}};
                    end
                    `RAM_WE_W: m1_wen_predec <= 4'b1111;
                    default: m1_wen_predec <= 4'b0;
                endcase
            end
        end else if (x2_store_data_load_dep && load_result_valid) begin
            // Preserve the corrected value when another local backpressure
            // source prevents enqueue on the result-valid cycle.
            m1_wdata_predec <= m1_load_forward_wdata;
        end
    end

    always @(*) begin
        m1_daccess_ren   = 4'b0;
        m1_daccess_wen   = 4'b0;
        m1_daccess_wdata = x2_store_data_load_dep ?
                           m1_load_forward_wdata : m1_wdata_predec;
        if (!m1_read_block)
            m1_daccess_ren = m1_ren_predec;
        // Do not enqueue stale RF data.  In the normal blocking-Load timeline
        // load_result_valid rises on the same registered edge which releases
        // M1, so this interlock adds no cycle.  It is also a safety net for any
        // future independent Store-buffer backpressure.
        if (!m1_write_block &&
            (!x2_store_data_load_dep || load_result_valid))
            m1_daccess_wen = m1_wen_predec;
    end

endmodule
