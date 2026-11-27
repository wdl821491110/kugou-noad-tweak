/* kgvipaward v3 自动领版 — 酷狗概念版打开自动领会员
 *
 * A. 凭据采集（v3 改为主攻 App 请求层）：
 *   - swizzle KGNetworkTools urlPublicParameterDictionary: （App 所有请求的公共参数
 *     字典：dfid/mid/token/userid 全在里面，swizzle 类方法对所有实例生效）
 *   - swizzle KGNetworkTools signFillUrlCustomParameterDictionary:bodyString:isCdnRequest:signature:
 *     （补抓单请求自定义参数）
 *   - NSURLSession dataTaskWithRequest:completionHandler: 兜底（v2 遗留）
 *   凭据齐了（token+userid）弹一次「凭据已采集」，随后自动领取。
 * B. 自动领取（复刻 DL Music 验证过的服务端接口）：
 *   1) 签到 POST /youth/v1/recharge/receive_vip_listen_song
 *      (source_id=90139, receive_day=今天) → 领 1 天畅听 VIP
 *   2) POST /youth/v1/listen_song/upgrade_vip_reward (kugouid, ad_type=1)
 *      → 升级 1 天概念版 VIP
 *   签名：MD5(盐 + sort(k=v) + 空 + 盐)，概念版盐 LnT6xp...，appid=3116 clientver=11440
 *   错误码：131001=今天已签（正常），20028=风控
 * C. 入口直领 hook 保留（点界面领奖入口跳过广告直接领）。
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>

#define KG_SALT @"LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
#define KG_CREDS_KEY @"kg_vipaward_creds"
#define KG_VER @"v3"

static NSMutableDictionary *KGCreds = nil;
static BOOL KGCredsLoaded = NO;
static BOOL KGClaimDone = NO;
static BOOL KGReadyAlertShown = NO;
static IMP KGOrigDataTask = NULL;
static IMP KGOrigPublicDict = NULL;
static IMP KGOrigSignFill = NULL;

static void KGAutoClaim(void);   /* 前置声明：采集层会触发自动领 */

/* ================= 弹窗 ================= */
static void KGVipAlert(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = nil;
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

/* ================= MD5 / 签名 ================= */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static NSString *KGMD5(NSString *input) {
    unsigned char digest[16];
    const char *bytes = input.UTF8String;
    CC_MD5(bytes, (CC_LONG)strlen(bytes), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) { [hex appendFormat:@"%02x", digest[i]]; }
    return hex;
}
#pragma clang diagnostic pop

static NSString *KGSign(NSDictionary *params) {
    NSArray *keys = [[params allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableString *s = [NSMutableString string];
    for (NSString *k in keys) { [s appendFormat:@"%@=%@", k, params[k]]; }
    return KGMD5([NSString stringWithFormat:@"%@%@%@", KG_SALT, s, KG_SALT]);
}

/* ================= 凭据存储 ================= */
static void KGLoadCreds(void) {
    if (KGCredsLoaded) { return; }
    KGCredsLoaded = YES;
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:KG_CREDS_KEY];
    KGCreds = saved ? [NSMutableDictionary dictionaryWithDictionary:saved] : [NSMutableDictionary dictionary];
}

static void KGSaveCreds(void) {
    @synchronized (KGCreds) {
        [[NSUserDefaults standardUserDefaults] setObject:[NSDictionary dictionaryWithDictionary:KGCreds]
                                                  forKey:KG_CREDS_KEY];
    }
}

static BOOL KGCredsReady(void) {
    @synchronized (KGCreds) {
        NSString *tok = KGCreds[@"token"], *uid = KGCreds[@"userid"];
        return tok.length > 0 && uid.length > 0;
    }
}

static void KGCaptureKV(NSString *k, NSString *v) {
    if (k.length == 0 || v.length == 0 || ![v isKindOfClass:[NSString class]]) { return; }
    BOOL hit = NO;
    @synchronized (KGCreds) {
        if ([k isEqualToString:@"token"]) { KGCreds[@"token"] = v; hit = YES; }
        else if ([k isEqualToString:@"userid"] || [k isEqualToString:@"kugouid"]) {
            if (![v isEqualToString:@"0"]) { KGCreds[@"userid"] = v; hit = YES; }
        }
        else if ([k isEqualToString:@"dfid"]) { KGCreds[@"dfid"] = v; hit = YES; }
        else if ([k isEqualToString:@"mid"]) { KGCreds[@"mid"] = v; hit = YES; }
    }
    if (hit) { KGSaveCreds(); }
}

static void KGCaptureDict(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) { return; }
    for (NSString *k in dict) { KGCaptureKV(k, [NSString stringWithFormat:@"%@", dict[k]]); }
    if (!KGReadyAlertShown && KGCredsReady()) {
        KGReadyAlertShown = YES;
        KGVipAlert(@"凭据已采集，稍后自动领取");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ KGAutoClaim(); });
    }
}

static void KGCaptureURL(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    if (!host || ![host containsString:@"kugou"]) { return; }
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *it in c.queryItems) { KGCaptureKV(it.name, it.value); }
}

