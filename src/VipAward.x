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
#import <Security/Security.h>

#define KG_VER   @"v15b"
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
static NSString *KGTokenTestReport = @"";
static NSString *KGAPITestReport = @"";
static NSMutableArray *KGReqLog = nil;   // App 自身请求 URL（脱敏）
// v12：从 App 自身签名/建请求链路观测到的真实参数（用来和 DL Music 那套对照）
static NSString *KGAppToken = nil, *KGAppUid = nil, *KGAppDfid = nil, *KGAppMid = nil;
static NSString *KGAppAppid = nil, *KGAppClientver = nil, *KGAppSalt = nil;
static NSString *KGNetObsReport = @"";
static BOOL H_SignA = NO, H_SignB = NO, H_DaoKey = NO, H_DaoInfo = NO;
static IMP KGOrigSignA = NULL, KGOrigSignB = NULL, KGOrigDaoKey = NULL, KGOrigDaoInfo = NULL;
// v14：最底层观测点。任何网络请求构造时都会走 -[NSURLRequest URL] / setHTTPBody:，
// 不依赖任何酷狗私有类，命中率最高。拿到带 token 的 URL 后立即入库并触发领取。
static IMP KGOrigReqURL = NULL, KGOrigSetBody = NULL;
static BOOL H_ReqURL = NO, H_SetBody = NO;
static BOOL KGObservedToken = NO;
// v15：记录 App 自己发出的 youth 请求原始 URL（含完整 signature），
// 用来反推 appid=3114 对应的 salt；我们自己的请求靠关联对象打标记排除。
static NSMutableArray *KGRawReqs = nil;
static char kKGOurReqKey;
// v13：钥匙串 / Cookie 里的真实凭据
static NSMutableArray *KGKeyCands = nil;
static NSMutableString *KGKeyReport = nil;
static NSMutableString *KGCookieReport = nil;

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

// ---------- 请求日志（脱敏，用于对比 App 自身真实请求） ----------
static NSString *KGMaskToken(NSString *s) {
    if (!s.length) { return @""; }
    if (s.length <= 10) { return @"***"; }
    return [NSString stringWithFormat:@"%@..%lu", [s substringToIndex:8], (unsigned long)s.length];
}

static void KGLogReq(NSString *url) {
    if (url.length == 0) { return; }
    NSMutableArray *parts = [NSMutableArray arrayWithArray:[url componentsSeparatedByString:@"&"]];
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *p = parts[i];
        if ([p hasPrefix:@"token="]) {
            parts[i] = [@"token=" stringByAppendingString:KGMaskToken([p substringFromIndex:6])];
        }
    }
    NSString *m = [parts componentsJoinedByString:@"&"];
    if (m.length > 320) { m = [m substringToIndex:320]; }
    if (!KGReqLog) { KGReqLog = [NSMutableArray array]; }
    @synchronized (KGReqLog) {
        [KGReqLog addObject:m];
        while (KGReqLog.count > 20) { [KGReqLog removeObjectAtIndex:0]; }
    }
}

static NSString *KGSign(NSDictionary *params);
static NSString *KGCurSalt(void);

static NSString *KGUnesc(NSString *s) {
    if (s.length == 0) { return @""; }
    return [s stringByRemovingPercentEncoding] ?: s;
}

static NSDictionary *KGQueryDict(NSString *url) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSRange r = [url rangeOfString:@"?"];
    if (r.location == NSNotFound) { return d; }
    NSString *q = [url substringFromIndex:r.location + 1];
    NSRange frag = [q rangeOfString:@"#"];
    if (frag.location != NSNotFound) { q = [q substringToIndex:frag.location]; }
    for (NSString *kv in [q componentsSeparatedByString:@"&"]) {
        NSRange e = [kv rangeOfString:@"="];
        if (e.location == NSNotFound) { continue; }
        NSString *k = [kv substringToIndex:e.location];
        NSString *v = KGUnesc([kv substringFromIndex:e.location + 1]);
        if (k.length) { d[k] = v; }
    }
    return d;
}

static BOOL KGUsable(NSString *s) {
    return (s.length > 0 && ![s isEqualToString:@"-"] && ![s isEqualToString:@"0"]);
}

// 观测 App 自己构造的（已签名）请求，抓真实 token/dfid/mid/appid/salt
static int KGObsUrlCount = 0;
static int KGObsDictCount = 0;

static void KGObserveURL(NSString *url, NSString *saltHint) {
    if (url.length < 10) { return; }
    if (saltHint.length >= 16 && ![saltHint isEqualToString:@"-"]) { KGAppSalt = saltHint; }
    if (KGObsUrlCount > 400) { return; }
    KGObsUrlCount++;
    NSDictionary *p = KGQueryDict(url);
    if (p.count == 0) { return; }
    NSString *t = KGStr(p[@"token"]);
    // v15：64 位才是登录 token，钥匙串里的 36/40 位是 qimei 之类，不能被顶掉
    if (t.length >= 32) {
        if (!KGAppToken || t.length == 64 || t.length > KGAppToken.length) { KGAppToken = t; }
    }
    NSString *u = KGStr(p[@"userid"]); if (u.length == 0) { u = KGStr(p[@"kugouid"]); }
    if (KGUsable(u)) { KGAppUid = u; }
    NSString *df = KGStr(p[@"dfid"]); if (df.length == 0) { df = KGStr(p[@"dfid2"]); }
    if (KGUsable(df)) { KGAppDfid = df; }
    NSString *md = KGStr(p[@"mid"]);
    if (KGUsable(md)) { KGAppMid = md; }
    NSString *ap = KGStr(p[@"appid"]);
    if (KGUsable(ap)) { KGAppAppid = ap; }
    NSString *cv = KGStr(p[@"clientver"]);
    if (KGUsable(cv)) { KGAppClientver = cv; }
    // 记录一条（脱敏 token，其余原样，用于对比 App 真实参数）
    NSString *path = url;
    NSRange qr = [path rangeOfString:@"?"];
    if (qr.location != NSNotFound) { path = [path substringToIndex:qr.location]; }
    if (path.length > 130) { path = [path substringToIndex:130]; }
    NSMutableArray *kv = [NSMutableArray array];
    for (NSString *k in @[@"dfid", @"mid", @"appid", @"clientver", @"userid", @"kugouid", @"source_id", @"receive_day", @"ad_type", @"signature"]) {
        NSString *v = KGStr(p[k]);
        if (v.length == 0) { continue; }
        if ([k isEqualToString:@"signature"] && v.length > 12) { v = [v substringToIndex:12]; }
        [kv addObject:[NSString stringWithFormat:@"%@=%@", k, v]];
    }
    NSString *sig = KGStr(p[@"signature"]);
    if (sig.length >= 32) {
        NSMutableDictionary *q = [NSMutableDictionary dictionaryWithDictionary:p];
        [q removeObjectForKey:@"signature"];
        NSString *mine = KGSign(q);
        [kv addObject:[NSString stringWithFormat:@"sigMatch=%@", [[mine lowercaseString] isEqualToString:[sig lowercaseString]] ? @"Y" : @"N"]];
    }
    KGLogReq([NSString stringWithFormat:@"%@ | tok=%@ | %@", path, KGMaskToken(t), [kv componentsJoinedByString:@"&"]]);
}

