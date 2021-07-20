`timescale 1ns / 1ps

`include "cpuops.vh"

module riscvcpu(
	input clock,
	input wallclock,
	input reset,
	output logic ifetch = 1'b1, // High for instruction fetch, low for data r/w
	output logic [31:0] memaddress = 32'd0,
	output logic [31:0] cpudataout = 32'd0,
	output logic [3:0] cpuwriteena = 4'b0000,
	output logic cpureadena = 1'b0,
	input [31:0] cpudatain,
	input busstall,
	input IRQ,
	input [1:0] IRQ_TYPE);

// Start from RETIRE state so that we can
// set up instruction fetch address and read
// data which will be available on the next
// clock, in FETCH state.
logic [`CPUSTAGECOUNT-1:0] cpustate = `CPUSTAGEMASK_RETIREINSTRUCTION;

logic [31:0] PC = 32'h20000000;			// Boot from AudioRAM/BootROM device
logic [31:0] nextPC = 32'h20000000;		// Has to be same as PC at startup

// Assume no ebreak
logic ebreak = 1'b0;
// Assume valid instruction
logic illegalinstruction = 1'b0;

// Write address has to be set at the same time
// as read or write enable, this shadow ensures that
logic [31:0] targetaddress;

// Integer and float file write control lines
wire rwen, fwen;
// Delayed write enable copy for EXEC step
logic intregisterwriteenable = 1'b0;
logic floatregisterwriteenable = 1'b0;

// Data input for register writes
logic [31:0] fdata = 32'd0;
logic [31:0] rdata = 32'd0;

// Data for memory store
logic [31:0] storedata = 32'd0;

// Instruction decoder and related wires
wire [4:0] Wopcode;
wire [4:0] Waluop;
wire [2:0] Wfunc3;
wire [6:0] Wfunc7;
wire [11:0] Wfunc12;
wire [4:0] Wrs1;
wire [4:0] Wrs2;
wire [4:0] Wrs3;
wire [4:0] Wrd;
wire [11:0] Wcsrindex;
wire [31:0] Wimmed;
wire Wselectimmedasrval2;

// Decoder will attempt to operate on all memory input
logic decodeenable = 1'b0;
wire decodebuf;
BUFG decodebufg ( .O(decodebuf), .I(decodeenable) );

decoder mydecoder(
	.clock(clock),
	.enable(decodebuf),
	.instruction(cpudatain),
	.opcode(Wopcode),
	.rwen(rwen),
	.fwen(fwen),
	.aluop(Waluop),
	.func3(Wfunc3),
	.func7(Wfunc7),
	.func12(Wfunc12),
	.rs1(Wrs1),
	.rs2(Wrs2),
	.rs3(Wrs3), // Used for fused multiply-add/sub float instructions 
	.rd(Wrd),
	.immed(Wimmed),
	.csrindex(Wcsrindex),
	.selectimmedasrval2(Wselectimmedasrval2) );

// Read results from integer and float registers
wire [31:0] rval1;
wire [31:0] rval2;
wire [31:0] frval1;
wire [31:0] frval2;
wire [31:0] frval3;

// Integer register file
registerfile myintegerregs(
	.clock(clock),					// Writes are clocked, reads are not
	.rs1(Wrs1),						// Source register 1
	.rs2(Wrs2),						// Source register 2
	.rd(Wrd),						// Destination register
	.wren(intregisterwriteenable),	// Write enable bit for writing to register rd (delayed copy)
	.datain(rdata),					// Data into register rd (write)
	.rval1(rval1),					// Value of rs1 (read)
	.rval2(rval2) );				// Value of rs2 (read)

// Floating point register file
floatregisterfile myfloatregs(
	.clock(clock),
	.rs1(Wrs1),
	.rs2(Wrs2),
	.rs3(Wrs3),
	.rd(Wrd),
	.wren(floatregisterwriteenable),
	.datain(fdata),
	.rval1(frval1),
	.rval2(frval2),
	.rval3(frval3) );

// Output from ALU unit based on current op
wire [31:0] aluout;

// Integer ALU unit
ALU myalu(
	.aluout(aluout),								// Result of current ALU op
	.func3(Wfunc3),									// Sub instruction
	.val1(rval1),									// Input value one (rs1)
	.val2(Wselectimmedasrval2 ? Wimmed : rval2),	// Input value two (rs2 or immed)
	.aluop(Waluop) );								// ALU op to apply
	
// Branch decision result
wire branchout;

// Branch ALU unit
branchALU mybranchalu(
	.branchout(branchout),							// High if we should take the branch
	.val1(rval1),									// Input value one (rs1)
	.val2(Wselectimmedasrval2 ? Wimmed : rval2),	// Input value two (rs2 or immed)
	.aluop(Waluop) );								// Compare opearation for branch decision

// -----------------------------------------------------------------------
// Integer math
// -----------------------------------------------------------------------

wire mulbusy, divbusy, divbusyu;
wire [31:0] product;
wire [31:0] quotient;
wire [31:0] quotientu;
wire [31:0] remainder;
wire [31:0] remainderu;

wire isexecuting = cpustate[`CPUEXEC]==1'b1;
wire isexecutingfloatop = isexecuting & (Wopcode==`OPCODE_FLOAT_OP);

// Pulses to kick math operations
wire mulstart = isexecuting & (Waluop==`ALU_MUL) & (Wopcode == `OPCODE_OP);
multiplier themul(
    .clk(clock),
    .reset(reset),
    .start(mulstart),
    .busy(mulbusy),           // calculation in progress
    .func3(Wfunc3),
    .multiplicand(rval1),
    .multiplier(rval2),
    .product(product) );

wire divstart = isexecuting & (Waluop==`ALU_DIV | Waluop==`ALU_REM) & (Wopcode == `OPCODE_OP);
DIVU unsigneddivider (
	.clk(clock),
	.reset(reset),
	.start(divstart),		// start signal
	.busy(divbusyu),		// calculation in progress
	.dividend(rval1),		// dividend
	.divisor(rval2),		// divisor
	.quotient(quotientu),	// result: quotient
	.remainder(remainderu)	// result: remainer
);

DIV signeddivider (
	.clk(clock),
	.reset(reset),
	.start(divstart),		// start signal
	.busy(divbusy),			// calculation in progress
	.dividend(rval1),		// dividend
	.divisor(rval2),		// divisor
	.quotient(quotient),	// result: quotient
	.remainder(remainder)	// result: remainder
);

// Stall status
wire imathstart = divstart | mulstart;
wire imathbusy = divbusy | divbusyu | mulbusy;

// -----------------------------------------------------------------------
// Floating point math
// -----------------------------------------------------------------------

logic fmaddvalid = 1'b0;
logic fmsubvalid = 1'b0;
logic fnmsubvalid = 1'b0;
logic fnmaddvalid = 1'b0;
logic faddvalid = 1'b0;
logic fsubvalid = 1'b0;
logic fmulvalid = 1'b0;
logic fdivvalid = 1'b0;
logic fi2fvalid = 1'b0;
logic fui2fvalid = 1'b0;
logic ff2ivalid = 1'b0;
logic ff2uivalid = 1'b0;
logic fsqrtvalid = 1'b0;
logic feqvalid = 1'b0;
logic fltvalid = 1'b0;
logic flevalid = 1'b0;

wire fmaddresultvalid;
wire fmsubresultvalid;
wire fnmsubresultvalid; 
wire fnmaddresultvalid;
wire faddresultvalid;
wire fsubresultvalid;
wire fmulresultvalid;
wire fdivresultvalid;
wire fi2fresultvalid;
wire fui2fresultvalid;
wire ff2iresultvalid;
wire ff2uiresultvalid;
wire fsqrtresultvalid;
wire feqresultvalid;
wire fltresultvalid;
wire fleresultvalid;

wire [31:0] fmaddresult;
wire [31:0] fmsubresult;
wire [31:0] fnmsubresult;
wire [31:0] fnmaddresult;
wire [31:0] faddresult;
wire [31:0] fsubresult;
wire [31:0] fmulresult;
wire [31:0] fdivresult;
wire [31:0] fi2fresult;
wire [31:0] fui2fresult;
wire [31:0] ff2iresult;
wire [31:0] ff2uiresult;
wire [31:0] fsqrtresult;
wire [7:0] feqresult;
wire [7:0] fltresult;
wire [7:0] fleresult;

fp_madd floatfmadd(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(fmaddvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fmaddvalid),
	.s_axis_c_tdata(frval3),
	.s_axis_c_tvalid(fmaddvalid),
	.aclk(clock),
	.m_axis_result_tdata(fmaddresult),
	.m_axis_result_tvalid(fmaddresultvalid) );

fp_msub floatfmsub(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(fmsubvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fmsubvalid),
	.s_axis_c_tdata(frval3),
	.s_axis_c_tvalid(fmsubvalid),
	.aclk(clock),
	.m_axis_result_tdata(fmsubresult),
	.m_axis_result_tvalid(fmsubresultvalid) );

fp_madd floatfnmsub(
	.s_axis_a_tdata({~frval1[31], frval1[30:0]}), // -A
	.s_axis_a_tvalid(fnmsubvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fnmsubvalid),
	.s_axis_c_tdata(frval3),
	.s_axis_c_tvalid(fnmsubvalid),
	.aclk(clock),
	.m_axis_result_tdata(fnmsubresult),
	.m_axis_result_tvalid(fnmsubresultvalid) );

fp_msub floatfnmadd(
	.s_axis_a_tdata({~frval1[31], frval1[30:0]}), // -A
	.s_axis_a_tvalid(fnmaddvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fnmaddvalid),
	.s_axis_c_tdata(frval3),
	.s_axis_c_tvalid(fnmaddvalid),
	.aclk(clock),
	.m_axis_result_tdata(fnmaddresult),
	.m_axis_result_tvalid(fnmaddresultvalid) );

fp_add floatadd(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(faddvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(faddvalid),
	.aclk(clock),
	.m_axis_result_tdata(faddresult),
	.m_axis_result_tvalid(faddresultvalid) );
	
fp_sub floatsub(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(fsubvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fsubvalid),
	.aclk(clock),
	.m_axis_result_tdata(fsubresult),
	.m_axis_result_tvalid(fsubresultvalid) );


fp_mul floatmul(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(fmulvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fmulvalid),
	.aclk(clock),
	.m_axis_result_tdata(fmulresult),
	.m_axis_result_tvalid(fmulresultvalid) );

fp_div floatdiv(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(fdivvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fdivvalid),
	.aclk(clock),
	.m_axis_result_tdata(fdivresult),
	.m_axis_result_tvalid(fdivresultvalid) );

fp_i2f floati2f(
	.s_axis_a_tdata(rval1), // Integer source
	.s_axis_a_tvalid(fi2fvalid),
	.aclk(clock),
	.m_axis_result_tdata(fi2fresult),
	.m_axis_result_tvalid(fi2fresultvalid) );

fp_ui2f floatui2f(
	.s_axis_a_tdata(rval1), // Integer source
	.s_axis_a_tvalid(fui2fvalid),
	.aclk(clock),
	.m_axis_result_tdata(fui2fresult),
	.m_axis_result_tvalid(fui2fresultvalid) );

fp_f2i floatf2i(
	.s_axis_a_tdata(frval1), // Float source
	.s_axis_a_tvalid(ff2ivalid),
	.aclk(clock),
	.m_axis_result_tdata(ff2iresult),
	.m_axis_result_tvalid(ff2iresultvalid) );

// NOTE: Sharing same logic with f2i here, ignoring sign bit instead
fp_f2i floatf2ui(
	.s_axis_a_tdata({1'b0,frval1[30:0]}), // abs(A) (float register is source)
	.s_axis_a_tvalid(ff2uivalid),
	.aclk(clock),
	.m_axis_result_tdata(ff2uiresult),
	.m_axis_result_tvalid(ff2uiresultvalid) );
	
fp_sqrt floatsqrt(
	.s_axis_a_tdata({1'b0,frval1[30:0]}), // abs(A) (float register is source)
	.s_axis_a_tvalid(fsqrtvalid),
	.aclk(clock),
	.m_axis_result_tdata(fsqrtresult),
	.m_axis_result_tvalid(fsqrtresultvalid) );

fp_eq floateq(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(feqvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(feqvalid),
	.aclk(clock),
	.m_axis_result_tdata(feqresult),
	.m_axis_result_tvalid(feqresultvalid) );

fp_lt floatlt(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(fltvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fltvalid),
	.aclk(clock),
	.m_axis_result_tdata(fltresult),
	.m_axis_result_tvalid(fltresultvalid) );

fp_le floatle(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(flevalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(flevalid),
	.aclk(clock),
	.m_axis_result_tdata(fleresult),
	.m_axis_result_tvalid(fleresultvalid) );


// -----------------------------------------------------------------------
// Cycle/Timer/Reti CSRs
// -----------------------------------------------------------------------

logic [4:0] CSRIndextoLinearIndex;
logic [31:0] CSRReg [0:23];

initial begin
	CSRReg[`CSR_FFLAGS]		= 32'd0;
	CSRReg[`CSR_FRM]		= 32'd0;
	CSRReg[`CSR_FCSR]		= 32'd0;
	CSRReg[`CSR_MSTATUS]	= 32'd0;
	CSRReg[`CSR_MISA]		= {2'b01, 4'b0000, 26'b00000000000001000100100000};	// 301 MXL:1, 32 bits, Extensions: I M F;
	CSRReg[`CSR_MIE]		= 32'd0;
	CSRReg[`CSR_MTVEC]		= 32'd0;
	CSRReg[`CSR_MSCRATCH]	= 32'd0;
	CSRReg[`CSR_MEPC]		= 32'd0;
	CSRReg[`CSR_MCAUSE]		= 32'd0;
	CSRReg[`CSR_MTVAL]		= 32'd0;
	CSRReg[`CSR_MIP]		= 32'd0;
	CSRReg[`CSR_DCSR]		= 32'd0;
	CSRReg[`CSR_DPC]		= 32'd0;
	CSRReg[`CSR_TIMECMPLO]	= 32'hFFFFFFFF; // timecmp = 0xFFFFFFFFFFFFFFFF
	CSRReg[`CSR_TIMECMPHI]	= 32'hFFFFFFFF;
	CSRReg[`CSR_CYCLELO]	= 32'd0;
	CSRReg[`CSR_CYCLEHI]	= 32'd0;
	CSRReg[`CSR_TIMELO]		= 32'd0;
	CSRReg[`CSR_RETILO]		= 32'd0;
	CSRReg[`CSR_TIMEHI]		= 32'd0;
	CSRReg[`CSR_RETIHI]		= 32'd0;
	CSRReg[`CSR_VENDORID]	= 32'd0;
	CSRReg[`CSR_HARTID]		= 32'd0;
end

always_comb begin
	case (Wcsrindex)
		12'h001: CSRIndextoLinearIndex = `CSR_FFLAGS;
		12'h002: CSRIndextoLinearIndex = `CSR_FRM;
		12'h003: CSRIndextoLinearIndex = `CSR_FCSR;
		12'h300: CSRIndextoLinearIndex = `CSR_MSTATUS;
		12'h301: CSRIndextoLinearIndex = `CSR_MISA;
		12'h304: CSRIndextoLinearIndex = `CSR_MIE;
		12'h305: CSRIndextoLinearIndex = `CSR_MTVEC;
		12'h340: CSRIndextoLinearIndex = `CSR_MSCRATCH;
		12'h341: CSRIndextoLinearIndex = `CSR_MEPC;
		12'h342: CSRIndextoLinearIndex = `CSR_MCAUSE;
		12'h343: CSRIndextoLinearIndex = `CSR_MTVAL;
		12'h344: CSRIndextoLinearIndex = `CSR_MIP;
		12'h780: CSRIndextoLinearIndex = `CSR_DCSR;
		12'h781: CSRIndextoLinearIndex = `CSR_DPC;
		12'h800: CSRIndextoLinearIndex = `CSR_TIMECMPLO;
		12'h801: CSRIndextoLinearIndex = `CSR_TIMECMPHI;
		12'hB00: CSRIndextoLinearIndex = `CSR_CYCLELO;
		12'hB80: CSRIndextoLinearIndex = `CSR_CYCLEHI;
		12'hC01: CSRIndextoLinearIndex = `CSR_TIMELO;
		12'hC02: CSRIndextoLinearIndex = `CSR_RETILO;
		12'hC81: CSRIndextoLinearIndex = `CSR_TIMEHI;
		12'hC82: CSRIndextoLinearIndex = `CSR_RETIHI;
		12'hF11: CSRIndextoLinearIndex = `CSR_VENDORID;
		12'hF14: CSRIndextoLinearIndex = `CSR_HARTID;
	endcase
end

// Other custom CSRs r/w between 0x802-0x8FF

// Advancing cycles is simple since clocks = cycles
logic [63:0] internalcyclecounter = 64'd0;
always @(posedge clock) begin
	internalcyclecounter <= internalcyclecounter + 64'd1;
end

// Time is also simple since we know we have 10M ticks per second
// from which we can derive seconds elapsed
logic [63:0] internalwallclockcounter = 64'd0;
always @(posedge wallclock) begin
	internalwallclockcounter <= internalwallclockcounter + 64'd1;
end

logic [63:0] internalretirecounter = 64'd0;
always @(posedge clock) begin
	internalretirecounter <= internalretirecounter + {63'd0, cpustate[`CPURETIREINSTRUCTION]};
end

wire timerinterrupt = CSRReg[`CSR_MIE][7] & (internalwallclockcounter >= {CSRReg[`CSR_TIMECMPHI], CSRReg[`CSR_TIMECMPLO]});
wire externalinterrupt = (CSRReg[`CSR_MIE][11] & IRQ);

// -----------------------------------------------------------------------
// CPU Core
// -----------------------------------------------------------------------

always @(posedge clock) begin
	if (reset) begin

		cpustate <= `CPUSTAGEMASK_RETIREINSTRUCTION;

	end else begin

		// Clear the state bits for next clock
		cpustate <= `CPUSTAGEMASK_NONE;

		// Selected state can now set the bit for the
		// next state for the next clock, which will
		// override the above zero-set.
		unique case (1'b1)

			cpustate[`CPUFETCH]: begin
				if (busstall) begin
					// Bus might stall during writes if busy
					// Wait in this state until it's freed
					cpustate[`CPUFETCH] <= 1'b1;
				end else begin
					// Can stop read request now
					// Read result will be available in DECODE stage
					cpureadena <= 1'b0;
					decodeenable <= 1'b1;
					ifetch <= 1'b0;
					cpustate[`CPUDECODE] <= 1'b1;
				end
			end

			cpustate[`CPUDECODE]: begin
				decodeenable <= 1'b0;
				// Update counters
				{CSRReg[`CSR_CYCLEHI], CSRReg[`CSR_CYCLELO]} <= internalcyclecounter;
				{CSRReg[`CSR_TIMEHI], CSRReg[`CSR_TIMELO]} <= internalwallclockcounter;
				{CSRReg[`CSR_RETIHI], CSRReg[`CSR_RETILO]} <= internalretirecounter;
				cpustate[`CPUEXEC] <= 1'b1;
			end

			cpustate[`CPUEXEC]: begin
				// We decide on the nextPC in EXEC
				nextPC <= PC + 32'd4;

				ebreak <= 1'b0;
				illegalinstruction <= 1'b0;

				// These actually work (and generate much better WNS) in synthesis, DO NOT remove!
				// Consider these as the catch-all for unassigned states, set to don't care value X.
				fdata <= 32'd0;
				rdata <= 32'd0; // Don't care
				storedata <= 32'd0; // Don't care
				//memaddress <= 32'd0; // Don't touch without corresponding re/we set
				//cpureadena <= 1'b0;
				targetaddress <= 32'd0; // Don't care

				// Set this up at the appropriate time
				// so that the write happens after
				// any values are calculated.
				// Make sure to shut down register writes before we damage something
				// during mathstart since we need to route to a lengthy operation
				intregisterwriteenable <= imathstart ? 1'b0 : rwen;
				floatregisterwriteenable <= fwen;

				// Set up any nextPC or register data
				unique case (Wopcode)
					`OPCODE_AUPC: begin
						rdata <= PC + Wimmed;
						cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
					end
					`OPCODE_LUI: begin
						rdata <= Wimmed;
						cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
					end
					`OPCODE_JAL: begin
						rdata <= PC + 32'd4;
						nextPC <= PC + Wimmed;
						cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
					end
					`OPCODE_OP, `OPCODE_OP_IMM: begin
						if (imathstart) begin
							cpustate[`CPUMSTALL] <= 1'b1;
						end else begin
							rdata <= aluout;
							cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
						end
					end
					`OPCODE_FLOAT_LDW, `OPCODE_LOAD: begin
						memaddress <= rval1 + Wimmed;
						cpureadena <= 1'b1;
						// Load has to wait one extra clock
						// so that the memory load / register write
						// has time to complete.
						cpustate[`CPULOADSTALL] <= 1'b1;
					end
					`OPCODE_FLOAT_STW, `OPCODE_STORE: begin
						storedata <= (Wopcode == `OPCODE_FLOAT_STW) ? frval2 : rval2;
						targetaddress <= rval1 + Wimmed;
						cpustate[`CPUSTORE] <= 1'b1;
					end
					`OPCODE_FENCE: begin
						// TODO:
						cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
					end
					`OPCODE_SYSTEM: begin
						unique case (Wfunc3)
							3'b000: begin // ECALL/EBREAK
								cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
								unique case (Wfunc12)
									12'b000000000000: begin // ECALL
										// TBD
										// example: 
										// li a7, SBI_SHUTDOWN // also a0/a1/a2, retval in a0
  										// ecall
  									end
									12'b000000000001: begin // EBREAK
										ebreak <= CSRReg[`CSR_MIE][3];
									end
									// privileged instructions
									12'b001100000010: begin // MRET
										if (CSRReg[`CSR_MCAUSE][15:0] == 16'd2) CSRReg[`CSR_MIP][2] <= 1'b0; // Disable illegal instruction exception pending
										if (CSRReg[`CSR_MCAUSE][15:0] == 16'd3) CSRReg[`CSR_MIP][3] <= 1'b0; // Disable machine interrupt pending
										if (CSRReg[`CSR_MCAUSE][15:0] == 16'd7) CSRReg[`CSR_MIP][7] <= 1'b0; // Disable machine timer interrupt pending
										if (CSRReg[`CSR_MCAUSE][15:0] == 16'd11) CSRReg[`CSR_MIP][11] <= 1'b0; // Disable machine external interrupt pending
										CSRReg[`CSR_MSTATUS][3] <= CSRReg[`CSR_MSTATUS][7]; // MIE=MPIE - set to previous machine interrupt enable state
										CSRReg[`CSR_MSTATUS][7] <= 1'b0; // Clear MPIE
										nextPC <= CSRReg[`CSR_MEPC];
									end
								endcase
							end
							3'b001, // CSRRW
							3'b010, // CSRRS
							3'b011, // CSSRRC
							3'b101, // CSRRWI
							3'b110, // CSRRSI
							3'b111: begin // CSRRCI
								cpustate[`CPUUPDATECSR] <= 1'b1;
								rdata <= CSRReg[CSRIndextoLinearIndex];
							end
							default: begin
								cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
							end
						endcase
					end
					`OPCODE_FLOAT_OP: begin
						unique case (Wfunc7)
							`FSGNJ: begin
								unique case(Wfunc3)
									3'b000: begin // FSGNJ
										fdata <= {frval2[31], frval1[30:0]}; 
									end
									3'b001: begin  // FSGNJN
										fdata <= {~frval2[31], frval1[30:0]};
									end
									3'b010: begin  // FSGNJX
										fdata <= {frval1[31]^frval2[31], frval1[30:0]};
									end
								endcase
								cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
							end
							`FMVXW: begin
								if (Wfunc3 == 3'b000) //FMVXW
									rdata <= frval1;
								else // FCLASS
									rdata <= 32'd0; // TBD
								cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
							end
							`FMVWX: begin
								fdata <= rval1;
								cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
							end
							`FADD: begin
								faddvalid <= 1'b1;
								cpustate[`CPUFSTALL] <= 1'b1;
							end
							`FSUB: begin
								fsubvalid <= 1'b1;
								cpustate[`CPUFSTALL] <= 1'b1;
							end	
							`FMUL: begin
								fmulvalid <= 1'b1;
								cpustate[`CPUFSTALL] <= 1'b1;
							end	
							`FDIV: begin
								fdivvalid <= 1'b1;
								cpustate[`CPUFSTALL] <= 1'b1;
							end
							`FCVTSW: begin	
								fi2fvalid <= (Wrs2==5'b00000) ? 1'b1:1'b0; // Signed
								fui2fvalid <= (Wrs2==5'b00001) ? 1'b1:1'b0; // Unsigned
								cpustate[`CPUFSTALL] <= 1'b1;
							end
							`FCVTWS: begin
								ff2ivalid <= (Wrs2==5'b00000) ? 1'b1:1'b0; // Signed
								ff2uivalid <= (Wrs2==5'b00001) ? 1'b1:1'b0; // Unsigned
								cpustate[`CPUFSTALL] <= 1'b1;
							end
							`FSQRT: begin
								fsqrtvalid <= 1'b1;
								cpustate[`CPUFSTALL] <= 1'b1;
							end
							`FEQ: begin
								feqvalid <= (Wfunc3==3'b010) ? 1'b1:1'b0; // FEQ
								fltvalid <= (Wfunc3==3'b001) ? 1'b1:1'b0; // FLT
								flevalid <= (Wfunc3==3'b000) ? 1'b1:1'b0; // FLE
								cpustate[`CPUFSTALL] <= 1'b1;
							end
							`FMAX: begin
								fltvalid <= 1'b1; // FLT
								cpustate[`CPUFSTALL] <= 1'b1;
							end
						endcase
					end
					`OPCODE_FLOAT_MADD: begin
						fmaddvalid <= 1'b1;
						cpustate[`CPUFFSTALL] <= 1'b1;
					end
					`OPCODE_FLOAT_MSUB: begin
						fmsubvalid <= 1'b1;
						cpustate[`CPUFFSTALL] <= 1'b1;
					end
					`OPCODE_FLOAT_NMSUB: begin
						fnmsubvalid <= 1'b1; // is actually MADD!
						cpustate[`CPUFFSTALL] <= 1'b1;
					end
					`OPCODE_FLOAT_NMADD: begin
						fnmaddvalid <= 1'b1; // is actually MSUB!
						cpustate[`CPUFFSTALL] <= 1'b1;
					end
					`OPCODE_JALR: begin
						rdata <= PC + 32'd4;
						nextPC <= rval1 + Wimmed;
						cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
					end
					`OPCODE_BRANCH: begin
						nextPC <= branchout == 1'b1 ? PC + Wimmed : PC + 32'd4;
						cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
					end
					default: begin
						// This is an unhandled instruction
						illegalinstruction <= CSRReg[`CSR_MIE][2];
						cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
					end
				endcase

			end
			
			cpustate[`CPUUPDATECSR]: begin
				// Stop copying to integer register
				intregisterwriteenable <= 1'b0;
				
				// Write to r/w CSR
				case(Wfunc3)
					3'b001: begin // CSRRW
						CSRReg[CSRIndextoLinearIndex] <= rval1;
					end
					3'b101: begin // CSRRWI
						CSRReg[CSRIndextoLinearIndex] <= Wimmed;
					end
					3'b010: begin // CSRRS
						CSRReg[CSRIndextoLinearIndex] <= rdata | rval1;
					end
					3'b110: begin // CSRRSI
						CSRReg[CSRIndextoLinearIndex] <= rdata | Wimmed;
					end
					3'b011: begin // CSSRRC
						CSRReg[CSRIndextoLinearIndex] <= rdata & (~rval1);
					end
					3'b111: begin // CSRRCI
						CSRReg[CSRIndextoLinearIndex] <= rdata & (~Wimmed);
					end
					default: begin // Unknown
						CSRReg[CSRIndextoLinearIndex] <= rdata;
					end
				endcase
				cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
			end
			
			cpustate[`CPUFSTALL]: begin

				faddvalid <= 1'b0;
				fsubvalid <= 1'b0;
				fmulvalid <= 1'b0;
				fdivvalid <= 1'b0;
				fi2fvalid <= 1'b0;
				fui2fvalid <= 1'b0;
				ff2ivalid <= 1'b0;
				ff2uivalid <= 1'b0;
				fsqrtvalid <= 1'b0;
				feqvalid <= 1'b0;
				fltvalid <= 1'b0;
				flevalid <= 1'b0;

				if  (fmulresultvalid | fdivresultvalid | fi2fresultvalid | fui2fresultvalid | ff2iresultvalid | ff2uiresultvalid | faddresultvalid | fsubresultvalid | fsqrtresultvalid | feqresultvalid | fltresultvalid | fleresultvalid) begin
					intregisterwriteenable <= rwen;
					floatregisterwriteenable <= fwen;
					cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
					unique case (Wfunc7)
						`FADD: begin
							fdata <= faddresult;
						end
						`FSUB: begin
							fdata <= fsubresult;
						end
						`FMUL: begin
							fdata <= fmulresult;
						end
						`FDIV: begin
							rdata <= fdivresult;
						end
						`FCVTSW: begin // NOTE: FCVT.S.WU is unsigned version
							fdata <= Wrs2==5'b00000 ? fi2fresult : fui2fresult; // Result goes to float register (signed int to float)
						end
						`FCVTWS: begin // NOTE: FCVT.WU.S is unsigned version
							rdata <= Wrs2==5'b00000 ? ff2iresult : ff2uiresult; // Result goes to integer register (float to signed int)
						end
						`FSQRT: begin
							fdata <= fsqrtresult;
						end
						`FEQ: begin
							if (Wfunc3==3'b010) // FEQ
								rdata <= {31'd0,feqresult[0]};
							else if (Wfunc3==3'b001) // FLT
								rdata <= {31'd0,fltresult[0]};
							else //if (Wfunc3==3'b000) // FLE
								rdata <= {31'd0,fleresult[0]};
						end
						`FMIN: begin
							if (Wfunc3==3'b000) // FMIN
								fdata <= fltresult[0]==1'b0 ? frval2 : frval1;
							else // FMAX
								fdata <= fltresult[0]==1'b0 ? frval1 : frval2;
						end
					endcase
				end else begin
					cpustate[`CPUFSTALL] <= 1'b1; // Stall further for float op
				end
			end

			cpustate[`CPUFFSTALL]: begin

				fmaddvalid <= 1'b0;
				fmsubvalid <= 1'b0;
				fnmsubvalid <= 1'b0;
				fnmaddvalid <= 1'b0;

				if (fnmsubresultvalid | fnmaddresultvalid | fmsubresultvalid | fmaddresultvalid) begin
					floatregisterwriteenable <= 1'b1;
					cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
					unique case (Wopcode)
						`OPCODE_FLOAT_NMSUB: begin
							fdata <= fnmsubresult;
						end
						`OPCODE_FLOAT_NMADD: begin
							fdata <= fnmaddresult;
						end
						`OPCODE_FLOAT_MADD: begin
							fdata <= fmaddresult;
						end
						`OPCODE_FLOAT_MSUB: begin
							fdata <= fmsubresult;
						end
					endcase
				end else begin
					cpustate[`CPUFFSTALL] <= 1'b1; // Stall further for fused float
				end
			end
			
			cpustate[`CPUMSTALL]: begin
				if (imathbusy) begin
					cpustate[`CPUMSTALL] <= 1'b1;
				end else begin
					// Re-enable register writes
					intregisterwriteenable <= 1'b1;
					unique case (Waluop)
						`ALU_MUL: begin
							rdata <= product;
						end
						`ALU_DIV: begin
							rdata <= Wfunc3==`F3_DIV ? quotient : quotientu;
						end
						`ALU_REM: begin
							rdata <= Wfunc3==`F3_REM ? remainder : remainderu;
						end
					endcase
					cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
				end
			end
			
			cpustate[`CPULOADSTALL]: begin
				// Stall state for memory reads
				if (busstall) begin
					// Bus might stall during writes if busy
					// Wait in this state until it's freed
					cpustate[`CPULOADSTALL] <= 1'b1;
				end else begin
					cpureadena <= 1'b0;
					cpustate[`CPULOADCOMPLETE] <= 1'b1;
				end
			end

			cpustate[`CPULOADCOMPLETE]: begin
				// Read complete, handle register write-back
				unique case (Wfunc3)
					3'b000: begin // BYTE with sign extension
						unique case (memaddress[1:0])
							2'b11: begin rdata <= {{24{cpudatain[31]}}, cpudatain[31:24]}; end
							2'b10: begin rdata <= {{24{cpudatain[23]}}, cpudatain[23:16]}; end
							2'b01: begin rdata <= {{24{cpudatain[15]}}, cpudatain[15:8]}; end
							2'b00: begin rdata <= {{24{cpudatain[7]}}, cpudatain[7:0]}; end
						endcase
					end
					3'b001: begin // WORD with sign extension
						unique case (memaddress[1])
							1'b1: begin rdata <= {{16{cpudatain[31]}}, cpudatain[31:16]}; end
							1'b0: begin rdata <= {{16{cpudatain[15]}}, cpudatain[15:0]}; end
						endcase
					end
					3'b010: begin // DWORD
						if (Wopcode == `OPCODE_FLOAT_LDW)
							fdata <= cpudatain[31:0];
						else
							rdata <= cpudatain[31:0];
					end
					3'b100: begin // BYTE with zero extension
						unique case (memaddress[1:0])
							2'b11: begin rdata <= {24'd0, cpudatain[31:24]}; end
							2'b10: begin rdata <= {24'd0, cpudatain[23:16]}; end
							2'b01: begin rdata <= {24'd0, cpudatain[15:8]}; end
							2'b00: begin rdata <= {24'd0, cpudatain[7:0]}; end
						endcase
					end
					3'b101: begin // WORD with zero extension
						unique case (memaddress[1])
							1'b1: begin rdata <= {16'd0, cpudatain[31:16]}; end
							1'b0: begin rdata <= {16'd0, cpudatain[15:0]}; end
						endcase
					end
				endcase
				// We can now write back
				if (Wopcode == `OPCODE_FLOAT_LDW)
					floatregisterwriteenable <= 1'b1;
				else
					intregisterwriteenable <= 1'b1;
				cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
			end

			cpustate[`CPUSTORE]: begin
				// Request write of current register data to memory
				// with appropriate write mask and data size
				// For FSW, func3==010, same as SW (DWORD)
				memaddress <= targetaddress;
				unique case (Wfunc3)
					3'b000: begin // BYTE
						cpudataout <= {storedata[7:0], storedata[7:0], storedata[7:0], storedata[7:0]};
						case (targetaddress[1:0])
							2'b11: begin cpuwriteena <= 4'b1000; end
							2'b10: begin cpuwriteena <= 4'b0100; end
							2'b01: begin cpuwriteena <= 4'b0010; end
							2'b00: begin cpuwriteena <= 4'b0001; end
						endcase
					end
					3'b001: begin // WORD
						cpudataout <= {storedata[15:0], storedata[15:0]};
						case (targetaddress[1])
							1'b1: begin cpuwriteena <= 4'b1100; end
							1'b0: begin cpuwriteena <= 4'b0011; end
						endcase
					end
					default: begin // DWORD
						cpudataout <= storedata;
						cpuwriteena <= 4'b1111;
					end
				endcase
				cpustate[`CPUSTORECOMPLETE] <= 1'b1;
			end
			
			cpustate[`CPUSTORECOMPLETE]: begin
				if (busstall) begin
					cpustate[`CPUSTORECOMPLETE] <= 1'b1;
				end else begin
					cpuwriteena <= 4'b0000;
					cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
				end
			end

			cpustate[`CPURETIREINSTRUCTION]: begin
				// We need to turn off the
				// register write enable lines
				// before we fetch and decode a new
				// instruction so we don't destroy
				// any registers while rd changes
				intregisterwriteenable <= 1'b0;
				floatregisterwriteenable <= 1'b0;

				// Default, assume no exceptions/interrupts
				PC <= nextPC;
				memaddress <= nextPC;
				// Turn on reads to fetch the next instruction
				cpureadena <= 1'b1;
				ifetch <= 1'b1;

				if (CSRReg[`CSR_MSTATUS][3]) begin
				
					// Common action in case of 'any' interrupt
					if (illegalinstruction | ebreak | timerinterrupt | externalinterrupt) begin
						CSRReg[`CSR_MSTATUS][7] <= CSRReg[`CSR_MSTATUS][3]; // Remember interrupt enable status in pending state (MPIE = MIE)
						CSRReg[`CSR_MSTATUS][3] <= 1'b0; // Clear interrupts during handler
						CSRReg[`CSR_MTVAL] <= 32'd0; // Store interrupt/exception specific data (default=0)
						CSRReg[`CSR_MEPC] <= nextPC; // Remember where to return
						// Jump to handler
						// Set up non-vectored branch (always assume CSRReg[`CSR_MTVEC][1:0]==2'b00)
						PC <= {CSRReg[`CSR_MTVEC][31:2],2'b00};
						memaddress <= {CSRReg[`CSR_MTVEC][31:2],2'b00};
					end

					// Set interrupt pending bits
					{CSRReg[`CSR_MIP][2], CSRReg[`CSR_MIP][3], CSRReg[`CSR_MIP][7], CSRReg[`CSR_MIP][11]} <= {illegalinstruction, ebreak, timerinterrupt, externalinterrupt};
					
					unique case (1'b1)
						illegalinstruction: begin
							CSRReg[`CSR_MCAUSE] <= {1'b0, 31'd2}; // No extra cause, just illegal instruction exception (high bit clear)
							CSRReg[`CSR_MTVAL] <= PC; // Store the address of the instruction with the exception
						end
						ebreak: begin
							CSRReg[`CSR_MCAUSE] <= {1'b1, 31'd3}; // No extra cause, just a breakpoint interrupt
							// Special case; ebreak returns to same PC as breakpoint
							CSRReg[`CSR_MEPC] <= PC;
						end
						timerinterrupt: begin
							// Time interrupt stays pending until cleared
							CSRReg[`CSR_MCAUSE][15:0] <= 32'd7; // Timer Interrupt
							CSRReg[`CSR_MCAUSE][31:16] <= {1'b1, 15'd0}; // Type of timer interrupt is set to zero
						end
						externalinterrupt: begin
							// External interrupt of type IRQ_TYPE from buttons/switches/UART and other peripherals
							CSRReg[`CSR_MCAUSE][15:0] <= 32'd11; // Machine External Interrupt
							CSRReg[`CSR_MCAUSE][31:16] <= {1'b1, 13'd0, IRQ_TYPE}; // Mask generated for devices causing interrupt
						end
					endcase
				end

				cpustate[`CPUFETCH] <= 1'b1;
			end
		endcase
	end
end

endmodule
