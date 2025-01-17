/*
 * Copyright (c) 2017 Apple Inc. All Rights Reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 *
 * @APPLE_LICENSE_HEADER_END@
 */

#if OCTAGON

#import <OCMock/OCMock.h>

#import "keychain/ckks/tests/CloudKitMockXCTest.h"
#import "keychain/ckks/tests/CloudKitKeychainSyncingMockXCTest.h"

#import "keychain/securityd/SecItemServer.h"
#import "keychain/securityd/SecItemDb.h"

#import "keychain/ckks/CKKS.h"
#import "keychain/ckks/CKKSKeychainView.h"
#import "keychain/ckks/CKKSCurrentKeyPointer.h"
#import "keychain/ckks/CKKSItemEncrypter.h"
#import "keychain/ckks/CKKSKey.h"
#import "keychain/ckks/CKKSOutgoingQueueEntry.h"
#import "keychain/ckks/CKKSIncomingQueueEntry.h"
#import "keychain/ckks/CKKSSynchronizeOperation.h"
#import "keychain/ckks/CKKSViewManager.h"
#import "keychain/ckks/CKKSZoneStateEntry.h"
#import "keychain/ckks/CKKSManifest.h"
#import "keychain/ckks/CKKSPeer.h"
#import "keychain/categories/NSError+UsefulConstructors.h"

#import "keychain/ot/OTDefines.h"

#import "tests/secdmockaks/mockaks.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#import "keychain/SecureObjectSync/SOSAccount.h"
#pragma clang diagnostic pop

@implementation ZoneKeys
- (instancetype)initLoadingRecordsFromZone:(FakeCKZone*)zone {
    if((self = [super init])) {
        CKRecordID* currentTLKPointerID    = [[CKRecordID alloc] initWithRecordName:SecCKKSKeyClassTLK zoneID:zone.zoneID];
        CKRecordID* currentClassAPointerID = [[CKRecordID alloc] initWithRecordName:SecCKKSKeyClassA   zoneID:zone.zoneID];
        CKRecordID* currentClassCPointerID = [[CKRecordID alloc] initWithRecordName:SecCKKSKeyClassC   zoneID:zone.zoneID];

        CKRecord* currentTLKPointerRecord    = zone.currentDatabase[currentTLKPointerID];
        CKRecord* currentClassAPointerRecord = zone.currentDatabase[currentClassAPointerID];
        CKRecord* currentClassCPointerRecord = zone.currentDatabase[currentClassCPointerID];

        self.currentTLKPointer    = currentTLKPointerRecord ?    [[CKKSCurrentKeyPointer alloc] initWithCKRecord: currentTLKPointerRecord] : nil;
        self.currentClassAPointer = currentClassAPointerRecord ? [[CKKSCurrentKeyPointer alloc] initWithCKRecord: currentClassAPointerRecord] : nil;
        self.currentClassCPointer = currentClassCPointerRecord ? [[CKKSCurrentKeyPointer alloc] initWithCKRecord: currentClassCPointerRecord] : nil;

        CKRecordID* currentTLKID    = self.currentTLKPointer.currentKeyUUID    ? [[CKRecordID alloc] initWithRecordName:self.currentTLKPointer.currentKeyUUID    zoneID:zone.zoneID] : nil;
        CKRecordID* currentClassAID = self.currentClassAPointer.currentKeyUUID ? [[CKRecordID alloc] initWithRecordName:self.currentClassAPointer.currentKeyUUID zoneID:zone.zoneID] : nil;
        CKRecordID* currentClassCID = self.currentClassCPointer.currentKeyUUID ? [[CKRecordID alloc] initWithRecordName:self.currentClassCPointer.currentKeyUUID zoneID:zone.zoneID] : nil;

        CKRecord* currentTLKRecord    = currentTLKID    ? zone.currentDatabase[currentTLKID]    : nil;
        CKRecord* currentClassARecord = currentClassAID ? zone.currentDatabase[currentClassAID] : nil;
        CKRecord* currentClassCRecord = currentClassCID ? zone.currentDatabase[currentClassCID] : nil;

        self.tlk =    currentTLKRecord ?    [[CKKSKey alloc] initWithCKRecord: currentTLKRecord]    : nil;
        self.classA = currentClassARecord ? [[CKKSKey alloc] initWithCKRecord: currentClassARecord] : nil;
        self.classC = currentClassCRecord ? [[CKKSKey alloc] initWithCKRecord: currentClassCRecord] : nil;
    }
    return self;
}

@end

// No tests here, just helper functions
@implementation CloudKitKeychainSyncingMockXCTest

- (void)setUp {
    // Need to convince your tests to set these, no matter what the on-disk plist says? Uncomment.
    (void)[CKKSManifest shouldSyncManifests]; // perfrom initialization
    SecCKKSSetSyncManifests(false);
    SecCKKSSetEnforceManifests(false);

    // Check that your environment is set up correctly
    XCTAssertFalse([CKKSManifest shouldSyncManifests], "Manifests syncing is disabled");
    XCTAssertFalse([CKKSManifest shouldEnforceManifests], "Manifests enforcement is disabled");

    // Use our superclass to create a fake keychain
    [super setUp];

    self.automaticallyBeginCKKSViewCloudKitOperation = true;
    self.suggestTLKUpload = OCMClassMock([CKKSNearFutureScheduler class]);
    OCMStub([self.suggestTLKUpload trigger]);

    // If a subclass wants to fill these in before calling setUp, fine.
    self.ckksZones = self.ckksZones ?: [NSMutableSet set];
    self.ckksViews = self.ckksViews ?: [NSMutableSet set];
    self.keys = self.keys ?: [[NSMutableDictionary alloc] init];

    [SecMockAKS reset];

    // Set up a remote peer with no keys
    self.remoteSOSOnlyPeer = [[CKKSSOSPeer alloc] initWithSOSPeerID:@"remote-peer-with-no-keys"
                                                encryptionPublicKey:nil
                                                   signingPublicKey:nil
                                                           viewList:self.managedViewList];
    NSMutableSet<id<CKKSSOSPeerProtocol>>* currentPeers = [NSMutableSet setWithObject:self.remoteSOSOnlyPeer];
    self.mockSOSAdapter.trustedPeers = currentPeers;

    // Fake out whether class A keys can be loaded from the keychain.
    self.mockCKKSKeychainBackedKey = OCMClassMock([CKKSKeychainBackedKey class]);
    __weak __typeof(self) weakSelf = self;
    BOOL (^shouldFailKeychainQuery)(NSDictionary* query) = ^BOOL(NSDictionary* query) {
        __strong __typeof(self) strongSelf = weakSelf;
        return !!strongSelf.keychainFetchError;
    };

    OCMStub([self.mockCKKSKeychainBackedKey setKeyMaterialInKeychain:[OCMArg checkWithBlock:shouldFailKeychainQuery] error:[OCMArg anyObjectRef]]
            ).andCall(self, @selector(handleFailedSetKeyMaterialInKeychain:error:));

    OCMStub([self.mockCKKSKeychainBackedKey queryKeyMaterialInKeychain:[OCMArg checkWithBlock:shouldFailKeychainQuery] error:[OCMArg anyObjectRef]]
            ).andCall(self, @selector(handleFailedLoadKeyMaterialFromKeychain:error:));

    // Bring up a fake CKKSControl object
    id mockConnection = OCMPartialMock([[NSXPCConnection alloc] init]);
    OCMStub([mockConnection remoteObjectProxyWithErrorHandler:[OCMArg any]]).andCall(self, @selector(injectedManager));
    self.ckksControl = [[CKKSControl alloc] initWithConnection:mockConnection];
    XCTAssertNotNil(self.ckksControl, "Should have received control object");

    self.accountMetaDataStore = OCMPartialMock([[OTCuttlefishAccountStateHolder alloc]init]);
    OCMStub([self.accountMetaDataStore loadOrCreateAccountMetadata:[OCMArg anyObjectRef]]).andCall(self, @selector(loadOrCreateAccountMetadata:));
}

