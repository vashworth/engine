// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#define FML_USED_ON_EMBEDDER

#import "FlutterObservatoryPublisher.h"

#include <arpa/inet.h>
#include <netdb.h>

#if FLUTTER_RELEASE

@implementation FlutterObservatoryPublisher
- (instancetype)initWithEnableObservatoryPublication:(BOOL)enableObservatoryPublication
                               withWirelessDebugging:(BOOL)isWirelessDebugging {
  return [super init];
}
@end

#else  // FLUTTER_RELEASE

#import <TargetConditionals.h>
// NSNetService works fine on physical devices before iOS 13.2.
// However, it doesn't expose the services to regular mDNS
// queries on the Simulator or on iOS 13.2+ devices.
//
// When debugging issues with this implementation, the following is helpful:
//
// 1) Running `dns-sd -Z _dartobservatory`. This is a built-in macOS tool that
//    can find advertized observatories using this method. If dns-sd can't find
//    it, then the observatory is not getting advertized over any network
//    interface that the host machine has access to.
// 2) The Python zeroconf package. The dns-sd tool can sometimes see things
//    that aren't advertizing over a network interface - for example, simulators
//    using NSNetService has been observed using dns-sd, but doesn't show up in
//    the Python package (which is a high quality socket based implementation).
//    If that happens, this code should be tweaked such that it shows up in both
//    dns-sd's output and Python zeroconf's detection.
// 3) The Dart multicast_dns package, which is what Flutter uses to find the
//    port and auth code. If the advertizement shows up in dns-sd and Python
//    zeroconf but not multicast_dns, then it is a bug in multicast_dns.
#include <dns_sd.h>
#include <net/if.h>

#include "flutter/fml/logging.h"
#include "flutter/fml/memory/weak_ptr.h"
#include "flutter/fml/message_loop.h"
#include "flutter/fml/platform/darwin/scoped_nsobject.h"
#include "flutter/runtime/dart_service_isolate.h"

@protocol FlutterObservatoryPublisherDelegate
- (void)publishServiceProtocolPort:(NSURL*)uri;
- (void)stopService;
@end

@interface FlutterObservatoryPublisher ()
+ (NSData*)createTxtData:(NSURL*)url;

@property(readonly, class) NSString* serviceName;
@property(readonly) fml::scoped_nsobject<NSObject<FlutterObservatoryPublisherDelegate>> delegate;
@property(nonatomic, readwrite) NSURL* url;
@property(readonly) BOOL enableObservatoryPublication;

@end

@interface ObservatoryDNSServiceDelegate : NSObject <FlutterObservatoryPublisherDelegate>
@end

@implementation ObservatoryDNSServiceDelegate {
  DNSServiceRef _dnsRegisterServiceRef;
  DNSServiceRef _dnsResolveServiceRef;
  BOOL _isWirelessDebugging;
}

- (instancetype)initWithIsWirelessDebugging:(BOOL)isWirelessDebugging {
  self = [super init];
  NSAssert(self, @"Super must not return null on init.");
  _isWirelessDebugging = isWirelessDebugging;
  return self;
}

- (void)stopService {
  if (_dnsResolveServiceRef) {
    DNSServiceRefDeallocate(_dnsResolveServiceRef);
    _dnsResolveServiceRef = NULL;
  }
  if (_dnsRegisterServiceRef) {
    DNSServiceRefDeallocate(_dnsRegisterServiceRef);
    _dnsRegisterServiceRef = NULL;
  }
}

