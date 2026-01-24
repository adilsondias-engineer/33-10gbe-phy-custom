/*
 * Simple UART Transmitter
 *
 * 8N1 format: 8 data bits, no parity, 1 stop bit
 * * *********************************************************************
 * Copyright 2026 Adilson Dias
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Author: Adilson Dias
 * GitHub: https://github.com/adilsondias-engineer/fpga-trading-systems
 * Date: January 2026
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module uart_tx_simple #(
        parameter CLK_FREQ  = 100_000_000,
        parameter BAUD_RATE = 115200
    )(
        input  wire       clk,
        input  wire       rst,
        input  wire [7:0] tx_data,
        input  wire       tx_start,
        output reg        tx_busy,
        output reg        tx
    );

    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;

    localparam STATE_IDLE      = 2'd0;
    localparam STATE_START_BIT = 2'd1;
    localparam STATE_DATA_BITS = 2'd2;
    localparam STATE_STOP_BIT  = 2'd3;

    reg [1:0]  state;
    reg [15:0] clk_counter;
    reg [2:0]  bit_index;
    reg [7:0]  tx_shift_reg;

    always @(posedge clk) begin
        if (rst) begin
            state       <= STATE_IDLE;
            tx          <= 1'b1;
            tx_busy     <= 1'b0;
            clk_counter <= 16'd0;
            bit_index   <= 3'd0;
            tx_shift_reg <= 8'd0;
        end
        else begin
            case (state)
                STATE_IDLE: begin
                    tx      <= 1'b1;
                    tx_busy <= 1'b0;
                    clk_counter <= 16'd0;
                    bit_index   <= 3'd0;

                    if (tx_start) begin
                        tx_shift_reg <= tx_data;
                        tx_busy <= 1'b1;
                        state <= STATE_START_BIT;
                    end
                end

                STATE_START_BIT: begin
                    tx <= 1'b0;
                    if (clk_counter < CLKS_PER_BIT - 1) begin
                        clk_counter <= clk_counter + 1;
                    end
                    else begin
                        clk_counter <= 16'd0;
                        state <= STATE_DATA_BITS;
                    end
                end

                STATE_DATA_BITS: begin
                    tx <= tx_shift_reg[bit_index];
                    if (clk_counter < CLKS_PER_BIT - 1) begin
                        clk_counter <= clk_counter + 1;
                    end
                    else begin
                        clk_counter <= 16'd0;
                        if (bit_index < 7) begin
                            bit_index <= bit_index + 1;
                        end
                        else begin
                            bit_index <= 3'd0;
                            state <= STATE_STOP_BIT;
                        end
                    end
                end

                STATE_STOP_BIT: begin
                    tx <= 1'b1;
                    if (clk_counter < CLKS_PER_BIT - 1) begin
                        clk_counter <= clk_counter + 1;
                    end
                    else begin
                        clk_counter <= 16'd0;
                        state <= STATE_IDLE;
                    end
                end

                default:
                    state <= STATE_IDLE;
            endcase
        end
    end

endmodule

`resetall
