/*
 * Copyright (c) 2013-2014 Apple Inc. All Rights Reserved.
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




#include <Security/SecBase.h>
#include <Security/SecItem.h>

#include <CoreFoundation/CFDictionary.h>

#include "keychain/SecureObjectSync/SOSAccount.h"
#include <Security/SecureObjectSync/SOSCloudCircle.h>
#include "keychain/SecureObjectSync/SOSInternal.h"
#include "keychain/SecureObjectSync/SOSUserKeygen.h"
#include "keychain/SecureObjectSync/SOSTransport.h"

#include <stdlib.h>
#include <unistd.h>

#include "secd_regressions.h"
#include "SOSTestDataSource.h"

#include "SOSRegressionUtilities.h"
#include <utilities/SecCFWrappers.h>
#include <Security/SecKeyPriv.h>

#include "keychain/securityd/SOSCloudCircleServer.h"

#include "SOSAccountTesting.h"
#include "SecdTestKeychainUtilities.h"


static bool AssertCreds(SOSAccount* account,CFStringRef acct_name, CFDataRef password) {
    CFErrorRef error = NULL;
    bool retval;
    ok((retval = SOSAccountAssertUserCredentialsAndUpdate(account, acct_name, password, &error)), "Credential setting (%@)", error);
    CFReleaseNull(error);
    return retval;
}

static inline bool SOSAccountEvaluateKeysAndCircle_wTxn(SOSAccount* acct, CFErrorRef* error)
{
    __block bool result = false;
    [acct performTransaction:^(SOSAccountTransaction * _Nonnull txn) {
        result = SOSAccountEvaluateKeysAndCircle(txn, NULL);
    }];
    return result;
}

static bool ResetToOffering(SOSAccount* account) {
    CFErrorRef error = NULL;
    bool retval;
    ok((retval = SOSAccountResetToOffering_wTxn(account, &error)), "Reset to offering (%@)", error);
    CFReleaseNull(error);
    return retval;
}

static bool JoinCircle(SOSAccount* account) {
    CFErrorRef error = NULL;
    bool retval;
    ok((retval = SOSAccountJoinCircles_wTxn(account, &error)), "Join Circle (%@)", error);
    CFReleaseNull(error);
    return retval;
}

static bool AcceptApplicants(SOSAccount* account, CFIndex cnt) {
    CFErrorRef error = NULL;
    bool retval = false;
    CFArrayRef applicants = SOSAccountCopyApplicants(account, &error);
    
    ok((retval = (applicants && CFArrayGetCount(applicants) == cnt)), "See applicants %@ (%@)", applicants, error);
    if(retval) ok((retval = SOSAccountAcceptApplicants(account, applicants, &error)), "Accept Applicants (%@)", error);
    CFReleaseNull(applicants);
    CFReleaseNull(error);
    return retval;
}

static void tests(void)
{
    CFDataRef cfpassword = CFDataCreate(NULL, (uint8_t *) "FooFooFoo", 10);
    CFStringRef cfaccount = CFSTR("test@test.org");
    
    CFMutableDictionaryRef changes = CFDictionaryCreateMutableForCFTypes(kCFAllocatorDefault);
    SOSAccount* alice_account = CreateAccountForLocalChanges(CFSTR("Alice"), CFSTR("TestSource"));
    SOSAccount* bob_account = CreateAccountForLocalChanges(CFSTR("Bob"), CFSTR("TestSource"));
    SOSAccount* carol_account = CreateAccountForLocalChanges(CFSTR("Carol"), CFSTR("TestSource"));
    
    /* Set Initial Credentials and Parameters for the Syncing Circles ---------------------------------------*/
    ok(AssertCreds(bob_account, cfaccount, cfpassword), "Setting credentials for Bob");
    // Bob wins writing at this point, feed the changes back to alice.

    is(ProcessChangesUntilNoChange(changes, alice_account, bob_account, carol_account, NULL), 1, "updates");

    ok(AssertCreds(alice_account, cfaccount, cfpassword), "Setting credentials for Alice");
    ok(AssertCreds(carol_account, cfaccount, cfpassword), "Setting credentials for Carol");
    CFReleaseNull(cfpassword);
    
    /* Make Alice First Peer -------------------------------------------------------------------------------*/
    ok(ResetToOffering(alice_account), "Reset to offering - Alice as first peer");
    
    is(ProcessChangesUntilNoChange(changes, alice_account, bob_account, carol_account, NULL), 2, "updates");

    /* Bob Joins -------------------------------------------------------------------------------------------*/
    ok(JoinCircle(bob_account), "Bob Applies");
    
    is(ProcessChangesUntilNoChange(changes, alice_account, bob_account, carol_account, NULL), 2, "updates");

    /* Alice Accepts -------------------------------------------------------------------------------------------*/
    ok(AcceptApplicants(alice_account, 1), "Alice Accepts Bob's Application");
    
    is(ProcessChangesUntilNoChange(changes, alice_account, bob_account, carol_account, NULL), 3, "4 updates");
    accounts_agree("bob&alice pair", bob_account, alice_account);
    
    /* Carol Applies -------------------------------------------------------------------------------------------*/
    ok(JoinCircle(carol_account), "Carol Applies");
    
    is(ProcessChangesUntilNoChange(changes, alice_account, bob_account, carol_account, NULL), 2, "updates");
    is(countPeers(alice_account), 2, "See two peers");
    
    
    /* Change Password ------------------------------------------------------------------------------------------*/
    CFDataRef cfnewpassword = CFDataCreate(NULL, (uint8_t *) "ooFooFooF", 10);
    
    ok(AssertCreds(bob_account , cfaccount, cfnewpassword), "Credential resetting for Bob");
    is(countPeers(bob_account), 2, "There are two valid peers - iCloud and Bob");
    is(countActivePeers(bob_account), 3, "There are three active peers - bob, alice, and iCloud");
    is(countActiveValidPeers(bob_account), 2, "There is two active valid peer - Bob and iCloud");
    
    is(ProcessChangesUntilNoChange(changes, alice_account, bob_account, carol_account, NULL), 2, "updates");

    ok(AssertCreds(alice_account , cfaccount, cfnewpassword), "Credential resetting for Alice");
    
    is(ProcessChangesUntilNoChange(changes, alice_account, bob_account, carol_account, NULL), 3, "updates");

    is(countPeers(alice_account), 2, "There are two peers - bob and alice");
    is(countActiveValidPeers(alice_account), 3, "There are three active valid peers - alice, bob, and icloud");
    
    is(ProcessChangesUntilNoChange(changes, alice_account, bob_account, carol_account, NULL), 1, "updates");

    accounts_agree("bob&alice pair", bob_account, alice_account);
    is(countPeers(alice_account), 2, "There are two peers - bob and alice");
    is(countActiveValidPeers(alice_account), 3, "There are three active valid peers - alice, bob, and icloud");
    
    ok(AssertCreds(carol_account , cfaccount, cfnewpassword), "Credential resetting for Carol");

    is(ProcessChangesUntilNoChange(changes, alice_account, bob_account, carol_account, NULL), 1, "updates");
    is(ProcessChangesUntilNoChange(changes, alice_account, bob_account, carol_account, NULL), 2, "updates");

    accounts_agree("bob&alice pair", bob_account, alice_account);
    accounts_agree_internal("bob&carol pair", bob_account, carol_account, false);

    ok(AcceptApplicants(alice_account , 1), "Alice Accepts Carol's Application");
    
    is(ProcessChangesUntilNoChange(changes, alice_account, bob_account, carol_account, NULL), 4, "updates");

    accounts_agree_internal("bob&alice pair", bob_account, alice_account, false);
    accounts_agree_internal("bob&carol pair", bob_account, carol_account, false);
    accounts_agree_internal("carol&alice pair", alice_account, carol_account, false);
    
    
    /* Change Password 2 ----------------------------------------------------------------------------------------*/
    CFReleaseNull(cfnewpassword);
    cfnewpassword = CFDataCreate(NULL, (uint8_t *) "ffoffoffo", 10);
    
    /* Bob */
    ok(AssertCreds(bob_account , cfaccount, cfnewpassword), "Credential resetting for Bob");
    is(ProcessChangesUntilNoChange(changes, alice_account, bob_account, carol_account, NULL), 2, "updates");

    is(countPeers(bob_account), 3, "There are three peers - Alice, Carol, Bob");
    is(countActivePeers(bob_account), 4, "There are four active peers - bob, alice, carol and iCloud");
    is(countActiveValidPeers(bob_account), 2, "There is two active valid peer - Bob and iCloud");
    

    /* Alice */
    ok(AssertCreds(alice_account , cfaccount, cfnewpassword), "Credential resetting for Alice");
    is(ProcessChangesUntilNoChange(changes, alice_account, bob_account, carol_account, NULL), 3, "updates");

    is(countPeers(alice_account), 3, "There are three peers - Alice, Carol, Bob");
    is(countActivePeers(alice_account), 4, "There are four active peers - bob, alice, carol and iCloud");
    is(countActiveValidPeers(alice_account), 3, "There are three active valid peers - alice, bob, and icloud");

    
    /* Carol */
    ok(AssertCreds(carol_account , cfaccount, cfnewpassword), "Credential resetting for Carol");
    is(ProcessChangesUntilNoChange(changes, alice_account, bob_account, carol_account, NULL), 4, "updates");

    is(countPeers(carol_account), 3, "There are three peers - Alice, Carol, Bob");
    is(countActivePeers(carol_account), 4, "There are four active peers - bob, alice, carol and iCloud");
    is(countActiveValidPeers(carol_account), 4, "There are three active valid peers - alice, bob, carol, and icloud");
    
    accounts_agree_internal("bob&alice pair", bob_account, alice_account, false);

    /* Change Password 3 - cause a parm lost update collision ----------------------------------------------------*/
    CFReleaseNull(cfnewpassword);
    cfnewpassword = CFDataCreate(NULL, (uint8_t *) "cococococ", 10);
    
    ok(AssertCreds(bob_account , cfaccount, cfnewpassword), "Credential resetting for Bob");
    ok(AssertCreds(alice_account , cfaccount, cfnewpassword), "Credential resetting for Alice");
    is(ProcessChangesUntilNoChange(changes, alice_account, bob_account, carol_account, NULL), 4, "updates");

    is(countPeers(alice_account), 3, "There are three peers - Alice, Carol, Bob");
    is(countActivePeers(alice_account), 4, "There are four active peers - bob, alice, carol and iCloud");
    is(countActiveValidPeers(alice_account), 3, "There are three active valid peers - alice, bob, and icloud");

    /* Change Password 4 - new peer changes the password and joins ----------------------------------------------------*/
    CFReleaseNull(cfnewpassword);
    cfnewpassword = CFDataCreate(NULL, (uint8_t *) "dodododod", 10);

    SOSAccount* david_account = CreateAccountForLocalChanges(CFSTR("David"), CFSTR("TestSource"));
    ok(AssertCreds(david_account , cfaccount, cfnewpassword), "Credential resetting for David");
    is(ProcessChangesUntilNoChange(changes, david_account, NULL), 2, "updates");
    is(countPeers(david_account), 3, "Still 3 peers");
    
    
    ok(JoinCircle(david_account), "David Applies");
    is(ProcessChangesUntilNoChange(changes, david_account, NULL), 2, "updates");
    is(countPeers(david_account), 1, "Only David is in circle");
    

    CFReleaseNull(cfnewpassword);
    alice_account = nil;
    bob_account = nil;
    carol_account = nil;
    david_account = nil;
    SOSTestCleanup();
}

int secd_58_password_change(int argc, char *const *argv)
{
    plan_tests(211);
    
    secd_test_setup_temp_keychain(__FUNCTION__, NULL);

    tests();
    
    return 0;
}
