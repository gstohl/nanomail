//! Every test: the protocol and mail helpers, and the views through ui.Tester.
test {
    _ = @import("jmap/types.zig");
    _ = @import("jmap/protocol.zig");
    _ = @import("mail/html.zig");
    _ = @import("mail/links.zig");
    _ = @import("mail/dates.zig");
    _ = @import("mail/address.zig");
    _ = @import("mail/kinds.zig");
    _ = @import("copy.zig");
    _ = @import("compose.zig");
    _ = @import("jmap/session.zig");
    _ = @import("jmap/send.zig");
    _ = @import("jmap/oauth.zig");
    _ = @import("jmap/loopback.zig");
    _ = @import("tests_client.zig");
    _ = @import("tests_views.zig");
    // NSURLSession: Apple's only.
    if (@import("builtin").os.tag.isDarwin()) {
        _ = @import("jmap/http_apple.zig");
        _ = @import("jmap/http_apple_stream.zig");
    }
    _ = @import("tests_rich.zig");
    _ = @import("tests_layout.zig");
}
