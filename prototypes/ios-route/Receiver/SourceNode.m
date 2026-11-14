#import "ProbeRenderer.h"

AVAudioSourceNode *ARMakeSourceNode(ARRenderer *renderer) {
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:ARSampleRate channels:2];
    if (!format) return nil;
    return [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:
        ^OSStatus(BOOL *silence, const AudioTimeStamp *time, AVAudioFrameCount frames, AudioBufferList *output) {
            (void)time; (void)silence;
            return ar_renderer_render(renderer, frames, output);
        }];
}
