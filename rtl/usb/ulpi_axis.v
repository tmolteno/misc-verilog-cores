`timescale 1ns / 100ps
module ulpi_axis #(
    parameter EP1_BULK_IN  = 1,
    parameter EP1_BULK_OUT = 1,
    parameter EP1_CONTROL  = 0,

    parameter EP2_BULK_IN  = 1,
    parameter EP2_BULK_OUT = 0,
    parameter EP2_CONTROL  = 0,

    parameter ENDPOINT1 = 1,  // todo: set to '0' to disable
    parameter ENDPOINT2 = 2,  // todo: set to '0' to disable

    parameter integer SERIAL_LENGTH = 8,
    parameter [SERIAL_LENGTH*8-1:0] SERIAL_STRING = "TART0001",

    parameter [15:0] VENDOR_ID = 16'hF4CE,
    parameter integer VENDOR_LENGTH = 19,
    parameter [VENDOR_LENGTH*8-1:0] VENDOR_STRING = "University of Otago",

    parameter [15:0] PRODUCT_ID = 16'h0003,
    parameter integer PRODUCT_LENGTH = 8,
    parameter [PRODUCT_LENGTH*8-1:0] PRODUCT_STRING = "TART USB"
) (
    // Global, asynchronous reset
    input  areset_n,
    output reset_no,

    // UTMI Low Pin Interface (ULPI)
    input ulpi_clock_i,
    input ulpi_dir_i,
    input ulpi_nxt_i,
    output ulpi_stp_o,
    inout [7:0] ulpi_data_io,

    // USB clock-domain clock & reset
    output usb_clock_o,
    output usb_reset_o,  // USB core is in reset state

    // Status flags for IN/OUT FIFOs, and the USB core
    output fifo_in_full_o,
    output fifo_out_full_o,
    output fifo_out_overflow_o,
    output fifo_has_data_o,

    output configured_o,
    output has_telemetry_o,
    output usb_sof_o,
    output crc_err_o,
    output crc_vld_o,
    output timeout_o,
    output usb_vbus_valid_o,
    output usb_hs_enabled_o,
    output usb_idle_o,  // USB core is idling
    output usb_suspend_o,  // USB core has been suspended
    output ulpi_rx_overflow_o,

    // USB Bulk Transfer parameters and data-streams
    input blk_in_ready_i,
    input blk_out_ready_i,
    output blk_start_o,
    output blk_cycle_o,
    output [3:0] blk_endpt_o,
    input blk_error_i,

    // AXI4-stream slave-port signals (IN: EP -> host)
    // Note: USB clock-domain
    input s_axis_tvalid_i,
    output s_axis_tready_o,
    input s_axis_tlast_i,
    input [7:0] s_axis_tdata_i,

    // AXI4-stream master-port signals (OUT: host -> EP)
    // Note: USB clock-domain
    output m_axis_tvalid_o,
    input m_axis_tready_i,
    output m_axis_tlast_o,
    output [7:0] m_axis_tdata_o
);


  // -- Constants -- //

  localparam HIGH_SPEED = 1;

  localparam CONFIG_DESC_LEN = 9;
  localparam INTERFACE_DESC_LEN = 9;
  localparam EP1_IN_DESC_LEN = 7;
  localparam EP1_OUT_DESC_LEN = 7;
  localparam EP2_IN_DESC_LEN = 7;

  localparam CONFIG_DESC = {
    8'h32,  // bMaxPower = 100 mA
    8'hC0,  // bmAttributes = Self-powered
    8'h00,  // iConfiguration
    8'h01,  // bConfigurationValue
    8'h01,  // bNumInterfaces = 1
    16'h0027,  // wTotalLength = 39
    8'h02,  // bDescriptionType = Configuration Descriptor
    8'h09  // bLength = 9
  };

  localparam INTERFACE_DESC = {
    8'h00,  // iInterface
    8'h00,  // bInterfaceProtocol
    8'h00,  // bInterfaceSubClass
    8'h00,  // bInterfaceClass
    8'h03,  // bNumEndpoints = 2
    8'h00,  // bAlternateSetting
    8'h00,  // bInterfaceNumber = 0
    8'h04,  // bDescriptorType = Interface Descriptor
    8'h09  // bLength = 9
  };

  localparam EP1_IN_DESC = {
    8'h00,  // bInterval
    16'h0200,  // wMaxPacketSize = 512 bytes
    8'h02,  // bmAttributes = Bulk
    8'h81,  // bEndpointAddress = IN1
    8'h05,  // bDescriptorType = Endpoint Descriptor
    8'h07  // bLength = 7
  };

  localparam EP1_OUT_DESC = {
    8'h00,  // bInterval
    16'h0200,  // wMaxPacketSize = 512 bytes
    8'h02,  // bmAttributes = Bulk
    8'h01,  // bEndpointAddress = OUT1
    8'h05,  // bDescriptorType = Endpoint Descriptor
    8'h07  // bLength = 7
  };

  localparam EP2_IN_DESC = {
    8'h00,  // bInterval
    16'h0200,  // wMaxPacketSize = 512 bytes
    8'h02,  // bmAttributes = Bulk
    8'h82,  // bEndpointAddress = IN2
    8'h05,  // bDescriptorType = Endpoint Descriptor
    8'h07  // bLength = 7
  };

  localparam integer CONF_DESC_SIZE = CONFIG_DESC_LEN + INTERFACE_DESC_LEN + EP1_IN_DESC_LEN + EP1_OUT_DESC_LEN + EP2_IN_DESC_LEN;
  localparam integer CONF_DESC_BITS = CONF_DESC_SIZE * 8;
  localparam integer CSB = CONF_DESC_BITS - 1;
  localparam [CSB:0] CONF_DESC_VALS = {
    EP2_IN_DESC, EP1_OUT_DESC, EP1_IN_DESC, INTERFACE_DESC, CONFIG_DESC
  };


  // -- Global Signals and Assignments -- //

  wire usb_reset_w, ulpi_rst_nw;

  reg rst_nq, rst_nr, rst_n1, rst_n0;
  wire clock, reset;

  assign usb_clock_o = clock;
  assign usb_reset_o = reset;

  assign clock = ulpi_clock_i;
  assign reset = ~rst_nq;
  assign ulpi_rst_nw = rst_n1;
  assign reset_no = ulpi_rst_nw;

  // Compute the reset signals
  always @(posedge clock or negedge areset_n) begin
    if (!areset_n) begin
      {rst_nq, rst_nr, rst_n1, rst_n0} <= 4'h0;
    end else begin
      {rst_nq, rst_nr, rst_n1, rst_n0} <= {rst_nr & ~usb_reset_w, rst_n1, rst_n0, areset_n};
    end
  end

  // ULPI signals
  wire [7:0] ulpi_data_iw, ulpi_data_ow;

  assign ulpi_data_io = ulpi_dir_i ? {8{1'bz}} : ulpi_data_ow;
  assign ulpi_data_iw = ulpi_data_io;


  // -- Local Signals and Assignments -- //

  wire ulpi_rx_tvalid_w, ulpi_rx_tready_w, ulpi_rx_tkeep_w, ulpi_rx_tlast_w;
  wire ulpi_tx_tvalid_w, ulpi_tx_tready_w, ulpi_tx_tkeep_w, ulpi_tx_tlast_w;
  wire [3:0] ulpi_rx_tuser_w, ulpi_tx_tuser_w;
  wire [7:0] ulpi_rx_tdata_w, ulpi_tx_tdata_w;

  wire tok_recv_w;
  wire [6:0] tok_addr_w;
  wire [3:0] tok_endp_w;

  wire usb_tx_busy_w, usb_tx_done_w;


  // -- Top-level USB Control Core -- //

  protocol #(
      .CONFIG_DESC_LEN(CONF_DESC_SIZE),
      .CONFIG_DESC(CONF_DESC_VALS),
      .VENDOR_LENGTH(VENDOR_LENGTH),
      .VENDOR_STRING(VENDOR_STRING),
      .PRODUCT_LENGTH(PRODUCT_LENGTH),
      .PRODUCT_STRING(PRODUCT_STRING),
      .SERIAL_LENGTH(SERIAL_LENGTH),
      .SERIAL_STRING(SERIAL_STRING),
      .VENDOR_ID(VENDOR_ID),
      .PRODUCT_ID(PRODUCT_ID)
  ) U_PROTOCOL0 (
      .clock(clock),
      .reset(reset),

      .configured_o   (configured_o),
      .has_telemetry_o(has_telemetry_o),
      .usb_addr_o     (),
      .usb_conf_o     (),
      .usb_sof_o      (usb_sof_o),
      .crc_err_i      (crc_err_o),
      .timeout_o      (timeout_o),

      // USB bulk endpoint data-paths
      .blk_in_ready_i(blk_in_ready_i),
      .blk_out_ready_i(blk_out_ready_i),
      .blk_start_o(blk_start_o),
      .blk_cycle_o(blk_cycle_o),
      .blk_endpt_o(blk_endpt_o),
      .blk_error_i(blk_error_i),

      .blk_tvalid_i(s_axis_tvalid_i),
      .blk_tready_o(s_axis_tready_o),
      .blk_tlast_i (s_axis_tlast_i),
      .blk_tdata_i (s_axis_tdata_i),

      .blk_tvalid_o(m_axis_tvalid_o),
      .blk_tready_i(m_axis_tready_i),
      .blk_tlast_o (m_axis_tlast_o),
      .blk_tdata_o (m_axis_tdata_o),

      .tok_recv_i(tok_recv_w),
      .tok_addr_i(tok_addr_w),
      .tok_endp_i(tok_endp_w),

      .usb_tx_busy_i(usb_tx_busy_w),
      .usb_tx_done_i(usb_tx_done_w),

      // USB control & bulk data received from host (via decoder)
      .usb_tvalid_i(ulpi_rx_tvalid_w),
      .usb_tready_o(ulpi_rx_tready_w),
      .usb_tkeep_i (ulpi_rx_tkeep_w),
      .usb_tlast_i (ulpi_rx_tlast_w),
      .usb_tuser_i (ulpi_rx_tuser_w),
      .usb_tdata_i (ulpi_rx_tdata_w),

      // USB control & bulk data transmitted to host (via encoder)
      .usb_tvalid_o(ulpi_tx_tvalid_w),
      .usb_tready_i(ulpi_tx_tready_w),
      .usb_tkeep_o (ulpi_tx_tkeep_w),
      .usb_tlast_o (ulpi_tx_tlast_w),
      .usb_tuser_o (ulpi_tx_tuser_w),
      .usb_tdata_o (ulpi_tx_tdata_w)
  );


endmodule  // ulpi_axis