- (void)tearDown {
    // Make sure the key state machine won't be poked after teardown
    for(CKKSKeychainView* view in self.ckksViews) {
        [view.pokeKeyStateMachineScheduler cancel];
    }
    [self.ckksViews removeAllObjects];

    [super tearDown];
    self.keys = nil;

    [self.mockCKKSKeychainBackedKey stopMocking];
    self.mockCKKSKeychainBackedKey = nil;

    [((id)self.accountMetaDataStore) stopMocking];

    self.remoteSOSOnlyPeer = nil;
}

- (void)startCKKSSubsystem
{
    [super startCKKSSubsystem];
    if(self.mockSOSAdapter.circleStatus == kSOSCCInCircle) {
        [self beginSOSTrustedOperationForAllViews];
    } else {
        [self endSOSTrustedOperationForAllViews];
    }
}

- (void)beginSOSTrustedOperationForAllViews {
    for(CKKSKeychainView* view in self.ckksViews) {
        [self beginSOSTrustedViewOperation:view];
    }
}

- (void)beginSOSTrustedViewOperation:(CKKSKeychainView*)view
{
    if(self.automaticallyBeginCKKSViewCloudKitOperation) {
        [view beginCloudKitOperation];
    }

    [view beginTrustedOperation:@[self.mockSOSAdapter] suggestTLKUpload:self.suggestTLKUpload];
}

- (void)endSOSTrustedOperationForAllViews {
    for(CKKSKeychainView* view in self.ckksViews) {
        [self endSOSTrustedViewOperation:view];
    }
}

- (void)endSOSTrustedViewOperation:(CKKSKeychainView*)view
{
    if(self.automaticallyBeginCKKSViewCloudKitOperation) {
        [view beginCloudKitOperation];
    }
    [view endTrustedOperation];
}

- (void)verifyDatabaseMocks {
    OCMVerifyAllWithDelay(self.mockDatabase, 20);
    [self waitForCKModifications];
}

- (void)createClassCItemAndWaitForUpload:(CKRecordZoneID*)zoneID account:(NSString*)account {
    [self expectCKModifyItemRecords:1
           currentKeyPointerRecords:1
                             zoneID:zoneID
                          checkItem:[self checkClassCBlock:zoneID message:@"Object was encrypted under class C key in hierarchy"]];
    [self addGenericPassword: @"data" account: account];
    OCMVerifyAllWithDelay(self.mockDatabase, 20);
}

- (void)createClassAItemAndWaitForUpload:(CKRecordZoneID*)zoneID account:(NSString*)account {
    [self expectCKModifyItemRecords:1
           currentKeyPointerRecords:1
                             zoneID:zoneID
                          checkItem: [self checkClassABlock:zoneID message:@"Object was encrypted under class A key in hierarchy"]];
    [self addGenericPassword:@"asdf"
                     account:account
                    viewHint:nil
                      access:(id)kSecAttrAccessibleWhenUnlocked
                   expecting:errSecSuccess
                     message:@"Adding class A item"];
    OCMVerifyAllWithDelay(self.mockDatabase, 20);
}

// Helpers to handle 'failed' keychain loading and saving
- (bool)handleFailedLoadKeyMaterialFromKeychain:(NSDictionary*)query error:(NSError * __autoreleasing *) error {
    NSAssert(self.keychainFetchError != nil, @"must have a keychain error to error with");

    if(error) {
        *error = self.keychainFetchError;
    }
    return false;
}

- (bool)handleFailedSetKeyMaterialInKeychain:(NSDictionary*)query error:(NSError * __autoreleasing *) error {
    NSAssert(self.keychainFetchError != nil, @"must have a keychain error to error with");

    if(error) {
        *error = self.keychainFetchError;
    }
    return false;
}


- (ZoneKeys*)createFakeKeyHierarchy: (CKRecordZoneID*)zoneID oldTLK:(CKKSKey*) oldTLK {
    if(self.keys[zoneID]) {
        // Already created. Skip.
        return self.keys[zoneID];
    }

    NSError* error = nil;

    ZoneKeys* zonekeys = [[ZoneKeys alloc] init];

    zonekeys.tlk = [self fakeTLK:zoneID];
    [zonekeys.tlk CKRecordWithZoneID: zoneID]; // no-op here, but memoize in the object
    zonekeys.currentTLKPointer = [[CKKSCurrentKeyPointer alloc] initForClass: SecCKKSKeyClassTLK currentKeyUUID: zonekeys.tlk.uuid zoneID:zoneID encodedCKRecord: nil];
    [zonekeys.currentTLKPointer CKRecordWithZoneID: zoneID];

    if(oldTLK) {
        zonekeys.rolledTLK = oldTLK;
        [zonekeys.rolledTLK wrapUnder: zonekeys.tlk error:&error];
        XCTAssertNotNil(zonekeys.rolledTLK, "Created a rolled TLK");
        XCTAssertNil(error, "No error creating rolled TLK");
    }

    zonekeys.classA = [CKKSKey randomKeyWrappedByParent: zonekeys.tlk keyclass:SecCKKSKeyClassA error:&error];
    XCTAssertNotNil(zonekeys.classA, "make Class A key");
    zonekeys.classA.currentkey = true;
    [zonekeys.classA CKRecordWithZoneID: zoneID];
    zonekeys.currentClassAPointer = [[CKKSCurrentKeyPointer alloc] initForClass: SecCKKSKeyClassA currentKeyUUID: zonekeys.classA.uuid zoneID:zoneID encodedCKRecord: nil];
    [zonekeys.currentClassAPointer CKRecordWithZoneID: zoneID];

    zonekeys.classC = [CKKSKey randomKeyWrappedByParent: zonekeys.tlk keyclass:SecCKKSKeyClassC error:&error];
    XCTAssertNotNil(zonekeys.classC, "make Class C key");
    zonekeys.classC.currentkey = true;
    [zonekeys.classC CKRecordWithZoneID: zoneID];
    zonekeys.currentClassCPointer = [[CKKSCurrentKeyPointer alloc] initForClass: SecCKKSKeyClassC currentKeyUUID: zonekeys.classC.uuid zoneID:zoneID encodedCKRecord: nil];
    [zonekeys.currentClassCPointer CKRecordWithZoneID: zoneID];

    self.keys[zoneID] = zonekeys;
    return zonekeys;
}

- (void)saveFakeKeyHierarchyToLocalDatabase: (CKRecordZoneID*)zoneID {
    NSError* error = nil;
    ZoneKeys* zonekeys = [self createFakeKeyHierarchy: zoneID oldTLK:nil];

    [zonekeys.tlk saveToDatabase:&error];
    XCTAssertNil(error, "TLK saved to database successfully");

    [zonekeys.classA saveToDatabase:&error];
    XCTAssertNil(error, "Class A key saved to database successfully");

    [zonekeys.classC saveToDatabase:&error];
    XCTAssertNil(error, "Class C key saved to database successfully");

    [zonekeys.currentTLKPointer saveToDatabase:&error];
    XCTAssertNil(error, "Current TLK pointer saved to database successfully");

    [zonekeys.currentClassAPointer saveToDatabase:&error];
    XCTAssertNil(error, "Current Class A pointer saved to database successfully");

    [zonekeys.currentClassCPointer saveToDatabase:&error];
    XCTAssertNil(error, "Current Class C pointer saved to database successfully");
}

- (void)putFakeDeviceStatusInCloudKit:(CKRecordZoneID*)zoneID zonekeys:(ZoneKeys*)zonekeys {
    // SOS peer IDs are written bare, missing the CKKSSOSPeerPrefix. Strip it here.
    NSString* peerID = self.remoteSOSOnlyPeer.peerID;
    if([peerID hasPrefix:CKKSSOSPeerPrefix]) {
        peerID = [peerID substringFromIndex:CKKSSOSPeerPrefix.length];
    }

    CKKSDeviceStateEntry* dse = [[CKKSDeviceStateEntry alloc] initForDevice:self.remoteSOSOnlyPeer.peerID
                                                                  osVersion:@"faux-version"
                                                             lastUnlockTime:nil
                                                              octagonPeerID:nil
                                                              octagonStatus:nil
                                                               circlePeerID:peerID
                                                               circleStatus:kSOSCCInCircle
                                                                   keyState:SecCKKSZoneKeyStateReady
                                                             currentTLKUUID:zonekeys.tlk.uuid
                                                          currentClassAUUID:zonekeys.classA.uuid
                                                          currentClassCUUID:zonekeys.classC.uuid
                                                                     zoneID:zoneID
                                                            encodedCKRecord:nil];
    [self.zones[zoneID] addToZone:dse zoneID:zoneID];
}

