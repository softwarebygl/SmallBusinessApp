//
//  EmailHTML.swift
//  GLSmallBusiness
//
//  Shared HTML scaffolding for the branded emails (estimate, invoice, payment receipt).
//
//  Why a white "card": Mail (and most clients) render the compose/reading area in DARK mode, but
//  HTML email colors don't auto-adapt. Hardcoded dark text on a dark background is invisible — which
//  is exactly what made the old emails look blank. Wrapping the content in an explicit white card on
//  a light page keeps the logo, text, and figures readable in light AND dark Mail.
//

import Foundation

enum EmailHTML {
    /// Wraps the inner HTML in a white card on a light page so it reads on any Mail appearance.
    static func page(_ innerHTML: String) -> String {
        """
        <div style="margin:0;padding:24px 12px;background-color:#f4f1ea;">
          <div style="max-width:560px;margin:0 auto;background-color:#ffffff;border:1px solid #ece5d6;border-radius:16px;padding:30px 28px;font-family:-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif;color:#1c1c1e;font-size:15px;line-height:1.55;">
        \(innerHTML)
          </div>
        </div>
        """
    }

    /// A light, bordered key/value box (Total, Balance, …) with right-aligned amounts.
    static func summaryBox(_ rows: [(label: String, value: String, strong: Bool)]) -> String {
        let body = rows.map { row in
            let weight = row.strong ? "600" : "400"
            let labelColor = row.strong ? "#1c1c1e" : "#6b6b6b"
            return """
            <tr>
              <td style="padding:8px 16px;color:\(labelColor);font-weight:\(weight);">\(row.label)</td>
              <td style="padding:8px 16px;text-align:right;color:#1c1c1e;font-weight:\(weight);white-space:nowrap;">\(row.value)</td>
            </tr>
            """
        }.joined(separator: "\n")
        return """
        <table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;border-collapse:collapse;background-color:#faf8f3;border:1px solid #ece5d6;border-radius:12px;margin:6px 0 20px;overflow:hidden;">
        \(body)
        </table>
        """
    }
}
