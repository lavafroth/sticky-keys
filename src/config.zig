const std = @import("std");
const Io = std.Io;

pub const Config = struct {
    double_tap: u64,
    touch_timeout: i64,
    touch_grace_area: i64,
    modifiers_enabled: [8]bool,
};

pub const default = Config{
    .double_tap = 200,
    .touch_grace_area = 300,
    .touch_timeout = 500,
    .modifiers_enabled = [8]bool{ true, true, true, true, true, true, true, true },
};

const config_options = [_]struct { []const u8, u8 }{
    .{ "double-tap-timeout-ms", 2 },
    .{ "grace-area", 4 },
    .{ "unlatch-timeout-ms", 6 },
    .{ "modifiers", 8 },
};

const read_buffer_size = 4096;
const line_buffer_size = 256;
const config_options_map = std.static_string_map.StaticStringMap(u8).initComptime(config_options);

const MODIFIER_NAMES = [_][]const u8{ "leftctrl", "rightctrl", "leftshift", "rightshift", "leftmeta", "rightmeta", "leftalt", "rightalt" };

pub fn parseConfig(path: []const u8, io: Io) !Config {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    var read_buffer: [read_buffer_size]u8 = undefined;
    var fr = file.reader(io, &read_buffer);
    var reader = &fr.interface;

    var line_buffer: [line_buffer_size]u8 = undefined;
    var line = std.Io.Writer.fixed(&line_buffer);

    var config = Config{
        .double_tap = 200,
        .touch_grace_area = 300,
        .touch_timeout = 500,
        .modifiers_enabled = [8]bool{ false, false, false, false, false, false, false, false },
    };

    var in_section_touchpad: u8 = 0;
    while (true) : (line.end = 0) {
        _ = reader.streamDelimiter(&line, '\n') catch |err| {
            if (err == error.EndOfStream) break else return err;
        };
        _ = reader.toss(1);
        const line_contents = line.buffer[0..line.end];
        const line_trimmed = std.mem.trim(u8, line_contents, "\r\n ");

        if (std.mem.eql(u8, line_trimmed, "[touchpad]")) in_section_touchpad = 1;
        if (line_trimmed.len == 0) {
            in_section_touchpad = 0;
            continue;
        }

        var iter = std.mem.splitScalar(u8, line_trimmed, '=');

        while (true) {
            const entry = std.mem.trim(u8, (iter.next() orelse break), " ");
            const value = std.mem.trim(u8, (iter.next() orelse break), " ");

            const config_option = in_section_touchpad | (config_options_map.get(entry) orelse 0);

            switch (config_option) {
                2 => config.double_tap = try std.fmt.parseUnsigned(u64, value, 10),
                5 => config.touch_grace_area = @intCast(try std.fmt.parseUnsigned(u32, value, 10)),
                7 => config.touch_timeout = @intCast(try std.fmt.parseUnsigned(u32, value, 10)),
                8 => {
                    var modifiers = std.mem.splitScalar(u8, value, ' ');
                    while (modifiers.next()) |modifier| {
                        for (0.., MODIFIER_NAMES) |i, name| {
                            if (std.mem.eql(u8, name, modifier)) {
                                config.modifiers_enabled[i] = true;
                                break;
                            }
                        }
                    }
                },
                else => {
                    std.log.err("config file defines unknown property{s}: {s}", .{ if (in_section_touchpad == 1) " in touchpad section" else "", entry });
                    return ConfigError.UnknownProperty;
                },
            }
        }
    }

    var any_modifier_chosen = false;
    for (config.modifiers_enabled) |v| any_modifier_chosen |= v;

    if (!any_modifier_chosen) {
        config.modifiers_enabled = [8]bool{ true, true, true, true, true, true, true, true };
    }
    return config;
}

pub const ConfigError = error{UnknownProperty};
