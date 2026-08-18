// NetworkProbe — a one-screen iOS app for seeing `baguette network` work.
//
// Two buttons that fetch the same URL two different ways, and print how long
// each took:
//
//   URLSession  — goes through the URL Loading System, so baguette's injected
//                 URLProtocol conditions it.
//   WKWebView   — WebKit loads page resources in its own networking process,
//                 on a path URLProtocol does not sit on, so it is NOT
//                 conditioned.
//
// Run them side by side under `baguette network set --latency 3000` and the
// gap documented in docs/features/network.md stops being a claim and becomes
// two numbers on a screen.

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

/// Small and cache-hostile: a query string keeps every request going to the
/// network rather than being answered from the URL cache, which would make a
/// conditioned request look instant.
static NSString *ProbeURL(void) {
    return [NSString stringWithFormat:@"https://www.apple.com/library/test/success.html?n=%u",
            arc4random()];
}

@interface ProbeViewController : UIViewController <WKNavigationDelegate>
@property (nonatomic, strong) UITextView *log;
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic) NSTimeInterval webStartedAt;
@end

@implementation ProbeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *title = [UILabel new];
    title.text = @"Network Probe";
    title.font = [UIFont monospacedSystemFontOfSize:22 weight:UIFontWeightBold];

    UILabel *hint = [UILabel new];
    hint.text = @"URLSession is conditioned. WKWebView is not.";
    hint.font = [UIFont systemFontOfSize:13];
    hint.textColor = UIColor.secondaryLabelColor;
    hint.numberOfLines = 0;

    UIButton *session = [self buttonTitled:@"Fetch — URLSession"
                                    action:@selector(fetchWithURLSession)];
    UIButton *burst = [self buttonTitled:@"Fetch ×5 — URLSession"
                                  action:@selector(fetchBurst)];
    UIButton *webview = [self buttonTitled:@"Load — WKWebView"
                                    action:@selector(loadInWebView)];
    UIButton *clear = [self buttonTitled:@"Clear log" action:@selector(clearLog)];

    self.log = [UITextView new];
    self.log.editable = NO;
    self.log.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.log.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.log.layer.cornerRadius = 10;

    // On screen, and it has to be: WebKit does not start a load for a
    // WKWebView that is not in a window, so an offscreen one sits there
    // reporting nothing and looks like the load silently failed.
    self.web = [WKWebView new];
    self.web.navigationDelegate = self;
    [self.web.heightAnchor constraintEqualToConstant:120].active = YES;
    self.web.layer.cornerRadius = 8;
    self.web.clipsToBounds = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, hint, session, burst, webview, clear, self.web, self.log,
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
    ]];

    [self append:@"Ready. Arm a condition, then relaunch this app:"];
    [self append:@"  baguette network set --udid <UDID> --latency 3000"];
}

- (UIButton *)buttonTitled:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    b.backgroundColor = UIColor.tertiarySystemBackgroundColor;
    b.layer.cornerRadius = 9;
    [b.heightAnchor constraintEqualToConstant:42].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)append:(NSString *)line {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.log.text = [NSString stringWithFormat:@"%@%@\n", self.log.text ?: @"", line];
        NSRange end = NSMakeRange(self.log.text.length - 1, 1);
        [self.log scrollRangeToVisible:end];
    });
}

- (void)clearLog { self.log.text = @""; }

#pragma mark Fetches

- (void)fetchWithURLSession {
    NSDate *started = NSDate.date;
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:ProbeURL()]];
    // A default configuration, which is what an ordinary app uses — and what
    // baguette's configuration swizzle reaches.
    NSURLSession *session = [NSURLSession
        sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration];
    [[session dataTaskWithRequest:request
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        long ms = (long)(-started.timeIntervalSinceNow * 1000);
        if (error) {
            [self append:[NSString stringWithFormat:@"URLSession  FAILED in %4ld ms — %@ (%ld)",
                          ms, error.localizedDescription, (long)error.code]];
            return;
        }
        long status = (long)((NSHTTPURLResponse *)response).statusCode;
        [self append:[NSString stringWithFormat:@"URLSession  %ld in %4ld ms, %lu bytes",
                      status, ms, (unsigned long)data.length]];
    }] resume];
}

- (void)fetchBurst {
    for (int i = 0; i < 5; i++) [self fetchWithURLSession];
}

- (void)loadInWebView {
    self.webStartedAt = NSDate.date.timeIntervalSince1970;
    [self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:ProbeURL()]]];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    long ms = (long)((NSDate.date.timeIntervalSince1970 - self.webStartedAt) * 1000);
    [self append:[NSString stringWithFormat:@"WKWebView   loaded in %4ld ms  (not conditioned)",
                  ms]];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
    long ms = (long)((NSDate.date.timeIntervalSince1970 - self.webStartedAt) * 1000);
    [self append:[NSString stringWithFormat:@"WKWebView   failed in %4ld ms — %@",
                  ms, error.localizedDescription]];
}

@end

@interface ProbeAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation ProbeAppDelegate
- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [ProbeViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass(ProbeAppDelegate.class));
    }
}
