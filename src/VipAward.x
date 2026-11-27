// kgvipaward v5 — 自动领会员（直调服务端接口，复刻 DL Music）
// 变更：删除入口直领 hook（不再弹"已触发直领"）；凭据只需 token+kugouid，
//       三路获取：hook 登录写入点 / 轮询 KGSVUserInfoManager / NSUserDefaults 兜底
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CommonCrypto/CommonDigest.h>

#define KG_VER   @"v5"
#define KG_SALT  @"LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
#define KG_CREDS_KEY @"kg_vipaward_creds"
#define KG_MID   @"158116268513255000000000000000"   // DL Music calculateMid 风格的固定 30 位十进制
#define KG_APPID @"3116"
#define KG_CLIENTVER @"11440"
#define KG_UA    @"Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi"
#define KG_RF    @"B9EDA08A64250DEFFBCADDEE00F8F25F"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static NSMutableDictionary *KGCreds = nil;
static BOOL KGCredsLoaded = NO;
static BOOL KGDoneToday = NO;
static IMP KGOrigLoginSetter = NULL;
static BOOL KGHooksInstalled = NO;

// ---------- 工具 ----------
static NSString *KGMD5(NSString *in) {
    unsigned char d[16];
    CC_MD5(in.UTF8String, (CC_LONG)strlen(in.UTF8String), d);
    NSMutableString *o = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) { [o appendFormat:@"%02x", d[i]]; }
    return o;
}

static NSString *KGSign(NSDictionary *params) {
    NSMutableString *s = [NSMutableString string];
    for (NSString *k in [params.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [s appendFormat:@"%@=%@", k, params[k]];
    }
    return KGMD5([NSString stringWithFormat:@"%@%@%@", KG_SALT, s, KG_SALT]);
}

static NSString *KGStr(id v) {
    if (!v || v == (id)NSNull.null) { return @""; }
    if ([v isKindOfClass:NSString.class]) { return v; }
    return [NSString stringWithFormat:@"%@", v];
}

static void KGSaveCreds(NSString *token, NSString *userid) {
    if (token.length == 0 || userid.length == 0) { return; }
    @synchronized (KGCreds) {
        KGCreds[@"token"] = token;
        KGCreds[@"userid"] = userid;
        KGCredsLoaded = YES;
        [[NSUserDefaults standardUserDefaults] setObject:[KGCreds copy] forKey:KG_CREDS_KEY];
    }
}

static void KGLoadCreds(void) {
    @synchronized (KGCreds) {
        if (KGCredsLoaded) { return; }
        NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:KG_CREDS_KEY];
        if (d[@"token"].length > 0 && d[@"userid"].length > 0) {
            [KGCreds addEntriesFromDictionary:d];
            KGCredsLoaded = YES;
        }
    }
}

