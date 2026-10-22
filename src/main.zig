const std = @import("std");
const Io = std.Io;

const linux = std.os.linux;

// const c = @cImport(@cInclude("linux/uinput.h"));

pub const UInputSetup = extern struct {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
    name: [80]u8,
    ff_effects_max: u32 = 0,
};

/// ioctl command to exclusively grab a device
pub const EVIOCGRAB = linux.IOCTL.IOW('E', 0x90, c_int);
pub const EVIOCSCLOCKID = linux.IOCTL.IOW('E', 0xa0, c_int);
pub const CLOCK_MONOTONIC = 1;

const UINPUT_IOCTL_BASE = 'U';
pub const UI_SET_EVBIT = linux.IOCTL.IOW(UINPUT_IOCTL_BASE, 100, c_int);
pub const UI_SET_KEYBIT = linux.IOCTL.IOW(UINPUT_IOCTL_BASE, 101, c_int);
pub const UI_DEV_CREATE = linux.IOCTL.IO(UINPUT_IOCTL_BASE, 1);
pub const UI_DEV_DESTROY = linux.IOCTL.IO(UINPUT_IOCTL_BASE, 2);
pub const UI_DEV_SETUP = linux.IOCTL.IOW(UINPUT_IOCTL_BASE, 3, UInputSetup);
pub const EV_KEY = 0x01;
pub const EV_SYN = 0x00;
pub const SYN_REPORT = 0x00;
pub const KEY_MAX = 0x2ff;
pub const KEY_CNT = KEY_MAX + 1;

pub const KEY_LEFTCTRL = 29;
pub const KEY_RIGHTCTRL = 97;
pub const KEY_LEFTSHIFT = 42;
pub const KEY_RIGHTSHIFT = 54;
pub const KEY_LEFTMETA = 125;
pub const KEY_RIGHTMETA = 126;
pub const KEY_LEFTALT = 56;
pub const KEY_RIGHTALT = 100;
pub const EV_LED = 0x11;
pub const LED_CAPSL = 0x01;
const MODIFIERS = [_]u16{ KEY_LEFTCTRL, KEY_RIGHTCTRL, KEY_LEFTSHIFT, KEY_RIGHTSHIFT, KEY_LEFTMETA, KEY_RIGHTMETA, KEY_LEFTALT, KEY_RIGHTALT };

const InputEvent = extern struct { time_sec: linux.time_t, time_usec: linux.time_t, type: u16, code: u16, value: i32 };
const DeviceContext = struct {
    fd: i32,
    path: []u8,
    input_event: InputEvent,
    fn setCapsLockLED(self: *DeviceContext, value: i32) void {
        _ = linux.write(self.fd, @ptrCast(&InputEvent{
            .type = EV_LED,
            .code = LED_CAPSL,
            .value = value,
            .time_sec = 0,
            .time_usec = 0,
        }), @sizeOf(InputEvent));
    }
};

const VirtualDevice = struct {
    fd: i32,

    /// Writes accumulated change events in the state machine to the virtual device.
    /// Guarantees single write to virtual device descriptor.
    fn dispatch(self: *VirtualDevice, transaction: []u8) void {
        // TODO: handle EINTR
        _ = linux.write(self.fd, @ptrCast(transaction), transaction.len);
    }
};

const Config = struct {
    double_tap: u64,
};

const ModifierState = enum(u8) {
    Free,
    Latched,
    Locked,
    fn value(self: ModifierState) i32 {
        if (self == .Free) return 0;
        return 1;
    }
};
const ModifierTransition = [3]ModifierState{ .Latched, .Free, .Free };
const Modifier = struct { last: linux.time_t, state: ModifierState };

const KeyboardHandler = struct {
    modifiers: [8]Modifier,

    // 1 extra for buffer input event
    // 1 extra for ev_syn synchronization event
    delta: [10]InputEvent,

    n_delta: usize,
    n_free: usize,
    double_tap: u64,

    fn unlatch(self: *KeyboardHandler) void {
        for (0..self.modifiers.len) |i| {
            if (self.modifiers[i].state == .Latched) {
                self.modifiers[i].state = .Free;
                self.modifier_delta(i, ModifierState.Free.value());
                self.n_free += 1;
            }
        }
        std.debug.print("\t\t{d} free\n", .{self.n_free});
    }

    fn store_delta(self: *KeyboardHandler, ev: InputEvent) void {
        self.delta[self.n_delta] = ev;
        self.n_delta += 1;
    }

    fn modifier_delta(self: *KeyboardHandler, index: usize, value: i32) void {
        self.store_delta(InputEvent{
            .type = EV_KEY,
            .code = MODIFIERS[index],
            .value = value,
            .time_sec = 0,
            .time_usec = 0,
        });
    }

    /// Appends finishing synchronize event to internal change tracking buffer.
    fn finalize(self: *KeyboardHandler) []u8 {
        self.store_delta(std.mem.zeroes(InputEvent));
        const ret: []u8 = @ptrCast(self.delta[0 .. self.n_delta + 1]);
        self.n_delta = 0;
        return ret;
    }

    fn indicator(self: *KeyboardHandler) i32 {
        return @intFromBool(self.n_free != self.modifiers.len);
    }

    fn modifier_pressed(self: *KeyboardHandler, modifier_index: usize, event_time_ms: linux.time_t) void {
        const modifier = &self.modifiers[modifier_index];
        const elapsed_ms = event_time_ms - modifier.last;

        var new_state = ModifierState.Locked;

        if (elapsed_ms > self.double_tap)
            new_state = ModifierTransition[@intFromEnum(modifier.state)];

        if (modifier.state != new_state) {
            const old_free = modifier.state == .Free;
            const new_free = new_state == .Free;
            if (!old_free and new_free) self.n_free += 1;
            if (!new_free and old_free) self.n_free -= 1;

            modifier.state = new_state;
            self.modifier_delta(modifier_index, new_state.value());
        }
        modifier.last = event_time_ms;

        std.debug.print("{d} = {any}\t{d} free\n", .{ modifier_index, modifier.state, self.n_free });
    }
};

