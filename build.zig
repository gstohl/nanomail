const std = @import("std");
const nanoui_build = @import("nanoui");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("nanoui", .{ .target = target, .optimize = optimize });
    const nanoui = dep.module("nanoui");
    const os = target.result.os.tag;
    const apple = os == .macos or os == .ios;

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
    // Passwords live in the keychain; iOS signs in through a sheet.
    if (apple) mod.linkFramework("Security", .{});
    if (os == .ios) mod.linkFramework("AuthenticationServices", .{});
    // The Simulator reads an app's entitlements (its keychain group) from a
    // section of the binary, as Xcode puts them there (main.zig exports it).
    if (os == .ios) mod.addAnonymousImport("simulator.entitlements", .{ .root_source_file = b.path("ios/simulator.entitlements") });
    const exe = b.addExecutable(.{ .name = "nanomail", .root_module = mod });

    if (os == .ios) {
        // zig build $(sh zig-pkg/nanoui-*/tools/ios/zig-lib.sh) -Dtarget=aarch64-ios-simulator
        // makes zig-out/ios/nanomail.app; `run` runs it in the booted Simulator.
        // -Dtarget=aarch64-ios makes it for an iPhone, to be signed for one.
        const opts: nanoui_build.ios.Options = .{ .name = "nanomail", .id = "dev.nanomail.app", .version = @import("build.zig.zon").version, .file_sharing = true };
        // nanoui's Info.plist with one more key: App Transport Security
        // lets plain http:// reach the local network (a test server); the
        // internet takes https only.
        const plist = nanoui_build.ios.infoPlist(b, exe.name, target.result, opts);
        const ats = "  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>\n</dict>\n</plist>";
        const end = std.mem.lastIndexOf(u8, plist, "</dict>") orelse plist.len;
        const wf = b.addWriteFiles();
        _ = wf.add("nanomail.app/Info.plist", b.fmt("{s}{s}\n", .{ plist[0..end], ats }));
        const bin = if (target.result.abi == .simulator) exe.getEmittedBin() else deviceLink(b, mod, target.result);
        _ = wf.addCopyFile(bin, "nanomail.app/nanomail");
        const bundle = wf.getDirectory().path(b, "nanomail.app");
        b.getInstallStep().dependOn(&b.addInstallDirectory(.{ .source_dir = bundle, .install_dir = .prefix, .install_subdir = "ios/nanomail.app" }).step);
        const run = b.step("run", "Run nanomail in the booted Simulator");
        if (target.result.abi == .simulator) {
            const r = nanoui_build.ios.runInSimulator(b, bundle, opts, dep.path("."));
            r.addPassthruArgs();
            run.dependOn(&r.step);
        } else run.dependOn(&b.addFail("run runs in the Simulator (-Dtarget=aarch64-ios-simulator); install on a device from Xcode or with xcrun devicectl").step);
        return;
    }

    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run nanomail (opens its window)").dependOn(&run.step);

    // The app icon, drawn by nanoui offscreen (macos/package.sh).
    const icon = b.addExecutable(.{ .name = "nanomail-icon", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/icon.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    b.step("icon", "Build zig-out/bin/nanomail-icon").dependOn(&b.addInstallArtifact(icon, .{}).step);

    // Tests render views offscreen with ui.Tester: no window opens. With
    // NANOMAIL_TEST_URL set they also talk to that JMAP server.
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    if (apple) tests.root_module.linkFramework("Security", .{});
    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true;
    b.step("test", "Run the tests").dependOn(&run_tests.step);
}

/// The program for an iPhone: Zig compiles it, Apple's linker links it.
/// An iPhone won't start a program Zig 0.17 links itself (the Simulator
/// does), so the Zig code goes in an object, with the frameworks and
/// libraries nanoui's modules and nanomail's ask for.
fn deviceLink(b: *std.Build, mod: *std.Build.Module, target: std.Target) std.Build.LazyPath {
    const obj = b.addObject(.{ .name = "nanomail", .root_module = mod });
    obj.bundle_compiler_rt = true;
    const min = target.os.version_range.semver.min;
    const link = b.addSystemCommand(&.{ "xcrun", "-sdk", "iphoneos", "clang", "-arch", "arm64", b.fmt("-mios-version-min={d}.{d}", .{ min.major, min.minor }) });
    link.addFileArg(obj.getEmittedBin());
    for (mod.getGraph().modules) |m| {
        for (m.frameworks.keys()) |f| link.addArgs(&.{ "-framework", f });
        for (m.link_objects.items) |o| if (o == .system_lib) link.addArg(b.fmt("-l{s}", .{o.system_lib.name}));
    }
    link.addArg("-o");
    return link.addOutputFileArg("nanomail");
}