// ---------- 弹窗 ----------
static void KGVipAlert(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = nil;
        for (__kindof UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (sc.activationState != UISceneActivationStateForegroundActive) { continue; }
            for (UIWindow *w in [sc windows reverseObjectEnumerator].allObjects) {
                if (!w.rootViewController) { continue; }
                root = w.rootViewController;
                break;
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

// ---------- 凭据采集 ----------
// 主动读登录管理器：KGSVUserInfoManager.shareInstance 的 token / kugouId / isLogin
static void KGReadLoginManager(void) {
    Class c = objc_getClass("KGSVUserInfoManager");
    if (!c) { return; }
    id inst = ((id(*)(id, SEL))objc_msgSend)((id)c, sel_registerName("shareInstance"));
    if (!inst) { return; }
    NSString *tok = KGStr(((id(*)(id, SEL))objc_msgSend)(inst, sel_registerName("token")));
    NSString *kid = KGStr(((id(*)(id, SEL))objc_msgSend)(inst, sel_registerName("kugouId")));
    if (tok.length > 0 && kid.length > 0) { KGSaveCreds(tok, kid); }
}

// NSUserDefaults 兜底扫描
static BOOL KGScanUserDefaults(void) {
    NSDictionary *all = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    NSString *tok = nil, *kid = nil;
    for (NSString *k in all) {
        NSString *lk = k.lowercaseString;
        id v = all[k];
        if (!tok && ([lk isEqualToString:@"token"] || [lk containsString:@"usertoken"] ||
                     ([lk containsString:@"token"] && k.length < 20))) {
            NSString *s = KGStr(v);
            if (s.length >= 16 && [s rangeOfString:@" "].location == NSNotFound) { tok = s; }
        }
        if (!kid && ([lk isEqualToString:@"kugouid"] || [lk isEqualToString:@"userid"] ||
                     ([lk containsString:@"kugouid"] && k.length < 20))) {
            NSString *s = KGStr(v);
            if (s.length > 0 && [s rangeOfString:@" "].location == NSNotFound) { kid = s; }
        }
        if (tok && kid) { break; }
    }
    if (tok && kid) { KGSaveCreds(tok, kid); return YES; }
    return NO;
}

// ---------- 自动领 ----------
static NSString *KGTodayString(void) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyy-MM-dd";
    return [f stringFromDate:[NSDate date]];
}

static NSString *KGEnc(NSString *v) {
    return [v stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
}

static void KGPost(NSString *path, NSMutableDictionary *params,
                   void (^done)(NSDictionary *json, NSError *err)) {
    params[@"dfid"] = @"-";
    params[@"uuid"] = @"-";
    params[@"mid"] = KG_MID;
    params[@"appid"] = KG_APPID;
    params[@"clientver"] = KG_CLIENTVER;
    NSString *ct = [NSString stringWithFormat:@"%d", (int)[NSDate date].timeIntervalSince1970];
    params[@"clienttime"] = ct;
    params[@"signature"] = KGSign(params);

    NSMutableArray *qs = [NSMutableArray array];
    for (NSString *k in params) {
        [qs addObject:[NSString stringWithFormat:@"%@=%@", k, KGEnc([NSString stringWithFormat:@"%@", params[k]])]];
    }
    NSString *url = [NSString stringWithFormat:@"https://gateway.kugou.com%@?%@", path, [qs componentsJoinedByString:@"&"]];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"POST";
    [req setValue:KG_UA forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"-" forHTTPHeaderField:@"dfid"];
    [req setValue:KG_MID forHTTPHeaderField:@"mid"];
    [req setValue:ct forHTTPHeaderField:@"clienttime"];
    [req setValue:@"1" forHTTPHeaderField:@"kg-rc"];
    [req setValue:@"5d816a0" forHTTPHeaderField:@"kg-thash"];
    [req setValue:@"1" forHTTPHeaderField:@"kg-rec"];
    [req setValue:KG_RF forHTTPHeaderField:@"kg-rf"];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 15;

    NSURLSession *s = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration];
    NSURLSessionDataTask *t = [s dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (e || !d) { done(nil, e); return; }
        id json = nil;
        @try { json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil]; } @catch (__unused NSException *ex) {}
        done([json isKindOfClass:NSDictionary.class] ? json : nil, nil);
    }];
    [t resume];
}

static void KGDoClaim(void);
static void KGDoUpgrade(void);

static void KGDoClaim(void) {
    if (KGDoneToday) { return; }
    NSString *token = nil, *userid = nil;
    @synchronized (KGCreds) { token = KGCreds[@"token"]; userid = KGCreds[@"userid"]; }
    if (token.length == 0 || userid.length == 0) { return; }

    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    p[@"source_id"] = @"90139";
    p[@"receive_day"] = KGTodayString();
    p[@"token"] = token;
    p[@"userid"] = userid;
    KGPost(@"/youth/v1/recharge/receive_vip_listen_song", p, ^(NSDictionary *json, NSError *err) {
        NSString *msg;
        if (err) { msg = [NSString stringWithFormat:@"签到网络错误: %@", err.localizedDescription]; }
        else {
            NSInteger code = -999;
            if ([json[@"status"] respondsToSelector:@selector(intValue)]) { code = [json[@"status"] intValue]; }
            NSString *em = KGStr(json[@"error_code"]);
            if (code == 0) { msg = @"签到成功"; }
            else if ([em isEqualToString:@"131001"]) { msg = @"今天已签到"; }
            else { msg = [NSString stringWithFormat:@"签到失败 code=%@ status=%@ msg=%@", em, KGStr(json[@"status"]), KGStr(json[@"error_msg"])]; }
        }
        KGVipAlert([NSString stringWithFormat:@"自动领(%@)：%@", KG_VER, msg]);
        if ([msg hasPrefix:@"签到成功"] || [msg isEqualToString:@"今天已签到"]) { KGDoUpgrade(); }
    });
}

static void KGDoUpgrade(void) {
    NSString *userid = nil, *token = nil;
    @synchronized (KGCreds) { userid = KGCreds[@"userid"]; token = KGCreds[@"token"]; }
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    p[@"kugouid"] = userid;
    p[@"ad_type"] = @"1";
    if (token.length > 0) { p[@"token"] = token; p[@"userid"] = userid; }
    KGPost(@"/youth/v1/listen_song/upgrade_vip_reward", p, ^(NSDictionary *json, NSError *err) {
        NSString *msg;
        if (err) { msg = [NSString stringWithFormat:@"升级网络错误: %@", err.localizedDescription]; }
        else {
            NSInteger code = -999;
            if ([json[@"status"] respondsToSelector:@selector(intValue)]) { code = [json[@"status"] intValue]; }
            if (code == 0) { msg = @"升级成功，已领概念版 VIP 1 天"; KGDoneToday = YES; }
            else { msg = [NSString stringWithFormat:@"升级失败 code=%@ status=%@ msg=%@", KGStr(json[@"error_code"]), KGStr(json[@"status"]), KGStr(json[@"error_msg"])]; }
        }
        KGVipAlert([NSString stringWithFormat:@"自动领(%@)：%@", KG_VER, msg]);
    });
}

