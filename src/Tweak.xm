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
 *  - v9：v8 仍漏两张卡且隐藏后留大片空白，修正方向：
 *     * 识别：按 cell 内 UILabel / accessibilityLabel 文字命中标题关键词，
 *       不再只靠类名（「喜欢 X 的 TA 也喜欢」「概念er新推」的类名猜错）。
 *     * 高度：记录命中的 collectionView / indexPath，hook sizeForItem 与
 *       heightForRow 返回 0，并 invalidateLayout，空白随卡片一起消失。
 *     * 重试：cell 类可能在用户首次进发现页才注册，加 1 秒 × 180 次重试。
 *     * 赚钱：补拦 taskCenterButtonClick / p_btnTaskCenterAction 等真实点击。
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

/* ============ v9: 运行时状态 / 通用工具 ============
 * 1) 保存被替换方法的原始 IMP，便于「先调用原实现，再判断是否隐藏」；
 * 2) 记录命中关键词的 indexPath，供 sizeForItem / heightForRow 归零；
 * 3) 按 cell 内文字识别，避免类名猜错。 */
static NSMutableDictionary *KGOriginalIMPs = nil;
static NSMutableSet *KGHiddenPaths = nil;
static NSArray *KGHideKeywords = nil;

static void KGInitRuntimeState(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        KGOriginalIMPs = [NSMutableDictionary dictionary];
        KGHiddenPaths = [NSMutableSet set];
        KGHideKeywords = @[
            @"TA也喜欢", @"ta也喜欢", @"TA特喜欢", @"ta特喜欢",
            @"概念er新推", @"概念实验室", @"曲风盲盒", @"VIP专属", @"小众宝藏",
            @"赚钱", @"赚金币", @"赚概念币", @"任务中心"
        ];
    });
}

static void KGStoreOriginalIMP(Method m) {
    KGInitRuntimeState();
    if (!m) { return; }
    NSValue *key = [NSValue valueWithPointer:(void *)m];
    if (KGOriginalIMPs[key]) { return; }
    IMP original = method_getImplementation(m);
    if (original) { KGOriginalIMPs[key] = [NSValue valueWithPointer:(void *)original]; }
}

static IMP KGOriginalIMP(Method m) {
    KGInitRuntimeState();
    if (!m) { return NULL; }
    NSValue *value = KGOriginalIMPs[[NSValue valueWithPointer:(void *)m]];
    return value ? (IMP)[value pointerValue] : NULL;
}

static BOOL KGTextMatches(NSString *text) {
    if (text.length == 0) { return NO; }
    for (NSString *keyword in KGHideKeywords) {
        if ([text rangeOfString:keyword options:(NSCaseInsensitiveSearch | NSLiteralSearch)].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static BOOL KGViewTextMatches(UIView *view, NSInteger depth) {
    if (!view || depth > 12) { return NO; }
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        if (KGTextMatches(label.text) || KGTextMatches(label.attributedText.string)) { return YES; }
    }
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        if (KGTextMatches(button.titleLabel.text)) { return YES; }
    }
    if (KGTextMatches(view.accessibilityLabel)) { return YES; }
    for (UIView *subview in view.subviews) {
        if (KGViewTextMatches(subview, depth + 1)) { return YES; }
    }
    return NO;
}

static void KGHideView(UIView *view) {
    if (view.hidden != YES) { view.hidden = YES; }
    if (view.alpha != 0.0) { view.alpha = 0.0; }
}

static NSString *KGPathKey(id container, NSInteger section, NSInteger index) {
    return [NSString stringWithFormat:@"%p-%ld-%ld", (__bridge void *)container, (long)section, (long)index];
}

static BOOL KGIsHiddenPath(id container, NSInteger section, NSInteger index) {
    KGInitRuntimeState();
    return [KGHiddenPaths containsObject:KGPathKey(container, section, index)];
}

static BOOL KGMarkHiddenPath(id container, NSInteger section, NSInteger index) {
    KGInitRuntimeState();
    NSString *key = KGPathKey(container, section, index);
    if ([KGHiddenPaths containsObject:key]) { return NO; }
    [KGHiddenPaths addObject:key];
    return YES;
}

/* ============ v8/v9: 首页运营卡片 + 任务入口 view 运行时隐藏 ============
 * v8：按类名 hook layoutSubviews 让 cell 自身隐藏。
 * v9：额外 hook preferredLayoutAttributesFittingAttributes: 返回 zero size，
 *     只改本类方法，绝不碰父类，避免误伤普通歌曲 cell。 */
static void KGHiddenLayout(id self, SEL _cmd) {
    KGHideView((UIView *)self);
}

static UICollectionViewLayoutAttributes *KGHiddenFitting(id self, SEL _cmd, UICollectionViewLayoutAttributes *attributes) {
    UICollectionViewLayoutAttributes *result = [attributes copy];
    if (!result) { result = [UICollectionViewLayoutAttributes new]; }
    result.size = CGSizeZero;
    result.hidden = YES;
    result.alpha = 0.0;
    return result;
}

/* 只给「本类」安装方法：绝不用 class_getInstanceMethod（会沿继承链拿到父类实现） */
static BOOL KGInstallOwnMethod(Class cls, SEL sel, IMP imp, const char *types) {
    if (class_addMethod(cls, sel, imp, types)) { return YES; }
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    BOOL done = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (sel_isEqual(method_getName(list[i]), sel)) {
            method_setImplementation(list[i], imp);
            done = YES;
            break;
        }
    }
    free(list);
    return done;
}

