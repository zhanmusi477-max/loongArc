# Protocol-proven CDC exceptions only.  This XDC is implementation-only and is
# read late, after synthesis has created the precise synchronizer/RAM objects.
# CPU and SRAM clocks remain related; no clock pair is declared asynchronous.

# CDC-1: asynchronous FIFO Gray-pointer synchronizers.
# Startpoints: opposite-domain registered Gray pointer bits.
# Endpoints: only first-stage D pins below.  async_fifo.v changes one Gray bit
# per increment and passes it through two ASYNC_REG flops before full/empty uses
# it.  Therefore the crossing is not a single-cycle transfer.  The second stage
# and every downstream path remain normally timed.
set_false_path -to [get_pins -quiet -hier -regexp {.*(wr_ptr_gray_rdclk1_reg|rd_ptr_gray_wrclk1_reg)\[[0-9]+\]/D}]

# CDC-2: toggle/level handshakes between CPU and SRAM bus domains.
# Startpoints: done_toggle_bus, sram_ready and cpu_ready source registers.
# Endpoints: only the three first receiving synchronizer D pins.  Controls are
# held/toggled until two ASYNC_REG stages have sampled them; receivers act only
# on the second stage, which and all following logic remain normally timed.
set_false_path -to [get_pins -quiet -hier -filter {NAME =~ */done_toggle_cpu1_reg/D}]
set_false_path -to [get_pins -quiet -hier -regexp {.*write_order_done_gray_cpu1_reg\[[0-9]+\]/D}]
set_false_path -to [get_pins -quiet -hier -regexp {.*(sram_ready_cpu_sync_reg|cpu_ready_sram_sync_reg)\[0\]/D}]

# CDC-2b: DCache single-outstanding held-payload mailbox event synchronizers.
# The request toggle first enters the falling-edge *_neg ASYNC_REG; the normal
# rising-edge bus/SRAM registers are the second stage 9.760 ns later.  The
# response uses explicit CPU falling/rising ASYNC_REG stages.  Only the first
# receiving D pins are excepted, so destination-domain control remains timed.
set_false_path -to [get_pins -quiet -hier -filter \
    {NAME =~ *g_related_req_mailbox*req_toggle_bus_neg_reg/D}]
set_false_path -to [get_pins -quiet -hier -filter \
    {NAME =~ *g_related_resp_mailbox*resp_toggle_cpu1_reg/D}]

# CDC-3: asynchronous FIFO payload storage.
#
# The FWFT payload is protected by the Gray-pointer/empty handshake above, but
# it must still arrive as one coherent word before the receiver is allowed to
# pop it.  A false path here let placement and routing consume an unbounded
# amount of that protocol margin; at 135 MHz this can corrupt an instruction on
# hardware even though zero-delay RTL simulation passes.  Constrain the actual
# datapath to 10 ns instead.  This is tighter than the minimum two-CPU-cycle
# write-to-consume interval (14.814 ns at 135 MHz), while remaining applicable
# to the slower CPU-to-SRAM direction as well.  It does not relax any synchronous
# CPU path and it adds no latency or pipeline stall.
set_max_delay -datapath_only 10.000 \
    -from [get_clocks -quiet {clk_out1_pll_example clk_out2_pll_example}] \
    -through [get_pins -quiet -of_objects \
        [get_cells -quiet -hier -filter {NAME =~ */*fifo/mem_reg*}] \
        -filter {DIRECTION == OUT}]

# CDC-4: DCache held mailbox payloads.
#
# A request payload changes with its toggle, is sampled at the falling bus edge,
# and cannot reach the SRAM I/O registers until the following rising edge: at
# least one 9.760 ns half-period of stability.  A response is
# held for the complete ~19.5 ns SRAM beat and its event crosses CPU rise/fall
# before consumption on the following CPU rise.  The response bound is chosen
# below the 6.064 ns CPU period at the highest planned 165 MHz run, so the same
# protocol proof remains valid throughout the frequency sweep.  Bound the
# physical datapaths below those protocol windows instead of applying an
# unbounded false path or a multicycle path.
set_max_delay -datapath_only 9.000 \
    -from [get_cells -quiet -hier -filter \
        {NAME =~ *g_related_req_mailbox*req_payload_cpu_reg*}] \
    -to [get_clocks -quiet clk_out2_pll_example]

set_max_delay -datapath_only 5.500 \
    -from [get_cells -quiet -hier -filter \
        {NAME =~ *g_related_resp_mailbox*resp_payload_bus_reg*}] \
    -to [get_clocks -quiet clk_out1_pll_example]
