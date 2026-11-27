/* 酷狗音乐概念版 5.3.3 (com.kugou.kgyouth) 去广告 + 精简 tweak
 *
 * v4 = v3 + 真实 show 方法拦截：
 *  - v2：全部 hook 改为「运行时挂载」。原因：LiveContainer 里 tweak 常在宿主
 *    进程早期加载，此时客制 App 的 ObjC 类还没注册，Logos %hook 在 %ctor 里
 *    拿不到类，hook 全失效（广告还在、Siri 词表照常注册并崩溃）。现用
 *    objc_getClass + method_setImplementation，多时机重试，类何时注册何时挂。
 *  - v3：A 运营弹窗（KGAlertManager / YouthAlertQueueJob）+ C 检查入口
 *    （checkShowVIPExpireAlert 等），按 selector 全局挂载。
 *  - v4：v3 只拦了「检查」入口，实际弹窗由 show* 方法绘制，导致 VIP 到期弹窗和
 *    签到弹窗仍出现。补拦真实显示方法：showAlertWithIsExpire:days:、
 *    realShowV3WithIsExpire:days:、showCalendarSignInAlert: 等。
 *  - v5-B：精简引导浮层（GuideView），拦 showGuideView/showSlideGuide 等
 *    真实显示方法；避开带 complete block 的方法防止回调不触发卡流程。
 *  - v6-D：精简臃肿功能入口（直播/K歌/游戏/商城），只拦纯跳转方法，
 *    不隐藏 view（防依赖崩溃）、不碰内购（防 VIP 买不了）、不碰带 block 的。
 *  - v7：我的页赚钱（任务中心）+ 首页轮播图 + 首页运营卡片位
 *    （概念实验室/盲盒/VIP推荐/小众宝藏等）。数据源用空数组而非 nil 防崩；
 *    不碰首页推荐主接口 requestRecSortFirstPageData，保住正常歌曲流。
 *  - v8：v7 三处都没生效，修正方向：
 *     * 产物改名 kugou_noad_v8.dylib，避免 LC 里版本混淆。
 *     * 轮播图：补拦缓存读取链路 getCacheBannerInfo / readBannerInfoFromLocalPlist
 *       / refreshBannerList: 等（v7 只拦了 FroShow 变体）。
 *     * 赚钱入口：补拦 needRefreshTaskCenterEntrance 等数据判定。
 *     * 6 卡片：不再拦 banner 数据源（走的是推荐流原生 cell），改为运行时
 *       按类名 hook 这些 cell 的 layoutSubviews 隐藏自身。
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

/* ============ v8: 首页 6 个运营卡片 cell 运行时隐藏 ============
 * 这些卡片是首页推荐流里的原生 UICollectionViewCell，不走 banner 数据源。
 * 静态解析拿不到它们的 method list，改为运行时按类名拿到类，
 * 替换 layoutSubviews：隐藏自身，让卡片视觉消失。不调用原实现 =
 * 内部 subview 不再布局渲染，但 cell 仍占位（不会崩，这是最安全档位）。 */
static void KGHiddenLayout(id self, SEL _cmd) {
    UIView *v = (UIView *)self;
    if (v.hidden != YES) { v.hidden = YES; }
    if (v.alpha != 0.0) { v.alpha = 0.0; }
}

