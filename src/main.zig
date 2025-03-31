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

// This function is called by PortAudio in a high-priority thread.
// Keep it fast! Avoid allocations, file I/O, or complex locking.
fn paCallback(
    inputBuffer: ?*const anyopaque, // const void *input
    outputBuffer: ?*anyopaque, // void *output (unused for input-only)
    frameCount: c_ulong, // Number of frames in this buffer
    timeInfo: ?*const pa.PaStreamCallbackTimeInfo, // Timing info (unused here)
    statusFlags: pa.PaStreamCallbackFlags, // e.g., paInputOverflow
    userData: ?*anyopaque, // Custom data pointer (unused here)
) callconv(.C) c_int { // IMPORTANT: Must use C calling convention
    _ = outputBuffer; // Mark as unused
    _ = timeInfo;
    _ = userData;

    // Check for input buffer issues reported by PortAudio
    if (statusFlags & pa.paInputOverflow != 0) {
        // Using std.debug.print is often safer in callbacks than std.log
        std.debug.print("Warning: Input overflow detected in callback!\n", .{});
    }
    if (statusFlags & pa.paInputUnderflow != 0) {
        std.debug.print("Warning: Input underflow detected in callback!\n", .{});
    }

    // Ensure we actually have an input buffer
    if (inputBuffer == null) {
        std.debug.print("Warning: Null input buffer in callback!\n", .{});
        // Returning paContinue might be okay, but paAbort might be safer
        // if this indicates a serious problem. Let's continue for now.
        return pa.paContinue;
    }

    // Cast the opaque input pointer to the correct sample type (paFloat32 -> f32)
    // The buffer contains 'frameCount * NUM_CHANNELS' samples.
    // Using @alignCast is good practice when casting from anyopaque.
    const input_samples: [*c]const f32 = @ptrCast(@alignCast(inputBuffer.?));
    const num_samples = frameCount * @as(c_ulong, @intCast(NUM_CHANNELS));

    // --- Process the audio data (Example: Calculate Peak and RMS) ---
    var peak: f32 = 0.0;
    var sum_sq: f64 = 0.0; // Use f64 for accumulator to avoid precision loss

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

    // Print the results (again, std.debug.print is preferred in callback)
    // Limit printing frequency in real apps if performance is critical
    std.debug.print("Callback: frames={d} peak={d:.4} RMS={d:.4}\n", .{
        frameCount, peak, rms,
    });

    // Tell PortAudio to keep calling this callback
    return pa.paContinue;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    _ = allocator; // Mark as used if needed later, unused in this example

    std.log.info("PortAudio Input Example (Callback)", .{});
    std.log.info("Sample Rate: {d}, Channels: {d}, Format: paFloat32", .{
        SAMPLE_RATE, NUM_CHANNELS,
    });

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
    } else {
        std.log.info("Using Device: {s}", .{std.mem.span(deviceInfo.*.name)});
        std.log.info("Max Input Channels: {d}", .{deviceInfo.*.maxInputChannels});
        if (NUM_CHANNELS > deviceInfo.*.maxInputChannels) {
            std.log.err("Requested channel count ({d}) exceeds device max ({d})", .{
                NUM_CHANNELS, deviceInfo.*.maxInputChannels,
            });
            return error.InvalidChannelCount;
        }
    }

    var inputParameters: pa.PaStreamParameters = .{
        .device = inputDeviceIndex,
        .channelCount = NUM_CHANNELS,
        .sampleFormat = SAMPLE_FORMAT,
        .suggestedLatency = if (deviceInfo != null)
            deviceInfo.*.defaultLowInputLatency
        else
            0.0,
        .hostApiSpecificStreamInfo = null, // Usually null
    };

    var stream: ?*pa.PaStream = null; // Pointer to the stream object
    std.log.info("Opening stream...", .{});
    err = pa.Pa_OpenStream(
        &stream, // Address of the stream pointer
        &inputParameters, // Pointer to input parameters
        null, // No output parameters
        SAMPLE_RATE,
        FRAMES_PER_BUFFER,
        pa.paNoFlag, // No special stream flags
        paCallback, // Pointer to OUR callback function
        null, // No user data pointer needed for this example
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

    std.log.info("Starting stream...", .{});
    err = pa.Pa_StartStream(stream);
    if (err != pa.paNoError) {
        printPaError("Pa_StartStream", err);
        return error.StreamStartFailed;
    }
    defer {
        if (stream != null) {
            std.log.info("Stopping stream...", .{});
            // Use Abort for quicker exit, Stop waits for buffers.
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
