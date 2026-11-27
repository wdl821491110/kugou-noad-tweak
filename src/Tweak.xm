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
 *     * 重试：cell 类可能在用户首次进发现页才注册，加 1 秒 × 180 次重试。
 *     * 赚钱：补拦 taskCenterButtonClick / p_btnTaskCenterAction 等真实点击。
 *  - v9b：v9 启动黑屏后闪退，判定是 sizeForItem / heightForRow /
 *     preferredLayoutAttributesFittingAttributes 归零导致布局反复重算。
 *     v9b 回退全部高度归零，只保留按文字隐藏 + 真实点击拦截，先保启动稳定。
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
static NSArray *KGHideKeywords = nil;
static NSMutableSet *KGHiddenPaths = nil;

static void KGInitRuntimeState(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        KGOriginalIMPs = [NSMutableDictionary dictionary];
        KGHiddenPaths = [NSMutableSet set];
        KGHideKeywords = @[
            @"TA也喜欢", @"ta也喜欢", @"TA特喜欢", @"ta特喜欢",
            @"概念er新推", @"概念实验室", @"曲风盲盒", @"VIP专属", @"小众宝藏",
            @"赚钱", @"赚金币", @"赚概念币", @"任务中心",
            @"频道推荐", @"免费听", @"潮流尝鲜"
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

/* ============ v9g: 隐藏白名单（防关键词误伤） ============
 * 免费听页（YouthAIFreeTabViewController）自身元素含「免费听」文字，
 * 全局 willDisplay 隐藏会把整个页面误杀成空白。
 * 只允许在首页 / 发现页 / 我的页的列表容器里做关键词隐藏。 */
static UIViewController *KGViewControllerForView(UIView *view) {
    UIResponder *r = view;
    while (r && ![r isKindOfClass:[UIViewController class]]) { r = r.nextResponder; }
    return (UIViewController *)r;
}

static BOOL KGContainerAllowsHiding(UIView *container) {
    UIViewController *vc = KGViewControllerForView(container);
    if (!vc) { return NO; }
    NSString *name = NSStringFromClass([vc class]);
    static NSArray *prefixes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        prefixes = @[@"KGYouthHome", @"KGYouthDiscover", @"KGYouthNewDiscover",
                     @"YouthNewDiscover", @"KGYouthMine", @"YouthHomeMine"];
    });
    for (NSString *p in prefixes) {
        if ([name hasPrefix:p]) { return YES; }
    }
    return NO;
}

/* ============ v8/v9: 首页运营卡片 + 任务入口 view 运行时隐藏 ============
 * 按类名 hook layoutSubviews 让 cell 自身隐藏；只改本类方法，
 * 绝不碰父类，避免误伤普通歌曲 cell。 */
static void KGHiddenLayout(id self, SEL _cmd) {
    KGHideView((UIView *)self);
}

/* ============ v9f: 隐藏路径记录 + 高度归零（消除大片空白） ============
 * v9 曾实现过，当时被误判为黑屏元凶回退；真凶是全局遍历超时（v9e 已修）。
 * 命中的 collectionView/tableView + indexPath 记进 KGHiddenPaths，
 * sizeForItem / heightForRow 对这些路径返回 0，并 invalidateLayout 刷新。 */
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

    for (int i = 0; names[i] && i < 32; i++) {
        if (installed[i]) { continue; }
        Class cls = objc_getClass(names[i]);
        if (!cls) { continue; }   // 类还没注册，下一秒再试

        if (KGInstallOwnMethod(cls, layoutSel, (IMP)KGHiddenLayout, "v@:")) {
            installed[i] = YES;
            KGLogAlways(@"hidden hook installed: %s", names[i]);
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

/* ============ v9g: 首页固定不滑动 ============
 * 用户要求首页固定、不能上下滑动。类级 hook KGYouthHomeController 的
 * viewDidAppear:，先调父类实现（本类无实现时从父类拿），再递归把
 * 视图树里的 UIScrollView 全部 scrollEnabled=NO。 */
static void KGDisableScrolling(UIView *view) {
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)view;
        if (sv.scrollEnabled) { sv.scrollEnabled = NO; }
    }
    for (UIView *sub in view.subviews) { KGDisableScrolling(sub); }
}

static IMP KGHomeOrigAppear = NULL;
static void KGHomeDidAppear(id self, SEL _cmd, BOOL animated) {
    if (KGHomeOrigAppear) {
        ((void (*)(id, SEL, BOOL))KGHomeOrigAppear)(self, _cmd, animated);
    } else {
        /* class_addMethod 新加的场景：本类无实现，兜底调父类 */
        Method superM = class_getInstanceMethod(class_getSuperclass(object_getClass(self)), _cmd);
        if (superM) { ((void (*)(id, SEL, BOOL))method_getImplementation(superM))(self, _cmd, animated); }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        KGDisableScrolling((UIView *)self);
    });
}