- (void)publishServiceProtocolPort:(NSURL*)url {
  DNSServiceFlags flags = kDNSServiceFlagsDefault;
#if TARGET_IPHONE_SIMULATOR
  // Simulator needs to use local loopback explicitly to work.
  uint32_t interfaceIndex = if_nametoindex("lo0");
#else   // TARGET_IPHONE_SIMULATOR
  // Physical devices need to request all interfaces.
  uint32_t interfaceIndex = 0;
#endif  // TARGET_IPHONE_SIMULATOR
  const char* registrationType = "_dartobservatory._tcp";
  const char* domain = "local.";  // default domain
  uint16_t port = [[url port] unsignedShortValue];

  NSData* txtData = [FlutterObservatoryPublisher createTxtData:url];
  DNSServiceErrorType err = DNSServiceRegister(
      &_dnsRegisterServiceRef, flags, interfaceIndex,
      FlutterObservatoryPublisher.serviceName.UTF8String, registrationType, domain, NULL,
      htons(port), txtData.length, txtData.bytes, RegistrationCallback, (void*)self);

  if (err != kDNSServiceErr_NoError) {
    FML_LOG(ERROR) << "Failed to register observatory port with mDNS with error " << err << ".";
    if (@available(iOS 14.0, *)) {
      FML_LOG(ERROR) << "On iOS 14+, local network broadcast in apps need to be declared in "
                     << "the app's Info.plist. Debug and profile Flutter apps and modules host "
                     << "VM services on the local network to support debugging features such "
                     << "as hot reload and DevTools. To make your Flutter app or module "
                     << "attachable and debuggable, add a '" << registrationType << "' value "
                     << "to the 'NSBonjourServices' key in your Info.plist for the Debug/"
                     << "Profile configurations. "
                     << "For more information, see "
                     << "https://flutter.dev/docs/development/add-to-app/ios/"
                        "project-setup#local-network-privacy-permissions";
    }
  } else {
    DNSServiceSetDispatchQueue(_dnsRegisterServiceRef, dispatch_get_main_queue());
  }
}

static void DNSSD_API RegistrationCallback(DNSServiceRef sdRef,
                                           DNSServiceFlags flags,
                                           DNSServiceErrorType errorCode,
                                           const char* name,
                                           const char* regType,
                                           const char* domain,
                                           void* context) {
  if (errorCode == kDNSServiceErr_NoError) {
    FML_DLOG(INFO) << "FlutterObservatoryPublisher is ready!";

    ObservatoryDNSServiceDelegate* observatoryDelegate = (ObservatoryDNSServiceDelegate*)context;

    // Resolve the service to get the IP (which is needed for iOS wireless debugging).
    if (observatoryDelegate->_isWirelessDebugging) {
      DNSServiceErrorType err =
          DNSServiceResolve(&observatoryDelegate->_dnsResolveServiceRef, flags, 0, name, regType,
                            domain, ResolveCallback, context);
      if (err != kDNSServiceErr_NoError) {
        FML_LOG(ERROR) << "Failed to resolve service with mDNS with error " << err << ".";
        if (@available(iOS 14.0, *)) {
          FML_LOG(ERROR) << "On iOS 14+, local network broadcast in apps need to be declared in "
                         << "the app's Info.plist. Debug and profile Flutter apps and modules host "
                         << "VM services on the local network to support debugging features such "
                         << "as hot reload and DevTools. To make your Flutter app or module "
                         << "attachable and debuggable, add a '" << regType << "' value "
                         << "to the 'NSBonjourServices' key in your Info.plist for the Debug/"
                         << "Profile configurations. "
                         << "For more information, see "
                         << "https://flutter.dev/docs/development/add-to-app/ios/"
                            "project-setup#local-network-privacy-permissions";
        }
      } else {
        DNSServiceSetDispatchQueue(observatoryDelegate->_dnsResolveServiceRef,
                                   dispatch_get_main_queue());
      }
    }
  } else if (errorCode == kDNSServiceErr_PolicyDenied) {
    FML_LOG(ERROR)
        << "Could not register as server for FlutterObservatoryPublisher, permission "
        << "denied. Check your 'Local Network' permissions for this app in the Privacy section of "
        << "the system Settings.";
  } else {
    FML_LOG(ERROR) << "Could not register as server for FlutterObservatoryPublisher. Check your "
                      "network settings and relaunch the application.";
  }
}

