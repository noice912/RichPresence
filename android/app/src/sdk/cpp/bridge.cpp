// A thin bridge from the app (Kotlin) to Discord's Social SDK (C++).
// Everything the SDK calls back with is forwarded to DiscordNative's static methods.
// SDK callbacks only run inside runCallbacks(), which the app calls on its main thread.
#include <jni.h>
#include <android/log.h>
#include <memory>
#include <optional>
#include <string>

#define DISCORDPP_IMPLEMENTATION
#include "discordpp.h"

namespace {
JavaVM* g_vm = nullptr;
jclass g_cls = nullptr;
std::shared_ptr<discordpp::Client> g_client;
uint64_t g_appId = 0;
std::optional<discordpp::AuthorizationCodeVerifier> g_verifier;

JNIEnv* env() {
    JNIEnv* e = nullptr;
    if (g_vm->GetEnv(reinterpret_cast<void**>(&e), JNI_VERSION_1_6) != JNI_OK) {
        g_vm->AttachCurrentThread(&e, nullptr);
    }
    return e;
}

jstring js(JNIEnv* e, const std::string& s) { return e->NewStringUTF(s.c_str()); }

std::string cs(JNIEnv* e, jstring s) {
    if (!s) return {};
    const char* c = e->GetStringUTFChars(s, nullptr);
    std::string out(c);
    e->ReleaseStringUTFChars(s, c);
    return out;
}

void callStr(const char* name, const std::string& a) {
    JNIEnv* e = env();
    jmethodID m = e->GetStaticMethodID(g_cls, name, "(Ljava/lang/String;)V");
    jstring ja = js(e, a);
    e->CallStaticVoidMethod(g_cls, m, ja);
    e->DeleteLocalRef(ja);
}

void signIn(discordpp::AuthorizationTokenType type, const std::string& access) {
    g_client->UpdateToken(type, access, [](discordpp::ClientResult r) {
        if (!r.Successful()) { callStr("onAuthError", "Couldn't use the saved sign-in: " + r.Error()); return; }
        g_client->Connect();
    });
}

void onTokens(discordpp::ClientResult r, std::string access, std::string refresh,
              discordpp::AuthorizationTokenType type, int32_t expiresIn, std::string) {
    if (!r.Successful()) { callStr("onAuthError", "Discord refused the sign-in: " + r.Error()); return; }
    JNIEnv* e = env();
    jmethodID m = e->GetStaticMethodID(g_cls, "onTokens", "(Ljava/lang/String;Ljava/lang/String;I)V");
    jstring a = js(e, access), f = js(e, refresh);
    e->CallStaticVoidMethod(g_cls, m, a, f, static_cast<jint>(expiresIn));
    e->DeleteLocalRef(a);
    e->DeleteLocalRef(f);
    signIn(type, access);
}
}  // namespace

extern "C" {

JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void*) {
    g_vm = vm;
    JNIEnv* e = nullptr;
    vm->GetEnv(reinterpret_cast<void**>(&e), JNI_VERSION_1_6);
    jclass c = e->FindClass("io/github/noice912/richpresence/DiscordNative");
    g_cls = static_cast<jclass>(e->NewGlobalRef(c));
    return JNI_VERSION_1_6;
}

