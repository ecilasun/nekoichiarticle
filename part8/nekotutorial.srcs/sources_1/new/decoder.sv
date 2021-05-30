`timescale 1ns / 1ps

`include "cpuops.vh"
`include "aluops.vh"

module decoder(
	input [31:0] instruction,	// Raw input instruction
	output logic [6:0] opcode,	// Current instruction class
	output logic [4:0] aluop,	// Current ALU op
	output logic rwen,			// Register writes enabled
	output logic [2:0] func3,	// Sub-instruction
	output logic [6:0] func7,	// Sub-instruction
	output logic [4:0] rs1,		// Source register one
	output logic [4:0] rs2,		// Source register two
	output logic [4:0] rs3,		// Unused for now
	output logic [4:0] rd,		// Destination register
	output logic [31:0] immed,	// Unpacked immediate integer value
	output logic selectimmedasrval2 // Select rval2 or unpacked integer during EXEC
);
	
always_comb begin

	opcode = instruction[6:0];
	rs1 = instruction[19:15];
	rs2 = instruction[24:20];
	rs3 = instruction[31:27]; // Used by fused float ops
	rd = instruction[11:7];
	func3 = instruction[14:12];
	func7 = instruction[31:25];
	selectimmedasrval2 = opcode==`OPCODE_OP_IMM ? 1'b1 : 1'b0;
	
	unique case (instruction[6:0])
		`OPCODE_OP: begin
			immed = 32'd0;
			rwen = 1'b1;
			// Base integer ALU instructions
			unique case (func3)
				3'b000: aluop = func7[5] == 1'b0 ? `ALU_ADD : `ALU_SUB;
				3'b001: aluop = `ALU_SLL;
				3'b010: aluop = `ALU_SLT;
				3'b011: aluop = `ALU_SLTU;
				3'b100: aluop = `ALU_XOR;
				3'b101: aluop = func7[5] == 1'b0 ? `ALU_SRL : `ALU_SRA;
				3'b110: aluop = `ALU_OR;
				3'b111: aluop = `ALU_AND;
			endcase
		end

		`OPCODE_OP_IMM: begin
			immed = {{20{instruction[31]}},instruction[31:20]};
			rwen = 1'b1;
			unique case (func3)
				3'b000: aluop = `ALU_ADD; // NOTE: No immediate mode sub exists
				3'b001: aluop = `ALU_SLL;
				3'b010: aluop = `ALU_SLT;
				3'b011: aluop = `ALU_SLTU;
				3'b100: aluop = `ALU_XOR;
				3'b101: aluop = func7[5] == 1'b0 ? `ALU_SRL : `ALU_SRA;
				3'b110: aluop = `ALU_OR;
				3'b111: aluop = `ALU_AND;
			endcase
		end

		`OPCODE_LUI: begin
			immed = {instruction[31:12],12'd0};
			rwen = 1'b1;
			aluop = `ALU_NONE;
		end

		`OPCODE_STORE: begin
			immed = {{20{instruction[31]}},instruction[31:25],instruction[11:7]};
			rwen = 1'b0;
			aluop = `ALU_NONE;
		end

		`OPCODE_LOAD: begin
			immed = {{20{instruction[31]}},instruction[31:20]};
			rwen = 1'b1;
			aluop = `ALU_NONE;
		end

		`OPCODE_JAL: begin
			immed = {{11{instruction[31]}}, instruction[31], instruction[19:12], instruction[20], instruction[30:21], 1'b0};
			rwen = 1'b1;
			aluop = `ALU_NONE;
		end

		`OPCODE_JALR: begin
			immed = {{20{instruction[31]}},instruction[31:20]};
			rwen = 1'b1;
			aluop = `ALU_NONE;
		end

		`OPCODE_BRANCH: begin
			immed = {{19{instruction[31]}},instruction[31],instruction[7],instruction[30:25],instruction[11:8],1'b0};
			rwen = 1'b0;
			aluop = `ALU_NONE;
		end

		`OPCODE_AUPC: begin
			immed = {instruction[31:12],12'd0};
			rwen = 1'b1;
			aluop = `ALU_NONE;
		end

		`OPCODE_FENCE: begin
			immed = 32'd0;
			rwen = 1'b0;
			aluop = `ALU_NONE;
		end

		`OPCODE_SYSTEM: begin
			immed = {27'd0, instruction[19:15]};
			// Register write flag depends on func3
			rwen = (func3 == 3'b000) ? 1'b0 : 1'b1;
			aluop = `ALU_NONE;
		end

		default: begin
			immed = 32'd0;
			rwen = 1'b0;
			aluop = `ALU_NONE;
		end
	endcase

end

endmodule
