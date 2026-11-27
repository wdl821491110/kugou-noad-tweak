// kgvipaward v9 — 自动领会员（直调服务端接口，复刻 DL Music）
// v9 变更：
//  1) hook 分点独立安装 + 2 秒重试（dylib 注入时机早，目标类可能在 framework 里尚未加载）
//  2) 运行时自动探测：遍历已加载类，找「有 token getter + 有单例入口」的类，直接读 token/isLogin/uid
//  3) 完整诊断写入 Documents/Tweaks/kugou/diag.txt
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CommonCrypto/CommonDigest.h>

#define KG_VER   @"v9"
#define KG_SALT  @"LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
#define KG_CREDS_KEY @"kg_vipaward_creds"
#define KG_MID   @"158116268513255000000000000000"
#define KG_APPID @"3116"
#define KG_CLIENTVER @"11440"
#define KG_UA    @"Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi"
#define KG_RF    @"B9EDA08A64250DEFFBCADDEE00F8F25F"
#define KG_DIAG_PATH(dir) [dir stringByAppendingPathComponent:@"Documents/Tweaks/kugou/diag.txt"]

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static NSMutableDictionary *KGCreds = nil;
static BOOL KGCredsLoaded = NO;
static BOOL KGDoneToday = NO;
static IMP KGOrigLoginSetter = NULL;
static IMP KGOrigEnvInit = NULL;
static IMP KGOrigEnvTok = NULL;
static IMP KGOrigAF = NULL;
static IMP KGOrigCommon2[2] = {NULL, NULL};
static IMP KGOrigRes = NULL;
static id KGLastEnv = nil;
// 挂载状态
static BOOL H_Login = NO, H_EnvInit = NO, H_EnvTok = NO, H_AF = NO, H_Common = NO, H_Res = NO;
static NSString *KGProbeReport = @"";

// ---------- 工具 ----------
static NSString *KGMD5(NSString *in) {
    unsigned char d[16];
    CC_MD5(in.UTF8String, (CC_LONG)strlen(in.UTF8String), d);
    NSMutableString *o = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) { [o appendFormat:@"%02x", d[i]]; }
    return o;
}

static NSString *KGStr(id v) {
    if (!v || v == (id)NSNull.null) { return @""; }
    if ([v isKindOfClass:NSString.class]) { return v; }
    if ([v respondsToSelector:@selector(stringValue)]) { return [v stringValue]; }
    return [NSString stringWithFormat:@"%@", v];
}

