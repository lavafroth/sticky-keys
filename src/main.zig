const std = @import("std");
const Io = std.Io;

const linux = std.os.linux;

const InputEvent = extern struct { time_sec: linux.time_t, time_usec: linux.time_t, type: u16, code: u16, value: i32 };

const DeviceContext = struct { fd: i32, path: []u8, input_event: InputEvent };

const sticky_keys = @import("sticky_keys");
const max_path_bytes = Io.Dir.max_path_bytes;

const DeviceDetectionError = error{NoKeyboardFound};

/// Greedily fills the pb buffer with the name of the first
/// `kbd` handler device having the word "keyboard" in the name.
/// Returns the length of the path.
pub fn detectKeyboard(pb: *[max_path_bytes]u8, io: Io) !usize {
    var file = try std.Io.Dir.openFileAbsolute(io, "/proc/bus/input/devices", .{ .mode = .read_only });
    defer file.close(io);
    return parseInputProcFile(file, pb, io);
}

pub fn parseInputProcFile(file: Io.File, pb: *[max_path_bytes]u8, io: Io) !usize {
    var read_buffer: [4 * max_path_bytes]u8 = undefined;
    var fr = file.reader(io, &read_buffer);
    var reader = &fr.interface;

    var line_buffer: [max_path_bytes]u8 = undefined;
    var line = std.Io.Writer.fixed(&line_buffer);
    var name_has_keyboard = false;

    const name_prefix = "N: Name=";
    const handler_prefix = "H: Handlers=";

    while (true) : (line.end = 0) {
        const consumed = reader.streamDelimiter(&line, '\n') catch |err| {
            if (err == error.EndOfStream) break else return err;
        };
        _ = reader.toss(1);
        if (consumed == 0) {
            name_has_keyboard = false;
        }

        if (std.mem.eql(u8, line.buffer[0..name_prefix.len], name_prefix)) {
            name_has_keyboard = std.mem.find(u8, line.buffer[name_prefix.len..], "keyboard") != null;
            continue;
        }
        if (std.mem.eql(u8, line.buffer[0..handler_prefix.len], handler_prefix) and
            std.mem.find(u8, line.buffer[handler_prefix.len..], "kbd") != null)
        {
            var offset = std.mem.find(u8, line.buffer[handler_prefix.len..], "event") orelse continue;
            const began = offset + handler_prefix.len;
            offset = std.mem.find(u8, line.buffer[began..], " ") orelse continue;
            const ended = offset + began;

            // device_path_len = offset;

            if (name_has_keyboard) {
                const written = try std.fmt.bufPrint(pb, "/dev/input/{s}", .{line.buffer[began..ended]});
                return written.len;
            }
        }
    }
    return DeviceDetectionError.NoKeyboardFound;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var pb: [max_path_bytes]u8 = undefined;
    const pb_len = try detectKeyboard(&pb, io);

    // pb must live as long as device
    var device = DeviceContext{
        .fd = 0,
        .input_event = undefined,
        .path = pb[0..pb_len],
    };
    const file = try Io.Dir.openFileAbsolute(io, device.path, .{ .mode = .read_only });
    defer file.close(io);

    device.fd = file.handle;

    var ring = try linux.IoUring.init(16, 0);
    defer ring.deinit();

    while (true) {
        _ = try ring.read(69, device.fd, linux.IoUring.ReadBuffer{ .buffer = @ptrCast(&device.input_event) }, 0);
        _ = try ring.submit_and_wait(1);
        const cqe = try ring.copy_cqe();

        if (device.input_event.type != 1) { // EV_KEY
            continue;
        }

        std.debug.print("result {d} userdata: {d}\n", .{ cqe.res, cqe.user_data });
        std.debug.print("{any}\n", .{device.input_event});
    }
}

test "test sample devices proc file" {
    const io = std.testing.io;
    var file = try std.Io.Dir.cwd().openFile(io, "tests/procfile", .{ .mode = .read_only });
    defer file.close(io);
    var pb: [max_path_bytes]u8 = undefined;
    _ = try parseInputProcFile(file, &pb, io);
}
