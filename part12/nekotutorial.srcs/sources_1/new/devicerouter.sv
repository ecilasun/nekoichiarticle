`timescale 1ns / 1ps

module devicerouter(
	input uartbase,
	input cpuclock,
	input gpuclock,
	input vgaclock,
	input reset_p,
	input reset_n,
	input [31:0] busaddress,
	input [31:0] busdatain,
	output [31:0] busdataout,
	input [3:0] buswe,
	input busre,
	output busstall,
	output uart_rxd_out,
	input uart_txd_in,
	output [3:0] DVI_R,
	output [3:0] DVI_G,
	output [3:0] DVI_B,
	output DVI_HS,
	output DVI_VS,
	output DVI_DE,
	output DVI_CLK );

// -----------------------------------------------------------------------
// Device selection
// -----------------------------------------------------------------------

wire deviceBRAM					= (busaddress[31]==1'b0) & (busaddress < 32'h00040000) ? 1'b1 : 1'b0;	// 0x00000000 - 0x0003FFFF
//wire deviceDDR3				= (busaddress[31]==1'b0) & (busaddress >= 32'h00040000) ? 1'b1 : 1'b0;	// 0x00040000 - 0x7FFFFFFF 
//wire deviceOtherWrite			= {busaddress[31], busaddress[4:2]} == 4'b1111 ? 1'b1 : 1'b0;			// 0x8000001C Reserved for future use
//wire deviceOtherRead			= {busaddress[31], busaddress[4:2]} == 4'b1110 ? 1'b1 : 1'b0;			// 0x80000018 Reserved for future use
//wire deviceSPIWrite			= {busaddress[31], busaddress[4:2]} == 4'b1101 ? 1'b1 : 1'b0;			// 0x80000014 Reserved for future use
//wire deviceSPIRead			= {busaddress[31], busaddress[4:2]} == 4'b1100 ? 1'b1 : 1'b0;			// 0x80000010 Reserved for future use
wire deviceUARTTxWrite			= {busaddress[31], busaddress[4:2]} == 4'b1011 ? 1'b1 : 1'b0;			// 0x8000000C UART write port
wire deviceUARTRxRead			= {busaddress[31], busaddress[4:2]} == 4'b1010 ? 1'b1 : 1'b0;			// 0x80000008 UART read port
wire deviceUARTByteCountRead	= {busaddress[31], busaddress[4:2]} == 4'b1001 ? 1'b1 : 1'b0;			// 0x80000004 UART incoming queue byte count
wire deviceGPUFIFOWrite			= {busaddress[31], busaddress[4:2]} == 4'b1000 ? 1'b1 : 1'b0;			// 0x80000000 GPU command queue

// -----------------------------------------------------------------------
// Device : UART
// Serial communications at 115200bps
// -----------------------------------------------------------------------

// Transmitter (CPU -> FIFO -> Tx)

wire [9:0] outfifodatacount;
wire [7:0] outfifoout;
wire uarttxbusy, outfifofull, outfifoempty, outfifovalid;
logic [7:0] datatotransmit = 8'h00;
logic [7:0] outfifoin; // This will create a latch since it keeps its value
logic transmitbyte = 1'b0;
logic txstate = 1'b0;
logic outuartfifowe = 1'b0;
logic outfifore = 1'b0;

async_transmitter UART_transmit(
	.clk(uartbase),
	.TxD_start(transmitbyte),
	.TxD_data(datatotransmit),
	.TxD(uart_rxd_out),
	.TxD_busy(uarttxbusy) );

// Output FIFO
uartfifo UART_out_fifo(
    // In
    .full(outfifofull),
    .din(outfifoin),		// Data latched from CPU
    .wr_en(outuartfifowe),	// CPU controls write, high for one clock
    // Out
    .empty(outfifoempty),	// Nothing to read
    .dout(outfifoout),		// To transmitter
    .rd_en(outfifore),		// Transmitter can send
    .wr_clk(cpuclock),		// CPU write clock
    .rd_clk(uartbase),		// Transmitter clock runs much slower
    .valid(outfifovalid),	// Read result valid
    // Ctl
    .rst(reset_p),
    .rd_data_count(outfifodatacount) );

// Fifo output serializer
always @(posedge(uartbase)) begin
	if (txstate == 1'b0) begin // IDLE_STATE
		if (~uarttxbusy & (transmitbyte == 1'b0)) begin // Safe to attempt send, UART not busy or triggered
			if (~outfifoempty) begin // Something in FIFO? Trigger read and go to transmit 
				outfifore <= 1'b1;			
				txstate <= 1'b1;
			end else begin
				outfifore <= 1'b0;
				txstate <= 1'b0; // Stay in idle state
			end
		end else begin // Transmit hardware busy or we kicked a transmit (should end next clock)
			outfifore <= 1'b0;
			txstate <= 1'b0; // Stay in idle state
		end
		transmitbyte <= 1'b0;
	end else begin // TRANSMIT_STATE
		outfifore <= 1'b0; // Stop read request
		if (outfifovalid) begin // Kick send and go to idle
			datatotransmit <= outfifoout;
			transmitbyte <= 1'b1;
			txstate <= 1'b0;
		end else begin
			txstate <= 1'b1; // Stay in transmit state and wait for valid fifo data
		end
	end
end

// Receiver (Rx -> FIFO -> CPU)

wire [9:0] infifodatacount;
wire [7:0] infifoout, uartbytein;
wire infifofull, infifoempty, infifovalid, uartbyteavailable;
logic [7:0] inuartbyte;
logic infifowe = 1'b0;

async_receiver UART_receive(
	.clk(uartbase),
	.RxD(uart_txd_in),
	.RxD_data_ready(uartbyteavailable),
	.RxD_data(uartbytein),
	.RxD_idle(),
	.RxD_endofpacket() );

// Input FIFO
uartfifo UART_in_fifo(
    // In
    .full(infifofull),
    .din(inuartbyte),
    .wr_en(infifowe),
    // Out
    .empty(infifoempty),
    .dout(infifoout),
    .rd_en(busre & deviceUARTRxRead),
    .wr_clk(uartbase),
    .rd_clk(cpuclock),
    .valid(infifovalid),
    // Ctl
    .rst(reset_p),
    .rd_data_count(infifodatacount) );

// Fifo input control
always @(posedge(uartbase)) begin
	if (uartbyteavailable) begin
		infifowe <= 1'b1;
		inuartbyte <= uartbytein;
	end else begin
		infifowe <= 1'b0;
	end
end

// -----------------------------------------------------------------------
// System memory
// -----------------------------------------------------------------------

wire [31:0] memdataout;
wire [31:0] dmaaddress;
wire [31:0] dmadatain;
wire [31:0] dmadataout;
wire [3:0] dmawe;

// System memory
sysmem mymemory(
	// CPU direct access port
	.addra(busaddress[17:2]),									// 16 bit DWORD memory address
	.clka(cpuclock),											// Synchronized to CPU clock
	.dina(busdatain),											// Data in from CPU
	.douta(memdataout),											// Data out from RAM address to CPU
	.wea(deviceBRAM ? buswe : 4'b0000),							// Write control line from CPU
	.ena(deviceBRAM ? (reset_n & (busre | (|buswe))) : 1'b0),	// Unit enabled only when not in reset and reading or writing
	// GPU DMA port
	.addrb(dmaaddress[17:2]),									// 16 bit DWORD GPU address
	.clkb(gpuclock),											// Synchronized to GPU clock
	.dinb(dmadatain),											// Data from GPU
	.doutb(dmadataout),											// Data to GPU
	.web(dmawe),												// GPU write control line
	.enb(reset_n) );											// Reads are always enabled for GPU when not in reset
	
// -----------------------------------------------------------------------
// GPU
// -----------------------------------------------------------------------

wire [31:0] gpu_fifodataout;
wire gpu_fifowrfull;
wire gpu_fifordempty;
wire gpu_fifodatavalid;
wire gpu_fifore;
wire videopage;

logic [31:0] gpu_fifocommand;
logic [31:0] vsync_signal = 32'd0;
logic gpu_fifowe;

wire [13:0] gpuwriteaddress;
wire [3:0] gpuwriteena;
wire [31:0] gpuwriteword;
wire [11:0] gpulanewritemask;

GPU rv32gpu(
	.clock(gpuclock),					// GPU clock
	.reset(reset_p),					// Reset line
	.vsync(vsync_signal),				// Input from vsync FIFO
	.videopage(videopage),				// Video page select line
	// FIFO control
	.fifoempty(gpu_fifordempty),
	.fifodout(gpu_fifodataout),
	.fifdoutvalid(gpu_fifodatavalid),
	.fiford_en(gpu_fifore),
	// VRAM output
	.vramaddress(gpuwriteaddress),		// VRAM write address
	.vramwe(gpuwriteena),				// VRAM write enable line
	.vramwriteword(gpuwriteword),		// Data to write to VRAM
	.lanemask(gpulanewritemask),		// Video memory lane force enable mask
	// SYSMEM input/output 
	.dmaaddress(dmaaddress),			// DMA memory address in SYSMEM
	.dmawriteword(dmadatain),			// Input to DMA channel of SYSMEM
	.dma_data(dmadataout),				// Output from DMA channel of SYSMEM
	.dmawe(dmawe) );					// DMA write control

// -----------------------------------------------------------------------
// GPU FIFO
// -----------------------------------------------------------------------

gpufifo GPUCommands(
	// Write
	.full(gpu_fifowrfull),
	.din(gpu_fifocommand),
	.wr_en(gpu_fifowe),
	// Read
	.empty(gpu_fifordempty),
	.dout(gpu_fifodataout),
	.rd_en(gpu_fifore),
	// Control
	.wr_clk(cpuclock),
	.rd_clk(gpuclock),
	.rst(reset_p),
	.valid(gpu_fifodatavalid) );

// -----------------------------------------------------------------------
// DVI
// -----------------------------------------------------------------------

wire [11:0] video_x;
wire [11:0] video_y;

wire [3:0] VIDEO_R_ONE;
wire [3:0] VIDEO_G_ONE;
wire [3:0] VIDEO_B_ONE;
wire [3:0] VIDEO_R_TWO;
wire [3:0] VIDEO_G_TWO;
wire [3:0] VIDEO_B_TWO;
wire inDisplayWindowA, inDisplayWindowB;

VideoControllerGen VideoUnitA(
	.gpuclock(gpuclock),
	.vgaclock(vgaclock),
	.reset_n(reset_n),
	.writesenabled(videopage),
	.video_x(video_x),
	.video_y(video_y),
	// Wire input
	.memaddress(gpuwriteaddress),
	.mem_writeena(gpuwriteena),
	.writeword(gpuwriteword),
	.lanemask(gpulanewritemask),
	// Video output
	.red(VIDEO_R_ONE),
	.green(VIDEO_G_ONE),
	.blue(VIDEO_B_ONE),
	.inDisplayWindow(inDisplayWindowA) );

VideoControllerGen VideoUnitB(
	.gpuclock(gpuclock),
	.vgaclock(vgaclock),
	.reset_n(reset_n),
	.writesenabled(~videopage),
	.video_x(video_x),
	.video_y(video_y),
	// Wire input
	.memaddress(gpuwriteaddress),
	.mem_writeena(gpuwriteena),
	.writeword(gpuwriteword),
	.lanemask(gpulanewritemask),
	// Video output
	.red(VIDEO_R_TWO),
	.green(VIDEO_G_TWO),
	.blue(VIDEO_B_TWO),
	.inDisplayWindow(inDisplayWindowB) );

wire vsync_we;
logic [31:0] vsynccounter;

wire inDisplayWindow = videopage == 1'b0 ? inDisplayWindowA : inDisplayWindowB;
assign DVI_DE = inDisplayWindow;
assign DVI_R = inDisplayWindow ? (videopage == 1'b0 ? VIDEO_R_ONE : VIDEO_R_TWO) : 1'b0;
assign DVI_G = inDisplayWindow ? (videopage == 1'b0 ? VIDEO_G_ONE : VIDEO_G_TWO) : 1'b0;
assign DVI_B = inDisplayWindow ? (videopage == 1'b0 ? VIDEO_B_ONE : VIDEO_B_TWO) : 1'b0;
assign DVI_CLK = vgaclock;

vgatimer VideoScanout(
		.rst_i(reset_p),
		.clk_i(vgaclock),
        .hsync_o(DVI_HS),
        .vsync_o(DVI_VS),
        .counter_x(video_x),
        .counter_y(video_y),
        .vsynctrigger_o(vsync_we),
        .vsynccounter(vsynccounter) );

// -----------------------------------------------------------------------
// Domain crossing Vsync
// -----------------------------------------------------------------------

wire [31:0] vsync_fastdomain;
wire vsyncfifoempty;
wire vsyncfifofull;
wire vsyncfifovalid;

logic vsync_re;
DomainCrossSignalFifo GPUVGAVSyncQueue(
	.full(vsyncfifofull),
	.din(vsynccounter),
	.wr_en(vsync_we),
	.empty(vsyncfifoempty),
	.dout(vsync_fastdomain),
	.rd_en(vsync_re),
	.wr_clk(vgaclock),
	.rd_clk(gpuclock),
	.rst(reset_p),
	.valid(vsyncfifovalid) );

// Drain the vsync fifo and set vsync signal for the GPU every time we find one
always @(posedge gpuclock) begin
	vsync_re <= 1'b0;
	if (~vsyncfifoempty) begin
		vsync_re <= 1'b1;
	end
	if (vsyncfifovalid) begin
		vsync_signal <= vsync_fastdomain;
	end
end

// -----------------------------------------------------------------------
// Bus traffic control and routing
// -----------------------------------------------------------------------

wire [31:0] uartdataout = {24'd0, infifoout};
wire [31:0] uartbytecountout = {22'd0, infifodatacount};
//wire [31:0] sddatawide = {24'd0, sdrq_dataout};
//wire [31:0] bus_dataout = deviceUARTRxRead ? uartdataout : (deviceUARTByteCountRead ? uartbytecountout : (deviceSPIRead ? sddatawide : (deviceDDR3 ? 32'hFFFFFFFF : memdataout)));
assign busdataout = deviceUARTRxRead ? uartdataout : (deviceUARTByteCountRead ? uartbytecountout : memdataout);

wire gpustall = deviceGPUFIFOWrite ? gpu_fifowrfull : 1'b0;
wire uartwritestall = deviceUARTTxWrite ? outfifofull : 1'b0;
wire uartreadstall = deviceUARTRxRead ? infifoempty : 1'b0;
//wire spiwritestall = deviceSPIWrite ? sdwq_full : 1'b0;
//wire spireadstall = deviceSPIRead ? sdrq_empty : 1'b0;

assign busstall = uartwritestall | uartreadstall | gpustall;// | spiwritestall | spireadstall;

always_comb begin
	// SYSMEM r/w (0x00000000 - 0x0003FFFF)
	// This one self-selects in the System memory section
	
	// DDR3 (0x00040000 - 0x7FFFFFFF) - Reserved for future
	//ddr3_address = cpu_address;
	//ddr3_writeword = busdatain;
	//ddr3_writeena = deviceDDR3 ? cpu_writeena : 4'b0000;
	//ddr3_readena = deviceDDR3 ? cpu_readena : 0;

	// GPU command fifo write control
	gpu_fifocommand = busdatain; // DWORD writes only, no byte masking
	gpu_fifowe = deviceGPUFIFOWrite ? ((~gpu_fifowrfull) & (|buswe)) : 1'b0;

	// UART (receive)
	// This one self-selects in the UART device

	// SPI (receive) - Reserved for future
	//sdrq_re = (deviceSPIRead & (~sdrq_empty)) ? cpu_readena : 1'b0;

	// UART (transmit)
	case (buswe)
		4'b1000: begin outfifoin = busdatain[31:24]; end
		4'b0100: begin outfifoin = busdatain[23:16]; end
		4'b0010: begin outfifoin = busdatain[15:8]; end
		4'b0001: begin outfifoin = busdatain[7:0]; end
	endcase
	outuartfifowe = deviceUARTTxWrite ? ((~outfifofull) & (|buswe)) : 1'b0;

	// SPI (transmit) - Reserved for future
	/*case (cpu_writeena)
		4'b1000: begin sdwq_datain = busdatain[31:24]; end
		4'b0100: begin sdwq_datain = busdatain[23:16]; end
		4'b0010: begin sdwq_datain = busdatain[15:8]; end
		4'b0001: begin sdwq_datain = busdatain[7:0]; end
	endcase
	sdwq_we = deviceSPIWrite ? ((~sdwq_full) & (|buswe)) : 1'b0;*/
end

endmodule