static void KGInstallCardCellHooks(void) {
    static const char *names[] = {
        "KGYouthNewDiscoverConceptLabV5Cell",
        "KGYouthNewDiscoverNicheRecV5Cell",
        "KGYouthNewDiscoverVipRecV5Cell",
        "KGYouthNewDiscoverDifTagRecV5Cell",
        "KGYouthNewDiscoverTagRecV5Cell",
        "KGYouthNewDiscoverTagRecItemV5Cell",
        "KGYouthNewDiscoverTagRecIpadV5Cell",
        "KGYouthNewDiscoverHotRecV5Cell",
        "KGYouthNewDiscoverAdV5Cell",
        "KGYouthNewDiscoverAdItemV5Cell",
        "KGYouthNewDiscoverAdOperItemV5Cell",
        "KGYouthNewDiscoverUniAdItemV5Cell",
        "KGYouthNewDiscoverCardAdItemV5Cell",
        "KGYouthNewDiscoverCardAdV5View",
        "KGYouthNewDiscoverCardAdView",
        "KGYouthNewDiscoverAdBannerCollectionCell",
        "YouthDiscoverTmeMaskAdV5Cell",
        "YouthDiscoverTmeWaistAdV5Cell",
        "YouthNewDiscoverConceptLabItemBaseCell",
        "YouthNewDiscoverDifTagRecItemBaseCell",
        "YouthNewDiscoverDifTagRecItemBigCell",
        "YouthNewDiscoverDifTagRecItemSmallCell",
        "YouthNewDiscoverDifTagRecItemSmallSongTableCell",
        "KGYouthNewDiscoverVipRecItemV5Cell",
        "KGYouthNewDiscoverNicheRecItemV5Cell",
        "KGYouthMineHeaderTaskView",
        "KGYouthMineTaskCenterView",
        "YouthMineFreeReceiveTaskBarView",
        NULL
    };
    static BOOL installed[32] = { NO };
    SEL layoutSel = @selector(layoutSubviews);
    SEL fittingSel = @selector(preferredLayoutAttributesFittingAttributes:);

    for (int i = 0; names[i] && i < 32; i++) {
        if (installed[i]) { continue; }
        Class cls = objc_getClass(names[i]);
        if (!cls) { continue; }   // 类还没注册，下一秒再试

        BOOL a = KGInstallOwnMethod(cls, layoutSel, (IMP)KGHiddenLayout, "v@:");
        BOOL b = KGInstallOwnMethod(cls, fittingSel, (IMP)KGHiddenFitting, "@:@");
        if (a || b) {
            installed[i] = YES;
            KGLogAlways(@"hidden hooks installed: %s", names[i]);
        } else {
            KGLogAlways(@"cannot hook: %s", names[i]);
        }
    }
}