static NSString *KGSign(NSDictionary *params) {
    NSMutableString *s = [NSMutableString string];
    for (NSString *k in [params.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [s appendFormat:@"%@=%@", k, params[k]];
    }
    return KGMD5([NSString stringWithFormat:@"%@%@%@", KG_SALT, s, KG_SALT]);
}

static void KGSaveCreds(NSString *token, NSString *userid) {
    if (token.length == 0 || userid.length == 0) { return; }
    @synchronized (KGCreds) {
        if (KGCreds[@"token"]) { return; }
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
        NSString *t = KGStr(d[@"token"]);
        NSString *u = KGStr(d[@"userid"]);
        if (t.length > 0 && u.length > 0) {
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
            for (UIWindow *w in sc.windows) {
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

// ---------- 诊断文件 ----------
static void KGWriteDiag(NSString *extra) {
    NSMutableString *s = [NSMutableString string];
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"MM-dd HH:mm:ss";
    [s appendFormat:@"=== %@ %@ ===\n", KG_VER, [f stringFromDate:[NSDate date]]];
    [s appendFormat:@"hooks: login=%@ envInit=%@ envTok=%@ af=%@ common=%@ res=%@\n",
        H_Login?@"OK":@"MISS", H_EnvInit?@"OK":@"MISS", H_EnvTok?@"OK":@"MISS",
        H_AF?@"OK":@"MISS", H_Common?@"OK":@"MISS", H_Res?@"OK":@"MISS"];
    NSString *token = nil, *uid = nil;
    @synchronized (KGCreds) { token = KGCreds[@"token"]; uid = KGCreds[@"userid"]; }
    [s appendFormat:@"creds: tokLen=%lu uid=%@\n", (unsigned long)(token ? token.length : 0), uid.length ? uid : @"-"];
    // 类存在性
    NSArray *names = @[@"KGSVUserInfoManager", @"KGEnvironment", @"AFHTTPSessionManager",
                       @"KGCommonParamDao", @"KGHistoryUserTokenManager", @"KTVUserManager",
                       @"ADCUserProvider", @"KGNetworkTools", @"__NSCFURLSession"];
    for (NSString *n in names) {
        [s appendFormat:@"class %@: %@\n", n, objc_getClass(n.name.UTF8String) ? @"Y" : @"N"];
    }
    // UserDefaults 键
    NSDictionary *ud = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    [s appendFormat:@"UD keys(%lu): ", (unsigned long)ud.count];
    NSMutableArray *all = [NSMutableArray array];
    for (NSString *k in ud) { [all addObject:k]; }
    [s appendString:[[all sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]];
    [s appendString:@"\n"];
    [s appendFormat:@"probe:\n%@", KGProbeReport.length ? KGProbeReport : @"(未运行)\n"];
    if (extra) { [s appendFormat:@"extra: %@\n", extra]; }
    NSString *p = KG_DIAG_PATH(NSHomeDirectory());
    [[NSFileManager defaultManager] createDirectoryAtPath:[p stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [s writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// ---------- 凭据采集（主动读） ----------
static void KGReadCredsFile(void) {
    NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Tweaks/kugou/kgcreds.json"];
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d) { return; }
    id j = nil;
    @try { j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil]; } @catch (__unused NSException *ex) {}
    if (![j isKindOfClass:NSDictionary.class]) { return; }
    NSString *t = KGStr(j[@"token"]);
    NSString *u = KGStr(j[@"userid"]);
    if (t.length > 0 && u.length > 0) { KGSaveCreds(t, u); }
}

static void KGReadHistoryToken(void) {
    Class c = objc_getClass("KGHistoryUserTokenManager");
    if (!c) { return; }
    @try {
        id inst = ((id(*)(id, SEL))objc_msgSend)((id)c, sel_registerName("sharedInstance"));
        if (!inst) { return; }
        NSString *uid = KGStr(((id(*)(id, SEL))objc_msgSend)(inst, sel_registerName("getLatestLoginUserId")));
        if (uid.length == 0) { return; }
        id model = ((id(*)(id, SEL, id))objc_msgSend)(inst, sel_registerName("getHistoryUserTokenModel:"), uid);
        if (!model) { return; }
        NSString *tok = KGStr(((id(*)(id, SEL))objc_msgSend)(model, sel_registerName("token")));
        if (tok.length > 0) { KGSaveCreds(tok, uid); }
    } @catch (__unused NSException *ex) {}
}

static void KGReadLoginManager(void) {
    Class c = objc_getClass("KGSVUserInfoManager");
    if (!c) { return; }
    @try {
        id inst = ((id(*)(id, SEL))objc_msgSend)((id)c, sel_registerName("shareInstance"));
        if (!inst) { return; }
        NSString *tok = KGStr(((id(*)(id, SEL))objc_msgSend)(inst, sel_registerName("token")));
        NSString *kid = KGStr(((id(*)(id, SEL))objc_msgSend)(inst, sel_registerName("kugouId")));
        if (tok.length > 0 && kid.length > 0) { KGSaveCreds(tok, kid); }
    } @catch (__unused NSException *ex) {}
}

// 运行时自动探测：找「有 token getter + 单例入口」的类，直接读 token/isLogin/uid
static void KGProbeAllSingletons(void) {
    int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) { return; }
    NSMutableString *rep = [NSMutableString string];
    NSArray *singles = @[@"shareInstance", @"sharedInstance", @"defaultInstance",
                         @"sharedManager", @"shared", @"sharedUserInfo", @"currentUser"];
    NSArray *uidSels = @[@"kugouId", @"userid", @"userId", @"getUserId",
                         @"getLatestLoginUserId", @"kugouid", @"uid"];
    for (int i = 0; i < count; i++) {
        Class c = classes[i];
        const char *cn = class_getName(c);
        if (!cn) { continue; }
        NSString *name = [NSString stringWithUTF8String:cn];
        if (!name || name.length == 0) { continue; }
        if (!([name containsString:@"User"] || [name containsString:@"Account"] ||
              [name containsString:@"Login"] || [name containsString:@"Token"] ||
              [name containsString:@"Session"] || [name containsString:@"Vip"])) { continue; }
        if (!class_getInstanceMethod(c, sel_registerName("token"))) { continue; }
        id inst = nil;
        for (NSString *sn in singles) {
            if (!class_getClassMethod(c, NSSelectorFromString(sn))) { continue; }
            @try { inst = ((id(*)(id, SEL))objc_msgSend)((id)c, NSSelectorFromString(sn)); } @catch (__unused NSException *ex) { inst = nil; }
            if (inst) { break; }
        }
        if (!inst) { continue; }
        NSString *tok = @"";
        @try { tok = KGStr(((id(*)(id, SEL))objc_msgSend)(inst, sel_registerName("token"))); } @catch (__unused NSException *ex) {}
        BOOL login = NO;
        if (class_getInstanceMethod(c, sel_registerName("isLogin"))) {
            @try { login = ((BOOL(*)(id, SEL))objc_msgSend)(inst, sel_registerName("isLogin")); } @catch (__unused NSException *ex) {}
        }
        NSString *uid = @"";
        for (NSString *us in uidSels) {
            if (!class_getInstanceMethod(c, NSSelectorFromString(us))) { continue; }
            @try { uid = KGStr(((id(*)(id, SEL))objc_msgSend)(inst, NSSelectorFromString(us))); } @catch (__unused NSException *ex) { uid = @""; }
            if (uid.length) { break; }
        }
        [rep appendFormat:@"  %@ login=%d tokLen=%lu uid=%@\n", name, login,
            (unsigned long)tok.length, uid.length ? uid : @"-"];
        if (tok.length > 0 && uid.length > 0) { KGSaveCreds(tok, uid); }
    }
    free(classes);
    KGProbeReport = rep.length ? rep : @"(no candidate)\n";
}

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
            if (code == 1) { msg = @"签到成功"; }
            else if ([em isEqualToString:@"131001"]) { msg = @"今天已签到"; }
            else if ([em isEqualToString:@"20028"]) { msg = @"账号风控(20028)"; }
            else { msg = [NSString stringWithFormat:@"签到失败 code=%@ status=%@ msg=%@", em, KGStr(json[@"status"]), KGStr(json[@"error_msg"])]; }
        }
        KGVipAlert([NSString stringWithFormat:@"自动领(%@)：%@", KG_VER, msg]);
        KGWriteDiag(msg);
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
            NSString *em = KGStr(json[@"error_code"]);
            if (code == 1) { msg = @"升级成功，已领概念版 VIP 1 天"; KGDoneToday = YES; }
            else if ([em isEqualToString:@"131001"]) { msg = @"今天已签到"; KGDoneToday = YES; }
            else if ([em isEqualToString:@"20028"]) { msg = @"账号风控(20028)"; }
            else { msg = [NSString stringWithFormat:@"升级失败 code=%@ status=%@ msg=%@", em, KGStr(json[@"status"]), KGStr(json[@"error_msg"])]; }
        }
        KGVipAlert([NSString stringWithFormat:@"自动领(%@)：%@", KG_VER, msg]);
        KGWriteDiag(msg);
    });
}

static void KGAutoClaimTick(BOOL verbose) {
    if (KGDoneToday) { return; }
    KGLoadCreds();
    KGReadCredsFile();
    KGReadHistoryToken();
    KGReadLoginManager();
    if (KGLastEnv) {
        @try {
            NSString *t = KGStr(((id(*)(id, SEL))objc_msgSend)(KGLastEnv, sel_registerName("token")));
            NSString *u = KGStr(((id(*)(id, SEL))objc_msgSend)(KGLastEnv, sel_registerName("userID")));
            if (t.length > 0 && u.length > 0) { KGSaveCreds(t, u); }
        } @catch (__unused NSException *ex) {}
    }
    NSString *token = nil, *userid = nil;
    @synchronized (KGCreds) { token = KGCreds[@"token"]; userid = KGCreds[@"userid"]; }
    if (token.length == 0 || userid.length == 0) {
        KGProbeAllSingletons();
        KGScanUserDefaults();
        @synchronized (KGCreds) { token = KGCreds[@"token"]; userid = KGCreds[@"userid"]; }
    }
    if (token.length > 0 && userid.length > 0) {
        KGDoClaim();
    } else if (verbose) {
        KGWriteDiag(@"diag-tick");
        KGVipAlert([NSString stringWithFormat:
            @"%@诊断: 缺凭据\n挂载 登录:%@ 环境:%@ AF:%@ 参数:%@\n探测:%@\n详见 Documents/Tweaks/kugou/diag.txt",
            KG_VER,
            H_Login?@"OK":@"MISS", H_EnvInit?@"OK":@"MISS", H_AF?@"OK":@"MISS", H_Common?@"OK":@"MISS",
            KGProbeReport.length ? @"见文件" : @"无候选"]);
    }
}

// ---------- 挂载（分点独立 + 重试） ----------
static void KGInstallCommonHook(Class cc, NSString *selName, int slot) {
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cc, sel);
    if (!m) { return; }
    IMP ni = imp_implementationWithBlock(^(id self) {
        id d = nil;
        IMP orig = KGOrigCommon2[slot];
        if (orig) { d = ((id(*)(id, SEL))orig)(self, sel); }
        if ([d isKindOfClass:NSDictionary.class]) {
            NSString *t = KGStr(d[@"token"]);
            NSString *u = KGStr(d[@"userid"]);
            if (u.length == 0) { u = KGStr(d[@"kugouid"]); }
            if (t.length > 0 && u.length > 0) { KGSaveCreds(t, u); }
        }
        return d;
    });
    KGOrigCommon2[slot] = method_setImplementation(m, ni);
}

static void KGInstallHooksOnce(void) {
    // 1) KGSVUserInfoManager setLoginInfoWithKugouID:token:nikeName:
    if (!H_Login) {
        Class c = objc_getClass("KGSVUserInfoManager");
        SEL sel = sel_registerName("setLoginInfoWithKugouID:token:nikeName:");
        Method m = c ? class_getInstanceMethod(c, sel) : NULL;
        if (m) {
            IMP ni = imp_implementationWithBlock(^(id self, id kugouid, id token, id nick) {
                if (KGOrigLoginSetter) { ((void(*)(id, SEL, id, id, id))KGOrigLoginSetter)(self, sel, kugouid, token, nick); }
                KGSaveCreds(KGStr(token), KGStr(kugouid));
            });
            KGOrigLoginSetter = method_setImplementation(m, ni);
            H_Login = YES;
        }
    }
    // 2) KGEnvironment init / setToken:
    Class ec = objc_getClass("KGEnvironment");
    if (ec) {
        if (!H_EnvInit) {
            SEL isel = sel_registerName("initWithAppId:mId:userID:token:appVersion:channelId:vipType:musicType:isVip:pType:");
            Method im = class_getInstanceMethod(ec, isel);
            if (im) {
                IMP ni = imp_implementationWithBlock(^(id self, id appId, id mId, id uid, id tok, id ver, id ch,
                                                       unsigned long long vipType, unsigned long long musicType, BOOL isVip, long long pType) {
                    id r = nil;
                    if (KGOrigEnvInit) {
                        r = ((id(*)(id, SEL, id, id, id, id, id, id, unsigned long long, unsigned long long, BOOL, long long))KGOrigEnvInit)
                            (self, isel, appId, mId, uid, tok, ver, ch, vipType, musicType, isVip, pType);
                    }
                    KGLastEnv = self;
                    KGSaveCreds(KGStr(tok), KGStr(uid));
                    return r;
                });
                KGOrigEnvInit = method_setImplementation(im, ni);
                H_EnvInit = YES;
            }
        }
        if (!H_EnvTok) {
            SEL ts = sel_registerName("setToken:");
            Method tm = class_getInstanceMethod(ec, ts);
            if (tm) {
                IMP nt = imp_implementationWithBlock(^(id self, id tok) {
                    if (KGOrigEnvTok) { ((void(*)(id, SEL, id))KGOrigEnvTok)(self, ts, tok); }
                    KGLastEnv = self;
                    @try {
                        NSString *u = KGStr(((id(*)(id, SEL))objc_msgSend)(self, sel_registerName("userID")));
                        KGSaveCreds(KGStr(tok), u);
                    } @catch (__unused NSException *ex) {}
                });
                KGOrigEnvTok = method_setImplementation(tm, nt);
                H_EnvTok = YES;
            }
        }
    }
    // 3) AFHTTPSessionManager dataTaskWithHTTPMethod:...
    if (!H_AF) {
        Class ac = objc_getClass("AFHTTPSessionManager");
        SEL asel = sel_registerName("dataTaskWithHTTPMethod:URLString:parameters:headers:uploadProgress:downloadProgress:success:failure:");
        Method am = ac ? class_getInstanceMethod(ac, asel) : NULL;
        if (am) {
            IMP na = imp_implementationWithBlock(^(id self, id method, id urlStr, id params, id headers,
                                                   id up, id down, id success, id failure) {
                id r = nil;
                if (KGOrigAF) {
                    r = ((id(*)(id, SEL, id, id, id, id, id, id, id, id))KGOrigAF)
                        (self, asel, method, urlStr, params, headers, up, down, success, failure);
                }
                if ([params isKindOfClass:NSDictionary.class]) {
                    NSDictionary *p = params;
                    NSString *t = KGStr(p[@"token"]);
                    NSString *u = KGStr(p[@"userid"]);
                    if (u.length == 0) { u = KGStr(p[@"kugouid"]); }
                    if (t.length > 0 && u.length > 0) { KGSaveCreds(t, u); }
                }
                return r;
            });
            KGOrigAF = method_setImplementation(am, na);
            H_AF = YES;
        }
    }
    // 4) KGCommonParamDao generateCommonDict / generateNewCommonDict
    if (!H_Common) {
        Class cc = objc_getClass("KGCommonParamDao");
        if (cc) {
            KGInstallCommonHook(cc, @"generateCommonDict", 0);
            KGInstallCommonHook(cc, @"generateNewCommonDict", 1);
            H_Common = (KGOrigCommon2[0] != NULL || KGOrigCommon2[1] != NULL);
        }
    }
    // 5) NSURLSession 真实类（类簇私有子类）
    if (!H_Res) {
        Class rc = objc_getClass("__NSCFURLSession");
        if (!rc) { rc = objc_getClass("NSURLSession"); }
        SEL sel = sel_registerName("dataTaskWithRequest:completionHandler:");
        Method m = rc ? class_getInstanceMethod(rc, sel) : NULL;
        if (m) {
            IMP ni = imp_implementationWithBlock(^(id self, id req, id handler) {
                @try {
                    NSString *url = [[req URL] absoluteString];
                    if (url.length && [url containsString:@"token="] && [url containsString:@"userid="]) {
                        NSMutableDictionary *q = [NSMutableDictionary dictionary];
                        NSArray *parts = [[url componentsSeparatedByString:@"?"].lastObject componentsSeparatedByString:@"&"];
                        for (NSString *kv in parts) {
                            NSArray *pair = [kv componentsSeparatedByString:@"="];
                            if (pair.count == 2) { q[pair[0]] = pair[1]; }
                        }
                        NSString *t = KGStr(q[@"token"]);
                        NSString *u = KGStr(q[@"userid"]);
                        if (u.length == 0) { u = KGStr(q[@"kugouid"]); }
                        if (t.length > 0 && u.length > 0) { KGSaveCreds(t, u); }
                    }
                } @catch (__unused NSException *ex) {}
                id r = nil;
                if (KGOrigRes) { r = ((id(*)(id, SEL, id, id))KGOrigRes)(self, sel, req, handler); }
                return r;
            });
            KGOrigRes = method_setImplementation(m, ni);
            H_Res = (KGOrigRes != NULL);
        }
    }
}

static void KGScheduleHookRetry(int left) {
    KGInstallHooksOnce();
    if ((H_Login && H_EnvInit && H_AF) || left <= 0) { return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ KGScheduleHookRetry(left - 1); });
}

static void KGBootstrap(void) {
    KGCreds = [NSMutableDictionary dictionary];
    KGDoneToday = NO;
    KGInstallHooksOnce();
    KGScheduleHookRetry(120);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        KGVipAlert([NSString stringWithFormat:@"已加载(%@)", KG_VER]);
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        static BOOL announced = NO;
        KGLoadCreds();
        KGReadCredsFile();
        KGReadHistoryToken();
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
