`timescale 1ns / 1ps

`include "cpuops.vh"

module riscvcpu(
	input clock,
	input reset,
	output logic [3:0] diagnosis = 4'b0000,
	logic [31:0] memaddress = 32'd0,
	output logic [31:0] cpudataout = 32'd0,
	output logic [3:0] cpuwriteena = 4'b0000,
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

wire [31:0] rval2selector = selectimmedasrval2 ? immed : rval2;

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
	.val2(rval2selector),	// Input value two (rs2 or immed)
	.aluop(aluop) );		// ALU op to apply
	
// Branch decision result
wire branchout;

// Branch ALU unit
branchALU mybranchalu(
	.branchout(branchout),	// High if we should take the branch
	.val1(rval1),			// Input value one (rs1)
	.val2(rval2selector),	// Input value two (rs2 or immed)
	.aluop(aluop) );		// Compare opearation for branch decision

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
				// This is to cover for the 1 cycle read delay
				// of our block RAM
				// Read result will be available on the next clock
				diagnosis[0] <= 1'b0;
				cpustate[`CPUDECODE] <= 1'b1;
			end

			cpustate[`CPUDECODE]: begin
				// cpudatain now contains our
				// first instruction to decode
				// Set it as decoder input
				instruction <= cpudatain;
				cpustate[`CPUEXEC] <= 1'b1;
			end

			cpustate[`CPUEXEC]: begin
				// We decide on the nextPC in EXEC
				nextPC <= PC + 4;

				// Set this up at the appropriate time
				// so that the write happens after
				// any values are calculated.
				registerwriteenable <= rwen;

				// Set up any nextPC or register data
				unique case (opcode)
					`OPCODE_AUPC: begin
						rdata <= PC + immed;
						cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
					end
					`OPCODE_LUI: begin
						rdata <= immed;
						cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
					end
					`OPCODE_JAL: begin
						rdata <= PC + 32'd4;
						nextPC <= PC + immed;
						cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
					end
					`OPCODE_OP, `OPCODE_OP_IMM: begin
						rdata <= aluout;
						cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
					end
					`OPCODE_LOAD: begin
						memaddress <= rval1 + immed;
						// Load has to wait one extra clock
						// so that the memory load / register write
						// has time to complete.
						cpustate[`CPULOADSTALL] <= 1'b1;
					end
					`OPCODE_STORE: begin
						rdata <= rval2;
						memaddress <= rval1 + immed;
						cpustate[`CPUSTORE] <= 1'b1;
					end
					`OPCODE_FENCE: begin
						// TODO:
						cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
					end
					`OPCODE_SYSTEM: begin
						// TODO:
						cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
					end
					`OPCODE_JALR: begin
						rdata <= PC + 32'd4;
						nextPC <= rval1 + immed;
						cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
					end
					`OPCODE_BRANCH: begin
						nextPC <= branchout == 1'b1 ? PC + immed : PC + 32'd4;
						cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
					end
					default: begin
						// This is an unhandled instruction
						cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
					end
				endcase

			end
			
			cpustate[`CPULOADSTALL]: begin
				// Stall state for memory reads
				cpustate[`CPULOADCOMPLETE] <= 1'b1;
			end

			cpustate[`CPULOADCOMPLETE]: begin
				// Read complete, handle register write-back
				unique case (func3)
					3'b000: begin // BYTE with sign extension
						unique case (memaddress[1:0])
							2'b11: begin rdata <= {{24{cpudatain[31]}},cpudatain[31:24]}; end
							2'b10: begin rdata <= {{24{cpudatain[23]}},cpudatain[23:16]}; end
							2'b01: begin rdata <= {{24{cpudatain[15]}},cpudatain[15:8]}; end
							2'b00: begin rdata <= {{24{cpudatain[7]}},cpudatain[7:0]}; end
						endcase
					end
					3'b001: begin // WORD with sign extension
						unique case (memaddress[1])
							1'b1: begin rdata <= {{16{cpudatain[31]}},cpudatain[31:16]}; end
							1'b0: begin rdata <= {{16{cpudatain[15]}},cpudatain[15:0]}; end
						endcase
					end
					3'b010: begin // DWORD
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
				registerwriteenable <= 1'b1; // We can now write back
				cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
			end

			cpustate[`CPUSTORE]: begin
				// Request write of current register data to memory
				// with appropriate write mask and data size
				unique case (func3)
					3'b000: begin // BYTE
						cpudataout <= {rdata[7:0], rdata[7:0], rdata[7:0], rdata[7:0]};
						unique case (memaddress[1:0])
							2'b11: begin cpuwriteena <= 4'b1000; end
							2'b10: begin cpuwriteena <= 4'b0100; end
							2'b01: begin cpuwriteena <= 4'b0010; end
							2'b00: begin cpuwriteena <= 4'b0001; end
						endcase
					end
					3'b001: begin // WORD
						cpudataout <= {rdata[15:0], rdata[15:0]};
						unique case (memaddress[1])
							1'b1: begin cpuwriteena <= 4'b1100; end
							1'b0: begin cpuwriteena <= 4'b0011; end
						endcase
					end
					default: begin // DWORD
						cpudataout <= rdata;
						cpuwriteena <= 4'b1111;
					end
				endcase
				cpustate[`CPURETIREINSTRUCTION] <= 1'b1;
			end

			cpustate[`CPURETIREINSTRUCTION]: begin
				// We need to turn off the
				// register write enable
				// before we fethc and decode a new
				// instruction so we don't destroy
				// any registers while rd changes
				registerwriteenable <= 1'b0;

				// Turn off memory writes in flight
				cpuwriteena <= 4'b0000;

				// Set new PC
				PC <= nextPC;
				// Full address of next instruction
				memaddress <= nextPC;
				diagnosis[0] <= 1'b1;
				cpustate[`CPUFETCH] <= 1'b1;
			end
		endcase
	end
end

endmodule
