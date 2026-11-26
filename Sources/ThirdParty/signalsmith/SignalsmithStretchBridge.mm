#import "SignalsmithStretchBridge.h"
#import "signalsmith-stretch.h"

struct SignalsmithStretchContext {
    signalsmith::stretch::SignalsmithStretch<float> stretch;
};

SignalsmithStretchRef SignalsmithStretchCreate(int channels, double sampleRate, bool cheaper) {
    auto *ctx = new SignalsmithStretchContext();
    if (cheaper) {
        ctx->stretch.presetCheaper(channels, sampleRate);
    } else {
        ctx->stretch.presetDefault(channels, sampleRate);
    }
    return ctx;
}

void SignalsmithStretchDestroy(SignalsmithStretchRef ctx) {
    delete ctx;
}

void SignalsmithStretchReset(SignalsmithStretchRef ctx) {
    ctx->stretch.reset();
}

int SignalsmithStretchInputLatency(SignalsmithStretchRef ctx) {
    return ctx->stretch.inputLatency();
}

int SignalsmithStretchOutputLatency(SignalsmithStretchRef ctx) {
    return ctx->stretch.outputLatency();
}

void SignalsmithStretchProcessMono(SignalsmithStretchRef ctx,
                                    const float *input, int inputSamples,
                                    float *output, int outputSamples) {
    const float *inputChans[1] = { input };
    float *outputChans[1] = { output };
    ctx->stretch.process(inputChans, inputSamples, outputChans, outputSamples);
}

void SignalsmithStretchOutputSeekMono(SignalsmithStretchRef ctx,
                                       const float *input, int inputLength) {
    const float *inputChans[1] = { input };
    ctx->stretch.outputSeek(inputChans, inputLength);
}
