`timescale 1ns / 1ps

module nekotop(
	// Input clock
	input CLK_I,
	// Reset on lower panel, rightmost button
	input RST_I,
	// 4 monochrome LEDs
	output [3:0] led
);

clockgen myclock(
	.resetn(~RST_I),		// Incoming external reset (negated)
	.clk_in1(CLK_I),		// Input external clock
	.cpuclock(cpuclock),	// Generated CPU clock 
	.locked(clockLocked) );	// High when clock is stable

wire reset_p = RST_I | (~clockLocked);
wire reset_n = (~RST_I) & clockLocked;

wire [3:0] diagnosis;

// Full 32 bit BYTE address between CPU and RAM
wire [31:0] memaddress;
// Data wires from/to CPU to/from RAM
wire [31:0] cpudataout;
wire [31:0] cpudatain;
wire [3:0] cpuwriteena;

sysmem mymemory(
	.addra(memaddress[17:2]),	// 16 bit DWORD address
	.clka(cpuclock),			// Clock, same as CPU clock
	.dina(cpudataout),			// Data in from CPU to RAM address
	.douta(cpudatain),			// Data out from RAM address to CPU
	.ena(reset_n),				// Reads enabled only when not in reset
	.wea(cpuwriteena) );		// Write control line from CPU

riscvcpu mycpu(
	.clock(cpuclock),			// CPU clock
	.reset(reset_p),			// CPU reset line
	.diagnosis(diagnosis),		// Diagnosis output
	.memaddress(memaddress),	// Memory address to operate on
	.cpudataout(cpudataout),	// CPU data to write to external device
	.cpuwriteena(cpuwriteena),	// Write control line
	.cpudatain(cpudatain) );	// Data from external device to CPU

assign led = diagnosis;

endmodule
