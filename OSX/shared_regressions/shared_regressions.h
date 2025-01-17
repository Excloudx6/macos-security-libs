/* To add a test:
 1) add it here
 2) Add it as command line argument for SecurityTest.app/SecurityTestOSX.app in the Release, Debug schemes, and World schemes
 3) Add any resource your test needs in to the SecurityTest.app, SecurityDevTest.app, and SecurityTestOSX.app targets.

 This file contains iOS/OSX shared tests that are built in libSharedRegression.a
 For iOS-only tests see Security_regressions.h
 */
#include <regressions/test/testmore.h>

ONE_TEST(si_21_sectrust_asr)
ONE_TEST(si_22_sectrust_iap)
#if !TARGET_OS_WATCH
ONE_TEST(si_23_sectrust_ocsp)
#else
DISABLED_ONE_TEST(si_23_sectrust_ocsp)
#endif
ONE_TEST(si_24_sectrust_itms)
ONE_TEST(si_24_sectrust_diginotar)
ONE_TEST(si_24_sectrust_digicert_malaysia)
ONE_TEST(si_24_sectrust_passbook)
ONE_TEST(si_25_cms_skid)
ONE_TEST(si_26_sectrust_copyproperties)
ONE_TEST(si_28_sectrustsettings)
ONE_TEST(si_29_cms_chain_mode)
ONE_TEST(si_32_sectrust_pinning_required)
ONE_TEST(si_34_cms_timestamp)
ONE_TEST(si_35_cms_expiration_time)
ONE_TEST(si_44_seckey_gen)
ONE_TEST(si_44_seckey_rsa)
ONE_TEST(si_44_seckey_ec)
ONE_TEST(si_44_seckey_ies)
ONE_TEST(si_44_seckey_aks)
#if TARGET_OS_IOS && !TARGET_OS_SIMULATOR
ONE_TEST(si_44_seckey_fv)
#endif
ONE_TEST(si_44_seckey_proxy)
ONE_TEST(si_60_cms)
ONE_TEST(si_61_pkcs12)
ONE_TEST(si_62_csr)
ONE_TEST(si_64_ossl_cms)
ONE_TEST(si_65_cms_cert_policy)
ONE_TEST(si_66_smime)
#if !TARGET_OS_WATCH
ONE_TEST(si_67_sectrust_blocklist)
ONE_TEST(si_84_sectrust_allowlist)
#else
DISABLED_ONE_TEST(si_67_sectrust_blocklist)
DISABLED_ONE_TEST(si_84_sectrust_allowlist)
#endif
ONE_TEST(si_68_secmatchissuer)
ONE_TEST(si_70_sectrust_unified)
ONE_TEST(si_71_mobile_store_policy)
ONE_TEST(si_74_OTA_PKI_Signer)
ONE_TEST(si_83_seccertificate_sighashalg)
ONE_TEST(si_88_sectrust_valid)
ONE_TEST(si_89_cms_hash_agility)
ONE_TEST(rk_01_recoverykey)

ONE_TEST(padding_00_mmcs)
