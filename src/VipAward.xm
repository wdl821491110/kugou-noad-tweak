#import <UIKit/UIKit.h>

// ============================================================
// kgvipaward — 酷狗概念版「看广告领会员」直领
//
// 原理：App 的看广告领会员走 YouthFreeModeTouchPointAdAwardManager：
//   点击 → checkAwardAndLoadAdvertData: → loadAdvertData: (广告SDK)
//   → advertDataLoadFinished: → 播视频 → receiveAwardAfterSeeVideo
//   → receiveSeeVideoAward:complete: → 领奖接口(App自带签名/登录态)
//
// 本 tweak 在点击入口直接触发领奖，完全绕开广告加载与播放。
// 领奖请求本身由 App 自己的网络层发出（登录态、签名都是原生的）。
// ============================================================

@interface YouthFreeModeTouchPointAdAwardManager : NSObject
- (void)receiveAwardAfterSeeVideo;
- (void)recordStartTime;
- (void)recordEndTime;
@end

%hook YouthFreeModeTouchPointAdAwardManager

// 点击「看广告领会员」入口：跳过广告，直接领
- (void)checkAwardAndLoadAdvertData:(void (^)(void))callback {
    NSLog(@"[KGVipAward] entry click -> direct receive (skip ad)");
    [self recordStartTime];
    [self recordEndTime];
    [self receiveAwardAfterSeeVideo];
    if (callback) callback();
}

// 广告数据加载完成回调：不弹广告，直接领
- (void)advertDataLoadFinished:(void (^)(void))callback {
    NSLog(@"[KGVipAward] advert data loaded -> direct receive (skip ad)");
    [self recordStartTime];
    [self recordEndTime];
    [self receiveAwardAfterSeeVideo];
}

%end
