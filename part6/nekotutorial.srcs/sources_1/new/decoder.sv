`timescale 1ns / 1ps

`include "cpuops.vh"

module decoder(
	input [31:0] instruction,
	output logic [6:0] opcode,
	output logic [2:0] func3,
	output logic [6:0] func7,
	output logic [4:0] rs1,
	output logic [4:0] rs2,
	output logic [4:0] rs3,
	output logic [4:0] rd,
	output logic [31:0] immed,
	output logic selectimmedasrval2 );
	
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
		end
		`OPCODE_OP_IMM: begin
			immed = {{20{instruction[31]}},instruction[31:20]};
		end
		`OPCODE_LUI: begin
			immed = {instruction[31:12],12'd0};
		end
		`OPCODE_STORE: begin
			immed = {{20{instruction[31]}},instruction[31:25],instruction[11:7]};
		end
		`OPCODE_LOAD: begin
			immed = {{20{instruction[31]}},instruction[31:20]};
		end
		`OPCODE_JAL: begin
			immed = {{11{instruction[31]}}, instruction[31], instruction[19:12], instruction[20], instruction[30:21], 1'b0};
		end
		`OPCODE_JALR: begin
			immed = {{20{instruction[31]}},instruction[31:20]};
		end
		`OPCODE_BRANCH: begin
			immed = {{19{instruction[31]}},instruction[31],instruction[7],instruction[30:25],instruction[11:8],1'b0};
		end
		`OPCODE_AUPC: begin
			immed = {instruction[31:12],12'd0};
		end
		`OPCODE_FENCE: begin
			immed = 32'd0;
		end
		`OPCODE_SYSTEM: begin
			immed = {27'd0, instruction[19:15]};
		end
		default: begin
			immed = 32'd0;
		end
	endcase

end

endmodule
