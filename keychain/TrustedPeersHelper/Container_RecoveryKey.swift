import CoreData
import Foundation

extension Container {
    func preflightVouchWithRecoveryKey(recoveryKey: String,
                                       salt: String,
                                       reply: @escaping (String?, Set<String>?, TPPolicy?, Error?) -> Void) {
        self.semaphore.wait()
        let reply: (String?, Set<String>?, TPPolicy?, Error?) -> Void = {
            os_log("preflightRecoveryKey complete: %{public}@",
                   log: tplogTrace, type: .info, traceError($3))
            self.semaphore.signal()
            reply($0, $1, $2, $3)
        }

        self.fetchAndPersistChangesIfNeeded { fetchError in
            guard fetchError == nil else {
                os_log("preflightRecoveryKey unable to fetch current peers: %{public}@", log: tplogDebug, type: .default, (fetchError as CVarArg?) ?? "")
                reply(nil, nil, nil, fetchError)
                return
            }

            // Ensure we have all policy versions claimed by peers, including our sponsor
            self.fetchPolicyDocumentsWithSemaphore(versions: self.model.allPolicyVersions()) { _, fetchPolicyDocumentsError in
                guard fetchPolicyDocumentsError == nil else {
                    os_log("preflightRecoveryKey unable to fetch policy documents: %{public}@", log: tplogDebug, type: .default, (fetchPolicyDocumentsError as CVarArg?) ?? "no error")
                    reply(nil, nil, nil, fetchPolicyDocumentsError)
                    return
                }

                self.moc.performAndWait {
                    guard let egoPeerID = self.containerMO.egoPeerID,
                        let egoPermData = self.containerMO.egoPeerPermanentInfo,
                        let egoPermSig = self.containerMO.egoPeerPermanentInfoSig else {
                        os_log("preflightRecoveryKey: no ego peer ID", log: tplogDebug, type: .default)
                        reply(nil, nil, nil, ContainerError.noPreparedIdentity)
                        return
                    }

                    let keyFactory = TPECPublicKeyFactory()
                    guard let selfPermanentInfo = TPPeerPermanentInfo(peerID: egoPeerID, data: egoPermData, sig: egoPermSig, keyFactory: keyFactory) else {
                        reply(nil, nil, nil, ContainerError.invalidPermanentInfoOrSig)
                        return
                    }

                    var recoveryKeys: RecoveryKey
                    do {
                        recoveryKeys = try RecoveryKey(recoveryKeyString: recoveryKey, recoverySalt: salt)
                    } catch {
                        os_log("preflightRecoveryKey: failed to create recovery keys: %{public}@", log: tplogDebug, type: .default, error as CVarArg)
                        reply(nil, nil, nil, ContainerError.failedToCreateRecoveryKey)
                        return
                    }

                    // Dear model: if i were to use this recovery key, what peers would I end up using?
                    guard self.model.isRecoveryKeyEnrolled() else {
                        os_log("preflightRecoveryKey: recovery Key is not enrolled", log: tplogDebug, type: .default)
                        reply(nil, nil, nil, ContainerError.recoveryKeysNotEnrolled)
                        return
                    }

                    guard let sponsorPeerID = self.model.peerIDThatTrustsRecoveryKeys(TPRecoveryKeyPair(signingSPKI: recoveryKeys.peerKeys.signingKey.publicKey.keyData,
                                                                                                        encryptionSPKI: recoveryKeys.peerKeys.encryptionKey.publicKey.keyData)) else {
                                                                                                            os_log("preflightRecoveryKey Untrusted recovery key set", log: tplogDebug, type: .default)
                                                                                                            reply(nil, nil, nil, ContainerError.untrustedRecoveryKeys)
                                                                                                            return
                    }

                    guard let sponsor = self.model.peer(withID: sponsorPeerID) else {
                        os_log("preflightRecoveryKey Failed to find peer with ID", log: tplogDebug, type: .default)
                        reply(nil, nil, nil, ContainerError.sponsorNotRegistered(sponsorPeerID))
                        return
                    }

                    do {
                        let bestPolicy = try self.model.policy(forPeerIDs: sponsor.dynamicInfo?.includedPeerIDs ?? [sponsor.peerID],
                                                               candidatePeerID: egoPeerID,
                                                               candidateStableInfo: sponsor.stableInfo)

                        let views = try bestPolicy.views(forModel: selfPermanentInfo.modelID)
                        reply(recoveryKeys.peerKeys.peerID, views, bestPolicy, nil)
                    } catch {
                        os_log("preflightRecoveryKey: error fetching policy: %{public}@", log: tplogDebug, type: .default, error as CVarArg)
                        reply(nil, nil, nil, error)
                        return
                    }
                }
            }
        }
    }
}
