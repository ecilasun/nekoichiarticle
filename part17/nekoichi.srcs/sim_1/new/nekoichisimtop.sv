`timescale 1ns / 1ps

module nekoichisimtop( );

// parameter SIMULATION = "TRUE";

logic clk;
logic reset;

wire uart_rxd_out;
logic uart_txd_in = 1'b0;

wire tx_mclk, tx_lrck, tx_sclk, tx_sdout;

// Startup
initial begin
	clk = 1'b0;
	reset = 1'b1;
	#25 reset = 1'b0;
	$display("NekoIchi device startup (post-reset)");
end

wire ddr3_reset_n;
wire [0:0]   ddr3_cke;
wire [0:0]   ddr3_ck_p; 
wire [0:0]   ddr3_ck_n;
wire [0:0]   ddr3_cs_n;
wire ddr3_ras_n; 
wire ddr3_cas_n;
wire ddr3_we_n;
wire [2:0]   ddr3_ba;
wire [13:0]  ddr3_addr;
wire [0:0]   ddr3_odt;
wire [1:0]   ddr3_dm;
wire [1:0]   ddr3_dqs_p;
wire [1:0]   ddr3_dqs_n;
wire [15:0]  ddr3_dq;

ddr3_model ddr3simmod(
    .rst_n(ddr3_reset_n),
    .ck(ddr3_ck_p),
    .ck_n(ddr3_ck_n),
    .cke(ddr3_cke),
    .cs_n(ddr3_cs_n),
    .ras_n(ddr3_ras_n),
    .cas_n(ddr3_cas_n),
    .we_n(ddr3_we_n),
    .dm_tdqs(ddr3_dm),
    .ba(ddr3_ba),
    .addr(ddr3_addr),
    .dq(ddr3_dq),
    .dqs(ddr3_dqs_p),
    .dqs_n(ddr3_dqs_n),
    .tdqs_n(), // out
    .odt(ddr3_odt) );

// Top module simulation instance
nekotop simtop(
	.CLK_I(clk),
	.RST_I(reset),

	.uart_rxd_out(uart_rxd_out),
	.uart_txd_in(uart_txd_in),

    .ddr3_reset_n(ddr3_reset_n),	// TODO: Tie the DDR3 sim code here
    .ddr3_cke(ddr3_cke),
    .ddr3_ck_p(ddr3_ck_p),  // -
    .ddr3_ck_n(ddr3_ck_n),
    .ddr3_cs_n(ddr3_cs_n),
    .ddr3_ras_n(ddr3_ras_n), 
    .ddr3_cas_n(ddr3_cas_n), 
    .ddr3_we_n(ddr3_we_n),
    .ddr3_ba(ddr3_ba),
    .ddr3_addr(ddr3_addr),
    .ddr3_odt(ddr3_odt),
    .ddr3_dm(ddr3_dm), // -
    .ddr3_dqs_p(ddr3_dqs_p), // -
    .ddr3_dqs_n(ddr3_dqs_n),
    .ddr3_dq(ddr3_dq),

	.switches(4'b0000),	// No switch set
	.buttons(3'b000),	// No button held down

	.spi_cs_n(),
	.spi_mosi(),
	.spi_miso(),
	.spi_sck(),
	.spi_cd(1'b1),		// 1: No card

    .tx_mclk(tx_mclk),	// Audio output is ignored in simulation
    .tx_lrck(tx_lrck),
    .tx_sclk(tx_sclk),
    .tx_sdout(tx_sdout),

	.DVI_R(),			// Video output is ignored in simulation
	.DVI_G(),
	.DVI_B(),
	.DVI_HS(),
	.DVI_VS(),
	.DVI_DE(),
	.DVI_CLK() );

// Feed a 100Mhz external clock to top module
always begin
	#5 clk = ~clk;
end

endmodule