- (void)putFakeDeviceStatusInCloudKit:(CKRecordZoneID*)zoneID {
    [self putFakeDeviceStatusInCloudKit:zoneID zonekeys:self.keys[zoneID]];
}

- (void)putFakeOctagonOnlyDeviceStatusInCloudKit:(CKRecordZoneID*)zoneID zonekeys:(ZoneKeys*)zonekeys {
    CKKSDeviceStateEntry* dse = [[CKKSDeviceStateEntry alloc] initForDevice:self.remoteSOSOnlyPeer.peerID
                                                                  osVersion:@"faux-version"
                                                             lastUnlockTime:nil
                                                              octagonPeerID:@"octagon-fake-peer-id"
                                                              octagonStatus:[[OTCliqueStatusWrapper alloc] initWithStatus:CliqueStatusIn]
                                                               circlePeerID:nil
                                                               circleStatus:kSOSCCError
                                                                   keyState:SecCKKSZoneKeyStateReady
                                                             currentTLKUUID:zonekeys.tlk.uuid
                                                          currentClassAUUID:zonekeys.classA.uuid
                                                          currentClassCUUID:zonekeys.classC.uuid
                                                                     zoneID:zoneID
                                                            encodedCKRecord:nil];
    [self.zones[zoneID] addToZone:dse zoneID:zoneID];
}

- (void)putFakeOctagonOnlyDeviceStatusInCloudKit:(CKRecordZoneID*)zoneID {
    [self putFakeOctagonOnlyDeviceStatusInCloudKit:zoneID zonekeys:self.keys[zoneID]];
}

- (void)putFakeKeyHierarchyInCloudKit: (CKRecordZoneID*)zoneID {
    ZoneKeys* zonekeys = [self createFakeKeyHierarchy: zoneID oldTLK:nil];
    XCTAssertNotNil(zonekeys, "failed to create fake key hierarchy for zoneID=%@", zoneID);
    XCTAssertNil(zonekeys.error, "should have no error creating a zonekeys");

    secnotice("fake-cloudkit", "new fake hierarchy: %@", zonekeys);

    FakeCKZone* zone = self.zones[zoneID];
    XCTAssertNotNil(zone, "failed to find zone %@", zoneID);

    dispatch_sync(zone.queue, ^{
        [zone _onqueueAddToZone:zonekeys.tlk    zoneID:zoneID];
        [zone _onqueueAddToZone:zonekeys.classA zoneID:zoneID];
        [zone _onqueueAddToZone:zonekeys.classC zoneID:zoneID];

        [zone _onqueueAddToZone:zonekeys.currentTLKPointer    zoneID:zoneID];
        [zone _onqueueAddToZone:zonekeys.currentClassAPointer zoneID:zoneID];
        [zone _onqueueAddToZone:zonekeys.currentClassCPointer zoneID:zoneID];

        if(zonekeys.rolledTLK) {
            [zone _onqueueAddToZone:zonekeys.rolledTLK zoneID:zoneID];
        }
    });
}

- (void)rollFakeKeyHierarchyInCloudKit: (CKRecordZoneID*)zoneID {
    ZoneKeys* zonekeys = self.keys[zoneID];
    self.keys[zoneID] = nil;

    CKKSKey* oldTLK = zonekeys.tlk;
    NSError* error = nil;
    [oldTLK ensureKeyLoaded:&error];
    XCTAssertNil(error, "shouldn't error ensuring that the oldTLK has its key material");

    [self createFakeKeyHierarchy: zoneID oldTLK:oldTLK];
    [self putFakeKeyHierarchyInCloudKit: zoneID];
}

- (void)ensureZoneDeletionAllowed:(FakeCKZone*)zone {
    [super ensureZoneDeletionAllowed:zone];

    // Here's a hack: if we're deleting this zone, also drop the keys that used to be in it
    self.keys[zone.zoneID] = nil;
}

- (NSArray<CKRecord*>*)putKeySetInCloudKit:(CKKSCurrentKeySet*)keyset
{
    XCTAssertNotNil(keyset.tlk, "Should have a TLK to put a key set in CloudKit");
    CKRecordZoneID* zoneID = keyset.tlk.zoneID;
    XCTAssertNotNil(zoneID, "Should have a zoneID to put a key set in CloudKit");

    ZoneKeys* zonekeys = self.keys[zoneID];
    XCTAssertNil(zonekeys, "Should not already have zone keys when putting keyset in cloudkit");
    zonekeys = [[ZoneKeys alloc] initForZoneName:zoneID.zoneName];

    FakeCKZone* zone = self.zones[zoneID];
    // Cuttlefish makes this for you, but for now assert if there's an issue
    XCTAssertNotNil(zone, "Should already have a fakeckzone before putting a keyset in it");

    __block NSMutableArray<CKRecord*>* newRecords = [NSMutableArray array];
    dispatch_sync(zone.queue, ^{
        [newRecords addObject:[zone _onqueueAddToZone:keyset.tlk    zoneID:zoneID]];
        [newRecords addObject:[zone _onqueueAddToZone:keyset.classA zoneID:zoneID]];
        [newRecords addObject:[zone _onqueueAddToZone:keyset.classC zoneID:zoneID]];

        [newRecords addObject:[zone _onqueueAddToZone:keyset.currentTLKPointer    zoneID:zoneID]];
        [newRecords addObject:[zone _onqueueAddToZone:keyset.currentClassAPointer zoneID:zoneID]];
        [newRecords addObject:[zone _onqueueAddToZone:keyset.currentClassCPointer zoneID:zoneID]];

        // TODO handle a rolled TLK
        //if(zonekeys.rolledTLK) {
        //    [zone _onqueueAddToZone:zonekeys.rolledTLK zoneID:zoneID];
        //}

        zonekeys.tlk = keyset.tlk;
        zonekeys.classA = keyset.classA;
        zonekeys.classC = keyset.classC;
        self.keys[zoneID] = zonekeys;

        // Octagon uploads the pending TLKshares, not all of them
        for(CKKSTLKShareRecord* tlkshare in keyset.pendingTLKShares) {
            [newRecords addObject:[zone _onqueueAddToZone:tlkshare zoneID:zoneID]];
        }
    });

    return newRecords;
}

- (void)performOctagonTLKUpload:(NSSet<CKKSKeychainView*>*)views
{
    [self performOctagonTLKUpload:views afterUpload:nil];
}

- (void)performOctagonTLKUpload:(NSSet<CKKSKeychainView*>*)views afterUpload:(void (^_Nullable)(void))afterUpload
{
    NSMutableArray<CKKSResultOperation<CKKSKeySetProviderOperationProtocol>*>* keysetOps = [NSMutableArray array];

    for(CKKSKeychainView* view in views) {
        XCTAssertEqual(0, [view.keyHierarchyConditions[SecCKKSZoneKeyStateWaitForTLKCreation] wait:40*NSEC_PER_SEC], @"key state should enter 'waitfortlkcreation' (view %@)", view);
        [keysetOps addObject: [view findKeySet]];
    }

    // Now that we've kicked them all off, wait for them to resolve
    for(CKKSKeychainView* view in views) {
        XCTAssertEqual(0, [view.keyHierarchyConditions[SecCKKSZoneKeyStateWaitForTLKUpload] wait:40*NSEC_PER_SEC], @"key state should enter 'waitfortlkupload'");
    }

    NSMutableArray<CKRecord*>* keyHierarchyRecords = [NSMutableArray array];

    for(CKKSResultOperation<CKKSKeySetProviderOperationProtocol>* keysetOp in keysetOps) {
        // Wait until finished is usually a bad idea. We could rip this out into an operation if we'd like.
        [keysetOp waitUntilFinished];
        XCTAssertNil(keysetOp.error, "Should be no error fetching keyset from CKKS");

        NSArray<CKRecord*>* records = [self putKeySetInCloudKit:keysetOp.keyset];
        [keyHierarchyRecords addObjectsFromArray:records];
    }

    if(afterUpload) {
        afterUpload();
    }

    // Tell our views about our shiny new records!
    for(CKKSKeychainView* view in views) {
        [view receiveTLKUploadRecords: keyHierarchyRecords];
    }
}

