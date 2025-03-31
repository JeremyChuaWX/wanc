const std = @import("std");

const pa = @cImport({
    @cInclude("portaudio.h");
});

pub fn main() !void {
    std.log.info("Initializing PortAudio...", .{});

    var err: pa.PaError = pa.Pa_Initialize();
    if (err != pa.paNoError) {
        std.log.err("PortAudio error: {s}", .{pa.Pa_GetErrorText(err)});
        return error.PortAudioInitFailed;
    }
    defer _ = pa.Pa_Terminate();

    std.log.info("PortAudio initialized successfully.", .{});

    const versionInfo = pa.Pa_GetVersionInfo().*;
    std.log.info("PortAudio version: {s}", .{versionInfo.versionText});

    const numDevices = pa.Pa_GetDeviceCount();
    if (numDevices < 0) {
        err = numDevices;
        std.log.err("PortAudio error getting device count: {s}", .{pa.Pa_GetErrorText(err)});
        return error.PortAudioDeviceCountFailed;
    }

    std.log.info("Number of devices: {d}", .{numDevices});

    var i: pa.PaDeviceIndex = 0;
    while (i < numDevices) : (i += 1) {
        const deviceInfoPtr = pa.Pa_GetDeviceInfo(i);
        if (deviceInfoPtr == null) {
            std.log.warn("Could not get info for device {d} (null pointer)", .{i});
            continue;
        }
        const deviceInfo = deviceInfoPtr.*;
        std.log.info("Device {d}: {s}", .{ i, deviceInfo.name });
        std.log.info("  Max Input Channels: {d}", .{deviceInfo.maxInputChannels});
        std.log.info("  Max Output Channels: {d}", .{deviceInfo.maxOutputChannels});
        std.log.info("  Default Sample Rate: {d}", .{deviceInfo.defaultSampleRate});
    }
}
