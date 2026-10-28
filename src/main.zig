const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const config = @import("config.zig");

/// ioctl command to exclusively grab a device
pub const EVIOCGRAB = linux.IOCTL.IOW('E', 0x90, c_int);
pub const EVIOCSCLOCKID = linux.IOCTL.IOW('E', 0xa0, c_int);
pub const CLOCK_MONOTONIC = 1;
pub const EV_SYN = 0x00;
pub const EV_KEY = 0x01;
pub const ABS_X = 0x00;
pub const ABS_Y = 0x01;
pub const EV_ABS = 0x03;
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
pub const BTN_LEFT = 0x110;
pub const BTN_RIGHT = 0x111;
pub const BTN_TOOL_FINGER = 0x145;
pub const BTN_TOUCH = 0x14a;

const MODIFIERS = [_]u16{ KEY_LEFTCTRL, KEY_RIGHTCTRL, KEY_LEFTSHIFT, KEY_RIGHTSHIFT, KEY_LEFTMETA, KEY_RIGHTMETA, KEY_LEFTALT, KEY_RIGHTALT };

pub const UInputSetup = extern struct {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
    name: [80]u8,
    ff_effects_max: u32 = 0,
};

const UINPUT_IOCTL_BASE = 'U';
pub const UI_SET_EVBIT = linux.IOCTL.IOW(UINPUT_IOCTL_BASE, 100, c_int);
pub const UI_SET_KEYBIT = linux.IOCTL.IOW(UINPUT_IOCTL_BASE, 101, c_int);
pub const UI_DEV_CREATE = linux.IOCTL.IO(UINPUT_IOCTL_BASE, 1);
pub const UI_DEV_DESTROY = linux.IOCTL.IO(UINPUT_IOCTL_BASE, 2);
pub const UI_DEV_SETUP = linux.IOCTL.IOW(UINPUT_IOCTL_BASE, 3, UInputSetup);

const InputEvent = extern struct {
    time_sec: linux.time_t,
    time_usec: linux.time_t,
    type: u16,
    code: u16,
    value: i32,
    fn timeMilliseconds(self: *InputEvent) i64 {
        return self.time_sec * 1000 + @divTrunc(self.time_usec, 1000);
    }
};
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
    fn sync(self: *DeviceContext) void {
        _ = linux.write(self.fd, @ptrCast(&std.mem.zeroes(InputEvent)), @sizeOf(InputEvent));
    }
};

