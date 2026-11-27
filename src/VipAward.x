/* kgvipaward — 酷狗概念版「看广告领会员」直领（纯 runtime 挂载版）
 *
 * 原理：App 的看广告领会员走 YouthFreeModeTouchPointAdAwardManager：
 *   点击 → checkAwardAndLoadAdvertData: → loadAdvertData: (广告SDK)
 *   → advertDataLoadFinished: → 播视频 → receiveAwardAfterSeeVideo
 *   → receiveSeeVideoAward:complete: → 领奖接口(App自带签名/登录态)
 *
 * 本 tweak 在点击入口直接触发领奖，完全绕开广告加载与播放。
 * 领奖请求本身由 App 自己的网络层发出（登录态、签名都是原生的）。
 *
 * 实现方式与 kugou_noad_v9h 相同：纯 objc/runtime 挂载，
 * 不依赖 CydiaSubstrate（LiveContainer 环境没有这个库）。
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define KGLogAlways(...) NSLog(@"[KGVipAward] " __VA_ARGS__)

/* 替换后的入口实现：void(id, SEL, id block) */
static void KGVipDirectReceive(id self, SEL _cmd, id callback) {
    KGLogAlways(@"%@ -> direct receive (skip ad)", NSStringFromSelector(_cmd));
    Class cls = object_getClass(self);
    /* recordStartTime / recordEndTime 先补上（领奖链路可能校验起止时间） */
    Method m1 = class_getInstanceMethod(cls, sel_registerName("recordStartTime"));
    if (m1) { ((void (*)(id, SEL))method_getImplementation(m1))(self, method_getName(m1)); }
    Method m2 = class_getInstanceMethod(cls, sel_registerName("recordEndTime"));
    if (m2) { ((void (*)(id, SEL))method_getImplementation(m2))(self, method_getName(m2)); }
    Method m3 = class_getInstanceMethod(cls, sel_registerName("receiveAwardAfterSeeVideo"));
    if (m3) {
        ((void (*)(id, SEL))method_getImplementation(m3))(self, method_getName(m3));
        KGLogAlways(@"receiveAwardAfterSeeVideo called");
    } else {
        KGLogAlways(@"receiveAwardAfterSeeVideo NOT FOUND");
    }
    if (callback) { ((void (^)(void))callback)(); }
}

/* 类可能懒加载注册：定时重试直到挂上 */
static void KGVipInstallHooks(void) {
    static BOOL entryDone = NO;
    static BOOL loadedDone = NO;
    static const char *targets[] = {
        "YouthFreeModeTouchPointAdAwardManager",
        "YouthFreeModePenetrateManager",   /* 备选类：另一个免费领会员管理器 */
        NULL
    };
    SEL sels[] = {
        sel_registerName("checkAwardAndLoadAdvertData:"),
        sel_registerName("advertDataLoadFinished:"),
    };

    for (int i = 0; targets[i]; i++) {
        Class cls = objc_getClass(targets[i]);
        if (!cls) { continue; }
        for (int j = 0; j < 2; j++) {
            Method m = class_getInstanceMethod(cls, sels[j]);
            if (!m) { continue; }
            BOOL done = (j == 0) ? entryDone : loadedDone;
            if (done) { continue; }
            method_setImplementation(m, (IMP)KGVipDirectReceive);
            if (j == 0) { entryDone = YES; } else { loadedDone = YES; }
            KGLogAlways(@"hooked %s#%s", targets[i], sel_getName(sels[j]));
        }
    }
}

%ctor {
    KGLogAlways(@"loaded (pure runtime mode, no substrate)");

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
