import Foundation
import Testing
@testable import WingcordCore

/// Walking a report tree.
///
/// The failure mode of a report flow is a submission whose breadcrumbs describe
/// a path the reader did not take — and that is a pure-data bug, which is
/// exactly what a value type lets a test catch without a network or a view.
@Suite("Report path")
struct ReportPathTests {

    /// The shape of Discord's own message tree, cut down to the branch the
    /// captured payload walks: root → Something else → too young → yes.
    private var menu: ReportMenu {
        ReportMenu(
            name: "message",
            variant: "8",
            version: "1.0",
            rootNodeID: 7,
            nodes: [
                7: ReportNode(
                    id: 7,
                    header: "Report Message",
                    elements: [.subjectPreview],
                    children: [
                        ReportChoice(label: "Spam", nodeID: 98),
                        ReportChoice(label: "Something else", nodeID: 80),
                    ]
                ),
                80: ReportNode(
                    id: 80,
                    header: "How can we help?",
                    children: [
                        ReportChoice(label: "This person is too young", nodeID: 91),
                    ]
                ),
                91: ReportNode(
                    id: 91,
                    header: "Do they state their age?",
                    children: [
                        ReportChoice(label: "Yes, they state their age", nodeID: 127),
                    ]
                ),
                127: ReportNode(
                    id: 127,
                    header: "Report Summary",
                    button: .submit,
                    elements: [.subjectPreview, .breadcrumbs],
                    reportType: "sub_coppa"
                ),
                79: ReportNode(
                    id: 79,
                    header: "What information was posted?",
                    button: .next(17),
                    elements: [
                        .checkbox(
                            name: "pii_select",
                            options: [
                                ReportOption(value: "face_pic", label: "Face pic"),
                                ReportOption(value: "ip_address", label: "IP address"),
                                ReportOption(value: "legal_name", label: "Legal name"),
                            ]
                        )
                    ]
                ),
                17: ReportNode(id: 17, header: "Report Summary", button: .submit),
            ]
        )
    }

    @Test("The breadcrumbs are the ids walked, root first")
    func breadcrumbsAreTheWalk() {
        var path = ReportPath(root: menu.rootNodeID)
        path.push(80, label: "Something else")
        path.push(91, label: "This person is too young")
        path.push(127, label: "Yes, they state their age")

        #expect(path.nodeIDs == [7, 80, 91, 127])
        #expect(path.currentNodeID == 127)
        #expect(
            path.labels == [
                "Something else", "This person is too young", "Yes, they state their age",
            ]
        )
    }

    @Test("A button step contributes an id and no summary line")
    func buttonStepsAreSilent() {
        var path = ReportPath(root: 79)
        path.push(17, label: nil)
        #expect(path.nodeIDs == [79, 17])
        #expect(path.labels.isEmpty)
    }

    @Test("Back undoes exactly one step, and stops at the root")
    func backIsTheInverse() {
        var path = ReportPath(root: menu.rootNodeID)
        path.push(80, label: "Something else")
        path.push(91, label: "Too young")
        path.pop()
        #expect(path.nodeIDs == [7, 80])
        #expect(path.labels == ["Something else"])
        path.pop()
        #expect(!path.canGoBack)
        path.pop()
        #expect(path.nodeIDs == [7])
    }

    @Test("A checkbox page is unsatisfied until something is ticked")
    func checkboxIsRequired() {
        var path = ReportPath(root: 79)
        let node = menu[79]!
        #expect(!path.satisfies(node))
        path.toggle("face_pic", in: "pii_select")
        #expect(path.satisfies(node))
        path.toggle("face_pic", in: "pii_select")
        #expect(!path.satisfies(node))
    }

    @Test("A node with no checkbox is satisfied by existing")
    func plainNodesAreSatisfied() {
        let path = ReportPath(root: menu.rootNodeID)
        #expect(path.satisfies(menu[127]!))
    }

    @Test("Submitted elements keep the node's own order, not the tick order")
    func elementsFollowTheNode() {
        var path = ReportPath(root: 79)
        path.toggle("legal_name", in: "pii_select")
        path.toggle("face_pic", in: "pii_select")
        // Ticked last-first; submitted in the order the page offered them, so a
        // reader and a moderator read the same list.
        #expect(path.submissionElements(in: menu) == ["pii_select": ["face_pic", "legal_name"]])
    }

    @Test("An untouched checkbox contributes no key at all")
    func emptySelectionsAreAbsent() {
        var path = ReportPath(root: 79)
        path.toggle("face_pic", in: "pii_select")
        path.toggle("face_pic", in: "pii_select")
        // An empty array is a claim the reader did not make.
        #expect(path.submissionElements(in: menu).isEmpty)
    }

    @Test("A node's own kind decides whether it submits")
    func submissionIsANodeProperty() {
        #expect(menu[127]!.submits)
        #expect(!menu[80]!.submits)
        #expect(ReportNode(id: 1, header: "", isAutoSubmit: true).submits)
    }
}

/// Folding a quoted body into the one line a reply header can show.
@Suite("Quoted excerpts")
struct MessageExcerptTests {

    @Test("Markdown is folded and newlines collapse to spaces")
    func oneLine() {
        #expect(MessageReference.excerpt(of: "**bold** and\nanother line") == "bold and another line")
        #expect(MessageReference.excerpt(of: "  spaced   out  ") == "spaced out")
        #expect(MessageReference.excerpt(of: "") == "")
    }

    @Test("A code block is not carried around in every message that quotes it")
    func longBodiesAreCut() {
        #expect(MessageReference.excerpt(of: String(repeating: "a", count: 500)).count == 180)
    }

    @Test("A body that is only whitespace folds to nothing rather than to a space")
    func whitespaceOnly() {
        #expect(MessageReference.excerpt(of: "   \n\n  ") == "")
    }
}