- (void)saveTLKMaterialToKeychainSimulatingSOS: (CKRecordZoneID*)zoneID {

    XCTAssertNotNil(self.keys[zoneID].tlk, "Have a TLK to save for zone %@", zoneID);

    __block CFErrorRef cferror = NULL;
    kc_with_dbt(true, &cferror, ^bool (SecDbConnectionRef dbt) {
        bool ok = kc_transaction_type(dbt, kSecDbExclusiveRemoteSOSTransactionType, &cferror, ^bool {
            NSError* error = nil;
            [self.keys[zoneID].tlk saveKeyMaterialToKeychain: false error:&error];
            XCTAssertNil(error, @"Saved TLK material to keychain");
            return true;
        });
        return ok;
    });

    XCTAssertNil( (__bridge NSError*)cferror, @"no error with transaction");
    CFReleaseNull(cferror);
}
static SOSFullPeerInfoRef SOSCreateFullPeerInfoFromName(CFStringRef name,
                                                        SecKeyRef* outSigningKey,
                                                        SecKeyRef* outOctagonSigningKey,
                                                        SecKeyRef* outOctagonEncryptionKey,
                                                        CFErrorRef *error)
{
    SOSFullPeerInfoRef result = NULL;
    SecKeyRef publicKey = NULL;
    CFDictionaryRef gestalt = NULL;
    
    *outSigningKey = GeneratePermanentFullECKey(256, name, error);
    
    *outOctagonSigningKey = GeneratePermanentFullECKey(384, name, error);
    *outOctagonEncryptionKey = GeneratePermanentFullECKey(384, name, error);

    gestalt = SOSCreatePeerGestaltFromName(name);
    
    result = SOSFullPeerInfoCreate(NULL, gestalt, NULL, *outSigningKey,
                                   *outOctagonSigningKey, *outOctagonEncryptionKey,
                                   error);
    
    CFReleaseNull(gestalt);
    CFReleaseNull(publicKey);
    
    return result;
}
- (NSMutableArray<NSData *>*) SOSPiggyICloudIdentities
{
    SecKeyRef signingKey = NULL;
    SecKeyRef octagonSigningKey = NULL;
    SecKeyRef octagonEncryptionKey = NULL;
    NSMutableArray<NSData *>* icloudidentities = [NSMutableArray array];

    SOSFullPeerInfoRef fpi = SOSCreateFullPeerInfoFromName(CFSTR("Test Peer"), &signingKey, &octagonSigningKey, &octagonEncryptionKey, NULL);
    
    NSData *data = CFBridgingRelease(SOSPeerInfoCopyData(SOSFullPeerInfoGetPeerInfo(fpi), NULL));
    CFReleaseNull(fpi);
    if (data)
        [icloudidentities addObject:data];
    
    CFReleaseNull(signingKey);
    CFReleaseNull(octagonSigningKey);
    CFReleaseNull(octagonEncryptionKey);

    return icloudidentities;
}
static CFDictionaryRef SOSCreatePeerGestaltFromName(CFStringRef name)
{
    return CFDictionaryCreateForCFTypes(kCFAllocatorDefault,
                                        kPIUserDefinedDeviceNameKey, name,
                                        NULL);
}
-(NSMutableDictionary*)SOSPiggyBackCopyFromKeychain
{
    __block NSMutableDictionary *piggybackdata = [[NSMutableDictionary alloc] init];
    __block CFErrorRef cferror = NULL;
    kc_with_dbt(true, &cferror, ^bool (SecDbConnectionRef dbt) {
        bool ok = kc_transaction_type(dbt, kSecDbExclusiveRemoteSOSTransactionType, &cferror, ^bool {
            piggybackdata[@"idents"] = [self SOSPiggyICloudIdentities];
            piggybackdata[@"tlk"] = SOSAccountGetAllTLKs();

            return true;
        });
        return ok;
    });
    
    XCTAssertNil( (__bridge NSError*)cferror, @"no error with transaction");
    CFReleaseNull(cferror);
    return piggybackdata;
}
- (void)SOSPiggyBackAddToKeychain:(NSDictionary*)piggydata{
    __block CFErrorRef cferror = NULL;
    kc_with_dbt(true, &cferror, ^bool (SecDbConnectionRef dbt) {
        bool ok = kc_transaction_type(dbt, kSecDbExclusiveRemoteSOSTransactionType, &cferror, ^bool {
            NSError* error = nil;
            NSArray* icloudidentities = piggydata[@"idents"];
            NSArray* tlk = piggydata[@"tlk"];

            SOSPiggyBackAddToKeychain(icloudidentities, tlk);
            
            XCTAssertNil(error, @"Saved TLK-piggy material to keychain");
            return true;
        });
        return ok;
    });
    
    XCTAssertNil( (__bridge NSError*)cferror, @"no error with transaction");
    CFReleaseNull(cferror);
}

- (void)saveTLKMaterialToKeychain: (CKRecordZoneID*)zoneID {
    NSError* error = nil;
    XCTAssertNotNil(self.keys[zoneID].tlk, "Have a TLK to save for zone %@", zoneID);

    // Don't make the stashed local copy of the TLK
    [self.keys[zoneID].tlk saveKeyMaterialToKeychain:false error:&error];
    XCTAssertNil(error, @"Saved TLK material to keychain");
}

- (void)deleteTLKMaterialFromKeychain: (CKRecordZoneID*)zoneID {
    NSError* error = nil;
    XCTAssertNotNil(self.keys[zoneID].tlk, "Have a TLK to save for zone %@", zoneID);
    [self.keys[zoneID].tlk deleteKeyMaterialFromKeychain:&error];
    XCTAssertNil(error, @"Saved TLK material to keychain");
}

- (void)saveClassKeyMaterialToKeychain: (CKRecordZoneID*)zoneID {
    NSError* error = nil;
    XCTAssertNotNil(self.keys[zoneID].classA, "Have a Class A to save for zone %@", zoneID);
    [self.keys[zoneID].classA saveKeyMaterialToKeychain:&error];
    XCTAssertNil(error, @"Saved Class A material to keychain");

    XCTAssertNotNil(self.keys[zoneID].classC, "Have a Class C to save for zone %@", zoneID);
    [self.keys[zoneID].classC saveKeyMaterialToKeychain:&error];
    XCTAssertNil(error, @"Saved Class C material to keychain");
}


- (void)putTLKShareInCloudKit:(CKKSKey*)key
                         from:(id<CKKSSelfPeer>)sharingPeer
                           to:(id<CKKSPeer>)receivingPeer
                       zoneID:(CKRecordZoneID*)zoneID
{
    NSError* error = nil;
    CKKSTLKShareRecord* share = [CKKSTLKShareRecord share:key
                                           as:sharingPeer
                                           to:receivingPeer
                                        epoch:-1
                                     poisoned:0
                                        error:&error];
    XCTAssertNil(error, "Should have been no error sharing a CKKSKey");
    XCTAssertNotNil(share, "Should be able to create a share");

    CKRecord* shareRecord = [share CKRecordWithZoneID: zoneID];
    XCTAssertNotNil(shareRecord, "Should have been able to create a CKRecord");

    FakeCKZone* zone = self.zones[zoneID];
    XCTAssertNotNil(zone, "Should have a zone to put a TLKShare in");
    [zone addToZone:shareRecord];

    ZoneKeys* keys = self.keys[zoneID];
    XCTAssertNotNil(keys, "Have a zonekeys object for this zone");
    keys.tlkShares = keys.tlkShares ? [keys.tlkShares arrayByAddingObject:share] : @[share];
}