const max_path_bytes = Io.Dir.max_path_bytes;

const DeviceDetectionError = error{NoKeyboardFound};
const DebugError = error{EscapeHatch};

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
            const offset = std.mem.find(u8, line.buffer[handler_prefix.len..], "event") orelse continue;
            const began = offset + handler_prefix.len;
            const ended = (std.mem.find(u8, line.buffer[began..], " ") orelse line.end) + began;

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
    pb[pb_len] = 0;

    // pb must live as long as device
    var device = DeviceContext{
        .fd = 0,
        .input_event = undefined,
        .path = pb[0 .. pb_len + 1],
    };

    const keyboard: i32 = @intCast(linux.open(@ptrCast(device.path), .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0o644));
    defer _ = linux.close(keyboard);

    device.fd = keyboard;

    try io.sleep(.fromSeconds(1), .awake);

    _ = linux.ioctl(device.fd, EVIOCSCLOCKID, CLOCK_MONOTONIC);
    _ = linux.ioctl(device.fd, EVIOCGRAB, 1);
    defer _ = linux.ioctl(device.fd, EVIOCGRAB, 0);

    try io.sleep(.fromSeconds(1), .awake);

    const uinput_fd: i32 = @intCast(linux.open("/dev/uinput", .{ .ACCMODE = .WRONLY, .NONBLOCK = true }, 0o644));
    defer _ = linux.close(uinput_fd);

    _ = linux.ioctl(uinput_fd, UI_SET_EVBIT, EV_KEY);
    for (0..KEY_CNT) |i| {
        _ = linux.ioctl(uinput_fd, UI_SET_KEYBIT, i);
    }

    var setup = std.mem.zeroes(UInputSetup);
    setup.vendor = 0xbabe;
    setup.product = 0x1337;
    setup.version = 0x0001;
    const name = "sticky keys";
    for (name, 0..) |v, i| {
        setup.name[i] = v;
    }

    _ = linux.ioctl(uinput_fd, UI_DEV_SETUP, @intFromPtr(&setup));
    _ = linux.ioctl(uinput_fd, UI_DEV_CREATE, 0);

    defer _ = linux.ioctl(uinput_fd, UI_DEV_DESTROY, 0);

    var virtual_device = VirtualDevice{ .fd = uinput_fd };

    var ring = try linux.IoUring.init(16, 0);
    defer ring.deinit();

    std.debug.print("latched to {s}\n", .{device.path});

    _ = try ring.read(@intFromPtr(&device), device.fd, .{ .buffer = @ptrCast(&device.input_event) }, 0);
    // TODO: queue future device requests like touchpads here

    // config from ini file
    const config = Config{ .double_tap = 200 };
    var machine: KeyboardHandler = .{ .modifiers = std.mem.zeroes([8]Modifier), .double_tap = config.double_tap, .delta = undefined, .n_delta = 0, .n_free = 8 };

    // ring.timeout(user_data: u64, ts: *const kernel_timespec, count: u32, flags: u32)
    var user_data: u64 = 0;
    while (true) : (user_data += 1) {
        _ = try ring.submit_and_wait(1);
        try consumeAndRequeue(&ring, &virtual_device, &machine);
    }
}

fn consumeAndRequeue(ring: *linux.IoUring, virtual_device: *VirtualDevice, machine: *KeyboardHandler) !void {
    const head = ring.cq.head.* & ring.cq.mask;
    const cqe = ring.cq.cqes[head];
    defer ring.cq_advance(1);

    if (cqe.res != @sizeOf(InputEvent)) {
        return;
    }

    // cater to whichever device sends an event
    const device_context_ptr = cqe.user_data;
    const device_context: *DeviceContext = @ptrFromInt(device_context_ptr);

    const is_key = device_context.input_event.type == EV_KEY;

    if (is_key) {
        if (device_context.input_event.code == KEY_RIGHTALT) return DebugError.EscapeHatch;
        const modifier_index = std.mem.findScalar(u16, &MODIFIERS, device_context.input_event.code);

        if (modifier_index == null) {
            machine.store_delta(device_context.input_event);
            machine.unlatch();
            virtual_device.dispatch(machine.finalize());
        }

        if (modifier_index != null and device_context.input_event.value == 1) {
            const event_time_ms = device_context.input_event.time_sec * 1000 + @divTrunc(device_context.input_event.time_usec, 1000);
            machine.modifier_pressed(modifier_index.?, event_time_ms);
            virtual_device.dispatch(machine.finalize());
        }

        device_context.setCapsLockLED(machine.indicator());
    }

    _ = try ring.read(device_context_ptr, device_context.fd, .{ .buffer = @ptrCast(&device_context.input_event) }, 0);
}

test "test sample devices proc file" {
    const io = std.testing.io;
    var file = try std.Io.Dir.cwd().openFile(io, "tests/procfile", .{ .mode = .read_only });
    defer file.close(io);
    var pb: [max_path_bytes]u8 = undefined;
    const name_len = try parseInputProcFile(file, &pb, io);
    const is_event0 = std.mem.eql(u8, pb[0..name_len], "/dev/input/event0");
    try std.testing.expect(is_event0);
}
