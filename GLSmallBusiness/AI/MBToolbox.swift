//
//  MBToolbox.swift
//  GLSmallBusiness — AI
//
//  The My Business toolbox (toolset mb-1): the two manifests the app ships in its bundle
//  (`tools.mb-1.json` — the server keeps a byte-identical copy — and `tools.mb-1.ondevice.json`),
//  each loaded through GoldLifeAI's `GLAIToolbox`, with this app's executors bound by name.
//
//  Every executor takes its summary and parameters FROM its manifest entry: the manifest is the
//  one source of truth (AI/README.md), so a tool can't describe itself differently from what the
//  server declares. The same read executors serve both toolboxes; on device the loop passes an
//  output budget (`GLAIToolContext.outputCharacterLimit`) and they answer shorter.
//
//  Every manifest tool is bound now (stage 4): the read tools, the core writes, the five areas'
//  writes, and the six hand-offs the host presents. `scheduled` is empty and `MBToolboxTests`
//  fails if anything in the manifest has no executor.
//

import Foundation
import GoldLifeAI

nonisolated enum MBToolboxError: Error, Equatable {
    case manifestMissing(String)
}

@MainActor
final class MBToolbox {
    static let toolset = "mb-1"
    static let onlineManifestName = "tools.mb-1"
    static let onDeviceManifestName = "tools.mb-1.ondevice"

    /// The last stage whose tools are ALL bound (see the header). Stage 4 is the finished toolbox.
    static let buildStage = 4

    /// Manifest tools not bound yet → the stage that binds them. Empty at stage 4.
    /// `undo_last_request` and `load_tools` are built into the conversation controller and never listed.
    static let scheduled: [String: Int] = [:]

    let online: GLAIToolbox
    let onDevice: GLAIToolbox

    init(environment: MBToolEnvironment, bundle: Bundle = .main) throws {
        // `GLAIToolbox(manifestURL:)` reads local files only (law 59).
        online = try GLAIToolbox(manifestURL: Self.manifestURL(Self.onlineManifestName, in: bundle))
        onDevice = try GLAIToolbox(manifestURL: Self.manifestURL(Self.onDeviceManifestName, in: bundle))
        online.bind(Self.readTools(for: online.manifest, environment: environment))
        online.bind(Self.writeTools(for: online.manifest, environment: environment))
        online.bind(Self.areaTools(for: online.manifest, environment: environment))
        online.bind(Self.handoffTools(for: online.manifest, environment: environment))
        // The offline toolbox never gets a write tool (law 12, and `GLAIOnDeviceTransport` refuses
        // an executor that isn't read-only).
        onDevice.bind(Self.readTools(for: onDevice.manifest, environment: environment))
    }

