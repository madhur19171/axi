/*

Copyright (c) 2023 Madhur Kumar

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: System Verilog

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * AXI4 DMA
 */
module axi_dma_lite_config #
(
	parameter AXI_CONFIG_BASE_ADDR = 64'h50000000,
	// Width of AXI data bus in bits
	parameter AXI_DATA_WIDTH = 32,
	// Width of AXI address bus in bits
	parameter AXI_ADDR_WIDTH = 16,
	// Width of AXI wstrb (width of data bus in words)
	parameter AXI_STRB_WIDTH = (AXI_DATA_WIDTH/8),
	// Width of AXI ID signal
	parameter AXI_ID_WIDTH = 8,
	// Maximum AXI burst length to generate
	parameter AXI_MAX_BURST_LEN = 16,
	// Width of AXI stream interfaces in bits
	parameter AXIS_DATA_WIDTH = AXI_DATA_WIDTH,
	// Use AXI stream tkeep signal
	parameter AXIS_KEEP_ENABLE = (AXIS_DATA_WIDTH>8),
	// AXI stream tkeep signal width (words per cycle)
	parameter AXIS_KEEP_WIDTH = (AXIS_DATA_WIDTH/8),
	// Use AXI stream tlast signal
	parameter AXIS_LAST_ENABLE = 1,
	// Propagate AXI stream tid signal
	parameter AXIS_ID_ENABLE = 0,
	// AXI stream tid signal width
	parameter AXIS_ID_WIDTH = 8,
	// Propagate AXI stream tdest signal
	parameter AXIS_DEST_ENABLE = 0,
	// AXI stream tdest signal width
	parameter AXIS_DEST_WIDTH = 8,
	// Propagate AXI stream tuser signal
	parameter AXIS_USER_ENABLE = 0,
	// AXI stream tuser signal width
	parameter AXIS_USER_WIDTH = 1,
	// Width of length field
	parameter LEN_WIDTH = 20,
	// Width of tag field
	parameter TAG_WIDTH = 8,
	// Enable support for scatter/gather DMA
	// (multiple descriptors per AXI stream frame)
	parameter ENABLE_SG = 0,
	// Enable support for unaligned transfers
	parameter ENABLE_UNALIGNED = 0
)
(
	input  wire                       clk,
	input  wire                       rst,

	// AXI-Lite slave port to configure the DMA
	AXI_LITE.Slave                    config_slave,

	// AXI-4 Interface to communicate with the Memory
	AXI_BUS.Master                    master,

	// Master Stream Interface
	output [AXI_DATA_WIDTH - 1 : 0]   axis_master_data,
	output                            axis_master_valid,
	output                            axis_master_last,
	input                             axis_master_ready,

	// Slave Stream Interface
	input [AXI_DATA_WIDTH - 1 : 0]    axis_slave_data,
	input                             axis_slave_valid,
	input                             axis_slave_last,
	output                            axis_slave_ready,

	/*
	 * Configuration
	 */
	input  wire                       read_enable,
	input  wire                       write_enable,
	input  wire                       write_abort
);

	/*  Configuration Registers:
			Register 0: Read Address    
			Register 1: Read Length     
			Register 2: Read Status     

			Register 3: Write Address   
			Register 4: Write Length    
			Register 5: Write Status  

			Read is same as DMA to Device	(Reads from Memory and sends to Stream)
			Write is same as Device to DMA  (Reads from Stream and Writes to Memory)
	*/

	localparam DMA_BUSY = 2'b01;
	localparam DMA_ERR  = 2'b10;
	localparam DMA_DONE = 2'b11;

	localparam WORD_LENGTH = AXI_DATA_WIDTH / 8; // Number of words in Data

	localparam READ_ADDRESS_OFFSET  =       0;
	localparam READ_LENGTH_OFFSET   =       WORD_LENGTH;
	localparam READ_STATUS_OFFSET   =       2 * WORD_LENGTH;

	localparam WRITE_ADDRESS_OFFSET =       3 * WORD_LENGTH;
	localparam WRITE_LENGTH_OFFSET  =       4 * WORD_LENGTH;
	localparam WRITE_STATUS_OFFSET  =       5 * WORD_LENGTH;
	

	// AXI read descriptor input
	logic [AXI_ADDR_WIDTH-1:0]  s_axis_read_desc_addr = 0;
	logic [LEN_WIDTH-1:0]       s_axis_read_desc_len = 0;
	logic [TAG_WIDTH-1:0]       s_axis_read_desc_tag = 0;
	logic [AXIS_ID_WIDTH-1:0]   s_axis_read_desc_id = 0;
	logic [AXIS_DEST_WIDTH-1:0] s_axis_read_desc_dest = 0;
	logic [AXIS_USER_WIDTH-1:0] s_axis_read_desc_user = 0;
	logic                       s_axis_read_desc_valid = 0;
	wire                        s_axis_read_desc_ready;

	// AXI read descriptor status output
	wire [TAG_WIDTH-1:0]       m_axis_read_desc_status_tag;
	wire [3:0]                 m_axis_read_desc_status_error;
	wire                       m_axis_read_desc_status_valid;

	// AXI write descriptor input
	logic [AXI_ADDR_WIDTH-1:0]  s_axis_write_desc_addr = 0;
	logic [LEN_WIDTH-1:0]       s_axis_write_desc_len = 0;
	logic [TAG_WIDTH-1:0]       s_axis_write_desc_tag = 0;
	logic                       s_axis_write_desc_valid = 0;
	wire                        s_axis_write_desc_ready;
	
	// AXI write descriptor status output
	wire [LEN_WIDTH-1:0]       m_axis_write_desc_status_len;
	wire [TAG_WIDTH-1:0]       m_axis_write_desc_status_tag;
	wire [AXIS_ID_WIDTH-1:0]   m_axis_write_desc_status_id;
	wire [AXIS_DEST_WIDTH-1:0] m_axis_write_desc_status_dest;
	wire [AXIS_USER_WIDTH-1:0] m_axis_write_desc_status_user;
	wire [3:0]                 m_axis_write_desc_status_error;
	wire                       m_axis_write_desc_status_valid;

	// Controller logic
	logic received_write_request;
	logic [AXI_ADDR_WIDTH - 1 : 0] write_request_address;

	logic received_read_request;
	logic [AXI_ADDR_WIDTH - 1 : 0] read_request_address;

	logic [1 : 0] 	read_status;		// Latest Status of the read descriptor of DMA
	logic 			read_status_valid;	// Is the read status currently valid or not
	logic			read_status_accessed;	// Asserted when the Read Status address is read
	logic [1 : 0] 	write_status;		// Latest Status of the write descriptor of DMA
	logic 			write_status_valid;	// Is the write status currently valid or not
	logic			write_status_accessed;	// Asserted when the Write Status address is read

	always_comb begin
		// TODO: Currently, assume that the Lite port is always ready
		config_slave.aw_ready = 1;
		config_slave.w_ready = 1;
		config_slave.ar_ready = 1;
	end

	// Logic to record a Configuration to do a DMA to Device transfer(Read)
	always_ff @(posedge clk) begin
		if(rst) begin
			received_read_request <= 0;
			read_request_address <= 0;
		end 
		else if(config_slave.w_valid & config_slave.w_ready & received_read_request) begin
			received_read_request <= 0;
		end
		else if(
					config_slave.aw_valid & 
					config_slave.aw_ready & 
					(
					 config_slave.aw_addr == (AXI_CONFIG_BASE_ADDR + READ_ADDRESS_OFFSET) |
					 config_slave.aw_addr == (AXI_CONFIG_BASE_ADDR + READ_LENGTH_OFFSET)
					) & 
					~received_read_request) begin
			received_read_request <= 1;
			read_request_address <= config_slave.aw_addr;
		end
	end

	// Logic to record a Configuration to do a Device to DMA transfer(Write)
	always_ff @(posedge clk) begin
		if(rst) begin
			received_write_request <= 0;
			write_request_address <= 0;
		end 
		else if(config_slave.w_valid & config_slave.w_ready & received_write_request) begin
			received_write_request <= 0;
		end
		else if(
					config_slave.aw_valid & 
					config_slave.aw_ready & 
					(
					 config_slave.aw_addr == (AXI_CONFIG_BASE_ADDR + WRITE_ADDRESS_OFFSET) |
					 config_slave.aw_addr == (AXI_CONFIG_BASE_ADDR + WRITE_LENGTH_OFFSET)
					) & 
					~received_write_request) begin
			received_write_request <= 1;
			write_request_address <= config_slave.aw_addr;
		end
	end

	// Writing to Read Config channel
	always_ff @(posedge clk) begin
		if(rst) begin
			s_axis_read_desc_addr <= 0;
			s_axis_read_desc_len <= 0;
			s_axis_read_desc_valid <= 0;
		end 
		else if(config_slave.w_valid & config_slave.w_ready & received_read_request) begin
			case(read_request_address)

				(AXI_CONFIG_BASE_ADDR + READ_ADDRESS_OFFSET) : begin
					$display("Written to Read Address Register: 0x%0x", config_slave.w_data);
					s_axis_read_desc_addr <= config_slave.w_data;
				end

				(AXI_CONFIG_BASE_ADDR + READ_LENGTH_OFFSET) : begin
					$display("Written to Read Length Register: %0d", config_slave.w_data);
					s_axis_read_desc_len <= config_slave.w_data;
					s_axis_read_desc_valid <= 1;
				end

				default :  begin
					s_axis_read_desc_addr <= 0;
					s_axis_read_desc_len <= 0;
					s_axis_read_desc_valid <= 0;
				end 
			endcase
		end

		if(s_axis_read_desc_valid & s_axis_read_desc_ready)
			s_axis_read_desc_valid <= 0;

	end


	// Writing to Write Config channel
	always_ff @(posedge clk) begin
		if(rst) begin
			s_axis_write_desc_addr <= 0;
			s_axis_write_desc_len <= 0;
			s_axis_write_desc_valid <= 0;
		end 
		else if(config_slave.w_valid & config_slave.w_ready & received_write_request) begin
			case(write_request_address)

				(AXI_CONFIG_BASE_ADDR + WRITE_ADDRESS_OFFSET) : begin
					$display("Written to Write Address Register: 0x%0x", config_slave.w_data);
					s_axis_write_desc_addr <= config_slave.w_data;
				end

				(AXI_CONFIG_BASE_ADDR + WRITE_LENGTH_OFFSET) : begin
					$display("Written to Write Length Register: %0d", config_slave.w_data);
					s_axis_write_desc_len <= config_slave.w_data;
					s_axis_write_desc_valid <= 1;
				end

				default :  begin
					s_axis_write_desc_addr <= 0;
					s_axis_write_desc_len <= 0;
					s_axis_write_desc_valid <= 0;
				end 
			endcase
		end

		if(s_axis_write_desc_valid & s_axis_write_desc_ready)
			s_axis_write_desc_valid <= 0;
	end

	// Generating Write Response
	always_ff @(posedge clk) begin
		if(rst) begin
			config_slave.b_valid <= 0;
			config_slave.b_resp <= 0;	// OKAY
		end

		else if(config_slave.b_valid & config_slave.b_ready) begin
			config_slave.b_valid <= 0;
		end

		else if(config_slave.w_valid & config_slave.w_ready) begin
			config_slave.b_valid <= 1;
		end
	end

	// Reading from Status Descriptors

	/* Constraint:
			There is a constraint that once the DMA is configured to do a transfer,
			the status descriptor channel must be read till the DMA becomes idle again.
			Post becoming idle and reading the Status Descriptor, the DMA can be
			configured again.

			This constraint holds true for both read and write
			Before initiating a new read or write, the current read or write
			should be finidhed with its corresponding descriptor read.

			This constraint is because we are not using the tag fields of the status descriptor

			TODO: Remove this constraint to allow backpressure just like Xilinx
					Otherwise there will be stalls if the data transfer length is 
					greater than the buffers available
	*/

	// read_status:
	always_ff @(posedge clk) begin
		if(rst) begin
			read_status			<= 0;		
			read_status_valid	<= 0;
		end
		
		else if(m_axis_read_desc_status_valid) begin
			read_status			<= m_axis_read_desc_status_error;		
			read_status_valid	<= 1;
		end

		else if(config_slave.r_valid & config_slave.r_ready & read_status_accessed) begin
			read_status_valid	<= 0;
		end
	end

	// write status:
	always_ff @(posedge clk) begin
		if(rst) begin
			write_status		<= 0;		
			write_status_valid	<= 0;
		end

		else if(m_axis_write_desc_status_valid) begin
			write_status		<= m_axis_write_desc_status_error;		
			write_status_valid	<= 1;
		end

		else if(config_slave.r_valid & config_slave.r_ready & write_status_accessed) begin
			write_status_valid	<= 0;
		end
	end


	// TODO: Avoid problem with consecutive reads of status registers for reads and writes
	// Currently, there may be problem if in one CC read status is read and in next write status
	// is read as the *_status_accessed signals are asserted on address read and deasserted on 
	// read handshake. So if they happen on consecutive CC, there may be corruption.
	always_ff @(posedge clk) begin
		if(rst) begin
			config_slave.r_data <= 0;
			config_slave.r_valid <= 0;
			config_slave.r_resp <= 0;	// OKAY
		end 

		else if(config_slave.r_valid & config_slave.r_ready) begin
			config_slave.r_valid <= 0;

			if(write_status_accessed)
				write_status_accessed <= 0;
			if(read_status_accessed)
				read_status_accessed <= 0;
		end
		
		else if(config_slave.ar_valid & config_slave.ar_ready) begin
			case(config_slave.ar_addr) 
				(AXI_CONFIG_BASE_ADDR + READ_STATUS_OFFSET) : begin
					if(read_status_valid == 0) begin // if the read desc status is invalid, just send a busy response
						config_slave.r_data <= DMA_BUSY;
					end 
					else begin
						config_slave.r_data <= DMA_DONE;	// TODO: Error Reporting
					end

					read_status_accessed <= 1;
				end

				(AXI_CONFIG_BASE_ADDR + WRITE_STATUS_OFFSET) : begin
					if(write_status_valid == 0) begin // if the write desc status is invalid, just send a busy response
						config_slave.r_data <= DMA_BUSY;
					end 
					else begin
						config_slave.r_data <= DMA_DONE;	// TODO: Error Reporting
					end

					write_status_accessed <= 1;
				end

				default: begin
					config_slave.r_data <= 0;
					config_slave.r_valid <= 0;
					config_slave.r_resp <= 0;	// OKAY
				end 
			endcase

			config_slave.r_valid <= 1;
		end
	end

	axi_dma #(
		.AXI_DATA_WIDTH(AXI_DATA_WIDTH),
		.AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
		.AXI_STRB_WIDTH(AXI_STRB_WIDTH),
		.AXI_ID_WIDTH(AXI_ID_WIDTH),
		.AXI_MAX_BURST_LEN(AXI_MAX_BURST_LEN),
		.AXIS_DATA_WIDTH(AXIS_DATA_WIDTH),
		.AXIS_KEEP_ENABLE(AXIS_KEEP_ENABLE),
		.AXIS_KEEP_WIDTH(AXIS_KEEP_WIDTH),
		.AXIS_LAST_ENABLE(AXIS_LAST_ENABLE),
		.AXIS_ID_ENABLE(AXIS_ID_ENABLE),
		.AXIS_ID_WIDTH(AXIS_ID_WIDTH),
		.AXIS_DEST_ENABLE(AXIS_DEST_ENABLE),
		.AXIS_DEST_WIDTH(AXIS_DEST_WIDTH),
		.AXIS_USER_ENABLE(AXIS_USER_ENABLE),
		.AXIS_USER_WIDTH(AXIS_USER_WIDTH),
		.LEN_WIDTH(LEN_WIDTH),
		.TAG_WIDTH(TAG_WIDTH),
		.ENABLE_SG(ENABLE_SG),
		.ENABLE_UNALIGNED(ENABLE_UNALIGNED)
	) axi_dma_inst

	(   .clk(clk), .rst(rst),

		// AXI Stream Read Descriptors
		.s_axis_read_desc_addr  (s_axis_read_desc_addr ) ,
		.s_axis_read_desc_len   (s_axis_read_desc_len  ) ,
		.s_axis_read_desc_tag   (s_axis_read_desc_tag  ) ,
		.s_axis_read_desc_id    (s_axis_read_desc_id   ) ,
		.s_axis_read_desc_dest  (s_axis_read_desc_dest ) ,
		.s_axis_read_desc_user  (s_axis_read_desc_user ) ,
		.s_axis_read_desc_valid (s_axis_read_desc_valid) ,
		.s_axis_read_desc_ready (s_axis_read_desc_ready) ,
		
		.m_axis_read_desc_status_tag   (m_axis_read_desc_status_tag  ) ,
		.m_axis_read_desc_status_error (m_axis_read_desc_status_error) ,
		.m_axis_read_desc_status_valid (m_axis_read_desc_status_valid) ,

		.s_axis_write_desc_addr  (s_axis_write_desc_addr )   ,
		.s_axis_write_desc_len   (s_axis_write_desc_len  )   ,
		.s_axis_write_desc_tag   (s_axis_write_desc_tag  )   ,
		.s_axis_write_desc_valid (s_axis_write_desc_valid)   ,
		.s_axis_write_desc_ready (s_axis_write_desc_ready)   ,

		.m_axis_write_desc_status_len   (m_axis_write_desc_status_len  ) ,
		.m_axis_write_desc_status_tag   (m_axis_write_desc_status_tag  ) ,
		.m_axis_write_desc_status_id    (m_axis_write_desc_status_id   ) ,
		.m_axis_write_desc_status_dest  (m_axis_write_desc_status_dest ) ,
		.m_axis_write_desc_status_user  (m_axis_write_desc_status_user ) ,
		.m_axis_write_desc_status_error (m_axis_write_desc_status_error) ,
		.m_axis_write_desc_status_valid (m_axis_write_desc_status_valid) ,
		
		// AXI Stream Master Channel of DMA
		.m_axis_read_data_tdata     (axis_master_data),
		.m_axis_read_data_tvalid    (axis_master_valid),
		.m_axis_read_data_tready    (axis_master_ready),
		.m_axis_read_data_tlast     (axis_master_last),
		.m_axis_read_data_tkeep		(),
		.m_axis_read_data_tid		(),
		.m_axis_read_data_tdest		(),
		.m_axis_read_data_tuser		(),
		
		// AXI Stream Slave Channel of DMA
		.s_axis_write_data_tdata    (axis_slave_data),
		.s_axis_write_data_tkeep    (0),
		.s_axis_write_data_tvalid   (axis_slave_valid),
		.s_axis_write_data_tready   (axis_slave_ready),
		.s_axis_write_data_tlast    (axis_slave_last),
		.s_axis_write_data_tid      (0),
		.s_axis_write_data_tdest    (0),
		.s_axis_write_data_tuser    (0),

		// AXI-4 Master Interface
		.m_axi_awid     (master.aw_id),
		.m_axi_awaddr   (master.aw_addr),
		.m_axi_awlen    (master.aw_len),
		.m_axi_awsize   (master.aw_size),
		.m_axi_awburst  (master.aw_burst),
		.m_axi_awlock   (master.aw_lock),
		.m_axi_awcache  (master.aw_cache),
		.m_axi_awprot   (master.aw_prot),
		.m_axi_awvalid  (master.aw_valid),
		.m_axi_awready  (master.aw_ready),
		.m_axi_wdata    (master.w_data),
		.m_axi_wstrb    (master.w_strb),
		.m_axi_wlast    (master.w_last),
		.m_axi_wvalid   (master.w_valid),
		.m_axi_wready   (master.w_ready),
		.m_axi_bid      (master.b_id),
		.m_axi_bresp    (master.b_resp),
		.m_axi_bvalid   (master.b_valid),
		.m_axi_bready   (master.b_ready),
		.m_axi_arid     (master.ar_id),
		.m_axi_araddr   (master.ar_addr),
		.m_axi_arlen    (master.ar_len),
		.m_axi_arsize   (master.ar_size),
		.m_axi_arburst  (master.ar_burst),
		.m_axi_arlock   (master.ar_lock),
		.m_axi_arcache  (master.ar_cache),
		.m_axi_arprot   (master.ar_prot),
		.m_axi_arvalid  (master.ar_valid),
		.m_axi_arready  (master.ar_ready),
		.m_axi_rid      (master.r_id),
		.m_axi_rdata    (master.r_data),
		.m_axi_rresp    (master.r_resp),
		.m_axi_rlast    (master.r_last),
		.m_axi_rvalid   (master.r_valid),
		.m_axi_rready   (master.r_ready),

		.read_enable(read_enable),
		.write_enable(write_enable),
		.write_abort(write_abort)
	);

endmodule

`resetall