static void KGInstallCardCellHooks(void) {
    /* 概念实验室 / 曲风盲盒 / VIP专属推荐 / 小众宝藏 / 喜欢 ta 特喜欢 / 概念er新推 */
    static const char *names[] = {
        "KGYouthNewDiscoverConceptLabV5Cell",
        "KGYouthNewDiscoverNicheRecV5Cell",
        "KGYouthNewDiscoverVipRecV5Cell",
        "KGYouthNewDiscoverDifTagRecV5Cell",
        "KGYouthNewDiscoverCardAdV5View",
        "KGYouthNewDiscoverCardAdView",
        "YouthNewDiscoverConceptLabItemBaseCell",
        "YouthNewDiscoverDifTagRecItemBaseCell",
        NULL
    };
    static BOOL installed[16] = { NO };
    SEL layoutSel = @selector(layoutSubviews);

    /* 不用 dispatch_once：cell 类可能启动晚期才注册，每次 tick 重试未装上的 */
    for (int i = 0; names[i] && i < 16; i++) {
        if (installed[i]) { continue; }
        Class cls = objc_getClass(names[i]);
        if (!cls) { continue; }   // 还没注册，下次再试

        /* 关键：绝不能用 class_getInstanceMethod，它会沿继承链拿到父类
         * (UICollectionViewCell) 的 layoutSubviews，替换后会隐藏所有 cell。
         * 先 class_addMethod 给本类加自己的实现（不碰父类）；
         * 若本类已有自己的实现（add 失败），再只在本类 method list 内替换。 */
        BOOL added = class_addMethod(cls, layoutSel, (IMP)KGHiddenLayout, "v@:");
        if (added) {
            installed[i] = YES;
            KGLogAlways(@"added hidden layout to: %s", names[i]);
        } else {
            unsigned int mc = 0;
            Method *mlist = class_copyMethodList(cls, &mc);
            BOOL done = NO;
            for (unsigned int k = 0; k < mc; k++) {
                if (sel_isEqual(method_getName(mlist[k]), layoutSel)) {
                    method_setImplementation(mlist[k], (IMP)KGHiddenLayout);
                    installed[i] = YES;
                    KGLogAlways(@"replaced own layout on: %s", names[i]);
                    done = YES;
                    break;
                }
            }
            free(mlist);
            if (!done) { KGLogAlways(@"cannot hook layout on: %s", names[i]); }
        }
    }
}

static void KGCallCB(id cb) {
    if (cb) { ((KGSuccessCB)cb)(nil); }
}

/* 通用空实现：void 返回 / id 返回 */
static void KGNoop(id self, SEL _cmd, ...) { }
static id KGNoopNil(id self, SEL _cmd, ...) { return nil; }

