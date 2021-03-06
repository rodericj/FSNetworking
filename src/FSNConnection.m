//
//  FSNConnection.m
//  FSN
//
//  Created by George King on 7/14/11.
//  Copyright 2011-2012 Foursquare Labs, Inc. All rights reserved.
//  Permission to use this file is granted in FSNetworking/license.txt (apache v2).
//


#import "FSNData.h"
#import "FSNConnection.h"


// Typically, FSN_QUEUED_CONNECTIONS is set to 0 or 1 in the target's prefix header.
// Note that NSURLConnection setDelegateQueue appears to be broken on iOS 5.1, causing application-wide deadlocks.
// See README.md for details.

#if FSN_QUEUED_CONNECTIONS

#if TARGET_OS_IPHONE
#warning "NSURLConnection using setDelegateQueue is known to deadlock on iOS 5"
#endif

#endif


NSString * const FSNConnectionActivityBegan = @"FSNConnectionActivityBegan";
NSString * const FSNConnectionActivityEnded = @"FSNConnectionActivityEnded";


NSString* stringForRequestMethod(FSNRequestMethod method) {
    switch (method) {
        case FSNRequestMethodGET:   return @"GET";
        case FSNRequestMethodPOST:  return @"POST";
        default:
            NSCAssert(0, @"unknown request method");
            return nil;
    }
}


@interface FSNConnection ()

// public readonly

@property (nonatomic, retain, readwrite) NSURLResponse *response;
@property (nonatomic, retain, readwrite) NSMutableData *responseData;

@property (nonatomic, retain, readwrite) id<NSObject> parseResult;
@property (nonatomic, retain, readwrite) NSError *error;

@property (nonatomic, readwrite) BOOL didStart;
@property (nonatomic, readwrite) BOOL didFinishLoading;
@property (nonatomic, readwrite) BOOL didComplete;

@property (nonatomic, readwrite) int uploadProgressBytes;
@property (nonatomic, readwrite) int uploadExpectedBytes;

// private

@property (nonatomic, retain) NSURLConnection *connection;
@property (nonatomic, retain) NSRecursiveLock *blocksLock;

#if TARGET_OS_IPHONE
@property (nonatomic) UIBackgroundTaskIdentifier taskIdentifier;
#endif

@end


@implementation FSNConnection

@synthesize
url                     = _url,
method                  = _method,
headers                 = _headers,
parameters              = _parameters,

parseBlock              = _parseBlock,
completionBlock         = _completionBlock,
progressBlock           = _progressBlock,

response                = _response,
responseData            = _responseData,
parseResult             = _parseResult,
error                   = _error,

didStart                = _didStart,
didFinishLoading        = _didFinishLoading,
didComplete             = _didComplete,

uploadProgressBytes     = _uploadProgressBytes,
uploadExpectedBytes     = _uploadExpectedBytes,

#if TARGET_OS_IPHONE
shouldRunInBackground   = _shouldRunInBackground,
taskIdentifier          = _taskIdentifier,
#endif

connection              = _connection,
blocksLock              = _blocksLock;


#pragma mark - NSObject


- (void)dealloc {
    
    NSAssert(!self.connection, @"non-nil connection: %@", self.connection);
    
#if TARGET_OS_IPHONE
    // if this task was set to run in background then the expiration handler should be retaining self
    NSAssert1(self.taskIdentifier == UIBackgroundTaskInvalid,
              @"deallocated request has background task identifier: %@", self);
#endif
    
    self.url            = nil;
    self.headers        = nil;
    self.parameters     = nil;
    self.response       = nil;
    self.responseData   = nil;
    self.parseResult    = nil;
    self.error          = nil;
    
    [self clearBlocks]; // not cleanup; assert no taskIdentifer above instead
    
    // just to be safe in production
    [self.connection cancel];
    self.connection = nil;
    
    self.blocksLock = nil;
    
    [super dealloc];
}


- (NSString*)description {
    return
    [NSString stringWithFormat:
     @"<%@: %p | parse:%@ fin:%@ prog:%@ | "
     @"cn:%@ res:%@ err:%@ | "
     @"st:%@ fl:%@ comp:%@ succ:%@ | url: %@>",
     self.class, self, BIT_YN(self.parseBlock), BIT_YN(self.completionBlock), BIT_YN(self.progressBlock),
     BIT_YN(self.connection), BIT_YN(self.parseResult), BIT_YN(self.error),
     BIT_YN(self.didStart), BIT_YN(self.didFinishLoading), BIT_YN(self.didComplete), BIT_YN(self.didSucceed),
     self.url];
}


