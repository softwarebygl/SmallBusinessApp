//
//  DomainMoney.swift
//  GLSmallBusiness
//
//  Small shared money rules for the domain services, the models and the tool boundary.
//
//  THE ONE MONEY RULE (REQUIREMENTS law 60, owner ruling 2026-09-27). Every amount — a line total,
//  a discount, tax, a total, a deposit, a balance, an amount due, a paycheck — is rounded to the
//  cent ONCE, half-up (away from zero), on the amount as written: the Decimal the person's numbers
//  make, never the binary Double that only approximates it. So the math runs in `Decimal` from each
//  input's shortest spelling (`decimal(_:)`), each amount is rounded once (`cents(_:)`), and that
//  one value is what the screen, the PDF, the email, the assistant and the Stripe charge all use:
//
//    - a computed amount comes back already rounded (`roundedToCents`), so nothing downstream ever
//      holds an unrounded half cent;
//    - money TEXT goes through `.money` (FormatStyle below) — the same rule, so even a stored or
//      summed Double can never print a different cent than the one it rounds to here;
//    - a pay link charges `wholeCents(_:)` of the rounded amount, never `(amount × 100).rounded()`
//      of a binary value ($327.97499999999997 used to show $327.97 and charge $327.98).
//
//  MONEY IS ENTERED IN WHOLE CENTS (owner ruling 2026-09-27). An AMOUNT — a payment, a receipt
//  total, a deposit in dollars, a flat subcontractor or employee entry, a paycheck, a bonus, the
//  amount-due request, a job's agreed price — takes at most two decimals (`isWholeCents`): its form
//  field refuses a third decimal as it is typed (`AutoClearNumberField(wholeCents:)`), and the
//  assistant's call is refused with `invalid_arguments` so the model sends it again in whole cents
//  (`MBWholeCentsGate`). The services that store a typed amount (payments, receipts, flat entries,
//  paychecks, bonuses, the amount due, the agreed price) still round it to the cent when they write
//  it, so an older record re-saved from a form is stored the way it shows.
//  Wherever amounts are added (`roundedSum`, `Tally`), they are added exactly as written and the
//  sum is rounded once — the same rule, and the sync Worker's (its paid lock adds payments that
//  way). A stored amount written before this rule (or synced in from an older build) may still
//  carry a fraction of a cent; it counts as written, so such a total can read a cent off the sum
//  of the rows it adds.
//  Prices, rates and percentages (a unit price, an hourly rate, a discount, a deposit percentage)
//  are not amounts: the forms AND the assistant keep what was typed (`MBArguments.number`), and the
//  amounts made from them are rounded where they are computed.
//
//  The sync Worker's paid-invoice lock recomputes the invoice amounts with the same rule
//  (gl-business-api src/money.ts), so both sides always agree on Paid.
//

import Foundation
@_exported import GoldLifeDocuments

public typealias DomainMoney = GoldLifeDocuments.GLMoney
public typealias EstimateTotals = GoldLifeDocuments.GLDocumentTotals
public typealias ChangeOrderMath = GoldLifeDocuments.GLChangeOrderMath
public typealias InvoiceMath = GoldLifeDocuments.GLInvoiceMath

// MARK: - Money text

nonisolated extension FormatStyle where Self == FloatingPointFormatStyle<Double>.Currency {
    /// THE money text: US dollars, rounded half-up on the amount as written — the same cents
    /// `GLMoney.roundedToCents` gives and a pay link charges (law 60). The system's default
    /// currency style rounds ties to even ($1,000.025 → $1,000.02), so money never uses it directly.
    static var money: Self { .glMoney }

    /// `money` written the way the app's chosen language writes it (law 25) — what every SCREEN
    /// shows. `money` alone follows the phone's language: a Spanish-region phone with the app in
    /// English read "1.000,00 US$" beside English words (QA 2026-10-03 F132). Same cents, same
    /// half-up rule; only the symbol and separators follow the app. (GoldLifeDocuments' pattern:
    /// `.glMoney.locale(locale)`.)
    static var appMoney: Self { .glMoney.locale(MBLocalization.currentLocale) }

    /// The same rule in another currency (a screen that reads the locale's currency code).
    static func money(code: String) -> Self { .glMoney(code: code) }
}
