import Foundation

/// Builds the bug report a user files, and works out which crash report to
/// tell them to attach.
///
/// The app has no telemetry and is never getting any — so the only way a
/// problem reaches us is a person choosing to describe it. Everything here
/// exists to make that cheap: the facts we would otherwise ask for are filled
/// in, and if the app has crashed recently the report is named rather than
/// described, because "attach your crash log" sends people to a folder they
/// have never opened.
///
/// Nothing in this file touches the network or the disk. It turns facts into a
/// URL and a filename; the app collects the facts, opens the URL and reveals
/// the file.
public enum ProblemReport {

    /// What we would otherwise have to ask the reporter for, and would get
    /// wrong or half-answered.
    public struct Environment: Equatable, Sendable {
        /// Marketing version — `1.1.1`.
        public let version: String
        /// Build number, which is the commit count. Tells two builds of the
        /// same version apart, which matters more than it sounds: a bug
        /// reported against `1.1.1` could be any of several dozen builds.
        public let build: String
        /// `26.0 (25A354)`. The build in brackets is the useful half — point
        /// releases have broken window chrome before.
        public let system: String
        /// `Mac15,3` rather than "MacBook Pro", because the identifier says
        /// which chip and the marketing name doesn't.
        public let model: String
        /// A report filed from a demo build describes a simulation, not the
        /// engine. Worth knowing before spending an hour on it.
        public let isSimulating: Bool

        public init(version: String, build: String, system: String, model: String, isSimulating: Bool) {
            self.version = version
            self.build = build
            self.system = system
            self.model = model
            self.isSimulating = isSimulating
        }
    }

    /// A crash report on disk, reduced to the two things that decide whether
    /// it is worth mentioning.
    public struct CrashReport: Equatable, Sendable {
        public let name: String
        public let modified: Date

        public init(name: String, modified: Date) {
            self.name = name
            self.modified = modified
        }
    }

    /// How far back a crash is still plausibly the one being reported.
    ///
    /// Two weeks, and the window is the whole point of the function. Without
    /// one, a crash from six months ago gets attached to an unrelated report
    /// about a mis-drawn row — which is worse than attaching nothing, because
    /// it sends the reading of it in a direction that has nothing to do with
    /// the bug.
    public static let crashWindow: TimeInterval = 14 * 24 * 60 * 60

    /// The newest crash report worth attaching, or nil.
    ///
    /// Takes the candidates and the current time as arguments so it stays a
    /// pure function — the app lists the folder, this decides.
    ///
    /// Matching is on the prefix macOS actually writes: `Current-` followed by
    /// a timestamp, `.ips` since Monterey. It is deliberately not a match on
    /// "contains Current", which would also pick up an unrelated app with
    /// Current in its name.
    public static func newestCrashReport(
        among candidates: [CrashReport],
        now: Date,
        window: TimeInterval = crashWindow
    ) -> CrashReport? {
        candidates
            .filter { $0.name.hasPrefix("Current-") && $0.name.hasSuffix(".ips") }
            .filter { now.timeIntervalSince($0.modified) <= window }
            // A report dated in the future is a clock that has been moved, not
            // a crash that hasn't happened yet. Keep it rather than dropping
            // it: it is still the newest thing on disk and still the one the
            // person is looking at.
            .max { $0.modified < $1.modified }
    }

    /// The issue body, as Markdown, with the questions still to answer.
    ///
    /// The blanks are deliberate and in this order: what happened comes first
    /// because it is the only thing we cannot work out ourselves, and the
    /// environment is last because it is already filled in and nobody needs to
    /// read past it.
    public static func body(environment: Environment, crashReport: String?) -> String {
        var out = """
            **What happened?**


            **What did you expect?**


            **Steps to reproduce**

            1.
            2.

            **Does `-simulate` reproduce it?** yes / no

            **Environment**

            - macOS version: \(environment.system)
            - Mac model: \(environment.model)
            - Current build: \(environment.version) (\(environment.build))
            """

        // Stated as a line in the report rather than folded into the build
        // number, because it changes what the report means.
        if environment.isSimulating {
            out += "\n- Running with `-simulate`, so this describes the simulated engine"
        }

        out += "\n\n**Details** (console output, screenshots)\n\n"

        if let crashReport {
            // Named, not described. The file has been revealed in Finder by
            // the time this is read, so the instruction is "drag the one that
            // is already selected", which is a thing a person can do.
            out += """
                <!--
                Current crashed recently and this report is the newest one:

                    \(crashReport)

                It has been revealed in Finder. Drag it into this box to attach
                it — it says where the crash happened, which is usually the
                whole answer. It contains no personal data beyond file paths.
                -->
                """
        } else {
            out += """
                <!--
                Screenshots help more than a description for anything visual —
                drag them into this box.
                -->
                """
        }

        return out
    }

    /// The prefilled "new issue" URL.
    ///
    /// **The body has to be passed as a query parameter rather than a
    /// template**, because GitHub lets one or the other win and it is the
    /// parameter: asking for `template=bug_report.md` *and* a body silently
    /// discards the template. So the shape of the body above deliberately
    /// mirrors `.github/ISSUE_TEMPLATE/bug_report.md`, and the two want
    /// changing together.
    public static func issueURL(
        repository: String,
        environment: Environment,
        crashReport: String?
    ) -> URL? {
        // Encoded by hand because `URLComponents` leaves `+` alone in a query,
        // and GitHub reads a `+` as a space — so any body containing one came
        // out mangled. Only the unreserved set survives; everything else,
        // including the newlines this body is mostly made of, gets escaped.
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        let text = body(environment: environment, crashReport: crashReport)
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            return nil
        }
        return URL(string: "https://github.com/\(repository)/issues/new?labels=bug&body=\(encoded)")
    }
}
