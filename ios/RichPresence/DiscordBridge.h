#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Discord's Social SDK (C++) for Swift. Callbacks arrive on the main thread, inside -runCallbacks.
@interface DiscordBridge : NSObject

- (instancetype)initWithAppId:(uint64_t)appId;

/// Call often (the app does it 10 times a second).
- (void)runCallbacks;

/// Opens Discord to ask the person to link their account.
- (void)authorize;
- (void)useAccessToken:(NSString *)token;
- (void)refreshWithToken:(NSString *)refreshToken;
- (void)disconnect;

/// type: 0 = Playing, 2 = Listening. start/end are Unix milliseconds, 0 for none.
/// name: what follows "Playing"/"Listening to" (Discord may keep the app name instead).
/// display: which line the status shows: 0 = name, 1 = state, 2 = details.
- (void)updateWithType:(NSInteger)type
                  name:(nullable NSString *)name
               display:(NSInteger)display
               details:(nullable NSString *)details
                 state:(nullable NSString *)state
                 start:(int64_t)start
                   end:(int64_t)end
                 image:(nullable NSString *)image
             imageText:(nullable NSString *)imageText;
- (void)clear;

@property (nonatomic, copy, nullable) void (^onLog)(NSString *message);
@property (nonatomic, copy, nullable) void (^onTokens)(NSString *access, NSString *refresh, NSInteger expiresIn);
@property (nonatomic, copy, nullable) void (^onReady)(NSString *displayName);
@property (nonatomic, copy, nullable) void (^onDisconnected)(NSString *reason);

@end

NS_ASSUME_NONNULL_END