// 每次尝试：读登录管理器 → UserDefaults 兜底 → 有凭据就领
static void KGAutoClaimTick(BOOL verbose) {
    if (KGDoneToday) { return; }
    KGLoadCreds();
    KGReadLoginManager();
    @synchronized (KGCreds) {
        if (KGCreds[@"token"].length == 0 || KGCreds[@"userid"].length == 0) {
            KGScanUserDefaults();
        }
    }
    NSString *token = nil, *userid = nil;
    @synchronized (KGCreds) { token = KGCreds[@"token"]; userid = KGCreds[@"userid"]; }
    if (token.length > 0 && userid.length > 0) {
        KGDoClaim();
    } else if (verbose) {
        // 诊断：报告具体缺什么
        Class c = objc_getClass("KGSVUserInfoManager");
        BOOL hasInst = NO, login = NO;
        NSString *tokLen = @"-", kid = @"-";
        if (c) {
            id inst = ((id(*)(id, SEL))objc_msgSend)((id)c, sel_registerName("shareInstance"));
            if (inst) {
                hasInst = YES;
                login = ((BOOL(*)(id, SEL))objc_msgSend)(inst, sel_registerName("isLogin"));
                tokLen = [NSString stringWithFormat:@"%lu", (unsigned long)KGStr(((id(*)(id, SEL))objc_msgSend)(inst, sel_registerName("token"))).length];
                kid = KGStr(((id(*)(id, SEL))objc_msgSend)(inst, sel_registerName("kugouId")));
                if (kid.length == 0) { kid = @"空"; }
            }
        }
        NSString *scan = KGScanUserDefaults() ? @"有" : @"无";
        KGVipAlert([NSString stringWithFormat:@"%@诊断: 缺[token,userid]\n管理器类:%@ 实例:%@ isLogin:%@\ntoken长度:%@ kugouId:%@\nUserDefaults兜底:%@",
                    KG_VER, c ? @"有" : @"无", hasInst ? @"有" : @"无", login ? @"Y" : @"N", tokLen, kid, scan]);
    }
}

// ---------- 挂载 ----------
static void KGInstallHooks(void) {
    if (KGHooksInstalled) { return; }
    Class c = objc_getClass("KGSVUserInfoManager");
    if (!c) { return; }
    SEL sel = sel_registerName("setLoginInfoWithKugouID:token:nikeName:");
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { return; }
    IMP newImp = imp_implementationWithBlock(^(id self, id kugouid, id token, id nick) {
        if (KGOrigLoginSetter) {
            ((void(*)(id, SEL, id, id, id))KGOrigLoginSetter)(self, sel, kugouid, token, nick);
        }
        KGSaveCreds(KGStr(token), KGStr(kugouid));
    });
    KGOrigLoginSetter = method_setImplementation(m, newImp);
    KGHooksInstalled = YES;
}

static void KGBootstrap(void) {
    KGCreds = [NSMutableDictionary dictionary];
    KGInstallHooks();
    KGDoneToday = NO;

    // 启动确认（带版本号）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        KGVipAlert([NSString stringWithFormat:@"已加载(%@)", KG_VER]);
    });

    // 12 秒时检查凭据：齐了提示并 5 秒后开领
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        static BOOL announced = NO;
        KGLoadCreds();
        KGReadLoginManager();
        NSString *token = nil, *userid = nil;
        @synchronized (KGCreds) { token = KGCreds[@"token"]; userid = KGCreds[@"userid"]; }
        if (token.length > 0 && userid.length > 0 && !announced) {
            announced = YES;
            KGVipAlert([NSString stringWithFormat:@"凭据已采集(%@)，5 秒后自动领取", KG_VER]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ KGDoClaim(); });
        }
    });

    // 定时尝试：25/45(带诊断)/90/180/300 秒
    NSArray *delays = @[@25, @45, @90, @180, @300];
    for (NSNumber *d in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ KGAutoClaimTick(d.integerValue == 45); });
    }
}

__attribute__((constructor)) static void KGEntry(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ KGBootstrap(); });
}

#pragma clang diagnostic pop