    static func manifestURL(_ name: String, in bundle: Bundle) throws -> URL {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw MBToolboxError.manifestMissing(name)
        }
        return url
    }

    /// The read executors for whichever of find / get / report / help the manifest lists.
    static func readTools(for manifest: GLAIManifest, environment: MBToolEnvironment) -> [any GLAITool] {
        var tools: [any GLAITool] = []
        if let entry = manifest.tool(named: "find") { tools.append(MBFindTool(entry: entry, env: environment)) }
        if let entry = manifest.tool(named: "get") { tools.append(MBGetTool(entry: entry, env: environment)) }
        if let entry = manifest.tool(named: "report") { tools.append(MBReportTool(entry: entry, env: environment)) }
        if let entry = manifest.tool(named: "help") { tools.append(MBHelpTool(entry: entry, env: environment)) }
        if let entry = manifest.tool(named: "list_bank_transactions") { tools.append(MBListBankTransactionsTool(entry: entry, env: environment)) }
        if let entry = manifest.tool(named: "list_subscriptions") { tools.append(MBListSubscriptionsTool(entry: entry, env: environment)) }
        return tools
    }

    /// The core write executors. Each one is a thin wrapper over a service in `Services/Domain/`
    /// (DOMAIN-SERVICES.md): the same save the matching button runs. Each is bound behind
    /// `MBWholeCentsGate`, so no amount with a fraction of a cent reaches it.
    static func writeTools(for manifest: GLAIManifest, environment: MBToolEnvironment) -> [any GLAITool] {
        var tools: [any GLAITool] = []
        func add(_ name: String, _ make: (GLAIManifest.Tool) -> any GLAITool) {
            guard let entry = manifest.tool(named: name) else { return }
            tools.append(MBWholeCentsGate(tool: make(entry)))
        }
        add("save_customer") { MBSaveCustomerTool(entry: $0, env: environment) }
        add("create_estimate") { MBCreateEstimateTool(entry: $0, env: environment) }
        add("edit_estimate") { MBEditEstimateTool(entry: $0, env: environment) }
        add("create_contract") { MBCreateContractTool(entry: $0, env: environment) }
        add("edit_contract") { MBEditContractTool(entry: $0, env: environment) }
        add("invoice_from_contract") { MBInvoiceFromContractTool(entry: $0, env: environment) }
        add("create_invoice") { MBCreateInvoiceTool(entry: $0, env: environment) }
        add("edit_invoice") { MBEditInvoiceTool(entry: $0, env: environment) }
        add("set_status") { MBSetStatusTool(entry: $0, env: environment) }
        add("save_job") { MBSaveJobTool(entry: $0, env: environment) }
        add("record_payment") { MBRecordPaymentTool(entry: $0, env: environment) }
        add("delete") { MBDeleteTool(entry: $0, env: environment) }
        return tools
    }

    /// The five areas' write executors (money, expenses, catalog, team, settings). Same rule as the
    /// core writes: each one is a thin wrapper over a service in `Services/Domain/`, bound behind
    /// `MBWholeCentsGate`.
    static func areaTools(for manifest: GLAIManifest, environment: MBToolEnvironment) -> [any GLAITool] {
        var tools: [any GLAITool] = []
        func add(_ name: String, _ make: (GLAIManifest.Tool) -> any GLAITool) {
            guard let entry = manifest.tool(named: name) else { return }
            tools.append(MBWholeCentsGate(tool: make(entry)))
        }
        add("save_change_order") { MBSaveChangeOrderTool(entry: $0, env: environment) }
        add("apply_change_order") { MBApplyChangeOrderTool(entry: $0, env: environment) }
        add("save_receipt") { MBSaveReceiptTool(entry: $0, env: environment) }
        add("save_price_item") { MBSavePriceItemTool(entry: $0, env: environment) }
        add("save_employee") { MBSaveEmployeeTool(entry: $0, env: environment) }
        add("log_time") { MBLogTimeTool(entry: $0, env: environment) }
        add("pay_employee") { MBPayEmployeeTool(entry: $0, env: environment) }
        add("edit_paycheck") { MBEditPaycheckTool(entry: $0, env: environment) }
        add("save_subcontractor") { MBSaveSubcontractorTool(entry: $0, env: environment) }
        add("log_sub_work") { MBLogSubWorkTool(entry: $0, env: environment) }
        add("pay_subcontractor") { MBPaySubcontractorTool(entry: $0, env: environment) }
        add("update_business") { MBUpdateBusinessTool(entry: $0, env: environment) }
        add("update_work_schedule") { MBUpdateWorkScheduleTool(entry: $0, env: environment) }
        add("update_app_settings") { MBUpdateAppSettingsTool(entry: $0, env: environment) }
        add("classify_transaction") { MBClassifyTransactionTool(entry: $0, env: environment) }
        add("set_merchant_rule") { MBSetMerchantRuleTool(entry: $0, env: environment) }
        add("update_subscription") { MBUpdateSubscriptionTool(entry: $0, env: environment) }
        add("save_project") { MBSaveProjectTool(entry: $0, env: environment) }
        add("set_document") { MBSetDocumentTool(entry: $0, env: environment) }
        return tools
    }

    /// The six tools that hand the person a screen, a composer, a share sheet or a picker. They
    /// write nothing themselves — `MBAIHandoffPresenter` shows the UI and the loop waits for it.
    static func handoffTools(for manifest: GLAIManifest, environment: MBToolEnvironment) -> [any GLAITool] {
        var tools: [any GLAITool] = []
        func add(_ name: String, _ make: (GLAIManifest.Tool) -> any GLAITool) {
            guard let entry = manifest.tool(named: name) else { return }
            tools.append(make(entry))
        }
        add("open") { MBOpenTool(entry: $0, env: environment) }
        add("send") { MBSendTool(entry: $0, env: environment) }
        add("pick_media") { MBPickMediaTool(entry: $0, env: environment) }
        add("share_document") { MBShareDocumentTool(entry: $0, env: environment) }
        add("save_to_contacts") { MBSaveToContactsTool(entry: $0, env: environment) }
        add("contact_developer") { MBContactDeveloperTool(entry: $0, env: environment) }
        return tools
    }
}

// MARK: - Whole cents

/// Money is entered in whole cents, through the assistant as on the forms (law 60, owner ruling
/// 2026-09-27). Every write tool is bound behind this gate: a call whose AMOUNT argument
/// (`MBArguments.amountKeys`) carries a fraction of a cent is refused before the tool runs, so
/// before anyone is asked to confirm it, as the model's own slip (`invalid_arguments`). The model
/// reads why and sends the amount again in whole cents. Prices, rates and percentages are not
/// amounts and pass through as sent.
@MainActor
struct MBWholeCentsGate: GLAITool {
    let tool: any GLAITool

    var name: String { tool.name }
    var summary: String { tool.summary }
    var parameters: GLAISchema { tool.parameters }
    var area: GLAIToolArea { tool.area }

    func run(_ call: GLAIToolCall, context: GLAIToolContext) async -> GLAIToolOutcome {
        if let refusal = MBArguments(json: call.arguments).centFractionRefusal() { return refusal }
        return await tool.run(call, context: context)
    }
}