/* ================= swizzle 1：KGNetworkTools 公共参数字典（主通道） ================= */
static id KGPublicDictImp(id self, SEL _cmd, BOOL flag) {
    id dict = ((id (*)(id, SEL, BOOL))KGOrigPublicDict)(self, _cmd, flag);
    KGCaptureDict(dict);
    return dict;
}

/* ================= swizzle 2：signFillUrl（补抓自定义参数） ================= */
static id KGSignFillImp(id self, SEL _cmd, id paramDict, id bodyString, BOOL isCdn, id *signature) {
    KGCaptureDict(paramDict);
    return ((id (*)(id, SEL, id, id, BOOL, id *))KGOrigSignFill)(self, _cmd, paramDict, bodyString, isCdn, signature);
}

/* ================= swizzle 3：NSURLSession 兜底 ================= */
static id KGDataTaskImp(id self, SEL _cmd, NSURLRequest *request, id handler) {
    KGCaptureURL(request.URL);
    NSDictionary *headers = request.allHTTPHeaderFields;
    if (headers) {
        for (NSString *k in headers) { KGCaptureKV(k.lowercaseString, headers[k]); }
    }
    if (KGOrigDataTask) {
        return ((id (*)(id, SEL, NSURLRequest *, id))KGOrigDataTask)(self, _cmd, request, handler);
    }
    return nil;
}

static void KGVipInstallCapture(void) {
    /* KGNetworkTools：App 网络层主通道 */
    Class kg = objc_getClass("KGNetworkTools");
    if (kg) {
        if (!KGOrigPublicDict) {
            Method m = class_getInstanceMethod(kg, sel_registerName("urlPublicParameterDictionary:"));
            if (m) {
                KGOrigPublicDict = method_getImplementation(m);
                method_setImplementation(m, (IMP)KGPublicDictImp);
            }
        }
        if (!KGOrigSignFill) {
            Method m2 = class_getInstanceMethod(kg, sel_registerName("signFillUrlCustomParameterDictionary:bodyString:isCdnRequest:signature:"));
            if (m2) {
                KGOrigSignFill = method_getImplementation(m2);
                method_setImplementation(m2, (IMP)KGSignFillImp);
            }
        }
    }
    /* NSURLSession 兜底 */
    if (!KGOrigDataTask) {
        Class cls = [NSURLSession class];
        SEL sel = @selector(dataTaskWithRequest:completionHandler:);
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            KGOrigDataTask = method_getImplementation(m);
            method_setImplementation(m, (IMP)KGDataTaskImp);
        }
    }
}

/* ================= 自动领取 ================= */
static NSString *KGLocalDay(void) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyy-MM-dd";
    f.timeZone = [NSTimeZone localTimeZone];
    return [f stringFromDate:[NSDate date]];
}

static NSString *KGNumText(id v) {
    if ([v isKindOfClass:[NSNumber class]]) { return [v stringValue]; }
    if ([v isKindOfClass:[NSString class]]) { return v; }
    return @"0";
}

static void KGPost(NSString *path, NSDictionary *params, void (^done)(NSDictionary *body)) {
    NSMutableDictionary *p = [NSMutableDictionary dictionaryWithDictionary:params];
    p[@"signature"] = KGSign(params);
    NSURLComponents *c = [[NSURLComponents alloc] initWithString:[@"https://gateway.kugou.com" stringByAppendingString:path]];
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *k in p) {
        [items addObject:[NSURLQueryItem queryItemWithName:k
                                                     value:[NSString stringWithFormat:@"%@", p[k]]]];
    }
    c.queryItems = items;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:c.URL];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 20.0;
    [req setValue:@"Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [req setValue:params[@"dfid"] ?: @"-" forHTTPHeaderField:@"dfid"];
    [req setValue:params[@"clienttime"] forHTTPHeaderField:@"clienttime"];
    [req setValue:params[@"mid"] ?: @"-" forHTTPHeaderField:@"mid"];
    [req setValue:@"1" forHTTPHeaderField:@"kg-rc"];
    [req setValue:@"5d816a0" forHTTPHeaderField:@"kg-thash"];
    [req setValue:@"1" forHTTPHeaderField:@"kg-rec"];
    [req setValue:@"B9EDA08A64250DEFFBCADDEE00F8F25F" forHTTPHeaderField:@"kg-rf"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data) {
            done(@{ @"status": @0, @"error_msg": err.localizedDescription ?: @"网络错误" });
            return;
        }
        id json = nil;
        @try { json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]; }
        @catch (NSException *e) { json = nil; }
        if (![json isKindOfClass:[NSDictionary class]]) { json = @{}; }
        done(json);
    }] resume];
}