- (void)putTLKSharesInCloudKit:(CKKSKey*)key
                          from:(id<CKKSSelfPeer>)sharingPeer
                        zoneID:(CKRecordZoneID*)zoneID
{
    NSSet* peers = [self.mockSOSAdapter.trustedPeers setByAddingObject:self.mockSOSAdapter.selfPeer];

    for(id<CKKSPeer> peer in peers) {
        // Can only send to peers with encryption keys
        if(peer.publicEncryptionKey) {
            [self putTLKShareInCloudKit:key from:sharingPeer to:peer zoneID:zoneID];
        }
    }
}

- (void)putSelfTLKSharesInCloudKit:(CKRecordZoneID*)zoneID {
    CKKSKey* tlk = self.keys[zoneID].tlk;
    XCTAssertNotNil(tlk, "Should have a TLK for zone %@", zoneID);
    [self putTLKSharesInCloudKit:tlk from:self.mockSOSAdapter.selfPeer zoneID:zoneID];
}

- (void)saveTLKSharesInLocalDatabase:(CKRecordZoneID*)zoneID {
    ZoneKeys* keys = self.keys[zoneID];
    XCTAssertNotNil(keys, "Have a zonekeys object for this zone");

    for(CKKSTLKShareRecord* share in keys.tlkShares) {
        NSError* error = nil;
        [share saveToDatabase:&error];
        XCTAssertNil(error, "Shouldn't have been an error saving a TLKShare to the database");
    }
}

- (void)createAndSaveFakeKeyHierarchy: (CKRecordZoneID*)zoneID {
    // Put in CloudKit first, so the records on-disk will have the right change tags
    [self putFakeKeyHierarchyInCloudKit:       zoneID];
    [self saveFakeKeyHierarchyToLocalDatabase: zoneID];
    [self saveTLKMaterialToKeychain:           zoneID];
    [self saveClassKeyMaterialToKeychain:      zoneID];

    [self putSelfTLKSharesInCloudKit:zoneID];
    [self saveTLKSharesInLocalDatabase:zoneID];
}

// Override our base class here, but only for Keychain Views

- (void)expectCKModifyRecords:(NSDictionary<NSString*, NSNumber*>*)expectedRecordTypeCounts
      deletedRecordTypeCounts:(NSDictionary<NSString*, NSNumber*>*)expectedDeletedRecordTypeCounts
                       zoneID:(CKRecordZoneID*)zoneID
          checkModifiedRecord:(BOOL (^)(CKRecord*))checkRecord
         runAfterModification:(void (^) (void))afterModification
{

    void (^newAfterModification)(void) = afterModification;
    if([self.ckksZones containsObject:zoneID]) {
        __weak __typeof(self) weakSelf = self;
        newAfterModification = ^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            XCTAssertNotNil(strongSelf, "self exists");

            // Reach into our cloudkit database and extract the keys
            CKRecordID* currentTLKPointerID =    [[CKRecordID alloc] initWithRecordName:SecCKKSKeyClassTLK zoneID:zoneID];
            CKRecordID* currentClassAPointerID = [[CKRecordID alloc] initWithRecordName:SecCKKSKeyClassA   zoneID:zoneID];
            CKRecordID* currentClassCPointerID = [[CKRecordID alloc] initWithRecordName:SecCKKSKeyClassC   zoneID:zoneID];

            ZoneKeys* zonekeys = strongSelf.keys[zoneID];
            if(!zonekeys) {
                zonekeys = [[ZoneKeys alloc] init];
                strongSelf.keys[zoneID] = zonekeys;
            }

            XCTAssertNotNil(strongSelf.zones[zoneID].currentDatabase[currentTLKPointerID],    "Have a currentTLKPointer");
            XCTAssertNotNil(strongSelf.zones[zoneID].currentDatabase[currentClassAPointerID], "Have a currentClassAPointer");
            XCTAssertNotNil(strongSelf.zones[zoneID].currentDatabase[currentClassCPointerID], "Have a currentClassCPointer");
            XCTAssertNotNil(strongSelf.zones[zoneID].currentDatabase[currentTLKPointerID][SecCKRecordParentKeyRefKey],    "Have a currentTLKPointer parent");
            XCTAssertNotNil(strongSelf.zones[zoneID].currentDatabase[currentClassAPointerID][SecCKRecordParentKeyRefKey], "Have a currentClassAPointer parent");
            XCTAssertNotNil(strongSelf.zones[zoneID].currentDatabase[currentClassCPointerID][SecCKRecordParentKeyRefKey], "Have a currentClassCPointer parent");
            XCTAssertNotNil([strongSelf.zones[zoneID].currentDatabase[currentTLKPointerID][SecCKRecordParentKeyRefKey] recordID].recordName,    "Have a currentTLKPointer parent UUID");
            XCTAssertNotNil([strongSelf.zones[zoneID].currentDatabase[currentClassAPointerID][SecCKRecordParentKeyRefKey] recordID].recordName, "Have a currentClassAPointer parent UUID");
            XCTAssertNotNil([strongSelf.zones[zoneID].currentDatabase[currentClassCPointerID][SecCKRecordParentKeyRefKey] recordID].recordName, "Have a currentClassCPointer parent UUID");

            zonekeys.currentTLKPointer =    [[CKKSCurrentKeyPointer alloc] initWithCKRecord: strongSelf.zones[zoneID].currentDatabase[currentTLKPointerID]];
            zonekeys.currentClassAPointer = [[CKKSCurrentKeyPointer alloc] initWithCKRecord: strongSelf.zones[zoneID].currentDatabase[currentClassAPointerID]];
            zonekeys.currentClassCPointer = [[CKKSCurrentKeyPointer alloc] initWithCKRecord: strongSelf.zones[zoneID].currentDatabase[currentClassCPointerID]];

            XCTAssertNotNil(zonekeys.currentTLKPointer.currentKeyUUID,    "Have a currentTLKPointer current UUID");
            XCTAssertNotNil(zonekeys.currentClassAPointer.currentKeyUUID, "Have a currentClassAPointer current UUID");
            XCTAssertNotNil(zonekeys.currentClassCPointer.currentKeyUUID, "Have a currentClassCPointer current UUID");

            CKRecordID* currentTLKID =    [[CKRecordID alloc] initWithRecordName:zonekeys.currentTLKPointer.currentKeyUUID    zoneID:zoneID];
            CKRecordID* currentClassAID = [[CKRecordID alloc] initWithRecordName:zonekeys.currentClassAPointer.currentKeyUUID zoneID:zoneID];
            CKRecordID* currentClassCID = [[CKRecordID alloc] initWithRecordName:zonekeys.currentClassCPointer.currentKeyUUID zoneID:zoneID];

            zonekeys.tlk =    [[CKKSKey alloc] initWithCKRecord: strongSelf.zones[zoneID].currentDatabase[currentTLKID]];
            zonekeys.classA = [[CKKSKey alloc] initWithCKRecord: strongSelf.zones[zoneID].currentDatabase[currentClassAID]];
            zonekeys.classC = [[CKKSKey alloc] initWithCKRecord: strongSelf.zones[zoneID].currentDatabase[currentClassCID]];

            XCTAssertNotNil(zonekeys.tlk, "Have the current TLK");
            XCTAssertNotNil(zonekeys.classA, "Have the current Class A key");
            XCTAssertNotNil(zonekeys.classC, "Have the current Class C key");

            NSMutableArray<CKKSTLKShareRecord*>* shares = [NSMutableArray array];
            for(CKRecordID* recordID in strongSelf.zones[zoneID].currentDatabase.allKeys) {
                if([recordID.recordName hasPrefix: [CKKSTLKShareRecord ckrecordPrefix]]) {
                    CKKSTLKShareRecord* share = [[CKKSTLKShareRecord alloc] initWithCKRecord:strongSelf.zones[zoneID].currentDatabase[recordID]];
                    XCTAssertNotNil(share, "Should be able to parse a CKKSTLKShare CKRecord into a CKKSTLKShare");
                    [shares addObject:share];
                }
            }
            zonekeys.tlkShares = shares;

            if(afterModification) {
                afterModification();
            }
        };
    }

    [super expectCKModifyRecords:expectedRecordTypeCounts
         deletedRecordTypeCounts:expectedDeletedRecordTypeCounts
                          zoneID:zoneID
             checkModifiedRecord:checkRecord
            runAfterModification:newAfterModification];
}

