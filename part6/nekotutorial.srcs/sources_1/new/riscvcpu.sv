`timescale 1ns / 1ps

module riscvcpu(
	input clock,
	input reset,
	output logic [3:0] diagnosis = 4'b0000,
	logic [9:0] memaddress,
	output logic [31:0] cpudataout = 32'd0,
	wire [31:0] cpudatain  );

// Number of bits for the one-hot encoded CPU state
`define CPUSTAGECOUNT           4

// Bit indices for one-hot encoded CPU state
`define CPUFETCH				0
`define CPUDECODE				1
`define CPUEXEC					2
`define CPURETIREINSTRUCTION	3

// Start from RETIRE state so that we can
// set up instruction fetch address and read
// data which will be available on the next
// clock, in FETCH state.
logic [`CPUSTAGECOUNT-1:0] cpustate = 4'b1000;

logic [31:0] PC = 32'd0;
logic [31:0] nextPC = 32'd0;

always @(posedge clock) begin
	if (reset) begin
		//
	end else begin

		// Clear the state bits for next clock
		cpustate <= 4'b0000;

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
				nextPC <= PC + 4;
				cpustate[`CPUEXEC] <= 1'b1;
			end
			cpustate[`CPUEXEC]: begin
				// TODO:
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