- (id)init {
    self = [super init];
    if (!self) return nil;
    
    // protect executing blocks from being dealloced; lock is recursive because:
    // - calling clearBlocks may cause an object in the block closure to be released
    // - that may in turn 'own' the connection, and call clearBlocks to properly break retain cycles in all cases.
    self.blocksLock = [[NSRecursiveLock new] autorelease];
    
    return self;
}


#pragma mark - NSURLConnectionDelegate


// MARK: redirects


// called whenever an NSURLConnection determines that it must change URLs in order to continue loading a request.
// TODO: support redirect modification with a redirectBlock or delegate?
- (NSURLRequest *)connection:(NSURLConnection *)connection
             willSendRequest:(NSURLRequest *)request
            redirectResponse:(NSURLResponse *)response {
    
    FSNVerbose(@"%p: willSendResponse", self);
    return request;
}


// called whenever an NSURLConnection determines that the client needs to provide a new, unopened body stream.
// TODO: support streams with streamBlock or delegate?
//- (NSInputStream *)connection:(NSURLConnection *)connection needNewBodyStream:(NSURLRequest *)request {
//    FSNVerbose(@"%p: needNewBodyStream", self);
//}


// MARK: authentication


// TODO: support authenticationBlock or delegate?
- (BOOL)connectionShouldUseCredentialStorage:(NSURLConnection *)connection {

    FSNVerbose(@"%p: connectionShouldUseCredentialStorage", self);
    return YES;
}


- (void)connection:(NSURLConnection *)connection
willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
    
    FSNVerbose(@"%p: willSendRequestForAuthenticationChallenge", self);
    [challenge.sender performDefaultHandlingForAuthenticationChallenge:challenge];
}


// MARK: response


- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSHTTPURLResponse *)response {

    FSNVerbose(@"%p: didReceiveResponse", self);
    FSNVerbose(@"Response Headers: %@", [response allHeaderFields]);
    
    // according to apple docs, this method may be called more than once in rare cases (similar to body stream case)
    // for this reason, responseData should be initialized/reset here
    self.response = response;
    self.responseData = [NSMutableData data];
}


- (void)connection:(NSURLConnection *)connection
   didSendBodyData:(NSInteger)bytesWritten
 totalBytesWritten:(NSInteger)totalBytesWritten
totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite {
    
    FSNVerbose(@"%p: didSendBodyData", self);
    
    self.uploadProgressBytes = totalBytesWritten;
    self.uploadExpectedBytes = totalBytesExpectedToWrite;
    
    [self performReportProgress];
}


- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
 
    FSNVerbose(@"%p: didReceiveData", self);
    
    [self.responseData appendData:data];
    [self performReportProgress];
}


- (NSCachedURLResponse *)connection:(NSURLConnection *)connection
                  willCacheResponse:(NSCachedURLResponse *)cachedResponse {
    
    FSNVerbose(@"%p: willCacheResponse;\n  cachedResponse: %@", self, cachedResponse);
    return cachedResponse; // return nil to circumvent caching
}


- (void)connectionDidFinishLoading:(NSURLConnection *)connection {

    FSNVerbose(@"%p: didFinishLoading", self);
    
    self.didFinishLoading = YES;
    
    if (self.parseBlock) {
        [self callOrDispatchParse];
    }
    else {
        [self performComplete];
    }
}


- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    
    FSNVerbose(@"%p: didFail", self);
    [self failWithError:error];
}


#pragma mark - FSNConnection


#if FSN_QUEUED_CONNECTIONS
+ (NSOperationQueue *)queue {
    static NSOperationQueue *q = nil;
    if (!q) {
        q = [NSOperationQueue new];
        q.name = @"FSNConnection queue";
    }
    return q;
}
#endif


+ (NSMutableSet *)mutableConnections {
    
    static NSMutableSet *set = nil;
    if (!set) {
        set = [NSMutableSet new];
    }
    return set;
}


// publicly expose the connection set as read-only
+ (NSSet *)connections {
    return [self mutableConnections];
}


+ (void)cancelAllConnections {
    for (FSNConnection *c in [[self connections] allObjects]) {
        [c cancel];
    }
}


+ (id)withUrl:(NSURL *)url
       method:(FSNRequestMethod)method
      headers:(NSDictionary*)headers
   parameters:(NSDictionary*)parameters
   parseBlock:(FSNParseBlock)parseBlock