// 优先用从 App 自身签名链路观测到的配置（salt/appid/clientver/dfid/mid）
static NSString *KGCurSalt(void) { return (KGAppSalt.length >= 16) ? KGAppSalt : KG_SALT; }
static NSString *KGCurAppid(void) { return KGAppAppid.length ? KGAppAppid : KG_APPID; }
static NSString *KGCurDfid(void) { return KGAppDfid.length ? KGAppDfid : @"-"; }
static NSString *KGCurMid(void) { return KGAppMid.length ? KGAppMid : KG_MID; }

// 观测 App 的参数 dict（signFill 的输入）
static void KGObserveDict(id dict, NSString *salt, NSString *appid) {
    if (salt.length >= 16 && ![salt isEqualToString:@"-"]) { KGAppSalt = salt; }
    if (KGUsable(appid)) { KGAppAppid = appid; }
    if (KGObsDictCount > 400) { return; }
    KGObsDictCount++;
    if (![dict isKindOfClass:NSDictionary.class]) { return; }
    NSDictionary *p = dict;
    NSString *t = KGStr(p[@"token"]);
    // v15：64 位才是登录 token，钥匙串里的 36/40 位是 qimei 之类，不能被顶掉
    if (t.length >= 32) {
        if (!KGAppToken || t.length == 64 || t.length > KGAppToken.length) { KGAppToken = t; }
    }
    NSString *u = KGStr(p[@"userid"]); if (u.length == 0) { u = KGStr(p[@"kugouid"]); }
    if (KGUsable(u)) { KGAppUid = u; }
    NSString *df = KGStr(p[@"dfid"]);
    if (KGUsable(df)) { KGAppDfid = df; }
    NSString *md = KGStr(p[@"mid"]);
    if (KGUsable(md)) { KGAppMid = md; }
    NSString *cv = KGStr(p[@"clientver"]);
    if (KGUsable(cv)) { KGAppClientver = cv; }
    if (KGUsable(KGStr(p[@"appid"]))) { KGAppAppid = KGStr(p[@"appid"]); }
    NSString *skey = KGStr(p[@"source_id"]);
    if (skey.length || KGStr(p[@"receive_day"]).length) {
        KGLogReq([NSString stringWithFormat:@"[dict] tok=%@ src=%@ day=%@ dfid=%@ mid=%@ appid=%@ salt=%@",
                  KGMaskToken(t), skey, KGStr(p[@"receive_day"]), KGStr(p[@"dfid"]),
                  KGStr(p[@"mid"]), KGStr(p[@"appid"]), salt.length ? salt : @"-"]);
    }
}