/* 返回空容器：比 nil 安全，避免下游直接遍历/取 count 崩溃 */
static id KGNoopEmptyArray(id self, SEL _cmd, ...) { return @[]; }

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

    /* v4: VIP 到期弹窗的真实 show/realShow 方法
     * （v3 只拦 check*，弹窗仍由下面这些 show 方法绘制） */
    {"showAlertWithIsExpire:days:", (IMP)KGNoopNil},
    {"showAlertWithIsExpire:days:isTest:", (IMP)KGNoopNil},
    {"showWVIPAlertWithIsExpire:days:", (IMP)KGNoopNil},
    {"showExpireAlert", (IMP)KGNoopNil},
    {"showExpireAlertWithoutExpire:", (IMP)KGNoopNil},
    {"showWVIPExpireAlert", (IMP)KGNoopNil},
    {"showVipExpiredAlertDate", (IMP)KGNoopNil},
    {"showMusicPacketExpiredAlertDate", (IMP)KGNoopNil},
    {"showPlayPriviledgeAlert:priviledgeKey:thumb:isExpire:themeId:", (IMP)KGNoopNil},
    {"realShowV2WithIsExpire:days:", (IMP)KGNoopNil},
    {"realShowV3WithIsExpire:days:", (IMP)KGNoopNil},

    /* v4: 签到弹窗的真实 show 方法（每天签到赚概念币） */
    {"showCalendarSignInAlert:", (IMP)KGNoopNil},
    {"showCalendarSignInAlert:webAlertShowedBlock:", (IMP)KGNoopNil},
    {"showCalendarSignInAlert:sourceId:webAlertShowedBlock:", (IMP)KGNoopNil},
    {"p_showCalendarSignInAlert:", (IMP)KGNoopNil},
    {"showMyPageTaskCenterSignIn", (IMP)KGNoopNil},
    {"canShowCanlendarSignInAlert", (IMP)KGNoopNil},
    {"checkShowCalendarSignInAlertWithFirstPlay", (IMP)KGNoopNil},

    /* v5-B: 引导浮层（GuideView）真实显示方法。
     * 只挑 show 与 p_show 开头这类真正绘制的方法；避开带 complete/endShow block 的
     * （拦了不调 block 会让流程卡住）。中风险：首次用某功能会没提示，但功能本身可用。 */
    {"showGuide", (IMP)KGNoopNil},
    {"showGuideView", (IMP)KGNoopNil},
    {"showGuideView:", (IMP)KGNoopNil},
    {"showGuideViewIfNeeded", (IMP)KGNoopNil},
    {"showGuideViewInShareSheet", (IMP)KGNoopNil},
    {"showGuideAlertViewWithExtraAward:", (IMP)KGNoopNil},
    {"showSlideGuide", (IMP)KGNoopNil},
    {"showNextPlayGuideView", (IMP)KGNoopNil},
    {"showPlayDiyEntranceGuide", (IMP)KGNoopNil},
    {"showPlayDiyEntranceGuideSheet:", (IMP)KGNoopNil},
    {"showPlayerModeUpgradeGuideIfNeeded", (IMP)KGNoopNil},
    {"showPlayerPriviledgeGuideSheet:", (IMP)KGNoopNil},
    {"showPlayerPriviledgeAdGuideAlert", (IMP)KGNoopNil},
    {"showDetailGuide:", (IMP)KGNoopNil},
    {"showShareGuideView", (IMP)KGNoopNil},
    {"showLyricMakeToolGuide", (IMP)KGNoopNil},
    {"showCardPointGuideView", (IMP)KGNoopNil},
    {"showAIRadioGuideAlertView", (IMP)KGNoopNil},
    {"showHiresGuideAlert", (IMP)KGNoopNil},
    {"showPubshNotiGuideAlert", (IMP)KGNoopNil},
    {"showPubshNotiGuideAlert:", (IMP)KGNoopNil},
    {"showAdvertNotiGuideAlert:", (IMP)KGNoopNil},
    {"p_showNewCreationGuideAlertView", (IMP)KGNoopNil},
    {"p_showPlayDiyEntranceGuideSheet", (IMP)KGNoopNil},
    {"p_showPlayPostMoveGuideSheet", (IMP)KGNoopNil},
    {"p_showTaskCenterGuideAlertView", (IMP)KGNoopNil},
    {"checkAndShowGuideIfNeeded", (IMP)KGNoopNil},
    {"checkAndShowEditGuide", (IMP)KGNoopNil},
    {"checkAndShowLongPressGuide", (IMP)KGNoopNil},
    {"checkAndShowHiresGuideAlert", (IMP)KGNoopNil},
    {"checkShowGuide", (IMP)KGNoopNil},
    {"checkShowGuideTips", (IMP)KGNoopNil},
    {"checkShowGuideView", (IMP)KGNoopNil},
    {"checkToShowGuideView", (IMP)KGNoopNil},
    {"checkGuideViewShow", (IMP)KGNoopNil},
    {"canShowGuideView", (IMP)KGNoopNil},
    {"canShowGuideAlert", (IMP)KGNoopNil},
    {"checkShowAutoGuide", (IMP)KGNoopNil},
    {"delayShowLyricHandbookGuide", (IMP)KGNoopNil},

    /* v6-D: 臃肿功能入口（直播 / K歌 / 游戏 / 商城）纯跳转方法。
     * 只拦 UI 跳转与入口点击：点了没反应，但不隐藏 view、不动依赖，不会崩。
     * 刻意不碰：内购（goToAppStore 等，拦了 VIP 买不了）、主播开播、带 block 的方法。
     * 入口图标可能仍显示，只是点进去无反应；彻底隐藏入口需另行逐类验证。 */
    {"jumpToLivePage", (IMP)KGNoopNil},
    {"enterGame", (IMP)KGNoopNil},
    {"pushToGameViewController", (IMP)KGNoopNil},
    {"gotoFriendlyBattleGame", (IMP)KGNoopNil},
    {"gotoChangchangKsong", (IMP)KGNoopNil},
    {"goToKTVListenWork", (IMP)KGNoopNil},
    {"goToKtvPlayView:", (IMP)KGNoopNil},
    {"jumpToKtvDetailVC:songInfo:", (IMP)KGNoopNil},
    {"didClicKTVEnterButtonButton", (IMP)KGNoopNil},
    {"p_ktvEnterButtonClicked:", (IMP)KGNoopNil},
    {"enterStoreType:", (IMP)KGNoopNil},
    {"jumpThemeStorePage", (IMP)KGNoopNil},

    /* v7: 我的页「赚钱」= 任务中心（TaskCenter）入口。
     * 拦跳转 + 入口数据/显示判定；canShow* 用 KGNoopNil 返回 NO。 */
    {"goToTaskCenter", (IMP)KGNoopNil},
    {"goToTaskCenterWithSourceId:", (IMP)KGNoopNil},
    {"jumpToTaskCenter", (IMP)KGNoopNil},
    {"gotoTaskCenterView", (IMP)KGNoopNil},
    {"clickOpenTaskCenter", (IMP)KGNoopNil},
    {"requestTaskCenterEntrance", (IMP)KGNoopNil},
    {"canShowTaskCenter", (IMP)KGNoopNil},
    {"canShowDailyTaskCenter", (IMP)KGNoopNil},

    /* v7: 首页轮播图。之前只拦 request（走缓存绕过），这次连数据源+渲染一起拦。
     * 数据源方法返回空数组而非 nil，避免下游遍历崩溃。 */
    {"getCacheBannerInfoFroShow", (IMP)KGNoopEmptyArray},
    {"filterCanShowHomeBannerItem:", (IMP)KGNoopEmptyArray},
    {"refreshWithBanners:", (IMP)KGNoopNil},
    {"reloadBannerData", (IMP)KGNoopNil},
    {"showBannerByDiffCategory", (IMP)KGNoopNil},
    {"setupSliderBannerAdSubviews:", (IMP)KGNoopNil},
    {"refreshRecommendBannerFromRequestResponse:", (IMP)KGNoopNil},

    /* v7b: 首页运营卡片位数据源（概念实验室/盲盒/VIP推荐/小众宝藏等）。
     * 这些卡片由 discovery / home banner 信息接口下发，拦数据源返回空数组。
     * 注意：不碰 requestRecSortFirstPageData（首页推荐主接口），保住正常歌曲流。 */
    {"requestDiscoveryBannerInfo", (IMP)KGNoopNil},
    {"requestNewDiscoveryBannerInfo", (IMP)KGNoopNil},
    {"getDiscoveryBannerInfoWithError:", (IMP)KGNoopEmptyArray},
    {"getHomeADBannarListWithError:", (IMP)KGNoopEmptyArray},
    {"getHomeADBannarListWithWithRepCallBack:exceptionCallBack:", (IMP)KGNoopNil},
    {"getCardHomeBannerInfoWithError:", (IMP)KGNoopEmptyArray},
    {"requestBannerBackupForHomeWithError:", (IMP)KGNoopNil},
    {"requestBannerBackupForHomeWithSuccessBlock:failBlock:", (IMP)KGNoopNil},
    {"requestHomeTextAd", (IMP)KGNoopNil},

    /* v8: 轮播图缓存读取链路（v7 只拦了 FroShow 变体，实际还走这几个） */
    {"getCacheBannerInfo", (IMP)KGNoopEmptyArray},
    {"readBannerInfoFromLocalPlist", (IMP)KGNoopNil},
    {"refreshBannerList:", (IMP)KGNoopNil},
    {"updateBannerList", (IMP)KGNoopNil},
    {"setBannerInfoArray:", (IMP)KGNoop},
    {"setArrBannerList:", (IMP)KGNoop},
    {"setBannerInfos:", (IMP)KGNoop},

    /* v8: 我的页「赚钱」入口数据判定（v7 只拦 canShow，入口由这些驱动） */
    {"needRefreshTaskCenterEntrance", (IMP)KGNoopNil},
    {"mineTaskCenterReadPointShow", (IMP)KGNoopNil},
    {"checkCanShowMyPageTaskCenterSignIn", (IMP)KGNoopNil},
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

    /* v8：首页 6 个运营卡片 cell 运行时隐藏 */
    KGInstallCardCellHooks();
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
