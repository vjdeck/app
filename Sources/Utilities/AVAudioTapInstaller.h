#ifndef AVAudioTapInstaller_h
#define AVAudioTapInstaller_h

#import <AVFoundation/AVFoundation.h>

BOOL VJDeckInstallAudioTap(
    AVAudioNode *_Nonnull node,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat *_Nullable format,
    AVAudioNodeTapBlock _Nonnull block,
    NSError *_Nullable *_Nullable error
);

#endif
