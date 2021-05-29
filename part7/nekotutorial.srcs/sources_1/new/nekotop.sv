`timescale 1ns / 1ps

module nekotop(
	// Input clock
	input CLK_I,
	// Reset on lower panel, rightmost button
	input RST_I,
	// 4 monochrome LEDs
	output [3:0] led
);

wire [3:0] diagnosis;

// 10 bit byte-address wire between CPU and RAM
wire [9:0] memaddress;
// Data wires from/to CPU to/from RAM
wire [31:0] cpudataout;
wire [31:0] cpudatain;

sysmem mymemory(
	.addra(memaddress),	// 10 bit DWORD aligned address
	.clka(CLK_I),		// Clock, same as CPU clock
	.dina(cpudataout),	// Data in from CPU to RAM address
	.douta(cpudatain),	// Data out from RAM address to CPU
	.ena(1'b1),			// Reads are always enabled for now
	.wea(4'b0000) );	// Byte select mask for writes, no writes when 0000

riscvcpu mycpu(
	.clock(CLK_I),
	.reset(RST_I),
	.diagnosis(diagnosis),
	.memaddress(memaddress),
	.cpudataout(cpudataout),
	.cpudatain(cpudatain) );

assign led = diagnosis;

endmodule
