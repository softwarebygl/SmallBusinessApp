//
//  SubcontractorFormScreen.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/21/26.
//
//  Add / edit a subcontractor. Mirrors EmployeeFormScreen / CustomerFormScreen: a pushed Form
//  with the cream background, a trailing Save (the back button replaces Cancel), and an onSave
//  callback (iPad auto-select).
//  Tax details (W-9 / TIN) come in the tax-document round.
//

import SwiftUI
import GoldLifeUI
import SwiftData

struct SubcontractorFormScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var gold: Color { GLTheme.accentFill }

    let editing: Subcontractor?
    var onSave: ((Subcontractor) -> Void)? = nil

    @State private var firstName: String
    @State private var lastName: String
    @State private var businessName: String
    @State private var email: String
    @State private var phone: String
    @State private var street1: String
    @State private var street2: String
    @State private var city: String
    @State private var state: String
    @State private var postalCode: String
    @State private var isActive: Bool
    @State private var notes: String
    @State private var hourlyRate: Double
    @State private var w9TINType: W9TINType?
    @State private var w9TIN: String
    @State private var showingContactPicker = false
    @State private var tinSaveFailed = false
    @State private var tinRevealed = false   // their Tax ID stays masked until Face ID unlocks it
    /// In-flight guard: prevents a double-tap from inserting twice, but resets on a Tax-ID failure so
    /// the user can unlock and tap Save again (unlike SaveOnceButton, which would stay dead).
    @State private var isSaving = false
    /// On the add path, the subcontractor inserted on the first attempt — reused on a retry so a
    /// Tax-ID-failure re-save mutates the same record instead of creating a duplicate.
    @State private var insertedSubcontractor: Subcontractor?
    /// Set when a lapsed subscription refuses a write — the alert names it (ReadOnlyGate.swift).
    @State private var readOnlyRefusal: MBWriteOperation?
    /// A refusal SubcontractorService threw that the form did not predict (DomainErrorAlert.swift).
    @State private var domainError: DomainError?

    init(editing: Subcontractor? = nil, onSave: ((Subcontractor) -> Void)? = nil) {
        self.editing = editing
        self.onSave = onSave
        _firstName    = State(initialValue: editing?.firstName ?? "")
        _lastName     = State(initialValue: editing?.lastName ?? "")
        _businessName = State(initialValue: editing?.businessName ?? "")
        _email        = State(initialValue: editing?.email ?? "")
        _phone        = State(initialValue: editing?.phone ?? "")
        _street1      = State(initialValue: editing?.address.street1 ?? "")
        _street2      = State(initialValue: editing?.address.street2 ?? "")
        _city         = State(initialValue: editing?.address.city ?? "")
        _state        = State(initialValue: editing?.address.state ?? "")
        _postalCode   = State(initialValue: editing?.address.postalCode ?? "")
        _isActive     = State(initialValue: editing?.isActive ?? true)
        _notes        = State(initialValue: editing?.notes ?? "")
        _hourlyRate   = State(initialValue: editing?.hourlyRate ?? 0)
        _w9TINType    = State(initialValue: editing?.w9TINType)
        _w9TIN        = State(initialValue: editing?.secureTIN ?? "")
    }

    private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isValid: Bool {
        !trim(firstName).isEmpty || !trim(lastName).isEmpty || !trim(businessName).isEmpty
    }

    @State private var initialDigest: String?
    private var digest: String {
        "\(firstName)|\(lastName)|\(businessName)|\(email)|\(phone)|\(street1)|\(street2)|\(city)|\(state)|\(postalCode)|\(isActive)|\(notes)|\(hourlyRate)|\(w9TINType?.rawValue ?? "")|\(w9TIN)"
    }
    private var isDirty: Bool { initialDigest.map { $0 != digest } ?? false }

    var body: some View {
        Form {
            if editing == nil {
                Section {
                    HStack {
                        Button { showingContactPicker = true } label: {
                            Label("Import from Phone Contacts", systemImage: "person.crop.circle.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        InfoButton(text: "Pull a name, business, phone, email, and address from your phone's contacts.", topic: "Import from Phone Contacts")
                    }
                }
            }
            Section("Name") {
                TextField("First name", text: $firstName)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                TextField("Last name", text: $lastName)
                    .textContentType(.familyName)
                    .textInputAutocapitalization(.words)
            }
            Section("Business") {
                TextField("Business name (optional)", text: $businessName)
                    .textContentType(.organizationName)
                    .textInputAutocapitalization(.words)
            }
            Section("Contact") {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    #if !os(macOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                PhoneTextField(placeholder: "Phone", text: $phone)
            }
            Section("Address") {
                GLAddressField("Street", street: $street1, city: $city, state: $state, zip: $postalCode)
                    .textContentType(.streetAddressLine1)
                TextField("Apt / Suite (optional)", text: $street2)
                    .textContentType(.streetAddressLine2)
                TextField("City", text: $city)
                    .textContentType(.addressCity)
                TextField("State", text: $state)
                    .textContentType(.addressState)
                    .textInputAutocapitalization(.characters)
                TextField("Postal code", text: $postalCode)
                    .textContentType(.postalCode)
                    #if !os(macOS)
                    .keyboardType(.numberPad)
                    #endif
            }
            Section {
                LabeledContent("Hourly rate") {
                    AutoClearNumberField(placeholder: "$0.00", value: $hourlyRate, style: .currency)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                InfoLabel("Pay rate", info: "Optional. If set, you can log what you owe as “hours × rate.” Leave at $0 to enter flat amounts.", topic: "Pay rate")
            }
            Section {
                Picker("Taxpayer ID type", selection: $w9TINType) {
                    Text("Select…").tag(W9TINType?.none)
                    ForEach(W9TINType.allCases) { Text($0.label).tag(W9TINType?.some($0)) }
                }
                // While a stored number is still masked, switching the type would relabel digits
                // the owner can't see (an SSN stamped as "EIN" on their 1099-NEC), so the picker is
                // locked until the Tax ID is revealed — same reveal-before-mutate rule as the field
                // itself, mirroring the business W-9 form.
                .disabled(!tinRevealed && !w9TIN.isEmpty)
                .onChange(of: w9TINType) { _, _ in
                    // SSN and EIN formats differ, so switching type clears the old number — but only
                    // once revealed. While masked, w9TIN holds their real stored value the user can't
                    // see, so blanking it here would silently destroy an unseen SSN/EIN.
                    if tinRevealed { w9TIN = "" }
                }
                if tinRevealed {
                    LabeledContent(w9TINType?.label ?? mbLoc("Tax ID")) {
                        TINField(kind: w9TINType, text: $w9TIN)
                    }
                } else {
                    // Masked until Face ID — their SSN/EIN isn't shown to anyone holding an unlocked phone.
                    // The whole row is the button (a control nested in a LabeledContent value slot doesn't
                    // reliably receive taps in a Form).
                    Button {
                        Task {
                            if await BiometricGate.authenticateInSession(reason: mbLoc("Unlock their Tax ID.")) {
                                tinRevealed = true
                            }
                        }
                    } label: {
                        HStack {
                            Text(w9TINType?.label ?? mbLoc("Tax ID"))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(w9TIN.isEmpty ? mbLoc("Tap to add") : "•••••••••")
                                .foregroundStyle(.secondary)
                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(gold)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("taxIdRevealButton")
                }
            } header: {
                InfoLabel("Tax details (for their 1099-NEC)", info: "Optional. The SSN/EIN from the W-9 they gave you. Stored securely in your Keychain, not the synced database — used to generate their 1099-NEC.", topic: "Tax details (for their 1099-NEC)")
            } footer: {
                if !tinRevealed && !w9TIN.isEmpty {
                    Text("Unlock to change the ID type.")
                }
            }
            Section {
                Toggle("Active", isOn: $isActive)
            }
            Section("Notes") {
                TextField("Notes (optional)", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
            }
        }
        .glFormBackground()
        .readOnlyRefusalAlert($readOnlyRefusal)
        .domainErrorAlert($domainError)
        .onAppear { if initialDigest == nil { initialDigest = digest } }
        .discardChangesGuard(isDirty: isDirty)
        .sheet(isPresented: $showingContactPicker) {
            ContactPickerView { contact in
                let draft = ContactsBridge.draft(from: contact)
                firstName = draft.firstName; lastName = draft.lastName
                businessName = draft.businessName
                email = draft.email; phone = draft.phoneNumber
                street1 = draft.street1; street2 = draft.street2
                city = draft.city; state = draft.state; postalCode = draft.postalCode
                // Only when the contact carried one — never blank an existing photo.
                if let photo = draft.imageData { importedPhoto = photo }
                showingContactPicker = false
            } onCancel: {
                showingContactPicker = false
            }
            .ignoresSafeArea()
        }
        .navigationTitle(GLScript.padded(editing == nil ? mbLoc("New Subcontractor") : mbLoc("Edit Subcontractor")))
        .toolbarTitleDisplayMode(.large)
        .contentMargins(.top, GLScript.titleClearance(for: GLScript.padded(editing == nil ? mbLoc("New Subcontractor") : mbLoc("Edit Subcontractor"))), for: .scrollContent)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard !isSaving else { return }
                    isSaving = true
                    save()
                }
                .disabled(!isValid || isSaving)
            }
        }
        .alert("Couldn’t save their Tax ID", isPresented: $tinSaveFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Their other details were saved, but the Tax ID wasn’t. Make sure your device is unlocked, then tap Save again.")
        }
    }

    /// A photo carried in from the Contacts picker, applied on save.
    @State private var importedPhoto: Data?

    private func save() {
        guard ReadOnlyGate.allows(.saveSubcontractor, into: $readOnlyRefusal) else {
            isSaving = false      // resettable guard: the alert invites a retry, so re-arm Save
            return
        }
        // SubcontractorService trims, validates and saves everything but the tax fields — the
        // same path the assistant uses. The TIN type and the Keychain TIN stay HERE, behind Face ID.
        let draft = SubcontractorDraft(
            firstName: firstName, lastName: lastName, businessName: businessName,
            email: email, phone: phone,
            address: Address(street1: street1, street2: street2, city: city,
                             state: state, postalCode: postalCode),
            hourlyRate: hourlyRate, isActive: isActive, notes: notes
        )
        let saved: Subcontractor
        do {
            // On the add path, reuse the record inserted on a prior attempt — otherwise a
            // Tax-ID-failure retry would insert a SECOND subcontractor (the resettable Save re-runs
            // this whole method).
            if let sub = editing ?? insertedSubcontractor {
                try SubcontractorService.update(sub, with: draft, photo: importedPhoto, in: modelContext)
                saved = sub
            } else {
                saved = try SubcontractorService.create(draft, photo: importedPhoto, in: modelContext)
                insertedSubcontractor = saved
            }
        } catch {
            DomainError.present(error, readOnly: $readOnlyRefusal, domainError: $domainError)
            isSaving = false      // resettable guard: re-arm Save
            return
        }
        setIfChanged(saved, \.w9TINTypeRaw, w9TINType?.rawValue)
        // Only write the Tax ID when the owner actually revealed (and could edit) it — otherwise leave
        // the stored value untouched, so a routine edit can never wipe an unseen SSN/EIN.
        let tinSaved = tinRevealed ? saved.updateTIN(w9TIN) : true
        // The tax fields were written after the service's save; persist them (and a first
        // `tinKey`) now too, rather than waiting for autosave.
        modelContext.saveChanges()
        // Everything but the secure Tax ID is saved; if that one write failed, keep the form open
        // and tell the user instead of dismissing as if it all saved.
        guard tinSaved else { tinSaveFailed = true; isSaving = false; return }
        // The add flow's onSave replaces the navigation path itself; dismissing on top of that
        // is a second stack mutation in the same tick — the exact blank-screen push. One owner.
        if let onSave { onSave(saved) } else { dismiss() }
    }
}

#Preview("Add") {
    SubcontractorFormScreen()
        .modelContainer(for: Subcontractor.self, inMemory: true)
}
