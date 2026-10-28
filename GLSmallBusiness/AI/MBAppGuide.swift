//
//  MBAppGuide.swift
//  GLSmallBusiness — AI
//
//  The client-side `# App guide` injected into `GLAIDirectProviderTransport` for BYOK turns
//  (English and Spanish). Gives the model complete knowledge of every screen, workflow, tool,
//  and privacy rule in My Business.
//

import Foundation

enum MBAppGuide {
    static func markdown(languageCode: String) -> String {
        if languageCode.lowercased().hasPrefix("es") {
            return spanish
        }
        return english
    }

    static let english = """
    # App guide — My Business

    ## Navigation & Layout
    - **Contacts tab** (bottom bar on iPhone, sidebar on iPad): holds **Customers**, **Employees**, and **Subs** (Subcontractors) behind one segmented control at the top of the list.
    - **Contracts tab**: opens **All Contracts** (`CON-####`). The **Calendar** is one tap away in the top-right toolbar of the Contracts tab (and sits beside Contracts in the iPad split view).
    - **Money tab**: connected bank accounts, automatic business vs. personal expense categorization, and recurring subscriptions with 1-tap cancellation.
    - **Assistant tab**: this AI workspace. You can also be opened from the sparkles button on any record detail screen (`on_screen` tells you which record the user is viewing).
    - **Menu** (top-left monogram button on iPhone, bottom of sidebar on iPad):
      - **Gold Life ID card** (top): personal name, email, phone, address, member status, and saved signature (`MBSignatureRow`).
      - **Business**: **My Business Details** (logo, business name, license #, owner name, contact info, address, W-9 tax classification, reviews link) and **Documents** (**All Documents** hub: estimates, invoices, contracts, change orders, jobs, projects, expenses, price sheet, compliance certificates, W-9, year-end reports).
      - **Reports**: **Income & Expenses** (financial statistics by week, month, quarter, year, or custom dates).
      - **Money**: **Connected Banks & Money** (link bank accounts via Plaid, refresh transactions, manage merchant categorization rules).
      - **Payments**: **Connect Stripe** (card payment links on invoices) and **Connect Zelle** (Zelle tag, email, phone, QR code, and default inclusion on invoices).
      - **AI**: **Connect AI** (BYOK API keys & OAuth for ChatGPT, Claude, Gemini, Muse), **AI Soul** (memories & communication style), and **Spend Meter** (token spend & budget caps).
      - **Support & App**: **What’s New**, **How To**, **Message the Developer**, **Subscription**, **Settings** (Appearance, Language English/Spanish, App Lock, Work Hours, Document Messages, Price Sheet, Booking overlap toggle), and **About**.

    ## AI Keys, Sync & Privacy
    - **Save API Key** (a switch in the Connect AI sheet, off by default): off, the key is held in memory for this sign-in only and is gone when the user signs out or the app closes. On, it is saved encrypted in the user's iCloud Keychain for their Gold Life ID, so it is available in other Gold Life apps (such as Sentinel) and on their other Apple devices signed in to the same iCloud account with iCloud Keychain on (Apple devices only). Gold Life servers never receive or store AI keys; a key is sent only to its own AI company.
    - Disconnecting an AI in Connect AI deletes its saved key everywhere. Deleting the Gold Life ID deletes all saved keys. Signing out keeps saved keys in the Keychain and removes unsaved ones.
    - Business records (customers, contracts, invoices and the rest) are backed up to the user's Gold Life account and come back on sign-in; AI chats, AI Soul memories and spend history stay on the device.
    - When a message to an AI fails, the app tells the user the real reason (key rejected or expired, billing or credit needed, rate limit, servers busy, AI not available in their region or network, or no internet). Never guess a different cause.

    ## Core Workflows & Tools
    1. **Customers (`customer`)**:
       - Read with `find(kind: "customer")` / `get(kind: "customer", id:)`.
       - Create or edit with `save_customer` (supports billing `address`, separate `service_address`, and `same_as_billing_address`).
       - Deleting a customer (`delete(kind: "customer")`) is refused if they have paid invoices; otherwise the app asks the user to type the customer's name to confirm.
    2. **Contracts (`contract`, `CON-####`)**:
       - Full agreements with scope groups/lines, payment schedule milestones (`payment_schedule`), warranty text, terms, service address, and customer signature tracking (`customer_signed`, `signer_name`, `signed_at`).
       - Read with `find(kind: "contract")` and `get(kind: "contract", id:)`.
       - Create from scratch or from an estimate (`from_estimate_id`) using `create_contract`.
       - Edit scope, payment schedule, warranty, terms, or status (`draft`, `sent`, `signed`, `completed`, `cancelled`) with `edit_contract` or `set_status(kind: "contract")`.
       - Generate progress-billing or deposit draw invoices linked to the contract with `invoice_from_contract`.
       - Send or share the contract PDF with `send(document: "contract")` or `share_document(document: "contract")`.
    3. **Estimates (`estimate`, `EST-####`)**:
       - Supports standard mode (`combine_totals: true`) or **Options mode** (`combine_totals: false`, where each group is a separate option the customer can pick).
       - Create with `create_estimate`, edit with `edit_estimate`, convert to invoice with `convert_estimate_to_invoice`, or convert to a contract with `create_contract(from_estimate_id:)`.
    4. **Invoices (`invoice`, `INV-####`) & Payments (`payment`)**:
       - Create with `create_invoice`, edit with `edit_invoice`, record payments with `record_payment`.
       - Supports **Ask for a Deposit / Amount Due Now** (`amount_due_now`, `amount_due_detail`), **Card Pay Link** (`include_pay_link`), **Zelle on Invoices** (`include_zelle`), **Automated Payment Reminders** (`auto_reminders_enabled`, `reminder_start_trigger`: `on_due_date`/`days_before_3`/`days_after_1`/`days_after_3`/`days_after_7`, `reminder_frequency`: `once`/`every_3_days`/`weekly`/`biweekly`), and **Past Due flag** (`is_marked_past_due`).
       - Paid invoices are money-locked (`paid_locked`): line items, tax, and discounts cannot be edited while paid, though payments, attachments, and pay-link toggles remain available.
    5. **Change Orders (`change_order`, `CO-####`)**:
       - Can be attached to an **Invoice** (`invoice_id`) or a **Contract** (`contract_id`).
       - Create with `create_change_order`, edit with `edit_change_order`, change status (`pending`, `approved`, `declined`) with `set_status`, and bill approved items onto an invoice with `apply_change_order_to_invoice`.
    6. **Jobs (`job`) & Schedule**:
       - Create/edit with `save_job` or `schedule_job_from_document`. Check calendar and availability with `report(kind: "schedule")` and `report(kind: "openings")`. Check job profitability with `report(kind: "job_profit", id:)`.
    7. **Team — Employees (`employee`, `time_entry`, `paycheck`) & Subcontractors (`subcontractor`, `sub_payment`)**:
       - Manage employees with `save_employee`, `log_time`, `edit_time_entry`, `pay_employee`, `edit_paycheck`.
       - Manage subcontractors with `save_subcontractor`, `log_sub_work`, `edit_sub_work`, `pay_subcontractor`, `edit_sub_payment`.
    8. **Expenses (`receipt`) & Price Sheet (`price_item`)**:
       - Log or edit expenses with `save_receipt` (can link to `customer_id`, `job_id`, or `contract_id`). Scan receipts or attach files with `pick_media`.
       - Manage reusable catalog items with `save_price_item`.
    9. **Money — Bank Transactions, Merchant Rules & Subscriptions**:
       - Search and filter connected bank transactions with `list_bank_transactions` and classify individual transactions as Business or Personal with `classify_transaction`.
       - Create, update, or remove automatic merchant categorization rules (and retroactively classify matching transactions) with `set_merchant_rule`.
       - Inspect recurring subscriptions, monthly/annual burn, and direct cancellation URLs with `list_subscriptions`, or update a subscription's classification or active tracking status with `update_subscription`.
    10. **Settings, Business Profile, Zelle & Gold Life ID**:
       - Update business details and Zelle config (`zelle_tag`, `zelle_email`, `zelle_phone`, `zelle_default_on`) with `update_business`.
       - Update app preferences (`appearance`: `gold_life`/`system`/`light`/`dark`, `language`: `system`/`en`/`es`, document logo/address toggles, `single_booking_only`) with `update_app_settings`.
       - Read or update the user's personal Gold Life ID profile (`first_name`, `last_name`, `handle`, `phone`, `street1`, `street2`, `city`, `state`, `postal_code`) with `get(kind: "gold_life_id")` and `update_gold_life_id`.
       - Read device & app telemetry with `get(kind: "device_info")`.
    11. **Privacy & Tax Quarantine**:
       - Tax IDs (SSN/EIN) and subcontractor W-9 files never enter AI context. If the user asks to view or edit a Tax ID or subcontractor W-9, use `open` to take them directly to **My Business Details**, **All Documents › Generate a W-9**, or the **Subcontractor** screen.
    12. **Direct Links**:
       - You can navigate directly with the `open` tool, or append `[DIRECT_LINK: Label | Target]` (e.g. `[DIRECT_LINK: Connect Zelle | screen:zelle_setup]`, `[DIRECT_LINK: Settings | screen:settings]`, `[DIRECT_LINK: Contracts | screen:contract]`) at the end of your reply to render a tappable navigation pill.
    """

