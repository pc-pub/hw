
`define FORCE_CONTENTION_ASSERTION_RESET_ACTIVE 1'b1

`ifndef SYNTHESIS
    `define FIFOGEN_KEEP_ASSERTION_VERIF_CODE
`else
    `ifdef FV_ASSERT_ON
        `define FIFOGEN_KEEP_ASSERTION_VERIF_CODE
    `endif
`endif

`include "simulate_x_tick.vh"


module NV_NVDLA_CDP_DP_data_fifo_80x9 (
      nvdla_core_clk
    , nvdla_core_rstn
    , data_wr_prdy
    , data_wr_pvld
`ifdef FV_RAND_WR_PAUSE
    , data_wr_pause
`endif
    , data_wr_pd
    , data_rd_prdy
    , data_rd_pvld
    , data_rd_pd
    , pwrbus_ram_pd
    );

// spyglass disable_block W401 -- clock is not input to module
input         nvdla_core_clk;
input         nvdla_core_rstn;
output        data_wr_prdy;
input         data_wr_pvld;
`ifdef FV_RAND_WR_PAUSE
input         data_wr_pause;
`endif
input  [8:0] data_wr_pd;
input         data_rd_prdy;
output        data_rd_pvld;
output [8:0] data_rd_pd;
input  [31:0] pwrbus_ram_pd;

//| &PerlBeg;
//|     $NV_NVDLA_CDP_DP_data_fifo_80x9_PARENT_VIVA_MODULE = "$VIVA_MODULE";
//|     $VIVA_MODULE = "NV_NVDLA_CDP_DP_data_fifo_80x9";
//| &PerlEnd;


`ifdef FV_RAND_WR_PAUSE
// FV forces this signal to trigger random stalling
wire data_wr_pause = 0;
`endif

// Master Clock Gating (SLCG)
//
// We gate the clock(s) when idle or stalled.
// This allows us to turn off numerous miscellaneous flops
// that don't get gated during synthesis for one reason or another.
//
// We gate write side and read side separately. 
// If the fifo is synchronous, we also gate the ram separately, but if
// -master_clk_gated_unified or -status_reg/-status_logic_reg is specified, 
// then we use one clk gate for write, ram, and read.
//
wire nvdla_core_clk_mgated_enable;   // assigned by code at end of this module
wire nvdla_core_clk_mgated;               // used only in synchronous fifos
NV_CLK_gate_power nvdla_core_clk_mgate( .clk(nvdla_core_clk), .reset_(nvdla_core_rstn), .clk_en(nvdla_core_clk_mgated_enable), .clk_gated(nvdla_core_clk_mgated) );

// 
// WRITE SIDE
//
// VCS coverage off
`ifndef SYNTHESIS
wire wr_pause_rand;  // random stalling
`endif
// VCS coverage on
wire wr_reserving;
reg        data_wr_busy_int;		        	// copy for internal use
assign     data_wr_prdy = !data_wr_busy_int;
assign       wr_reserving = data_wr_pvld && !data_wr_busy_int; // reserving write space?



wire       wr_popping;                          // fwd: write side sees pop?


reg  [6:0] data_wr_count;			// write-side count

wire [6:0] wr_count_next_wr_popping = wr_reserving ? data_wr_count : (data_wr_count - 1'd1); // spyglass disable W164a W484
wire [6:0] wr_count_next_no_wr_popping = wr_reserving ? (data_wr_count + 1'd1) : data_wr_count; // spyglass disable W164a W484
wire [6:0] wr_count_next = wr_popping ? wr_count_next_wr_popping : 
                                               wr_count_next_no_wr_popping;

wire wr_count_next_no_wr_popping_is_80 = ( wr_count_next_no_wr_popping == 7'd80 );
wire wr_count_next_is_80 = wr_popping ? 1'b0 :
                                          wr_count_next_no_wr_popping_is_80;
wire [6:0] wr_limit_muxed;  // muxed with simulation/emulation overrides
wire [6:0] wr_limit_reg = wr_limit_muxed;
`ifdef FV_RAND_WR_PAUSE
                          // VCS coverage off
wire       data_wr_busy_next = wr_count_next_is_80 || // busy next cycle?
                          (wr_limit_reg != 7'd0 &&      // check data_wr_limit if != 0
                           wr_count_next >= wr_limit_reg) || data_wr_pause;
                          // VCS coverage on