- (void)expectCKReceiveSyncKeyHierarchyError:(CKRecordZoneID*)zoneID {

    __weak __typeof(self) weakSelf = self;
    [[self.mockDatabase expect] addOperation:[OCMArg checkWithBlock:^BOOL(id obj) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        XCTAssertNotNil(strongSelf, "self exists");

        __block bool rejected = false;
        if ([obj isKindOfClass:[CKModifyRecordsOperation class]]) {
            CKModifyRecordsOperation *op = (CKModifyRecordsOperation *)obj;

            if(!op.atomic) {
                // We only care about atomic operations
                return NO;
            }

            // We want to only match zone updates pertaining to this zone
            for(CKRecord* record in op.recordsToSave) {
                if(![record.recordID.zoneID isEqual: zoneID]) {
                    return NO;
                }
            }

            // we oly want to match updates that are updating a class C or class A CKP
            bool updatingClassACKP = false;
            bool updatingClassCCKP = false;
            for(CKRecord* record in op.recordsToSave) {
                if([record.recordID.recordName isEqualToString:SecCKKSKeyClassA]) {
                    updatingClassACKP = true;
                }
                if([record.recordID.recordName isEqualToString:SecCKKSKeyClassC]) {
                    updatingClassCCKP = true;
                }
            }

            if(!updatingClassACKP && !updatingClassCCKP) {
                return NO;
            }

            FakeCKZone* zone = strongSelf.zones[zoneID];
            XCTAssertNotNil(zone, "Should have a zone for these records");

            // We only want to match if the synckeys aren't pointing correctly

            ZoneKeys* zonekeys = [[ZoneKeys alloc] initLoadingRecordsFromZone:zone];

            XCTAssertNotNil(zonekeys.currentTLKPointer,    "Have a currentTLKPointer");
            XCTAssertNotNil(zonekeys.currentClassAPointer, "Have a currentClassAPointer");
            XCTAssertNotNil(zonekeys.currentClassCPointer, "Have a currentClassCPointer");

            XCTAssertNotNil(zonekeys.tlk,    "Have the current TLK");
            XCTAssertNotNil(zonekeys.classA, "Have the current Class A key");
            XCTAssertNotNil(zonekeys.classC, "Have the current Class C key");

            // Ensure that either the Class A synckey or the class C synckey do not immediately wrap to the current TLK
            bool classALinkBroken = ![zonekeys.classA.parentKeyUUID isEqualToString:zonekeys.tlk.uuid];
            bool classCLinkBroken = ![zonekeys.classC.parentKeyUUID isEqualToString:zonekeys.tlk.uuid];

            // Neither synckey link is broken. Don't match this operation.
            if(!classALinkBroken && !classCLinkBroken) {
                return NO;
            }

            NSMutableDictionary<CKRecordID*, NSError*>* failedRecords = [[NSMutableDictionary alloc] init];

            @synchronized(zone.currentDatabase) {
                for(CKRecord* record in op.recordsToSave) {
                    if(classALinkBroken && [record.recordID.recordName isEqualToString:SecCKKSKeyClassA]) {
                        failedRecords[record.recordID] = [strongSelf ckInternalServerExtensionError:CKKSServerUnexpectedSyncKeyInChain description:@"synckey record: current classA synckey does not point to current tlk synckey"];
                        rejected = true;
                    }
                    if(classCLinkBroken && [record.recordID.recordName isEqualToString:SecCKKSKeyClassC]) {
                        failedRecords[record.recordID] = [strongSelf ckInternalServerExtensionError:CKKSServerUnexpectedSyncKeyInChain description:@"synckey record: current classC synckey does not point to current tlk synckey"];
                        rejected = true;
                    }
                }
            }

            if(rejected) {
                [strongSelf rejectWrite: op failedRecords:failedRecords];
            }
        }
        return rejected ? YES : NO;
    }]];
}

- (void)checkNoCKKSData: (CKKSKeychainView*) view {
    // Test that there are no items in the database
    [view dispatchSync:^bool{
        NSError* error = nil;
        NSArray<CKKSMirrorEntry*>* ckmes = [CKKSMirrorEntry all: view.zoneID error:&error];
        XCTAssertNil(error, "No error fetching CKMEs");
        XCTAssertEqual(ckmes.count, 0ul, "No CKMirrorEntries");

        NSArray<CKKSOutgoingQueueEntry*>* oqes = [CKKSOutgoingQueueEntry all: view.zoneID error:&error];
        XCTAssertNil(error, "No error fetching OQEs");
        XCTAssertEqual(oqes.count, 0ul, "No OutgoingQueueEntries");

        NSArray<CKKSIncomingQueueEntry*>* iqes = [CKKSIncomingQueueEntry all: view.zoneID error:&error];
        XCTAssertNil(error, "No error fetching IQEs");
        XCTAssertEqual(iqes.count, 0ul, "No IncomingQueueEntries");

        NSArray<CKKSKey*>* keys = [CKKSKey all: view.zoneID error:&error];
        XCTAssertNil(error, "No error fetching keys");
        XCTAssertEqual(keys.count, 0ul, "No CKKSKeys");

        NSArray<CKKSDeviceStateEntry*>* deviceStates = [CKKSDeviceStateEntry allInZone:view.zoneID error:&error];
        XCTAssertNil(error, "should be no error fetching device states");
        XCTAssertEqual(deviceStates.count, 0ul, "No Device State entries");
        return false;
    }];
}

- (BOOL (^) (CKRecord*)) checkClassABlock: (CKRecordZoneID*) zoneID message:(NSString*) message {
    __weak __typeof(self) weakSelf = self;
    return ^BOOL(CKRecord* record) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        XCTAssertNotNil(strongSelf, "self exists");

        ZoneKeys* zoneKeys = strongSelf.keys[zoneID];
        XCTAssertNotNil(zoneKeys, "Have zone keys for %@", zoneID);
        XCTAssertEqualObjects([record[SecCKRecordParentKeyRefKey] recordID].recordName, zoneKeys.classA.uuid, "%@", message);
        return [[record[SecCKRecordParentKeyRefKey] recordID].recordName isEqual: zoneKeys.classA.uuid];
    };
}

- (BOOL (^) (CKRecord*)) checkClassCBlock: (CKRecordZoneID*) zoneID message:(NSString*) message {
    __weak __typeof(self) weakSelf = self;
    return ^BOOL(CKRecord* record) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        XCTAssertNotNil(strongSelf, "self exists");

        ZoneKeys* zoneKeys = strongSelf.keys[zoneID];
        XCTAssertNotNil(zoneKeys, "Have zone keys for %@", zoneID);
        XCTAssertEqualObjects([record[SecCKRecordParentKeyRefKey] recordID].recordName, zoneKeys.classC.uuid, "%@", message);
        return [[record[SecCKRecordParentKeyRefKey] recordID].recordName isEqual: zoneKeys.classC.uuid];
    };
}

- (BOOL (^) (CKRecord*)) checkPasswordBlock:(CKRecordZoneID*)zoneID
                                    account:(NSString*)account
                                   password:(NSString*)password  {
    __weak __typeof(self) weakSelf = self;
    return ^BOOL(CKRecord* record) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        XCTAssertNotNil(strongSelf, "self exists");

        ZoneKeys* zoneKeys = strongSelf.keys[zoneID];
        XCTAssertNotNil(zoneKeys, "Have zone keys for %@", zoneID);
        XCTAssertNotNil([record[SecCKRecordParentKeyRefKey] recordID].recordName, "Have a wrapping key");

        CKKSKey* key = nil;
        if([[record[SecCKRecordParentKeyRefKey] recordID].recordName isEqualToString: zoneKeys.classC.uuid]) {
            key = zoneKeys.classC;
        } else if([[record[SecCKRecordParentKeyRefKey] recordID].recordName isEqualToString: zoneKeys.classA.uuid]) {
            key = zoneKeys.classA;
        }
        XCTAssertNotNil(key, "Found a key via UUID");

        CKKSMirrorEntry* ckme = [[CKKSMirrorEntry alloc] initWithCKRecord: record];

        NSError* error = nil;
        NSDictionary* dict = [CKKSItemEncrypter decryptItemToDictionary:ckme.item error:&error];
        XCTAssertNil(error, "No error decrypting item");
        XCTAssertEqualObjects(account, dict[(id)kSecAttrAccount], "Account matches");
        XCTAssertEqualObjects([password dataUsingEncoding:NSUTF8StringEncoding], dict[(id)kSecValueData], "Password matches");
        return YES;
    };
}