static void KGInstallHomeFixedHook(void) {
    static BOOL installed = NO;
    if (installed) { return; }
    Class cls = objc_getClass("KGYouthHomeController");
    if (!cls) { return; }
    SEL sel = @selector(viewDidAppear:);
    if (class_addMethod(cls, sel, (IMP)KGHomeDidAppear, "v@:c")) {
        installed = YES;
        KGLogAlways(@"home fixed hook added");
        return;
    }
    /* 本类已有实现：存原 IMP 后替换，绝不丢原逻辑 */
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        if (sel_isEqual(method_getName(list[i]), sel)) {
            KGHomeOrigAppear = method_getImplementation(list[i]);
            method_setImplementation(list[i], (IMP)KGHomeDidAppear);
            installed = YES;
            KGLogAlways(@"home fixed hook replaced");
            break;
        }
    }
    free(list);
}

/* ============ v9h: 视图树定期扫描（换实现方式，不靠方法 hook） ============
 * 「赚钱」入口不走 willDisplay、方法 hook 也不命中，彻底换思路：
 * 定时扫描可见 window 的整棵视图树，发现文字命中关键词的 UILabel，
 * 就把它的入口容器（向上第一个有实际尺寸的祖先）整体隐藏。
 * 不依赖类名和 hook 命中，所见即所得；已隐藏子树自动剪枝。 */
static void KGScanAndHideEntryViews(UIView *view, NSInteger depth) {
    if (!view || view.hidden || view.alpha <= 0.01 || depth > 24) { return; }
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        if (KGTextMatches(label.text) || KGTextMatches(label.attributedText.string)) {
            /* 向上找最多 3 层，第一个有实际尺寸（>40x20）的祖先即入口容器 */
            UIView *target = label;
            UIView *parent = label.superview;
            for (int i = 0; parent && i < 3; i++) {
                CGSize s = parent.frame.size;
                if (s.width > 40 && s.height > 20) { target = parent; break; }
                parent = parent.superview;
            }
            KGHideView(target);
            KGLogAlways(@"entry scan hidden: %@ in %@", NSStringFromClass([target class]),
                        NSStringFromClass([KGViewControllerForView(target) class] ?: [NSObject class]));
            return;
        }
    }
    for (UIView *sub in view.subviews) { KGScanAndHideEntryViews(sub, depth + 1); }
}

static void KGScanAllWindows(void) {
    KGInitRuntimeState();
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (!w.hidden) { KGScanAndHideEntryViews(w, 0); }
    }
}

static NSTimer *KGEntryScanTimer = nil;
static NSInteger KGEntryScanTicks = 0;
static void KGStartEntryScanTimer(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        KGEntryScanTimer = [NSTimer scheduledTimerWithTimeInterval:1.5
                                                            repeats:YES
                                                              block:^(NSTimer *timer) {
            dispatch_async(dispatch_get_main_queue(), ^{
                KGScanAllWindows();
            });
            if (++KGEntryScanTicks >= 240) {   /* 1.5s × 240 = 6 分钟 */
                [timer invalidate];
                KGEntryScanTimer = nil;
            }
        }];
        if (KGEntryScanTimer) {
            [[NSRunLoop mainRunLoop] addTimer:KGEntryScanTimer forMode:NSRunLoopCommonModes];
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

/* ============ v9/v9b/v9f: 按文字隐藏 + 高度归零 ============
 * 这些 hook 不能置空原实现：先调用 original，再按 cell 内文字判断。
 * 原始 IMP 在 KGInstallSelectorHooks 替换前存进 KGOriginalIMPs。
 * v9f：恢复高度归零——命中的路径 sizeForItem/heightForRow 返回 0，
 * 并 invalidateLayout / reloadData 消除大片空白。 */
static IMP KGCurrentOriginalIMP(id self, SEL sel) {
    return KGOriginalIMP(class_getInstanceMethod(object_getClass(self), sel));
}

static void KGWillDisplayCollectionCell(id self, SEL _cmd, UICollectionView *collectionView,
                                        UICollectionViewCell *cell, NSIndexPath *indexPath) {
    IMP original = KGCurrentOriginalIMP(self, _cmd);
    if (original) { ((void (*)(id, SEL, id, id, id))original)(self, _cmd, collectionView, cell, indexPath); }
    if (!KGContainerAllowsHiding(collectionView)) { return; }
    if (!KGViewTextMatches(cell, 0)) { return; }

    KGHideView(cell);
    BOOL fresh = KGMarkHiddenPath(collectionView, indexPath.section, indexPath.item);
    if (fresh) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [collectionView.collectionViewLayout invalidateLayout];
        });
    }
    KGLogAlways(@"hidden collection cell by text: %ld-%ld",
                (long)indexPath.section, (long)indexPath.item);
}

