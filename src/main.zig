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
    inputBuffer: ?*const anyopaque, // const void *input
    outputBuffer: ?*anyopaque, // void *output
    frameCount: c_ulong, // Number of frames for BOTH buffers
    timeInfo: ?*const pa.PaStreamCallbackTimeInfo,
    statusFlags: pa.PaStreamCallbackFlags,
    userData: ?*anyopaque, // Pointer to our CallbackData
) callconv(.C) c_int {
    _ = timeInfo;

    if (statusFlags & pa.paInputOverflow != 0) {
        std.debug.print("Warning: Input overflow detected!\n", .{});
    }
    if (statusFlags & pa.paOutputUnderflow != 0) {
        std.debug.print("Warning: Output underflow detected!\n", .{});
    }

    if (userData == null) {
        std.debug.print("Error: userData is null in callback!\n", .{});
        return pa.paAbort;
    }
    const data: *const CallbackData = @ptrCast(@alignCast(userData.?));
    const num_channels = data.channel_count;

    if (outputBuffer == null) {
        std.debug.print("Error: Null output buffer in callback!\n", .{});
        return pa.paAbort;
    }

    const output_samples: [*c]f32 = @ptrCast(@alignCast(outputBuffer.?)); // mutable
    const num_samples_total = frameCount * @as(c_ulong, @intCast(num_channels));
    const output_slice = output_samples[0..num_samples_total];

    if (inputBuffer == null) {
        std.debug.print("Input buffer null, outputting silence.\n", .{});
        @memset(output_slice, 0.0);
        return pa.paContinue;
    }

    const input_samples: [*c]const f32 = @ptrCast(@alignCast(inputBuffer.?));
    const input_slice = input_samples[0..num_samples_total];

    for (input_slice, 0..) |input_sample, i| {
        output_slice[i] = -input_sample;
    }

    return pa.paContinue;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    _ = allocator;

    std.log.info("PortAudio Full-Duplex Example (Callback)", .{});

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
    const outputDeviceIndex = pa.Pa_GetDefaultOutputDevice();
    if (outputDeviceIndex == pa.paNoDevice) {
        std.log.err("No default output device found.", .{});
        return error.NoOutputDevice;
    }
    std.log.info("Default Input Device Index: {d}", .{inputDeviceIndex});
    std.log.info("Default Output Device Index: {d}", .{outputDeviceIndex});

    const inputDeviceInfo = pa.Pa_GetDeviceInfo(inputDeviceIndex);
    if (inputDeviceInfo == null) {
        std.log.err("Could not get input device info (Index {d})", .{inputDeviceIndex});
        return error.DeviceInfoFailed;
    }
    const outputDeviceInfo = pa.Pa_GetDeviceInfo(outputDeviceIndex);
    if (outputDeviceInfo == null) {
        std.log.err("Could not get output device info (Index {d})", .{outputDeviceIndex});
        return error.DeviceInfoFailed;
    }
    std.log.info("Input Device: {s}", .{std.mem.span(inputDeviceInfo.*.name)});
    std.log.info("Output Device: {s}", .{std.mem.span(outputDeviceInfo.*.name)});

    const sample_rate: f64 = inputDeviceInfo.*.defaultSampleRate;

    // Use mono (1 channel) if supported by both, otherwise fail.
    // Could add logic for stereo if needed.
    if (inputDeviceInfo.*.maxInputChannels == 0) {
        std.log.err("Input device has no input channels.", .{});
        return error.NoInputChannelsOnDevice;
    }
    if (outputDeviceInfo.*.maxOutputChannels == 0) {
        std.log.err("Output device has no output channels.", .{});
        return error.NoOutputChannelsOnDevice;
    }
    const num_channels: c_int = 1; // Use mono

    const frames_per_buffer: c_ulong = pa.paFramesPerBufferUnspecified;

    std.log.info(
        \\Using Parameters: Sample Rate={d:.1}, Channels={d}, FramesPerBuffer=Unspecified
    , .{ sample_rate, num_channels });

    var callback_data = CallbackData{
        .channel_count = num_channels,
    };

    var inputParameters: pa.PaStreamParameters = .{
        .device = inputDeviceIndex,
        .channelCount = num_channels,
        .sampleFormat = SAMPLE_FORMAT,
        .suggestedLatency = inputDeviceInfo.*.defaultLowInputLatency,
        .hostApiSpecificStreamInfo = null,
    };

    var outputParameters: pa.PaStreamParameters = .{
        .device = outputDeviceIndex,
        .channelCount = num_channels,
        .sampleFormat = SAMPLE_FORMAT,
        .suggestedLatency = outputDeviceInfo.*.defaultLowOutputLatency,
        .hostApiSpecificStreamInfo = null,
    };

    err = pa.Pa_IsFormatSupported(&inputParameters, &outputParameters, sample_rate);
    if (err != pa.paFormatIsSupported) {
        printPaError("Pa_IsFormatSupported", err);
        std.log.err("The requested format combination is not supported.", .{});
        return error.FormatNotSupported;
    } else {
        std.log.info("Format combination is supported.", .{});
    }

    var stream: ?*pa.PaStream = null;
    std.log.info("Opening full-duplex stream...", .{});
    err = pa.Pa_OpenStream(
        &stream,
        &inputParameters, // Pointer to input parameters
        &outputParameters, // Pointer to output parameters
        sample_rate,
        frames_per_buffer,
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
        std.log.info(
            \\Actual Stream Info: Input Latency={d:.4}s, Output Latency={d:.4}s, SampleRate={d:.1}Hz
        , .{
            streamInfo.*.inputLatency,
            streamInfo.*.outputLatency,
            streamInfo.*.sampleRate,
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

    std.log.info("Stream is active. Playing back input for 10 seconds...", .{});
    std.log.info("You should hear audio from your input device now.", .{});
    pa.Pa_Sleep(10 * 1000);
    std.log.info("Finished playback.", .{});

    std.log.info("Exiting normally.", .{});
}