static void DNSSD_API ResolveCallback(DNSServiceRef sdRef,
                                      DNSServiceFlags flags,
                                      uint32_t interfaceIndex,
                                      DNSServiceErrorType errorCode,
                                      const char* fullname,
                                      const char* hosttarget,
                                      uint16_t port,
                                      uint16_t txtLen,
                                      const unsigned char* txtRecord,
                                      void* context) {
  if (errorCode == kDNSServiceErr_NoError) {
    struct hostent* hostentry = gethostbyname(hosttarget);
    if (hostentry != nil) {
      char** addressList = hostentry->h_addr_list;
      for (char* address = *addressList; address; address = *++addressList) {
        if (hostentry->h_addrtype == AF_INET) {
          // Convert IPv4 address from binary to string and log it for the tool to find.
          struct in_addr* addressBinary = (struct in_addr*)address;
          char ipAddress[INET_ADDRSTRLEN];
          inet_ntop(AF_INET, addressBinary, ipAddress, INET_ADDRSTRLEN);
          if (![[NSString stringWithUTF8String:ipAddress] isEqualToString:@"127.0.0.1"]) {
            NSLog(@"Resolved IP Address is %s", ipAddress);
          }
        } else if (hostentry->h_addrtype == AF_INET6) {
          // Convert IPv6 address from binary to string and log it for the tool to find.
          struct in6_addr* addressBinary = (struct in6_addr*)address;
          char ipAddress[INET6_ADDRSTRLEN];
          inet_ntop(AF_INET6, addressBinary, ipAddress, INET6_ADDRSTRLEN);
          if (![[NSString stringWithUTF8String:ipAddress] isEqualToString:@"127.0.0.1"]) {
            NSLog(@"Resolved IP Address is %s", ipAddress);
          }
        }
      }
    }
  } else if (errorCode == kDNSServiceErr_PolicyDenied) {
    FML_LOG(ERROR)
        << "Could not resolve the service for FlutterObservatoryPublisher, permission "
        << "denied. Check your 'Local Network' permissions for this app in the Privacy section of "
        << "the system Settings.";
  } else {
    FML_LOG(ERROR) << "Could not resolve the service for FlutterObservatoryPublisher. Check your "
                      "network settings and relaunch the application.";
  }
  DNSServiceRefDeallocate(sdRef);
}

@end

@implementation FlutterObservatoryPublisher {
  flutter::DartServiceIsolate::CallbackHandle _callbackHandle;
  std::unique_ptr<fml::WeakPtrFactory<FlutterObservatoryPublisher>> _weakFactory;
}

- (instancetype)initWithEnableObservatoryPublication:(BOOL)enableObservatoryPublication
                               withWirelessDebugging:(BOOL)isWirelessDebugging {
  self = [super init];
  NSAssert(self, @"Super must not return null on init.");

  _delegate.reset(
      [[ObservatoryDNSServiceDelegate alloc] initWithIsWirelessDebugging:isWirelessDebugging]);
  _enableObservatoryPublication = enableObservatoryPublication;
  _weakFactory = std::make_unique<fml::WeakPtrFactory<FlutterObservatoryPublisher>>(self);

  fml::MessageLoop::EnsureInitializedForCurrentThread();

  _callbackHandle = flutter::DartServiceIsolate::AddServerStatusCallback(
      [weak = _weakFactory->GetWeakPtr(),
       runner = fml::MessageLoop::GetCurrent().GetTaskRunner()](const std::string& uri) {
        if (!uri.empty()) {
          runner->PostTask([weak, uri]() {
            // uri comes in as something like 'http://127.0.0.1:XXXXX/' where XXXXX is the port
            // number.
            if (weak) {
              NSURL* url = [[[NSURL alloc]
                  initWithString:[NSString stringWithUTF8String:uri.c_str()]] autorelease];
              weak.get().url = url;
              if (weak.get().enableObservatoryPublication) {
                [[weak.get() delegate] publishServiceProtocolPort:url];
              }
            }
          });
        }
      });

  return self;
}

+ (NSString*)serviceName {
  return NSBundle.mainBundle.bundleIdentifier;
}

+ (NSData*)createTxtData:(NSURL*)url {
  // Check to see if there's an authentication code. If there is, we'll provide
  // it as a txt record so flutter tools can establish a connection.
  NSString* path = [[url path] substringFromIndex:MIN(1, [[url path] length])];
  NSData* pathData = [path dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary<NSString*, NSData*>* txtDict = @{
    @"authCode" : pathData,
  };
  return [NSNetService dataFromTXTRecordDictionary:txtDict];
}

- (void)dealloc {
  // It will be destroyed and invalidate its weak pointers
  // before any other members are destroyed.
  _weakFactory.reset();

  [_delegate stopService];
  [_url release];

  flutter::DartServiceIsolate::RemoveServerStatusCallback(_callbackHandle);
  [super dealloc];
}
@end

#endif  // FLUTTER_RELEASE
