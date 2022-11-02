// Copyright (c) 2020 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Authors:
// - Wolfgang Roenninger <wroennin@iis.ee.ethz.ch>
// - Andreas Kurth <akurth@iis.ee.ethz.ch>

// Directed Random Verification Testbench for `axi_lite_regs`.

`include "axi/assign.svh"

/// Testbench for validating the module `axi_lite_regs`.
module tb_axi_lite_regs #(
  /// Define the parameter `RegNumBytes` of the DUT.
  parameter int unsigned              TbRegNumBytes  = 32'd200,
  /// Define the parameter `AxiReadOnly` of the DUT.
  parameter logic [TbRegNumBytes-1:0] TbAxiReadOnly  = {{TbRegNumBytes-18{1'b0}}, 18'b101110111111000000},
  /// Define the parameter `PrivProtOnly` of the DUT.
  parameter bit                       TbPrivProtOnly = 1'b0,
  /// Define the parameter `SecuProtOnly` of the DUT.
  parameter bit                       TbSecuProtOnly = 1'b0,
  /// Number of random writes generated by the testbench AXI4-Lite random master.
  parameter int unsigned              TbNoWrites     = 32'd1000,
  /// Number of random reads generated by the testbench AXI4-Lite random master.
  parameter int unsigned              TbNoReads      = 32'd1500
);
  // AXI configuration
  localparam int unsigned AxiAddrWidth = 32'd32;    // Axi Address Width
  localparam int unsigned AxiDataWidth = 32'd32;    // Axi Data Width
  localparam int unsigned AxiStrbWidth = AxiDataWidth / 32'd8;
  // timing parameters
  localparam time CyclTime = 10ns;
  localparam time ApplTime =  2ns;
  localparam time TestTime =  8ns;

  typedef logic [7:0]              byte_t;
  typedef logic [AxiAddrWidth-1:0] axi_addr_t;
  typedef logic [AxiDataWidth-1:0] axi_data_t;
  typedef logic [AxiStrbWidth-1:0] axi_strb_t;

  localparam axi_addr_t StartAddr = axi_addr_t'(0);
  localparam axi_addr_t EndAddr   =
      axi_addr_t'(StartAddr + TbRegNumBytes + TbRegNumBytes/5);

  localparam byte_t [TbRegNumBytes-1:0] RegRstVal = '0;

  typedef axi_test::axi_lite_rand_master #(
    // AXI interface parameters
    .AW ( AxiAddrWidth ),
    .DW ( AxiDataWidth ),
    // Stimuli application and test time
    .TA ( ApplTime  ),
    .TT ( TestTime  ),
    .MIN_ADDR ( StartAddr ),
    .MAX_ADDR ( EndAddr   ),
    .MAX_READ_TXNS  ( 10 ),
    .MAX_WRITE_TXNS ( 10 )
  ) rand_lite_master_t;

  // -------------
  // DUT signals
  // -------------
  logic clk;
  // DUT signals
  logic rst_n;
  logic end_of_sim;
  // Register signals
  byte_t [TbRegNumBytes-1:0] reg_d,     reg_q;
  logic  [TbRegNumBytes-1:0] wr_active, rd_active, reg_load;

  // -------------------------------
  // AXI Interfaces
  // -------------------------------
  AXI_LITE #(
    .AXI_ADDR_WIDTH ( AxiAddrWidth      ),
    .AXI_DATA_WIDTH ( AxiDataWidth      )
  ) master ();
  AXI_LITE_DV #(
    .AXI_ADDR_WIDTH ( AxiAddrWidth      ),
    .AXI_DATA_WIDTH ( AxiDataWidth      )
  ) master_dv (clk);
  `AXI_LITE_ASSIGN(master, master_dv)

  // -------------------------------
  // AXI Rand Masters and Slaves
  // -------------------------------
  // Masters control simulation run time
  initial begin : proc_generate_axi_traffic
    automatic rand_lite_master_t lite_axi_master = new ( master_dv, "Lite Master");
    automatic axi_data_t      data = '0;
    automatic axi_pkg::resp_t resp = '0;
    end_of_sim <= 1'b0;
    lite_axi_master.reset();
    @(posedge rst_n);
    repeat (5) @(posedge clk);
    // Test known register.
    // Write to it.
    lite_axi_master.write(axi_addr_t'(32'h0000_0000), axi_pkg::prot_t'('0),
        axi_data_t'(64'hDEADBEEFDEADBEEF), axi_strb_t'(8'hFF), resp);
    if (TbPrivProtOnly || TbSecuProtOnly) begin
      assert (resp == axi_pkg::RESP_SLVERR) else
          $fatal(1, "PrivProtOnly || SecuProtOnly: Unprivileged access was falsely granted.");
    end else begin
      assert (resp == axi_pkg::RESP_OKAY) else
          $fatal(1, "Access should be granted");
    end
    // Read from it.
    lite_axi_master.read(axi_addr_t'(32'h0000_0000), axi_pkg::prot_t'('0), data, resp);
    if (TbPrivProtOnly || TbSecuProtOnly) begin
      // Expect error response
      assert (resp == axi_pkg::RESP_SLVERR) else
          $fatal(1, "PrivProtOnly || SecuProtOnly: Unprivileged access was falsely granted.");
      assert (data == axi_data_t'(32'hBA5E1E55)) else
          $fatal(1, "Data is unexpected, should be axi_data_t'(32'hBA5E1E55).");
    end else begin
      assert (resp == axi_pkg::RESP_OKAY) else
          $fatal(1, "Access should be granted.");
      // Checking of the expecetd read data is handled in `proc_check_read_data`.
    end

    // Let random stimuli application checking is separate.
    lite_axi_master.run(TbNoReads, TbNoWrites);
    end_of_sim <= 1'b1;
  end

  initial begin : proc_generate_direct_load
    for (int unsigned i = 0; i < TbRegNumBytes; i++) begin
      automatic int unsigned j = i;
      fork
        toggle_load(j);
      join_none
    end
  end

  task automatic toggle_load(int unsigned byte_i);
    byte_t       rand_val;
    int unsigned rand_wait;
    @(posedge rst_n);
    reg_load[byte_i] = 1'b0;
    reg_d[byte_i]    = 8'h00;
    @(posedge clk);
    forever begin
      rand_wait = $urandom_range(0, 20);
      repeat (rand_wait) @(posedge clk);
      rand_val          = byte_t'($urandom());
      reg_d[byte_i]    <= #ApplTime rand_val;
      reg_load[byte_i] <= #ApplTime 1'b1;
      @(posedge clk);
      reg_d[byte_i]    <= #ApplTime '0;
      reg_load[byte_i] <= #ApplTime 1'b0;
    end
  endtask : toggle_load

  initial begin : proc_check_read_data
    automatic axi_data_t      exp_rdata[$];
    automatic axi_pkg::resp_t exp_resp[$];

    @(posedge rst_n);
    forever begin
      @(posedge clk);
      #(TestTime);

      // Push the expected data back.
      if (master.ar_valid && master.ar_ready) begin
        automatic int unsigned ar_idx = ((master.ar_addr - StartAddr)
            >> $clog2(AxiStrbWidth) << $clog2(AxiStrbWidth));
        automatic axi_data_t      r_data = axi_data_t'(0);
        automatic axi_pkg::resp_t r_resp = axi_pkg::RESP_SLVERR;
        for (int unsigned i = 0; i < AxiStrbWidth; i++) begin
          if ((ar_idx+i) < TbRegNumBytes) begin
            r_data[8*i+:8] = reg_q[ar_idx+i];
            r_resp         = axi_pkg::RESP_OKAY;
          end else begin
            r_data[8*i+:8] = 8'hxx;
          end
        end
        // check the right protection access
        if (TbPrivProtOnly && !master.ar_prot[0]) begin
          r_resp = axi_pkg::RESP_SLVERR;
        end
        if (TbSecuProtOnly && !master.ar_prot[1]) begin
          r_resp = axi_pkg::RESP_SLVERR;
        end
        exp_resp.push_back(r_resp);
        exp_rdata.push_back(r_data);
      end

      // compare data if there is a value expected
      if (master.r_valid && master.r_ready) begin
        automatic axi_data_t r_data = exp_rdata.pop_front();
        if (master.r_resp == axi_pkg::RESP_OKAY) begin
          for (int unsigned i = 0; i < AxiStrbWidth; i++) begin
            automatic byte_t exp_byte = r_data[8*i+:8];
            if (exp_byte !== 8'hxx) begin
              assert (master.r_data[8*i+:8] == exp_byte) else
                  $error("Unexpected read data: exp: %0h observed: %0h", r_data, master.r_data);
              assert (master.r_resp == axi_pkg::RESP_OKAY);
            end
          end
        end else if (master.r_resp == axi_pkg::RESP_SLVERR) begin
          assert (master.r_data == axi_data_t'(32'hBA5E1E55));
        end else begin
          $error("Slave responded with false response: %0h", master.r_resp);
        end
      end
    end
  end

  axi_pkg::resp_t b_resp_queue[$];

  // Only works as module expects both AW & W valid before it does something
  initial begin : proc_check_write_data
    @(posedge rst_n);
    forever begin
      #TestTime;
      // AW and W is launched, setup the test tasks
      if (master.aw_valid && master.aw_ready && master.w_valid && master.w_ready) begin
        automatic int unsigned aw_idx = ((master.aw_addr - StartAddr)
            >> $clog2(AxiStrbWidth) << $clog2(AxiStrbWidth));
        automatic axi_pkg::resp_t exp_b_resp = (aw_idx < TbRegNumBytes) ?
            axi_pkg::RESP_OKAY : axi_pkg::RESP_SLVERR;
        automatic bit all_ro = 1'b1;
        // check for errors from wrong access protection
        if (TbPrivProtOnly && !master.aw_prot[0]) begin
          exp_b_resp = axi_pkg::RESP_SLVERR;
        end
        if (TbSecuProtOnly && !master.aw_prot[1]) begin
          exp_b_resp = axi_pkg::RESP_SLVERR;
        end
        // Check if all accesses bytes are read only
        for (int unsigned i = 0; i < AxiStrbWidth; i++) begin
          if (!TbAxiReadOnly[aw_idx+i]) begin
            all_ro = 1'b0;
          end
        end
        if (all_ro) begin
          exp_b_resp = axi_pkg::RESP_SLVERR;
        end

        // do the actual write checking
        if (exp_b_resp == axi_pkg::RESP_OKAY) begin
          // go through every byte
          for (int unsigned i = 0; i < AxiStrbWidth; i++) begin
            if ((aw_idx+i) < TbRegNumBytes) begin
              if (master.w_strb[i]) begin
                automatic int unsigned        j = aw_idx + i;
                automatic byte_t       exp_byte = master.w_data[8*i+:8];
                fork
                  check_q(j, exp_byte);
                join_none
              end
              assert (master.w_strb[i] == wr_active[aw_idx+i]);
            end
          end
        end
        b_resp_queue.push_back(exp_b_resp);
      end
      @(posedge clk);
    end
  end

  initial begin : proc_check_b
    automatic axi_pkg::resp_t exp_b_resp;
    @(posedge rst_n);
    forever begin
      #TestTime;
      if (master.b_valid && master.b_ready) begin
        if (b_resp_queue.size()) begin
          exp_b_resp = b_resp_queue.pop_front();
          assert (exp_b_resp == master.b_resp) else
              $error("Unexpected B response: EXP: %b ACT: %b", exp_b_resp, master.b_resp);
        end else begin
          $error("B response even no AW was sent.");
        end
      end
      @(posedge clk);
    end
  end

  // check that the expected register byte has been written
  task automatic check_q(int unsigned byte_i, byte_t exp_byte);
    automatic byte_t save_byte = (reg_load[byte_i]) ? reg_d[byte_i] : reg_q[byte_i];
    @(posedge clk);
    #TestTime;
    if (!TbAxiReadOnly[byte_i]) begin
      assert(exp_byte == reg_q[byte_i]) else
          $error("AXI write was not registered at byte: %0d", byte_i);
    end else begin
      assert (reg_q[byte_i] == save_byte) else
          $error("AXI write onto read only byte: %0d SAVE: %h EXP: %h ACT %h",
              byte_i, save_byte, exp_byte, reg_q[byte_i]);
    end
  endtask : check_q

  // Some assertions for additional checking.
  default disable iff (~rst_n);
  for (genvar i = 0; i < TbRegNumBytes; i++) begin : gen_check_ro_bytes
    if (TbAxiReadOnly[i]) begin : gen_check_ro
      ro_assert_no_load: assert property (@(posedge clk)
          ((wr_active[i] && !reg_load[i]) |=> $stable(reg_q[i]))) else
          $fatal(1, "ReadOnly byte %0d changed from AXI write, while not direct loaded.", i);
      ro_assert_load: assert property (@(posedge clk)
          ((wr_active[i] && reg_load[i]) |=> (reg_q[i] === $past(reg_d[i])))) else
          $fatal(1, "ReadOnly byte %0d changed from AXI write, while direct loaded.", i);
    end
    load_assert_no_axi: assert property (@(posedge clk)
        (reg_load[i] && !TbAxiReadOnly[i] |-> !wr_active[i])) else
        $fatal(1, "Byte %0d, AXI write onto non read-only and direct load are both active!", i);
    load_assert_data:   assert property (@(posedge clk)
        (reg_load[i] |=> reg_q[i] === $past(reg_d[i]))) else
        $fatal(1, "Byte %0d, direct load was executed falsely.", i);
    stable_assert:      assert property (@(posedge clk)
        (!reg_load[i] && !wr_active[i]) |=> $stable(reg_q[i])) else
        $fatal(1, "Byte %0d is unstable, when no AXI write or direct load.", i);
  end

  initial begin : proc_stop_sim
    wait (end_of_sim);
    repeat (1000) @(posedge clk);
    $display("Simulation stopped as Master transferred its data.");
    `ifdef TARGET_VCS
    $finish(1);
    `else
    $stop();
    `endif
  end

  //-----------------------------------
  // Clock generator
  //-----------------------------------
  clk_rst_gen #(
    .ClkPeriod    ( CyclTime ),
    .RstClkCycles ( 5        )
  ) i_clk_gen (
    .clk_o (clk),
    .rst_no(rst_n)
  );

  //-----------------------------------
  // DUT
  //-----------------------------------
  axi_lite_regs_intf #(
    .REG_NUM_BYTES  ( TbRegNumBytes  ),
    .AXI_ADDR_WIDTH ( AxiAddrWidth   ),
    .AXI_DATA_WIDTH ( AxiDataWidth   ),
    .PRIV_PROT_ONLY ( TbPrivProtOnly ),
    .SECU_PROT_ONLY ( TbSecuProtOnly ),
    .AXI_READ_ONLY  ( TbAxiReadOnly  ),
    .REG_RST_VAL    ( RegRstVal      )
  ) i_axi_lite_regs (
    .clk_i       ( clk       ),
    .rst_ni      ( rst_n     ),
    .slv         ( master    ),
    .wr_active_o ( wr_active ),
    .rd_active_o ( rd_active ),
    .reg_d_i     ( reg_d     ),
    .reg_load_i  ( reg_load  ),
    .reg_q_o     ( reg_q     )
  );
endmodule