static void KGWillDisplayTableCell(id self, SEL _cmd, UITableView *tableView,
                                   UITableViewCell *cell, NSIndexPath *indexPath) {
    IMP original = KGCurrentOriginalIMP(self, _cmd);
    if (original) { ((void (*)(id, SEL, id, id, id))original)(self, _cmd, tableView, cell, indexPath); }
    if (!KGContainerAllowsHiding(tableView)) { return; }
    if (!KGViewTextMatches(cell, 0)) { return; }

    KGHideView(cell);
    BOOL fresh = KGMarkHiddenPath(tableView, indexPath.section, indexPath.row);
    if (fresh) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [tableView reloadData];
        });
    }
    KGLogAlways(@"hidden table cell by text: %ld-%ld",
                (long)indexPath.section, (long)indexPath.row);
}

static void KGWillDisplaySupplementary(id self, SEL _cmd, UICollectionView *collectionView,
                                       UIView *view, NSString *kind, NSIndexPath *indexPath) {
    IMP original = KGCurrentOriginalIMP(self, _cmd);
    if (original) { ((void (*)(id, SEL, id, id, id, id))original)(self, _cmd, collectionView, view, kind, indexPath); }
    if (!KGContainerAllowsHiding(collectionView)) { return; }
    if (KGViewTextMatches(view, 0)) { KGHideView(view); }
}

static void KGWillDisplayTableHeader(id self, SEL _cmd, UITableView *tableView,
                                     UIView *view, NSInteger section) {
    IMP original = KGCurrentOriginalIMP(self, _cmd);
    if (original) { ((void (*)(id, SEL, id, id, NSInteger))original)(self, _cmd, tableView, view, section); }
    if (!KGContainerAllowsHiding(tableView)) { return; }
    if (KGViewTextMatches(view, 0)) { KGHideView(view); }
}

typedef CGSize (*KGSizeIMP)(id, SEL, id, id, id);
typedef CGFloat (*KGHeightIMP)(id, SEL, id, id);

static CGSize KGSizeForItem(id self, SEL _cmd, UICollectionView *collectionView,
                            UICollectionViewLayout *layout, NSIndexPath *indexPath) {
    if (KGIsHiddenPath(collectionView, indexPath.section, indexPath.item)) { return CGSizeZero; }
    IMP original = KGCurrentOriginalIMP(self, _cmd);
    if (original) { return ((KGSizeIMP)original)(self, _cmd, collectionView, layout, indexPath); }
    return CGSizeMake(1.0, 1.0);
}

static CGFloat KGHeightForRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    if (KGIsHiddenPath(tableView, indexPath.section, indexPath.row)) { return 0.0; }
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
    /* v9h: 退路恢复——置空 earnMoneyUrlStr，入口万一漏网，点进去也是拼命加载中 */
    {"earnMoneyUrlStr", (IMP)KGNoopNil},
    /* v9f: 任务入口 view 的真实显示/点击（方法 hook 对入口不一定命中，
     * v9g 起由视图树扫描兜底做视觉隐藏） */
    {"showTaskView", (IMP)KGNoopNil},
    {"clickTaskView", (IMP)KGNoopNil},
    {"checkShowTaskView", (IMP)KGNoopNil},
    {"checkTaskViewShowBI", (IMP)KGNoopNil},
    {"setTaskView:", (IMP)KGNoop},
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

/* v9g: 已检查类缓存（KGInstallSelHookList 跳过已检查过的类） */
static NSMutableSet *KGCheckedClasses = nil;

static NSUInteger KGInstallSelHookList(KGSelHook *list, NSUInteger listCount, NSMutableSet *hookedMethods) {
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) { return 0; }
    __block NSUInteger added = 0;
    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        /* v9g: 已检查过的类直接跳过 —— 重试遍历只处理新注册类，
         * 成本从几秒降到几毫秒，让长周期重试可行（赚钱入口类是
         * 用户首次进「我的」页才懒加载注册的）。 */
        NSValue *clsKey = [NSValue valueWithPointer:(void *)cls];
        if ([KGCheckedClasses containsObject:clsKey]) { continue; }
        [KGCheckedClasses addObject:clsKey];
        for (NSUInteger j = 0; j < listCount; j++) {
            SEL sel = sel_registerName(list[j].sel);
            Method m = class_getInstanceMethod(cls, sel);
            if (!m) { continue; }
            NSValue *key = [NSValue valueWithPointer:(void *)m];
            if ([hookedMethods containsObject:key]) { continue; }
            [hookedMethods addObject:key];
            KGStoreOriginalIMP(m);
            method_setImplementation(m, list[j].imp);
            added++;
            KGLog(@"global hooked %s on %@", list[j].sel, NSStringFromClass(cls));
        }
    }
    free(classes);
    return added;
}

