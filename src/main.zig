const std = @import("std");

const pa = @cImport({
    @cInclude("portaudio.h");
});

const SAMPLE_FORMAT: pa.PaSampleFormat = pa.paFloat32;

fn printPaError(comptime context: []const u8, err_code: pa.PaError) void {
    const err_text = pa.Pa_GetErrorText(err_code);
    std.log.err("{s} failed: [{d}] {s}", .{
        context, err_code, std.mem.span(err_text),
    });
}

const CallbackData = struct {
    channel_count: c_int,
};

fn paCallback(
    inputBuffer: ?*const anyopaque,
    outputBuffer: ?*anyopaque,
    frameCount: c_ulong,
    timeInfo: ?*const pa.PaStreamCallbackTimeInfo,
    statusFlags: pa.PaStreamCallbackFlags,
    userData: ?*anyopaque, // Pointer to our CallbackData
) callconv(.C) c_int {
    _ = outputBuffer;
    _ = timeInfo;

    if (statusFlags & pa.paInputOverflow != 0) {
        std.debug.print("Warning: Input overflow detected in callback!\n", .{});
    }
    if (statusFlags & pa.paInputUnderflow != 0) {
        std.debug.print("Warning: Input underflow detected in callback!\n", .{});
    }

    if (inputBuffer == null) {
        std.debug.print("Warning: Null input buffer in callback!\n", .{});
        return pa.paContinue;
    }

    if (userData == null) {
        std.debug.print("Error: userData is null in callback!\n", .{});
        return pa.paAbort; // Cannot proceed without channel count
    }
    const data: *const CallbackData = @ptrCast(@alignCast(userData.?));
    const num_channels = data.channel_count;

    const input_samples: [*c]const f32 = @ptrCast(@alignCast(inputBuffer.?));
    const num_samples = frameCount * @as(c_ulong, @intCast(num_channels));

    var peak: f32 = 0.0;
    var sum_sq: f64 = 0.0;

    var i: c_ulong = 0;
    while (i < num_samples) : (i += 1) {
        const sample = input_samples[i];
        const abs_sample = @abs(sample);
        if (abs_sample > peak) {
            peak = abs_sample;
        }
        sum_sq += @as(f64, sample) * @as(f64, sample);
    }

    const rms = if (num_samples > 0)
        std.math.sqrt(sum_sq / @as(f64, @floatFromInt(num_samples)))
    else
        0.0;

    std.debug.print("Callback: frames={d} peak={d:.4} RMS={d:.4}\n", .{
        frameCount, peak, rms,
    });

    return pa.paContinue;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    _ = allocator;

    std.log.info("PortAudio Input Example (Callback - Device Defaults)", .{});

    var err: pa.PaError = undefined;

    std.log.info("Initializing PortAudio...", .{});
    err = pa.Pa_Initialize();
    if (err != pa.paNoError) {
        printPaError("Pa_Initialize", err);
        return error.PortAudioInitFailed;
    }
    defer {
        std.log.info("Terminating PortAudio...", .{});
        const term_err = pa.Pa_Terminate();
        if (term_err != pa.paNoError) {
            printPaError("Pa_Terminate", term_err);
        }
    }

    const inputDeviceIndex = pa.Pa_GetDefaultInputDevice();
    if (inputDeviceIndex == pa.paNoDevice) {
        std.log.err("No default input device found.", .{});
        return error.NoInputDevice;
    }
    std.log.info("Default Input Device Index: {d}", .{inputDeviceIndex});

    const deviceInfo = pa.Pa_GetDeviceInfo(inputDeviceIndex);
    if (deviceInfo == null) {
        std.log.err("Could not get device info for index {d}", .{inputDeviceIndex});
        return error.DeviceInfoFailed;
    }
    std.log.info("Using Device: {s}", .{std.mem.span(deviceInfo.*.name)});

    const sample_rate: f64 = deviceInfo.*.defaultSampleRate;
    const max_input_channels: c_int = deviceInfo.*.maxInputChannels;

    if (max_input_channels == 0) {
        std.log.err("Selected device '{s}' has no input channels.", .{
            std.mem.span(deviceInfo.*.name),
        });
        return error.NoInputChannelsOnDevice;
    }
    const num_channels: c_int = 1; // Use mono if possible

    // Let PortAudio determine the optimal buffer size based on latency.
    const frames_per_buffer: c_ulong = pa.paFramesPerBufferUnspecified;

    std.log.info(
        \\Using Device Defaults: Sample Rate={d:.1}, Channels={d}, FramesPerBuffer=Unspecified
    , .{ sample_rate, num_channels });

    var callback_data = CallbackData{
        .channel_count = num_channels,
    };

    var inputParameters: pa.PaStreamParameters = .{
        .device = inputDeviceIndex,
        .channelCount = num_channels, // Use determined channel count
        .sampleFormat = SAMPLE_FORMAT, // Use configured format
        .suggestedLatency = deviceInfo.*.defaultLowInputLatency, // Use device low latency
        .hostApiSpecificStreamInfo = null,
    };

    var stream: ?*pa.PaStream = null;
    std.log.info("Opening stream...", .{});
    err = pa.Pa_OpenStream(
        &stream,
        &inputParameters,
        null, // No output
        sample_rate, // Use determined sample rate
        frames_per_buffer, // Use paFramesPerBufferUnspecified
        pa.paNoFlag,
        paCallback,
        &callback_data, // Pass pointer to our data struct
    );
    if (err != pa.paNoError) {
        printPaError("Pa_OpenStream", err);
        return error.StreamOpenFailed;
    }
    defer {
        if (stream != null) {
            std.log.info("Closing stream...", .{});
            const close_err = pa.Pa_CloseStream(stream);
            if (close_err != pa.paNoError) {
                printPaError("Pa_CloseStream", close_err);
            }
        }
    }

    const streamInfo = pa.Pa_GetStreamInfo(stream);
    if (streamInfo != null) {
        std.log.info("Actual Stream Info: Latency={d:.4}s, SampleRate={d:.1}Hz", .{
            streamInfo.*.inputLatency, streamInfo.*.sampleRate,
        });
    }

    std.log.info("Starting stream...", .{});
    err = pa.Pa_StartStream(stream);
    if (err != pa.paNoError) {
        printPaError("Pa_StartStream", err);
        return error.StreamStartFailed;
    }
    defer {
        if (stream != null) {
            std.log.info("Stopping stream...", .{});
            const stop_err = pa.Pa_AbortStream(stream);
            if (stop_err != pa.paNoError) {
                printPaError("Pa_AbortStream", stop_err);
            }
        }
    }

    std.log.info("Stream is active. Listening for 10 seconds...", .{});
    std.log.info("Check your console for 'Callback:' messages.", .{});
    pa.Pa_Sleep(1000); // Sleep for 1s (Pa_Sleep takes milliseconds)
    std.log.info("Finished listening.", .{});

    std.log.info("Exiting normally.", .{});
}
