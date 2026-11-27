/* kgvipaward 调试版 — 酷狗概念版「看广告领会员」直领
 *
 * 三层可见反馈（弹窗）：
 *   1. App 启动后 3 秒：「KGVipAward 已加载」→ dylib 被 LiveContainer 装上了
 *   2. hook 成功挂载时：「已挂载」→ 目标类已注册且方法已替换
 *   3. 点击领奖入口时：「已触发直领」→ 入口方法被命中
 * 哪一层没弹，问题就出在哪一层。
 *
 * 实现与 v9h 相同：纯 objc/runtime 挂载，不依赖 CydiaSubstrate。
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void KGVipAlert(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = nil;
        /* iOS13+ scene API：遍历所有连接 scene 找前台 key window，避免 keyWindow 弃用告警 */
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState != UISceneActivationStateForegroundActive) { continue; }
            for (UIWindow *win in ws.windows) {
                if (win.isKeyWindow) { root = win.rootViewController; break; }
            }
            if (root) { break; }
        }
        if (!root) { return; }
        while (root.presentedViewController) { root = root.presentedViewController; }
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"KGVipAward"
                                                                    message:msg
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [root presentViewController:ac animated:YES completion:nil];
    });
}

/* 替换后的入口实现：void(id, SEL, id block) */
static void KGVipDirectReceive(id self, SEL _cmd, id callback) {
    KGVipAlert([NSString stringWithFormat:@"已触发直领：%@（跳过广告）", NSStringFromSelector(_cmd)]);
    Class cls = object_getClass(self);
    /* recordStartTime / recordEndTime 先补上（领奖链路可能校验起止时间） */
    Method m1 = class_getInstanceMethod(cls, sel_registerName("recordStartTime"));
    if (m1) { ((void (*)(id, SEL))method_getImplementation(m1))(self, method_getName(m1)); }
    Method m2 = class_getInstanceMethod(cls, sel_registerName("recordEndTime"));
    if (m2) { ((void (*)(id, SEL))method_getImplementation(m2))(self, method_getName(m2)); }
    Method m3 = class_getInstanceMethod(cls, sel_registerName("receiveAwardAfterSeeVideo"));
    if (m3) {
        ((void (*)(id, SEL))method_getImplementation(m3))(self, method_getName(m3));
    } else {
        KGVipAlert(@"receiveAwardAfterSeeVideo 不存在！");
    }
    if (callback) { ((void (^)(void))callback)(); }
}

/* 类可能懒加载注册：定时重试直到挂上 */
static void KGVipInstallHooks(void) {
    static BOOL entryDone = NO;
    static BOOL playerDone = NO;
    static BOOL loadedDone = NO;
    Class cls = objc_getClass("YouthFreeModeTouchPointAdAwardManager");
    if (!cls) { return; }

    SEL sels[] = {
        sel_registerName("checkAwardAndLoadAdvertData:"),
        sel_registerName("checkPlayerShowAdAwardLoadAdvertData:"),
        sel_registerName("advertDataLoadFinished:"),
    };
    BOOL *flags[] = { &entryDone, &playerDone, &loadedDone };

    for (int j = 0; j < 3; j++) {
        if (*flags[j]) { continue; }
        Method m = class_getInstanceMethod(cls, sels[j]);
        if (!m) { continue; }
        method_setImplementation(m, (IMP)KGVipDirectReceive);
        *flags[j] = YES;
        KGVipAlert([NSString stringWithFormat:@"已挂载：%@ → %s", NSStringFromSelector(sels[j]),
                    class_getName(cls)]);
    }
}

%ctor {
    /* 层1：dylib 被加载（延迟 3 秒等 window 就绪） */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        KGVipAlert(@"已加载（调试版）");
    });

    /* 立刻挂一次 + 主队列下一 loop 再挂 + 定时重试（类懒加载时兜底） */
    KGVipInstallHooks();
    dispatch_async(dispatch_get_main_queue(), ^{ KGVipInstallHooks(); });

    static NSInteger ticks = 0;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC, 0);
    dispatch_source_set_event_handler(timer, ^{
        KGVipInstallHooks();
        if (++ticks >= 120) { dispatch_cancel(timer); }
    });
    dispatch_resume(timer);
}