static NSString *KGSign(NSDictionary *params) {
    // v15：签名必须与 appid 同口径。本地实测 appid=3116 + LnT6xpN3… 签名被服务端认可(返回 51002 而非 20006)，
    // appid=3114/1058 配任何已知 salt 都是 20006。因此固定 3116 口径，绝不再用观测到的 appid 参与签名。
    NSString *salt = KG_SALT;
    NSMutableString *s = [NSMutableString string];
    for (NSString *k in [params.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [s appendFormat:@"%@=%@", k, params[k]];
    }
    return KGMD5([NSString stringWithFormat:@"%@%@%@", salt, s, salt]);
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

static NSString *KGVDesc(id v) {
    if (!v || v == (id)NSNull.null) { return @"(nil)"; }
    if ([v isKindOfClass:NSString.class]) {
        NSString *x = (NSString *)v;
        if (x.length > 24) { return [NSString stringWithFormat:@"%@..(%lu)", [x substringToIndex:12], (unsigned long)x.length]; }
        return x;
    }
    if ([v isKindOfClass:NSNumber.class]) { return [(NSNumber *)v stringValue]; }
    NSString *d = [v description] ?: @"";
    if (d.length > 44) { return [NSString stringWithFormat:@"%@..(%lu)", [d substringToIndex:20], (unsigned long)d.length]; }
    return d;
}

// ---------- 诊断文件 ----------
static void KGWriteDiag(NSString *extra) {
    NSMutableString *s = [NSMutableString string];
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"MM-dd HH:mm:ss";
    [s appendFormat:@"=== %@ %@ ===\n", KG_VER, [f stringFromDate:[NSDate date]]];
    [s appendFormat:@"hooks: login=%@ envInit=%@ envTok=%@ af=%@ common=%@ res=%@ signA=%@ signB=%@ daokey=%@ daoinfo=%@\n",
        H_Login?@"OK":@"MISS", H_EnvInit?@"OK":@"MISS", H_EnvTok?@"OK":@"MISS",
        H_AF?@"OK":@"MISS", H_Common?@"OK":@"MISS", H_Res?@"OK":@"MISS",
        H_SignA?@"OK":@"MISS", H_SignB?@"OK":@"MISS", H_DaoKey?@"OK":@"MISS", H_DaoInfo?@"OK":@"MISS"];
    [s appendFormat:@"hooks14: requrl=%@ setbody=%@ observed=%@ urls=%d\n",
        H_ReqURL?@"OK":@"MISS", H_SetBody?@"OK":@"MISS", KGObservedToken?@"YES":@"NO", KGObsUrlCount];
    // v15：App 自己发出的 youth 请求原始 URL（含 signature），用于反推 appid=3114 的 salt
    @synchronized (KGRawReqs) {
        [s appendString:@"rawreq:"];
        if (!KGRawReqs || KGRawReqs.count == 0) { [s appendString:@" (无)\n"]; }
        else {
            [s appendFormat:@" %lu 条\n", (unsigned long)KGRawReqs.count];
            for (NSString *u in KGRawReqs) { [s appendFormat:@"  %@\n", u]; }
        }
    }
    NSString *token = nil, *uid = nil;
    @synchronized (KGCreds) { token = KGCreds[@"token"]; uid = KGCreds[@"userid"]; }
    [s appendFormat:@"creds: tokLen=%lu uid=%@\n", (unsigned long)(token ? token.length : 0), uid.length ? uid : @"-"];
    // 从 App 自身签名/建请求链路观测到的真实配置（探索性）
    [s appendFormat:@"netsign: salt=%@ appid=%@ clientver=%@\n", KGAppSalt.length ? KGAppSalt : @"-",
        KGAppAppid.length ? KGAppAppid : @"-", KGAppClientver.length ? KGAppClientver : @"-"];
    [s appendFormat:@"netsign: tok=%@ uid=%@ dfid=%@ mid=%@\n",
        KGAppToken.length ? KGMaskToken(KGAppToken) : @"-",
        KGAppUid.length ? KGAppUid : @"-",
        KGAppDfid.length ? KGAppDfid : @"-",
        KGAppMid.length ? KGAppMid : @"-"];
    [s appendString:@"keychain:"];
    [s appendString:KGKeyReport.length ? KGKeyReport : @" (未运行)\n"];
    [s appendString:@"cookies:"];
    [s appendString:KGCookieReport.length ? KGCookieReport : @" (未运行)\n"];
    // 概念版用户状态的键（脱敏）
    {
        id st = [[NSUserDefaults standardUserDefaults] objectForKey:@"YouthUserStateInfoKey"];
        [s appendString:@"ystate: "];
        if (!st) { [s appendString:@"(nil)\n"]; }
        else if ([st isKindOfClass:NSDictionary.class]) {
            NSDictionary *d = st;
            [s appendFormat:@"dict %lu keys: ", (unsigned long)d.count];
            for (NSString *k in [[d allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
                id v = d[k];
                NSString *vs = KGVDesc(v);
                [s appendFormat:@"%@=%@ ", k, vs];
            }
            [s appendString:@"\n"];
        } else if ([st isKindOfClass:NSData.class]) {
            [s appendFormat:@"NSData(%lu)\n", (unsigned long)[(NSData *)st length]];
        } else {
            NSString *vs = KGVDesc(st);
            [s appendFormat:@"%@ %@\n", NSStringFromClass([st class]), vs];
        }
    }
    // 类存在性
    NSArray *names = @[@"KGSVUserInfoManager", @"KGEnvironment", @"AFHTTPSessionManager",
                       @"KGCommonParamDao", @"KGHistoryUserTokenManager", @"KTVUserManager",
                       @"ADCUserProvider", @"KGNetworkTools", @"__NSCFURLSession"];
    for (NSString *n in names) {
        [s appendFormat:@"class %@: %@\n", n, objc_getClass(n.UTF8String) ? @"Y" : @"N"];
    }
    // UserDefaults 键
    NSDictionary *ud = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    [s appendFormat:@"UD keys(%lu): ", (unsigned long)ud.count];
    NSMutableArray *all = [NSMutableArray array];
    for (NSString *k in ud) { [all addObject:k]; }
    [s appendString:[[all sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]];
    [s appendString:@"\n"];
    [s appendFormat:@"probe:\n%@", KGProbeReport.length ? KGProbeReport : @"(未运行)\n"];
    // 候选 token 实打测试结果
    [s appendFormat:@"tokentest:\n%@", KGTokenTestReport.length ? KGTokenTestReport : @"(未运行)\n"];
    // App 内真实接口探测（哪个接口认这个 token）
    [s appendFormat:@"apiprobe:\n%@", KGAPITestReport.length ? KGAPITestReport : @"(未运行)\n"];
    // App 自身请求（脱敏，证明真实接口地址/参数）
    [s appendString:@"appreq:\n"];
    if (KGReqLog.count == 0) { [s appendString:@"(无)\n"]; }
    else {
        for (NSString *l in KGReqLog) { [s appendFormat:@"  %@\n", l]; }
    }
    // UserDefaults 里可能的凭据载体（脱敏）
    [s appendString:@"uddump:\n"];
    for (NSString *k in @[@"lastStartToken", @"YouthUserStateInfoKey"]) {
        id v = [[NSUserDefaults standardUserDefaults] objectForKey:k];
        if (!v) { [s appendFormat:@"  %@: (nil)\n", k]; continue; }
        NSString *desc = nil;
        if ([v isKindOfClass:NSString.class]) { desc = v; }
        else if ([v isKindOfClass:NSData.class]) { desc = [NSString stringWithFormat:@"NSData(%lu)", (unsigned long)[v length]]; }
        else { desc = [NSString stringWithFormat:@"%@ %@", NSStringFromClass([v class]), [v description]]; }
        if (desc.length > 40) {
            desc = [NSString stringWithFormat:@"%@..(%lu)", [desc substringToIndex:16], (unsigned long)desc.length];
        }
        [s appendFormat:@"  %@: %@\n", k, desc];
    }
    if (extra) { [s appendFormat:@"extra: %@\n", extra]; }
    NSString *p = KG_DIAG_PATH(NSHomeDirectory());
    [[NSFileManager defaultManager] createDirectoryAtPath:[p stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [s writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// ---------- 钥匙串 / Cookie 凭据挖掘 ----------
static void KGPushKeyCand(NSString *src, id token, id uid) {
    NSString *t = KGStr(token);
    NSString *u = KGStr(uid);
    if (t.length < 32 || t.length > 200) { return; }
    if ([t rangeOfString:@" "].location != NSNotFound) { return; }
    if (!KGKeyCands) { KGKeyCands = [NSMutableArray array]; }
    for (NSDictionary *d in KGKeyCands) {
        if ([d[@"token"] isEqualToString:t]) { return; }
    }
    [KGKeyCands addObject:@{@"src": src, @"token": t, @"uid": u}];
}

static void KGDigCreds(NSString *src, id value) {
    if (!value) { return; }
    NSString *sv = nil;
    if ([value isKindOfClass:NSString.class]) { sv = value; }
    else if ([value isKindOfClass:NSData.class]) {
        sv = [[NSString alloc] initWithData:(NSData *)value encoding:NSUTF8StringEncoding];
    }
    if (!sv.length) { return; }
    NSString *trim = [sv stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trim.length) { return; }
    if ([trim hasPrefix:@"{"] || [trim hasPrefix:@"["]) {
        id j = nil;
        @try {
            j = [NSJSONSerialization JSONObjectWithData:[trim dataUsingEncoding:NSUTF8StringEncoding]
                                                options:0 error:nil];
        } @catch (__unused NSException *ex) {}
        if ([j isKindOfClass:NSDictionary.class]) {
            NSDictionary *d = j;
            id t = d[@"token"] ?: d[@"userToken"] ?: d[@"usertoken"] ?: d[@"tk"] ?: d[@"access_token"];
            id u = d[@"userid"] ?: d[@"kugouid"] ?: d[@"userId"] ?: d[@"uid"];
            if (t) { KGPushKeyCand(src, t, u); }
            return;
        }
    }
    if (trim.length >= 32 && trim.length <= 200 &&
        [trim rangeOfString:@" "].location == NSNotFound &&
        [trim rangeOfString:@"{"].location == NSNotFound) {
        KGPushKeyCand(src, trim, nil);
    }
}

static void KGDumpKeychain(void) {
    if (!KGKeyReport) { KGKeyReport = [NSMutableString string]; }
    NSArray *classes = @[(__bridge id)kSecClassGenericPassword, (__bridge id)kSecClassInternetPassword];
    NSArray *tags = @[@"gen", @"net"];
    for (NSUInteger ci = 0; ci < classes.count; ci++) {
        NSMutableDictionary *q = [NSMutableDictionary dictionary];
        q[(__bridge id)kSecClass] = classes[ci];
        q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
        q[(__bridge id)kSecReturnAttributes] = @YES;
        q[(__bridge id)kSecReturnData] = @YES;
        CFTypeRef out = NULL;
        OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &out);
        if (st != errSecSuccess || !out) {
            [KGKeyReport appendFormat:@" %@: st=%d\n", tags[ci], (int)st];
            continue;
        }
        NSArray *items = (__bridge_transfer NSArray *)out;
        [KGKeyReport appendFormat:@" %@ count=%lu\n", tags[ci], (unsigned long)items.count];
        for (NSDictionary *it in items) {
            NSString *svc = KGStr(it[(__bridge id)kSecAttrService]);
            NSString *acct = KGStr(it[(__bridge id)kSecAttrAccount]);
            id data = it[(__bridge id)kSecValueData];
            NSString *vs = nil;
            if ([data isKindOfClass:NSData.class]) {
                vs = [[NSString alloc] initWithData:(NSData *)data encoding:NSUTF8StringEncoding];
            }
            NSString *shown = vs.length ? vs : ([data isKindOfClass:NSData.class]
                    ? [NSString stringWithFormat:@"data(%lu)", (unsigned long)[(NSData *)data length]]
                    : KGVDesc(data));
            [KGKeyReport appendFormat:@"   [%@/%@] %@\n", svc.length ? svc : @"-", acct.length ? acct : @"-",
                KGVDesc(shown)];
            KGDigCreds([NSString stringWithFormat:@"KC:%@", svc.length ? svc : @"-"], vs ?: data);
            if (!KGAppUid.length && acct.length > 4 && acct.length < 14 &&
                [acct rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound) {
                KGAppUid = acct;
            }
        }
    }
}

static void KGDumpCookies(void) {
    if (!KGCookieReport) { KGCookieReport = [NSMutableString string]; }
    NSArray *cs = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
    [KGCookieReport appendFormat:@" count=%lu\n", (unsigned long)cs.count];
    NSMutableDictionary *kv = [NSMutableDictionary dictionary];
    for (NSHTTPCookie *c in cs) {
        NSString *nm = c.name ?: @"";
        NSString *val = c.value ?: @"";
        NSString *dom = c.domain ?: @"";
        if ([dom containsString:@"kugou"] || val.length > 24) {
            [KGCookieReport appendFormat:@"   %@ %@=%@\n", dom, nm, KGVDesc(val)];
        }
        if (val.length >= 8) { kv[nm.lowercaseString] = val; }
    }
    NSString *t = kv[@"token"] ?: kv[@"usertoken"];
    NSString *u = kv[@"userid"] ?: kv[@"kugouid"];
    if (t) { KGPushKeyCand(@"cookie", t, u); }
    if (KGUsable(kv[@"dfid"]) && !KGAppDfid) { KGAppDfid = kv[@"dfid"]; }
    if (KGUsable(kv[@"mid"]) && !KGAppMid) { KGAppMid = kv[@"mid"]; }
}

// 读 KGEnvironment 实例上的 mId / appId（请求机签用的真实设备号）
static void KGReadEnvFields(void) {
    if (!KGLastEnv) { return; }
    @try {
        NSString *md = KGStr(((id(*)(id, SEL))objc_msgSend)(KGLastEnv, sel_registerName("mId")));
        NSString *ap = KGStr(((id(*)(id, SEL))objc_msgSend)(KGLastEnv, sel_registerName("appId")));
        if (KGUsable(md) && !KGAppMid) { KGAppMid = md; }
        if (KGUsable(ap) && !KGAppAppid) { KGAppAppid = ap; }
    } @catch (__unused NSException *ex) {}
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
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) { return; }
    NSMutableString *rep = [NSMutableString string];
    NSArray *singles = @[@"shareInstance", @"sharedInstance", @"defaultInstance",
                         @"sharedManager", @"shared", @"sharedUserInfo", @"currentUser"];
    NSArray *uidSels = @[@"kugouId", @"userid", @"userId", @"getUserId",
                         @"getLatestLoginUserId", @"kugouid", @"uid"];
    for (unsigned int i = 0; i < count; i++) {
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
    params[@"dfid"] = KGCurDfid();
    params[@"uuid"] = @"-";
    params[@"mid"] = KGCurMid();
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
    objc_setAssociatedObject(req, &kKGOurReqKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    req.HTTPMethod = @"POST";
    [req setValue:KG_UA forHTTPHeaderField:@"User-Agent"];
    [req setValue:KGCurDfid() forHTTPHeaderField:@"dfid"];
    [req setValue:KGCurMid() forHTTPHeaderField:@"mid"];
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

static void KGGet(NSString *path, NSMutableDictionary *params,
                  void (^done)(NSDictionary *json, NSError *err)) {
    params[@"dfid"] = KGCurDfid();
    params[@"uuid"] = @"-";
    params[@"mid"] = KGCurMid();
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
    objc_setAssociatedObject(req, &kKGOurReqKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    req.HTTPMethod = @"GET";
    [req setValue:KG_UA forHTTPHeaderField:@"User-Agent"];
    [req setValue:KGCurDfid() forHTTPHeaderField:@"dfid"];
    [req setValue:KGCurMid() forHTTPHeaderField:@"mid"];
    [req setValue:ct forHTTPHeaderField:@"clienttime"];
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

// ---------- App 内真实接口探测 ----------
// 响应有两种格式：@/youth/* 用 error_code/error_msg，@/concepts/* 用 errcode/errmsg
static NSString *KGRespCode(NSDictionary *json) {
    NSString *c = KGStr(json[@"error_code"]);
    if (!c.length) { c = KGStr(json[@"errcode"]); }
    return c;
}
static NSString *KGRespMsg(NSDictionary *json) {
    NSString *m = KGStr(json[@"error_msg"]);
    if (!m.length) { m = KGStr(json[@"errmsg"]); }
    return m;
}

static void KGProbeQueue(NSArray *defs, NSUInteger i, NSMutableArray *acc,
                         NSMutableArray *oks, void (^done)(void)) {
    if (!defs || i >= defs.count) {
        for (NSDictionary *d in oks) { (void)d; }
        KGAPITestReport = [acc componentsJoinedByString:@"\n"];
        if (done) { done(); }
        return;
    }
    NSArray *def = defs[i];
    NSString *method = def[0], *path = def[1];
    NSMutableDictionary *p = [NSMutableDictionary dictionaryWithDictionary:def[2]];
    void (^cb)(NSDictionary *, NSError *) = ^(NSDictionary *json, NSError *err) {
        NSString *line;
        if (err) {
            line = [NSString stringWithFormat:@"%@ %@ -> ERR %@", method, path, err.localizedDescription];
        } else {
            NSString *code = KGRespCode(json);
            NSString *msg = KGRespMsg(json);
            NSInteger st = [KGStr(json[@"status"]) integerValue];
            line = [NSString stringWithFormat:@"%@ %@ -> status=%ld code=%@ %@",
                    method, path, (long)st, code.length ? code : @"-", msg];
            BOOL ok = (st == 1) || [code isEqualToString:@"0"] || [code isEqualToString:@"131001"];
            if (ok) {
                [oks addObject:line];
                line = [line stringByAppendingString:@"  <== 可用"];
            }
        }
        [acc addObject:line];
        KGProbeQueue(defs, i + 1, acc, oks, done);
    };
    if ([method isEqualToString:@"POST"]) {
        KGPost(path, p, cb);
    } else {
        KGGet(path, p, cb);
    }
}

static void KGProbeApis(void (^done)(void)) {
    static BOOL running = NO;
    if (running) { if (done) { done(); } return; }
    running = YES;
    NSString *token = nil, *uid = nil;
    @synchronized (KGCreds) { token = KGStr(KGCreds[@"token"]); uid = KGStr(KGCreds[@"userid"]); }
    if (token.length == 0 || uid.length == 0) {
        KGAPITestReport = @"(无凭据)";
        running = NO;
        if (done) { done(); }
        return;
    }
    // ① 先判定 token 是否有效（GET get_vip_tips：51002=无效，其它=有效；20006=签名错）
    NSMutableDictionary *vt = [NSMutableDictionary dictionary];
    vt[@"token"] = token;
    vt[@"userid"] = uid;
    KGGet(@"/youth/v1/account/get_vip_tips", vt, ^(NSDictionary *json, NSError *err) {
        NSString *code = KGRespCode(json);
        NSString *valid = @"?";
        // v15：只有无错误码 / code=0 才算 token 有效；51002、20006、20002 全是无效
        if (code.length == 0 || [code isEqualToString:@"0"]) { valid = @"Y"; }
        else { valid = @"N"; }
        NSString *head = [NSString stringWithFormat:@"tokenValid: %@ (code=%@ %@, salt=%@ appid=%@ dfid=%@)",
                          valid, code.length ? code : @"-", KGRespMsg(json),
                          KGCurSalt(), KGCurAppid(), KGCurDfid()];
        // ② 概念版真实接口（POST；响应 errcode 0=成功）
        NSArray *defs = @[
            @[@"POST", @"/concepts/v1/free_mode/receive_vip_morning",
              (@{@"token": token, @"userid": uid})],
            @[@"POST", @"/concepts/v1/recharge/receive_365_welfare",
              (@{@"token": token, @"userid": uid})],
            @[@"GET", @"/youth/v1/ad/get_ad_vip_time",
              (@{@"token": token, @"userid": uid})],
            @[@"GET", @"/youth/v1/free_package/get_vip_task",
              (@{@"token": token, @"userid": uid})],
            @[@"GET", @"/youth/v1/player/get_user_free_info",
              (@{@"token": token, @"userid": uid})],
            @[@"POST", @"/youth/v1/recharge/receive_vip_listen_song",
              (@{@"source_id": @"90139", @"receive_day": KGTodayString(), @"token": token, @"userid": uid})],
        ];
        NSMutableArray *acc = [NSMutableArray arrayWithObject:head];
        NSMutableArray *oks = [NSMutableArray array];
        KGProbeQueue(defs, 0, acc, oks, ^{
            running = NO;
            if (oks.count > 0) {
                KGVipAlert([NSString stringWithFormat:@"%@接口探测命中 %lu 个(见 diag)", KG_VER, (unsigned long)oks.count]);
            }
            if (done) { done(); }
        });
    });
}

// ---------- 候选凭据收集（多源） ----------
static id KGFirstValue(id inst, NSArray *sels) {
    if (!inst) { return nil; }
    for (NSString *sn in sels) {
        SEL s = NSSelectorFromString(sn);
        if (![inst respondsToSelector:s]) { continue; }
        @try {
            id v = ((id(*)(id, SEL))objc_msgSend)(inst, s);
            if (v && v != (id)NSNull.null && KGStr(v).length > 0) { return v; }
        } @catch (__unused NSException *ex) {}
    }
    return nil;
}

static NSArray *KGSingleNames(void) {
    return @[@"shareInstance", @"sharedInstance", @"defaultInstance", @"sharedManager",
             @"shared", @"sharedUserInfo", @"currentUser"];
}

static id KGInstanceOf(NSString *clsName) {
    Class c = objc_getClass(clsName.UTF8String);
    if (!c) { return nil; }
    for (NSString *sn in KGSingleNames()) {
        SEL s = NSSelectorFromString(sn);
        if (![c respondsToSelector:s]) { continue; }
        @try {
            id v = ((id(*)(id, SEL))objc_msgSend)((id)c, s);
            if (v) { return v; }
        } @catch (__unused NSException *ex) {}
    }
    return nil;
}

static void KGAddCand(NSMutableArray *out, NSString *src, id tv, id uv) {
    NSString *t = KGStr(tv), *u = KGStr(uv);
    if (t.length < 16 || u.length == 0) { return; }
    for (NSDictionary *d in out) { if ([d[@"token"] isEqualToString:t]) { return; } }
    [out addObject:@{@"src": src, @"token": t, @"uid": u}];
}

static NSMutableArray *KGCollectCandidates(void) {
    NSMutableArray *out = [NSMutableArray array];
    // App 自身真实请求里观测到的 token 优先级最高
    if (KGAppToken.length >= 32 && KGAppUid.length > 0) {
        KGAddCand(out, @"AppObserved", KGAppToken, KGAppUid);
    }
    // 钥匙串 / Cookie 里挖到的 token（uid 缺失时用已知 uid 兜底配对）
    if (KGKeyCands.count) {
        NSString *fbUid = KGAppUid;
        @synchronized (KGCreds) { if (!fbUid.length) { fbUid = KGStr(KGCreds[@"userid"]); } }
        for (NSDictionary *d in KGKeyCands) {
            NSString *u = KGStr(d[@"uid"]);
            if (!u.length) { u = fbUid; }
            KGAddCand(out, d[@"src"], d[@"token"], u);
        }
    }
    @synchronized (KGCreds) { KGAddCand(out, @"creds", KGCreds[@"token"], KGCreds[@"userid"]); }

    id ktv = KGInstanceOf(@"KTVUserManager");
    if (ktv) {
        KGAddCand(out, @"KTVUserManager",
                  KGFirstValue(ktv, @[@"token", @"getToken"]),
                  KGFirstValue(ktv, @[@"userId", @"userid", @"kugouId", @"kugouid", @"uid", @"getUserId", @"getLatestLoginUserId"]));
    }
    @try {
        Class c = objc_getClass("KGHistoryUserTokenManager");
        id inst = c ? ((id(*)(id, SEL))objc_msgSend)((id)c, sel_registerName("sharedInstance")) : nil;
        if (inst) {
            NSString *u = KGStr(((id(*)(id, SEL))objc_msgSend)(inst, sel_registerName("getLatestLoginUserId")));
            if (u.length == 0) { u = KGStr(KGFirstValue(inst, @[@"getLatestLoginUserId", @"latestLoginUserId"])); }
            if (u.length > 0) {
                id model = ((id(*)(id, SEL, id))objc_msgSend)(inst, sel_registerName("getHistoryUserTokenModel:"), u);
                KGAddCand(out, @"HistoryToken", KGFirstValue(model, @[@"token", @"userToken"]), u);
            }
        }
    } @catch (__unused NSException *ex) {}

    if (KGLastEnv) {
        KGAddCand(out, @"KGEnvironment",
                  KGFirstValue(KGLastEnv, @[@"token"]),
                  KGFirstValue(KGLastEnv, @[@"userID", @"userid", @"kugouId"]));
    }

    // UserDefaults 里的概念版用户状态
    id st = [[NSUserDefaults standardUserDefaults] objectForKey:@"YouthUserStateInfoKey"];
    if (st) {
        id obj = st;
        if ([st isKindOfClass:NSData.class]) {
            @try { obj = [NSJSONSerialization JSONObjectWithData:st options:0 error:nil]; } @catch (__unused NSException *ex) {}
        } else if ([st isKindOfClass:NSString.class]) {
            NSData *d = [st dataUsingEncoding:NSUTF8StringEncoding];
            id j = nil;
            @try { j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil]; } @catch (__unused NSException *ex) {}
            if ([j isKindOfClass:NSDictionary.class]) { obj = j; }
        }
        if ([obj isKindOfClass:NSDictionary.class]) {
            NSDictionary *d = obj;
            id t = d[@"token"] ?: d[@"userToken"] ?: d[@"tk"];
            id u = d[@"userid"] ?: d[@"kugouid"] ?: d[@"userId"];
            KGAddCand(out, @"YouthUserState", t, u);
        }
    }
    return out;
}

// ---------- 逐个候选做 token 有效性判定（GET get_vip_tips） ----------
static void KGTestTokenLine(NSString *src, NSString *t, NSString *u, void (^done)(NSString *line, BOOL valid)) {
    if (u.length == 0) {
        done([NSString stringWithFormat:@"%@ tok=%@(%lu) -> 缺 uid，跳过", src, KGMaskToken(t), (unsigned long)t.length], NO);
        return;
    }
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    p[@"token"] = t;
    p[@"userid"] = u;
    KGGet(@"/youth/v1/account/get_vip_tips", p, ^(NSDictionary *json, NSError *err) {
        if (err) {
            done([NSString stringWithFormat:@"%@ tok=%@ uid=%@ -> ERR %@",
                  src, KGMaskToken(t), u, err.localizedDescription], NO);
            return;
        }
        NSString *code = KGRespCode(json);
        NSString *msg = KGRespMsg(json);
        BOOL valid = (code.length > 0) && ![code isEqualToString:@"51002"] && ![code isEqualToString:@"20006"];
        done([NSString stringWithFormat:@"%@ tok=%@(%lu) uid=%@ -> code=%@ %@ tokenValid=%@",
              src, KGMaskToken(t), (unsigned long)t.length, u, code.length ? code : @"-", msg,
              valid ? @"Y" : @"N"], valid);
    });
}

static void KGTestQueue(NSArray *cands, NSUInteger i, NSMutableArray *acc, void (^done)(void)) {
    if (i >= cands.count) {
        KGTokenTestReport = [acc componentsJoinedByString:@"\n"];
        if (done) { done(); }
        return;
    }
    NSDictionary *c = cands[i];
    KGTestTokenLine(c[@"src"], c[@"token"], c[@"uid"], ^(NSString *line, BOOL valid) {
        [acc addObject:valid ? [line stringByAppendingString:@"  <== 可用"] : line];
        if (valid) {
            @synchronized (KGCreds) {
                KGCreds[@"token"] = c[@"token"];
                KGCreds[@"userid"] = c[@"uid"];
                KGCredsLoaded = YES;
                [[NSUserDefaults standardUserDefaults] setObject:[KGCreds copy] forKey:KG_CREDS_KEY];
            }
            if (KGAppUid.length == 0) { KGAppUid = c[@"uid"]; }
        }
        KGTestQueue(cands, i + 1, acc, done);
    });
}

static void KGRunTokenTests(void (^done)(void)) {
    static BOOL running = NO;
    if (running) { if (done) { done(); } return; }
    running = YES;
    NSArray *cands = KGCollectCandidates();
    if (cands.count == 0) {
        KGTokenTestReport = @"(无候选)";
        running = NO;
        if (done) { done(); }
        return;
    }
    KGTestQueue(cands, 0, [NSMutableArray array], ^{
        running = NO;
        if (done) { done(); }
    });
}

static void KGDoClaim(void);
static void KGDoUpgrade(void);

static void KGDoClaim(void) {
    if (KGDoneToday) { return; }
    static BOOL inflight = NO;
    if (inflight) { return; }
    NSString *token = nil, *userid = nil;
    @synchronized (KGCreds) { token = KGCreds[@"token"]; userid = KGCreds[@"userid"]; }
    if (token.length == 0 || userid.length == 0) { return; }
    inflight = YES;

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
        BOOL kgFail = ([msg hasPrefix:@"签到失败"] || [msg hasPrefix:@"签到网络错误"]);
        BOOL kgNoop = [msg isEqualToString:@"今天已签到"];
        static BOOL kgFailAlerted = NO;
        if (kgNoop) {
            // 131001 说明 token 已被服务端接受（否则只会是 51002/20018/20006），方案成立
            static BOOL kgOkAlerted = NO;
            if (!kgOkAlerted) {
                kgOkAlerted = YES;
                KGVipAlert([NSString stringWithFormat:@"%@：token 有效，今日已领，明天打开自动领", KG_VER]);
            }
        } else if (!kgFail || !kgFailAlerted) {
            if (kgFail) { kgFailAlerted = YES; }
            KGVipAlert([NSString stringWithFormat:@"自动领(%@)：%@", KG_VER, msg]);
        }
        KGWriteDiag(msg);
        inflight = NO;
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
        BOOL kgFail = ([msg hasPrefix:@"升级失败"] || [msg hasPrefix:@"升级网络错误"]);
        BOOL kgNoop = [msg isEqualToString:@"今天已签到"];
        static BOOL kgUpFailAlerted = NO;
        if (!kgNoop && (!kgFail || !kgUpFailAlerted)) {
            if (kgFail) { kgUpFailAlerted = YES; }
            KGVipAlert([NSString stringWithFormat:@"自动领(%@)：%@", KG_VER, msg]);
        }
        KGWriteDiag(msg);
    });
}

static BOOL KGSyncFromObserved(void) {
    if (KGAppToken.length < 32 || KGAppUid.length == 0) { return NO; }
    NSString *cur = nil;
    @synchronized (KGCreds) { cur = KGCreds[@"token"]; }
    if ([cur isEqualToString:KGAppToken]) { return YES; }
    @synchronized (KGCreds) {
        KGCreds[@"token"] = KGAppToken;
        KGCreds[@"userid"] = KGAppUid;
        KGCredsLoaded = YES;
        [[NSUserDefaults standardUserDefaults] setObject:[KGCreds copy] forKey:KG_CREDS_KEY];
    }
    return YES;
}

static void KGDigAllOnce(void) {
    static BOOL dug = NO;
    if (dug) { return; }
    dug = YES;
    KGReadEnvFields();
    KGDumpKeychain();
    KGDumpCookies();
}

static void KGAutoClaimTick(BOOL verbose) {
    if (KGDoneToday) { return; }
    KGLoadCreds();
    KGReadCredsFile();
    KGReadHistoryToken();
    KGReadLoginManager();
    KGSyncFromObserved();
    KGDigAllOnce();
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
    if (verbose) {
        // 45 秒诊断：① 逐个候选 token 判定有效性；② 用当前 token 试探概念版真实接口；③ 再试领取
        KGRunTokenTests(^{
            KGProbeApis(^{
                KGWriteDiag(@"diag-tick");
                KGDoClaim();
            });
        });
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

// v15：抓 App 自己发出的 youth 请求原始 URL（含完整 signature），用于反推 appid=3114 的 salt。
// 前提是该请求不是我们自己发的（KGPost/KGGet 会打关联标记）。
static void KGRawCapture(NSString *url) {
    if (url.length < 40) { return; }
    if ([url rangeOfString:@"gateway.kugou.com"].location == NSNotFound) { return; }
    if ([url rangeOfString:@"signature="].location == NSNotFound) { return; }
    if ([url rangeOfString:@"youth/"].location == NSNotFound &&
        [url rangeOfString:@"recharge"].location == NSNotFound &&
        [url rangeOfString:@"listen_song"].location == NSNotFound) { return; }
    if (!KGRawReqs) { KGRawReqs = [NSMutableArray array]; }
    @synchronized (KGRawReqs) {
        if (KGRawReqs.count >= 8) { return; }
        // 同一接口只保留第一条（clienttime 每次都变，整串去重无效）
        NSString *pathOnly = [url componentsSeparatedByString:@"?"].firstObject;
        for (NSString *e in KGRawReqs) {
            if ([[e componentsSeparatedByString:@"?"].firstObject isEqualToString:pathOnly]) { return; }
        }
        [KGRawReqs addObject:url];
    }
}

// v14 核心：全 App 网络请求必经点观测。只要 App 发出任意一个带 token 的请求，
// 就能拿到「App 真正在用的 token/userid」，这是 v13 之前一直没打通的环节。
static void KGOnURLSeen(NSString *url) {
    if (url.length < 8) { return; }
    if (![url containsString:@"token="]) { return; }
    KGObserveURL(url, nil);
    if (KGObservedToken) { return; }
    // v15：只有 64 位登录 token + userid 才算真凭据，避免 36/40 位的 qimei 误触发
    if (KGAppToken.length != 64 || KGAppUid.length == 0) { return; }
    KGObservedToken = YES;
    KGSaveCreds(KGAppToken, KGAppUid);
    KGWriteDiag([NSString stringWithFormat:@"v15 命中真实token len=%lu uid=%@ mid=%@ dfid=%@ appid=%@",
                 (unsigned long)KGAppToken.length, KGAppUid, KGAppMid, KGAppDfid, KGAppAppid]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ KGDoClaim(); });
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
                    // 记录 App 自身发往 youth/vip 业务的请求，供对比真实接口
                    NSString *us = KGStr(urlStr);
                    if (us.length && ([us containsString:@"youth"] || [us containsString:@"recharge"] ||
                                      [us containsString:@"vip"] || [us containsString:@"listen_song"])) {
                        NSMutableArray *kv = [NSMutableArray array];
                        for (NSString *k in p) {
                            if ([k isEqualToString:@"token"]) { continue; }
                            if ([k isEqualToString:@"signature"]) { continue; }
                            [kv addObject:[NSString stringWithFormat:@"%@=%@", k, KGStr(p[k])]];
                        }
                        KGLogReq([NSString stringWithFormat:@"%@ | tok=%@ | %@",
                                  us, KGMaskToken(t), [kv componentsJoinedByString:@"&"]]);
                    }
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
    // 6) KGNetworkTools 签名/拼参（App 自己算签名的地方，能拿到真实 salt/appid/dfid/token）
    if (!H_SignA) {
        Class nc = objc_getClass("KGNetworkTools");
        SEL s = sel_registerName("signFillUrlCustomParameterDictionary:bodyString:isCdnRequest:signature:appid:saltKey:is256Sign:");
        Method m = nc ? class_getInstanceMethod(nc, s) : NULL;
        if (m) {
            IMP ni = imp_implementationWithBlock(^(id self, id dict, id body, BOOL isCdn, id *sigOut,
                                                   id appid, id salt, BOOL is256) {
                id r = nil;
                if (KGOrigSignA) {
                    r = ((id(*)(id, SEL, id, id, BOOL, id*, id, id, BOOL))KGOrigSignA)
                        (self, s, dict, body, isCdn, sigOut, appid, salt, is256);
                }
                @try {
                    KGObserveDict(dict, KGStr(salt), KGStr(appid));
                    if ([r isKindOfClass:NSString.class]) { KGObserveURL(r, KGStr(salt)); }
                } @catch (__unused NSException *ex) {}
                return r;
            });
            KGOrigSignA = method_setImplementation(m, ni);
            H_SignA = (KGOrigSignA != NULL);
        }
    }
    if (!H_SignB) {
        Class nc = objc_getClass("KGNetworkTools");
        SEL s = sel_registerName("signFillUrlCustomParameterDictionary:bodyString:isCdnRequest:signature:saltKey:is256Sign:");
        Method m = nc ? class_getInstanceMethod(nc, s) : NULL;
        if (m) {
            IMP ni = imp_implementationWithBlock(^(id self, id dict, id body, BOOL isCdn, id *sigOut,
                                                   id salt, BOOL is256) {
                id r = nil;
                if (KGOrigSignB) {
                    r = ((id(*)(id, SEL, id, id, BOOL, id*, id, BOOL))KGOrigSignB)
                        (self, s, dict, body, isCdn, sigOut, salt, is256);
                }
                @try {
                    KGObserveDict(dict, KGStr(salt), nil);
                    if ([r isKindOfClass:NSString.class]) { KGObserveURL(r, KGStr(salt)); }
                } @catch (__unused NSException *ex) {}
                return r;
            });
            KGOrigSignB = method_setImplementation(m, ni);
            H_SignB = (KGOrigSignB != NULL);
        }
    }
    // 7) BaseHttpDao 建请求（返回 NSURLRequest，URL 里就是最终参数）
    if (!H_DaoKey) {
        Class dc = objc_getClass("BaseHttpDao");
        SEL s = sel_registerName("createRequestWithKey:AndFillUrl:AndReurnType:AndHeader:AndIsPost:");
        Method m = dc ? class_getInstanceMethod(dc, s) : NULL;
        if (m) {
            IMP ni = imp_implementationWithBlock(^(id self, id key, id url, int rt, id hdr, BOOL isPost) {
                id r = nil;
                if (KGOrigDaoKey) { r = ((id(*)(id, SEL, id, id, int, id, BOOL))KGOrigDaoKey)(self, s, key, url, rt, hdr, isPost); }
                @try {
                    if ([r isKindOfClass:NSURLRequest.class]) { KGObserveURL([[(NSURLRequest *)r URL] absoluteString], nil); }
                    else if ([r isKindOfClass:NSString.class]) { KGObserveURL((NSString *)r, nil); }
                    if ([url isKindOfClass:NSString.class] && [(NSString *)url containsString:@"?"]) { KGObserveURL((NSString *)url, nil); }
                } @catch (__unused NSException *ex) {}
                return r;
            });
            KGOrigDaoKey = method_setImplementation(m, ni);
            H_DaoKey = (KGOrigDaoKey != NULL);
        }
    }
    if (!H_DaoInfo) {
        Class dc = objc_getClass("BaseHttpDao");
        SEL s = sel_registerName("createRequestWithGetMethodInfo:AndIsPost:");
        Method m = dc ? class_getInstanceMethod(dc, s) : NULL;
        if (m) {
            IMP ni = imp_implementationWithBlock(^(id self, id info, BOOL isPost) {
                id r = nil;
                if (KGOrigDaoInfo) { r = ((id(*)(id, SEL, id, BOOL))KGOrigDaoInfo)(self, s, info, isPost); }
                @try {
                    if ([r isKindOfClass:NSURLRequest.class]) { KGObserveURL([[(NSURLRequest *)r URL] absoluteString], nil); }
                    NSString *d = info ? [info description] : nil;
                    if (d.length && ([d containsString:@"youth"] || [d containsString:@"recharge"] || [d containsString:@"vip"])) {
                        KGLogReq([NSString stringWithFormat:@"[info] %@", (d.length > 260 ? [d substringToIndex:260] : d)]);
                    }
                } @catch (__unused NSException *ex) {}
                return r;
            });
            KGOrigDaoInfo = method_setImplementation(m, ni);
            H_DaoInfo = (KGOrigDaoInfo != NULL);
        }
    }
    // 8) -[NSURLRequest URL] —— v14 的关键。全 App 任何网络请求构造/发送都会访问 URL，
    //    不依赖酷狗任何私有类，是唯一一定能命中的观测点。
    if (!H_ReqURL) {
        Class c = objc_getClass("NSURLRequest");
        SEL s = sel_registerName("URL");
        Method m = c ? class_getInstanceMethod(c, s) : NULL;
        if (m) {
            IMP ni = imp_implementationWithBlock(^id(id self) {
                id r = KGOrigReqURL ? ((id(*)(id, SEL))KGOrigReqURL)(self, s) : nil;
                @try {
                    if ([r isKindOfClass:NSURL.class]) {
                        NSString *u = [(NSURL *)r absoluteString];
                        BOOL ours = (objc_getAssociatedObject(self, &kKGOurReqKey) != nil);
                        if (!ours) { KGRawCapture(u); }
                        static int budget = 0;
                        if (budget < 6000) { budget++; KGOnURLSeen(u); }
                    }
                } @catch (__unused NSException *ex) {}
                return r;
            });
            KGOrigReqURL = method_setImplementation(m, ni);
            H_ReqURL = (KGOrigReqURL != NULL);
        }
    }
    // 9) -[NSMutableURLRequest setHTTPBody:] —— POST 时参数在 body 里，从这捞
    if (!H_SetBody) {
        Class c = objc_getClass("NSMutableURLRequest");
        SEL s = sel_registerName("setHTTPBody:");
        Method m = c ? class_getInstanceMethod(c, s) : NULL;
        if (m) {
            IMP ni = imp_implementationWithBlock(^(id self, NSData *body) {
                if (KGOrigSetBody) { ((void(*)(id, SEL, id))KGOrigSetBody)(self, s, body); }
                @try {
                    if (body.length > 8 && body.length < 30000) {
                        NSString *str = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
                        if (str.length && [str containsString:@"token="]) {
                            KGOnURLSeen([@"?" stringByAppendingString:str]);
                        }
                    }
                } @catch (__unused NSException *ex) {}
            });
            KGOrigSetBody = method_setImplementation(m, ni);
            H_SetBody = (KGOrigSetBody != NULL);
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
        KGSyncFromObserved();
        KGDigAllOnce();
        NSString *token = nil, *userid = nil;
        @synchronized (KGCreds) { token = KGCreds[@"token"]; userid = KGCreds[@"userid"]; }
        if (token.length > 0 && userid.length > 0 && !announced) {
            announced = YES;
            KGVipAlert([NSString stringWithFormat:@"凭据已采集(%@)，5 秒后自动领取\nsalt=%@ appid=%@", KG_VER,
                        KGCurSalt().length > 12 ? [KGCurSalt() substringToIndex:12] : KGCurSalt(), KGCurAppid()]);
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
