`timescale 1ns / 1ps

module devicerouter(
	input uartbase,
	input cpuclock,
	input reset_p,
	input reset_n,
	input [31:0] busaddress,
	input [31:0] busdatain,
	output [31:0] busdataout,
	input [3:0] buswe,
	input busre,
	output busstall,
	output uart_rxd_out,
	input uart_txd_in );

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
//wire deviceGPUFIFOWrite		= {busaddress[31], busaddress[4:2]} == 4'b1000 ? 1'b1 : 1'b0;			// 0x80000000 Reserved for future use

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

// System memory
sysmem mymemory(
	.addra(busaddress[17:2]),									// 16 bit DWORD memory address
	.clka(cpuclock),											// Clock, same as CPU clock
	.dina(busdatain),											// Data in from CPU
	.douta(memdataout),											// Data out from RAM address to CPU
	.ena(deviceBRAM ? (reset_n & (busre | (|buswe))) : 1'b0),	// Unit enabled only when not in reset and reading or writing
	.wea(deviceBRAM ? buswe : 4'b0000) );						// Write control line from CPU

// -----------------------------------------------------------------------
// Bus traffic control and routing
// -----------------------------------------------------------------------

wire [31:0] uartdataout = {24'd0, infifoout};
wire [31:0] uartbytecountout = {22'd0, infifodatacount};
//wire [31:0] sddatawide = {24'd0, sdrq_dataout};
//wire [31:0] bus_dataout = deviceUARTRxRead ? uartdataout : (deviceUARTByteCountRead ? uartbytecountout : (deviceSPIRead ? sddatawide : (deviceDDR3 ? 32'hFFFFFFFF : memdataout)));
assign busdataout = deviceUARTRxRead ? uartdataout : (deviceUARTByteCountRead ? uartbytecountout : memdataout);

//wire gpustall = deviceGPUFIFOWrite ? gpu_fifowrfull : 1'b0;
wire uartwritestall = deviceUARTTxWrite ? outfifofull : 1'b0;
wire uartreadstall = deviceUARTRxRead ? infifoempty : 1'b0;
//wire spiwritestall = deviceSPIWrite ? sdwq_full : 1'b0;
//wire spireadstall = deviceSPIRead ? sdrq_empty : 1'b0;

assign busstall = uartwritestall | uartreadstall;// | gpustall | spiwritestall | spireadstall;

always_comb begin
	// SYSMEM r/w (0x00000000 - 0x0003FFFF)
	// This one self-selects in the System memory section
	
	// DDR3 (0x00040000 - 0x7FFFFFFF) - Reserved for future
	//ddr3_address = cpu_address;
	//ddr3_writeword = busdatain;
	//ddr3_writeena = deviceDDR3 ? cpu_writeena : 4'b0000;
	//ddr3_readena = deviceDDR3 ? cpu_readena : 0;

	// GPU FIFO - Reserved for future
	//gpu_fifocommand = busdatain; // Dword writes, no masking
	//gpu_fifowe = deviceGPUFIFOWrite ? ((~gpu_fifowrfull) & (|cpu_writeena)) : 1'b0;

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
