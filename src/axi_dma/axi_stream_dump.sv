/*
	This is a test module for AXI-Stream interface
	
	The slave of this module connects with the master of 
	DUT module and this module dumps the data received on the 
	slave interface to the SLAVE_DUMP_FILE

	The master of this module connects to the slave of the
	DUT module and this module injects the data it reads 
	from the MASTER_SOURCE_FILE into the slave of DUT
*/

module axi_stream_dump #(
	parameter AXI_DATA_WIDTH = 32,
	parameter SLAVE_DUMP_FILE = "",
	parameter MASTER_SOURCE_FILE = ""
	) 
	(
		input clk,
		input rst,

		// Slave Channel
		input [AXI_DATA_WIDTH - 1 : 0] 			slave_data_in,
		input 									slave_valid_in,
		input 									slave_last_in,
		output logic							slave_ready_in,

		// Master Channel
		output logic [AXI_DATA_WIDTH - 1 : 0]	master_data_out,
		output logic							master_valid_out,
		output logic 							master_last_out,
		input 									master_ready_out
	);

	int slave_fd;	// File Descriptor to file to which Slave will write its data to
	int master_fd;	// File Descriptor to file from which Master will read its data from

	int slave_beat;
	int master_beat;

	// logic [AXI_DATA_WIDTH - 1 : 0] master_RAM []

	initial begin
		// Initializing Slave
		slave_fd = $fopen(SLAVE_DUMP_FILE, "w");
		slave_beat = 0;
		if(slave_fd)
			$display("Opened Stream Dump File");
		else
			$display("Failed to Open Stream Dump File");

		$fwrite(slave_fd, "Beat\t%0d:\n", slave_beat);

		// // Initializing Master
		// master_fd = $fopen(MASTER_SOURCE_FILE, "r");
		// master_beat = 0;
		// if(master_fd)
		// 	$display("Opened Stream Source File");
		// else
		// 	$display("Failed to Open Stream Source File");

		
	end

	// Dumping the data received on the Slave
	always_ff @(posedge clk) begin
		if(rst) begin
			slave_ready_in <= 1;
		end
		else if(slave_valid_in & slave_ready_in) begin
			$fwrite(slave_fd, "\t0x%0x\n", slave_data_in);

			if(slave_last_in) begin
				slave_beat++;
				$fwrite(slave_fd, "\nBeat\t%0d:\n", slave_beat);
			end
		end
	end

	// // Reading Data from Source file and putting it on Master
	// always_ff @(posedge clk) begin
	// 	if(rst) begin
	// 		master_data_out		<= 0;
	// 		master_valid_out	<= 0;
	// 		master_last_out		<= 0;
	// 	end
	// 	else if(slave_valid_in & slave_ready_in) begin
	// 		$fwrite(slave_fd, "\t0x%0x\n", slave_data_in);

	// 		if(slave_last_in) begin
	// 			slave_beat++;
	// 			$fwrite(slave_fd, "\nBeat\t%0d:\n", slave_beat);
	// 		end
	// 	end
	// end

	// always_ff @(posedge clk) begin
	// 	if(rst) begin
	// 		master_last_out		<= 0;
	// 	end
	// 	else if()
	// end

endmodule