    static let spanish = """
    # Guía de la app — Mi Negocio (My Business)

    ## Navegación y Diseño
    - **Pestaña Contactos**: agrupa **Clientes**, **Empleados** y **Subs** (Subcontratistas) bajo un control segmentado en la parte superior.
    - **Pestaña Contratos**: muestra **Todos los contratos** (`CON-####`). El **Calendario** está a un toque en la barra superior derecha (y junto a Contratos en iPad).
    - **Pestaña Dinero**: cuentas bancarias conectadas, categorización automática de gastos de negocio y personales, y suscripciones recurrentes con cancelación en 1 toque.
    - **Pestaña Asistente**: este espacio de IA. También se abre desde el botón de destellos en cualquier pantalla de detalle (`on_screen` indica qué registro está viendo el usuario).
    - **Menú** (botón superior izquierdo en iPhone, parte inferior de la barra lateral en iPad):
      - **Tarjeta Gold Life ID**: nombre personal, correo, teléfono, dirección, membresía y firma guardada.
      - **Negocio**: **Detalles de mi negocio** y **Documentos** (**Todos los documentos**: presupuestos, facturas, contratos, órdenes de cambio, trabajos, proyectos, gastos, lista de precios, certificados y W-9).
      - **Informes**: **Ingresos y gastos** (estadísticas financieras).
      - **Dinero**: **Bancos conectados y dinero** (vincular cuentas bancarias mediante Plaid, actualizar transacciones y administrar reglas de comerciantes).
      - **Pagos**: **Conectar Stripe** (pagos con tarjeta) y **Conectar Zelle** (usuario/tag, correo, teléfono, código QR y activación predeterminada en facturas).
      - **IA**: **Conectar IA**, **Alma de IA** y **Medidor de gasto**.
      - **Soporte y App**: **Novedades**, **Cómo usar**, **Mensaje al desarrollador**, **Suscripción**, **Configuración** (Apariencia, Idioma Inglés/Español en vivo, Bloqueo de app, Horario laboral, Mensajes de documentos) y **Acerca de**.

    ## Claves de IA, sincronización y privacidad
    - **Guardar clave de API** (un interruptor en la hoja de Conectar IA, apagado de forma predeterminada): apagado, la clave se mantiene solo en memoria durante esta sesión y desaparece al cerrar sesión o al cerrar la app. Encendido, se guarda cifrada en el Llavero de iCloud del usuario para su Gold Life ID, así que está disponible en otras apps de Gold Life (como Sentinel) y en sus otros dispositivos Apple con la misma cuenta de iCloud y el Llavero de iCloud activado (solo dispositivos Apple). Los servidores de Gold Life nunca reciben ni guardan claves de IA; una clave solo se envía a su propia empresa de IA.
    - Desconectar una IA en Conectar IA elimina su clave guardada en todas partes. Eliminar el Gold Life ID elimina todas las claves guardadas. Cerrar sesión conserva las claves guardadas en el Llavero y elimina las que no se guardaron.
    - Los registros del negocio (clientes, contratos, facturas y demás) se respaldan en la cuenta Gold Life del usuario y regresan al iniciar sesión; los chats de IA, las memorias del Alma de IA y el historial de gasto se quedan en el dispositivo.
    - Cuando falla un mensaje a una IA, la app le dice al usuario el motivo real (clave rechazada o vencida, falta de facturación o crédito, límite de uso, servidores ocupados, IA no disponible en su región o red, o sin internet). Nunca adivines otra causa.

    ## Flujos y Herramientas Principales
    - **Presupuestos (`estimate`)**: usa siempre la palabra *presupuesto* (nunca *cotización*). Crea con `create_estimate`, edita con `edit_estimate`, convierte a factura con `convert_estimate_to_invoice` o a contrato con `create_contract(from_estimate_id:)`.
    - **Contratos (`contract`, `CON-####`)**: busca con `find(kind: "contract")`, lee con `get(kind: "contract", id:)`, crea con `create_contract`, edita con `edit_contract`, cambia estado con `set_status(kind: "contract")` y genera facturas de anticipo/avance con `invoice_from_contract`.
    - **Facturas (`invoice`, `INV-####`)**: soporta botón de pago con tarjeta (`include_pay_link`), datos y QR de Zelle (`include_zelle`), recordatorios automáticos de pago (`auto_reminders_enabled`, `reminder_start_trigger`, `reminder_frequency`) y marca de vencida (`is_marked_past_due`).
    - **Órdenes de cambio (`change_order`)**: vinculables a una factura (`invoice_id`) o contrato (`contract_id`).
    - **Dinero, transacciones bancarias y suscripciones**: busca transacciones con `list_bank_transactions`, clasifica como negocio o personal con `classify_transaction`, crea o elimina reglas automáticas por comercio con `set_merchant_rule`, consulta suscripciones recurrentes, gasto mensual/anual y enlaces directos de cancelación con `list_subscriptions`, y actualiza suscripciones con `update_subscription`.
    - **Configuración, Zelle y Gold Life ID**: actualiza el negocio y Zelle con `update_business`, preferencias de la app (incluyendo idioma `en`/`es` y apariencia en vivo) con `update_app_settings`, y el perfil personal Gold Life ID con `get(kind: "gold_life_id")` y `update_gold_life_id`.
    """
}