`else
                          // VCS coverage off
wire       data_wr_busy_next = wr_count_next_is_80 || // busy next cycle?
                          (wr_limit_reg != 7'd0 &&      // check data_wr_limit if != 0
                           wr_count_next >= wr_limit_reg)  
 // VCS coverage off
 `ifndef SYNTHESIS
 || wr_pause_rand
 `endif
 // VCS coverage on
;
                          // VCS coverage on
`endif
always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_wr_busy_int <=  1'b0;
        data_wr_count <=  7'd0;
    end else begin
	data_wr_busy_int <=  data_wr_busy_next;
	if ( wr_reserving ^ wr_popping ) begin
	    data_wr_count <=  wr_count_next;
        end 
        `ifndef SYNTHESIS
        // VCS coverage off
        else if ( !(wr_reserving ^ wr_popping) ) begin
        end else begin
            data_wr_count <=  {7{`x_or_0}};
        end
        // VCS coverage on
        `endif // SYNTHESIS
    end
end

wire       wr_pushing = wr_reserving;   // data pushed same cycle as data_wr_pvld

//
// RAM
//

reg  [6:0] data_wr_adr;			// current write address
wire [6:0] data_rd_adr_p;		// read address to use for ram
wire [8:0] data_rd_pd_p_byp_ram;		// read data directly out of ram

wire rd_enable;

wire ore;
wire do_bypass;
wire comb_bypass;
wire rd_popping;
wire [31 : 0] pwrbus_ram_pd;

// Adding parameter for fifogen to disable wr/rd contention assertion in ramgen.
// Fifogen handles this by ignoring the data on the ram data out for that cycle.


nv_ram_rwsthp_80x9 #(`FORCE_CONTENTION_ASSERTION_RESET_ACTIVE) ram (
      .clk		 ( nvdla_core_clk )
    , .pwrbus_ram_pd ( pwrbus_ram_pd )
    , .wa        ( data_wr_adr )
    , .we        ( wr_pushing && (data_wr_count != 7'd0 || !rd_popping) )
    , .di        ( data_wr_pd )
    , .ra        ( data_rd_adr_p )
    , .re        ( (do_bypass && wr_pushing) || rd_enable )
    , .dout        ( data_rd_pd_p_byp_ram )
    , .byp_sel        ( comb_bypass )
    , .dbyp        ( data_wr_pd[8:0] )
    , .ore        ( ore )
    );
// next data_wr_adr if wr_pushing=1
wire [6:0] wr_adr_next = (data_wr_adr == 7'd79) ? 7'd0 : (data_wr_adr + 1'd1);  // spyglass disable W484

// spyglass disable_block W484
always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_wr_adr <=  7'd0;
    end else begin
        if ( wr_pushing ) begin
            data_wr_adr      <=  wr_adr_next;
        end 
        `ifndef SYNTHESIS
        // VCS coverage off
        else if ( !(wr_pushing) ) begin
        end else begin
            data_wr_adr   <=  {7{`x_or_0}};
        end
        // VCS coverage on
        `endif // SYNTHESIS
    end 
end
// spyglass enable_block W484

reg  [6:0] data_rd_adr;		// current read address
// next    read address
wire [6:0] rd_adr_next = (data_rd_adr == 7'd79) ? 7'd0 : (data_rd_adr + 1'd1);   // spyglass disable W484
assign         data_rd_adr_p = rd_popping ? rd_adr_next : data_rd_adr; // for ram

// spyglass disable_block W484
always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_rd_adr <=  7'd0;
    end else begin
        if ( rd_popping ) begin
	    data_rd_adr      <=  rd_adr_next;
        end 
        `ifndef SYNTHESIS
        // VCS coverage off
        else if ( !rd_popping ) begin
        end else begin
            data_rd_adr <=  {7{`x_or_0}};
        end
        // VCS coverage on
        `endif // SYNTHESIS
    end
end
// spyglass enable_block W484

assign do_bypass = (rd_popping ? (data_wr_adr == rd_adr_next) : (data_wr_adr == data_rd_adr));
wire [8:0] data_rd_pd_p_byp = data_rd_pd_p_byp_ram;


//
// Combinatorial Bypass
//
// If we're pushing an empty fifo, mux the wr_data directly.
//
assign comb_bypass = data_wr_count == 0;
wire [8:0] data_rd_pd_p = data_rd_pd_p_byp;



//
// SYNCHRONOUS BOUNDARY
//


assign wr_popping = rd_popping;		// let it be seen immediately


wire   rd_pushing = wr_pushing;		// let it be seen immediately

//
// READ SIDE
//

wire       data_rd_pvld_p; 		// data out of fifo is valid

reg        data_rd_pvld_int;	// internal copy of data_rd_pvld
assign     data_rd_pvld = data_rd_pvld_int;
assign     rd_popping = data_rd_pvld_p && !(data_rd_pvld_int && !data_rd_prdy);

reg  [6:0] data_rd_count_p;			// read-side fifo count
// spyglass disable_block W164a W484
wire [6:0] rd_count_p_next_rd_popping = rd_pushing ? data_rd_count_p : 
                                                                (data_rd_count_p - 1'd1);
wire [6:0] rd_count_p_next_no_rd_popping =  rd_pushing ? (data_rd_count_p + 1'd1) : 
                                                                    data_rd_count_p;
// spyglass enable_block W164a W484
wire [6:0] rd_count_p_next = rd_popping ? rd_count_p_next_rd_popping :
                                                     rd_count_p_next_no_rd_popping; 
wire rd_count_p_next_rd_popping_not_0 = rd_count_p_next_rd_popping != 0;
wire rd_count_p_next_no_rd_popping_not_0 = rd_count_p_next_no_rd_popping != 0;
wire rd_count_p_next_not_0 = rd_popping ? rd_count_p_next_rd_popping_not_0 :
                                              rd_count_p_next_no_rd_popping_not_0;
assign     data_rd_pvld_p = data_rd_count_p != 0 || rd_pushing;
assign rd_enable = ((rd_count_p_next_not_0) && ((~data_rd_pvld_p) || rd_popping));  // anytime data's there and not stalled
always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_rd_count_p <=  7'd0;
    end else begin
        if ( rd_pushing || rd_popping  ) begin
	    data_rd_count_p <=  rd_count_p_next;
        end 
        `ifndef SYNTHESIS
        // VCS coverage off
        else if ( !(rd_pushing || rd_popping ) ) begin
        end else begin
            data_rd_count_p <=  {7{`x_or_0}};
        end
        // VCS coverage on
        `endif // SYNTHESIS
    end
end
wire        rd_req_next = (data_rd_pvld_p || (data_rd_pvld_int && !data_rd_prdy)) ;

always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_rd_pvld_int <=  1'b0;
    end else begin
        data_rd_pvld_int <=  rd_req_next;
    end
end
assign data_rd_pd = data_rd_pd_p;
assign ore = rd_popping;

// Master Clock Gating (SLCG) Enables
//

// plusarg for disabling this stuff:

// VCS coverage off
`ifndef SYNTHESIS
reg master_clk_gating_disabled;  initial master_clk_gating_disabled = $test$plusargs( "fifogen_disable_master_clk_gating" ) != 0;
`endif
// VCS coverage on

// VCS coverage off
`ifndef SYNTHESIS
reg wr_pause_rand_dly;  
always @( posedge nvdla_core_clk or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        wr_pause_rand_dly <=  1'b0;
    end else begin
        wr_pause_rand_dly <=  wr_pause_rand;
    end
end
`endif
// VCS coverage on
assign nvdla_core_clk_mgated_enable = ((wr_reserving || wr_pushing || wr_popping || (data_wr_pvld && !data_wr_busy_int) || (data_wr_busy_int != data_wr_busy_next)) || (rd_pushing || rd_popping || (data_rd_pvld_int && data_rd_prdy)))
                               `ifdef FIFOGEN_MASTER_CLK_GATING_DISABLED
                               || 1'b1
                               `endif
                               // VCS coverage off
                               `ifndef SYNTHESIS
                               || master_clk_gating_disabled || (wr_pause_rand != wr_pause_rand_dly)
                               `endif
                               // VCS coverage on
;


// Simulation and Emulation Overrides of wr_limit(s)
//

`ifdef EMU

`ifdef EMU_FIFO_CFG
// Emulation Global Config Override
//
assign wr_limit_muxed = `EMU_FIFO_CFG.NV_NVDLA_CDP_DP_data_fifo_80x9_wr_limit_override ? `EMU_FIFO_CFG.NV_NVDLA_CDP_DP_data_fifo_80x9_wr_limit : 7'd0;
`else
// No Global Override for Emulation 
//
assign wr_limit_muxed = 7'd0;
`endif // EMU_FIFO_CFG

`else // !EMU
`ifdef SYNTHESIS

// No Override for RTL Synthesis
//

assign wr_limit_muxed = 7'd0;

`else  

// RTL Simulation Plusarg Override


// VCS coverage off

reg wr_limit_override;
reg [6:0] wr_limit_override_value; 
assign wr_limit_muxed = wr_limit_override ? wr_limit_override_value : 7'd0;
`ifdef NV_ARCHPRO
event reinit;

initial begin
    $display("fifogen reinit initial block %m");
    -> reinit;
end
`endif

`ifdef NV_ARCHPRO
always @( reinit ) begin
`else 
initial begin
`endif
    wr_limit_override = 0;
    wr_limit_override_value = 0;  // to keep viva happy with dangles
    if ( $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x9_wr_limit" ) ) begin
        wr_limit_override = 1;
        $value$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x9_wr_limit=%d", wr_limit_override_value);
    end
end

// VCS coverage on


`endif
`endif


// Random Write-Side Stalling
// VCS coverage off
`ifndef SYNTHESIS
// VCS coverage off

// leda W339 OFF -- Non synthesizable operator
// leda W372 OFF -- Undefined PLI task
// leda W373 OFF -- Undefined PLI function
// leda W599 OFF -- This construct is not supported by Synopsys
// leda W430 OFF -- Initial statement is not synthesizable
// leda W182 OFF -- Illegal statement for synthesis
// leda W639 OFF -- For synthesis, operands of a division or modulo operation need to be constants
// leda DCVER_274_NV OFF -- This system task is not supported by DC

integer stall_probability;      // prob of stalling
integer stall_cycles_min;       // min cycles to stall
integer stall_cycles_max;       // max cycles to stall
integer stall_cycles_left;      // stall cycles left
`ifdef NV_ARCHPRO
always @( reinit ) begin
`else 
initial begin
`endif
    stall_probability      = 0; // no stalling by default
    stall_cycles_min       = 1;
    stall_cycles_max       = 10;

`ifdef NO_PLI
`else
    if ( $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x9_fifo_stall_probability" ) ) begin
        $value$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x9_fifo_stall_probability=%d", stall_probability);
    end else if ( $test$plusargs( "default_fifo_stall_probability" ) ) begin
        $value$plusargs( "default_fifo_stall_probability=%d", stall_probability);
    end

    if ( $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x9_fifo_stall_cycles_min" ) ) begin
        $value$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x9_fifo_stall_cycles_min=%d", stall_cycles_min);
    end else if ( $test$plusargs( "default_fifo_stall_cycles_min" ) ) begin
        $value$plusargs( "default_fifo_stall_cycles_min=%d", stall_cycles_min);
    end

    if ( $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x9_fifo_stall_cycles_max" ) ) begin
        $value$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x9_fifo_stall_cycles_max=%d", stall_cycles_max);
    end else if ( $test$plusargs( "default_fifo_stall_cycles_max" ) ) begin
        $value$plusargs( "default_fifo_stall_cycles_max=%d", stall_cycles_max);
    end
`endif

    if ( stall_cycles_min < 1 ) begin
        stall_cycles_min = 1;
    end

    if ( stall_cycles_min > stall_cycles_max ) begin
        stall_cycles_max = stall_cycles_min;
    end

end

`ifdef NO_PLI
`else

// randomization globals
`ifdef SIMTOP_RANDOMIZE_STALLS
  always @( `SIMTOP_RANDOMIZE_STALLS.global_stall_event ) begin
    if ( ! $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x9_fifo_stall_probability" ) ) stall_probability = `SIMTOP_RANDOMIZE_STALLS.global_stall_fifo_probability; 
    if ( ! $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x9_fifo_stall_cycles_min"  ) ) stall_cycles_min  = `SIMTOP_RANDOMIZE_STALLS.global_stall_fifo_cycles_min;
    if ( ! $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x9_fifo_stall_cycles_max"  ) ) stall_cycles_max  = `SIMTOP_RANDOMIZE_STALLS.global_stall_fifo_cycles_max;
  end
`endif

`endif

always @( negedge nvdla_core_clk or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        stall_cycles_left <=  0;
    end else begin
`ifdef NO_PLI
            stall_cycles_left <=  0;
`else
            if ( data_wr_pvld && !(!data_wr_prdy)
                 && stall_probability != 0 ) begin
                if ( prand_inst0(1, 100) <= stall_probability ) begin
                    stall_cycles_left <=  prand_inst1(stall_cycles_min, stall_cycles_max);
                end else if ( stall_cycles_left !== 0  ) begin
                    stall_cycles_left <=  stall_cycles_left - 1;
                end
            end else if ( stall_cycles_left !== 0  ) begin
                stall_cycles_left <=  stall_cycles_left - 1;
            end
`endif
    end
end

assign wr_pause_rand = (stall_cycles_left !== 0) ;

// VCS coverage on
`endif
// VCS coverage on

// leda W339 ON
// leda W372 ON
// leda W373 ON
// leda W599 ON
// leda W430 ON
// leda W182 ON
// leda W639 ON
// leda DCVER_274_NV ON


//
// Histogram of fifo depth (from write side's perspective)
//
// NOTE: it will reference `SIMTOP.perfmon_enabled, so that
//       has to at least be defined, though not initialized.
//	 tbgen testbenches have it already and various
//	 ways to turn it on and off.
//
`ifdef PERFMON_HISTOGRAM 
// VCS coverage off
`ifndef SYNTHESIS
perfmon_histogram perfmon (
      .clk	( nvdla_core_clk ) 
    , .max      ( {25'd0, (wr_limit_reg == 7'd0) ? 7'd80 : wr_limit_reg} )
    , .curr	( {25'd0, data_wr_count} )
    );
`endif
// VCS coverage on
`endif

// spyglass disable_block W164a W164b W116 W484 W504

`ifdef SPYGLASS
`else

`ifdef FIFOGEN_KEEP_ASSERTION_VERIF_CODE
// VCS coverage off
`ifdef ASSERT_ON



`ifdef SPYGLASS
wire disable_assert_plusarg = 1'b0;
`else

`ifdef FV_ASSERT_ON
wire disable_assert_plusarg = 1'b0;
`else
wire disable_assert_plusarg = |($test$plusargs("DISABLE_NESS_FLOW_ASSERTIONS"));
`endif // ifdef FV_ASSERT_ON

`endif // ifdef SPYGLASS


wire assert_enabled = 1'b1 && !disable_assert_plusarg;


`endif // ifdef ASSERT_ON
// VCS coverage on
`endif // ifdef FIFOGEN_KEEP_ASSERTION_VERIF_CODE


`ifdef ASSERT_ON

// VCS coverage off
`ifndef SYNTHESIS
always @(assert_enabled) begin
    if ( assert_enabled === 1'b0 ) begin
        $display("Asserts are disabled for %m");
    end
end
`endif
// VCS coverage on

`endif

`endif

// spyglass enable_block W164a W164b W116 W484 W504


//| &Viva push ifdef_ignore_on;

`ifdef COVER

wire wr_testpoint_reset_ = ( nvdla_core_rstn === 1'bx ? 1'b0 : nvdla_core_rstn );


//| ::testpoint -autogen true -name "FIFOGEN_TESTPOINT Fifo Full" -clk nvdla_core_clk -reset wr_testpoint_reset_ data_wr_count==80;
//| &Force internal /^testpoint_/;

`ifndef DISABLE_TESTPOINTS
  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER
  `endif // COVER

  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER
  `endif // COVER

  `ifdef TP__FIFOGEN_TESTPOINT_Fifo_Full
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER
  `endif // TP__FIFOGEN_TESTPOINT_Fifo_Full

`ifdef COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER


`define NV_TESTPOINT_COVERAGE_GUARD_NV_NVDLA_CDP_DP_data_fifo_80x9
//VCS coverage off
    // TESTPOINT_START
    // NAME="FIFOGEN_TESTPOINT Fifo Full"
    // TYPE=OCCURRENCE
    // AUTOGEN=true
    // COUNT=1
    // GROUP="DEFAULT"
    // INFO=""
    // RANDOM_COVER=true
    // ASYNC_RESET=1
    // ACTIVE_HIGH_RESET=0
wire testpoint_0_internal_nvdla_core_clk   = nvdla_core_clk;
wire testpoint_0_internal_wr_testpoint_reset_ = wr_testpoint_reset_;

`ifdef FV_COVER_ON
    // Synthesizable code for SFV.
    wire testpoint_got_reset_testpoint_0_internal_wr_testpoint_reset__with_clock_testpoint_0_internal_nvdla_core_clk = 1'b1;
`else
    // Must be clocked with reset active before we start gathering
    // coverage.
    //  Reset signal: testpoint_0_internal_wr_testpoint_reset_
    //  Clock signal: testpoint_0_internal_nvdla_core_clk
    reg testpoint_got_reset_testpoint_0_internal_wr_testpoint_reset__with_clock_testpoint_0_internal_nvdla_core_clk;

    initial
        testpoint_got_reset_testpoint_0_internal_wr_testpoint_reset__with_clock_testpoint_0_internal_nvdla_core_clk <= 1'b0;

    always @(posedge testpoint_0_internal_nvdla_core_clk or negedge testpoint_0_internal_wr_testpoint_reset_) begin: HAS_RETENTION_TESTPOINT_RESET_0
        if (~testpoint_0_internal_wr_testpoint_reset_)
            testpoint_got_reset_testpoint_0_internal_wr_testpoint_reset__with_clock_testpoint_0_internal_nvdla_core_clk <= 1'b1;
    end
`endif

`ifndef LINE_TESTPOINTS_OFF
    reg testpoint_0_count_0;

    reg testpoint_0_goal_0;
    initial testpoint_0_goal_0 = 0;
    initial testpoint_0_count_0 = 0;
    always@(testpoint_0_count_0) begin
        if(testpoint_0_count_0 >= 1)
         begin
 `ifdef COVER_PRINT_TESTPOINT_HITS
            if (testpoint_0_goal_0 != 1'b1)
                $display("TESTPOINT_HIT: NV_NVDLA_CDP_DP_data_fifo_80x9 ::: FIFOGEN_TESTPOINT Fifo Full ::: data_wr_count==80");
 `endif
            //VCS coverage on
            //coverage name NV_NVDLA_CDP_DP_data_fifo_80x9 ::: FIFOGEN_TESTPOINT Fifo Full ::: testpoint_0_goal_0
            testpoint_0_goal_0 = 1'b1;
            //VCS coverage off
        end
        else
            testpoint_0_goal_0 = 1'b0;
    end

    // Increment counters for every condition that's true this clock.
    always @(posedge testpoint_0_internal_nvdla_core_clk) begin: HAS_RETENTION_TESTPOINT_GOAL_0
        if (testpoint_0_internal_wr_testpoint_reset_) begin
 `ifdef ASSOCIATE_TESTPOINT_NAME_GOAL_NUMBER
            if ((data_wr_count==80) && testpoint_got_reset_testpoint_0_internal_wr_testpoint_reset__with_clock_testpoint_0_internal_nvdla_core_clk)
                $display("NVIDIA TESTPOINT: NV_NVDLA_CDP_DP_data_fifo_80x9 ::: FIFOGEN_TESTPOINT Fifo Full ::: testpoint_0_goal_0");
 `endif
            if ((data_wr_count==80) && testpoint_got_reset_testpoint_0_internal_wr_testpoint_reset__with_clock_testpoint_0_internal_nvdla_core_clk)
                testpoint_0_count_0 <= 1'd1;
        end
        else begin
 `ifndef FV_COVER_ON
            if (!testpoint_got_reset_testpoint_0_internal_wr_testpoint_reset__with_clock_testpoint_0_internal_nvdla_core_clk) begin
 `endif
                testpoint_0_count_0 <= 1'd0;
 `ifndef FV_COVER_ON
            end
 `endif
        end
    end
`endif // LINE_TESTPOINTS_OFF

`ifndef SV_TESTPOINTS_OFF
    wire testpoint_0_goal_0_active = ((data_wr_count==80) && testpoint_got_reset_testpoint_0_internal_wr_testpoint_reset__with_clock_testpoint_0_internal_nvdla_core_clk);

    // system verilog testpoints, to leverage vcs testpoint coverage tools
 `ifndef SV_TESTPOINTS_DESCRIPTIVE
    system_verilog_testpoint svt_testpoint_0_goal_0 (.clk (testpoint_0_internal_nvdla_core_clk), .tp(testpoint_0_goal_0_active));
 `else
    system_verilog_testpoint svt_FIFOGEN_TESTPOINT_Fifo_Full_0 (.clk (testpoint_0_internal_nvdla_core_clk), .tp(testpoint_0_goal_0_active));
 `endif
`endif

    //VCS coverage on
`endif //COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER
`endif //  DISABLE_TESTPOINTS

    // TESTPOINT_END
//| ::testpoint -autogen true -name "FIFOGEN_TESTPOINT Fifo Full and wr_req" -clk nvdla_core_clk -reset wr_testpoint_reset_ data_wr_count==80 && data_wr_pvld;
`ifndef DISABLE_TESTPOINTS
  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER
  `endif // COVER

  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER
  `endif // COVER

  `ifdef TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER
  `endif // TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req

`ifdef COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER


`define NV_TESTPOINT_COVERAGE_GUARD_NV_NVDLA_CDP_DP_data_fifo_80x9
//VCS coverage off
    // TESTPOINT_START
    // NAME="FIFOGEN_TESTPOINT Fifo Full and wr_req"
    // TYPE=OCCURRENCE
    // AUTOGEN=true
    // COUNT=1
    // GROUP="DEFAULT"
    // INFO=""
    // RANDOM_COVER=true
    // ASYNC_RESET=1
    // ACTIVE_HIGH_RESET=0
wire testpoint_1_internal_nvdla_core_clk   = nvdla_core_clk;
wire testpoint_1_internal_wr_testpoint_reset_ = wr_testpoint_reset_;

`ifdef FV_COVER_ON
    // Synthesizable code for SFV.
    wire testpoint_got_reset_testpoint_1_internal_wr_testpoint_reset__with_clock_testpoint_1_internal_nvdla_core_clk = 1'b1;
`else
    // Must be clocked with reset active before we start gathering
    // coverage.
    //  Reset signal: testpoint_1_internal_wr_testpoint_reset_
    //  Clock signal: testpoint_1_internal_nvdla_core_clk
    reg testpoint_got_reset_testpoint_1_internal_wr_testpoint_reset__with_clock_testpoint_1_internal_nvdla_core_clk;

    initial
        testpoint_got_reset_testpoint_1_internal_wr_testpoint_reset__with_clock_testpoint_1_internal_nvdla_core_clk <= 1'b0;

    always @(posedge testpoint_1_internal_nvdla_core_clk or negedge testpoint_1_internal_wr_testpoint_reset_) begin: HAS_RETENTION_TESTPOINT_RESET_1
        if (~testpoint_1_internal_wr_testpoint_reset_)
            testpoint_got_reset_testpoint_1_internal_wr_testpoint_reset__with_clock_testpoint_1_internal_nvdla_core_clk <= 1'b1;
    end
`endif

`ifndef LINE_TESTPOINTS_OFF
    reg testpoint_1_count_0;

    reg testpoint_1_goal_0;
    initial testpoint_1_goal_0 = 0;
    initial testpoint_1_count_0 = 0;
    always@(testpoint_1_count_0) begin
        if(testpoint_1_count_0 >= 1)
         begin
 `ifdef COVER_PRINT_TESTPOINT_HITS
            if (testpoint_1_goal_0 != 1'b1)
                $display("TESTPOINT_HIT: NV_NVDLA_CDP_DP_data_fifo_80x9 ::: FIFOGEN_TESTPOINT Fifo Full and wr_req ::: data_wr_count==80 && data_wr_pvld");
 `endif
            //VCS coverage on
            //coverage name NV_NVDLA_CDP_DP_data_fifo_80x9 ::: FIFOGEN_TESTPOINT Fifo Full and wr_req ::: testpoint_1_goal_0
            testpoint_1_goal_0 = 1'b1;
            //VCS coverage off
        end
        else
            testpoint_1_goal_0 = 1'b0;
    end

    // Increment counters for every condition that's true this clock.
    always @(posedge testpoint_1_internal_nvdla_core_clk) begin: HAS_RETENTION_TESTPOINT_GOAL_1
        if (testpoint_1_internal_wr_testpoint_reset_) begin
 `ifdef ASSOCIATE_TESTPOINT_NAME_GOAL_NUMBER
            if ((data_wr_count==80 && data_wr_pvld) && testpoint_got_reset_testpoint_1_internal_wr_testpoint_reset__with_clock_testpoint_1_internal_nvdla_core_clk)
                $display("NVIDIA TESTPOINT: NV_NVDLA_CDP_DP_data_fifo_80x9 ::: FIFOGEN_TESTPOINT Fifo Full and wr_req ::: testpoint_1_goal_0");
 `endif
            if ((data_wr_count==80 && data_wr_pvld) && testpoint_got_reset_testpoint_1_internal_wr_testpoint_reset__with_clock_testpoint_1_internal_nvdla_core_clk)
                testpoint_1_count_0 <= 1'd1;
        end
        else begin
 `ifndef FV_COVER_ON
            if (!testpoint_got_reset_testpoint_1_internal_wr_testpoint_reset__with_clock_testpoint_1_internal_nvdla_core_clk) begin
 `endif
                testpoint_1_count_0 <= 1'd0;
 `ifndef FV_COVER_ON
            end
 `endif
        end
    end
`endif // LINE_TESTPOINTS_OFF

`ifndef SV_TESTPOINTS_OFF
    wire testpoint_1_goal_0_active = ((data_wr_count==80 && data_wr_pvld) && testpoint_got_reset_testpoint_1_internal_wr_testpoint_reset__with_clock_testpoint_1_internal_nvdla_core_clk);

    // system verilog testpoints, to leverage vcs testpoint coverage tools
 `ifndef SV_TESTPOINTS_DESCRIPTIVE
    system_verilog_testpoint svt_testpoint_1_goal_0 (.clk (testpoint_1_internal_nvdla_core_clk), .tp(testpoint_1_goal_0_active));
 `else
    system_verilog_testpoint svt_FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_0 (.clk (testpoint_1_internal_nvdla_core_clk), .tp(testpoint_1_goal_0_active));
 `endif
`endif

    //VCS coverage on
`endif //COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER
`endif //  DISABLE_TESTPOINTS

    // TESTPOINT_END


wire rd_testpoint_reset_ = ( nvdla_core_rstn === 1'bx ? 1'b0 : nvdla_core_rstn );


//| ::testpoint -autogen true -name "Fifo not empty and rd_busy" -clk nvdla_core_clk -reset rd_testpoint_reset_ data_rd_pvld && !data_rd_prdy;
`ifndef DISABLE_TESTPOINTS
  `ifdef COVER
    `define COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER
  `endif // COVER

  `ifdef COVER
    `define COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER
  `endif // COVER

  `ifdef TP__Fifo_not_empty_and_rd_busy
    `define COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER
  `endif // TP__Fifo_not_empty_and_rd_busy

`ifdef COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER


`define NV_TESTPOINT_COVERAGE_GUARD_NV_NVDLA_CDP_DP_data_fifo_80x9
//VCS coverage off
    // TESTPOINT_START
    // NAME="Fifo not empty and rd_busy"
    // TYPE=OCCURRENCE
    // AUTOGEN=true
    // COUNT=1
    // GROUP="DEFAULT"
    // INFO=""
    // RANDOM_COVER=true
    // ASYNC_RESET=1
    // ACTIVE_HIGH_RESET=0
wire testpoint_2_internal_nvdla_core_clk   = nvdla_core_clk;
wire testpoint_2_internal_rd_testpoint_reset_ = rd_testpoint_reset_;

`ifdef FV_COVER_ON
    // Synthesizable code for SFV.
    wire testpoint_got_reset_testpoint_2_internal_rd_testpoint_reset__with_clock_testpoint_2_internal_nvdla_core_clk = 1'b1;
`else
    // Must be clocked with reset active before we start gathering
    // coverage.
    //  Reset signal: testpoint_2_internal_rd_testpoint_reset_
    //  Clock signal: testpoint_2_internal_nvdla_core_clk
    reg testpoint_got_reset_testpoint_2_internal_rd_testpoint_reset__with_clock_testpoint_2_internal_nvdla_core_clk;

    initial
        testpoint_got_reset_testpoint_2_internal_rd_testpoint_reset__with_clock_testpoint_2_internal_nvdla_core_clk <= 1'b0;

    always @(posedge testpoint_2_internal_nvdla_core_clk or negedge testpoint_2_internal_rd_testpoint_reset_) begin: HAS_RETENTION_TESTPOINT_RESET_2
        if (~testpoint_2_internal_rd_testpoint_reset_)
            testpoint_got_reset_testpoint_2_internal_rd_testpoint_reset__with_clock_testpoint_2_internal_nvdla_core_clk <= 1'b1;
    end
`endif

`ifndef LINE_TESTPOINTS_OFF
    reg testpoint_2_count_0;

    reg testpoint_2_goal_0;
    initial testpoint_2_goal_0 = 0;
    initial testpoint_2_count_0 = 0;
    always@(testpoint_2_count_0) begin
        if(testpoint_2_count_0 >= 1)
         begin
 `ifdef COVER_PRINT_TESTPOINT_HITS
            if (testpoint_2_goal_0 != 1'b1)
                $display("TESTPOINT_HIT: NV_NVDLA_CDP_DP_data_fifo_80x9 ::: Fifo not empty and rd_busy ::: data_rd_pvld && !data_rd_prdy");
 `endif
            //VCS coverage on
            //coverage name NV_NVDLA_CDP_DP_data_fifo_80x9 ::: Fifo not empty and rd_busy ::: testpoint_2_goal_0
            testpoint_2_goal_0 = 1'b1;
            //VCS coverage off
        end
        else
            testpoint_2_goal_0 = 1'b0;
    end

    // Increment counters for every condition that's true this clock.
    always @(posedge testpoint_2_internal_nvdla_core_clk) begin: HAS_RETENTION_TESTPOINT_GOAL_2
        if (testpoint_2_internal_rd_testpoint_reset_) begin
 `ifdef ASSOCIATE_TESTPOINT_NAME_GOAL_NUMBER
            if ((data_rd_pvld && !data_rd_prdy) && testpoint_got_reset_testpoint_2_internal_rd_testpoint_reset__with_clock_testpoint_2_internal_nvdla_core_clk)
                $display("NVIDIA TESTPOINT: NV_NVDLA_CDP_DP_data_fifo_80x9 ::: Fifo not empty and rd_busy ::: testpoint_2_goal_0");
 `endif
            if ((data_rd_pvld && !data_rd_prdy) && testpoint_got_reset_testpoint_2_internal_rd_testpoint_reset__with_clock_testpoint_2_internal_nvdla_core_clk)
                testpoint_2_count_0 <= 1'd1;
        end
        else begin
 `ifndef FV_COVER_ON
            if (!testpoint_got_reset_testpoint_2_internal_rd_testpoint_reset__with_clock_testpoint_2_internal_nvdla_core_clk) begin
 `endif
                testpoint_2_count_0 <= 1'd0;
 `ifndef FV_COVER_ON
            end
 `endif
        end
    end
`endif // LINE_TESTPOINTS_OFF

`ifndef SV_TESTPOINTS_OFF
    wire testpoint_2_goal_0_active = ((data_rd_pvld && !data_rd_prdy) && testpoint_got_reset_testpoint_2_internal_rd_testpoint_reset__with_clock_testpoint_2_internal_nvdla_core_clk);

    // system verilog testpoints, to leverage vcs testpoint coverage tools
 `ifndef SV_TESTPOINTS_DESCRIPTIVE
    system_verilog_testpoint svt_testpoint_2_goal_0 (.clk (testpoint_2_internal_nvdla_core_clk), .tp(testpoint_2_goal_0_active));
 `else
    system_verilog_testpoint svt_Fifo_not_empty_and_rd_busy_0 (.clk (testpoint_2_internal_nvdla_core_clk), .tp(testpoint_2_goal_0_active));
 `endif
`endif

    //VCS coverage on
`endif //COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER
`endif //  DISABLE_TESTPOINTS

    // TESTPOINT_END

reg [1:0] testpoint_empty_state;
reg [1:0] testpoint_empty_state_nxt;
reg testpoint_non_empty_to_empty_to_non_empty_reached;

`define FIFO_INIT 2'b00
`define FIFO_NON_EMPTY 2'b01
`define FIFO_EMPTY 2'b10

always @(testpoint_empty_state or (!data_rd_pvld)) begin
    testpoint_empty_state_nxt = testpoint_empty_state;
    testpoint_non_empty_to_empty_to_non_empty_reached = 0;
    casez (testpoint_empty_state)
         `FIFO_INIT: begin
             if (!(!data_rd_pvld)) begin
                 testpoint_empty_state_nxt = `FIFO_NON_EMPTY;
             end
         end
         `FIFO_NON_EMPTY: begin
             if ((!data_rd_pvld)) begin
                 testpoint_empty_state_nxt = `FIFO_EMPTY;
             end
         end
         `FIFO_EMPTY: begin
             if (!(!data_rd_pvld)) begin
                 testpoint_non_empty_to_empty_to_non_empty_reached = 1;
                 testpoint_empty_state_nxt = `FIFO_NON_EMPTY;
             end
         end
         // VCS coverage off
         default: begin
             testpoint_empty_state_nxt = `FIFO_INIT;
         end
         // VCS coverage on
    endcase
end
always @( posedge nvdla_core_clk or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        testpoint_empty_state <=  2'b00;
    end else begin
         if (testpoint_empty_state != testpoint_empty_state_nxt) begin
             testpoint_empty_state <= testpoint_empty_state_nxt;
         end
     end
end

//| ::testpoint -autogen true -name "FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty" -clk nvdla_core_clk -reset rd_testpoint_reset_ testpoint_non_empty_to_empty_to_non_empty_reached; 
`ifndef DISABLE_TESTPOINTS
  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER
  `endif // COVER

  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER
  `endif // COVER

  `ifdef TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER
  `endif // TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty

`ifdef COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER


`define NV_TESTPOINT_COVERAGE_GUARD_NV_NVDLA_CDP_DP_data_fifo_80x9
//VCS coverage off
    // TESTPOINT_START
    // NAME="FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty"
    // TYPE=OCCURRENCE
    // AUTOGEN=true
    // COUNT=1
    // GROUP="DEFAULT"
    // INFO=""
    // RANDOM_COVER=true
    // ASYNC_RESET=1
    // ACTIVE_HIGH_RESET=0
wire testpoint_3_internal_nvdla_core_clk   = nvdla_core_clk;
wire testpoint_3_internal_rd_testpoint_reset_ = rd_testpoint_reset_;

`ifdef FV_COVER_ON
    // Synthesizable code for SFV.
    wire testpoint_got_reset_testpoint_3_internal_rd_testpoint_reset__with_clock_testpoint_3_internal_nvdla_core_clk = 1'b1;
`else
    // Must be clocked with reset active before we start gathering
    // coverage.
    //  Reset signal: testpoint_3_internal_rd_testpoint_reset_
    //  Clock signal: testpoint_3_internal_nvdla_core_clk
    reg testpoint_got_reset_testpoint_3_internal_rd_testpoint_reset__with_clock_testpoint_3_internal_nvdla_core_clk;

    initial
        testpoint_got_reset_testpoint_3_internal_rd_testpoint_reset__with_clock_testpoint_3_internal_nvdla_core_clk <= 1'b0;

    always @(posedge testpoint_3_internal_nvdla_core_clk or negedge testpoint_3_internal_rd_testpoint_reset_) begin: HAS_RETENTION_TESTPOINT_RESET_3
        if (~testpoint_3_internal_rd_testpoint_reset_)
            testpoint_got_reset_testpoint_3_internal_rd_testpoint_reset__with_clock_testpoint_3_internal_nvdla_core_clk <= 1'b1;
    end
`endif

`ifndef LINE_TESTPOINTS_OFF
    reg testpoint_3_count_0;

    reg testpoint_3_goal_0;
    initial testpoint_3_goal_0 = 0;
    initial testpoint_3_count_0 = 0;
    always@(testpoint_3_count_0) begin
        if(testpoint_3_count_0 >= 1)
         begin
 `ifdef COVER_PRINT_TESTPOINT_HITS
            if (testpoint_3_goal_0 != 1'b1)
                $display("TESTPOINT_HIT: NV_NVDLA_CDP_DP_data_fifo_80x9 ::: FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty ::: testpoint_non_empty_to_empty_to_non_empty_reached");
 `endif
            //VCS coverage on
            //coverage name NV_NVDLA_CDP_DP_data_fifo_80x9 ::: FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty ::: testpoint_3_goal_0
            testpoint_3_goal_0 = 1'b1;
            //VCS coverage off
        end
        else
            testpoint_3_goal_0 = 1'b0;
    end

    // Increment counters for every condition that's true this clock.
    always @(posedge testpoint_3_internal_nvdla_core_clk) begin: HAS_RETENTION_TESTPOINT_GOAL_3
        if (testpoint_3_internal_rd_testpoint_reset_) begin
 `ifdef ASSOCIATE_TESTPOINT_NAME_GOAL_NUMBER
            if ((testpoint_non_empty_to_empty_to_non_empty_reached) && testpoint_got_reset_testpoint_3_internal_rd_testpoint_reset__with_clock_testpoint_3_internal_nvdla_core_clk)
                $display("NVIDIA TESTPOINT: NV_NVDLA_CDP_DP_data_fifo_80x9 ::: FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty ::: testpoint_3_goal_0");
 `endif
            if ((testpoint_non_empty_to_empty_to_non_empty_reached) && testpoint_got_reset_testpoint_3_internal_rd_testpoint_reset__with_clock_testpoint_3_internal_nvdla_core_clk)
                testpoint_3_count_0 <= 1'd1;
        end
        else begin
 `ifndef FV_COVER_ON
            if (!testpoint_got_reset_testpoint_3_internal_rd_testpoint_reset__with_clock_testpoint_3_internal_nvdla_core_clk) begin
 `endif
                testpoint_3_count_0 <= 1'd0;
 `ifndef FV_COVER_ON
            end
 `endif
        end
    end
`endif // LINE_TESTPOINTS_OFF

`ifndef SV_TESTPOINTS_OFF
    wire testpoint_3_goal_0_active = ((testpoint_non_empty_to_empty_to_non_empty_reached) && testpoint_got_reset_testpoint_3_internal_rd_testpoint_reset__with_clock_testpoint_3_internal_nvdla_core_clk);

    // system verilog testpoints, to leverage vcs testpoint coverage tools
 `ifndef SV_TESTPOINTS_DESCRIPTIVE
    system_verilog_testpoint svt_testpoint_3_goal_0 (.clk (testpoint_3_internal_nvdla_core_clk), .tp(testpoint_3_goal_0_active));
 `else
    system_verilog_testpoint svt_FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_0 (.clk (testpoint_3_internal_nvdla_core_clk), .tp(testpoint_3_goal_0_active));
 `endif
`endif

    //VCS coverage on
`endif //COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER
`endif //  DISABLE_TESTPOINTS

    // TESTPOINT_END


`endif

//| &Viva pop ifdef_ignore_on;


//The NV_BLKBOX_SRC0 module is only present when the FIFOGEN_MODULE_SEARCH
// define is set.  This is to aid fifogen team search for fifogen fifo
// instance and module names in a given design.
`ifdef FIFOGEN_MODULE_SEARCH
NV_BLKBOX_SRC0 dummy_breadcrumb_fifogen_blkbox (.Y());
`endif

// spyglass enable_block W401 -- clock is not input to module

// synopsys dc_script_begin
//   set_boundary_optimization find(design, "NV_NVDLA_CDP_DP_data_fifo_80x9") true
// synopsys dc_script_end

//| &Attachment -no_warn EndModulePrepend;
//| _attach_EndModulePrepend_1;

`ifdef SYNTH_LEVEL1_COMPILE
`else
`ifdef SYNTHESIS
`else
`ifdef PRAND_VERILOG
// Only verilog needs any local variables
reg [47:0] prand_local_seed0;
reg prand_initialized0;
reg prand_no_rollpli0;
`endif
`endif
`endif

function [31:0] prand_inst0;
//VCS coverage off
    input [31:0] min;
    input [31:0] max;
    reg [32:0] diff;
    
    begin
`ifdef SYNTH_LEVEL1_COMPILE
        prand_inst0 = min;
`else
`ifdef SYNTHESIS
        prand_inst0 = min;
`else
`ifdef PRAND_VERILOG
        if (prand_initialized0 !== 1'b1) begin
            prand_no_rollpli0 = $test$plusargs("NO_ROLLPLI");
            if (!prand_no_rollpli0)
                prand_local_seed0 = {$prand_get_seed(0), 16'b0};
            prand_initialized0 = 1'b1;
        end
        if (prand_no_rollpli0) begin
            prand_inst0 = min;
        end else begin
            diff = max - min + 1;
            prand_inst0 = min + prand_local_seed0[47:16] % diff;
            // magic numbers taken from Java's random class (same as lrand48)
            prand_local_seed0 = prand_local_seed0 * 48'h5deece66d + 48'd11;
        end
`else
`ifdef PRAND_OFF
        prand_inst0 = min;
`else
        prand_inst0 = $RollPLI(min, max, "auto");
`endif
`endif
`endif
`endif
    end
//VCS coverage on
endfunction

//| _attach_EndModulePrepend_2;

`ifdef SYNTH_LEVEL1_COMPILE
`else
`ifdef SYNTHESIS
`else
`ifdef PRAND_VERILOG
// Only verilog needs any local variables
reg [47:0] prand_local_seed1;
reg prand_initialized1;
reg prand_no_rollpli1;
`endif
`endif
`endif

function [31:0] prand_inst1;
//VCS coverage off
    input [31:0] min;
    input [31:0] max;
    reg [32:0] diff;
    
    begin
`ifdef SYNTH_LEVEL1_COMPILE
        prand_inst1 = min;
`else
`ifdef SYNTHESIS
        prand_inst1 = min;
`else
`ifdef PRAND_VERILOG
        if (prand_initialized1 !== 1'b1) begin
            prand_no_rollpli1 = $test$plusargs("NO_ROLLPLI");
            if (!prand_no_rollpli1)
                prand_local_seed1 = {$prand_get_seed(1), 16'b0};
            prand_initialized1 = 1'b1;
        end
        if (prand_no_rollpli1) begin
            prand_inst1 = min;
        end else begin
            diff = max - min + 1;
            prand_inst1 = min + prand_local_seed1[47:16] % diff;
            // magic numbers taken from Java's random class (same as lrand48)
            prand_local_seed1 = prand_local_seed1 * 48'h5deece66d + 48'd11;
        end
`else
`ifdef PRAND_OFF
        prand_inst1 = min;
`else
        prand_inst1 = $RollPLI(min, max, "auto");
`endif
`endif
`endif
`endif
    end
//VCS coverage on
endfunction


//| &Perl $VIVA_MODULE = $NV_NVDLA_CDP_DP_data_fifo_80x9_PARENT_VIVA_MODULE;


endmodule // NV_NVDLA_CDP_DP_data_fifo_80x9



//| &Viva pop dangle_checks_off;

//| &Shell ${FIFOGEN} -stdout -m NV_NVDLA_CDP_DP_data_fifo_80x18
//|                 -clk_name   ::eval($VIVA_CLOCK)
//|                 -reset_name ::eval($VIVA_RESET)
//|                 -wr_pipebus data_wr
//|                 -rd_pipebus data_rd
//|                 -rd_reg
//|                 -ram_bypass
//|                 -d ::eval(80)
//|                 -w ::eval(18)
//|                 -ram ra2; 
//| &Depend "../../../../../../../socd/ip_chip_tools/1.0/defs/public/fifogen/golden/tlit6/fifogen.yml";
//
// AUTOMATICALLY GENERATED -- DO NOT EDIT OR CHECK IN
//
// /home/nvtools/engr/2018/04/28_05_00_03/nvtools/scripts/fifogen
// fifogen -input_config_yaml ../../../../../../../socd/ip_chip_tools/1.0/defs/public/fifogen/golden/tlit6/fifogen.yml -no_make_ram -no_make_ram -stdout -m NV_NVDLA_CDP_DP_data_fifo_80x18 -clk_name nvdla_core_clk -reset_name nvdla_core_rstn -wr_pipebus data_wr -rd_pipebus data_rd -rd_reg -ram_bypass -d 80 -w 18 -ram ra2 [Chosen ram type: ra2 - ramgen_generic (user specified, thus no other ram type is allowed)]
// chip config vars: strict_synchronizers=1  strict_synchronizers_use_lib_cells=1  strict_synchronizers_use_tm_lib_cells=1  strict_sync_randomizer=1  assertion_message_prefix=FIFOGEN_ASSERTION  testpoint_message_prefix=FIFOGEN_TESTPOINT  ignore_ramgen_fifola_variant=1  uses_p_SSYNC=0  uses_prand=1  uses_rammake_inc=1  use_x_or_0=1  force_wr_reg_gated=1  no_force_reset=1  no_timescale=1  remove_unused_ports=1  viva_parsed=1  no_pli_ifdef=1  requires_full_throughput=1  ram_auto_ff_bits_cutoff=16  ram_auto_ff_width_cutoff=2  ram_auto_ff_width_cutoff_max_depth=32  ram_auto_ff_depth_cutoff=-1  ram_auto_ff_no_la2_depth_cutoff=5  ram_auto_la2_width_cutoff=8  ram_auto_la2_width_cutoff_max_depth=56  ram_auto_la2_depth_cutoff=16  flopram_emu_model=1  dslp_single_clamp_port=1  dslp_clamp_port=1  slp_single_clamp_port=1  slp_clamp_port=1  master_clk_gated=1  clk_gate_module=NV_CLK_gate_power  redundant_timing_flops=0  hot_reset_async_force_ports_and_loopback=1  ram_sleep_en_width=1  async_cdc_reg_id=NV_AFIFO_  rd_reg_default_for_async=1  async_ram_instance_prefix=NV_ASYNC_RAM_  allow_rd_busy_reg_warning=0  do_dft_xelim_gating=1  add_dft_xelim_wr_clkgate=1  add_dft_xelim_rd_clkgate=1  allow_mt_rttrb_wr_reg=0 
//
// leda B_3208_NV OFF -- Unequal length LHS and RHS in assignment
// leda B_1405 OFF -- 2 asynchronous resets in this unit detected

//| &Viva push dangle_checks_off;

`define FORCE_CONTENTION_ASSERTION_RESET_ACTIVE 1'b1

`ifndef SYNTHESIS
    `define FIFOGEN_KEEP_ASSERTION_VERIF_CODE
`else
    `ifdef FV_ASSERT_ON
        `define FIFOGEN_KEEP_ASSERTION_VERIF_CODE
    `endif
`endif

`include "simulate_x_tick.vh"


module NV_NVDLA_CDP_DP_data_fifo_80x18 (
      nvdla_core_clk
    , nvdla_core_rstn
    , data_wr_prdy
    , data_wr_pvld
`ifdef FV_RAND_WR_PAUSE
    , data_wr_pause
`endif
    , data_wr_pd
    , data_rd_prdy
    , data_rd_pvld
    , data_rd_pd
    , pwrbus_ram_pd
    );

// spyglass disable_block W401 -- clock is not input to module
input         nvdla_core_clk;
input         nvdla_core_rstn;
output        data_wr_prdy;
input         data_wr_pvld;
`ifdef FV_RAND_WR_PAUSE
input         data_wr_pause;
`endif
input  [17:0] data_wr_pd;
input         data_rd_prdy;
output        data_rd_pvld;
output [17:0] data_rd_pd;
input  [31:0] pwrbus_ram_pd;

//| &PerlBeg;
//|     $NV_NVDLA_CDP_DP_data_fifo_80x18_PARENT_VIVA_MODULE = "$VIVA_MODULE";
//|     $VIVA_MODULE = "NV_NVDLA_CDP_DP_data_fifo_80x18";
//| &PerlEnd;


`ifdef FV_RAND_WR_PAUSE
// FV forces this signal to trigger random stalling
wire data_wr_pause = 0;
`endif

// Master Clock Gating (SLCG)
//
// We gate the clock(s) when idle or stalled.
// This allows us to turn off numerous miscellaneous flops
// that don't get gated during synthesis for one reason or another.
//
// We gate write side and read side separately. 
// If the fifo is synchronous, we also gate the ram separately, but if
// -master_clk_gated_unified or -status_reg/-status_logic_reg is specified, 
// then we use one clk gate for write, ram, and read.
//
wire nvdla_core_clk_mgated_enable;   // assigned by code at end of this module
wire nvdla_core_clk_mgated;               // used only in synchronous fifos
NV_CLK_gate_power nvdla_core_clk_mgate( .clk(nvdla_core_clk), .reset_(nvdla_core_rstn), .clk_en(nvdla_core_clk_mgated_enable), .clk_gated(nvdla_core_clk_mgated) );

// 
// WRITE SIDE
//
// VCS coverage off
`ifndef SYNTHESIS
wire wr_pause_rand;  // random stalling
`endif
// VCS coverage on
wire wr_reserving;
reg        data_wr_busy_int;		        	// copy for internal use
assign     data_wr_prdy = !data_wr_busy_int;
assign       wr_reserving = data_wr_pvld && !data_wr_busy_int; // reserving write space?



wire       wr_popping;                          // fwd: write side sees pop?


reg  [6:0] data_wr_count;			// write-side count

wire [6:0] wr_count_next_wr_popping = wr_reserving ? data_wr_count : (data_wr_count - 1'd1); // spyglass disable W164a W484
wire [6:0] wr_count_next_no_wr_popping = wr_reserving ? (data_wr_count + 1'd1) : data_wr_count; // spyglass disable W164a W484
wire [6:0] wr_count_next = wr_popping ? wr_count_next_wr_popping : 
                                               wr_count_next_no_wr_popping;

wire wr_count_next_no_wr_popping_is_80 = ( wr_count_next_no_wr_popping == 7'd80 );
wire wr_count_next_is_80 = wr_popping ? 1'b0 :
                                          wr_count_next_no_wr_popping_is_80;
wire [6:0] wr_limit_muxed;  // muxed with simulation/emulation overrides
wire [6:0] wr_limit_reg = wr_limit_muxed;
`ifdef FV_RAND_WR_PAUSE
                          // VCS coverage off
wire       data_wr_busy_next = wr_count_next_is_80 || // busy next cycle?
                          (wr_limit_reg != 7'd0 &&      // check data_wr_limit if != 0
                           wr_count_next >= wr_limit_reg) || data_wr_pause;
                          // VCS coverage on
`else
                          // VCS coverage off
wire       data_wr_busy_next = wr_count_next_is_80 || // busy next cycle?
                          (wr_limit_reg != 7'd0 &&      // check data_wr_limit if != 0
                           wr_count_next >= wr_limit_reg)  
 // VCS coverage off
 `ifndef SYNTHESIS
 || wr_pause_rand
 `endif
 // VCS coverage on
;
                          // VCS coverage on
`endif
always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_wr_busy_int <=  1'b0;
        data_wr_count <=  7'd0;
    end else begin
	data_wr_busy_int <=  data_wr_busy_next;
	if ( wr_reserving ^ wr_popping ) begin
	    data_wr_count <=  wr_count_next;
        end 
        `ifndef SYNTHESIS
        // VCS coverage off
        else if ( !(wr_reserving ^ wr_popping) ) begin
        end else begin
            data_wr_count <=  {7{`x_or_0}};
        end
        // VCS coverage on
        `endif // SYNTHESIS
    end
end

wire       wr_pushing = wr_reserving;   // data pushed same cycle as data_wr_pvld

//
// RAM
//

reg  [6:0] data_wr_adr;			// current write address
wire [6:0] data_rd_adr_p;		// read address to use for ram
wire [17:0] data_rd_pd_p_byp_ram;		// read data directly out of ram

wire rd_enable;

wire ore;
wire do_bypass;
wire comb_bypass;
wire rd_popping;
wire [31 : 0] pwrbus_ram_pd;

// Adding parameter for fifogen to disable wr/rd contention assertion in ramgen.
// Fifogen handles this by ignoring the data on the ram data out for that cycle.


nv_ram_rwsthp_80x18 #(`FORCE_CONTENTION_ASSERTION_RESET_ACTIVE) ram (
      .clk		 ( nvdla_core_clk )
    , .pwrbus_ram_pd ( pwrbus_ram_pd )
    , .wa        ( data_wr_adr )
    , .we        ( wr_pushing && (data_wr_count != 7'd0 || !rd_popping) )
    , .di        ( data_wr_pd )
    , .ra        ( data_rd_adr_p )
    , .re        ( (do_bypass && wr_pushing) || rd_enable )
    , .dout        ( data_rd_pd_p_byp_ram )
    , .byp_sel        ( comb_bypass )
    , .dbyp        ( data_wr_pd[17:0] )
    , .ore        ( ore )
    );
// next data_wr_adr if wr_pushing=1
wire [6:0] wr_adr_next = (data_wr_adr == 7'd79) ? 7'd0 : (data_wr_adr + 1'd1);  // spyglass disable W484

// spyglass disable_block W484
always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_wr_adr <=  7'd0;
    end else begin
        if ( wr_pushing ) begin
            data_wr_adr      <=  wr_adr_next;
        end 
        `ifndef SYNTHESIS
        // VCS coverage off
        else if ( !(wr_pushing) ) begin
        end else begin
            data_wr_adr   <=  {7{`x_or_0}};
        end
        // VCS coverage on
        `endif // SYNTHESIS
    end 
end
// spyglass enable_block W484

reg  [6:0] data_rd_adr;		// current read address
// next    read address
wire [6:0] rd_adr_next = (data_rd_adr == 7'd79) ? 7'd0 : (data_rd_adr + 1'd1);   // spyglass disable W484
assign         data_rd_adr_p = rd_popping ? rd_adr_next : data_rd_adr; // for ram

// spyglass disable_block W484
always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_rd_adr <=  7'd0;
    end else begin
        if ( rd_popping ) begin
	    data_rd_adr      <=  rd_adr_next;
        end 
        `ifndef SYNTHESIS
        // VCS coverage off
        else if ( !rd_popping ) begin
        end else begin
            data_rd_adr <=  {7{`x_or_0}};
        end
        // VCS coverage on
        `endif // SYNTHESIS
    end
end
// spyglass enable_block W484

assign do_bypass = (rd_popping ? (data_wr_adr == rd_adr_next) : (data_wr_adr == data_rd_adr));
wire [17:0] data_rd_pd_p_byp = data_rd_pd_p_byp_ram;


//
// Combinatorial Bypass
//
// If we're pushing an empty fifo, mux the wr_data directly.
//
assign comb_bypass = data_wr_count == 0;
wire [17:0] data_rd_pd_p = data_rd_pd_p_byp;



//
// SYNCHRONOUS BOUNDARY
//


assign wr_popping = rd_popping;		// let it be seen immediately


wire   rd_pushing = wr_pushing;		// let it be seen immediately

//
// READ SIDE
//

wire       data_rd_pvld_p; 		// data out of fifo is valid

reg        data_rd_pvld_int;	// internal copy of data_rd_pvld
assign     data_rd_pvld = data_rd_pvld_int;
assign     rd_popping = data_rd_pvld_p && !(data_rd_pvld_int && !data_rd_prdy);

reg  [6:0] data_rd_count_p;			// read-side fifo count
// spyglass disable_block W164a W484
wire [6:0] rd_count_p_next_rd_popping = rd_pushing ? data_rd_count_p : 
                                                                (data_rd_count_p - 1'd1);
wire [6:0] rd_count_p_next_no_rd_popping =  rd_pushing ? (data_rd_count_p + 1'd1) : 
                                                                    data_rd_count_p;
// spyglass enable_block W164a W484
wire [6:0] rd_count_p_next = rd_popping ? rd_count_p_next_rd_popping :
                                                     rd_count_p_next_no_rd_popping; 
wire rd_count_p_next_rd_popping_not_0 = rd_count_p_next_rd_popping != 0;
wire rd_count_p_next_no_rd_popping_not_0 = rd_count_p_next_no_rd_popping != 0;
wire rd_count_p_next_not_0 = rd_popping ? rd_count_p_next_rd_popping_not_0 :
                                              rd_count_p_next_no_rd_popping_not_0;
assign     data_rd_pvld_p = data_rd_count_p != 0 || rd_pushing;
assign rd_enable = ((rd_count_p_next_not_0) && ((~data_rd_pvld_p) || rd_popping));  // anytime data's there and not stalled
always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_rd_count_p <=  7'd0;
    end else begin
        if ( rd_pushing || rd_popping  ) begin
	    data_rd_count_p <=  rd_count_p_next;
        end 
        `ifndef SYNTHESIS
        // VCS coverage off
        else if ( !(rd_pushing || rd_popping ) ) begin
        end else begin
            data_rd_count_p <=  {7{`x_or_0}};
        end
        // VCS coverage on
        `endif // SYNTHESIS
    end
end
wire        rd_req_next = (data_rd_pvld_p || (data_rd_pvld_int && !data_rd_prdy)) ;

always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_rd_pvld_int <=  1'b0;
    end else begin
        data_rd_pvld_int <=  rd_req_next;
    end
end
assign data_rd_pd = data_rd_pd_p;
assign ore = rd_popping;

// Master Clock Gating (SLCG) Enables
//

// plusarg for disabling this stuff:

// VCS coverage off
`ifndef SYNTHESIS
reg master_clk_gating_disabled;  initial master_clk_gating_disabled = $test$plusargs( "fifogen_disable_master_clk_gating" ) != 0;
`endif
// VCS coverage on

// VCS coverage off
`ifndef SYNTHESIS
reg wr_pause_rand_dly;  
always @( posedge nvdla_core_clk or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        wr_pause_rand_dly <=  1'b0;
    end else begin
        wr_pause_rand_dly <=  wr_pause_rand;
    end
end
`endif
// VCS coverage on
assign nvdla_core_clk_mgated_enable = ((wr_reserving || wr_pushing || wr_popping || (data_wr_pvld && !data_wr_busy_int) || (data_wr_busy_int != data_wr_busy_next)) || (rd_pushing || rd_popping || (data_rd_pvld_int && data_rd_prdy)))
                               `ifdef FIFOGEN_MASTER_CLK_GATING_DISABLED
                               || 1'b1
                               `endif
                               // VCS coverage off
                               `ifndef SYNTHESIS
                               || master_clk_gating_disabled || (wr_pause_rand != wr_pause_rand_dly)
                               `endif
                               // VCS coverage on
;


// Simulation and Emulation Overrides of wr_limit(s)
//

`ifdef EMU

`ifdef EMU_FIFO_CFG
// Emulation Global Config Override
//
assign wr_limit_muxed = `EMU_FIFO_CFG.NV_NVDLA_CDP_DP_data_fifo_80x18_wr_limit_override ? `EMU_FIFO_CFG.NV_NVDLA_CDP_DP_data_fifo_80x18_wr_limit : 7'd0;
`else
// No Global Override for Emulation 
//
assign wr_limit_muxed = 7'd0;
`endif // EMU_FIFO_CFG

`else // !EMU
`ifdef SYNTHESIS

// No Override for RTL Synthesis
//

assign wr_limit_muxed = 7'd0;

`else  

// RTL Simulation Plusarg Override


// VCS coverage off

reg wr_limit_override;
reg [6:0] wr_limit_override_value; 
assign wr_limit_muxed = wr_limit_override ? wr_limit_override_value : 7'd0;
`ifdef NV_ARCHPRO
event reinit;

initial begin
    $display("fifogen reinit initial block %m");
    -> reinit;
end
`endif

`ifdef NV_ARCHPRO
always @( reinit ) begin
`else 
initial begin
`endif
    wr_limit_override = 0;
    wr_limit_override_value = 0;  // to keep viva happy with dangles
    if ( $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x18_wr_limit" ) ) begin
        wr_limit_override = 1;
        $value$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x18_wr_limit=%d", wr_limit_override_value);
    end
end

// VCS coverage on


`endif
`endif


// Random Write-Side Stalling
// VCS coverage off
`ifndef SYNTHESIS
// VCS coverage off

// leda W339 OFF -- Non synthesizable operator
// leda W372 OFF -- Undefined PLI task
// leda W373 OFF -- Undefined PLI function
// leda W599 OFF -- This construct is not supported by Synopsys
// leda W430 OFF -- Initial statement is not synthesizable
// leda W182 OFF -- Illegal statement for synthesis
// leda W639 OFF -- For synthesis, operands of a division or modulo operation need to be constants
// leda DCVER_274_NV OFF -- This system task is not supported by DC

integer stall_probability;      // prob of stalling
integer stall_cycles_min;       // min cycles to stall
integer stall_cycles_max;       // max cycles to stall
integer stall_cycles_left;      // stall cycles left
`ifdef NV_ARCHPRO
always @( reinit ) begin
`else 
initial begin
`endif
    stall_probability      = 0; // no stalling by default
    stall_cycles_min       = 1;
    stall_cycles_max       = 10;

`ifdef NO_PLI
`else
    if ( $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x18_fifo_stall_probability" ) ) begin
        $value$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x18_fifo_stall_probability=%d", stall_probability);
    end else if ( $test$plusargs( "default_fifo_stall_probability" ) ) begin
        $value$plusargs( "default_fifo_stall_probability=%d", stall_probability);
    end

    if ( $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x18_fifo_stall_cycles_min" ) ) begin
        $value$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x18_fifo_stall_cycles_min=%d", stall_cycles_min);
    end else if ( $test$plusargs( "default_fifo_stall_cycles_min" ) ) begin
        $value$plusargs( "default_fifo_stall_cycles_min=%d", stall_cycles_min);
    end

    if ( $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x18_fifo_stall_cycles_max" ) ) begin
        $value$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x18_fifo_stall_cycles_max=%d", stall_cycles_max);
    end else if ( $test$plusargs( "default_fifo_stall_cycles_max" ) ) begin
        $value$plusargs( "default_fifo_stall_cycles_max=%d", stall_cycles_max);
    end
`endif

    if ( stall_cycles_min < 1 ) begin
        stall_cycles_min = 1;
    end

    if ( stall_cycles_min > stall_cycles_max ) begin
        stall_cycles_max = stall_cycles_min;
    end

end

`ifdef NO_PLI
`else

// randomization globals
`ifdef SIMTOP_RANDOMIZE_STALLS
  always @( `SIMTOP_RANDOMIZE_STALLS.global_stall_event ) begin
    if ( ! $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x18_fifo_stall_probability" ) ) stall_probability = `SIMTOP_RANDOMIZE_STALLS.global_stall_fifo_probability; 
    if ( ! $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x18_fifo_stall_cycles_min"  ) ) stall_cycles_min  = `SIMTOP_RANDOMIZE_STALLS.global_stall_fifo_cycles_min;
    if ( ! $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x18_fifo_stall_cycles_max"  ) ) stall_cycles_max  = `SIMTOP_RANDOMIZE_STALLS.global_stall_fifo_cycles_max;
  end
`endif

`endif

always @( negedge nvdla_core_clk or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        stall_cycles_left <=  0;
    end else begin
`ifdef NO_PLI
            stall_cycles_left <=  0;
`else
            if ( data_wr_pvld && !(!data_wr_prdy)
                 && stall_probability != 0 ) begin
                if ( prand_inst0(1, 100) <= stall_probability ) begin
                    stall_cycles_left <=  prand_inst1(stall_cycles_min, stall_cycles_max);
                end else if ( stall_cycles_left !== 0  ) begin
                    stall_cycles_left <=  stall_cycles_left - 1;
                end
            end else if ( stall_cycles_left !== 0  ) begin
                stall_cycles_left <=  stall_cycles_left - 1;
            end
`endif
    end
end

assign wr_pause_rand = (stall_cycles_left !== 0) ;

// VCS coverage on
`endif
// VCS coverage on

// leda W339 ON
// leda W372 ON
// leda W373 ON
// leda W599 ON
// leda W430 ON
// leda W182 ON
// leda W639 ON
// leda DCVER_274_NV ON


//
// Histogram of fifo depth (from write side's perspective)
//
// NOTE: it will reference `SIMTOP.perfmon_enabled, so that
//       has to at least be defined, though not initialized.
//	 tbgen testbenches have it already and various
//	 ways to turn it on and off.
//
`ifdef PERFMON_HISTOGRAM 
// VCS coverage off
`ifndef SYNTHESIS
perfmon_histogram perfmon (
      .clk	( nvdla_core_clk ) 
    , .max      ( {25'd0, (wr_limit_reg == 7'd0) ? 7'd80 : wr_limit_reg} )
    , .curr	( {25'd0, data_wr_count} )
    );
`endif
// VCS coverage on
`endif

// spyglass disable_block W164a W164b W116 W484 W504

`ifdef SPYGLASS
`else

`ifdef FIFOGEN_KEEP_ASSERTION_VERIF_CODE
// VCS coverage off
`ifdef ASSERT_ON



`ifdef SPYGLASS
wire disable_assert_plusarg = 1'b0;
`else

`ifdef FV_ASSERT_ON
wire disable_assert_plusarg = 1'b0;
`else
wire disable_assert_plusarg = |($test$plusargs("DISABLE_NESS_FLOW_ASSERTIONS"));
`endif // ifdef FV_ASSERT_ON

`endif // ifdef SPYGLASS


wire assert_enabled = 1'b1 && !disable_assert_plusarg;


`endif // ifdef ASSERT_ON
// VCS coverage on
`endif // ifdef FIFOGEN_KEEP_ASSERTION_VERIF_CODE


`ifdef ASSERT_ON

// VCS coverage off
`ifndef SYNTHESIS
always @(assert_enabled) begin
    if ( assert_enabled === 1'b0 ) begin
        $display("Asserts are disabled for %m");
    end
end
`endif
// VCS coverage on

`endif

`endif

// spyglass enable_block W164a W164b W116 W484 W504


//| &Viva push ifdef_ignore_on;

`ifdef COVER

wire wr_testpoint_reset_ = ( nvdla_core_rstn === 1'bx ? 1'b0 : nvdla_core_rstn );


//| ::testpoint -autogen true -name "FIFOGEN_TESTPOINT Fifo Full" -clk nvdla_core_clk -reset wr_testpoint_reset_ data_wr_count==80;
//| &Force internal /^testpoint_/;

`ifndef DISABLE_TESTPOINTS
  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER
  `endif // COVER

  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER
  `endif // COVER

  `ifdef TP__FIFOGEN_TESTPOINT_Fifo_Full
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER
  `endif // TP__FIFOGEN_TESTPOINT_Fifo_Full

`ifdef COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER


`define NV_TESTPOINT_COVERAGE_GUARD_NV_NVDLA_CDP_DP_data_fifo_80x18
//VCS coverage off
    // TESTPOINT_START
    // NAME="FIFOGEN_TESTPOINT Fifo Full"
    // TYPE=OCCURRENCE
    // AUTOGEN=true
    // COUNT=1
    // GROUP="DEFAULT"
    // INFO=""
    // RANDOM_COVER=true
    // ASYNC_RESET=1
    // ACTIVE_HIGH_RESET=0
wire testpoint_4_internal_nvdla_core_clk   = nvdla_core_clk;
wire testpoint_4_internal_wr_testpoint_reset_ = wr_testpoint_reset_;

`ifdef FV_COVER_ON
    // Synthesizable code for SFV.
    wire testpoint_got_reset_testpoint_4_internal_wr_testpoint_reset__with_clock_testpoint_4_internal_nvdla_core_clk = 1'b1;
`else
    // Must be clocked with reset active before we start gathering
    // coverage.
    //  Reset signal: testpoint_4_internal_wr_testpoint_reset_
    //  Clock signal: testpoint_4_internal_nvdla_core_clk
    reg testpoint_got_reset_testpoint_4_internal_wr_testpoint_reset__with_clock_testpoint_4_internal_nvdla_core_clk;

    initial
        testpoint_got_reset_testpoint_4_internal_wr_testpoint_reset__with_clock_testpoint_4_internal_nvdla_core_clk <= 1'b0;

    always @(posedge testpoint_4_internal_nvdla_core_clk or negedge testpoint_4_internal_wr_testpoint_reset_) begin: HAS_RETENTION_TESTPOINT_RESET_4
        if (~testpoint_4_internal_wr_testpoint_reset_)
            testpoint_got_reset_testpoint_4_internal_wr_testpoint_reset__with_clock_testpoint_4_internal_nvdla_core_clk <= 1'b1;
    end
`endif

`ifndef LINE_TESTPOINTS_OFF
    reg testpoint_4_count_0;

    reg testpoint_4_goal_0;
    initial testpoint_4_goal_0 = 0;
    initial testpoint_4_count_0 = 0;
    always@(testpoint_4_count_0) begin
        if(testpoint_4_count_0 >= 1)
         begin
 `ifdef COVER_PRINT_TESTPOINT_HITS
            if (testpoint_4_goal_0 != 1'b1)
                $display("TESTPOINT_HIT: NV_NVDLA_CDP_DP_data_fifo_80x18 ::: FIFOGEN_TESTPOINT Fifo Full ::: data_wr_count==80");
 `endif
            //VCS coverage on
            //coverage name NV_NVDLA_CDP_DP_data_fifo_80x18 ::: FIFOGEN_TESTPOINT Fifo Full ::: testpoint_4_goal_0
            testpoint_4_goal_0 = 1'b1;
            //VCS coverage off
        end
        else
            testpoint_4_goal_0 = 1'b0;
    end

    // Increment counters for every condition that's true this clock.
    always @(posedge testpoint_4_internal_nvdla_core_clk) begin: HAS_RETENTION_TESTPOINT_GOAL_4
        if (testpoint_4_internal_wr_testpoint_reset_) begin
 `ifdef ASSOCIATE_TESTPOINT_NAME_GOAL_NUMBER
            if ((data_wr_count==80) && testpoint_got_reset_testpoint_4_internal_wr_testpoint_reset__with_clock_testpoint_4_internal_nvdla_core_clk)
                $display("NVIDIA TESTPOINT: NV_NVDLA_CDP_DP_data_fifo_80x18 ::: FIFOGEN_TESTPOINT Fifo Full ::: testpoint_4_goal_0");
 `endif
            if ((data_wr_count==80) && testpoint_got_reset_testpoint_4_internal_wr_testpoint_reset__with_clock_testpoint_4_internal_nvdla_core_clk)
                testpoint_4_count_0 <= 1'd1;
        end
        else begin
 `ifndef FV_COVER_ON
            if (!testpoint_got_reset_testpoint_4_internal_wr_testpoint_reset__with_clock_testpoint_4_internal_nvdla_core_clk) begin
 `endif
                testpoint_4_count_0 <= 1'd0;
 `ifndef FV_COVER_ON
            end
 `endif
        end
    end
`endif // LINE_TESTPOINTS_OFF

`ifndef SV_TESTPOINTS_OFF
    wire testpoint_4_goal_0_active = ((data_wr_count==80) && testpoint_got_reset_testpoint_4_internal_wr_testpoint_reset__with_clock_testpoint_4_internal_nvdla_core_clk);

    // system verilog testpoints, to leverage vcs testpoint coverage tools
 `ifndef SV_TESTPOINTS_DESCRIPTIVE
    system_verilog_testpoint svt_testpoint_4_goal_0 (.clk (testpoint_4_internal_nvdla_core_clk), .tp(testpoint_4_goal_0_active));
 `else
    system_verilog_testpoint svt_FIFOGEN_TESTPOINT_Fifo_Full_0 (.clk (testpoint_4_internal_nvdla_core_clk), .tp(testpoint_4_goal_0_active));
 `endif
`endif

    //VCS coverage on
`endif //COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER
`endif //  DISABLE_TESTPOINTS

    // TESTPOINT_END
//| ::testpoint -autogen true -name "FIFOGEN_TESTPOINT Fifo Full and wr_req" -clk nvdla_core_clk -reset wr_testpoint_reset_ data_wr_count==80 && data_wr_pvld;
`ifndef DISABLE_TESTPOINTS
  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER
  `endif // COVER

  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER
  `endif // COVER

  `ifdef TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER
  `endif // TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req

`ifdef COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER


`define NV_TESTPOINT_COVERAGE_GUARD_NV_NVDLA_CDP_DP_data_fifo_80x18
//VCS coverage off
    // TESTPOINT_START
    // NAME="FIFOGEN_TESTPOINT Fifo Full and wr_req"
    // TYPE=OCCURRENCE
    // AUTOGEN=true
    // COUNT=1
    // GROUP="DEFAULT"
    // INFO=""
    // RANDOM_COVER=true
    // ASYNC_RESET=1
    // ACTIVE_HIGH_RESET=0
wire testpoint_5_internal_nvdla_core_clk   = nvdla_core_clk;
wire testpoint_5_internal_wr_testpoint_reset_ = wr_testpoint_reset_;

`ifdef FV_COVER_ON
    // Synthesizable code for SFV.
    wire testpoint_got_reset_testpoint_5_internal_wr_testpoint_reset__with_clock_testpoint_5_internal_nvdla_core_clk = 1'b1;
`else
    // Must be clocked with reset active before we start gathering
    // coverage.
    //  Reset signal: testpoint_5_internal_wr_testpoint_reset_
    //  Clock signal: testpoint_5_internal_nvdla_core_clk
    reg testpoint_got_reset_testpoint_5_internal_wr_testpoint_reset__with_clock_testpoint_5_internal_nvdla_core_clk;

    initial
        testpoint_got_reset_testpoint_5_internal_wr_testpoint_reset__with_clock_testpoint_5_internal_nvdla_core_clk <= 1'b0;

    always @(posedge testpoint_5_internal_nvdla_core_clk or negedge testpoint_5_internal_wr_testpoint_reset_) begin: HAS_RETENTION_TESTPOINT_RESET_5
        if (~testpoint_5_internal_wr_testpoint_reset_)
            testpoint_got_reset_testpoint_5_internal_wr_testpoint_reset__with_clock_testpoint_5_internal_nvdla_core_clk <= 1'b1;
    end
`endif

`ifndef LINE_TESTPOINTS_OFF
    reg testpoint_5_count_0;

    reg testpoint_5_goal_0;
    initial testpoint_5_goal_0 = 0;
    initial testpoint_5_count_0 = 0;
    always@(testpoint_5_count_0) begin
        if(testpoint_5_count_0 >= 1)
         begin
 `ifdef COVER_PRINT_TESTPOINT_HITS
            if (testpoint_5_goal_0 != 1'b1)
                $display("TESTPOINT_HIT: NV_NVDLA_CDP_DP_data_fifo_80x18 ::: FIFOGEN_TESTPOINT Fifo Full and wr_req ::: data_wr_count==80 && data_wr_pvld");
 `endif
            //VCS coverage on
            //coverage name NV_NVDLA_CDP_DP_data_fifo_80x18 ::: FIFOGEN_TESTPOINT Fifo Full and wr_req ::: testpoint_5_goal_0
            testpoint_5_goal_0 = 1'b1;
            //VCS coverage off
        end
        else
            testpoint_5_goal_0 = 1'b0;
    end

    // Increment counters for every condition that's true this clock.
    always @(posedge testpoint_5_internal_nvdla_core_clk) begin: HAS_RETENTION_TESTPOINT_GOAL_5
        if (testpoint_5_internal_wr_testpoint_reset_) begin
 `ifdef ASSOCIATE_TESTPOINT_NAME_GOAL_NUMBER
            if ((data_wr_count==80 && data_wr_pvld) && testpoint_got_reset_testpoint_5_internal_wr_testpoint_reset__with_clock_testpoint_5_internal_nvdla_core_clk)
                $display("NVIDIA TESTPOINT: NV_NVDLA_CDP_DP_data_fifo_80x18 ::: FIFOGEN_TESTPOINT Fifo Full and wr_req ::: testpoint_5_goal_0");
 `endif
            if ((data_wr_count==80 && data_wr_pvld) && testpoint_got_reset_testpoint_5_internal_wr_testpoint_reset__with_clock_testpoint_5_internal_nvdla_core_clk)
                testpoint_5_count_0 <= 1'd1;
        end
        else begin
 `ifndef FV_COVER_ON
            if (!testpoint_got_reset_testpoint_5_internal_wr_testpoint_reset__with_clock_testpoint_5_internal_nvdla_core_clk) begin
 `endif
                testpoint_5_count_0 <= 1'd0;
 `ifndef FV_COVER_ON
            end
 `endif
        end
    end
`endif // LINE_TESTPOINTS_OFF

`ifndef SV_TESTPOINTS_OFF
    wire testpoint_5_goal_0_active = ((data_wr_count==80 && data_wr_pvld) && testpoint_got_reset_testpoint_5_internal_wr_testpoint_reset__with_clock_testpoint_5_internal_nvdla_core_clk);

    // system verilog testpoints, to leverage vcs testpoint coverage tools
 `ifndef SV_TESTPOINTS_DESCRIPTIVE
    system_verilog_testpoint svt_testpoint_5_goal_0 (.clk (testpoint_5_internal_nvdla_core_clk), .tp(testpoint_5_goal_0_active));
 `else
    system_verilog_testpoint svt_FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_0 (.clk (testpoint_5_internal_nvdla_core_clk), .tp(testpoint_5_goal_0_active));
 `endif
`endif

    //VCS coverage on
`endif //COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER
`endif //  DISABLE_TESTPOINTS

    // TESTPOINT_END


wire rd_testpoint_reset_ = ( nvdla_core_rstn === 1'bx ? 1'b0 : nvdla_core_rstn );


//| ::testpoint -autogen true -name "Fifo not empty and rd_busy" -clk nvdla_core_clk -reset rd_testpoint_reset_ data_rd_pvld && !data_rd_prdy;
`ifndef DISABLE_TESTPOINTS
  `ifdef COVER
    `define COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER
  `endif // COVER

  `ifdef COVER
    `define COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER
  `endif // COVER

  `ifdef TP__Fifo_not_empty_and_rd_busy
    `define COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER
  `endif // TP__Fifo_not_empty_and_rd_busy

`ifdef COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER


`define NV_TESTPOINT_COVERAGE_GUARD_NV_NVDLA_CDP_DP_data_fifo_80x18
//VCS coverage off
    // TESTPOINT_START
    // NAME="Fifo not empty and rd_busy"
    // TYPE=OCCURRENCE
    // AUTOGEN=true
    // COUNT=1
    // GROUP="DEFAULT"
    // INFO=""
    // RANDOM_COVER=true
    // ASYNC_RESET=1
    // ACTIVE_HIGH_RESET=0
wire testpoint_6_internal_nvdla_core_clk   = nvdla_core_clk;
wire testpoint_6_internal_rd_testpoint_reset_ = rd_testpoint_reset_;

`ifdef FV_COVER_ON
    // Synthesizable code for SFV.
    wire testpoint_got_reset_testpoint_6_internal_rd_testpoint_reset__with_clock_testpoint_6_internal_nvdla_core_clk = 1'b1;
`else
    // Must be clocked with reset active before we start gathering
    // coverage.
    //  Reset signal: testpoint_6_internal_rd_testpoint_reset_
    //  Clock signal: testpoint_6_internal_nvdla_core_clk
    reg testpoint_got_reset_testpoint_6_internal_rd_testpoint_reset__with_clock_testpoint_6_internal_nvdla_core_clk;

    initial
        testpoint_got_reset_testpoint_6_internal_rd_testpoint_reset__with_clock_testpoint_6_internal_nvdla_core_clk <= 1'b0;

    always @(posedge testpoint_6_internal_nvdla_core_clk or negedge testpoint_6_internal_rd_testpoint_reset_) begin: HAS_RETENTION_TESTPOINT_RESET_6
        if (~testpoint_6_internal_rd_testpoint_reset_)
            testpoint_got_reset_testpoint_6_internal_rd_testpoint_reset__with_clock_testpoint_6_internal_nvdla_core_clk <= 1'b1;
    end
`endif

`ifndef LINE_TESTPOINTS_OFF
    reg testpoint_6_count_0;

    reg testpoint_6_goal_0;
    initial testpoint_6_goal_0 = 0;
    initial testpoint_6_count_0 = 0;
    always@(testpoint_6_count_0) begin
        if(testpoint_6_count_0 >= 1)
         begin
 `ifdef COVER_PRINT_TESTPOINT_HITS
            if (testpoint_6_goal_0 != 1'b1)
                $display("TESTPOINT_HIT: NV_NVDLA_CDP_DP_data_fifo_80x18 ::: Fifo not empty and rd_busy ::: data_rd_pvld && !data_rd_prdy");
 `endif
            //VCS coverage on
            //coverage name NV_NVDLA_CDP_DP_data_fifo_80x18 ::: Fifo not empty and rd_busy ::: testpoint_6_goal_0
            testpoint_6_goal_0 = 1'b1;
            //VCS coverage off
        end
        else
            testpoint_6_goal_0 = 1'b0;
    end

    // Increment counters for every condition that's true this clock.
    always @(posedge testpoint_6_internal_nvdla_core_clk) begin: HAS_RETENTION_TESTPOINT_GOAL_6
        if (testpoint_6_internal_rd_testpoint_reset_) begin
 `ifdef ASSOCIATE_TESTPOINT_NAME_GOAL_NUMBER
            if ((data_rd_pvld && !data_rd_prdy) && testpoint_got_reset_testpoint_6_internal_rd_testpoint_reset__with_clock_testpoint_6_internal_nvdla_core_clk)
                $display("NVIDIA TESTPOINT: NV_NVDLA_CDP_DP_data_fifo_80x18 ::: Fifo not empty and rd_busy ::: testpoint_6_goal_0");
 `endif
            if ((data_rd_pvld && !data_rd_prdy) && testpoint_got_reset_testpoint_6_internal_rd_testpoint_reset__with_clock_testpoint_6_internal_nvdla_core_clk)
                testpoint_6_count_0 <= 1'd1;
        end
        else begin
 `ifndef FV_COVER_ON
            if (!testpoint_got_reset_testpoint_6_internal_rd_testpoint_reset__with_clock_testpoint_6_internal_nvdla_core_clk) begin
 `endif
                testpoint_6_count_0 <= 1'd0;
 `ifndef FV_COVER_ON
            end
 `endif
        end
    end
`endif // LINE_TESTPOINTS_OFF

`ifndef SV_TESTPOINTS_OFF
    wire testpoint_6_goal_0_active = ((data_rd_pvld && !data_rd_prdy) && testpoint_got_reset_testpoint_6_internal_rd_testpoint_reset__with_clock_testpoint_6_internal_nvdla_core_clk);

    // system verilog testpoints, to leverage vcs testpoint coverage tools
 `ifndef SV_TESTPOINTS_DESCRIPTIVE
    system_verilog_testpoint svt_testpoint_6_goal_0 (.clk (testpoint_6_internal_nvdla_core_clk), .tp(testpoint_6_goal_0_active));
 `else
    system_verilog_testpoint svt_Fifo_not_empty_and_rd_busy_0 (.clk (testpoint_6_internal_nvdla_core_clk), .tp(testpoint_6_goal_0_active));
 `endif
`endif

    //VCS coverage on
`endif //COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER
`endif //  DISABLE_TESTPOINTS

    // TESTPOINT_END

reg [1:0] testpoint_empty_state;
reg [1:0] testpoint_empty_state_nxt;
reg testpoint_non_empty_to_empty_to_non_empty_reached;

`define FIFO_INIT 2'b00
`define FIFO_NON_EMPTY 2'b01
`define FIFO_EMPTY 2'b10

always @(testpoint_empty_state or (!data_rd_pvld)) begin
    testpoint_empty_state_nxt = testpoint_empty_state;
    testpoint_non_empty_to_empty_to_non_empty_reached = 0;
    casez (testpoint_empty_state)
         `FIFO_INIT: begin
             if (!(!data_rd_pvld)) begin
                 testpoint_empty_state_nxt = `FIFO_NON_EMPTY;
             end
         end
         `FIFO_NON_EMPTY: begin
             if ((!data_rd_pvld)) begin
                 testpoint_empty_state_nxt = `FIFO_EMPTY;
             end
         end
         `FIFO_EMPTY: begin
             if (!(!data_rd_pvld)) begin
                 testpoint_non_empty_to_empty_to_non_empty_reached = 1;
                 testpoint_empty_state_nxt = `FIFO_NON_EMPTY;
             end
         end
         // VCS coverage off
         default: begin
             testpoint_empty_state_nxt = `FIFO_INIT;
         end
         // VCS coverage on
    endcase
end
always @( posedge nvdla_core_clk or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        testpoint_empty_state <=  2'b00;
    end else begin
         if (testpoint_empty_state != testpoint_empty_state_nxt) begin
             testpoint_empty_state <= testpoint_empty_state_nxt;
         end
     end
end

//| ::testpoint -autogen true -name "FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty" -clk nvdla_core_clk -reset rd_testpoint_reset_ testpoint_non_empty_to_empty_to_non_empty_reached; 
`ifndef DISABLE_TESTPOINTS
  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER
  `endif // COVER

  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER
  `endif // COVER

  `ifdef TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER
  `endif // TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty

`ifdef COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER


`define NV_TESTPOINT_COVERAGE_GUARD_NV_NVDLA_CDP_DP_data_fifo_80x18
//VCS coverage off
    // TESTPOINT_START
    // NAME="FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty"
    // TYPE=OCCURRENCE
    // AUTOGEN=true
    // COUNT=1
    // GROUP="DEFAULT"
    // INFO=""
    // RANDOM_COVER=true
    // ASYNC_RESET=1
    // ACTIVE_HIGH_RESET=0
wire testpoint_7_internal_nvdla_core_clk   = nvdla_core_clk;
wire testpoint_7_internal_rd_testpoint_reset_ = rd_testpoint_reset_;

`ifdef FV_COVER_ON
    // Synthesizable code for SFV.
    wire testpoint_got_reset_testpoint_7_internal_rd_testpoint_reset__with_clock_testpoint_7_internal_nvdla_core_clk = 1'b1;
`else
    // Must be clocked with reset active before we start gathering
    // coverage.
    //  Reset signal: testpoint_7_internal_rd_testpoint_reset_
    //  Clock signal: testpoint_7_internal_nvdla_core_clk
    reg testpoint_got_reset_testpoint_7_internal_rd_testpoint_reset__with_clock_testpoint_7_internal_nvdla_core_clk;

    initial
        testpoint_got_reset_testpoint_7_internal_rd_testpoint_reset__with_clock_testpoint_7_internal_nvdla_core_clk <= 1'b0;

    always @(posedge testpoint_7_internal_nvdla_core_clk or negedge testpoint_7_internal_rd_testpoint_reset_) begin: HAS_RETENTION_TESTPOINT_RESET_7
        if (~testpoint_7_internal_rd_testpoint_reset_)
            testpoint_got_reset_testpoint_7_internal_rd_testpoint_reset__with_clock_testpoint_7_internal_nvdla_core_clk <= 1'b1;
    end
`endif

`ifndef LINE_TESTPOINTS_OFF
    reg testpoint_7_count_0;

    reg testpoint_7_goal_0;
    initial testpoint_7_goal_0 = 0;
    initial testpoint_7_count_0 = 0;
    always@(testpoint_7_count_0) begin
        if(testpoint_7_count_0 >= 1)
         begin
 `ifdef COVER_PRINT_TESTPOINT_HITS
            if (testpoint_7_goal_0 != 1'b1)
                $display("TESTPOINT_HIT: NV_NVDLA_CDP_DP_data_fifo_80x18 ::: FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty ::: testpoint_non_empty_to_empty_to_non_empty_reached");
 `endif
            //VCS coverage on
            //coverage name NV_NVDLA_CDP_DP_data_fifo_80x18 ::: FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty ::: testpoint_7_goal_0
            testpoint_7_goal_0 = 1'b1;
            //VCS coverage off
        end
        else
            testpoint_7_goal_0 = 1'b0;
    end

    // Increment counters for every condition that's true this clock.
    always @(posedge testpoint_7_internal_nvdla_core_clk) begin: HAS_RETENTION_TESTPOINT_GOAL_7
        if (testpoint_7_internal_rd_testpoint_reset_) begin
 `ifdef ASSOCIATE_TESTPOINT_NAME_GOAL_NUMBER
            if ((testpoint_non_empty_to_empty_to_non_empty_reached) && testpoint_got_reset_testpoint_7_internal_rd_testpoint_reset__with_clock_testpoint_7_internal_nvdla_core_clk)
                $display("NVIDIA TESTPOINT: NV_NVDLA_CDP_DP_data_fifo_80x18 ::: FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty ::: testpoint_7_goal_0");
 `endif
            if ((testpoint_non_empty_to_empty_to_non_empty_reached) && testpoint_got_reset_testpoint_7_internal_rd_testpoint_reset__with_clock_testpoint_7_internal_nvdla_core_clk)
                testpoint_7_count_0 <= 1'd1;
        end
        else begin
 `ifndef FV_COVER_ON
            if (!testpoint_got_reset_testpoint_7_internal_rd_testpoint_reset__with_clock_testpoint_7_internal_nvdla_core_clk) begin
 `endif
                testpoint_7_count_0 <= 1'd0;
 `ifndef FV_COVER_ON
            end
 `endif
        end
    end
`endif // LINE_TESTPOINTS_OFF

`ifndef SV_TESTPOINTS_OFF
    wire testpoint_7_goal_0_active = ((testpoint_non_empty_to_empty_to_non_empty_reached) && testpoint_got_reset_testpoint_7_internal_rd_testpoint_reset__with_clock_testpoint_7_internal_nvdla_core_clk);

    // system verilog testpoints, to leverage vcs testpoint coverage tools
 `ifndef SV_TESTPOINTS_DESCRIPTIVE
    system_verilog_testpoint svt_testpoint_7_goal_0 (.clk (testpoint_7_internal_nvdla_core_clk), .tp(testpoint_7_goal_0_active));
 `else
    system_verilog_testpoint svt_FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_0 (.clk (testpoint_7_internal_nvdla_core_clk), .tp(testpoint_7_goal_0_active));
 `endif
`endif

    //VCS coverage on
`endif //COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER
`endif //  DISABLE_TESTPOINTS

    // TESTPOINT_END


`endif

//| &Viva pop ifdef_ignore_on;


//The NV_BLKBOX_SRC0 module is only present when the FIFOGEN_MODULE_SEARCH
// define is set.  This is to aid fifogen team search for fifogen fifo
// instance and module names in a given design.
`ifdef FIFOGEN_MODULE_SEARCH
NV_BLKBOX_SRC0 dummy_breadcrumb_fifogen_blkbox (.Y());
`endif

// spyglass enable_block W401 -- clock is not input to module

// synopsys dc_script_begin
//   set_boundary_optimization find(design, "NV_NVDLA_CDP_DP_data_fifo_80x18") true
// synopsys dc_script_end

//| &Attachment -no_warn EndModulePrepend;
//| _attach_EndModulePrepend_3;

`ifdef SYNTH_LEVEL1_COMPILE
`else
`ifdef SYNTHESIS
`else
`ifdef PRAND_VERILOG
// Only verilog needs any local variables
reg [47:0] prand_local_seed0;
reg prand_initialized0;
reg prand_no_rollpli0;
`endif
`endif
`endif

function [31:0] prand_inst0;
//VCS coverage off
    input [31:0] min;
    input [31:0] max;
    reg [32:0] diff;
    
    begin
`ifdef SYNTH_LEVEL1_COMPILE
        prand_inst0 = min;
`else
`ifdef SYNTHESIS
        prand_inst0 = min;
`else
`ifdef PRAND_VERILOG
        if (prand_initialized0 !== 1'b1) begin
            prand_no_rollpli0 = $test$plusargs("NO_ROLLPLI");
            if (!prand_no_rollpli0)
                prand_local_seed0 = {$prand_get_seed(0), 16'b0};
            prand_initialized0 = 1'b1;
        end
        if (prand_no_rollpli0) begin
            prand_inst0 = min;
        end else begin
            diff = max - min + 1;
            prand_inst0 = min + prand_local_seed0[47:16] % diff;
            // magic numbers taken from Java's random class (same as lrand48)
            prand_local_seed0 = prand_local_seed0 * 48'h5deece66d + 48'd11;
        end
`else
`ifdef PRAND_OFF
        prand_inst0 = min;
`else
        prand_inst0 = $RollPLI(min, max, "auto");
`endif
`endif
`endif
`endif
    end
//VCS coverage on
endfunction

//| _attach_EndModulePrepend_4;

`ifdef SYNTH_LEVEL1_COMPILE
`else
`ifdef SYNTHESIS
`else
`ifdef PRAND_VERILOG
// Only verilog needs any local variables
reg [47:0] prand_local_seed1;
reg prand_initialized1;
reg prand_no_rollpli1;
`endif
`endif
`endif

function [31:0] prand_inst1;
//VCS coverage off
    input [31:0] min;
    input [31:0] max;
    reg [32:0] diff;
    
    begin
`ifdef SYNTH_LEVEL1_COMPILE
        prand_inst1 = min;
`else
`ifdef SYNTHESIS
        prand_inst1 = min;
`else
`ifdef PRAND_VERILOG
        if (prand_initialized1 !== 1'b1) begin
            prand_no_rollpli1 = $test$plusargs("NO_ROLLPLI");
            if (!prand_no_rollpli1)
                prand_local_seed1 = {$prand_get_seed(1), 16'b0};
            prand_initialized1 = 1'b1;
        end
        if (prand_no_rollpli1) begin
            prand_inst1 = min;
        end else begin
            diff = max - min + 1;
            prand_inst1 = min + prand_local_seed1[47:16] % diff;
            // magic numbers taken from Java's random class (same as lrand48)
            prand_local_seed1 = prand_local_seed1 * 48'h5deece66d + 48'd11;
        end
`else
`ifdef PRAND_OFF
        prand_inst1 = min;
`else
        prand_inst1 = $RollPLI(min, max, "auto");
`endif
`endif
`endif
`endif
    end
//VCS coverage on
endfunction


//| &Perl $VIVA_MODULE = $NV_NVDLA_CDP_DP_data_fifo_80x18_PARENT_VIVA_MODULE;


endmodule // NV_NVDLA_CDP_DP_data_fifo_80x18



//| &Viva pop dangle_checks_off;

//| &Shell ${FIFOGEN} -stdout -m NV_NVDLA_CDP_DP_data_fifo_80x36
//|                 -clk_name   ::eval($VIVA_CLOCK)
//|                 -reset_name ::eval($VIVA_RESET)
//|                 -wr_pipebus data_wr
//|                 -rd_pipebus data_rd
//|                 -rd_reg
//|                 -ram_bypass
//|                 -d ::eval(80)
//|                 -w ::eval(36)
//|                 -ram ra2; 
//| &Depend "../../../../../../../socd/ip_chip_tools/1.0/defs/public/fifogen/golden/tlit6/fifogen.yml";
//
// AUTOMATICALLY GENERATED -- DO NOT EDIT OR CHECK IN
//
// /home/nvtools/engr/2018/04/28_05_00_03/nvtools/scripts/fifogen
// fifogen -input_config_yaml ../../../../../../../socd/ip_chip_tools/1.0/defs/public/fifogen/golden/tlit6/fifogen.yml -no_make_ram -no_make_ram -stdout -m NV_NVDLA_CDP_DP_data_fifo_80x36 -clk_name nvdla_core_clk -reset_name nvdla_core_rstn -wr_pipebus data_wr -rd_pipebus data_rd -rd_reg -ram_bypass -d 80 -w 36 -ram ra2 [Chosen ram type: ra2 - ramgen_generic (user specified, thus no other ram type is allowed)]
// chip config vars: strict_synchronizers=1  strict_synchronizers_use_lib_cells=1  strict_synchronizers_use_tm_lib_cells=1  strict_sync_randomizer=1  assertion_message_prefix=FIFOGEN_ASSERTION  testpoint_message_prefix=FIFOGEN_TESTPOINT  ignore_ramgen_fifola_variant=1  uses_p_SSYNC=0  uses_prand=1  uses_rammake_inc=1  use_x_or_0=1  force_wr_reg_gated=1  no_force_reset=1  no_timescale=1  remove_unused_ports=1  viva_parsed=1  no_pli_ifdef=1  requires_full_throughput=1  ram_auto_ff_bits_cutoff=16  ram_auto_ff_width_cutoff=2  ram_auto_ff_width_cutoff_max_depth=32  ram_auto_ff_depth_cutoff=-1  ram_auto_ff_no_la2_depth_cutoff=5  ram_auto_la2_width_cutoff=8  ram_auto_la2_width_cutoff_max_depth=56  ram_auto_la2_depth_cutoff=16  flopram_emu_model=1  dslp_single_clamp_port=1  dslp_clamp_port=1  slp_single_clamp_port=1  slp_clamp_port=1  master_clk_gated=1  clk_gate_module=NV_CLK_gate_power  redundant_timing_flops=0  hot_reset_async_force_ports_and_loopback=1  ram_sleep_en_width=1  async_cdc_reg_id=NV_AFIFO_  rd_reg_default_for_async=1  async_ram_instance_prefix=NV_ASYNC_RAM_  allow_rd_busy_reg_warning=0  do_dft_xelim_gating=1  add_dft_xelim_wr_clkgate=1  add_dft_xelim_rd_clkgate=1  allow_mt_rttrb_wr_reg=0 
//
// leda B_3208_NV OFF -- Unequal length LHS and RHS in assignment
// leda B_1405 OFF -- 2 asynchronous resets in this unit detected

//| &Viva push dangle_checks_off;

`define FORCE_CONTENTION_ASSERTION_RESET_ACTIVE 1'b1

`ifndef SYNTHESIS
    `define FIFOGEN_KEEP_ASSERTION_VERIF_CODE
`else
    `ifdef FV_ASSERT_ON
        `define FIFOGEN_KEEP_ASSERTION_VERIF_CODE
    `endif
`endif

`include "simulate_x_tick.vh"


module NV_NVDLA_CDP_DP_data_fifo_80x36 (
      nvdla_core_clk
    , nvdla_core_rstn
    , data_wr_prdy
    , data_wr_pvld
`ifdef FV_RAND_WR_PAUSE
    , data_wr_pause
`endif
    , data_wr_pd
    , data_rd_prdy
    , data_rd_pvld
    , data_rd_pd
    , pwrbus_ram_pd
    );

// spyglass disable_block W401 -- clock is not input to module
input         nvdla_core_clk;
input         nvdla_core_rstn;
output        data_wr_prdy;
input         data_wr_pvld;
`ifdef FV_RAND_WR_PAUSE
input         data_wr_pause;
`endif
input  [35:0] data_wr_pd;
input         data_rd_prdy;
output        data_rd_pvld;
output [35:0] data_rd_pd;
input  [31:0] pwrbus_ram_pd;

//| &PerlBeg;
//|     $NV_NVDLA_CDP_DP_data_fifo_80x36_PARENT_VIVA_MODULE = "$VIVA_MODULE";
//|     $VIVA_MODULE = "NV_NVDLA_CDP_DP_data_fifo_80x36";
//| &PerlEnd;


`ifdef FV_RAND_WR_PAUSE
// FV forces this signal to trigger random stalling
wire data_wr_pause = 0;
`endif

// Master Clock Gating (SLCG)
//
// We gate the clock(s) when idle or stalled.
// This allows us to turn off numerous miscellaneous flops
// that don't get gated during synthesis for one reason or another.
//
// We gate write side and read side separately. 
// If the fifo is synchronous, we also gate the ram separately, but if
// -master_clk_gated_unified or -status_reg/-status_logic_reg is specified, 
// then we use one clk gate for write, ram, and read.
//
wire nvdla_core_clk_mgated_enable;   // assigned by code at end of this module
wire nvdla_core_clk_mgated;               // used only in synchronous fifos
NV_CLK_gate_power nvdla_core_clk_mgate( .clk(nvdla_core_clk), .reset_(nvdla_core_rstn), .clk_en(nvdla_core_clk_mgated_enable), .clk_gated(nvdla_core_clk_mgated) );

// 
// WRITE SIDE
//
// VCS coverage off
`ifndef SYNTHESIS
wire wr_pause_rand;  // random stalling
`endif
// VCS coverage on
wire wr_reserving;
reg        data_wr_busy_int;		        	// copy for internal use
assign     data_wr_prdy = !data_wr_busy_int;
assign       wr_reserving = data_wr_pvld && !data_wr_busy_int; // reserving write space?



wire       wr_popping;                          // fwd: write side sees pop?


reg  [6:0] data_wr_count;			// write-side count

wire [6:0] wr_count_next_wr_popping = wr_reserving ? data_wr_count : (data_wr_count - 1'd1); // spyglass disable W164a W484
wire [6:0] wr_count_next_no_wr_popping = wr_reserving ? (data_wr_count + 1'd1) : data_wr_count; // spyglass disable W164a W484
wire [6:0] wr_count_next = wr_popping ? wr_count_next_wr_popping : 
                                               wr_count_next_no_wr_popping;

wire wr_count_next_no_wr_popping_is_80 = ( wr_count_next_no_wr_popping == 7'd80 );
wire wr_count_next_is_80 = wr_popping ? 1'b0 :
                                          wr_count_next_no_wr_popping_is_80;
wire [6:0] wr_limit_muxed;  // muxed with simulation/emulation overrides
wire [6:0] wr_limit_reg = wr_limit_muxed;
`ifdef FV_RAND_WR_PAUSE
                          // VCS coverage off
wire       data_wr_busy_next = wr_count_next_is_80 || // busy next cycle?
                          (wr_limit_reg != 7'd0 &&      // check data_wr_limit if != 0
                           wr_count_next >= wr_limit_reg) || data_wr_pause;
                          // VCS coverage on
`else
                          // VCS coverage off
wire       data_wr_busy_next = wr_count_next_is_80 || // busy next cycle?
                          (wr_limit_reg != 7'd0 &&      // check data_wr_limit if != 0
                           wr_count_next >= wr_limit_reg)  
 // VCS coverage off
 `ifndef SYNTHESIS
 || wr_pause_rand
 `endif
 // VCS coverage on
;
                          // VCS coverage on
`endif
always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_wr_busy_int <=  1'b0;
        data_wr_count <=  7'd0;
    end else begin
	data_wr_busy_int <=  data_wr_busy_next;
	if ( wr_reserving ^ wr_popping ) begin
	    data_wr_count <=  wr_count_next;
        end 
        `ifndef SYNTHESIS
        // VCS coverage off
        else if ( !(wr_reserving ^ wr_popping) ) begin
        end else begin
            data_wr_count <=  {7{`x_or_0}};
        end
        // VCS coverage on
        `endif // SYNTHESIS
    end
end

wire       wr_pushing = wr_reserving;   // data pushed same cycle as data_wr_pvld

//
// RAM
//

reg  [6:0] data_wr_adr;			// current write address
wire [6:0] data_rd_adr_p;		// read address to use for ram
wire [35:0] data_rd_pd_p_byp_ram;		// read data directly out of ram

wire rd_enable;

wire ore;
wire do_bypass;
wire comb_bypass;
wire rd_popping;
wire [31 : 0] pwrbus_ram_pd;

// Adding parameter for fifogen to disable wr/rd contention assertion in ramgen.
// Fifogen handles this by ignoring the data on the ram data out for that cycle.


nv_ram_rwsthp_80x36 #(`FORCE_CONTENTION_ASSERTION_RESET_ACTIVE) ram (
      .clk		 ( nvdla_core_clk )
    , .pwrbus_ram_pd ( pwrbus_ram_pd )
    , .wa        ( data_wr_adr )
    , .we        ( wr_pushing && (data_wr_count != 7'd0 || !rd_popping) )
    , .di        ( data_wr_pd )
    , .ra        ( data_rd_adr_p )
    , .re        ( (do_bypass && wr_pushing) || rd_enable )
    , .dout        ( data_rd_pd_p_byp_ram )
    , .byp_sel        ( comb_bypass )
    , .dbyp        ( data_wr_pd[35:0] )
    , .ore        ( ore )
    );
// next data_wr_adr if wr_pushing=1
wire [6:0] wr_adr_next = (data_wr_adr == 7'd79) ? 7'd0 : (data_wr_adr + 1'd1);  // spyglass disable W484

// spyglass disable_block W484
always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_wr_adr <=  7'd0;
    end else begin
        if ( wr_pushing ) begin
            data_wr_adr      <=  wr_adr_next;
        end 
        `ifndef SYNTHESIS
        // VCS coverage off
        else if ( !(wr_pushing) ) begin
        end else begin
            data_wr_adr   <=  {7{`x_or_0}};
        end
        // VCS coverage on
        `endif // SYNTHESIS
    end 
end
// spyglass enable_block W484

reg  [6:0] data_rd_adr;		// current read address
// next    read address
wire [6:0] rd_adr_next = (data_rd_adr == 7'd79) ? 7'd0 : (data_rd_adr + 1'd1);   // spyglass disable W484
assign         data_rd_adr_p = rd_popping ? rd_adr_next : data_rd_adr; // for ram

// spyglass disable_block W484
always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_rd_adr <=  7'd0;
    end else begin
        if ( rd_popping ) begin
	    data_rd_adr      <=  rd_adr_next;
        end 
        `ifndef SYNTHESIS
        // VCS coverage off
        else if ( !rd_popping ) begin
        end else begin
            data_rd_adr <=  {7{`x_or_0}};
        end
        // VCS coverage on
        `endif // SYNTHESIS
    end
end
// spyglass enable_block W484

assign do_bypass = (rd_popping ? (data_wr_adr == rd_adr_next) : (data_wr_adr == data_rd_adr));
wire [35:0] data_rd_pd_p_byp = data_rd_pd_p_byp_ram;


//
// Combinatorial Bypass
//
// If we're pushing an empty fifo, mux the wr_data directly.
//
assign comb_bypass = data_wr_count == 0;
wire [35:0] data_rd_pd_p = data_rd_pd_p_byp;



//
// SYNCHRONOUS BOUNDARY
//


assign wr_popping = rd_popping;		// let it be seen immediately


wire   rd_pushing = wr_pushing;		// let it be seen immediately

//
// READ SIDE
//

wire       data_rd_pvld_p; 		// data out of fifo is valid

reg        data_rd_pvld_int;	// internal copy of data_rd_pvld
assign     data_rd_pvld = data_rd_pvld_int;
assign     rd_popping = data_rd_pvld_p && !(data_rd_pvld_int && !data_rd_prdy);

reg  [6:0] data_rd_count_p;			// read-side fifo count
// spyglass disable_block W164a W484
wire [6:0] rd_count_p_next_rd_popping = rd_pushing ? data_rd_count_p : 
                                                                (data_rd_count_p - 1'd1);
wire [6:0] rd_count_p_next_no_rd_popping =  rd_pushing ? (data_rd_count_p + 1'd1) : 
                                                                    data_rd_count_p;
// spyglass enable_block W164a W484
wire [6:0] rd_count_p_next = rd_popping ? rd_count_p_next_rd_popping :
                                                     rd_count_p_next_no_rd_popping; 
wire rd_count_p_next_rd_popping_not_0 = rd_count_p_next_rd_popping != 0;
wire rd_count_p_next_no_rd_popping_not_0 = rd_count_p_next_no_rd_popping != 0;
wire rd_count_p_next_not_0 = rd_popping ? rd_count_p_next_rd_popping_not_0 :
                                              rd_count_p_next_no_rd_popping_not_0;
assign     data_rd_pvld_p = data_rd_count_p != 0 || rd_pushing;
assign rd_enable = ((rd_count_p_next_not_0) && ((~data_rd_pvld_p) || rd_popping));  // anytime data's there and not stalled
always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_rd_count_p <=  7'd0;
    end else begin
        if ( rd_pushing || rd_popping  ) begin
	    data_rd_count_p <=  rd_count_p_next;
        end 
        `ifndef SYNTHESIS
        // VCS coverage off
        else if ( !(rd_pushing || rd_popping ) ) begin
        end else begin
            data_rd_count_p <=  {7{`x_or_0}};
        end
        // VCS coverage on
        `endif // SYNTHESIS
    end
end
wire        rd_req_next = (data_rd_pvld_p || (data_rd_pvld_int && !data_rd_prdy)) ;

always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_rd_pvld_int <=  1'b0;
    end else begin
        data_rd_pvld_int <=  rd_req_next;
    end
end
assign data_rd_pd = data_rd_pd_p;
assign ore = rd_popping;

// Master Clock Gating (SLCG) Enables
//

// plusarg for disabling this stuff:

// VCS coverage off
`ifndef SYNTHESIS
reg master_clk_gating_disabled;  initial master_clk_gating_disabled = $test$plusargs( "fifogen_disable_master_clk_gating" ) != 0;
`endif
// VCS coverage on

// VCS coverage off
`ifndef SYNTHESIS
reg wr_pause_rand_dly;  
always @( posedge nvdla_core_clk or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        wr_pause_rand_dly <=  1'b0;
    end else begin
        wr_pause_rand_dly <=  wr_pause_rand;
    end
end
`endif
// VCS coverage on
assign nvdla_core_clk_mgated_enable = ((wr_reserving || wr_pushing || wr_popping || (data_wr_pvld && !data_wr_busy_int) || (data_wr_busy_int != data_wr_busy_next)) || (rd_pushing || rd_popping || (data_rd_pvld_int && data_rd_prdy)))
                               `ifdef FIFOGEN_MASTER_CLK_GATING_DISABLED
                               || 1'b1
                               `endif
                               // VCS coverage off
                               `ifndef SYNTHESIS
                               || master_clk_gating_disabled || (wr_pause_rand != wr_pause_rand_dly)
                               `endif
                               // VCS coverage on
;


// Simulation and Emulation Overrides of wr_limit(s)
//

`ifdef EMU

`ifdef EMU_FIFO_CFG
// Emulation Global Config Override
//
assign wr_limit_muxed = `EMU_FIFO_CFG.NV_NVDLA_CDP_DP_data_fifo_80x36_wr_limit_override ? `EMU_FIFO_CFG.NV_NVDLA_CDP_DP_data_fifo_80x36_wr_limit : 7'd0;
`else
// No Global Override for Emulation 
//
assign wr_limit_muxed = 7'd0;
`endif // EMU_FIFO_CFG

`else // !EMU
`ifdef SYNTHESIS

// No Override for RTL Synthesis
//

assign wr_limit_muxed = 7'd0;

`else  

// RTL Simulation Plusarg Override


// VCS coverage off

reg wr_limit_override;
reg [6:0] wr_limit_override_value; 
assign wr_limit_muxed = wr_limit_override ? wr_limit_override_value : 7'd0;
`ifdef NV_ARCHPRO
event reinit;

initial begin
    $display("fifogen reinit initial block %m");
    -> reinit;
end
`endif

`ifdef NV_ARCHPRO
always @( reinit ) begin
`else 
initial begin
`endif
    wr_limit_override = 0;
    wr_limit_override_value = 0;  // to keep viva happy with dangles
    if ( $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x36_wr_limit" ) ) begin
        wr_limit_override = 1;
        $value$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x36_wr_limit=%d", wr_limit_override_value);
    end
end

// VCS coverage on


`endif
`endif


// Random Write-Side Stalling
// VCS coverage off
`ifndef SYNTHESIS
// VCS coverage off

// leda W339 OFF -- Non synthesizable operator
// leda W372 OFF -- Undefined PLI task
// leda W373 OFF -- Undefined PLI function
// leda W599 OFF -- This construct is not supported by Synopsys
// leda W430 OFF -- Initial statement is not synthesizable
// leda W182 OFF -- Illegal statement for synthesis
// leda W639 OFF -- For synthesis, operands of a division or modulo operation need to be constants
// leda DCVER_274_NV OFF -- This system task is not supported by DC

integer stall_probability;      // prob of stalling
integer stall_cycles_min;       // min cycles to stall
integer stall_cycles_max;       // max cycles to stall
integer stall_cycles_left;      // stall cycles left
`ifdef NV_ARCHPRO
always @( reinit ) begin
`else 
initial begin
`endif
    stall_probability      = 0; // no stalling by default
    stall_cycles_min       = 1;
    stall_cycles_max       = 10;

`ifdef NO_PLI
`else
    if ( $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x36_fifo_stall_probability" ) ) begin
        $value$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x36_fifo_stall_probability=%d", stall_probability);
    end else if ( $test$plusargs( "default_fifo_stall_probability" ) ) begin
        $value$plusargs( "default_fifo_stall_probability=%d", stall_probability);
    end

    if ( $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x36_fifo_stall_cycles_min" ) ) begin
        $value$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x36_fifo_stall_cycles_min=%d", stall_cycles_min);
    end else if ( $test$plusargs( "default_fifo_stall_cycles_min" ) ) begin
        $value$plusargs( "default_fifo_stall_cycles_min=%d", stall_cycles_min);
    end

    if ( $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x36_fifo_stall_cycles_max" ) ) begin
        $value$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x36_fifo_stall_cycles_max=%d", stall_cycles_max);
    end else if ( $test$plusargs( "default_fifo_stall_cycles_max" ) ) begin
        $value$plusargs( "default_fifo_stall_cycles_max=%d", stall_cycles_max);
    end
`endif

    if ( stall_cycles_min < 1 ) begin
        stall_cycles_min = 1;
    end

    if ( stall_cycles_min > stall_cycles_max ) begin
        stall_cycles_max = stall_cycles_min;
    end

end

`ifdef NO_PLI
`else

// randomization globals
`ifdef SIMTOP_RANDOMIZE_STALLS
  always @( `SIMTOP_RANDOMIZE_STALLS.global_stall_event ) begin
    if ( ! $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x36_fifo_stall_probability" ) ) stall_probability = `SIMTOP_RANDOMIZE_STALLS.global_stall_fifo_probability; 
    if ( ! $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x36_fifo_stall_cycles_min"  ) ) stall_cycles_min  = `SIMTOP_RANDOMIZE_STALLS.global_stall_fifo_cycles_min;
    if ( ! $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x36_fifo_stall_cycles_max"  ) ) stall_cycles_max  = `SIMTOP_RANDOMIZE_STALLS.global_stall_fifo_cycles_max;
  end
`endif

`endif

always @( negedge nvdla_core_clk or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        stall_cycles_left <=  0;
    end else begin
`ifdef NO_PLI
            stall_cycles_left <=  0;
`else
            if ( data_wr_pvld && !(!data_wr_prdy)
                 && stall_probability != 0 ) begin
                if ( prand_inst0(1, 100) <= stall_probability ) begin
                    stall_cycles_left <=  prand_inst1(stall_cycles_min, stall_cycles_max);
                end else if ( stall_cycles_left !== 0  ) begin
                    stall_cycles_left <=  stall_cycles_left - 1;
                end
            end else if ( stall_cycles_left !== 0  ) begin
                stall_cycles_left <=  stall_cycles_left - 1;
            end
`endif
    end
end

assign wr_pause_rand = (stall_cycles_left !== 0) ;

// VCS coverage on
`endif
// VCS coverage on

// leda W339 ON
// leda W372 ON
// leda W373 ON
// leda W599 ON
// leda W430 ON
// leda W182 ON
// leda W639 ON
// leda DCVER_274_NV ON


//
// Histogram of fifo depth (from write side's perspective)
//
// NOTE: it will reference `SIMTOP.perfmon_enabled, so that
//       has to at least be defined, though not initialized.
//	 tbgen testbenches have it already and various
//	 ways to turn it on and off.
//
`ifdef PERFMON_HISTOGRAM 
// VCS coverage off
`ifndef SYNTHESIS
perfmon_histogram perfmon (
      .clk	( nvdla_core_clk ) 
    , .max      ( {25'd0, (wr_limit_reg == 7'd0) ? 7'd80 : wr_limit_reg} )
    , .curr	( {25'd0, data_wr_count} )
    );
`endif
// VCS coverage on
`endif

// spyglass disable_block W164a W164b W116 W484 W504

`ifdef SPYGLASS
`else

`ifdef FIFOGEN_KEEP_ASSERTION_VERIF_CODE
// VCS coverage off
`ifdef ASSERT_ON



`ifdef SPYGLASS
wire disable_assert_plusarg = 1'b0;
`else

`ifdef FV_ASSERT_ON
wire disable_assert_plusarg = 1'b0;
`else
wire disable_assert_plusarg = |($test$plusargs("DISABLE_NESS_FLOW_ASSERTIONS"));
`endif // ifdef FV_ASSERT_ON

`endif // ifdef SPYGLASS


wire assert_enabled = 1'b1 && !disable_assert_plusarg;


`endif // ifdef ASSERT_ON
// VCS coverage on
`endif // ifdef FIFOGEN_KEEP_ASSERTION_VERIF_CODE


`ifdef ASSERT_ON

// VCS coverage off
`ifndef SYNTHESIS
always @(assert_enabled) begin
    if ( assert_enabled === 1'b0 ) begin
        $display("Asserts are disabled for %m");
    end
end
`endif
// VCS coverage on

`endif

`endif

// spyglass enable_block W164a W164b W116 W484 W504


//| &Viva push ifdef_ignore_on;

`ifdef COVER

wire wr_testpoint_reset_ = ( nvdla_core_rstn === 1'bx ? 1'b0 : nvdla_core_rstn );


//| ::testpoint -autogen true -name "FIFOGEN_TESTPOINT Fifo Full" -clk nvdla_core_clk -reset wr_testpoint_reset_ data_wr_count==80;
//| &Force internal /^testpoint_/;

`ifndef DISABLE_TESTPOINTS
  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER
  `endif // COVER

  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER
  `endif // COVER

  `ifdef TP__FIFOGEN_TESTPOINT_Fifo_Full
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER
  `endif // TP__FIFOGEN_TESTPOINT_Fifo_Full

`ifdef COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER


`define NV_TESTPOINT_COVERAGE_GUARD_NV_NVDLA_CDP_DP_data_fifo_80x36
//VCS coverage off
    // TESTPOINT_START
    // NAME="FIFOGEN_TESTPOINT Fifo Full"
    // TYPE=OCCURRENCE
    // AUTOGEN=true
    // COUNT=1
    // GROUP="DEFAULT"
    // INFO=""
    // RANDOM_COVER=true
    // ASYNC_RESET=1
    // ACTIVE_HIGH_RESET=0
wire testpoint_8_internal_nvdla_core_clk   = nvdla_core_clk;
wire testpoint_8_internal_wr_testpoint_reset_ = wr_testpoint_reset_;

`ifdef FV_COVER_ON
    // Synthesizable code for SFV.
    wire testpoint_got_reset_testpoint_8_internal_wr_testpoint_reset__with_clock_testpoint_8_internal_nvdla_core_clk = 1'b1;
`else
    // Must be clocked with reset active before we start gathering
    // coverage.
    //  Reset signal: testpoint_8_internal_wr_testpoint_reset_
    //  Clock signal: testpoint_8_internal_nvdla_core_clk
    reg testpoint_got_reset_testpoint_8_internal_wr_testpoint_reset__with_clock_testpoint_8_internal_nvdla_core_clk;

    initial
        testpoint_got_reset_testpoint_8_internal_wr_testpoint_reset__with_clock_testpoint_8_internal_nvdla_core_clk <= 1'b0;

    always @(posedge testpoint_8_internal_nvdla_core_clk or negedge testpoint_8_internal_wr_testpoint_reset_) begin: HAS_RETENTION_TESTPOINT_RESET_8
        if (~testpoint_8_internal_wr_testpoint_reset_)
            testpoint_got_reset_testpoint_8_internal_wr_testpoint_reset__with_clock_testpoint_8_internal_nvdla_core_clk <= 1'b1;
    end
`endif

`ifndef LINE_TESTPOINTS_OFF
    reg testpoint_8_count_0;

    reg testpoint_8_goal_0;
    initial testpoint_8_goal_0 = 0;
    initial testpoint_8_count_0 = 0;
    always@(testpoint_8_count_0) begin
        if(testpoint_8_count_0 >= 1)
         begin
 `ifdef COVER_PRINT_TESTPOINT_HITS
            if (testpoint_8_goal_0 != 1'b1)
                $display("TESTPOINT_HIT: NV_NVDLA_CDP_DP_data_fifo_80x36 ::: FIFOGEN_TESTPOINT Fifo Full ::: data_wr_count==80");
 `endif
            //VCS coverage on
            //coverage name NV_NVDLA_CDP_DP_data_fifo_80x36 ::: FIFOGEN_TESTPOINT Fifo Full ::: testpoint_8_goal_0
            testpoint_8_goal_0 = 1'b1;
            //VCS coverage off
        end
        else
            testpoint_8_goal_0 = 1'b0;
    end

    // Increment counters for every condition that's true this clock.
    always @(posedge testpoint_8_internal_nvdla_core_clk) begin: HAS_RETENTION_TESTPOINT_GOAL_8
        if (testpoint_8_internal_wr_testpoint_reset_) begin
 `ifdef ASSOCIATE_TESTPOINT_NAME_GOAL_NUMBER
            if ((data_wr_count==80) && testpoint_got_reset_testpoint_8_internal_wr_testpoint_reset__with_clock_testpoint_8_internal_nvdla_core_clk)
                $display("NVIDIA TESTPOINT: NV_NVDLA_CDP_DP_data_fifo_80x36 ::: FIFOGEN_TESTPOINT Fifo Full ::: testpoint_8_goal_0");
 `endif
            if ((data_wr_count==80) && testpoint_got_reset_testpoint_8_internal_wr_testpoint_reset__with_clock_testpoint_8_internal_nvdla_core_clk)
                testpoint_8_count_0 <= 1'd1;
        end
        else begin
 `ifndef FV_COVER_ON
            if (!testpoint_got_reset_testpoint_8_internal_wr_testpoint_reset__with_clock_testpoint_8_internal_nvdla_core_clk) begin
 `endif
                testpoint_8_count_0 <= 1'd0;
 `ifndef FV_COVER_ON
            end
 `endif
        end
    end
`endif // LINE_TESTPOINTS_OFF

`ifndef SV_TESTPOINTS_OFF
    wire testpoint_8_goal_0_active = ((data_wr_count==80) && testpoint_got_reset_testpoint_8_internal_wr_testpoint_reset__with_clock_testpoint_8_internal_nvdla_core_clk);

    // system verilog testpoints, to leverage vcs testpoint coverage tools
 `ifndef SV_TESTPOINTS_DESCRIPTIVE
    system_verilog_testpoint svt_testpoint_8_goal_0 (.clk (testpoint_8_internal_nvdla_core_clk), .tp(testpoint_8_goal_0_active));
 `else
    system_verilog_testpoint svt_FIFOGEN_TESTPOINT_Fifo_Full_0 (.clk (testpoint_8_internal_nvdla_core_clk), .tp(testpoint_8_goal_0_active));
 `endif
`endif

    //VCS coverage on
`endif //COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER
`endif //  DISABLE_TESTPOINTS

    // TESTPOINT_END
//| ::testpoint -autogen true -name "FIFOGEN_TESTPOINT Fifo Full and wr_req" -clk nvdla_core_clk -reset wr_testpoint_reset_ data_wr_count==80 && data_wr_pvld;
`ifndef DISABLE_TESTPOINTS
  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER
  `endif // COVER

  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER
  `endif // COVER

  `ifdef TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER
  `endif // TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req

`ifdef COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER


`define NV_TESTPOINT_COVERAGE_GUARD_NV_NVDLA_CDP_DP_data_fifo_80x36
//VCS coverage off
    // TESTPOINT_START
    // NAME="FIFOGEN_TESTPOINT Fifo Full and wr_req"
    // TYPE=OCCURRENCE
    // AUTOGEN=true
    // COUNT=1
    // GROUP="DEFAULT"
    // INFO=""
    // RANDOM_COVER=true
    // ASYNC_RESET=1
    // ACTIVE_HIGH_RESET=0
wire testpoint_9_internal_nvdla_core_clk   = nvdla_core_clk;
wire testpoint_9_internal_wr_testpoint_reset_ = wr_testpoint_reset_;

`ifdef FV_COVER_ON
    // Synthesizable code for SFV.
    wire testpoint_got_reset_testpoint_9_internal_wr_testpoint_reset__with_clock_testpoint_9_internal_nvdla_core_clk = 1'b1;
`else
    // Must be clocked with reset active before we start gathering
    // coverage.
    //  Reset signal: testpoint_9_internal_wr_testpoint_reset_
    //  Clock signal: testpoint_9_internal_nvdla_core_clk
    reg testpoint_got_reset_testpoint_9_internal_wr_testpoint_reset__with_clock_testpoint_9_internal_nvdla_core_clk;

    initial
        testpoint_got_reset_testpoint_9_internal_wr_testpoint_reset__with_clock_testpoint_9_internal_nvdla_core_clk <= 1'b0;

    always @(posedge testpoint_9_internal_nvdla_core_clk or negedge testpoint_9_internal_wr_testpoint_reset_) begin: HAS_RETENTION_TESTPOINT_RESET_9
        if (~testpoint_9_internal_wr_testpoint_reset_)
            testpoint_got_reset_testpoint_9_internal_wr_testpoint_reset__with_clock_testpoint_9_internal_nvdla_core_clk <= 1'b1;
    end
`endif

`ifndef LINE_TESTPOINTS_OFF
    reg testpoint_9_count_0;

    reg testpoint_9_goal_0;
    initial testpoint_9_goal_0 = 0;
    initial testpoint_9_count_0 = 0;
    always@(testpoint_9_count_0) begin
        if(testpoint_9_count_0 >= 1)
         begin
 `ifdef COVER_PRINT_TESTPOINT_HITS
            if (testpoint_9_goal_0 != 1'b1)
                $display("TESTPOINT_HIT: NV_NVDLA_CDP_DP_data_fifo_80x36 ::: FIFOGEN_TESTPOINT Fifo Full and wr_req ::: data_wr_count==80 && data_wr_pvld");
 `endif
            //VCS coverage on
            //coverage name NV_NVDLA_CDP_DP_data_fifo_80x36 ::: FIFOGEN_TESTPOINT Fifo Full and wr_req ::: testpoint_9_goal_0
            testpoint_9_goal_0 = 1'b1;
            //VCS coverage off
        end
        else
            testpoint_9_goal_0 = 1'b0;
    end

    // Increment counters for every condition that's true this clock.
    always @(posedge testpoint_9_internal_nvdla_core_clk) begin: HAS_RETENTION_TESTPOINT_GOAL_9
        if (testpoint_9_internal_wr_testpoint_reset_) begin
 `ifdef ASSOCIATE_TESTPOINT_NAME_GOAL_NUMBER
            if ((data_wr_count==80 && data_wr_pvld) && testpoint_got_reset_testpoint_9_internal_wr_testpoint_reset__with_clock_testpoint_9_internal_nvdla_core_clk)
                $display("NVIDIA TESTPOINT: NV_NVDLA_CDP_DP_data_fifo_80x36 ::: FIFOGEN_TESTPOINT Fifo Full and wr_req ::: testpoint_9_goal_0");
 `endif
            if ((data_wr_count==80 && data_wr_pvld) && testpoint_got_reset_testpoint_9_internal_wr_testpoint_reset__with_clock_testpoint_9_internal_nvdla_core_clk)
                testpoint_9_count_0 <= 1'd1;
        end
        else begin
 `ifndef FV_COVER_ON
            if (!testpoint_got_reset_testpoint_9_internal_wr_testpoint_reset__with_clock_testpoint_9_internal_nvdla_core_clk) begin
 `endif
                testpoint_9_count_0 <= 1'd0;
 `ifndef FV_COVER_ON
            end
 `endif
        end
    end
`endif // LINE_TESTPOINTS_OFF

`ifndef SV_TESTPOINTS_OFF
    wire testpoint_9_goal_0_active = ((data_wr_count==80 && data_wr_pvld) && testpoint_got_reset_testpoint_9_internal_wr_testpoint_reset__with_clock_testpoint_9_internal_nvdla_core_clk);

    // system verilog testpoints, to leverage vcs testpoint coverage tools
 `ifndef SV_TESTPOINTS_DESCRIPTIVE
    system_verilog_testpoint svt_testpoint_9_goal_0 (.clk (testpoint_9_internal_nvdla_core_clk), .tp(testpoint_9_goal_0_active));
 `else
    system_verilog_testpoint svt_FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_0 (.clk (testpoint_9_internal_nvdla_core_clk), .tp(testpoint_9_goal_0_active));
 `endif
`endif

    //VCS coverage on
`endif //COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER
`endif //  DISABLE_TESTPOINTS

    // TESTPOINT_END


wire rd_testpoint_reset_ = ( nvdla_core_rstn === 1'bx ? 1'b0 : nvdla_core_rstn );


//| ::testpoint -autogen true -name "Fifo not empty and rd_busy" -clk nvdla_core_clk -reset rd_testpoint_reset_ data_rd_pvld && !data_rd_prdy;
`ifndef DISABLE_TESTPOINTS
  `ifdef COVER
    `define COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER
  `endif // COVER

  `ifdef COVER
    `define COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER
  `endif // COVER

  `ifdef TP__Fifo_not_empty_and_rd_busy
    `define COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER
  `endif // TP__Fifo_not_empty_and_rd_busy

`ifdef COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER


`define NV_TESTPOINT_COVERAGE_GUARD_NV_NVDLA_CDP_DP_data_fifo_80x36
//VCS coverage off
    // TESTPOINT_START
    // NAME="Fifo not empty and rd_busy"
    // TYPE=OCCURRENCE
    // AUTOGEN=true
    // COUNT=1
    // GROUP="DEFAULT"
    // INFO=""
    // RANDOM_COVER=true
    // ASYNC_RESET=1
    // ACTIVE_HIGH_RESET=0
wire testpoint_10_internal_nvdla_core_clk   = nvdla_core_clk;
wire testpoint_10_internal_rd_testpoint_reset_ = rd_testpoint_reset_;

`ifdef FV_COVER_ON
    // Synthesizable code for SFV.
    wire testpoint_got_reset_testpoint_10_internal_rd_testpoint_reset__with_clock_testpoint_10_internal_nvdla_core_clk = 1'b1;
`else
    // Must be clocked with reset active before we start gathering
    // coverage.
    //  Reset signal: testpoint_10_internal_rd_testpoint_reset_
    //  Clock signal: testpoint_10_internal_nvdla_core_clk
    reg testpoint_got_reset_testpoint_10_internal_rd_testpoint_reset__with_clock_testpoint_10_internal_nvdla_core_clk;

    initial
        testpoint_got_reset_testpoint_10_internal_rd_testpoint_reset__with_clock_testpoint_10_internal_nvdla_core_clk <= 1'b0;

    always @(posedge testpoint_10_internal_nvdla_core_clk or negedge testpoint_10_internal_rd_testpoint_reset_) begin: HAS_RETENTION_TESTPOINT_RESET_10
        if (~testpoint_10_internal_rd_testpoint_reset_)
            testpoint_got_reset_testpoint_10_internal_rd_testpoint_reset__with_clock_testpoint_10_internal_nvdla_core_clk <= 1'b1;
    end
`endif

`ifndef LINE_TESTPOINTS_OFF
    reg testpoint_10_count_0;

    reg testpoint_10_goal_0;
    initial testpoint_10_goal_0 = 0;
    initial testpoint_10_count_0 = 0;
    always@(testpoint_10_count_0) begin
        if(testpoint_10_count_0 >= 1)
         begin
 `ifdef COVER_PRINT_TESTPOINT_HITS
            if (testpoint_10_goal_0 != 1'b1)
                $display("TESTPOINT_HIT: NV_NVDLA_CDP_DP_data_fifo_80x36 ::: Fifo not empty and rd_busy ::: data_rd_pvld && !data_rd_prdy");
 `endif
            //VCS coverage on
            //coverage name NV_NVDLA_CDP_DP_data_fifo_80x36 ::: Fifo not empty and rd_busy ::: testpoint_10_goal_0
            testpoint_10_goal_0 = 1'b1;
            //VCS coverage off
        end
        else
            testpoint_10_goal_0 = 1'b0;
    end

    // Increment counters for every condition that's true this clock.
    always @(posedge testpoint_10_internal_nvdla_core_clk) begin: HAS_RETENTION_TESTPOINT_GOAL_10
        if (testpoint_10_internal_rd_testpoint_reset_) begin
 `ifdef ASSOCIATE_TESTPOINT_NAME_GOAL_NUMBER
            if ((data_rd_pvld && !data_rd_prdy) && testpoint_got_reset_testpoint_10_internal_rd_testpoint_reset__with_clock_testpoint_10_internal_nvdla_core_clk)
                $display("NVIDIA TESTPOINT: NV_NVDLA_CDP_DP_data_fifo_80x36 ::: Fifo not empty and rd_busy ::: testpoint_10_goal_0");
 `endif
            if ((data_rd_pvld && !data_rd_prdy) && testpoint_got_reset_testpoint_10_internal_rd_testpoint_reset__with_clock_testpoint_10_internal_nvdla_core_clk)
                testpoint_10_count_0 <= 1'd1;
        end
        else begin
 `ifndef FV_COVER_ON
            if (!testpoint_got_reset_testpoint_10_internal_rd_testpoint_reset__with_clock_testpoint_10_internal_nvdla_core_clk) begin
 `endif
                testpoint_10_count_0 <= 1'd0;
 `ifndef FV_COVER_ON
            end
 `endif
        end
    end
`endif // LINE_TESTPOINTS_OFF

`ifndef SV_TESTPOINTS_OFF
    wire testpoint_10_goal_0_active = ((data_rd_pvld && !data_rd_prdy) && testpoint_got_reset_testpoint_10_internal_rd_testpoint_reset__with_clock_testpoint_10_internal_nvdla_core_clk);

    // system verilog testpoints, to leverage vcs testpoint coverage tools
 `ifndef SV_TESTPOINTS_DESCRIPTIVE
    system_verilog_testpoint svt_testpoint_10_goal_0 (.clk (testpoint_10_internal_nvdla_core_clk), .tp(testpoint_10_goal_0_active));
 `else
    system_verilog_testpoint svt_Fifo_not_empty_and_rd_busy_0 (.clk (testpoint_10_internal_nvdla_core_clk), .tp(testpoint_10_goal_0_active));
 `endif
`endif

    //VCS coverage on
`endif //COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER
`endif //  DISABLE_TESTPOINTS

    // TESTPOINT_END

reg [1:0] testpoint_empty_state;
reg [1:0] testpoint_empty_state_nxt;
reg testpoint_non_empty_to_empty_to_non_empty_reached;

`define FIFO_INIT 2'b00
`define FIFO_NON_EMPTY 2'b01
`define FIFO_EMPTY 2'b10

always @(testpoint_empty_state or (!data_rd_pvld)) begin
    testpoint_empty_state_nxt = testpoint_empty_state;
    testpoint_non_empty_to_empty_to_non_empty_reached = 0;
    casez (testpoint_empty_state)
         `FIFO_INIT: begin
             if (!(!data_rd_pvld)) begin
                 testpoint_empty_state_nxt = `FIFO_NON_EMPTY;
             end
         end
         `FIFO_NON_EMPTY: begin
             if ((!data_rd_pvld)) begin
                 testpoint_empty_state_nxt = `FIFO_EMPTY;
             end
         end
         `FIFO_EMPTY: begin
             if (!(!data_rd_pvld)) begin
                 testpoint_non_empty_to_empty_to_non_empty_reached = 1;
                 testpoint_empty_state_nxt = `FIFO_NON_EMPTY;
             end
         end
         // VCS coverage off
         default: begin
             testpoint_empty_state_nxt = `FIFO_INIT;
         end
         // VCS coverage on
    endcase
end
always @( posedge nvdla_core_clk or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        testpoint_empty_state <=  2'b00;
    end else begin
         if (testpoint_empty_state != testpoint_empty_state_nxt) begin
             testpoint_empty_state <= testpoint_empty_state_nxt;
         end
     end
end

//| ::testpoint -autogen true -name "FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty" -clk nvdla_core_clk -reset rd_testpoint_reset_ testpoint_non_empty_to_empty_to_non_empty_reached; 
`ifndef DISABLE_TESTPOINTS
  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER
  `endif // COVER

  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER
  `endif // COVER

  `ifdef TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER
  `endif // TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty

`ifdef COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER


`define NV_TESTPOINT_COVERAGE_GUARD_NV_NVDLA_CDP_DP_data_fifo_80x36
//VCS coverage off
    // TESTPOINT_START
    // NAME="FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty"
    // TYPE=OCCURRENCE
    // AUTOGEN=true
    // COUNT=1
    // GROUP="DEFAULT"
    // INFO=""
    // RANDOM_COVER=true
    // ASYNC_RESET=1
    // ACTIVE_HIGH_RESET=0
wire testpoint_11_internal_nvdla_core_clk   = nvdla_core_clk;
wire testpoint_11_internal_rd_testpoint_reset_ = rd_testpoint_reset_;

`ifdef FV_COVER_ON
    // Synthesizable code for SFV.
    wire testpoint_got_reset_testpoint_11_internal_rd_testpoint_reset__with_clock_testpoint_11_internal_nvdla_core_clk = 1'b1;
`else
    // Must be clocked with reset active before we start gathering
    // coverage.
    //  Reset signal: testpoint_11_internal_rd_testpoint_reset_
    //  Clock signal: testpoint_11_internal_nvdla_core_clk
    reg testpoint_got_reset_testpoint_11_internal_rd_testpoint_reset__with_clock_testpoint_11_internal_nvdla_core_clk;

    initial
        testpoint_got_reset_testpoint_11_internal_rd_testpoint_reset__with_clock_testpoint_11_internal_nvdla_core_clk <= 1'b0;

    always @(posedge testpoint_11_internal_nvdla_core_clk or negedge testpoint_11_internal_rd_testpoint_reset_) begin: HAS_RETENTION_TESTPOINT_RESET_11
        if (~testpoint_11_internal_rd_testpoint_reset_)
            testpoint_got_reset_testpoint_11_internal_rd_testpoint_reset__with_clock_testpoint_11_internal_nvdla_core_clk <= 1'b1;
    end
`endif

`ifndef LINE_TESTPOINTS_OFF
    reg testpoint_11_count_0;

    reg testpoint_11_goal_0;
    initial testpoint_11_goal_0 = 0;
    initial testpoint_11_count_0 = 0;
    always@(testpoint_11_count_0) begin
        if(testpoint_11_count_0 >= 1)
         begin
 `ifdef COVER_PRINT_TESTPOINT_HITS
            if (testpoint_11_goal_0 != 1'b1)
                $display("TESTPOINT_HIT: NV_NVDLA_CDP_DP_data_fifo_80x36 ::: FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty ::: testpoint_non_empty_to_empty_to_non_empty_reached");
 `endif
            //VCS coverage on
            //coverage name NV_NVDLA_CDP_DP_data_fifo_80x36 ::: FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty ::: testpoint_11_goal_0
            testpoint_11_goal_0 = 1'b1;
            //VCS coverage off
        end
        else
            testpoint_11_goal_0 = 1'b0;
    end

    // Increment counters for every condition that's true this clock.
    always @(posedge testpoint_11_internal_nvdla_core_clk) begin: HAS_RETENTION_TESTPOINT_GOAL_11
        if (testpoint_11_internal_rd_testpoint_reset_) begin
 `ifdef ASSOCIATE_TESTPOINT_NAME_GOAL_NUMBER
            if ((testpoint_non_empty_to_empty_to_non_empty_reached) && testpoint_got_reset_testpoint_11_internal_rd_testpoint_reset__with_clock_testpoint_11_internal_nvdla_core_clk)
                $display("NVIDIA TESTPOINT: NV_NVDLA_CDP_DP_data_fifo_80x36 ::: FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty ::: testpoint_11_goal_0");
 `endif
            if ((testpoint_non_empty_to_empty_to_non_empty_reached) && testpoint_got_reset_testpoint_11_internal_rd_testpoint_reset__with_clock_testpoint_11_internal_nvdla_core_clk)
                testpoint_11_count_0 <= 1'd1;
        end
        else begin
 `ifndef FV_COVER_ON
            if (!testpoint_got_reset_testpoint_11_internal_rd_testpoint_reset__with_clock_testpoint_11_internal_nvdla_core_clk) begin
 `endif
                testpoint_11_count_0 <= 1'd0;
 `ifndef FV_COVER_ON
            end
 `endif
        end
    end
`endif // LINE_TESTPOINTS_OFF

`ifndef SV_TESTPOINTS_OFF
    wire testpoint_11_goal_0_active = ((testpoint_non_empty_to_empty_to_non_empty_reached) && testpoint_got_reset_testpoint_11_internal_rd_testpoint_reset__with_clock_testpoint_11_internal_nvdla_core_clk);

    // system verilog testpoints, to leverage vcs testpoint coverage tools
 `ifndef SV_TESTPOINTS_DESCRIPTIVE
    system_verilog_testpoint svt_testpoint_11_goal_0 (.clk (testpoint_11_internal_nvdla_core_clk), .tp(testpoint_11_goal_0_active));
 `else
    system_verilog_testpoint svt_FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_0 (.clk (testpoint_11_internal_nvdla_core_clk), .tp(testpoint_11_goal_0_active));
 `endif
`endif

    //VCS coverage on
`endif //COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER
`endif //  DISABLE_TESTPOINTS

    // TESTPOINT_END


`endif

//| &Viva pop ifdef_ignore_on;


//The NV_BLKBOX_SRC0 module is only present when the FIFOGEN_MODULE_SEARCH
// define is set.  This is to aid fifogen team search for fifogen fifo
// instance and module names in a given design.
`ifdef FIFOGEN_MODULE_SEARCH
NV_BLKBOX_SRC0 dummy_breadcrumb_fifogen_blkbox (.Y());
`endif

// spyglass enable_block W401 -- clock is not input to module

// synopsys dc_script_begin
//   set_boundary_optimization find(design, "NV_NVDLA_CDP_DP_data_fifo_80x36") true
// synopsys dc_script_end

//| &Attachment -no_warn EndModulePrepend;
//| _attach_EndModulePrepend_5;

`ifdef SYNTH_LEVEL1_COMPILE
`else
`ifdef SYNTHESIS
`else
`ifdef PRAND_VERILOG
// Only verilog needs any local variables
reg [47:0] prand_local_seed0;
reg prand_initialized0;
reg prand_no_rollpli0;
`endif
`endif
`endif

function [31:0] prand_inst0;
//VCS coverage off
    input [31:0] min;
    input [31:0] max;
    reg [32:0] diff;
    
    begin
`ifdef SYNTH_LEVEL1_COMPILE
        prand_inst0 = min;
`else
`ifdef SYNTHESIS
        prand_inst0 = min;
`else
`ifdef PRAND_VERILOG
        if (prand_initialized0 !== 1'b1) begin
            prand_no_rollpli0 = $test$plusargs("NO_ROLLPLI");
            if (!prand_no_rollpli0)
                prand_local_seed0 = {$prand_get_seed(0), 16'b0};
            prand_initialized0 = 1'b1;
        end
        if (prand_no_rollpli0) begin
            prand_inst0 = min;
        end else begin
            diff = max - min + 1;
            prand_inst0 = min + prand_local_seed0[47:16] % diff;
            // magic numbers taken from Java's random class (same as lrand48)
            prand_local_seed0 = prand_local_seed0 * 48'h5deece66d + 48'd11;
        end
`else
`ifdef PRAND_OFF
        prand_inst0 = min;
`else
        prand_inst0 = $RollPLI(min, max, "auto");
`endif
`endif
`endif
`endif
    end
//VCS coverage on
endfunction

//| _attach_EndModulePrepend_6;

`ifdef SYNTH_LEVEL1_COMPILE
`else
`ifdef SYNTHESIS
`else
`ifdef PRAND_VERILOG
// Only verilog needs any local variables
reg [47:0] prand_local_seed1;
reg prand_initialized1;
reg prand_no_rollpli1;
`endif
`endif
`endif

function [31:0] prand_inst1;
//VCS coverage off
    input [31:0] min;
    input [31:0] max;
    reg [32:0] diff;
    
    begin
`ifdef SYNTH_LEVEL1_COMPILE
        prand_inst1 = min;
`else
`ifdef SYNTHESIS
        prand_inst1 = min;
`else
`ifdef PRAND_VERILOG
        if (prand_initialized1 !== 1'b1) begin
            prand_no_rollpli1 = $test$plusargs("NO_ROLLPLI");
            if (!prand_no_rollpli1)
                prand_local_seed1 = {$prand_get_seed(1), 16'b0};
            prand_initialized1 = 1'b1;
        end
        if (prand_no_rollpli1) begin
            prand_inst1 = min;
        end else begin
            diff = max - min + 1;
            prand_inst1 = min + prand_local_seed1[47:16] % diff;
            // magic numbers taken from Java's random class (same as lrand48)
            prand_local_seed1 = prand_local_seed1 * 48'h5deece66d + 48'd11;
        end
`else
`ifdef PRAND_OFF
        prand_inst1 = min;
`else
        prand_inst1 = $RollPLI(min, max, "auto");
`endif
`endif
`endif
`endif
    end
//VCS coverage on
endfunction


//| &Perl $VIVA_MODULE = $NV_NVDLA_CDP_DP_data_fifo_80x36_PARENT_VIVA_MODULE;


endmodule // NV_NVDLA_CDP_DP_data_fifo_80x36



//| &Viva pop dangle_checks_off;

//| &Shell ${FIFOGEN} -stdout -m NV_NVDLA_CDP_DP_data_fifo_80x72
//|                 -clk_name   ::eval($VIVA_CLOCK)
//|                 -reset_name ::eval($VIVA_RESET)
//|                 -wr_pipebus data_wr
//|                 -rd_pipebus data_rd
//|                 -rd_reg
//|                 -ram_bypass
//|                 -d ::eval(80)
//|                 -w ::eval(72)
//|                 -ram ra2; 
//| &Depend "../../../../../../../socd/ip_chip_tools/1.0/defs/public/fifogen/golden/tlit6/fifogen.yml";
//
// AUTOMATICALLY GENERATED -- DO NOT EDIT OR CHECK IN
//
// /home/nvtools/engr/2018/04/28_05_00_03/nvtools/scripts/fifogen
// fifogen -input_config_yaml ../../../../../../../socd/ip_chip_tools/1.0/defs/public/fifogen/golden/tlit6/fifogen.yml -no_make_ram -no_make_ram -stdout -m NV_NVDLA_CDP_DP_data_fifo_80x72 -clk_name nvdla_core_clk -reset_name nvdla_core_rstn -wr_pipebus data_wr -rd_pipebus data_rd -rd_reg -ram_bypass -d 80 -w 72 -ram ra2 [Chosen ram type: ra2 - ramgen_generic (user specified, thus no other ram type is allowed)]
// chip config vars: strict_synchronizers=1  strict_synchronizers_use_lib_cells=1  strict_synchronizers_use_tm_lib_cells=1  strict_sync_randomizer=1  assertion_message_prefix=FIFOGEN_ASSERTION  testpoint_message_prefix=FIFOGEN_TESTPOINT  ignore_ramgen_fifola_variant=1  uses_p_SSYNC=0  uses_prand=1  uses_rammake_inc=1  use_x_or_0=1  force_wr_reg_gated=1  no_force_reset=1  no_timescale=1  remove_unused_ports=1  viva_parsed=1  no_pli_ifdef=1  requires_full_throughput=1  ram_auto_ff_bits_cutoff=16  ram_auto_ff_width_cutoff=2  ram_auto_ff_width_cutoff_max_depth=32  ram_auto_ff_depth_cutoff=-1  ram_auto_ff_no_la2_depth_cutoff=5  ram_auto_la2_width_cutoff=8  ram_auto_la2_width_cutoff_max_depth=56  ram_auto_la2_depth_cutoff=16  flopram_emu_model=1  dslp_single_clamp_port=1  dslp_clamp_port=1  slp_single_clamp_port=1  slp_clamp_port=1  master_clk_gated=1  clk_gate_module=NV_CLK_gate_power  redundant_timing_flops=0  hot_reset_async_force_ports_and_loopback=1  ram_sleep_en_width=1  async_cdc_reg_id=NV_AFIFO_  rd_reg_default_for_async=1  async_ram_instance_prefix=NV_ASYNC_RAM_  allow_rd_busy_reg_warning=0  do_dft_xelim_gating=1  add_dft_xelim_wr_clkgate=1  add_dft_xelim_rd_clkgate=1  allow_mt_rttrb_wr_reg=0 
//
// leda B_3208_NV OFF -- Unequal length LHS and RHS in assignment
// leda B_1405 OFF -- 2 asynchronous resets in this unit detected

//| &Viva push dangle_checks_off;

`define FORCE_CONTENTION_ASSERTION_RESET_ACTIVE 1'b1

`ifndef SYNTHESIS
    `define FIFOGEN_KEEP_ASSERTION_VERIF_CODE
`else
    `ifdef FV_ASSERT_ON
        `define FIFOGEN_KEEP_ASSERTION_VERIF_CODE
    `endif
`endif

`include "simulate_x_tick.vh"


module NV_NVDLA_CDP_DP_data_fifo_80x72 (
      nvdla_core_clk
    , nvdla_core_rstn
    , data_wr_prdy
    , data_wr_pvld
`ifdef FV_RAND_WR_PAUSE
    , data_wr_pause
`endif
    , data_wr_pd
    , data_rd_prdy
    , data_rd_pvld
    , data_rd_pd
    , pwrbus_ram_pd
    );

// spyglass disable_block W401 -- clock is not input to module
input         nvdla_core_clk;
input         nvdla_core_rstn;
output        data_wr_prdy;
input         data_wr_pvld;
`ifdef FV_RAND_WR_PAUSE
input         data_wr_pause;
`endif
input  [71:0] data_wr_pd;
input         data_rd_prdy;
output        data_rd_pvld;
output [71:0] data_rd_pd;
input  [31:0] pwrbus_ram_pd;

//| &PerlBeg;
//|     $NV_NVDLA_CDP_DP_data_fifo_80x72_PARENT_VIVA_MODULE = "$VIVA_MODULE";
//|     $VIVA_MODULE = "NV_NVDLA_CDP_DP_data_fifo_80x72";
//| &PerlEnd;


`ifdef FV_RAND_WR_PAUSE
// FV forces this signal to trigger random stalling
wire data_wr_pause = 0;
`endif

// Master Clock Gating (SLCG)
//
// We gate the clock(s) when idle or stalled.
// This allows us to turn off numerous miscellaneous flops
// that don't get gated during synthesis for one reason or another.
//
// We gate write side and read side separately. 
// If the fifo is synchronous, we also gate the ram separately, but if
// -master_clk_gated_unified or -status_reg/-status_logic_reg is specified, 
// then we use one clk gate for write, ram, and read.
//
wire nvdla_core_clk_mgated_enable;   // assigned by code at end of this module
wire nvdla_core_clk_mgated;               // used only in synchronous fifos
NV_CLK_gate_power nvdla_core_clk_mgate( .clk(nvdla_core_clk), .reset_(nvdla_core_rstn), .clk_en(nvdla_core_clk_mgated_enable), .clk_gated(nvdla_core_clk_mgated) );

// 
// WRITE SIDE
//
// VCS coverage off
`ifndef SYNTHESIS
wire wr_pause_rand;  // random stalling
`endif
// VCS coverage on
wire wr_reserving;
reg        data_wr_busy_int;		        	// copy for internal use
assign     data_wr_prdy = !data_wr_busy_int;
assign       wr_reserving = data_wr_pvld && !data_wr_busy_int; // reserving write space?



wire       wr_popping;                          // fwd: write side sees pop?


reg  [6:0] data_wr_count;			// write-side count

wire [6:0] wr_count_next_wr_popping = wr_reserving ? data_wr_count : (data_wr_count - 1'd1); // spyglass disable W164a W484
wire [6:0] wr_count_next_no_wr_popping = wr_reserving ? (data_wr_count + 1'd1) : data_wr_count; // spyglass disable W164a W484
wire [6:0] wr_count_next = wr_popping ? wr_count_next_wr_popping : 
                                               wr_count_next_no_wr_popping;

wire wr_count_next_no_wr_popping_is_80 = ( wr_count_next_no_wr_popping == 7'd80 );
wire wr_count_next_is_80 = wr_popping ? 1'b0 :
                                          wr_count_next_no_wr_popping_is_80;
wire [6:0] wr_limit_muxed;  // muxed with simulation/emulation overrides
wire [6:0] wr_limit_reg = wr_limit_muxed;
`ifdef FV_RAND_WR_PAUSE
                          // VCS coverage off
wire       data_wr_busy_next = wr_count_next_is_80 || // busy next cycle?
                          (wr_limit_reg != 7'd0 &&      // check data_wr_limit if != 0
                           wr_count_next >= wr_limit_reg) || data_wr_pause;
                          // VCS coverage on
`else
                          // VCS coverage off
wire       data_wr_busy_next = wr_count_next_is_80 || // busy next cycle?
                          (wr_limit_reg != 7'd0 &&      // check data_wr_limit if != 0
                           wr_count_next >= wr_limit_reg)  
 // VCS coverage off
 `ifndef SYNTHESIS
 || wr_pause_rand
 `endif
 // VCS coverage on
;
                          // VCS coverage on
`endif
always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_wr_busy_int <=  1'b0;
        data_wr_count <=  7'd0;
    end else begin
	data_wr_busy_int <=  data_wr_busy_next;
	if ( wr_reserving ^ wr_popping ) begin
	    data_wr_count <=  wr_count_next;
        end 
        `ifndef SYNTHESIS
        // VCS coverage off
        else if ( !(wr_reserving ^ wr_popping) ) begin
        end else begin
            data_wr_count <=  {7{`x_or_0}};
        end
        // VCS coverage on
        `endif // SYNTHESIS
    end
end

wire       wr_pushing = wr_reserving;   // data pushed same cycle as data_wr_pvld

//
// RAM
//

reg  [6:0] data_wr_adr;			// current write address
wire [6:0] data_rd_adr_p;		// read address to use for ram
wire [71:0] data_rd_pd_p_byp_ram;		// read data directly out of ram

wire rd_enable;

wire ore;
wire do_bypass;
wire comb_bypass;
wire rd_popping;
wire [31 : 0] pwrbus_ram_pd;

// Adding parameter for fifogen to disable wr/rd contention assertion in ramgen.
// Fifogen handles this by ignoring the data on the ram data out for that cycle.


nv_ram_rwsthp_80x72 #(`FORCE_CONTENTION_ASSERTION_RESET_ACTIVE) ram (
      .clk		 ( nvdla_core_clk )
    , .pwrbus_ram_pd ( pwrbus_ram_pd )
    , .wa        ( data_wr_adr )
    , .we        ( wr_pushing && (data_wr_count != 7'd0 || !rd_popping) )
    , .di        ( data_wr_pd )
    , .ra        ( data_rd_adr_p )
    , .re        ( (do_bypass && wr_pushing) || rd_enable )
    , .dout        ( data_rd_pd_p_byp_ram )
    , .byp_sel        ( comb_bypass )
    , .dbyp        ( data_wr_pd[71:0] )
    , .ore        ( ore )
    );
// next data_wr_adr if wr_pushing=1
wire [6:0] wr_adr_next = (data_wr_adr == 7'd79) ? 7'd0 : (data_wr_adr + 1'd1);  // spyglass disable W484

// spyglass disable_block W484
always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_wr_adr <=  7'd0;
    end else begin
        if ( wr_pushing ) begin
            data_wr_adr      <=  wr_adr_next;
        end 
        `ifndef SYNTHESIS
        // VCS coverage off
        else if ( !(wr_pushing) ) begin
        end else begin
            data_wr_adr   <=  {7{`x_or_0}};
        end
        // VCS coverage on
        `endif // SYNTHESIS
    end 
end
// spyglass enable_block W484

reg  [6:0] data_rd_adr;		// current read address
// next    read address
wire [6:0] rd_adr_next = (data_rd_adr == 7'd79) ? 7'd0 : (data_rd_adr + 1'd1);   // spyglass disable W484
assign         data_rd_adr_p = rd_popping ? rd_adr_next : data_rd_adr; // for ram

// spyglass disable_block W484
always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_rd_adr <=  7'd0;
    end else begin
        if ( rd_popping ) begin
	    data_rd_adr      <=  rd_adr_next;
        end 
        `ifndef SYNTHESIS
        // VCS coverage off
        else if ( !rd_popping ) begin
        end else begin
            data_rd_adr <=  {7{`x_or_0}};
        end
        // VCS coverage on
        `endif // SYNTHESIS
    end
end
// spyglass enable_block W484

assign do_bypass = (rd_popping ? (data_wr_adr == rd_adr_next) : (data_wr_adr == data_rd_adr));
wire [71:0] data_rd_pd_p_byp = data_rd_pd_p_byp_ram;


//
// Combinatorial Bypass
//
// If we're pushing an empty fifo, mux the wr_data directly.
//
assign comb_bypass = data_wr_count == 0;
wire [71:0] data_rd_pd_p = data_rd_pd_p_byp;



//
// SYNCHRONOUS BOUNDARY
//


assign wr_popping = rd_popping;		// let it be seen immediately


wire   rd_pushing = wr_pushing;		// let it be seen immediately

//
// READ SIDE
//

wire       data_rd_pvld_p; 		// data out of fifo is valid

reg        data_rd_pvld_int;	// internal copy of data_rd_pvld
assign     data_rd_pvld = data_rd_pvld_int;
assign     rd_popping = data_rd_pvld_p && !(data_rd_pvld_int && !data_rd_prdy);

reg  [6:0] data_rd_count_p;			// read-side fifo count
// spyglass disable_block W164a W484
wire [6:0] rd_count_p_next_rd_popping = rd_pushing ? data_rd_count_p : 
                                                                (data_rd_count_p - 1'd1);
wire [6:0] rd_count_p_next_no_rd_popping =  rd_pushing ? (data_rd_count_p + 1'd1) : 
                                                                    data_rd_count_p;
// spyglass enable_block W164a W484
wire [6:0] rd_count_p_next = rd_popping ? rd_count_p_next_rd_popping :
                                                     rd_count_p_next_no_rd_popping; 
wire rd_count_p_next_rd_popping_not_0 = rd_count_p_next_rd_popping != 0;
wire rd_count_p_next_no_rd_popping_not_0 = rd_count_p_next_no_rd_popping != 0;
wire rd_count_p_next_not_0 = rd_popping ? rd_count_p_next_rd_popping_not_0 :
                                              rd_count_p_next_no_rd_popping_not_0;
assign     data_rd_pvld_p = data_rd_count_p != 0 || rd_pushing;
assign rd_enable = ((rd_count_p_next_not_0) && ((~data_rd_pvld_p) || rd_popping));  // anytime data's there and not stalled
always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_rd_count_p <=  7'd0;
    end else begin
        if ( rd_pushing || rd_popping  ) begin
	    data_rd_count_p <=  rd_count_p_next;
        end 
        `ifndef SYNTHESIS
        // VCS coverage off
        else if ( !(rd_pushing || rd_popping ) ) begin
        end else begin
            data_rd_count_p <=  {7{`x_or_0}};
        end
        // VCS coverage on
        `endif // SYNTHESIS
    end
end
wire        rd_req_next = (data_rd_pvld_p || (data_rd_pvld_int && !data_rd_prdy)) ;

always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        data_rd_pvld_int <=  1'b0;
    end else begin
        data_rd_pvld_int <=  rd_req_next;
    end
end
assign data_rd_pd = data_rd_pd_p;
assign ore = rd_popping;

// Master Clock Gating (SLCG) Enables
//

// plusarg for disabling this stuff:

// VCS coverage off
`ifndef SYNTHESIS
reg master_clk_gating_disabled;  initial master_clk_gating_disabled = $test$plusargs( "fifogen_disable_master_clk_gating" ) != 0;
`endif
// VCS coverage on

// VCS coverage off
`ifndef SYNTHESIS
reg wr_pause_rand_dly;  
always @( posedge nvdla_core_clk or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        wr_pause_rand_dly <=  1'b0;
    end else begin
        wr_pause_rand_dly <=  wr_pause_rand;
    end
end
`endif
// VCS coverage on
assign nvdla_core_clk_mgated_enable = ((wr_reserving || wr_pushing || wr_popping || (data_wr_pvld && !data_wr_busy_int) || (data_wr_busy_int != data_wr_busy_next)) || (rd_pushing || rd_popping || (data_rd_pvld_int && data_rd_prdy)))
                               `ifdef FIFOGEN_MASTER_CLK_GATING_DISABLED
                               || 1'b1
                               `endif
                               // VCS coverage off
                               `ifndef SYNTHESIS
                               || master_clk_gating_disabled || (wr_pause_rand != wr_pause_rand_dly)
                               `endif
                               // VCS coverage on
;


// Simulation and Emulation Overrides of wr_limit(s)
//

`ifdef EMU

`ifdef EMU_FIFO_CFG
// Emulation Global Config Override
//
assign wr_limit_muxed = `EMU_FIFO_CFG.NV_NVDLA_CDP_DP_data_fifo_80x72_wr_limit_override ? `EMU_FIFO_CFG.NV_NVDLA_CDP_DP_data_fifo_80x72_wr_limit : 7'd0;
`else
// No Global Override for Emulation 
//
assign wr_limit_muxed = 7'd0;
`endif // EMU_FIFO_CFG

`else // !EMU
`ifdef SYNTHESIS

// No Override for RTL Synthesis
//

assign wr_limit_muxed = 7'd0;

`else  

// RTL Simulation Plusarg Override


// VCS coverage off

reg wr_limit_override;
reg [6:0] wr_limit_override_value; 
assign wr_limit_muxed = wr_limit_override ? wr_limit_override_value : 7'd0;
`ifdef NV_ARCHPRO
event reinit;

initial begin
    $display("fifogen reinit initial block %m");
    -> reinit;
end
`endif

`ifdef NV_ARCHPRO
always @( reinit ) begin
`else 
initial begin
`endif
    wr_limit_override = 0;
    wr_limit_override_value = 0;  // to keep viva happy with dangles
    if ( $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x72_wr_limit" ) ) begin
        wr_limit_override = 1;
        $value$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x72_wr_limit=%d", wr_limit_override_value);
    end
end

// VCS coverage on


`endif
`endif


// Random Write-Side Stalling
// VCS coverage off
`ifndef SYNTHESIS
// VCS coverage off

// leda W339 OFF -- Non synthesizable operator
// leda W372 OFF -- Undefined PLI task
// leda W373 OFF -- Undefined PLI function
// leda W599 OFF -- This construct is not supported by Synopsys
// leda W430 OFF -- Initial statement is not synthesizable
// leda W182 OFF -- Illegal statement for synthesis
// leda W639 OFF -- For synthesis, operands of a division or modulo operation need to be constants
// leda DCVER_274_NV OFF -- This system task is not supported by DC

integer stall_probability;      // prob of stalling
integer stall_cycles_min;       // min cycles to stall
integer stall_cycles_max;       // max cycles to stall
integer stall_cycles_left;      // stall cycles left
`ifdef NV_ARCHPRO
always @( reinit ) begin
`else 
initial begin
`endif
    stall_probability      = 0; // no stalling by default
    stall_cycles_min       = 1;
    stall_cycles_max       = 10;

`ifdef NO_PLI
`else
    if ( $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x72_fifo_stall_probability" ) ) begin
        $value$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x72_fifo_stall_probability=%d", stall_probability);
    end else if ( $test$plusargs( "default_fifo_stall_probability" ) ) begin
        $value$plusargs( "default_fifo_stall_probability=%d", stall_probability);
    end

    if ( $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x72_fifo_stall_cycles_min" ) ) begin
        $value$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x72_fifo_stall_cycles_min=%d", stall_cycles_min);
    end else if ( $test$plusargs( "default_fifo_stall_cycles_min" ) ) begin
        $value$plusargs( "default_fifo_stall_cycles_min=%d", stall_cycles_min);
    end

    if ( $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x72_fifo_stall_cycles_max" ) ) begin
        $value$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x72_fifo_stall_cycles_max=%d", stall_cycles_max);
    end else if ( $test$plusargs( "default_fifo_stall_cycles_max" ) ) begin
        $value$plusargs( "default_fifo_stall_cycles_max=%d", stall_cycles_max);
    end
`endif

    if ( stall_cycles_min < 1 ) begin
        stall_cycles_min = 1;
    end

    if ( stall_cycles_min > stall_cycles_max ) begin
        stall_cycles_max = stall_cycles_min;
    end

end

`ifdef NO_PLI
`else

// randomization globals
`ifdef SIMTOP_RANDOMIZE_STALLS
  always @( `SIMTOP_RANDOMIZE_STALLS.global_stall_event ) begin
    if ( ! $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x72_fifo_stall_probability" ) ) stall_probability = `SIMTOP_RANDOMIZE_STALLS.global_stall_fifo_probability; 
    if ( ! $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x72_fifo_stall_cycles_min"  ) ) stall_cycles_min  = `SIMTOP_RANDOMIZE_STALLS.global_stall_fifo_cycles_min;
    if ( ! $test$plusargs( "NV_NVDLA_CDP_DP_data_fifo_80x72_fifo_stall_cycles_max"  ) ) stall_cycles_max  = `SIMTOP_RANDOMIZE_STALLS.global_stall_fifo_cycles_max;
  end
`endif

`endif

always @( negedge nvdla_core_clk or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        stall_cycles_left <=  0;
    end else begin
`ifdef NO_PLI
            stall_cycles_left <=  0;
`else
            if ( data_wr_pvld && !(!data_wr_prdy)
                 && stall_probability != 0 ) begin
                if ( prand_inst0(1, 100) <= stall_probability ) begin
                    stall_cycles_left <=  prand_inst1(stall_cycles_min, stall_cycles_max);
                end else if ( stall_cycles_left !== 0  ) begin
                    stall_cycles_left <=  stall_cycles_left - 1;
                end
            end else if ( stall_cycles_left !== 0  ) begin
                stall_cycles_left <=  stall_cycles_left - 1;
            end
`endif
    end
end

assign wr_pause_rand = (stall_cycles_left !== 0) ;

// VCS coverage on
`endif
// VCS coverage on

// leda W339 ON
// leda W372 ON
// leda W373 ON
// leda W599 ON
// leda W430 ON
// leda W182 ON
// leda W639 ON
// leda DCVER_274_NV ON


//
// Histogram of fifo depth (from write side's perspective)
//
// NOTE: it will reference `SIMTOP.perfmon_enabled, so that
//       has to at least be defined, though not initialized.
//	 tbgen testbenches have it already and various
//	 ways to turn it on and off.
//
`ifdef PERFMON_HISTOGRAM 
// VCS coverage off
`ifndef SYNTHESIS
perfmon_histogram perfmon (
      .clk	( nvdla_core_clk ) 
    , .max      ( {25'd0, (wr_limit_reg == 7'd0) ? 7'd80 : wr_limit_reg} )
    , .curr	( {25'd0, data_wr_count} )
    );
`endif
// VCS coverage on
`endif

// spyglass disable_block W164a W164b W116 W484 W504

`ifdef SPYGLASS
`else

`ifdef FIFOGEN_KEEP_ASSERTION_VERIF_CODE
// VCS coverage off
`ifdef ASSERT_ON



`ifdef SPYGLASS
wire disable_assert_plusarg = 1'b0;
`else

`ifdef FV_ASSERT_ON
wire disable_assert_plusarg = 1'b0;
`else
wire disable_assert_plusarg = |($test$plusargs("DISABLE_NESS_FLOW_ASSERTIONS"));
`endif // ifdef FV_ASSERT_ON

`endif // ifdef SPYGLASS


wire assert_enabled = 1'b1 && !disable_assert_plusarg;


`endif // ifdef ASSERT_ON
// VCS coverage on
`endif // ifdef FIFOGEN_KEEP_ASSERTION_VERIF_CODE


`ifdef ASSERT_ON

// VCS coverage off
`ifndef SYNTHESIS
always @(assert_enabled) begin
    if ( assert_enabled === 1'b0 ) begin
        $display("Asserts are disabled for %m");
    end
end
`endif
// VCS coverage on

`endif

`endif

// spyglass enable_block W164a W164b W116 W484 W504


//| &Viva push ifdef_ignore_on;

`ifdef COVER

wire wr_testpoint_reset_ = ( nvdla_core_rstn === 1'bx ? 1'b0 : nvdla_core_rstn );


//| ::testpoint -autogen true -name "FIFOGEN_TESTPOINT Fifo Full" -clk nvdla_core_clk -reset wr_testpoint_reset_ data_wr_count==80;
//| &Force internal /^testpoint_/;

`ifndef DISABLE_TESTPOINTS
  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER
  `endif // COVER

  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER
  `endif // COVER

  `ifdef TP__FIFOGEN_TESTPOINT_Fifo_Full
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER
  `endif // TP__FIFOGEN_TESTPOINT_Fifo_Full

`ifdef COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER


`define NV_TESTPOINT_COVERAGE_GUARD_NV_NVDLA_CDP_DP_data_fifo_80x72
//VCS coverage off
    // TESTPOINT_START
    // NAME="FIFOGEN_TESTPOINT Fifo Full"
    // TYPE=OCCURRENCE
    // AUTOGEN=true
    // COUNT=1
    // GROUP="DEFAULT"
    // INFO=""
    // RANDOM_COVER=true
    // ASYNC_RESET=1
    // ACTIVE_HIGH_RESET=0
wire testpoint_12_internal_nvdla_core_clk   = nvdla_core_clk;
wire testpoint_12_internal_wr_testpoint_reset_ = wr_testpoint_reset_;

`ifdef FV_COVER_ON
    // Synthesizable code for SFV.
    wire testpoint_got_reset_testpoint_12_internal_wr_testpoint_reset__with_clock_testpoint_12_internal_nvdla_core_clk = 1'b1;
`else
    // Must be clocked with reset active before we start gathering
    // coverage.
    //  Reset signal: testpoint_12_internal_wr_testpoint_reset_
    //  Clock signal: testpoint_12_internal_nvdla_core_clk
    reg testpoint_got_reset_testpoint_12_internal_wr_testpoint_reset__with_clock_testpoint_12_internal_nvdla_core_clk;

    initial
        testpoint_got_reset_testpoint_12_internal_wr_testpoint_reset__with_clock_testpoint_12_internal_nvdla_core_clk <= 1'b0;

    always @(posedge testpoint_12_internal_nvdla_core_clk or negedge testpoint_12_internal_wr_testpoint_reset_) begin: HAS_RETENTION_TESTPOINT_RESET_12
        if (~testpoint_12_internal_wr_testpoint_reset_)
            testpoint_got_reset_testpoint_12_internal_wr_testpoint_reset__with_clock_testpoint_12_internal_nvdla_core_clk <= 1'b1;
    end
`endif

`ifndef LINE_TESTPOINTS_OFF
    reg testpoint_12_count_0;

    reg testpoint_12_goal_0;
    initial testpoint_12_goal_0 = 0;
    initial testpoint_12_count_0 = 0;
    always@(testpoint_12_count_0) begin
        if(testpoint_12_count_0 >= 1)
         begin
 `ifdef COVER_PRINT_TESTPOINT_HITS
            if (testpoint_12_goal_0 != 1'b1)
                $display("TESTPOINT_HIT: NV_NVDLA_CDP_DP_data_fifo_80x72 ::: FIFOGEN_TESTPOINT Fifo Full ::: data_wr_count==80");
 `endif
            //VCS coverage on
            //coverage name NV_NVDLA_CDP_DP_data_fifo_80x72 ::: FIFOGEN_TESTPOINT Fifo Full ::: testpoint_12_goal_0
            testpoint_12_goal_0 = 1'b1;
            //VCS coverage off
        end
        else
            testpoint_12_goal_0 = 1'b0;
    end

    // Increment counters for every condition that's true this clock.
    always @(posedge testpoint_12_internal_nvdla_core_clk) begin: HAS_RETENTION_TESTPOINT_GOAL_12
        if (testpoint_12_internal_wr_testpoint_reset_) begin
 `ifdef ASSOCIATE_TESTPOINT_NAME_GOAL_NUMBER
            if ((data_wr_count==80) && testpoint_got_reset_testpoint_12_internal_wr_testpoint_reset__with_clock_testpoint_12_internal_nvdla_core_clk)
                $display("NVIDIA TESTPOINT: NV_NVDLA_CDP_DP_data_fifo_80x72 ::: FIFOGEN_TESTPOINT Fifo Full ::: testpoint_12_goal_0");
 `endif
            if ((data_wr_count==80) && testpoint_got_reset_testpoint_12_internal_wr_testpoint_reset__with_clock_testpoint_12_internal_nvdla_core_clk)
                testpoint_12_count_0 <= 1'd1;
        end
        else begin
 `ifndef FV_COVER_ON
            if (!testpoint_got_reset_testpoint_12_internal_wr_testpoint_reset__with_clock_testpoint_12_internal_nvdla_core_clk) begin
 `endif
                testpoint_12_count_0 <= 1'd0;
 `ifndef FV_COVER_ON
            end
 `endif
        end
    end
`endif // LINE_TESTPOINTS_OFF

`ifndef SV_TESTPOINTS_OFF
    wire testpoint_12_goal_0_active = ((data_wr_count==80) && testpoint_got_reset_testpoint_12_internal_wr_testpoint_reset__with_clock_testpoint_12_internal_nvdla_core_clk);

    // system verilog testpoints, to leverage vcs testpoint coverage tools
 `ifndef SV_TESTPOINTS_DESCRIPTIVE
    system_verilog_testpoint svt_testpoint_12_goal_0 (.clk (testpoint_12_internal_nvdla_core_clk), .tp(testpoint_12_goal_0_active));
 `else
    system_verilog_testpoint svt_FIFOGEN_TESTPOINT_Fifo_Full_0 (.clk (testpoint_12_internal_nvdla_core_clk), .tp(testpoint_12_goal_0_active));
 `endif
`endif

    //VCS coverage on
`endif //COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_OR_COVER
`endif //  DISABLE_TESTPOINTS

    // TESTPOINT_END
//| ::testpoint -autogen true -name "FIFOGEN_TESTPOINT Fifo Full and wr_req" -clk nvdla_core_clk -reset wr_testpoint_reset_ data_wr_count==80 && data_wr_pvld;
`ifndef DISABLE_TESTPOINTS
  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER
  `endif // COVER

  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER
  `endif // COVER

  `ifdef TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER
  `endif // TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req

`ifdef COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER


`define NV_TESTPOINT_COVERAGE_GUARD_NV_NVDLA_CDP_DP_data_fifo_80x72
//VCS coverage off
    // TESTPOINT_START
    // NAME="FIFOGEN_TESTPOINT Fifo Full and wr_req"
    // TYPE=OCCURRENCE
    // AUTOGEN=true
    // COUNT=1
    // GROUP="DEFAULT"
    // INFO=""
    // RANDOM_COVER=true
    // ASYNC_RESET=1
    // ACTIVE_HIGH_RESET=0
wire testpoint_13_internal_nvdla_core_clk   = nvdla_core_clk;
wire testpoint_13_internal_wr_testpoint_reset_ = wr_testpoint_reset_;

`ifdef FV_COVER_ON
    // Synthesizable code for SFV.
    wire testpoint_got_reset_testpoint_13_internal_wr_testpoint_reset__with_clock_testpoint_13_internal_nvdla_core_clk = 1'b1;
`else
    // Must be clocked with reset active before we start gathering
    // coverage.
    //  Reset signal: testpoint_13_internal_wr_testpoint_reset_
    //  Clock signal: testpoint_13_internal_nvdla_core_clk
    reg testpoint_got_reset_testpoint_13_internal_wr_testpoint_reset__with_clock_testpoint_13_internal_nvdla_core_clk;

    initial
        testpoint_got_reset_testpoint_13_internal_wr_testpoint_reset__with_clock_testpoint_13_internal_nvdla_core_clk <= 1'b0;

    always @(posedge testpoint_13_internal_nvdla_core_clk or negedge testpoint_13_internal_wr_testpoint_reset_) begin: HAS_RETENTION_TESTPOINT_RESET_13
        if (~testpoint_13_internal_wr_testpoint_reset_)
            testpoint_got_reset_testpoint_13_internal_wr_testpoint_reset__with_clock_testpoint_13_internal_nvdla_core_clk <= 1'b1;
    end
`endif

`ifndef LINE_TESTPOINTS_OFF
    reg testpoint_13_count_0;

    reg testpoint_13_goal_0;
    initial testpoint_13_goal_0 = 0;
    initial testpoint_13_count_0 = 0;
    always@(testpoint_13_count_0) begin
        if(testpoint_13_count_0 >= 1)
         begin
 `ifdef COVER_PRINT_TESTPOINT_HITS
            if (testpoint_13_goal_0 != 1'b1)
                $display("TESTPOINT_HIT: NV_NVDLA_CDP_DP_data_fifo_80x72 ::: FIFOGEN_TESTPOINT Fifo Full and wr_req ::: data_wr_count==80 && data_wr_pvld");
 `endif
            //VCS coverage on
            //coverage name NV_NVDLA_CDP_DP_data_fifo_80x72 ::: FIFOGEN_TESTPOINT Fifo Full and wr_req ::: testpoint_13_goal_0
            testpoint_13_goal_0 = 1'b1;
            //VCS coverage off
        end
        else
            testpoint_13_goal_0 = 1'b0;
    end

    // Increment counters for every condition that's true this clock.
    always @(posedge testpoint_13_internal_nvdla_core_clk) begin: HAS_RETENTION_TESTPOINT_GOAL_13
        if (testpoint_13_internal_wr_testpoint_reset_) begin
 `ifdef ASSOCIATE_TESTPOINT_NAME_GOAL_NUMBER
            if ((data_wr_count==80 && data_wr_pvld) && testpoint_got_reset_testpoint_13_internal_wr_testpoint_reset__with_clock_testpoint_13_internal_nvdla_core_clk)
                $display("NVIDIA TESTPOINT: NV_NVDLA_CDP_DP_data_fifo_80x72 ::: FIFOGEN_TESTPOINT Fifo Full and wr_req ::: testpoint_13_goal_0");
 `endif
            if ((data_wr_count==80 && data_wr_pvld) && testpoint_got_reset_testpoint_13_internal_wr_testpoint_reset__with_clock_testpoint_13_internal_nvdla_core_clk)
                testpoint_13_count_0 <= 1'd1;
        end
        else begin
 `ifndef FV_COVER_ON
            if (!testpoint_got_reset_testpoint_13_internal_wr_testpoint_reset__with_clock_testpoint_13_internal_nvdla_core_clk) begin
 `endif
                testpoint_13_count_0 <= 1'd0;
 `ifndef FV_COVER_ON
            end
 `endif
        end
    end
`endif // LINE_TESTPOINTS_OFF

`ifndef SV_TESTPOINTS_OFF
    wire testpoint_13_goal_0_active = ((data_wr_count==80 && data_wr_pvld) && testpoint_got_reset_testpoint_13_internal_wr_testpoint_reset__with_clock_testpoint_13_internal_nvdla_core_clk);

    // system verilog testpoints, to leverage vcs testpoint coverage tools
 `ifndef SV_TESTPOINTS_DESCRIPTIVE
    system_verilog_testpoint svt_testpoint_13_goal_0 (.clk (testpoint_13_internal_nvdla_core_clk), .tp(testpoint_13_goal_0_active));
 `else
    system_verilog_testpoint svt_FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_0 (.clk (testpoint_13_internal_nvdla_core_clk), .tp(testpoint_13_goal_0_active));
 `endif
`endif

    //VCS coverage on
`endif //COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_Full_and_wr_req_OR_COVER
`endif //  DISABLE_TESTPOINTS

    // TESTPOINT_END


wire rd_testpoint_reset_ = ( nvdla_core_rstn === 1'bx ? 1'b0 : nvdla_core_rstn );


//| ::testpoint -autogen true -name "Fifo not empty and rd_busy" -clk nvdla_core_clk -reset rd_testpoint_reset_ data_rd_pvld && !data_rd_prdy;
`ifndef DISABLE_TESTPOINTS
  `ifdef COVER
    `define COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER
  `endif // COVER

  `ifdef COVER
    `define COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER
  `endif // COVER

  `ifdef TP__Fifo_not_empty_and_rd_busy
    `define COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER
  `endif // TP__Fifo_not_empty_and_rd_busy

`ifdef COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER


`define NV_TESTPOINT_COVERAGE_GUARD_NV_NVDLA_CDP_DP_data_fifo_80x72
//VCS coverage off
    // TESTPOINT_START
    // NAME="Fifo not empty and rd_busy"
    // TYPE=OCCURRENCE
    // AUTOGEN=true
    // COUNT=1
    // GROUP="DEFAULT"
    // INFO=""
    // RANDOM_COVER=true
    // ASYNC_RESET=1
    // ACTIVE_HIGH_RESET=0
wire testpoint_14_internal_nvdla_core_clk   = nvdla_core_clk;
wire testpoint_14_internal_rd_testpoint_reset_ = rd_testpoint_reset_;

`ifdef FV_COVER_ON
    // Synthesizable code for SFV.
    wire testpoint_got_reset_testpoint_14_internal_rd_testpoint_reset__with_clock_testpoint_14_internal_nvdla_core_clk = 1'b1;
`else
    // Must be clocked with reset active before we start gathering
    // coverage.
    //  Reset signal: testpoint_14_internal_rd_testpoint_reset_
    //  Clock signal: testpoint_14_internal_nvdla_core_clk
    reg testpoint_got_reset_testpoint_14_internal_rd_testpoint_reset__with_clock_testpoint_14_internal_nvdla_core_clk;

    initial
        testpoint_got_reset_testpoint_14_internal_rd_testpoint_reset__with_clock_testpoint_14_internal_nvdla_core_clk <= 1'b0;

    always @(posedge testpoint_14_internal_nvdla_core_clk or negedge testpoint_14_internal_rd_testpoint_reset_) begin: HAS_RETENTION_TESTPOINT_RESET_14
        if (~testpoint_14_internal_rd_testpoint_reset_)
            testpoint_got_reset_testpoint_14_internal_rd_testpoint_reset__with_clock_testpoint_14_internal_nvdla_core_clk <= 1'b1;
    end
`endif

`ifndef LINE_TESTPOINTS_OFF
    reg testpoint_14_count_0;

    reg testpoint_14_goal_0;
    initial testpoint_14_goal_0 = 0;
    initial testpoint_14_count_0 = 0;
    always@(testpoint_14_count_0) begin
        if(testpoint_14_count_0 >= 1)
         begin
 `ifdef COVER_PRINT_TESTPOINT_HITS
            if (testpoint_14_goal_0 != 1'b1)
                $display("TESTPOINT_HIT: NV_NVDLA_CDP_DP_data_fifo_80x72 ::: Fifo not empty and rd_busy ::: data_rd_pvld && !data_rd_prdy");
 `endif
            //VCS coverage on
            //coverage name NV_NVDLA_CDP_DP_data_fifo_80x72 ::: Fifo not empty and rd_busy ::: testpoint_14_goal_0
            testpoint_14_goal_0 = 1'b1;
            //VCS coverage off
        end
        else
            testpoint_14_goal_0 = 1'b0;
    end

    // Increment counters for every condition that's true this clock.
    always @(posedge testpoint_14_internal_nvdla_core_clk) begin: HAS_RETENTION_TESTPOINT_GOAL_14
        if (testpoint_14_internal_rd_testpoint_reset_) begin
 `ifdef ASSOCIATE_TESTPOINT_NAME_GOAL_NUMBER
            if ((data_rd_pvld && !data_rd_prdy) && testpoint_got_reset_testpoint_14_internal_rd_testpoint_reset__with_clock_testpoint_14_internal_nvdla_core_clk)
                $display("NVIDIA TESTPOINT: NV_NVDLA_CDP_DP_data_fifo_80x72 ::: Fifo not empty and rd_busy ::: testpoint_14_goal_0");
 `endif
            if ((data_rd_pvld && !data_rd_prdy) && testpoint_got_reset_testpoint_14_internal_rd_testpoint_reset__with_clock_testpoint_14_internal_nvdla_core_clk)
                testpoint_14_count_0 <= 1'd1;
        end
        else begin
 `ifndef FV_COVER_ON
            if (!testpoint_got_reset_testpoint_14_internal_rd_testpoint_reset__with_clock_testpoint_14_internal_nvdla_core_clk) begin
 `endif
                testpoint_14_count_0 <= 1'd0;
 `ifndef FV_COVER_ON
            end
 `endif
        end
    end
`endif // LINE_TESTPOINTS_OFF

`ifndef SV_TESTPOINTS_OFF
    wire testpoint_14_goal_0_active = ((data_rd_pvld && !data_rd_prdy) && testpoint_got_reset_testpoint_14_internal_rd_testpoint_reset__with_clock_testpoint_14_internal_nvdla_core_clk);

    // system verilog testpoints, to leverage vcs testpoint coverage tools
 `ifndef SV_TESTPOINTS_DESCRIPTIVE
    system_verilog_testpoint svt_testpoint_14_goal_0 (.clk (testpoint_14_internal_nvdla_core_clk), .tp(testpoint_14_goal_0_active));
 `else
    system_verilog_testpoint svt_Fifo_not_empty_and_rd_busy_0 (.clk (testpoint_14_internal_nvdla_core_clk), .tp(testpoint_14_goal_0_active));
 `endif
`endif

    //VCS coverage on
`endif //COVER_OR_TP__Fifo_not_empty_and_rd_busy_OR_COVER
`endif //  DISABLE_TESTPOINTS

    // TESTPOINT_END

reg [1:0] testpoint_empty_state;
reg [1:0] testpoint_empty_state_nxt;
reg testpoint_non_empty_to_empty_to_non_empty_reached;

`define FIFO_INIT 2'b00
`define FIFO_NON_EMPTY 2'b01
`define FIFO_EMPTY 2'b10

always @(testpoint_empty_state or (!data_rd_pvld)) begin
    testpoint_empty_state_nxt = testpoint_empty_state;
    testpoint_non_empty_to_empty_to_non_empty_reached = 0;
    casez (testpoint_empty_state)
         `FIFO_INIT: begin
             if (!(!data_rd_pvld)) begin
                 testpoint_empty_state_nxt = `FIFO_NON_EMPTY;
             end
         end
         `FIFO_NON_EMPTY: begin
             if ((!data_rd_pvld)) begin
                 testpoint_empty_state_nxt = `FIFO_EMPTY;
             end
         end
         `FIFO_EMPTY: begin
             if (!(!data_rd_pvld)) begin
                 testpoint_non_empty_to_empty_to_non_empty_reached = 1;
                 testpoint_empty_state_nxt = `FIFO_NON_EMPTY;
             end
         end
         // VCS coverage off
         default: begin
             testpoint_empty_state_nxt = `FIFO_INIT;
         end
         // VCS coverage on
    endcase
end
always @( posedge nvdla_core_clk or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        testpoint_empty_state <=  2'b00;
    end else begin
         if (testpoint_empty_state != testpoint_empty_state_nxt) begin
             testpoint_empty_state <= testpoint_empty_state_nxt;
         end
     end
end

//| ::testpoint -autogen true -name "FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty" -clk nvdla_core_clk -reset rd_testpoint_reset_ testpoint_non_empty_to_empty_to_non_empty_reached; 
`ifndef DISABLE_TESTPOINTS
  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER
  `endif // COVER

  `ifdef COVER
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER
  `endif // COVER

  `ifdef TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty
    `define COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER
  `endif // TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty

`ifdef COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER


`define NV_TESTPOINT_COVERAGE_GUARD_NV_NVDLA_CDP_DP_data_fifo_80x72
//VCS coverage off
    // TESTPOINT_START
    // NAME="FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty"
    // TYPE=OCCURRENCE
    // AUTOGEN=true
    // COUNT=1
    // GROUP="DEFAULT"
    // INFO=""
    // RANDOM_COVER=true
    // ASYNC_RESET=1
    // ACTIVE_HIGH_RESET=0
wire testpoint_15_internal_nvdla_core_clk   = nvdla_core_clk;
wire testpoint_15_internal_rd_testpoint_reset_ = rd_testpoint_reset_;

`ifdef FV_COVER_ON
    // Synthesizable code for SFV.
    wire testpoint_got_reset_testpoint_15_internal_rd_testpoint_reset__with_clock_testpoint_15_internal_nvdla_core_clk = 1'b1;
`else
    // Must be clocked with reset active before we start gathering
    // coverage.
    //  Reset signal: testpoint_15_internal_rd_testpoint_reset_
    //  Clock signal: testpoint_15_internal_nvdla_core_clk
    reg testpoint_got_reset_testpoint_15_internal_rd_testpoint_reset__with_clock_testpoint_15_internal_nvdla_core_clk;

    initial
        testpoint_got_reset_testpoint_15_internal_rd_testpoint_reset__with_clock_testpoint_15_internal_nvdla_core_clk <= 1'b0;

    always @(posedge testpoint_15_internal_nvdla_core_clk or negedge testpoint_15_internal_rd_testpoint_reset_) begin: HAS_RETENTION_TESTPOINT_RESET_15
        if (~testpoint_15_internal_rd_testpoint_reset_)
            testpoint_got_reset_testpoint_15_internal_rd_testpoint_reset__with_clock_testpoint_15_internal_nvdla_core_clk <= 1'b1;
    end
`endif

`ifndef LINE_TESTPOINTS_OFF
    reg testpoint_15_count_0;

    reg testpoint_15_goal_0;
    initial testpoint_15_goal_0 = 0;
    initial testpoint_15_count_0 = 0;
    always@(testpoint_15_count_0) begin
        if(testpoint_15_count_0 >= 1)
         begin
 `ifdef COVER_PRINT_TESTPOINT_HITS
            if (testpoint_15_goal_0 != 1'b1)
                $display("TESTPOINT_HIT: NV_NVDLA_CDP_DP_data_fifo_80x72 ::: FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty ::: testpoint_non_empty_to_empty_to_non_empty_reached");
 `endif
            //VCS coverage on
            //coverage name NV_NVDLA_CDP_DP_data_fifo_80x72 ::: FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty ::: testpoint_15_goal_0
            testpoint_15_goal_0 = 1'b1;
            //VCS coverage off
        end
        else
            testpoint_15_goal_0 = 1'b0;
    end

    // Increment counters for every condition that's true this clock.
    always @(posedge testpoint_15_internal_nvdla_core_clk) begin: HAS_RETENTION_TESTPOINT_GOAL_15
        if (testpoint_15_internal_rd_testpoint_reset_) begin
 `ifdef ASSOCIATE_TESTPOINT_NAME_GOAL_NUMBER
            if ((testpoint_non_empty_to_empty_to_non_empty_reached) && testpoint_got_reset_testpoint_15_internal_rd_testpoint_reset__with_clock_testpoint_15_internal_nvdla_core_clk)
                $display("NVIDIA TESTPOINT: NV_NVDLA_CDP_DP_data_fifo_80x72 ::: FIFOGEN_TESTPOINT Fifo non-empty to empty to non-empty ::: testpoint_15_goal_0");
 `endif
            if ((testpoint_non_empty_to_empty_to_non_empty_reached) && testpoint_got_reset_testpoint_15_internal_rd_testpoint_reset__with_clock_testpoint_15_internal_nvdla_core_clk)
                testpoint_15_count_0 <= 1'd1;
        end
        else begin
 `ifndef FV_COVER_ON
            if (!testpoint_got_reset_testpoint_15_internal_rd_testpoint_reset__with_clock_testpoint_15_internal_nvdla_core_clk) begin
 `endif
                testpoint_15_count_0 <= 1'd0;
 `ifndef FV_COVER_ON
            end
 `endif
        end
    end
`endif // LINE_TESTPOINTS_OFF

`ifndef SV_TESTPOINTS_OFF
    wire testpoint_15_goal_0_active = ((testpoint_non_empty_to_empty_to_non_empty_reached) && testpoint_got_reset_testpoint_15_internal_rd_testpoint_reset__with_clock_testpoint_15_internal_nvdla_core_clk);

    // system verilog testpoints, to leverage vcs testpoint coverage tools
 `ifndef SV_TESTPOINTS_DESCRIPTIVE
    system_verilog_testpoint svt_testpoint_15_goal_0 (.clk (testpoint_15_internal_nvdla_core_clk), .tp(testpoint_15_goal_0_active));
 `else
    system_verilog_testpoint svt_FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_0 (.clk (testpoint_15_internal_nvdla_core_clk), .tp(testpoint_15_goal_0_active));
 `endif
`endif

    //VCS coverage on
`endif //COVER_OR_TP__FIFOGEN_TESTPOINT_Fifo_non_empty_to_empty_to_non_empty_OR_COVER
`endif //  DISABLE_TESTPOINTS

    // TESTPOINT_END


`endif

//| &Viva pop ifdef_ignore_on;


//The NV_BLKBOX_SRC0 module is only present when the FIFOGEN_MODULE_SEARCH
// define is set.  This is to aid fifogen team search for fifogen fifo
// instance and module names in a given design.
`ifdef FIFOGEN_MODULE_SEARCH
NV_BLKBOX_SRC0 dummy_breadcrumb_fifogen_blkbox (.Y());
`endif

// spyglass enable_block W401 -- clock is not input to module

// synopsys dc_script_begin
//   set_boundary_optimization find(design, "NV_NVDLA_CDP_DP_data_fifo_80x72") true
// synopsys dc_script_end

//| &Attachment -no_warn EndModulePrepend;
//| _attach_EndModulePrepend_7;

`ifdef SYNTH_LEVEL1_COMPILE
`else
`ifdef SYNTHESIS
`else
`ifdef PRAND_VERILOG
// Only verilog needs any local variables
reg [47:0] prand_local_seed0;
reg prand_initialized0;
reg prand_no_rollpli0;
`endif
`endif
`endif

function [31:0] prand_inst0;
//VCS coverage off
    input [31:0] min;
    input [31:0] max;
    reg [32:0] diff;
    
    begin
`ifdef SYNTH_LEVEL1_COMPILE
        prand_inst0 = min;
`else
`ifdef SYNTHESIS
        prand_inst0 = min;
`else
`ifdef PRAND_VERILOG
        if (prand_initialized0 !== 1'b1) begin
            prand_no_rollpli0 = $test$plusargs("NO_ROLLPLI");
            if (!prand_no_rollpli0)
                prand_local_seed0 = {$prand_get_seed(0), 16'b0};
            prand_initialized0 = 1'b1;
        end
        if (prand_no_rollpli0) begin
            prand_inst0 = min;
        end else begin
            diff = max - min + 1;
            prand_inst0 = min + prand_local_seed0[47:16] % diff;
            // magic numbers taken from Java's random class (same as lrand48)
            prand_local_seed0 = prand_local_seed0 * 48'h5deece66d + 48'd11;
        end
`else
`ifdef PRAND_OFF
        prand_inst0 = min;
`else
        prand_inst0 = $RollPLI(min, max, "auto");
`endif
`endif
`endif
`endif
    end
//VCS coverage on
endfunction

//| _attach_EndModulePrepend_8;

`ifdef SYNTH_LEVEL1_COMPILE
`else
`ifdef SYNTHESIS
`else
`ifdef PRAND_VERILOG
// Only verilog needs any local variables
reg [47:0] prand_local_seed1;
reg prand_initialized1;
reg prand_no_rollpli1;
`endif
`endif
`endif

function [31:0] prand_inst1;
//VCS coverage off
    input [31:0] min;
    input [31:0] max;
    reg [32:0] diff;
    
    begin
`ifdef SYNTH_LEVEL1_COMPILE
        prand_inst1 = min;
`else
`ifdef SYNTHESIS
        prand_inst1 = min;
`else
`ifdef PRAND_VERILOG
        if (prand_initialized1 !== 1'b1) begin
            prand_no_rollpli1 = $test$plusargs("NO_ROLLPLI");
            if (!prand_no_rollpli1)
                prand_local_seed1 = {$prand_get_seed(1), 16'b0};
            prand_initialized1 = 1'b1;
        end
        if (prand_no_rollpli1) begin
            prand_inst1 = min;
        end else begin
            diff = max - min + 1;
            prand_inst1 = min + prand_local_seed1[47:16] % diff;
            // magic numbers taken from Java's random class (same as lrand48)
            prand_local_seed1 = prand_local_seed1 * 48'h5deece66d + 48'd11;
        end
`else
`ifdef PRAND_OFF
        prand_inst1 = min;
`else
        prand_inst1 = $RollPLI(min, max, "auto");
`endif
`endif
`endif
`endif
    end
//VCS coverage on
endfunction


//| &Perl $VIVA_MODULE = $NV_NVDLA_CDP_DP_data_fifo_80x72_PARENT_VIVA_MODULE;


endmodule // NV_NVDLA_CDP_DP_data_fifo_80x72