static void KGDoUpgrade(void) {
    NSString *userid = nil, *dfid = @"-", *mid = @"-", *token = @"";
    @synchronized (KGCreds) {
        userid = KGCreds[@"userid"] ?: @"0";
        dfid = KGCreds[@"dfid"] ?: @"-";
        mid = KGCreds[@"mid"] ?: @"-";
        token = KGCreds[@"token"] ?: @"";
    }
    NSString *ct = [NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970]];
    NSDictionary *params = @{
        @"dfid": dfid, @"mid": mid, @"uuid": @"-",
        @"appid": @"3116", @"clientver": @"11440", @"clienttime": ct,
        @"token": token, @"userid": userid,
        @"kugouid": userid, @"ad_type": @"1",
    };
    KGPost(@"/youth/v1/listen_song/upgrade_vip_reward", params, ^(NSDictionary *body) {
        int st = [KGNumText(body[@"status"]) intValue];
        NSString *msg = body[@"error_msg"] ?: @"";
        if (st == 1) {
            KGVipAlert(@"自动领：升级成功，获得 1 天概念版 VIP");
        } else {
            KGVipAlert([NSString stringWithFormat:@"自动领：升级未成功（%@）%@",
                        KGNumText(body[@"error_code"]),
                        msg.length ? [@" " stringByAppendingString:msg] : @""]);
        }
    });
}

static void KGDoSignIn(void) {
    NSString *userid = nil, *dfid = @"-", *mid = @"-", *token = @"";
    @synchronized (KGCreds) {
        userid = KGCreds[@"userid"] ?: @"0";
        dfid = KGCreds[@"dfid"] ?: @"-";
        mid = KGCreds[@"mid"] ?: @"-";
        token = KGCreds[@"token"] ?: @"";
    }
    NSString *ct = [NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970]];
    NSDictionary *params = @{
        @"dfid": dfid, @"mid": mid, @"uuid": @"-",
        @"appid": @"3116", @"clientver": @"11440", @"clienttime": ct,
        @"token": token, @"userid": userid,
        @"source_id": @"90139", @"receive_day": KGLocalDay(),
    };
    KGPost(@"/youth/v1/recharge/receive_vip_listen_song", params, ^(NSDictionary *body) {
        int st = [KGNumText(body[@"status"]) intValue];
        int code = [KGNumText(body[@"error_code"]) intValue];
        NSString *msg = body[@"error_msg"] ?: @"";
        if (st == 1) {
            KGVipAlert(@"自动领：签到成功，获得 1 天畅听 VIP");
            KGDoUpgrade();
        } else if (code == 131001) {
            KGVipAlert(@"自动领：今天已签到，直接尝试升级");
            KGDoUpgrade();
        } else if (code == 20028) {
            KGVipAlert(@"自动领：账号被风控，今天领不了");
        } else {
            KGVipAlert([NSString stringWithFormat:@"自动领：签到未成功（%d）%@", code, msg]);
        }
    });
}

static void KGAutoClaim(void) {
    if (KGClaimDone) { return; }
    KGLoadCreds();
    if (!KGCredsReady()) { return; }
    KGClaimDone = YES;
    KGDoSignIn();
}

/* ================= 入口直领 hook（保留） ================= */
static void KGVipDirectReceive(id self, SEL _cmd, id callback) {
    KGVipAlert([NSString stringWithFormat:@"已触发直领：%@（跳过广告）", NSStringFromSelector(_cmd)]);
    Class cls = object_getClass(self);
    Method m1 = class_getInstanceMethod(cls, sel_registerName("recordStartTime"));
    if (m1) { ((void (*)(id, SEL))method_getImplementation(m1))(self, method_getName(m1)); }
    Method m2 = class_getInstanceMethod(cls, sel_registerName("recordEndTime"));
    if (m2) { ((void (*)(id, SEL))method_getImplementation(m2))(self, method_getName(m2)); }
    Method m3 = class_getInstanceMethod(cls, sel_registerName("receiveAwardAfterSeeVideo"));
    if (m3) { ((void (*)(id, SEL))method_getImplementation(m3))(self, method_getName(m3)); }
    if (callback) { ((void (^)(void))callback)(); }
    KGAutoClaim();
}

static void KGVipInstallEntryHooks(void) {
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
    }
}

/* ================= 入口 ================= */
%ctor {
    KGLoadCreds();
    KGVipInstallCapture();
    KGVipInstallEntryHooks();
    dispatch_async(dispatch_get_main_queue(), ^{
        KGVipInstallCapture();
        KGVipInstallEntryHooks();
    });

    /* 启动确认弹窗（调试版，带版本号防装错文件） */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        KGVipAlert([NSString stringWithFormat:@"已加载（%@）", KG_VER]);
    });

    /* 40 秒诊断：凭据还没到位就明说 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!KGClaimDone && !KGCredsReady()) {
            KGVipAlert([NSString stringWithFormat:@"%@诊断：40秒了凭据还没采到（KGNetworkTools 未命中）", KG_VER]);
        }
    });

    /* 自动领：多次尝试兜底（凭据采集到位才执行） */
    NSArray *delays = @[@25.0, @45.0, @90.0, @180.0, @300.0];
    for (NSNumber *d in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ KGAutoClaim(); });
    }
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ KGAutoClaim(); });
    }];

    /* 类懒加载重试 */
    static NSInteger ticks = 0;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC, 0);
    dispatch_source_set_event_handler(timer, ^{
        KGVipInstallEntryHooks();
        if (++ticks >= 120) { dispatch_cancel(timer); }
    });
    dispatch_resume(timer);
}
