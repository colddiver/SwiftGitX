//
//  Repository+merge.swift
//  SwiftGitX
//
//  Fast-forward pull: fetch + merge analysis + GIT_CHECKOUT_SAFE tree checkout
//  + branch ref update.  Added to support PHPDevKit's git pull feature since the
//  upstream SwiftGitX library has merge marked TODO.
//

import libgit2
import Foundation

extension Repository {

    /// Fetches from the remote and fast-forwards the current branch if possible.
    ///
    /// - Parameter remote: The remote to pull from. Defaults to the upstream of the
    ///   current branch, then "origin".
    ///
    /// - Throws: `SwiftGitXError` with code `.nonFastForward` when a non-fast-forward
    ///   merge would be required (diverged histories). Throws other codes for network
    ///   or reference errors.
    public func pull(remote: Remote? = nil) async throws(SwiftGitXError) {
        // ── Step 1: fetch ────────────────────────────────────────────────────
        try await fetch(remote: remote)

        // ── Step 2: read FETCH_HEAD ──────────────────────────────────────────
        // git writes the fetched commit OID as the first field (tab-delimited)
        // of the first line of .git/FETCH_HEAD immediately after a fetch.
        let workDir = try workingDirectory
        let fetchHeadURL = workDir
            .appendingPathComponent(".git")
            .appendingPathComponent("FETCH_HEAD")

        guard
            let content   = try? String(contentsOf: fetchHeadURL, encoding: .utf8),
            let firstLine = content.components(separatedBy: "\n").first,
            let oidHex    = firstLine.components(separatedBy: "\t").first?
                                     .trimmingCharacters(in: .whitespaces),
            !oidHex.isEmpty
        else {
            throw SwiftGitXError(code: .notFound, category: .fetchHead,
                                 message: "FETCH_HEAD not found after fetch.")
        }

        // ── Step 3: parse OID ────────────────────────────────────────────────
        var rawOID = git_oid()
        guard git_oid_fromstr(&rawOID, oidHex) == 0 else {
            throw SwiftGitXError(code: .invalidSpec, category: .fetchHead,
                                 message: "Invalid OID in FETCH_HEAD: \(oidHex)")
        }

        // ── Step 4: create annotated commit for merge analysis ───────────────
        let annotatedCommit: OpaquePointer = try git(operation: .fetch) {
            var ptr: OpaquePointer?
            let status = git_annotated_commit_lookup(&ptr, pointer, &rawOID)
            return (ptr, status)
        }
        defer { git_annotated_commit_free(annotatedCommit) }

        // ── Step 5: merge analysis ───────────────────────────────────────────
        var analysis   = GIT_MERGE_ANALYSIS_NONE
        var preference = GIT_MERGE_PREFERENCE_NONE

        // git_merge_analysis expects UnsafeMutablePointer<OpaquePointer?>.
        // Wrap in Optional so the pointer type matches const git_annotated_commit **.
        var theirHead: OpaquePointer? = annotatedCommit
        let analysisStatus = withUnsafeMutablePointer(to: &theirHead) { ptr in
            git_merge_analysis(&analysis, &preference, pointer, ptr, 1)
        }
        guard analysisStatus == 0 else {
            throw SwiftGitXError(code: .error, category: .merge,
                                 message: "Merge analysis failed.")
        }

        // ── Step 6: act on analysis result ───────────────────────────────────
        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
            // Nothing to do — local branch is already at or ahead of remote.
            return
        }

        guard analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0 else {
            // Diverged histories: a true merge commit would be needed.
            throw SwiftGitXError(
                code: .nonFastForward, category: .merge,
                message: "Non-fast-forward merge required. " +
                         "Commit or stash your local changes, then retry.")
        }

        // ── Fast-forward ─────────────────────────────────────────────────────

        // 6a. Checkout the commit tree using GIT_CHECKOUT_SAFE so that locally
        //     modified files that are NOT part of the incoming diff are preserved.
        let targetOID = git_annotated_commit_id(annotatedCommit)!.pointee

        let commitPtr = try ObjectFactory.lookupObjectPointer(
            oid: targetOID,
            type: GIT_OBJECT_COMMIT,
            repositoryPointer: pointer
        )
        defer { git_object_free(commitPtr) }

        var checkoutOpts = git_checkout_options()
        git_checkout_options_init(&checkoutOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOpts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue

        try git(operation: .checkout) {
            git_checkout_tree(pointer, commitPtr, &checkoutOpts)
        }

        // 6b. Advance the current branch reference to the new commit.
        //     (git_checkout_tree only updates the working tree + index, not HEAD.)
        var headRefPtr: OpaquePointer?
        guard git_repository_head(&headRefPtr, pointer) == 0, let headRef = headRefPtr else {
            throw SwiftGitXError(code: .notFound, category: .reference,
                                 message: "Could not resolve HEAD after checkout.")
        }
        defer { git_reference_free(headRef) }

        var updatedRefPtr: OpaquePointer?
        var mutableOID = targetOID
        guard git_reference_set_target(&updatedRefPtr, headRef, &mutableOID,
                                       "pull: Fast-forward") == 0 else {
            throw SwiftGitXError(code: .error, category: .reference,
                                 message: "Could not update branch reference after fast-forward.")
        }
        if let updated = updatedRefPtr { git_reference_free(updated) }
    }
}
