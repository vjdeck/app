#ifndef SignalsmithStretchBridge_h
#define SignalsmithStretchBridge_h

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SignalsmithStretchContext *SignalsmithStretchRef;

SignalsmithStretchRef SignalsmithStretchCreate(int channels, double sampleRate, bool cheaper);
void SignalsmithStretchDestroy(SignalsmithStretchRef ctx);
void SignalsmithStretchReset(SignalsmithStretchRef ctx);

int SignalsmithStretchInputLatency(SignalsmithStretchRef ctx);
int SignalsmithStretchOutputLatency(SignalsmithStretchRef ctx);

void SignalsmithStretchProcessMono(SignalsmithStretchRef ctx,
                                    const float *input, int inputSamples,
                                    float *output, int outputSamples);

/// Prime the stretcher so the next `process()` call returns aligned output
/// with no preRoll silence. Pass `inputLength` = `inputLatency + rate * outputLatency`
/// samples of input, where the LAST samples are at the current position and
/// the preceding samples are the pre-roll history.
void SignalsmithStretchOutputSeekMono(SignalsmithStretchRef ctx,
                                       const float *input, int inputLength);

#ifdef __cplusplus
}
#endif

#endif
