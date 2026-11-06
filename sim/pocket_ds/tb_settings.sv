// Core Settings and controls (tools/ds/settings.py, nds_controls.sv,
// core_top_ds.sv's settings crossing, copied here): bridge writes on
// clk_74a reach the controls on clk_bus as one packet and change what the
// SELECT combos and the cursor speed do (A is the pen; SELECT+R or L the
// layout). Run by sim/pocket_ds/settings_test.py (also with planted bugs).
`timescale 1ns/1ps
module tb_settings;
    `include "nds_settings.svh"
    reg clk_74a = 0, clk = 0, reset = 1;
    always #6.7 clk_74a = !clk_74a;
    always #14.9 clk = !clk;
    reg bridge_wr = 0;
    reg [31:0] bridge_addr = 0, bridge_wr_data = 0;
    reg [15:0] keys = 0;
    reg [3:0] ctype = 4'h1;                 // the APF controller type (1: the Pocket's own buttons)
    reg [31:0] joy = 32'h8080_8080;         // {RY, RX, LY, LX}
    reg frame = 0;
    integer errors = 0;

    // ---- the settings crossing, as in core_top_ds.sv
    reg [SET_BITS-1:0] set_a = SET_DEFAULT;
    // a setting's value (a small option number) from either end of the bridge
    // word: with bridge_endian_little the APF delivers it byte-swapped, in
    // bits 31:24 (#253: the settings never changed on hardware); the other
    // byte is zero either way
    function automatic [3:0] set_v(input integer w);
        set_v = (bridge_wr_data[3:0] | bridge_wr_data[27:24]) & ((4'd1 << w) - 4'd1);
    endfunction
    always @(posedge clk_74a)
        if (bridge_wr && bridge_addr[31:8] == 24'h500000)
            case (bridge_addr[7:2])
                SET_SELECT_LR_IDX:     set_a[SET_SELECT_LR_BIT +: SET_SELECT_LR_W] <= set_v(SET_SELECT_LR_W);
                SET_SELECT_ABXY_IDX:   set_a[SET_SELECT_ABXY_BIT +: SET_SELECT_ABXY_W] <= set_v(SET_SELECT_ABXY_W);
                SET_CURSOR_SPEED_IDX:  set_a[SET_CURSOR_SPEED_BIT +: SET_CURSOR_SPEED_W] <= set_v(SET_CURSOR_SPEED_W);
                SET_SCREEN_ROTATION_IDX: set_a[SET_SCREEN_ROTATION_BIT +: SET_SCREEN_ROTATION_W] <= set_v(SET_SCREEN_ROTATION_W);
                default: ;
            endcase
    wire [SET_BITS-1:0] set_b;
    nds_sync #(.W(SET_BITS)) set_sync (.clk, .d(set_a), .q(set_b));

    wire [1:0] layout;
    wire touch, cursor, pen;
    wire [7:0] cx, cy;
    wire [15:0] ds_keys;
    nds_controls dut (.clk, .reset, .apf_keys(keys), .apf_type(ctype), .apf_joy(joy), .frame,
        .combo_sel({set_b[SET_SELECT_ABXY_BIT], set_b[SET_SELECT_LR_BIT]}), .touch_btn(2'd0),
        .speed(set_b[SET_CURSOR_SPEED_BIT +: 2]), .layout_set(2'd0), .set_new(1'b0),
        .layout, .touch, .cursor, .pen, .cur_x(cx), .cur_y(cy), .ds_keys);

    localparam K_DOWN = 1, K_UP = 0, K_RIGHT = 3, K_A = 4, K_B = 5, K_X = 6, K_Y = 7, K_L = 8, K_R = 9, K_SEL = 14;
    task automatic wait_clk(input integer n); repeat (n) @(posedge clk); endtask
    task automatic setting(input integer idx, input integer v);
        @(posedge clk_74a) begin bridge_wr <= 1; bridge_addr <= 32'h5000_0000 | (idx << 2); bridge_wr_data <= {v[7:0], 24'd0}; end   // byte-swapped, as the APF delivers it (bridge_endian_little)
        @(posedge clk_74a) bridge_wr <= 0;
        wait_clk(40);
    endtask
    task automatic press(input integer k); keys[k] = 1; wait_clk(8); endtask
    task automatic release_(input integer k); keys[k] = 0; wait_clk(8); endtask
    task automatic combo(input integer k);
        press(K_SEL); press(k); release_(k); release_(K_SEL);
        wait_clk(8);
    endtask
    task automatic frames(input integer n);
        repeat (n) begin @(posedge clk) frame <= 1; @(posedge clk) frame <= 0; end
    endtask
    task automatic check(input string what, input integer got, input integer want);
        if (got !== want) begin $display("ERROR %s: %0d, expected %0d", what, got, want); errors++; end
    endtask

    initial begin
        wait_clk(10); reset = 0; wait_clk(40);
        check("default layout", layout, 0);
        // SELECT Combos default: SELECT+R next layout, SELECT+L previous, SELECT + A/B/X/Y touch mode
        combo(K_R);                    check("SELECT+R next layout", layout, 1);
        combo(K_R); combo(K_R);        check("layout wraps forward", layout, 0);
        combo(K_L);                    check("SELECT+L previous layout (wraps back)", layout, 2);
        combo(K_L);                    check("SELECT+L previous layout", layout, 1);
        combo(K_L);                    check("SELECT+L back to stacked", layout, 0);
        // the toggling press is held back from the game while SELECT is down
        press(K_SEL); press(K_Y);      check("SELECT+Y: Y held back", ds_keys[K_Y], 0);
        release_(K_Y); release_(K_SEL); wait_clk(8);
        check("SELECT+Y touch mode", touch, 1);
        press(K_RIGHT); frames(5); release_(K_RIGHT);
        check("normal speed: 3 px/frame", cx, 128 + 15);
        press(K_A);                    check("A is the pen", pen, 1);
        check("A held back in touch mode", ds_keys[K_A], 0);
        release_(K_A);
        press(K_X);                    check("X reaches the game in touch mode", ds_keys[K_X], 1);
        release_(K_X);
        // Cursor Speed fast, slow
        setting(SET_CURSOR_SPEED_IDX, 2);
        press(K_UP); frames(3); release_(K_UP);
        check("fast speed: 6 px/frame", cy, 96 - 18);
        setting(SET_CURSOR_SPEED_IDX, 0);
        press(K_DOWN); frames(4); release_(K_DOWN);
        check("slow speed: 1 px/frame", cy, 96 - 14);
        combo(K_B);                    check("SELECT+B touch off", touch, 0);
        press(K_A);                    check("A reaches the game", ds_keys[K_A], 1);
        release_(K_A);
        combo(K_X);                    check("SELECT+X touch on", touch, 1);
        combo(K_A);                    check("SELECT+A touch off", touch, 0);
        check("layout untouched by the touch combos", layout, 0);
        // top only (layout 1, from stacked 0 -> SELECT+R): normal controls, touch kept but not applied
        combo(K_Y);                    check("touch on in stacked", touch, 1);
        check("cursor shown after the toggle", cursor, 1);
        combo(K_R);                    check("top only", layout, 1);
        check("top only: no touch", touch, 0);
        check("top only: no cursor", cursor, 0);
        press(K_A);                    check("top only: A reaches the game", ds_keys[K_A], 1);
        check("top only: no pen", pen, 0);
        release_(K_A);
        press(K_RIGHT);                check("top only: the D-pad reaches the game", ds_keys[K_RIGHT], 1);
        release_(K_RIGHT);
        press(K_SEL); press(K_X);      check("top only: SELECT+X reaches the game", ds_keys[K_X], 1);
        release_(K_X); release_(K_SEL); wait_clk(8);
        check("top only: SELECT+X no toggle", touch, 0);
        combo(K_R);                    check("bottom only", layout, 2);
        check("bottom only: touch mode back", touch, 1);
        combo(K_A);                    check("touch off", touch, 0);
        // the cursor hides 180 DS frames (3 s) after its last use
        combo(K_B);                    check("touch on again", touch, 1);
        frames(179); wait_clk(2);      check("cursor still shown at 179 frames", cursor, 1);
        frames(1); wait_clk(2);        check("cursor hidden at 180 frames", cursor, 0);
        press(K_UP); frames(1); release_(K_UP);
        check("moving shows the cursor again", cursor, 1);
        combo(K_B);                    check("touch off before analog", touch, 0);
        // analog sticks: ignored on the handheld (type 1), the left stick as the D-pad with type 3
        joy = 32'h8080_8010; frames(1); wait_clk(8);
        check("handheld: the stick is no D-pad", ds_keys[2], 0);
        ctype = 4'h3; joy = 32'h8080_8010; frames(1); wait_clk(8);
        check("analog: left stick left", ds_keys[2], 1);
        joy = 32'h8080_8050; frames(1); wait_clk(8);
        check("analog: hysteresis keeps left at 0x50", ds_keys[2], 1);
        joy = 32'h8080_8060; frames(1); wait_clk(8);
        check("analog: released at 0x60", ds_keys[2], 0);
        joy = 32'h8080_F080; frames(1); wait_clk(8);
        check("analog: left stick down", ds_keys[1], 1);
        joy = 32'h8080_8080; frames(1); wait_clk(8);
        // the right stick moves the cursor without touch mode: (0x7F - 32) / 8 = 11 px a frame
        begin
            integer x0;
            joy = 32'h80FF_8080; frames(1); wait_clk(8);    // (the sticks are sampled once a frame)
            x0 = cx; frames(2); wait_clk(4);
            check("right stick moves the cursor", cx, x0 + 22 > 255 ? 255 : x0 + 22);
            joy = 32'h8098_8080; frames(1); wait_clk(8);
            x0 = cx; frames(2); wait_clk(4);
            check("right stick inside the dead zone", cx, x0);
            joy = 32'h8080_8080; frames(1); wait_clk(8);
        end
        check("analog: cursor shown", cursor, 1);
        check("analog: no touch mode", touch, 0);
        press(13);                     check("R3 is the pen", pen, 1);
        release_(13);
        press(K_A);                    check("analog: A still reaches the game", ds_keys[K_A], 1);
        release_(K_A);
        combo(K_L);                    check("analog in top only", layout, 1);
        joy = 32'h80FF_8080; frames(1); wait_clk(8);
        begin
            integer x1;
            x1 = cx; frames(2); wait_clk(4);
            check("top only: the right stick does nothing", cx, x1);
        end
        press(13);                     check("top only: R3 no pen", pen, 0);
        release_(13);
        joy = 32'h8080_8080; ctype = 4'h1; frames(1); wait_clk(8);
        combo(K_L);                    check("stacked again", layout, 0);
        // Screen Rotation crosses with the other settings
        setting(SET_SCREEN_ROTATION_IDX, 2);
        check("Screen Rotation: right", set_b[SET_SCREEN_ROTATION_BIT +: 2], 2);
        check("Screen Rotation leaves both combos on", {set_b[SET_SELECT_ABXY_BIT], set_b[SET_SELECT_LR_BIT]}, 0);
        setting(SET_SCREEN_ROTATION_IDX, 0);
        // SELECT + L/R Off (A/B/X/Y on): SELECT, L and R reach the game, the layout stays; SELECT+Y still toggles touch
        setting(SET_SELECT_LR_IDX, 1);
        // (SELECT itself is still a combo key for A/B/X/Y: held back as before)
        press(K_SEL); press(K_L);
        check("L/R Off: L passes with SELECT", ds_keys[K_L], 1);
        release_(K_L); press(K_R);
        check("L/R Off: R passes with SELECT", ds_keys[K_R], 1);
        release_(K_R); release_(K_SEL); wait_clk(8);
        check("L/R Off: layout unchanged", layout, 0);
        press(K_SEL); press(K_Y);      check("L/R Off: SELECT+Y held back", ds_keys[K_Y], 0);
        release_(K_Y); release_(K_SEL); wait_clk(8);
        check("L/R Off: SELECT+Y still toggles touch", touch, 1);
        combo(K_Y);                    check("L/R Off: SELECT+Y toggles touch off", touch, 0);
        // SELECT + A/B/X/Y Off (L/R on): A/B/X/Y reach the game with SELECT, touch stays; SELECT+R still steps on
        setting(SET_SELECT_LR_IDX, 0);
        setting(SET_SELECT_ABXY_IDX, 1);
        press(K_SEL); press(K_A);
        check("A/B/X/Y Off: A passes with SELECT", ds_keys[K_A], 1);
        release_(K_A); press(K_X);
        check("A/B/X/Y Off: X passes with SELECT", ds_keys[K_X], 1);
        release_(K_X); release_(K_SEL); wait_clk(8);
        check("A/B/X/Y Off: touch unchanged", touch, 0);
        combo(K_R);                    check("A/B/X/Y Off: SELECT+R still steps the layout", layout, 1);
        combo(K_L);                    check("A/B/X/Y Off: SELECT+L steps back", layout, 0);
        // both Off: SELECT, L, R and A reach the game, nothing changes
        setting(SET_SELECT_LR_IDX, 1);
        press(K_SEL); press(K_L);
        check("both Off: SELECT passes", ds_keys[K_SEL], 1);
        check("both Off: L passes", ds_keys[K_L], 1);
        release_(K_L); press(K_A);
        check("both Off: A passes with SELECT", ds_keys[K_A], 1);
        release_(K_A); release_(K_SEL); wait_clk(8);
        check("both Off: layout unchanged", layout, 0);
        check("both Off: touch unchanged", touch, 0);
        if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d)", errors);
        $finish;
    end
endmodule