/* v9：类常在用户首次进发现页时才注册，6 次时机不够，补 1 秒 × 180 次重试 */
static NSTimer *KGCardHookTimer = nil;
static NSInteger KGCardHookTicks = 0;
static void KGStartCardHookTimer(void) {
    KGInstallCardCellHooks();
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        KGCardHookTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                           repeats:YES
                                                             block:^(NSTimer *timer) {
            KGInstallCardCellHooks();
            if (++KGCardHookTicks >= 180) {
                [timer invalidate];
                KGCardHookTimer = nil;
            }
        }];
        if (KGCardHookTimer) {
            [[NSRunLoop mainRunLoop] addTimer:KGCardHookTimer forMode:NSRunLoopCommonModes];
        }
    });
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

/* ============ v9: 按文字隐藏 + 高度归零（保留原实现） ============
 * 这些 hook 不能置空原实现：先调用 original，再按 cell 内文字判断。
 * 原始 IMP 在 KGInstallSelectorHooks 替换前存进 KGOriginalIMPs。 */
typedef CGSize (*KGSizeIMP)(id, SEL, id, id, id);
typedef CGFloat (*KGHeightIMP)(id, SEL, id, id);

static IMP KGCurrentOriginalIMP(id self, SEL sel) {
    return KGOriginalIMP(class_getInstanceMethod(object_getClass(self), sel));
}

static void KGWillDisplayCollectionCell(id self, SEL _cmd, UICollectionView *collectionView,
                                        UICollectionViewCell *cell, NSIndexPath *indexPath) {
    IMP original = KGCurrentOriginalIMP(self, _cmd);
    if (original) { ((void (*)(id, SEL, id, id, id))original)(self, _cmd, collectionView, cell, indexPath); }
    if (!KGViewTextMatches(cell, 0)) { return; }

    KGHideView(cell);
    NSInteger index = indexPath.item;
    BOOL fresh = KGMarkHiddenPath(collectionView, indexPath.section, index);
    if (fresh) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [collectionView.collectionViewLayout invalidateLayout];
        });
    }
    KGLogAlways(@"hidden collection cell by text: %ld-%ld", (long)indexPath.section, (long)index);
}

static void KGWillDisplayTableCell(id self, SEL _cmd, UITableView *tableView,
                                   UITableViewCell *cell, NSIndexPath *indexPath) {
    IMP original = KGCurrentOriginalIMP(self, _cmd);
    if (original) { ((void (*)(id, SEL, id, id, id))original)(self, _cmd, tableView, cell, indexPath); }
    if (!KGViewTextMatches(cell, 0)) { return; }

    KGHideView(cell);
    NSInteger index = indexPath.row;
    BOOL fresh = KGMarkHiddenPath(tableView, indexPath.section, index);
    if (fresh) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [tableView reloadData];
        });
    }
    KGLogAlways(@"hidden table cell by text: %ld-%ld", (long)indexPath.section, (long)index);
}

static void KGWillDisplaySupplementary(id self, SEL _cmd, UICollectionView *collectionView,
                                       UIView *view, NSString *kind, NSIndexPath *indexPath) {
    IMP original = KGCurrentOriginalIMP(self, _cmd);
    if (original) { ((void (*)(id, SEL, id, id, id, id))original)(self, _cmd, collectionView, view, kind, indexPath); }
    if (KGViewTextMatches(view, 0)) { KGHideView(view); }
}

static void KGWillDisplayTableHeader(id self, SEL _cmd, UITableView *tableView,
                                     UIView *view, NSInteger section) {
    IMP original = KGCurrentOriginalIMP(self, _cmd);
    if (original) { ((void (*)(id, SEL, id, id, NSInteger))original)(self, _cmd, tableView, view, section); }
    if (KGViewTextMatches(view, 0)) { KGHideView(view); }
}

static CGSize KGSizeForItem(id self, SEL _cmd, UICollectionView *collectionView,
                            UICollectionViewLayout *layout, NSIndexPath *indexPath) {
    NSInteger index = indexPath.item;
    if (KGIsHiddenPath(collectionView, indexPath.section, index)) { return CGSizeZero; }
    IMP original = KGCurrentOriginalIMP(self, _cmd);
    if (original) { return ((KGSizeIMP)original)(self, _cmd, collectionView, layout, indexPath); }
    return CGSizeMake(1.0, 1.0);
}