completionBlock:(FSNCompletionBlock)completionBlock
progressBlock:(FSNProgressBlock)progressBlock {
    
    FSNConnection *c = [[FSNConnection new] autorelease];
    
    c.url           = url;
    c.method        = method;
    c.headers       = headers;
    c.parameters    = parameters;
    c.parseBlock    = parseBlock;
    c.completionBlock   = completionBlock;
    c.progressBlock = progressBlock;
    
#if TARGET_OS_IPHONE
    c.shouldRunInBackground = (method == FSNRequestMethodPOST);
    c.taskIdentifier        = UIBackgroundTaskInvalid;
#endif
    
    return c;
}


// MARK: accessors


- (BOOL)didSucceed {
    return self.didComplete && !self.error;
}


// MARK: life cycle


- (void)clearBlocks {
    [self.blocksLock lock];
    
    self.parseBlock = nil;
    self.completionBlock = nil;
    self.progressBlock = nil;
    
    [self.blocksLock unlock];
}


- (void)cleanup {
    
    [self clearBlocks];
#if TARGET_OS_IPHONE
    [self endBackgroundTask];
#endif
    
    NSMutableSet *requests = [self.class mutableConnections];
    [requests removeObject:self];
    
    if (requests.count == 0) {
        [[NSNotificationCenter defaultCenter] postNotificationName:FSNConnectionActivityEnded object:nil];
    }
}


- (void)cancelConnection {
    FSNVerbose(@"%p: cancelConnection", self);
    [self.connection cancel]; // releases delegate (self)
    self.connection = nil;
}


- (void)callOrDispatchParse {
    
#if FSN_QUEUED_CONNECTIONS
    [self parse];
#else
    // dispatch to the medium priority global queue
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self parse]; 
    });    
#endif
}


// performed on a background thread, either via connection queue (mac) or dispatch_async (ios)
- (void)parse {
    ASSERT_NOT_MAIN_THREAD;
    
    NSError *error = nil;
    
    // because the connection could get canceled after the block calling this method is dispatched,
    // we must both lock out out concurrent cancellation, and check that the parse block still exists.
    
    [self.blocksLock lock];
    
    if (self.parseBlock) {

        self.parseResult = self.parseBlock(self, &error);
        
        if (error) {
            [self failWithError:error];
        }
        else {
            [self performComplete];
        }
    }
    
    [self.blocksLock unlock];
}


- (void)failWithError:(NSError *)error {
    FSNLog(@"failWithError: %@\n  error: %@", self, error);
    NSAssert(!self.error, @"error already set");
    self.error = error;
    
    [self performComplete];
}


- (void)performComplete {
    FSNVerbose(@"%p: performComplete", self);
    self.connection = nil;
    [self performSelectorOnMainThread:@selector(complete) withObject:nil waitUntilDone:NO]; // call retains self
}


- (void)complete {
    ASSERT_MAIN_THREAD;
    
#if FSN_LOG_VERBOSE
    NSTimeInterval s = [NSDate timeIntervalSinceReferenceDate];
#endif
    
    self.didComplete = YES;
    
    [self reportProgress];
    
    [self.blocksLock lock];
    if (self.completionBlock) {
        self.completionBlock(self);
    }
    [self.blocksLock unlock];
    
    [self cleanup];
    
    FSNVerbose(@"complete: %f", [NSDate timeIntervalSinceReferenceDate] - s);
}


// MARK: public


// returns self, or nil if start fails
- (FSNConnection *)start {
    
    // TODO: replace this assertion with failWithError: (never add to queue)
    NSAssert(self.url, @"nil url");
    
    FSNVerbose(@"%p: enqueue (#%d)", self, [[self.class connections] count]);
    
    NSMutableSet *connections = [self.class mutableConnections];
    [connections addObject:self];
    
    if (connections.count == 1) {
        [[NSNotificationCenter defaultCenter] postNotificationName:FSNConnectionActivityBegan object:nil];
    }
    
    self.didStart = YES;
    
#if TARGET_OS_IPHONE
    if (self.shouldRunInBackground) {
        self.taskIdentifier =
        [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            [self didExpireInBackground]; // application will retain self until we end the background task
        }];
    }