- (NSDictionary*)fakeRecordDictionary:(NSString*) account zoneID:(CKRecordZoneID*)zoneID {
    NSError* error = nil;

    /* Basically: @{
     @"acct"  : @"account-delete-me",
     @"agrp"  : @"com.apple.security.sos",
     @"cdat"  : @"2016-12-21 03:33:25 +0000",
     @"class" : @"genp",
     @"mdat"  : @"2016-12-21 03:33:25 +0000",
     @"musr"  : [[NSData alloc] init],
     @"pdmn"  : @"ak",
     @"sha1"  : [[NSData alloc] initWithBase64EncodedString: @"C3VWONaOIj8YgJjk/xwku4By1CY=" options:0],
     @"svce"  : @"",
     @"tomb"  : [NSNumber numberWithInt: 0],
     @"v_Data" : [@"data" dataUsingEncoding: NSUTF8StringEncoding],
     };
     TODO: this should be binary encoded instead of expanded, but the plist encoder should handle it fine */
    NSData* itemdata = [[NSData alloc] initWithBase64EncodedString:@"PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPCFET0NUWVBFIHBsaXN0IFBVQkxJQyAiLS8vQXBwbGUvL0RURCBQTElTVCAxLjAvL0VOIiAiaHR0cDovL3d3dy5hcHBsZS5jb20vRFREcy9Qcm9wZXJ0eUxpc3QtMS4wLmR0ZCI+CjxwbGlzdCB2ZXJzaW9uPSIxLjAiPgo8ZGljdD4KCTxrZXk+YWNjdDwva2V5PgoJPHN0cmluZz5hY2NvdW50LWRlbGV0ZS1tZTwvc3RyaW5nPgoJPGtleT5hZ3JwPC9rZXk+Cgk8c3RyaW5nPmNvbS5hcHBsZS5zZWN1cml0eS5zb3M8L3N0cmluZz4KCTxrZXk+Y2RhdDwva2V5PgoJPGRhdGU+MjAxNi0xMi0yMVQwMzozMzoyNVo8L2RhdGU+Cgk8a2V5PmNsYXNzPC9rZXk+Cgk8c3RyaW5nPmdlbnA8L3N0cmluZz4KCTxrZXk+bWRhdDwva2V5PgoJPGRhdGU+MjAxNi0xMi0yMVQwMzozMzoyNVo8L2RhdGU+Cgk8a2V5Pm11c3I8L2tleT4KCTxkYXRhPgoJPC9kYXRhPgoJPGtleT5wZG1uPC9rZXk+Cgk8c3RyaW5nPmFrPC9zdHJpbmc+Cgk8a2V5PnNoYTE8L2tleT4KCTxkYXRhPgoJQzNWV09OYU9JajhZZ0pqay94d2t1NEJ5MUNZPQoJPC9kYXRhPgoJPGtleT5zdmNlPC9rZXk+Cgk8c3RyaW5nPjwvc3RyaW5nPgoJPGtleT50b21iPC9rZXk+Cgk8aW50ZWdlcj4wPC9pbnRlZ2VyPgoJPGtleT52X0RhdGE8L2tleT4KCTxkYXRhPgoJWkdGMFlRPT0KCTwvZGF0YT4KPC9kaWN0Pgo8L3BsaXN0Pgo=" options:0];
    NSMutableDictionary * item = [[NSPropertyListSerialization propertyListWithData:itemdata
                                                                            options:0
                                                                             format:nil
                                                                              error:&error] mutableCopy];
    // Fix up dictionary
    item[@"agrp"] = @"com.apple.security.ckks";
    item[@"vwht"] = @"keychain";
    XCTAssertNil(error, "no error interpreting data as item");
    XCTAssertNotNil(item, "interpreted data as item");

    if(zoneID && ![zoneID.zoneName isEqualToString:@"keychain"]) {
        [item setObject: zoneID.zoneName forKey: (__bridge id) kSecAttrSyncViewHint];
    }

    if(account) {
        [item setObject: account forKey: (__bridge id) kSecAttrAccount];
    }
    return item;
}

- (CKRecord*)createFakeRecord: (CKRecordZoneID*)zoneID recordName:(NSString*)recordName {
    return [self createFakeRecord: zoneID recordName:recordName withAccount: nil key:nil];
}

- (CKRecord*)createFakeRecord: (CKRecordZoneID*)zoneID recordName:(NSString*)recordName withAccount: (NSString*) account {
    return [self createFakeRecord: zoneID recordName:recordName withAccount:account key:nil];
}

- (CKRecord*)createFakeRecord: (CKRecordZoneID*)zoneID recordName:(NSString*)recordName withAccount: (NSString*) account key:(CKKSKey*)key {
    NSMutableDictionary* item = [[self fakeRecordDictionary: account zoneID:zoneID] mutableCopy];

    // class c items should be class c
    if([key.keyclass isEqualToString:SecCKKSKeyClassC]) {
        item[(__bridge NSString*)kSecAttrAccessible] = @"ck";
    }

    CKRecordID* ckrid = [[CKRecordID alloc] initWithRecordName:recordName zoneID:zoneID];
    if(key) {
        return [self newRecord: ckrid withNewItemData:item key:key];
    } else {
        return [self newRecord: ckrid withNewItemData:item];
    }
}

- (CKRecord*)newRecord: (CKRecordID*) recordID withNewItemData:(NSDictionary*) dictionary {
    ZoneKeys* zonekeys = self.keys[recordID.zoneID];
    XCTAssertNotNil(zonekeys, "Have zone keys for zone");
    XCTAssertNotNil(zonekeys.classC, "Have class C key for zone");

    return [self newRecord:recordID withNewItemData:dictionary key:zonekeys.classC];
}

- (CKKSItem*)newItem:(CKRecordID*)recordID withNewItemData:(NSDictionary*)dictionary key:(CKKSKey*)key {
    NSError* error = nil;
    CKKSItem* cipheritem = [CKKSItemEncrypter encryptCKKSItem:[[CKKSItem alloc] initWithUUID:recordID.recordName
                                                                               parentKeyUUID:key.uuid
                                                                                      zoneID:recordID.zoneID]
                                               dataDictionary:dictionary
                                             updatingCKKSItem:nil
                                                    parentkey:key
                                                        error:&error];
    XCTAssertNil(error, "encrypted item with class c key");
    XCTAssertNotNil(cipheritem, "Have an encrypted item");

    return cipheritem;
}

- (CKRecord*)newRecord: (CKRecordID*) recordID withNewItemData:(NSDictionary*) dictionary key:(CKKSKey*)key {
    CKKSItem* item = [self newItem:recordID withNewItemData:dictionary key:key];

    CKRecord* ckr = [item CKRecordWithZoneID: recordID.zoneID];
    XCTAssertNotNil(ckr, "Created a CKRecord");
    return ckr;
}

- (NSDictionary*)decryptRecord: (CKRecord*) record {
    CKKSItem* item = [[CKKSItem alloc] initWithCKRecord: record];

    NSError* error = nil;

    NSDictionary* ret = [CKKSItemEncrypter decryptItemToDictionary: item error:&error];
    XCTAssertNil(error);
    XCTAssertNotNil(ret);
    return ret;
}

