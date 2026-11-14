#import <Foundation/Foundation.h>
#import <CoreAudio/AudioServerPlugIn.h>
#import "LocalTransport.h"

NS_ASSUME_NONNULL_BEGIN
@interface ARRouteDriver : NSObject
@property (class, readonly) ARRouteDriver *shared;
@property (nonatomic, readonly) uint64_t framesDelivered;
@property (nonatomic, readonly) BOOL registered;
@property (nonatomic, readonly) ARLinkStats transportStats;
// Also used by discovery, so declared and actual network endpoints agree.
@property (nonatomic, readonly) NSString *receiverIPv4;
// One name for discovery and HAL. Fixed before publication for the process lifetime.
@property (nonatomic, readonly) NSString *deviceDisplayName;
- (OSStatus)publishWithDeviceUID:(NSString *)uid;
// Starts only the transport. Activation must wait for transportStats.connected.
- (int)prepareTransport;
- (int)startCapture;
- (void)stopCapture;
@end
NS_ASSUME_NONNULL_END