#endif
    
    NSURLRequest *urlRequest = [self makeNSURLRequest];
    
    if (![NSURLConnection canHandleRequest:urlRequest]) {
        [self failWithError:
         [NSError errorWithDomain:FSNConnectionErrorDomain
                             code:0
                         userInfo:[NSDictionary dictionaryWithObject:@"request cannot be handled"
                                                              forKey:@"description"]]];
        return nil;
    }
    
    // initWithRequest semantics: url request is deep-copied; connection is started on current thread
    // TODO: determine if this deep-copy is problematic for large POST bodies
    self.connection = [[[NSURLConnection alloc] initWithRequest:urlRequest
                                                       delegate:self
                                               startImmediately:NO] autorelease];
    
    if (!self.connection) {
        
        [self failWithError:
         [NSError errorWithDomain:FSNConnectionErrorDomain
                             code:0
                         userInfo:[NSDictionary dictionaryWithObject:@"could not establish connection"
                                                              forKey:@"description"]]];
        return nil;
    }
    
#if FSN_QUEUED_CONNECTIONS
    [self.connection setDelegateQueue:[self.class queue]];
#else
    [self.connection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
#endif
    
    [self.connection start];
    
    return self;
}


- (void)cancel {
    
    FSNVerbose(@"%p: cancel", self);
    
    [self cancelConnection];
    [self cleanup]; // release blocks and background task identifier immediately
}


// MARK: background task


#if TARGET_OS_IPHONE

// ending the background task is critical to prevent the os from killing our app,
// and to prevent the application from retaining the request via the expiration handler block
- (void)endBackgroundTask {
    if (self.taskIdentifier != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.taskIdentifier]; // may cause self dealloc
        self.taskIdentifier = UIBackgroundTaskInvalid; // zero the property so that we pass the assertion in dealloc
    }
}


// called by the expiration handler block
- (void)didExpireInBackground {
    ASSERT_MAIN_THREAD; // according to beginBackgroundTaskWithExpirationHandler
    
    [self retain];
    [self cancelConnection]; // releases delegate (self)
    
    [self failWithError:
     [NSError errorWithDomain:FSNConnectionErrorDomain
                         code:FSNConnectionErrorCodeExpiredInBackgroundTask
                     userInfo:[NSDictionary dictionaryWithObject:@"expired in background task" forKey:@"description"]]];
    
    [self release];
}

#endif


// MARK: progress


- (int)downloadProgressBytes {
    return self.responseData.length;
}


- (int)downloadExpectedBytes {
    long long length = self.response.expectedContentLength;
    if (length > INT_MAX) {
        FSNLog(@"downloadExpectedBytes: huge value: %lld", length);
        return -1;
    }
    return length;
}


- (float)uploadProgress {
    if (self.uploadExpectedBytes < 1 || self.uploadProgressBytes > self.uploadExpectedBytes) return -1;
    return (float)self.uploadProgressBytes / (float)self.uploadExpectedBytes;
}


- (float)downloadProgress {
    if (self.downloadExpectedBytes < 1 || self.downloadProgressBytes > self.downloadExpectedBytes) return -1;
    return (float)self.downloadProgressBytes / (float)self.downloadExpectedBytes;
}


- (void)performReportProgress {
    [self performSelectorOnMainThread:@selector(reportProgress) withObject:nil waitUntilDone:NO];    
}


- (void)reportProgress {
    ASSERT_MAIN_THREAD;
    [self.blocksLock lock];
    if (self.progressBlock) {
        self.progressBlock(self);
    }
    [self.blocksLock unlock];
}


// MARK: request construction


- (NSString *)makeRequestString {
    
    if (self.method != FSNRequestMethodGET || !self.parameters.count) {
        return self.url.absoluteString;
    }
    
    return [NSString stringWithFormat:@"%@?%@", self.url.absoluteString, self.parameters.urlQueryString];
}