JNIEXPORT void JNICALL Java_io_github_noice912_richpresence_DiscordNative_init(JNIEnv*, jclass, jlong appId) {
    if (g_client) return;
    g_appId = static_cast<uint64_t>(appId);
    g_client = std::make_shared<discordpp::Client>();
    g_client->SetApplicationId(g_appId);
    g_client->AddLogCallback([](std::string msg, discordpp::LoggingSeverity) {
        __android_log_print(ANDROID_LOG_INFO, "DiscordSDK", "%s", msg.c_str());
    }, discordpp::LoggingSeverity::Warning);
    g_client->SetStatusChangedCallback([](discordpp::Client::Status s, discordpp::Client::Error err, int32_t detail) {
        JNIEnv* e = env();
        jmethodID m = e->GetStaticMethodID(g_cls, "onStatus", "(ILjava/lang/String;)V");
        std::string why = err == discordpp::Client::Error::None ? "" :
            discordpp::Client::ErrorToString(err) + " (" + std::to_string(detail) + ")";
        jstring w = js(e, why);
        e->CallStaticVoidMethod(g_cls, m, static_cast<jint>(s), w);
        e->DeleteLocalRef(w);
        if (s == discordpp::Client::Status::Ready) {
            if (auto u = g_client->GetCurrentUserV2()) callStr("onUser", u->DisplayName());
        }
    });
}

JNIEXPORT void JNICALL Java_io_github_noice912_richpresence_DiscordNative_runCallbacks(JNIEnv*, jclass) {
    discordpp::RunCallbacks();
}

// Opens Discord (the app if installed, otherwise the browser) to ask the person to link their account.
JNIEXPORT void JNICALL Java_io_github_noice912_richpresence_DiscordNative_authorize(JNIEnv*, jclass) {
    if (!g_client) return;
    g_verifier = g_client->CreateAuthorizationCodeVerifier();
    discordpp::AuthorizationArgs args;
    args.SetClientId(g_appId);
    args.SetScopes(discordpp::Client::GetDefaultPresenceScopes());
    args.SetCodeChallenge(g_verifier->Challenge());
    g_client->Authorize(args, [](discordpp::ClientResult r, std::string code, std::string redirectUri) {
        if (!r.Successful()) { callStr("onAuthError", "Linking was cancelled or failed: " + r.Error()); return; }
        g_client->GetToken(g_appId, code, g_verifier->Verifier(), redirectUri, onTokens);
    });
}

JNIEXPORT void JNICALL Java_io_github_noice912_richpresence_DiscordNative_useToken(JNIEnv* e, jclass, jstring access) {
    if (g_client) signIn(discordpp::AuthorizationTokenType::Bearer, cs(e, access));
}

JNIEXPORT void JNICALL Java_io_github_noice912_richpresence_DiscordNative_refresh(JNIEnv* e, jclass, jstring refresh) {
    if (g_client) g_client->RefreshToken(g_appId, cs(e, refresh), onTokens);
}

JNIEXPORT void JNICALL Java_io_github_noice912_richpresence_DiscordNative_disconnect(JNIEnv*, jclass) {
    if (g_client) g_client->Disconnect();
}

JNIEXPORT void JNICALL Java_io_github_noice912_richpresence_DiscordNative_update(
    JNIEnv* e, jclass, jint type, jstring details, jstring state, jlong start, jlong end,
    jstring image, jstring imageText) {
    if (!g_client) return;
    discordpp::Activity a;
    a.SetType(type == 2 ? discordpp::ActivityTypes::Listening : discordpp::ActivityTypes::Playing);
    if (details) a.SetDetails(cs(e, details));
    if (state) a.SetState(cs(e, state));
    if (start > 0 || end > 0) {
        discordpp::ActivityTimestamps t;
        if (start > 0) t.SetStart(static_cast<uint64_t>(start));
        if (end > 0) t.SetEnd(static_cast<uint64_t>(end));
        a.SetTimestamps(t);
    }
    if (image) {
        discordpp::ActivityAssets as;
        as.SetLargeImage(cs(e, image));
        if (imageText) as.SetLargeText(cs(e, imageText));
        a.SetAssets(as);
    }
    g_client->UpdateRichPresence(a, [](discordpp::ClientResult r) {
        if (!r.Successful()) callStr("onLog", "Discord didn't accept the status: " + r.Error());
    });
}

JNIEXPORT void JNICALL Java_io_github_noice912_richpresence_DiscordNative_clear(JNIEnv*, jclass) {
    if (g_client) g_client->ClearRichPresence();
}

}  // extern "C"