static NSUInteger KGInstallSelectorHooksSlow(void) {
    KGInitRuntimeState();
    if (!KGCheckedClasses) { KGCheckedClasses = [NSMutableSet set]; }
    static NSMutableSet *hookedMethods = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ hookedMethods = [NSMutableSet set]; });

    NSUInteger added = 0;
    added += KGInstallSelHookList(kSelHooks, kSelHookCount, hookedMethods);
    added += KGInstallSelHookList(kPreserveSelHooks, kPreserveSelHookCount, hookedMethods);
    return added;
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

    /* v8/v9：首页运营卡片 cell 运行时隐藏（定时器在 %ctor 里启动） */
    KGInstallCardCellHooks();
}

/* ============ v9e: 慢批次（全局 selector 遍历） ============
 * 崩溃证据：objc_copyClassList 遍历 21529 类 × 200+ selector 的
 * class_getInstanceMethod 在 didFinishLaunching 通知里同步执行，
 * 把 scene-create 拖过 8.4 秒看门狗红线（栈：class_getInstanceMethod ← dylib）。
 * 因此全局遍历绝不能出现在启动同步路径上：
 * 只在 DidBecomeActive 之后 / 秒级延迟时机异步执行，成功一次即停。 */
static NSUInteger KGInstallSelectorHooksSlow(void);

/* v9g: 慢批次从「3 次即停」改为长周期重试——赚钱入口类是懒加载注册，
 * 15 秒内根本没出现。有类缓存后每次重试只扫新类，2 秒一次可持续跑。 */
static BOOL KGSlowHooksDone = NO;
static NSInteger KGSlowIdleTicks = 0;
static void KGInstallSlowHooks(void) {
    if (KGSlowHooksDone) { return; }
    NSUInteger added = KGInstallSelectorHooksSlow();
    if (added == 0) {
        KGSlowIdleTicks++;
        /* 连续 20 次无新增（约 40 秒无新类）才停 */
        if (KGSlowIdleTicks >= 20) {
            KGSlowHooksDone = YES;
            KGLogAlways(@"slow hooks all installed");
        }
    } else {
        KGSlowIdleTicks = 0;
        KGLogAlways(@"slow hooks +%lu new", (unsigned long)added);
    }
}

static NSTimer *KGSlowHookTimer = nil;
static NSInteger KGSlowHookTicks = 0;
static void KGStartSlowHookTimer(void) {
    KGInstallSlowHooks();
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        KGSlowHookTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                           repeats:YES
                                                             block:^(NSTimer *timer) {
            KGInstallSlowHooks();
            KGInstallHomeFixedHook();   /* 首页类可能晚期注册，顺带重试 */
            if (++KGSlowHookTicks >= 150 || KGSlowHooksDone) {
                [timer invalidate];
                KGSlowHookTimer = nil;
            }
        }];
        if (KGSlowHookTimer) {
            [[NSRunLoop mainRunLoop] addTimer:KGSlowHookTimer forMode:NSRunLoopCommonModes];
        }
    });
}

%ctor {
    KGLogAlways(@"loaded for com.kugou.kgyouth 5.3.3 (runtime hook mode)");

    /* 1. 立刻挂一次（类已在内存时直接生效）——只跑快批次 */
    KGInstallAllHooks();

    /* 2. 主线程下一个 loop 再挂（覆盖 guest App 刚 dlopen 的情况），并启动各重试定时器 */
    dispatch_async(dispatch_get_main_queue(), ^{
        KGInstallAllHooks();
        KGStartCardHookTimer();
        KGStartSlowHookTimer();
        KGInstallHomeFixedHook();
        KGStartEntryScanTimer();
    });

    /* 3. App 启动完成时再挂一次——仍然只跑快批次 */
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        KGInstallAllHooks();
    }];

    /* 4. 分级延迟兜底：0.1 / 0.5 / 2 / 5 秒——只跑快批次 */
    NSArray *delays = @[@0.1, @0.5, @2.0, @5.0];
    for (NSNumber *d in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            KGInstallAllHooks();
        });
    }

    /* 5. 慢批次（全局 selector 遍历）：只在启动彻底完成后执行。
     * DidBecomeActive 已在首帧渲染后；8/15 秒双兜底防漏。
     * 主队列串行执行，与 hookedMethods set 的线程安全要求一致。 */
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{
            KGInstallSlowHooks();
        });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        KGInstallSlowHooks();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        KGInstallSlowHooks();
    });
}