const VirtualDevice = struct {
    fd: i32,

    fn dispatch(self: *VirtualDevice, transaction: []const u8) void {
        // TODO: handle EINTR
        _ = linux.write(self.fd, @ptrCast(transaction), transaction.len);
    }

    fn sendEvent(self: *VirtualDevice, typ: u16, code: u16, value: i32) void {
        self.dispatch(@ptrCast(&InputEvent{ .code = code, .type = typ, .value = value, .time_sec = 0, .time_usec = 0 }));
    }

    fn sync(self: *VirtualDevice) void {
        self.sendEvent(EV_SYN, SYN_REPORT, 0);
    }

    fn sendKey(self: *VirtualDevice, code: u16, value: i32) void {
        self.sendEvent(EV_KEY, code, value);
    }
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

const Point2D = struct {
    x: i64,
    y: i64,
};

const TouchStage = enum(u8) {
    NotedXY = 0,
    Initialized,
    NotedX,
};

const Touch = struct {
    began: Point2D,
    ended: Point2D,
    last_ms: i64,
    stage: TouchStage,
    active_timer_id: u64,
};

const Handler = struct {
    modifiers: [8]Modifier,
    keyboard: *DeviceContext,
    virtual_device: *VirtualDevice,
    touch: Touch,
    config: *const config.Config,

    fn unlatch(self: *Handler) void {
        for (0..self.modifiers.len) |i| {
            if (self.modifiers[i].state == .Latched) self.modifiers[i].state = .Free;
        }
    }

    fn commit(self: *Handler) void {
        for (0..self.modifiers.len) |i| {
            self.virtual_device.sendKey(MODIFIERS[i], self.modifiers[i].state.value());
        }
        self.virtual_device.sync();
        self.keyboard.setCapsLockLED(self.indicator());
        self.keyboard.sync();
    }

    fn indicator(self: *Handler) i32 {
        for (self.modifiers) |m| {
            if (m.state != .Free) return 1;
        }
        return 0;
    }

    fn anyLatched(self: *Handler) bool {
        for (self.modifiers) |m| {
            if (m.state == .Latched) return true;
        }
        return false;
    }

    fn modifierPressed(self: *Handler, modifier_index: usize, event_time_ms: linux.time_t) void {
        const modifier = &self.modifiers[modifier_index];
        const elapsed_ms = event_time_ms - modifier.last;

        var new_state = ModifierState.Locked;

        if (elapsed_ms > self.config.double_tap)
            new_state = ModifierTransition[@intFromEnum(modifier.state)];

        if (modifier.state != new_state) modifier.state = new_state;

        modifier.last = event_time_ms;
    }

    fn tapEuclideanDistanceSquare(self: *Handler) i64 {
        const dx = self.touch.ended.x - self.touch.began.x;
        const dy = self.touch.ended.y - self.touch.began.y;
        return dx * dx + dy * dy;
    }
};

const input_device_max_size = "/dev/input/event".len + 8;
const read_buffer_size = 4096;
const line_buffer_size = 256;

const DeviceDetectionError = error{NoKeyboardFound};
const DebugError = error{EscapeHatch};

/// Greedily fills the pb buffer with the name of the first
/// `kbd` handler device having the word "keyboard" in the name.
/// Returns the length of the path.
pub fn detectDevice(pb: *[input_device_max_size]u8, category: DeviceCategory, io: Io) !usize {
    var file = try std.Io.Dir.openFileAbsolute(io, "/proc/bus/input/devices", .{ .mode = .read_only });
    defer file.close(io);
    return parseInputProcFile(file, pb, category, io);
}

const DeviceCategory = enum(u8) { Keyboard, Touchpad };

pub fn parseInputProcFile(file: Io.File, pb: *[input_device_max_size]u8, category: DeviceCategory, io: Io) !usize {
    var read_buffer: [read_buffer_size]u8 = undefined;
    var fr = file.reader(io, &read_buffer);
    var reader = &fr.interface;

    var line_buffer: [line_buffer_size]u8 = undefined;
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

        var name_pattern: []const u8 = @ptrCast("keyboard");
        var id_pattern: []const u8 = @ptrCast("kbd");

        switch (category) {
            .Keyboard => {},
            .Touchpad => {
                name_pattern = "touchpad";
                id_pattern = "mouse";
            },
        }

        if (std.mem.eql(u8, line.buffer[0..name_prefix.len], name_prefix)) {
            name_has_keyboard = std.ascii.findIgnoreCase(line.buffer[name_prefix.len..], name_pattern) != null;
            continue;
        }
        if (std.mem.eql(u8, line.buffer[0..handler_prefix.len], handler_prefix) and
            std.mem.find(u8, line.buffer[handler_prefix.len..], id_pattern) != null)
        {
            const offset = std.mem.find(u8, line.buffer[handler_prefix.len..], "event") orelse continue;
            const began = offset + handler_prefix.len;
            const ended = (std.mem.find(u8, line.buffer[began..], " ") orelse line.end) + began;

            if (name_has_keyboard) {
                // write cstr
                const written = try std.fmt.bufPrint(pb, "/dev/input/{s}\x00", .{line.buffer[began..ended]});
                return written.len;
            }
        }
    }
    return DeviceDetectionError.NoKeyboardFound;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // config from ini file
    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next();
    const config_path = args_iter.next();
    const config_opts = if (config_path != null) try config.parseConfig(config_path.?, io) else config.default;

    var keyboard_pb: [input_device_max_size]u8 = undefined;
    var touchpad_pb: [input_device_max_size]u8 = undefined;

    const keyboard_pb_len = try detectDevice(&keyboard_pb, .Keyboard, io);
    const touchpad_pb_len = try detectDevice(&touchpad_pb, .Touchpad, io);

    // pb must live as long as device
    var keyboard = DeviceContext{
        .fd = 0,
        .input_event = undefined,
        .path = keyboard_pb[0..keyboard_pb_len],
    };

    keyboard.fd = @intCast(linux.open(@ptrCast(keyboard.path), .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0o644));
    defer _ = linux.close(keyboard.fd);

    var touchpad_device = DeviceContext{
        .fd = 0,
        .input_event = undefined,
        .path = touchpad_pb[0..touchpad_pb_len],
    };

    touchpad_device.fd = @intCast(linux.open(@ptrCast(touchpad_device.path), .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0o644));
    defer _ = linux.close(touchpad_device.fd);

    try io.sleep(.fromSeconds(1), .awake);

    _ = linux.ioctl(keyboard.fd, EVIOCSCLOCKID, CLOCK_MONOTONIC);
    _ = linux.ioctl(keyboard.fd, EVIOCGRAB, 1);
    defer _ = linux.ioctl(keyboard.fd, EVIOCGRAB, 0);

    _ = linux.ioctl(touchpad_device.fd, EVIOCSCLOCKID, CLOCK_MONOTONIC);

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

    std.debug.print("latched to {s}\n", .{keyboard.path});

    _ = try ring.read(@intFromPtr(&keyboard), keyboard.fd, .{ .buffer = @ptrCast(&keyboard.input_event) }, 0);
    _ = try ring.read(@intFromPtr(&touchpad_device), touchpad_device.fd, .{ .buffer = @ptrCast(&touchpad_device.input_event) }, 0);

    var machine: Handler = .{
        .keyboard = &keyboard,
        .virtual_device = &virtual_device,
        .modifiers = std.mem.zeroes([8]Modifier),
        .config = &config_opts,
        .touch = std.mem.zeroes(Touch),
    };

    const timer: linux.kernel_timespec = .{
        .sec = 0,
        .nsec = config_opts.touch_timeout * 1000 * 1000,
    };

    while (true) {
        _ = try ring.submit_and_wait(1);
        try consumeAndRequeue(&ring, &machine, &timer);
    }
}

