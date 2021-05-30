`timescale 1ns / 1ps

`include "cpuops.vh"

module riscvcpu(
	input clock,
	input reset,
	output logic [3:0] diagnosis = 4'b0000,
	logic [9:0] memaddress = 10'd0,
	output logic [31:0] cpudataout = 32'd0,
	wire [31:0] cpudatain  );

// Start from RETIRE state so that we can
// set up instruction fetch address and read
// data which will be available on the next
// clock, in FETCH state.
logic [`CPUSTAGECOUNT-1:0] cpustate = `CPUSTAGEMASK_RETIREINSTRUCTION;

logic [31:0] PC = 32'd0;
logic [31:0] nextPC = 32'd0;
logic [31:0] instruction = 32'd0; // Illegal instruction

// Register file write control
wire rwen;
// Delayed copy for EXEC step
logic registerwriteenable = 1'b0;

// Data input for register writes
logic [31:0] rdata = 32'd0;

// Instruction decoder and related wires
wire [6:0] opcode;
wire [4:0] aluop;
wire [2:0] func3;
wire [6:0] func7;
wire [4:0] rs1;
wire [4:0] rs2;
wire [4:0] rs3;
wire [4:0] rd;
wire [31:0] immed;
wire selectimmedasrval2;
decoder mydecoder(
	.instruction(instruction),
	.opcode(opcode),
	.rwen(rwen),
	.aluop(aluop),
	.func3(func3),
	.func7(func7),
	.rs1(rs1),
	.rs2(rs2),
	.rs3(rs3), // This is not used just yet 
	.rd(rd),
	.immed(immed),
	.selectimmedasrval2(selectimmedasrval2) );

// Read results of source register one and two
wire [31:0] rval1;
wire [31:0] rval2;

// Register file
registerfile myintegerregs(
	.reset(reset),				// Internal state resets when high
	.clock(clock),				// Writes are clocked, reads are not
	.rs1(rs1),					// Source register 1
	.rs2(rs2),					// Source register 2
	.rd(rd),					// Destination register
	.wren(registerwriteenable),	// Write enable bit for writing to register rd (delayed copy)
	.datain(rdata),				// Data into register rd (write)
	.rval1(rval1),				// Value of rs1 (read)
	.rval2(rval2) );			// Value of rs2 (read)

// Output from ALU unit based on current op
wire [31:0] aluout;

// Integer ALU unit
ALU myalu(
	.aluout(aluout),		// Result of current ALU op
	.func3(func3),			// Sub instruction
	.val1(rval1),			// Input value one (rs1)
	.val2(rval2),			// Input value two (rs2 or immed)
	.aluop(aluop) );		// ALU op to apply

always @(posedge clock) begin
	if (reset) begin
		//
	end else begin

		// Clear the state bits for next clock
		cpustate <= `CPUSTAGEMASK_NONE;

		// Selected state can now set the bit for the
		// next state for the next clock, which will
		// override the above zero-set.
		case (1'b1)
			cpustate[`CPUFETCH]: begin
				// Fetching from memory
				diagnosis[0] <= 1'b0;
				cpustate[`CPUDECODE] <= 1'b1;
			end
			cpustate[`CPUDECODE]: begin
				// cpudatain now contains our
				// first instruction to decode
				// Set it as decoder input
				instruction <= cpudatain;
				nextPC <= PC + 4;
				cpustate[`CPUEXEC] <= 1'b1;
			end
			cpustate[`CPUEXEC]: begin
				// Set this up at the appropriate time
				// so that the write happens after
				// any values are calculated.
				registerwriteenable <= rwen;
				// At this stage decoder output is ready
				cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
			end
			cpustate[`CPURETIREINSTRUCTION]: begin
				// We need to turn off the
				// register write enable
				// before we fethc and decode a new
				// instruction so we don't destroy
				// any registers while rd changes
				registerwriteenable <= 1'b0;
				// Set new PC
				PC <= nextPC;
				// Truncated
				memaddress <= nextPC[11:2];
				diagnosis[0] <= 1'b1;
				cpustate[`CPUFETCH] <= 1'b1;
			end
		endcase
	end
end

endmodule