static CGFloat KGHeightForRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    NSInteger index = indexPath.row;
    if (KGIsHiddenPath(tableView, indexPath.section, index)) { return 0.0; }
    IMP original = KGCurrentOriginalIMP(self, _cmd);
    if (original) { return ((KGHeightIMP)original)(self, _cmd, tableView, indexPath); }
    return 0.0;
}

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

    /* v9: 赚钱入口的真实点击方法（v7/v8 只拦跳转与数据判定，入口仍能点进去） */
    {"taskCenterButtonClick", (IMP)KGNoopNil},
    {"p_btnTaskCenterAction", (IMP)KGNoopNil},
    {"clickWithTaskCenter:", (IMP)KGNoopNil},
    {"goToTaskCenterWithSourceId:actionType:taskId:animated:", (IMP)KGNoopNil},
    {"goToTaskCenterWithSourceId:actionType:taskId:giftId:animated:", (IMP)KGNoopNil},
    {"refreshBottomTaskCenterView:", (IMP)KGNoopNil},
    {"setBottomTaskCenterView:", (IMP)KGNoop},
    {"earnMoneyUrlStr", (IMP)KGNoopNil},
};
static const NSUInteger kSelHookCount = sizeof(kSelHooks) / sizeof(kSelHooks[0]);

/* v9: 这些 hook 必须先调用原实现，不能置空。替换前保存 original IMP。 */
static KGSelHook kPreserveSelHooks[] = {
    {"collectionView:willDisplayCell:forItemAtIndexPath:", (IMP)KGWillDisplayCollectionCell},
    {"tableView:willDisplayCell:forRowAtIndexPath:", (IMP)KGWillDisplayTableCell},
    {"collectionView:willDisplaySupplementaryView:forElementKind:atIndexPath:", (IMP)KGWillDisplaySupplementary},
    {"tableView:willDisplayHeaderView:forSection:", (IMP)KGWillDisplayTableHeader},
    {"tableView:willDisplayFooterView:forSection:", (IMP)KGWillDisplayTableHeader},
    {"collectionView:layout:sizeForItemAtIndexPath:", (IMP)KGSizeForItem},
    {"tableView:heightForRowAtIndexPath:", (IMP)KGHeightForRow},
    {"tableView:estimatedHeightForRowAtIndexPath:", (IMP)KGHeightForRow},
};
static const NSUInteger kPreserveSelHookCount = sizeof(kPreserveSelHooks) / sizeof(kPreserveSelHooks[0]);

static void KGInstallSelHookList(KGSelHook *list, NSUInteger listCount, NSMutableSet *hookedMethods) {
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) { return; }
    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        for (NSUInteger j = 0; j < listCount; j++) {
            SEL sel = sel_registerName(list[j].sel);
            Method m = class_getInstanceMethod(cls, sel);
            if (!m) { continue; }
            NSValue *key = [NSValue valueWithPointer:(void *)m];
            if ([hookedMethods containsObject:key]) { continue; }
            [hookedMethods addObject:key];
            KGStoreOriginalIMP(m);
            method_setImplementation(m, list[j].imp);
            KGLog(@"global hooked %s on %@", list[j].sel, NSStringFromClass(cls));
        }
    }
    free(classes);
}

static void KGInstallSelectorHooks(void) {
    KGInitRuntimeState();
    static NSMutableSet *hookedMethods = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ hookedMethods = [NSMutableSet set]; });

    KGInstallSelHookList(kSelHooks, kSelHookCount, hookedMethods);
    KGInstallSelHookList(kPreserveSelHooks, kPreserveSelHookCount, hookedMethods);
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

    /* v8/v9：首页运营卡片 cell 运行时隐藏（定时器在 %ctor 里启动） */
    KGInstallCardCellHooks();
}

%ctor {
    KGLogAlways(@"loaded for com.kugou.kgyouth 5.3.3 (runtime hook mode)");

    /* 1. 立刻挂一次（类已在内存时直接生效） */
    KGInstallAllHooks();

    /* 2. 主线程下一个 loop 再挂（覆盖 guest App 刚 dlopen 的情况），并启动 cell hook 重试定时器 */
    dispatch_async(dispatch_get_main_queue(), ^{
        KGInstallAllHooks();
        KGStartCardHookTimer();
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