- (BOOL)addGenericPassword:(NSString*)password
                   account:(NSString*)account
                    access:(NSString*)access
                  viewHint:(NSString* _Nullable)viewHint
               accessGroup:(NSString* _Nullable)accessGroup
                 expecting:(OSStatus)status
                   message:(NSString*)message
{
    NSMutableDictionary* query = [@{
                                    (id)kSecClass : (id)kSecClassGenericPassword,
                                    (id)kSecAttrAccessible: (id)access,
                                    (id)kSecAttrAccount : account,
                                    (id)kSecAttrSynchronizable : (id)kCFBooleanTrue,
                                    (id)kSecValueData : (id) [password dataUsingEncoding:NSUTF8StringEncoding],
                                    } mutableCopy];

    query[(id)kSecAttrAccessGroup] = accessGroup ?: @"com.apple.security.ckks";

    if(viewHint) {
        query[(id)kSecAttrSyncViewHint] = viewHint;
    } else {
        // Fake it as 'keychain'. This lets CKKSScanLocalItemsOperation for the test-only 'keychain' view find items which would normally not have a view hint.
        query[(id)kSecAttrSyncViewHint] = @"keychain";
    }

    XCTAssertEqual(status, SecItemAdd((__bridge CFDictionaryRef) query, NULL), @"%@", message);
}

- (void)addGenericPassword: (NSString*) password account: (NSString*) account viewHint: (NSString*) viewHint access: (NSString*) access expecting: (OSStatus) status message: (NSString*) message {
    [self addGenericPassword:password
                     account:account
                      access:access
                    viewHint:viewHint
                 accessGroup:nil
                   expecting:status
                     message:message];
}

- (void)addGenericPassword: (NSString*) password account: (NSString*) account expecting: (OSStatus) status message: (NSString*) message {
    [self addGenericPassword:password account:account viewHint:nil access:(id)kSecAttrAccessibleAfterFirstUnlock expecting:errSecSuccess message:message];

}

- (void)addGenericPassword: (NSString*) password account: (NSString*) account {
    [self addGenericPassword:password account:account viewHint:nil access:(id)kSecAttrAccessibleAfterFirstUnlock expecting:errSecSuccess message:@"Add item to keychain"];
}

- (void)addGenericPassword: (NSString*) password account: (NSString*) account viewHint:(NSString*)viewHint {
    [self addGenericPassword:password account:account viewHint:viewHint access:(id)kSecAttrAccessibleAfterFirstUnlock expecting:errSecSuccess message:@"Add item to keychain with a viewhint"];
}

- (void)updateGenericPassword: (NSString*) newPassword account: (NSString*)account {
    NSDictionary* query = @{
                                    (id)kSecClass : (id)kSecClassGenericPassword,
                                    (id)kSecAttrAccessGroup : @"com.apple.security.ckks",
                                    (id)kSecAttrAccount : account,
                                    (id)kSecAttrSynchronizable : (id)kCFBooleanTrue,
                                    };

    NSDictionary* update = @{
                                    (id)kSecValueData : (id) [newPassword dataUsingEncoding:NSUTF8StringEncoding],
                                    };
    XCTAssertEqual(errSecSuccess, SecItemUpdate((__bridge CFDictionaryRef) query, (__bridge CFDictionaryRef) update), @"Updating item %@ to %@", account, newPassword);
}

- (void)updateAccountOfGenericPassword:(NSString*)newAccount
                               account:(NSString*)account {
    NSDictionary* query = @{
                            (id)kSecClass : (id)kSecClassGenericPassword,
                            (id)kSecAttrAccessGroup : @"com.apple.security.ckks",
                            (id)kSecAttrAccount : account,
                            (id)kSecAttrSynchronizable : (id)kCFBooleanTrue,
                            };

    NSDictionary* update = @{
                             (id)kSecAttrAccount : (id) newAccount,
                             };
    XCTAssertEqual(errSecSuccess, SecItemUpdate((__bridge CFDictionaryRef) query, (__bridge CFDictionaryRef) update), @"Updating item %@ to account %@", account, newAccount);
}

- (void)deleteGenericPassword: (NSString*) account {
    NSDictionary* query = @{
                            (id)kSecClass : (id)kSecClassGenericPassword,
                            (id)kSecAttrAccount : account,
                            (id)kSecAttrSynchronizable : (id)kCFBooleanTrue,
                            };

    XCTAssertEqual(errSecSuccess, SecItemDelete((__bridge CFDictionaryRef) query), @"Deleting item %@", account);
}

- (void)deleteGenericPasswordWithoutTombstones:(NSString*)account {
    NSDictionary* query = @{
                            (id)kSecClass : (id)kSecClassGenericPassword,
                            (id)kSecAttrAccount : account,
                            (id)kSecAttrSynchronizable : (id)kCFBooleanTrue,
                            (id)kSecUseTombstones: @NO,
                            };

    XCTAssertEqual(errSecSuccess, SecItemDelete((__bridge CFDictionaryRef) query), @"Deleting item %@", account);
}

- (void)findGenericPassword: (NSString*) account expecting: (OSStatus) status {
    NSDictionary *query = @{(id)kSecClass : (id)kSecClassGenericPassword,
                            (id)kSecAttrAccessGroup : @"com.apple.security.ckks",
                            (id)kSecAttrAccount : account,
                            (id)kSecAttrSynchronizable : (id)kCFBooleanTrue,
                            (id)kSecMatchLimit : (id)kSecMatchLimitOne,
                            };
    XCTAssertEqual(status, SecItemCopyMatching((__bridge CFDictionaryRef) query, NULL), "Finding item %@", account);
}

- (void)checkGenericPassword: (NSString*) password account: (NSString*) account {
    NSDictionary *query = @{(id)kSecClass : (id)kSecClassGenericPassword,
                            (id)kSecAttrAccessGroup : @"com.apple.security.ckks",
                            (id)kSecAttrAccount : account,
                            (id)kSecAttrSynchronizable : (id)kCFBooleanTrue,
                            (id)kSecMatchLimit : (id)kSecMatchLimitOne,
                            (id)kSecReturnData : (id)kCFBooleanTrue,
                            };
    CFTypeRef result = NULL;

    XCTAssertEqual(errSecSuccess, SecItemCopyMatching((__bridge CFDictionaryRef) query, &result), "Item %@ should exist", account);
    XCTAssertNotNil((__bridge id)result, "Should have received an item");

    NSString* storedPassword = [[NSString alloc] initWithData: (__bridge NSData*) result encoding: NSUTF8StringEncoding];
    XCTAssertNotNil(storedPassword, "Password should parse as a UTF8 password");

    XCTAssertEqualObjects(storedPassword, password, "Stored password should match received password");
}

-(XCTestExpectation*)expectChangeForView:(NSString*)view {
    NSString* notification = [NSString stringWithFormat: @"com.apple.security.view-change.%@", view];
    return [self expectationForNotification:notification object:nil handler:^BOOL(NSNotification * _Nonnull nsnotification) {
        secnotice("ckks", "Got a notification for %@: %@", notification, nsnotification);
        return YES;
    }];
}

- (void)expectCKKSTLKSelfShareUpload:(CKRecordZoneID*)zoneID {
    [self expectCKModifyKeyRecords:0 currentKeyPointerRecords:0 tlkShareRecords:1 zoneID:zoneID];
}

- (void)checkNSyncableTLKsInKeychain:(size_t)n {
    NSDictionary *query = @{(id)kSecClass : (id)kSecClassInternetPassword,
                            (id)kSecAttrAccessGroup : @"com.apple.security.ckks",
                            (id)kSecAttrSynchronizable : (id)kCFBooleanTrue,
                            (id)kSecAttrDescription: SecCKKSKeyClassTLK,
                            (id)kSecMatchLimit : (id)kSecMatchLimitAll,
                            (id)kSecReturnAttributes : (id)kCFBooleanTrue,
                            };
    CFTypeRef result = NULL;

    if(n == 0) {
        XCTAssertEqual(errSecItemNotFound, SecItemCopyMatching((__bridge CFDictionaryRef) query, &result), "Should have found no TLKs");
    } else {
        XCTAssertEqual(errSecSuccess, SecItemCopyMatching((__bridge CFDictionaryRef) query, &result), "Should have found TLKs");
        NSArray* items = (NSArray*) CFBridgingRelease(result);

        XCTAssertEqual(items.count, n, "Should have received %lu items", (unsigned long)n);
    }
}

- (OTAccountMetadataClassC*)loadOrCreateAccountMetadata:(NSError**)error
{
    if(error) {
        *error = [NSError errorWithDomain:@"securityd" code:errSecInteractionNotAllowed userInfo:nil];
    }
    return nil;
}

@end

#endif // OCTAGON
