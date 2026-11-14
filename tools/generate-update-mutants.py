import difflib
from pathlib import Path


root = Path(__file__).resolve().parents[1]
versions = "Sources/GenieCore/UpdateCheck.swift"
fetcher = "Sources/GenieCore/UpdateReleaseFetcher.swift"

changes = {
    "upd-semver.patch": (versions, [
        ("""        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch""", "        lhs.description < rhs.description"),
    ]),
    "upd-prerelease.patch": (versions, [
        (".filter { !$0.draft && !$0.prerelease }", ".filter { !$0.draft }"),
    ]),
    "upd-tagre.patch": (versions, [
        ("guard !part.isEmpty, part.allSatisfy({ $0 >= \"0\" && $0 <= \"9\" }) else { return nil }",
         "guard !part.isEmpty, let first = part.first, first >= \"0\", first <= \"9\" else { return nil }"),
        ("return Int(part)", "return Int(part.prefix(while: { $0 >= \"0\" && $0 <= \"9\" }))"),
    ]),
    "upd-dateorder.patch": (versions, [
        ("            .max()", "            .first"),
    ]),
    "upd-skipeq.patch": (versions, [
        ("if let skipped, latest <= skipped { return .skipped(latest) }",
         "if let skipped, latest != skipped { return .skipped(latest) }"),
    ]),
    "upd-faildelay.patch": (versions, [
        ("nextDue = completedAt.addingTimeInterval(60 * 60)",
         "nextDue = completedAt.addingTimeInterval(24 * 60 * 60)"),
    ]),
    "upd-manualreset.patch": (versions, [
        ("self.completedAt = completedAt", "if self.completedAt == nil { self.completedAt = completedAt }"),
        ("nextDue = completedAt.addingTimeInterval(24 * 60 * 60)",
         "nextDue = (self.completedAt ?? completedAt).addingTimeInterval(24 * 60 * 60)"),
    ]),
    "upd-devcall.patch": (versions, [
        ("""        guard case .release(let current) = build else {
            if !loggedUnsupportedBuild {
                loggedUnsupportedBuild = true
                await emit(result: \"skipped_dev\", current: nil, latest: nil, code: nil, status: nil, gateKey: \"skipped_dev\")
            }
            return
        }""", "        let current = currentVersion ?? ReleaseVersion(raw: \"0.0.0\")!"),
    ]),
    "upd-inflight.patch": (versions, [
        ("        manualRequested = false", "        if phase == .idle { manualRequested = false }"),
        ("guard case .release = build, phase == .idle else { return }", "guard case .release = build else { return }"),
    ]),
    "upd-keepresult.patch": (versions, [
        ("            self.failure = failure\n            rateLimitReset = reset",
         "            self.failure = failure\n            decision = nil\n            rateLimitReset = reset"),
    ]),
    "upd-auth.patch": (fetcher, [
        ("        request.setValue(\"genie-in-messages-update-check\", forHTTPHeaderField: \"User-Agent\")",
         "        request.setValue(\"genie-in-messages-update-check\", forHTTPHeaderField: \"User-Agent\")\n        request.setValue(\"dummy\", forHTTPHeaderField: \"Authorization\")"),
    ]),
    "upd-htmlurl.patch": (versions, [
        ("https://github.com/ChihiroNishioka/genie-in-messages/releases/tag/\\(version.tag)",
         "https://api.github.com/repos/ChihiroNishioka/genie-in-messages/releases/\\(version.tag)"),
    ]),
    "upd-tz.patch": (versions, [
        ("formatter.timeZone = timeZone", "formatter.timeZone = TimeZone.current"),
    ]),
}


for filename, (relative_path, replacements) in changes.items():
    source_path = root / relative_path
    original = source_path.read_text(encoding="utf-8")
    mutated = original
    for before, after in replacements:
        if mutated.count(before) != 1:
            raise SystemExit(f"expected one source occurrence for {filename}: {before!r}")
        mutated = mutated.replace(before, after, 1)
    diff = difflib.unified_diff(
        original.splitlines(keepends=True),
        mutated.splitlines(keepends=True),
        fromfile=f"a/{relative_path}",
        tofile=f"b/{relative_path}",
        n=3,
    )
    patch = f"diff --git a/{relative_path} b/{relative_path}\n" + "".join(diff)
    (root / "tools/mutants" / filename).write_text(patch, encoding="utf-8")

print(f"generated={len(changes)}")
