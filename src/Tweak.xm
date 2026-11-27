/* 酷狗音乐概念版 5.3.3 (com.kugou.kgyouth) 去广告 tweak
 * 策略：拦截广告"数据请求层"与"缓存层"，让广告数据为空 → 无广告可展示。
 * 只 hook 归属确定、签名精确的方法；不碰 UI 展示代码，避免闪退。
 *
 * 说明：
 *  - block 类型用 id 接收，置空广告数据时按需调用回调传空值，避免流程卡死。
 *  - 每个 hook 点可用宏 KG_DEBUG 打开日志。
 */

#define KG_DEBUG 0
#if KG_DEBUG
#define KGLog(...) NSLog(@"[KGNoAd] " __VA_ARGS__)
#else
#define KGLog(...) do {} while (0)
#endif

/* ============ 开屏广告 ============ */
/* KGSplashHttpDao: 开屏广告列表 / 实时开屏 / 资源下载 */
%hook KGSplashHttpDao

- (void)requestSplashListWithDownloadAds:(BOOL)downloadAds Error:(id)error {
    KGLog(@"block splash list request");
    // 不调用原实现：不拉取开屏广告
}

- (void)requestRealTimeSplashWithDownloadAds:(BOOL)downloadAds isStartSplash:(BOOL)isStart error:(id)error {
    KGLog(@"block realtime splash request");
}

- (void)requestDownloadSplashResourceWithError:(id)a andError:(id)b {
    KGLog(@"block splash resource download");
}

- (void)requestDownloadSplashAudioWithModel:(id)model andError:(id)error {
    KGLog(@"block splash audio download");
}

%end

/* 开屏缓存：让 DB 查不到可用开屏，防止走本地缓存展示 */
%hook SplashDBDao
- (id)getNotExpiredSplashs { KGLog(@"empty splash cache"); return nil; }
- (id)getAvailableSplashs { return nil; }
%end

/* ============ Banner / 信息流广告 ============ */
%hook ADBannerBLL

- (void)requestBlueTipAdInfo:(id)a successBlock:(id)success errorBlock:(id)error {
    KGLog(@"block blue tip ad");
    if (success) { ((void(^)(id))success)(nil); }
}
- (void)requestMineLinkAdInfos:(id)a successBlock:(id)success errorBlock:(id)error {
    KGLog(@"block mine link ad");
    if (success) { ((void(^)(id))success)(nil); }
}
- (void)requestTodaySongBannerAdInfo:(id)error {
    KGLog(@"block today song banner");
}
- (void)requestSearchBannerAdInfoWithLoadAds:(BOOL)load successBlock:(id)success errorBlock:(id)error {
    KGLog(@"block search banner");
    if (success) { ((void(^)(id))success)(nil); }
}
- (void)requestCommentBannerAdInfoWithLoadAds:(BOOL)load songInfo:(id)song successBlock:(id)success errorBlock:(id)error {
    KGLog(@"block comment banner");
    if (success) { ((void(^)(id))success)(nil); }
}
- (void)requestMyInfoPageAdInfoWithSuccessBlock:(id)success errorBlock:(id)error {
    KGLog(@"block mine page ad");
    if (success) { ((void(^)(id))success)(nil); }
}

%end

%hook YouthHomeChannelBannerBLL
- (void)requestBannerListWithSuccessBlock:(id)success failBlock:(id)fail {
    KGLog(@"block home channel banner");
    if (success) { ((void(^)(id))success)(nil); }
}
- (void)requestBannerListWithBusiParam:(id)param biz:(id)biz successBlock:(id)success failBlock:(id)fail {
    KGLog(@"block home channel banner v2");
    if (success) { ((void(^)(id))success)(nil); }
}
%end

%hook KGMusicHomeBannerBLL
- (void)getBannerInfoWithResultBlock:(id)result errorBlock:(id)error {
    KGLog(@"block music home banner");
    if (result) { ((void(^)(id))result)(nil); }
}
%end

/* ============ 激励广告入口（看广告得 VIP 等）============ */
/* 只拦截曝光/点击上报，不影响激励发放逻辑本身 */
%hook YouthAdvertBiManager
- (void)sendEnterExposureBIWithSourceId:(id)a { KGLog(@"no ad exposure BI"); }
- (void)sendEnterExposureBIWithSourceId:(id)a extraDict:(id)b { }
- (void)sendEnterClickBIWithSourceId:(id)a { }
- (void)sendEnterClickBIWithSourceId:(id)a type:(id)b { }
%end

/* ============ 屏蔽 Siri 词表注册 ============ */
/* 酷狗会向 Siri 注册自定义词表（歌手名/歌名），这里拦截掉 */
%hook KGMediaIntentStartTask
- (void)registerCustomVocabulary {
    KGLog(@"block Siri custom vocabulary registration");
    // 不调用原实现：不向 Siri 注册词表
}
%end

/* INVocabulary 是苹果系统类，setVocabularyStrings:ofType: 是词表写入口。
 * hook 置空，覆盖所有走系统 API 的词表注册路径（ofType 为 NSInteger 枚举）。 */
%hook INVocabulary
- (void)setVocabularyStrings:(id)strings ofType:(NSInteger)type {
    KGLog(@"block INVocabulary setVocabularyStrings");
    // 不写入任何词表
}
%end

/* ============ 播放器页广告 View（保险：直接隐藏） ============ */
/* 这些类归属确定的用 hook；找不到归属的靠上面请求层拦截兜底 */

%ctor {
    KGLog(@"KGNoAd loaded for com.kugou.kgyouth 5.3.3");
}
