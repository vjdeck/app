#import "AVAudioTapInstaller.h"

BOOL VJDeckInstallAudioTap(
    AVAudioNode *_Nonnull node,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat *_Nullable format,
    AVAudioNodeTapBlock _Nonnull block,
    NSError *_Nullable *_Nullable error
) {
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *reason = exception.reason ?: @"AVAudioNode installTap failed";
            NSMutableDictionary *userInfo = [@{
                NSLocalizedDescriptionKey: reason,
                @"exceptionName": exception.name ?: @"NSException"
            } mutableCopy];
            if (exception.callStackSymbols != nil) {
                userInfo[@"callStackSymbols"] = exception.callStackSymbols;
            }
            *error = [NSError errorWithDomain:@"com.bada.VJDeck.AVAudioTapInstaller"
                                         code:1
                                     userInfo:userInfo];
        }
        return NO;
    }
}
