import Foundation

public enum VariantMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case visual = "Visual", motion = "Motion", flow = "UX flow"
    public var id: String { rawValue }
}

public enum VariantEasing: String, Codable, CaseIterable, Identifiable, Sendable {
    case gentle = "Gentle", quick = "Quick", spring = "Spring"
    public var id: String { rawValue }
    public var css: String {
        switch self {
        case .gentle: "cubic-bezier(.2,0,.2,1)"
        case .quick: "cubic-bezier(0,0,.2,1)"
        case .spring: "cubic-bezier(.2,.9,.3,1.15)"
        }
    }
}

public enum VariantPresentation: String, Codable, CaseIterable, Identifiable, Sendable {
    case drawer = "Side panel", modal = "Dialog", inline = "Inline editing"
    public var id: String { rawValue }
}

/// A self-contained interaction prototype, saved with its source comment.
public struct ReviewVariant: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var parentID: UUID?
    public var family: String
    public var revision: Int = 1
    public var mode: VariantMode
    public var title: String
    public var rationale: String
    public var refinement: String = ""
    public var durationMS: Double
    public var distance: Double
    public var easing: VariantEasing
    public var presentation: VariantPresentation
    public var spacing: Double
    public var dimBackground: Bool
    public var version: String { revision == 1 ? family : "\(family).\(revision)" }
    public var filename: String { "variant-\(id.uuidString.lowercased()).html" }

    public static func presets(for mode: VariantMode) -> [Self] {
        switch mode {
        case .motion:
            [Self(family: "A", mode: mode, title: "Quick slide", rationale: "Short travel and a quick response.", durationMS: 140, distance: 16, easing: .quick, presentation: .drawer, spacing: 16, dimBackground: false),
             Self(family: "B", mode: mode, title: "Gentle fade", rationale: "A softer entrance with less movement.", durationMS: 220, distance: 8, easing: .gentle, presentation: .drawer, spacing: 16, dimBackground: true),
             Self(family: "C", mode: mode, title: "Spring", rationale: "A slight overshoot adds emphasis; try it at normal speed.", durationMS: 320, distance: 32, easing: .spring, presentation: .drawer, spacing: 16, dimBackground: false)]
        case .visual:
            [Self(family: "A", mode: mode, title: "Compact", rationale: "Tighter spacing keeps more information visible.", durationMS: 180, distance: 8, easing: .gentle, presentation: .drawer, spacing: 8, dimBackground: false),
             Self(family: "B", mode: mode, title: "Balanced", rationale: "More space separates labels and controls.", durationMS: 180, distance: 8, easing: .gentle, presentation: .drawer, spacing: 16, dimBackground: false),
             Self(family: "C", mode: mode, title: "Spacious", rationale: "Larger gaps emphasize individual decisions.", durationMS: 180, distance: 8, easing: .gentle, presentation: .drawer, spacing: 24, dimBackground: false)]
        case .flow:
            [Self(family: "A", mode: mode, title: "Side panel", rationale: "Edit while keeping the underlying page visible.", durationMS: 180, distance: 20, easing: .gentle, presentation: .drawer, spacing: 16, dimBackground: false),
             Self(family: "B", mode: mode, title: "Dialog", rationale: "Focus attention on one editing task.", durationMS: 180, distance: 8, easing: .gentle, presentation: .modal, spacing: 16, dimBackground: true),
             Self(family: "C", mode: mode, title: "Inline editing", rationale: "Edit in place without opening a separate surface.", durationMS: 180, distance: 0, easing: .gentle, presentation: .inline, spacing: 16, dimBackground: false)]
        }
    }

    public func implementationBrief(note: String) -> String {
        """
        Selected \(mode.rawValue) prototype \(version): \(title)
        Source feedback: \(note)
        Presentation: \(presentation.rawValue). Duration: \(Int(durationMS)) ms. Easing: \(easing.rawValue) (\(easing.css)). Travel: \(Int(distance)) px. Spacing: \(Int(spacing)) px. Dim background: \(dimBackground ? "yes" : "no").
        Refinement: \(refinement.isEmpty ? "None" : refinement)
        Prototype file: \(filename)
        Adapt this generic prototype to the app's real components. Support Save, Cancel, Escape, and reduced motion. Return a preview and code diff for review. This preference does not mark the original issue resolved.
        """
    }

    public var previewSettingsJSON: String {
        let settings: [String: Any] = [
            "duration": Int(min(1000, max(80, durationMS))), "travel": Int(min(80, max(0, distance))),
            "gap": Int(min(32, max(8, spacing))), "easing": easing.css,
            "dim": dimBackground ? 0.18 : 0,
            "presentation": presentation == .drawer ? "drawer" : presentation == .modal ? "modal" : "inline"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: .sortedKeys),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// No remote assets or user text in executable code. Opens in a browser without a build step.
    public func html(note: String) -> String {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
        }
        let duration = Int(min(1000, max(80, durationMS)))
        let travel = Int(min(80, max(0, distance)))
        let gap = Int(min(32, max(8, spacing)))
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(escaped(version + " · " + title))</title>
        <style>
        *{box-sizing:border-box}body{margin:0;color:#243047;background:#f3f5f9;font:14px -apple-system,BlinkMacSystemFont,sans-serif}
        button,input{font:inherit}button{cursor:pointer;border:1px solid #cfd6e1;border-radius:8px;padding:9px 12px;background:white;color:inherit}button.primary{background:#465be7;color:white;border-color:#465be7}button:focus-visible,input:focus-visible{outline:3px solid #8795ff;outline-offset:2px}
        header{padding:16px;border-bottom:1px solid #dfe4ed;background:white}header p{font-size:12px;color:#647087;margin:6px 0 0;white-space:pre-wrap;overflow-wrap:anywhere}
        main{padding:20px}.card{border:1px solid #dfe4ed;border-radius:12px;background:white;padding:18px}h2{font-size:18px;margin:0 0 12px}h3{font-size:16px;margin:0}p{line-height:1.5}.muted{color:#647087}.rows{display:grid;gap:var(--gap);margin:16px 0}.row{padding:10px;background:#f3f5f9;border-radius:8px}
        #scrim{position:fixed;inset:0;background:rgba(23,32,54,var(--dim));opacity:0;visibility:hidden;transition:opacity var(--duration) var(--easing)}
        :root{--duration:\(duration)ms;--travel:\(travel)px;--gap:\(gap)px;--easing:\(easing.css);--dim:\(dimBackground ? "0.18" : "0")}#panel{display:flex;flex-direction:column;gap:var(--gap);background:white;border:1px solid #dfe4ed;padding:20px;opacity:0;visibility:hidden;transform:translateX(var(--travel));transition:opacity var(--duration) var(--easing),transform var(--duration) var(--easing)}
        body.drawer #panel{position:fixed;right:0;top:0;bottom:0;width:min(85%,300px);box-shadow:-8px 0 30px #24304718;overflow:auto}
        body.modal #panel{position:fixed;left:50%;top:50%;width:min(85%,340px);max-height:90vh;overflow:auto;border-radius:14px;transform:translate(-50%,calc(-50% + var(--travel)));box-shadow:0 12px 40px #24304722}
        body.inline #panel{display:none;margin-top:16px;border-radius:10px;transform:translateY(var(--travel))}body.open.inline #panel{display:flex}
        body.open #panel{opacity:1;visibility:visible;transform:translate(0,0)}body.open.modal #panel{transform:translate(-50%,-50%)}body.open:not(.inline) #scrim{opacity:1;visibility:visible}
        label{display:grid;gap:6px}input{width:100%;padding:9px;border:1px solid #cfd6e1;border-radius:7px}footer{display:flex;gap:8px;justify-content:flex-end}#status{min-height:20px;color:#4355c4}
        @media(prefers-reduced-motion:reduce){#panel,#scrim{transition:none!important}}
        </style></head><body class="\(presentation == .drawer ? "drawer" : presentation == .modal ? "modal" : "inline")">
        <header><strong>\(escaped(version + " · " + title))</strong><p>Generic interactive prototype · \(escaped(note))</p></header>
        <main><div class="card"><h2>Project details</h2><p class="muted">Try opening, editing, saving, and cancelling.</p><div class="rows"><div class="row">Status · In progress</div><div class="row">Owner · Design team</div></div><button id="trigger" class="primary" onclick="openPanel()">Edit details</button><p id="status" role="status"></p>
        <div id="scrim" onclick="closePanel()"></div><section id="panel" aria-label="Edit project details" tabindex="-1"><h3>Edit details</h3><label>Project name<input id="name" value="Website refresh"></label><label>Owner<input value="Design team"></label><p class="muted">\(escaped(rationale))</p><footer><button onclick="closePanel()">Cancel</button><button class="primary" onclick="save()">Save</button></footer></section></div></main>
        <script>
        const panel=document.getElementById('panel'),trigger=document.getElementById('trigger');let replayTimer,baseDuration=\(duration);
        function applySettings(s,rate=1){baseDuration=s.duration;const style=document.documentElement.style;style.setProperty('--travel',s.travel+'px');style.setProperty('--gap',s.gap+'px');style.setProperty('--easing',s.easing);style.setProperty('--dim',s.dim);document.body.classList.remove('drawer','modal','inline');document.body.classList.add(s.presentation);replay(rate)}
        function openPanel(){document.body.classList.add('open');panel.focus()}
        function closePanel(){clearTimeout(replayTimer);document.body.classList.remove('open');trigger.focus()}
        function save(){document.getElementById('status').textContent='Saved: '+document.getElementById('name').value;closePanel()}
        function replay(rate=1){clearTimeout(replayTimer);document.documentElement.style.setProperty('--duration',(baseDuration/rate)+'ms');document.body.classList.remove('open');void panel.offsetWidth;replayTimer=setTimeout(openPanel,80)}
        document.addEventListener('keydown',e=>{if(e.key==='Escape')closePanel();if(e.key==='Tab'&&document.body.classList.contains('open')&&!document.body.classList.contains('inline')){const items=panel.querySelectorAll('input,button');const first=items[0],last=items[items.length-1];if(e.shiftKey&&(document.activeElement===first||document.activeElement===panel)){e.preventDefault();last.focus()}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus()}}});
        </script></body></html>
        """
    }
}
