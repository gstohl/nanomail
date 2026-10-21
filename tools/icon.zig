//! Draws nanomail's app icon with nanoui, offscreen: `icon OUT.png`
//! writes it at 1024×1024 (macOS's grid: an 824-point rounded square,
//! centered, on a clear canvas).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

const Icon = struct {
    fn view(_: *Icon, c: *ui.Context) void {
        const root = ui.div(c).sizeFull().center();
        defer root.end();
        const tile = ui.div(c).size(824, 824).center().rounded(185).bg(.hex(0x0a84ff)).shadow(.{ .color = .{ .a = 0.3 }, .blur = 28, .y = 12 });
        defer tile.end();
        // Its glyph under 512 pixels wide: nanoui's atlas starts that size.
        ui.icon(c, "envelope.fill", .{ .size = 340, .color = .white });
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.Usage;
    var icon: Icon = .{};
    var theme = ui.Theme.light;
    theme.background = ui.Color.transparent;
    var t: ui.Tester = undefined;
    try t.init(init.gpa, .init(&icon, Icon.view), .{ .width = 1024, .height = 1024, .scale = 1, .theme = theme });
    defer t.deinit();
    t.settle(0.2);
    try t.screenshot(args[1]);
}
