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

// Instruction decoder and related wires
wire [6:0] opcode;
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
	.func3(func3),
	.func7(func7),
	.rs1(rs1),
	.rs2(rs2),
	.rd(rd),
	.immed(immed),
	.selectimmedasrval2(selectimmedasrval2) );

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
				// At this stage decoder output is ready
				cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
			end
			cpustate[`CPURETIREINSTRUCTION]: begin
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
