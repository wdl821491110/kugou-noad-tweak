/* 酷狗音乐概念版 5.3.3 (com.kugou.kgyouth) 去广告 + 精简 tweak
 *
 * v3 = v2 运行时挂载 + A+C 弹窗精简：
 *  - v2：全部 hook 改为「运行时挂载」。原因：LiveContainer 里 tweak 常在宿主
 *    进程早期加载，此时客制 App 的 ObjC 类还没注册，Logos %hook 在 %ctor 里
 *    拿不到类，hook 全失效（广告还在、Siri 词表照常注册并崩溃）。现用
 *    objc_getClass + method_setImplementation，多时机重试，类何时注册何时挂。
 *  - A 运营弹窗：KGAlertManager / YouthAlertQueueJob 调度层，按 selector 全局挂载。
 *  - C 更新/VIP 到期弹窗：checkAndShowUpdateMessage / checkShowVIPExpireAlert 等。
 */

@import Foundation;
@import UIKit;
#import <objc/runtime.h>
#import <dlfcn.h>

#define KG_DEBUG 0
#define KGLogAlways(...) NSLog(@"[KGNoAd] " __VA_ARGS__)
#if KG_DEBUG
#define KGLog(...) KGLogAlways(__VA_ARGS__)
#else
#define KGLog(...) do {} while (0)
#endif

typedef void (^KGSuccessCB)(id);

static void KGCallCB(id cb) {
    if (cb) { ((KGSuccessCB)cb)(nil); }
}

/* 通用空实现：void 返回 / id 返回 */
static void KGNoop(id self, SEL _cmd, ...) { }
static id KGNoopNil(id self, SEL _cmd, ...) { return nil; }

/* 需要给回调传 nil，否则业务流程卡住 */
static void KGNoop_CB2(id self, SEL _cmd, id success, id error) { KGCallCB(success); }
static void KGNoop_CB3(id self, SEL _cmd, id a, id success, id error) { KGCallCB(success); }
static void KGNoop_CB3Bool(id self, SEL _cmd, BOOL a, id success, id error) { KGCallCB(success); }
static void KGNoop_CB4Bool(id self, SEL _cmd, BOOL a, id b, id success, id error) { KGCallCB(success); }
static void KGNoop_CB4Id(id self, SEL _cmd, id a, id b, id success, id error) { KGCallCB(success); }

/* ============ hook 注册表 ============ */
typedef struct {
    const char *cls;
    const char *sel;
    IMP imp;
    BOOL classMethod;
    BOOL installed;
} KGHook;

static KGHook kHooks[] = {
    /* 开屏广告 */
    {"KGSplashHttpDao", "requestSplashListWithDownloadAds:Error:", (IMP)KGNoop, NO, NO},
    {"KGSplashHttpDao", "requestRealTimeSplashWithDownloadAds:isStartSplash:error:", (IMP)KGNoop, NO, NO},
    {"KGSplashHttpDao", "requestDownloadSplashResourceWithError:andError:", (IMP)KGNoop, NO, NO},
    {"KGSplashHttpDao", "requestDownloadSplashAudioWithModel:andError:", (IMP)KGNoop, NO, NO},
    {"SplashDBDao", "getNotExpiredSplashs", (IMP)KGNoopNil, NO, NO},
    {"SplashDBDao", "getAvailableSplashs", (IMP)KGNoopNil, NO, NO},

    /* Banner / 信息流 */
    {"ADBannerBLL", "requestBlueTipAdInfo:successBlock:errorBlock:", (IMP)KGNoop_CB3, NO, NO},
    {"ADBannerBLL", "requestMineLinkAdInfos:successBlock:errorBlock:", (IMP)KGNoop_CB3, NO, NO},
    {"ADBannerBLL", "requestTodaySongBannerAdInfo:", (IMP)KGNoop, NO, NO},
    {"ADBannerBLL", "requestSearchBannerAdInfoWithLoadAds:successBlock:errorBlock:", (IMP)KGNoop_CB3Bool, NO, NO},
    {"ADBannerBLL", "requestCommentBannerAdInfoWithLoadAds:songInfo:successBlock:errorBlock:", (IMP)KGNoop_CB4Bool, NO, NO},
    {"ADBannerBLL", "requestMyInfoPageAdInfoWithSuccessBlock:errorBlock:", (IMP)KGNoop_CB2, NO, NO},
    {"YouthHomeChannelBannerBLL", "requestBannerListWithSuccessBlock:failBlock:", (IMP)KGNoop_CB2, NO, NO},
    {"YouthHomeChannelBannerBLL", "requestBannerListWithBusiParam:biz:successBlock:failBlock:", (IMP)KGNoop_CB4Id, NO, NO},
    {"KGMusicHomeBannerBLL", "getBannerInfoWithResultBlock:errorBlock:", (IMP)KGNoop_CB2, NO, NO},

    /* 激励广告曝光/点击上报 */
    {"YouthAdvertBiManager", "sendEnterExposureBIWithSourceId:", (IMP)KGNoop, NO, NO},
    {"YouthAdvertBiManager", "sendEnterExposureBIWithSourceId:extraDict:", (IMP)KGNoop, NO, NO},
    {"YouthAdvertBiManager", "sendEnterClickBIWithSourceId:", (IMP)KGNoop, NO, NO},
    {"YouthAdvertBiManager", "sendEnterClickBIWithSourceId:type:", (IMP)KGNoop, NO, NO},

    /* Siri 词表：app 层入口 */
    {"KGMediaIntentStartTask", "registerCustomVocabulary", (IMP)KGNoop, NO, NO},

    /* Siri 词表：系统层兜底（Intents 可能晚加载） */
    {"INVocabulary", "setVocabularyStrings:ofType:", (IMP)KGNoop, NO, NO},
};

