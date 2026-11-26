//
//  BridgingHeader.h
//  VJDeck
//

#ifndef BridgingHeader_h
#define BridgingHeader_h

#import <Syphon/Syphon.h>

// Signalsmith Stretch bridge
#import "SignalsmithStretchBridge.h"
#import "AVAudioTapInstaller.h"

// FFmpeg (libav) C API
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libavutil/channel_layout.h>
#include <libavutil/samplefmt.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

#endif