fn consumeAndRequeue(ring: *linux.IoUring, machine: *Handler, timer: *const linux.kernel_timespec) !void {
    const head = ring.cq.head.* & ring.cq.mask;
    const cqe = ring.cq.cqes[head];
    defer ring.cq_advance(1);

    if (cqe.res != @sizeOf(InputEvent)) {
        if (cqe.user_data != machine.touch.active_timer_id) return;
        machine.unlatch();
        machine.commit();
        return;
    }

    // cater to whichever device sends an event
    const device_context_ptr = cqe.user_data;
    const device_context: *DeviceContext = @ptrFromInt(device_context_ptr);

    const triggerTimer = try handleEvent(machine, device_context);
    if (triggerTimer) _ = try ring.timeout(machine.touch.active_timer_id, timer, 0, 0);
    _ = try ring.read(device_context_ptr, device_context.fd, .{ .buffer = @ptrCast(&device_context.input_event) }, 0);
}

fn handleEvent(machine: *Handler, device_context: *DeviceContext) !bool {
    const code = device_context.input_event.code;
    const value = device_context.input_event.value;

    const is_key = device_context.input_event.type == EV_KEY;
    const is_coordinate = device_context.input_event.type == EV_ABS;
    const is_pressed = value == 1;
    const click_not_touch = is_key and (code == BTN_LEFT or code == BTN_RIGHT or code == BTN_TOOL_FINGER);
    const click_is_touch = is_key and code == BTN_TOUCH;
    const key_not_click = is_key and !(click_is_touch or click_not_touch);
    const touch_pressed = click_is_touch and is_pressed;
    const second_tap_in_time = touch_pressed and device_context.input_event.timeMilliseconds() < machine.touch.last_ms + machine.config.touch_timeout;
    const touch_released = click_is_touch and value == 0;
    const x_axis = is_coordinate and code == ABS_X;
    const y_axis = is_coordinate and code == ABS_Y;
    const threshold: i64 = machine.config.touch_grace_area;
    const released_inside_circle = touch_released and machine.tapEuclideanDistanceSquare() < threshold * threshold;
    const released_beyond_circle = touch_released and !released_inside_circle;
    const trigger_timer = released_inside_circle and machine.anyLatched();
    const modifier_index = if (key_not_click) std.mem.findScalar(u16, &MODIFIERS, device_context.input_event.code) else null;
    const passthrough_modifier = modifier_index != null and !machine.config.modifiers_enabled[modifier_index.?];
    const catchall_key = key_not_click and modifier_index == null;
    const modifier_key_pressed = modifier_index != null and is_pressed and !passthrough_modifier;

    if (touch_released) machine.touch.last_ms = device_context.input_event.timeMilliseconds();
    if (trigger_timer) return true;
    if (second_tap_in_time) machine.touch.active_timer_id +%= 1;

    if (touch_pressed) machine.touch.stage = .Initialized;

    if (released_beyond_circle) {
        machine.unlatch();
        machine.commit();
    }

    if (catchall_key) {
        machine.virtual_device.dispatch(@ptrCast(&device_context.input_event));
        machine.virtual_device.sync();
        machine.unlatch();
        machine.commit();
    }

    if (passthrough_modifier) {
        if (value == 0) {
            machine.modifiers[modifier_index.?].state = .Free;
        } else {
            machine.modifiers[modifier_index.?].state = .Locked;
        }
        machine.virtual_device.dispatch(@ptrCast(&device_context.input_event));
        machine.virtual_device.sync();
        machine.commit();
    }

    if (modifier_key_pressed) {
        machine.modifierPressed(modifier_index.?, device_context.input_event.timeMilliseconds());
        machine.commit();
    }

    if (key_not_click and device_context.input_event.code == KEY_RIGHTALT) {
        return DebugError.EscapeHatch;
    }

    // the kernel sends x and y values in separate events:
    // first note x value, then y
    if (x_axis and machine.touch.stage == .Initialized) {
        machine.touch.began.x = value;
        machine.touch.stage = .NotedX;
    }

    if (y_axis and machine.touch.stage == .NotedX) {
        machine.touch.began.y = value;
        machine.touch.stage = .NotedXY;
    }

    if (x_axis) machine.touch.ended.x = value;
    if (y_axis) machine.touch.ended.y = value;

    return false;
}

test "test sample devices proc file" {
    const io = std.testing.io;
    var file = try std.Io.Dir.cwd().openFile(io, "tests/procfile", .{ .mode = .read_only });
    defer file.close(io);
    var pb: [input_device_max_size]u8 = undefined;
    const name_len = try parseInputProcFile(file, &pb, .Keyboard, io);
    const is_event0 = std.mem.eql(u8, pb[0..name_len], "/dev/input/event0");
    try std.testing.expect(is_event0);
}