static const NSUInteger kHookCount = sizeof(kHooks) / sizeof(kHooks[0]);

/* ============ A+C：弹窗调度层，按 selector 全局挂载 ============
 * 这些 selector 归属的核心类 method list 格式特殊，静态解析拿不到，
 * 所以运行时遍历所有已注册类，谁实现这些 selector 就换掉谁的实现。
 * 统一用 KGNoopNil：void 方法无害；BOOL 方法返回 NO；id 方法返回 nil。
 * selector 都是酷狗业务专有词，不会命中系统类。 */
typedef struct {
    const char *sel;
    IMP imp;
} KGSelHook;

static KGSelHook kSelHooks[] = {
    /* A. 运营弹窗调度中心 */
    {"showAlertWithKGAlertManager", (IMP)KGNoopNil},
    {"showAlertWithKGAlertManagerWithAppStoreBlock:feedBackBlock:closeBlock:", (IMP)KGNoopNil},
    {"kgAlertManagerShowAlert:", (IMP)KGNoopNil},
    {"kgAlertManagerWaitAlert:", (IMP)KGNoopNil},
    {"kgAlertManagerWillShowWithJob:", (IMP)KGNoopNil},
    {"kgAlertManagerCanShowNextJob", (IMP)KGNoopNil},
    {"kgAlertManagerCanPassRuleWithJob:", (IMP)KGNoopNil},
    {"kgAlertManagerCanShowInCurrentPage:", (IMP)KGNoopNil},
    {"kgAlertManagerCanShowInCurrentTab:", (IMP)KGNoopNil},
    /* C. 更新 / VIP 到期弹窗 */
    {"checkAndShowUpdateMessage", (IMP)KGNoopNil},
    {"checkVersionUpdate", (IMP)KGNoopNil},
    {"forceShowUpdateAlert", (IMP)KGNoopNil},
    {"checkShowVIPExpireAlert", (IMP)KGNoopNil},
    {"checkShowWVIPExpireAlert", (IMP)KGNoopNil},
    {"checkShowPlayPagePriviledgeVipExpireAlert", (IMP)KGNoopNil},
    {"checkShowInviteVipAlert", (IMP)KGNoopNil},
};
static const NSUInteger kSelHookCount = sizeof(kSelHooks) / sizeof(kSelHooks[0]);

static void KGInstallSelectorHooks(void) {
    static NSMutableSet *hookedMethods = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ hookedMethods = [NSMutableSet set]; });

    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) { return; }
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        for (NSUInteger j = 0; j < kSelHookCount; j++) {
            SEL sel = sel_registerName(kSelHooks[j].sel);
            Method m = class_getInstanceMethod(cls, sel);
            if (!m) { continue; }
            NSValue *key = [NSValue valueWithPointer:(void *)m];
            if ([hookedMethods containsObject:key]) { continue; }
            [hookedMethods addObject:key];
            method_setImplementation(m, kSelHooks[j].imp);
            KGLog(@"global hooked %s on %@", kSelHooks[j].sel, NSStringFromClass(cls));
        }
    }
    free(classes);
}

static void KGInstallAllHooks(void) {
    /* 强制把 Intents 拉进来，保证 INVocabulary 类可解析 */
    static dispatch_once_t onceTokens;
    dispatch_once(&onceTokens, ^{
        dlopen("/System/Library/Frameworks/Intents.framework/Intents", RTLD_NOW | RTLD_GLOBAL);
    });

    for (NSUInteger i = 0; i < kHookCount; i++) {
        KGHook *h = &kHooks[i];
        if (h->installed) { continue; }
        Class cls = objc_getClass(h->cls);
        if (!cls) { continue; }
        SEL sel = sel_registerName(h->sel);
        Method m = h->classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
        if (!m) { continue; }
        method_setImplementation(m, h->imp);
        h->installed = YES;
        KGLogAlways(@"hooked %s -> %s", h->cls, h->sel);
    }

    /* A+C：弹窗调度层全局 selector 挂载 */
    KGInstallSelectorHooks();
}

%ctor {
    KGLogAlways(@"loaded for com.kugou.kgyouth 5.3.3 (runtime hook mode)");

    /* 1. 立刻挂一次（类已在内存时直接生效） */
    KGInstallAllHooks();

    /* 2. 主线程下一个 loop 再挂（覆盖 guest App 刚 dlopen 的情况） */
    dispatch_async(dispatch_get_main_queue(), ^{
        KGInstallAllHooks();
    });

    /* 3. App 启动完成时再挂一次 */
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        KGInstallAllHooks();
    }];

    /* 4. 分级延迟兜底：0.1 / 0.5 / 2 / 5 秒 */
    NSArray *delays = @[@0.1, @0.5, @2.0, @5.0];
    for (NSNumber *d in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            KGInstallAllHooks();
        });
    }
}