- (NSData*)makePostBodyWithBoundary:(NSString*)boundary {
    NSAssert1(self.method == FSNRequestMethodPOST, @"wrong method: %d", self.method);
    
    NSMutableData *data = [NSMutableData data];
    
    NSData *prefix = [[NSString stringWithFormat:@"--%@\r\n", boundary] UTF8Data];
    NSData *sep = [@"\r\n" UTF8Data];
    
    for (id key in self.parameters) {
        id val = [self.parameters objectForKey:key];
        
        if (![key isKindOfClass:[NSString class]]) {
            FSNLogError(@"skipping bad parameter key: key class: %@ key: %@", [key class], key);
            NSAssert(0, @"bad parameter key type");
            continue;
        }
        
        NSString *typeString = nil;
        NSString *fileName = nil;
        NSData *valData = nil;
        
        if ([val isKindOfClass:[NSString class]] || [val isKindOfClass:[NSNumber class]]) {
            // webkit does not specify a type for plain text strings, so we don't either
            //valType = @"text/plain; charset=\"UTF-8\"";
            valData = [[val description] UTF8Data];
        }
        else if ([val isKindOfClass:[FSNData class]]) {
            typeString  = [val mimeTypeString];
            valData     = [val data];
            fileName    = [val fileName];
        }
        else {
            FSNLogError(@"skipping bad POST parameter value: key: %@; value class: %@; value: %@",
                        key, [val class], val);
            NSAssert(0, @"bad POST parameter value type");
            continue;
        }
        
        [data appendData:prefix];
        
        NSString *fileNameClause = fileName ? [NSString stringWithFormat:@"; filename=\"%@\"", fileName] : @"";
        
        [data appendData:
         [[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"%@\r\n", key, fileNameClause]
          UTF8Data]];
        
        if (typeString) {
            [data appendData:[[NSString stringWithFormat:@"Content-Type: %@\r\n", typeString] UTF8Data]]; 
        }
        
        [data appendData:sep];
        [data appendData:valData];
        [data appendData:sep];
        [data appendData:sep];
    }
    
    [data appendData:[[NSString stringWithFormat:@"--%@--\r\n\r\n", boundary] UTF8Data]];
    
#if FSN_LOG_POST_DATA
    FSNErr(@"  POST data:\n%@\n", [data debugString]);
#endif
    
    return data;
}


void logParameter(FSNRequestMethod method, id key, id val) {
    switch (method) {
#if !FSN_LOG_GET_PARAMETERS
        case FSNRequestMethodGET: break;
#endif
#if !FSN_LOG_POST_PARAMETERS
        case FSNRequestMethodPOST: break;
#endif
        default:
            FSNErr(@"  %-16s : %@", [[key description] UTF8String], val);
    }
}


// creates an NSURLRequest with which to create an NSURLConnection
- (NSURLRequest*)makeNSURLRequest {
    
    NSString *requestString = [self makeRequestString];
    NSURL *url = [[[NSURL alloc] initWithString:requestString] autorelease];
    NSMutableURLRequest* r = [NSMutableURLRequest requestWithURL:url];
    
    // always pipeline (could be changed to be an ifdef or instance property).
    [r setHTTPShouldUsePipelining:YES];
    
#if FSN_LOG_REQUESTS
    FSNLog(@"%@: %@", stringForRequestMethod(self.method), requestString);
    
    [self.parameters enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        logParameter(_method, k, v);
    }];
#endif
    
    [r setHTTPMethod:stringForRequestMethod(self.method)];
    
#if FSN_LOG_HEADERS
#define SET_HEADER(k, v) \
FSNErr(@"- header: %-16s : %@", [k UTF8String], v); [r setValue:v forHTTPHeaderField:k];
#else
#define SET_HEADER(k, v) [r setValue:v forHTTPHeaderField:k];
#endif
    
    switch (self.method) {
            
        case FSNRequestMethodGET:
            break; // no body
            
        case FSNRequestMethodPOST: {
            
            // decide if this request needs to be multipart
            BOOL multipart = NO;
            for (id k in self.parameters) {
                if ([[self.parameters valueForKey:k] isKindOfClass:[FSNData class]]) {
                    multipart = YES;
                    break;
                }
            };
            
            NSData *body;
            NSString *contentType;
            
            if (multipart) {
                // choose a random string boundary and hope it never collides with form data
                // this is what web browsers do for form requests (we use our own unique boundary)
                NSString *boundary = @"--FSN-POST-boundary-wXzBVZAKUhpccuA9";
                body = [self makePostBodyWithBoundary:boundary];
                contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary];
            }
            else { // UTF8, url-encoded body
                NSString *s = self.parameters.urlQueryString;
                body = [s UTF8Data];
                contentType = @"application/x-www-form-urlencoded";
            }
            
            NSString *contentLength = [NSString stringWithFormat:@"%u", body.length];
            
            SET_HEADER(@"Content-Type", contentType);
            SET_HEADER(@"Content-Length", contentLength);
            
            [r setHTTPBody:body];
            break;
        }
            
        default:
            [NSException raise:@"FSNConnectionException" format:@"unknown request method: %d", self.method];
    }
    
    // do this last for more readable header logging (so these are grouped with the conditional headers in the switch)
    for (NSString* k in self.headers) {
        NSString* v = [self.headers objectForKey:k];
        SET_HEADER(k, v);
    }
    
    return r;
}


@end
