module ring_buffer 
# (
    parameter SIZE_BUFFER = 8, // Number of entries in the ring buffer
    parameter DATA_WIDTH = 512, // Width of each entry in bits
    parameter ADDR_LEN = $clog2(SIZE_BUFFER) // Length of address bus in bits
)
(
    input wire clk,
    input wire rst,
    input wire wr_en, // Write enable
    input wire rd_en, // Read enable
    input wire [DATA_WIDTH-1:0] wr_data, // Data to write
    output reg [DATA_WIDTH-1:0] rd_data, // Data read
    output wire full, // Buffer full flag
    output wire empty // Buffer empty flag
);

    
    reg [DATA_WIDTH-1:0] buffer [0:SIZE_BUFFER-1]; // The ring buffer storage
    reg [ADDR_LEN-1:0] wr_ptr; // Write pointer
    reg [ADDR_LEN-1:0] rd_ptr; // Read pointer
    reg [ADDR_LEN:0] count; // Count of items in the buffer

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            count <= 0;
            full <= 1'b0;
            empty <= 1'b1;
        end else begin
            if (wr_en && !full) begin
                buffer[wr_ptr] <= wr_data;
                wr_ptr <= wr_ptr + 1;
                count <= count + 1;
            end

            if (rd_en && !empty) begin
                rd_data <= buffer[rd_ptr];
                rd_ptr <= rd_ptr + 1;
                count <= count - 1;
            end
        end
    end

    assign full = (count == SIZE_BUFFER);
    assign empty = (count == 0);

endmodule