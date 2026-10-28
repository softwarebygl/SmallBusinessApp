//
//  AuditWalkthroughUITests.swift
//  GLSmallBusinessUITests
//
//  TEMPORARY (qa-audit 2026-10-03): walks every screen reachable in sample mode and attaches a
//  screenshot of each, for the audit's live walkthrough. Not a regression test: it skips unless
//  MB_AUDIT=1, and it never fails on a missing row (it attaches the tree and moves on).
//  Variants: MB_AUDIT_ES=1 (the app's own Spanish), MB_AUDIT_DARK=1, MB_AUDIT_XXXL=1.
//

import XCTest

final class AuditWalkthroughUITests: GLUITestCase {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static var spanish: Bool { env["MB_AUDIT_ES"] == "1" }

    override class var extraLaunchArguments: [String] {
        var extra: [String] = []
        if spanish { extra.append("-demoES") }
        if env["MB_AUDIT_DARK"] == "1" { extra.append("-demoDark") }
        if env["MB_AUDIT_XXXL"] == "1" {
            extra += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        return extra
    }

    private static let es: [String: String] = [
        "Contacts": "Contactos", "Jobs": "Trabajos", "Contracts": "Contratos", "Customers": "Clientes", "Employees": "Empleados",
        "Subs": "Subcontr.", "Menu": "Menú", "My Business Details": "Detalles de mi negocio",
        "Documents": "Documentos", "Income & Expenses": "Ingresos y gastos",
        "Connect Stripe": "Conectar Stripe", "Connect Zelle": "Conectar Zelle", "What’s New": "Novedades", "How To": "Guías",
        "Subscription": "Suscripción", "Settings": "Ajustes", "About": "Acerca de",
        "All Invoices": "Todas las facturas", "All Jobs": "Todos los trabajos",
        "All Projects": "Todos los proyectos", "All Change Orders": "Todas las órdenes de cambio",
        "All Expenses": "Todos los gastos", "Price Sheet": "Lista de precios",
        "Insurance & Licensing": "Seguro y licencias", "Generate a W-9": "Generar un W-9",
        "Income & Expenses (Year-End)": "Ingresos y gastos (fin de año)",
        "Employee Wages (Year-End)": "Sueldos de empleados (fin de año)",
        "Subcontractor 1099s (Year-End)": "1099 de subcontratistas (fin de año)",
        "More Info": "Más información", "Appearance": "Apariencia", "Language": "Idioma",
        "Add Customer": "Agregar cliente", "Add Employee": "Agregar empleado",
        "Add Subcontractor": "Agregar subcontratista", "Calendar": "Calendario", "Upgrade": "Mejorar plan",
        "Estimates": "Presupuestos", "Invoices": "Facturas", "Subscribe": "Suscribirse", "Work schedule": "Horario de trabajo",
        "Document Messages": "Mensajes de documentos",
    ]

    private func L(_ en: String) -> String { Self.spanish ? (Self.es[en] ?? en) : en }

    private var counter = 0

    private func shot(_ name: String, settle: UInt32 = 2) {
        sleep(settle)
        counter += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%02d-%@", counter, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tree(_ why: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "tree-\(why)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Taps the row/button titled `title` (scrolling to it); false (and a tree dump) when absent.
    @discardableResult
    private func go(_ title: String) -> Bool {
        let label = L(title)
        var target = app.row(label)
        var swipes = 0
        while !target.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
            target = app.row(label)
        }
        guard target.isHittable else { tree("missing-\(title)"); return false }
        target.tap()
        return true
    }

    /// Taps the first button whose label starts with `prefix` (rows whose label carries a value too).
    @discardableResult
    private func goPrefix(_ prefix: String) -> Bool {
        let label = L(prefix)
        let query = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label))
        var swipes = 0
        while !(query.firstMatch.exists && query.firstMatch.isHittable) && swipes < 8 {
            app.swipeUp(); swipes += 1
        }
        guard query.firstMatch.exists, query.firstMatch.isHittable else { tree("missing-prefix-\(prefix)"); return false }
        query.firstMatch.tap()
        return true
    }

    private func tapButton(_ title: String) -> Bool {
        let button = app.buttons[L(title)]
        guard button.waitForExistence(timeout: 4) else { tree("missing-button-\(title)"); return false }
        button.tap()
        return true
    }

    private func scrollShots(_ name: String, pages: Int) {
        for page in 1...pages {
            app.swipeUp()
            shot("\(name)-scroll\(page)", settle: 1)
        }
    }

    private func openMenu() -> Bool {
        app.tabBars.buttons[L("Contacts")].tap()
        return tapButton("Menu")
    }

    private func fresh() { relaunch() }

    func testWalkEveryScreen() throws {
        guard Self.env["MB_AUDIT"] == "1" else { throw XCTSkip("audit walkthrough driver") }
        continueAfterFailure = true

        // Contacts
        shot("customers")
        if go("Carter, Danielle") { shot("customer-hub"); scrollShots("customer-hub", pages: 2) }
        fresh(); app.openContacts("Customers")
        if go("Carter, Danielle"), go("More Info") { shot("customer-info"); scrollShots("customer-info", pages: 1) }
        fresh(); app.openContacts("Customers")
        if go("Reed, Marcus"), goPrefix("Estimates") { shot("customer-estimates"); if goPrefix("Master Bath") { shot("estimate-detail"); scrollShots("estimate-detail", pages: 3) } }
        fresh(); app.openContacts("Customers")
        if go("Carter, Danielle"), goPrefix("Invoices") { shot("customer-invoices"); if goPrefix("Luxury Vinyl") { shot("invoice-detail"); scrollShots("invoice-detail", pages: 3) } }
        fresh(); app.openContacts("Customers")
        if tapButton("Add Customer") { shot("form-new-customer") }

        fresh(); app.openContacts("Employees"); shot("employees")
        if go("Caldwell, Owen") { shot("employee-hub"); scrollShots("employee-hub", pages: 2) }
        fresh(); app.openContacts("Employees")
        if tapButton("Add Employee") { shot("form-new-employee") }

        fresh(); app.openContacts("Subcontractors"); shot("subcontractors")
        if go("Mendoza, Luis") || go("Mendoza Plumbing") { shot("subcontractor-hub"); scrollShots("subcontractor-hub", pages: 2) }
        fresh(); app.openContacts("Subcontractors")
        if tapButton("Add Subcontractor") { shot("form-new-subcontractor") }

        // Contracts
        fresh(); app.tabBars.buttons[L("Contracts")].tap(); shot("contracts")
        if tapButton("Calendar") { shot("calendar") }
        fresh(); app.tabBars.buttons[L("Contracts")].tap()
        if goPrefix("Bathroom regrout") { shot("contract-detail"); scrollShots("contract-detail", pages: 2) }

        // Menu and everything under it
        fresh(); if openMenu() { shot("menu"); scrollShots("menu", pages: 2) }
        fresh(); if openMenu(), go("My Business Details") { shot("company"); scrollShots("company", pages: 3) }
        for row in ["All Invoices", "All Jobs", "All Projects", "All Change Orders", "All Expenses", "Price Sheet",
                    "Insurance & Licensing", "Generate a W-9", "Income & Expenses (Year-End)",
                    "Employee Wages (Year-End)", "Subcontractor 1099s (Year-End)"] {
            fresh()
            guard openMenu(), go("Documents") else { continue }
            if row == "All Invoices" { shot("documents") }
            if go(row) { shot("doc-" + row.replacingOccurrences(of: " ", with: "_")) }
        }
        for row in ["Income & Expenses", "Connect Stripe", "Connect Zelle", "What’s New", "Subscription", "About"] {
            fresh()
            if openMenu(), go(row) { shot("menu-" + row.replacingOccurrences(of: " ", with: "_")); scrollShots("menu-" + row, pages: 2) }
        }
        fresh(); if openMenu(), go("How To") { shot("howto", settle: 8); scrollShots("howto", pages: 3) }
        fresh(); if openMenu(), go("Settings") { shot("settings"); scrollShots("settings", pages: 4) }
        fresh(); if openMenu(), go("Settings"), goPrefix("Appearance") { shot("settings-appearance") }
        fresh(); if openMenu(), go("Settings"), goPrefix("Language") { shot("settings-language") }
        fresh(); if openMenu(), go("Settings"), goPrefix("Work schedule") { shot("settings-work-schedule"); scrollShots("settings-work-schedule", pages: 1) }
        fresh(); if openMenu(), go("Settings"), goPrefix("Document Messages") { shot("settings-document-messages"); scrollShots("settings-document-messages", pages: 1) }
        fresh(); if openMenu(), go("Subscription"), tapButton("Subscribe") { shot("paywall-subscribe", settle: 5); scrollShots("paywall-subscribe", pages: 2) }
        fresh(); if openMenu(), goPrefix("Gold Life") { shot("gold-life-id", settle: 3); scrollShots("gold-life-id", pages: 2) }

        // Document details and the demo deep links
        for screen in ["estimate", "invoice", "receipts", "stats", "company", "1099", "stripe"] {
            relaunch(adding: ["-demoScreen", screen])
            shot("demo-\(screen)", settle: 6)
        }
    }
}
