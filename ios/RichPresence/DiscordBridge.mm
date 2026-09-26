#import "DiscordBridge.h"

#define DISCORDPP_IMPLEMENTATION
#import <discord_partner_sdk/discordpp.h>

#include <memory>
#include <optional>
#include <string>

static NSString *ns(const std::string &s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }

@implementation DiscordBridge {
    std::shared_ptr<discordpp::Client> _client;
    uint64_t _appId;
    std::optional<discordpp::AuthorizationCodeVerifier> _verifier;
}

- (instancetype)initWithAppId:(uint64_t)appId {
    if ((self = [super init])) {
        _appId = appId;
        _client = std::make_shared<discordpp::Client>();
        _client->SetApplicationId(appId);
        __weak DiscordBridge *weakSelf = self;
        _client->SetStatusChangedCallback([weakSelf](discordpp::Client::Status s, discordpp::Client::Error err, int32_t detail) {
            DiscordBridge *me = weakSelf;
            if (!me) return;
            if (s == discordpp::Client::Status::Ready) {
                auto u = me->_client->GetCurrentUserV2();
                if (me.onReady) me.onReady(u ? ns(u->DisplayName()) : @"your account");
            } else if (s == discordpp::Client::Status::Disconnected && me.onDisconnected) {
                me.onDisconnected(err == discordpp::Client::Error::None ? @"" :
                    ns(discordpp::Client::ErrorToString(err) + " (" + std::to_string(detail) + ")"));
            }
        });
    }
    return self;
}

- (void)runCallbacks { discordpp::RunCallbacks(); }

- (void)log:(NSString *)m { if (self.onLog) self.onLog(m); }

- (void)signInWithType:(discordpp::AuthorizationTokenType)type token:(const std::string &)token {
    __weak DiscordBridge *weakSelf = self;
    _client->UpdateToken(type, token, [weakSelf](discordpp::ClientResult r) {
        DiscordBridge *me = weakSelf;
        if (!me) return;
        if (!r.Successful()) { [me log:[@"Couldn't use the saved sign-in: " stringByAppendingString:ns(r.Error())]]; return; }
        me->_client->Connect();
    });
}

- (discordpp::Client::TokenExchangeCallback)tokenCallback {
    __weak DiscordBridge *weakSelf = self;
    return [weakSelf](discordpp::ClientResult r, std::string access, std::string refresh,
                      discordpp::AuthorizationTokenType type, int32_t expiresIn, std::string) {
        DiscordBridge *me = weakSelf;
        if (!me) return;
        if (!r.Successful()) { [me log:[@"Discord refused the sign-in: " stringByAppendingString:ns(r.Error())]]; return; }
        if (me.onTokens) me.onTokens(ns(access), ns(refresh), expiresIn);
        [me signInWithType:type token:access];
    };
}

- (void)authorize {
    _verifier = _client->CreateAuthorizationCodeVerifier();
    discordpp::AuthorizationArgs args;
    args.SetClientId(_appId);
    args.SetScopes(discordpp::Client::GetDefaultPresenceScopes());
    args.SetCodeChallenge(_verifier->Challenge());
    __weak DiscordBridge *weakSelf = self;
    _client->Authorize(args, [weakSelf](discordpp::ClientResult r, std::string code, std::string redirectUri) {
        DiscordBridge *me = weakSelf;
        if (!me) return;
        if (!r.Successful()) { [me log:[@"Linking was cancelled or failed: " stringByAppendingString:ns(r.Error())]]; return; }
        me->_client->GetToken(me->_appId, code, me->_verifier->Verifier(), redirectUri, [me tokenCallback]);
    });
}

- (void)useAccessToken:(NSString *)token {
    [self signInWithType:discordpp::AuthorizationTokenType::Bearer token:std::string(token.UTF8String)];
}

- (void)refreshWithToken:(NSString *)refreshToken {
    _client->RefreshToken(_appId, std::string(refreshToken.UTF8String), [self tokenCallback]);
}

- (void)disconnect { _client->Disconnect(); }

- (void)updateWithType:(NSInteger)type details:(NSString *)details state:(NSString *)state
                 start:(int64_t)start end:(int64_t)end image:(NSString *)image imageText:(NSString *)imageText {
    discordpp::Activity a;
    a.SetType(type == 2 ? discordpp::ActivityTypes::Listening : discordpp::ActivityTypes::Playing);
    if (details) a.SetDetails(std::string(details.UTF8String));
    if (state) a.SetState(std::string(state.UTF8String));
    if (start > 0 || end > 0) {
        discordpp::ActivityTimestamps t;
        if (start > 0) t.SetStart((uint64_t)start);
        if (end > 0) t.SetEnd((uint64_t)end);
        a.SetTimestamps(t);
    }
    if (image) {
        discordpp::ActivityAssets as;
        as.SetLargeImage(std::string(image.UTF8String));
        if (imageText) as.SetLargeText(std::string(imageText.UTF8String));
        a.SetAssets(as);
    }
    __weak DiscordBridge *weakSelf = self;
    _client->UpdateRichPresence(a, [weakSelf](discordpp::ClientResult r) {
        if (!r.Successful()) [weakSelf log:[@"Discord didn't accept the status: " stringByAppendingString:ns(r.Error())]];
    });
}

- (void)clear { _client->ClearRichPresence(); }

@end
