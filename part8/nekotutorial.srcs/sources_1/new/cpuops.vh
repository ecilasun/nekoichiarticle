// ======================== CPU States ==========================

// Number of bits for the one-hot encoded CPU state
`define CPUSTAGECOUNT           4

// Bit indices for one-hot encoded CPU state
`define CPUFETCH				0
`define CPUDECODE				1
`define CPUEXEC					2
`define CPURETIREINSTRUCTION	3

`define CPUSTAGEMASK_NONE				0

`define CPUSTAGEMASK_FETCH				1
`define CPUSTAGEMASK_DECODE				2
`define CPUSTAGEMASK_EXEC				4
`define CPUSTAGEMASK_RETIREINSTRUCTION	8

// ===================== INSTUCTION GROUPS ======================
`define OPCODE_OP_IMM 	    7'b0010011
`define OPCODE_OP		    7'b0110011
`define OPCODE_LUI		    7'b0110111
`define OPCODE_STORE	    7'b0100011
`define OPCODE_LOAD		    7'b0000011
`define OPCODE_JAL		    7'b1101111
`define OPCODE_JALR		    7'b1100111
`define OPCODE_BRANCH	    7'b1100011
`define OPCODE_AUPC		    7'b0010111
`define OPCODE_FENCE	    7'b0001111
`define OPCODE_SYSTEM	    7'b1110011
// ==============================================================

// =================== INSTRUCTION SUBGROUPS ====================
`define F3_BEQ		3'b000
`define F3_BNE		3'b001
`define F3_BLT		3'b100
`define F3_BGE		3'b101
`define F3_BLTU		3'b110
`define F3_BGEU		3'b111

`define F3_ADD		3'b000
`define F3_SLL		3'b001
`define F3_SLT		3'b010
`define F3_SLTU		3'b011
`define F3_XOR		3'b100
`define F3_SR		3'b101
`define F3_OR		3'b110
`define F3_AND		3'b111

`define F3_MUL		3'b000
`define F3_MULH		3'b001
`define F3_MULHSU	3'b010
`define F3_MULHU	3'b011
`define F3_DIV		3'b100
`define F3_DIVU		3'b101
`define F3_REM		3'b110
`define F3_REMU		3'b111

`define F3_LB		3'b000
`define F3_LH		3'b001
`define F3_LW		3'b010
`define F3_LBU		3'b100
`define F3_LHU		3'b101

`define F3_SB		3'b000
`define F3_SH		3'b001
`define F3_SW		3'b010
// ==============================================================
