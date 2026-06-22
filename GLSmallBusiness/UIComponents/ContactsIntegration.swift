//
//  ContactsIntegration.swift
//  GLSmallBusiness
//
//  Two-way bridge with the device address book:
//   • import — the system contact picker (permission-free, out-of-process) fills a customer form,
//   • export — the system "new contact" card, pre-filled from a customer, that the user confirms.
//  Both are user-mediated by Apple's own UI, so the app never reads or writes the address book itself.
//

import SwiftUI
import Contacts
import ContactsUI

// MARK: - Mapping

enum ContactsBridge {
    /// The mapped fields pulled from a picked contact — plain strings the customer form can seed from.
    struct Draft {
        var firstName = "", middleName = "", lastName = "", businessName = ""
        var email = "", phoneNumber = "", officePhone = ""
        var street1 = "", street2 = "", city = "", state = "", postalCode = ""
    }

    /// Maps a picked `CNContact` to customer fields. The primary/mobile number becomes the phone
    /// (the text recipient); a work/main number becomes the office number.
    static func draft(from c: CNContact) -> Draft {
        let email = c.emailAddresses.first.map { $0.value as String } ?? ""

        var mobile = "", office = ""
        for entry in c.phoneNumbers {
            let number = entry.value.stringValue
            let label = entry.label ?? ""
            if label == CNLabelPhoneNumberMobile || label == CNLabelPhoneNumberiPhone {
                if mobile.isEmpty { mobile = number }
            } else if label == CNLabelWork || label == CNLabelPhoneNumberMain {
                if office.isEmpty { office = number }
            }
        }
        // Fallbacks: ensure the first number lands somewhere; a second distinct one fills office.
        if mobile.isEmpty, let first = c.phoneNumbers.first { mobile = first.value.stringValue }
        if office.isEmpty,
           let other = c.phoneNumbers.map(\.value.stringValue).first(where: { $0 != mobile }) {
            office = other
        }

        let postal = c.postalAddresses.first?.value
        let streetLines = (postal?.street ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return Draft(
            firstName: c.givenName, middleName: c.middleName, lastName: c.familyName,
            businessName: c.organizationName, email: email, phoneNumber: mobile, officePhone: office,
            street1: streetLines.first ?? "", street2: streetLines.dropFirst().joined(separator: ", "),
            city: postal?.city ?? "", state: postal?.state ?? "", postalCode: postal?.postalCode ?? "")
    }

    /// Builds an editable contact pre-filled from a customer, for the system new-contact card.
    static func contact(from customer: Customer) -> CNMutableContact {
        let c = CNMutableContact()
        c.givenName = customer.firstName
        c.middleName = customer.middleName
        c.familyName = customer.lastName
        if let business = customer.businessName, !business.isEmpty { c.organizationName = business }

        if !customer.email.isEmpty {
            c.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: customer.email as NSString)]
        }
        var phones: [CNLabeledValue<CNPhoneNumber>] = []
        if !customer.phoneNumber.isEmpty {
            phones.append(CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: customer.phoneNumber)))
        }
        if !customer.officePhone.isEmpty {
            phones.append(CNLabeledValue(label: CNLabelWork, value: CNPhoneNumber(stringValue: customer.officePhone)))
        }
        c.phoneNumbers = phones

        let a = customer.address
        if !a.isEmpty {
            let postal = CNMutablePostalAddress()
            postal.street = [a.street1, a.street2 ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
            postal.city = a.city
            postal.state = a.state
            postal.postalCode = a.postalCode
            c.postalAddresses = [CNLabeledValue(label: CNLabelWork, value: postal)]
        }
        return c
    }

    /// Builds an editable contact pre-filled from an employee (name + email + mobile phone).
    static func contact(from employee: Employee) -> CNMutableContact {
        let c = CNMutableContact()
        c.givenName = employee.firstName
        c.familyName = employee.lastName
        if !employee.email.isEmpty {
            c.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: employee.email as NSString)]
        }
        if !employee.phone.isEmpty {
            c.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: employee.phone))]
        }
        return c
    }

    /// Builds an editable contact pre-filled from a subcontractor (name, business, email, phone, address).
    static func contact(from sub: Subcontractor) -> CNMutableContact {
        let c = CNMutableContact()
        c.givenName = sub.firstName
        c.familyName = sub.lastName
        if !sub.businessName.isEmpty { c.organizationName = sub.businessName }
        if !sub.email.isEmpty {
            c.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: sub.email as NSString)]
        }
        if !sub.phone.isEmpty {
            c.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: sub.phone))]
        }
        let a = sub.address
        if !a.isEmpty {
            let postal = CNMutablePostalAddress()
            postal.street = [a.street1, a.street2 ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
            postal.city = a.city
            postal.state = a.state
            postal.postalCode = a.postalCode
            c.postalAddresses = [CNLabeledValue(label: CNLabelWork, value: postal)]
        }
        return c
    }
}

// MARK: - Import: system contact picker

/// The system contact picker (no Contacts permission needed). Calls `onPick` with the chosen contact,
/// or `onCancel` if dismissed — the caller uses either to close the hosting sheet.
///
/// Presented over an invisible host controller rather than being the sheet's content directly:
/// `CNContactPickerViewController` dismisses *its presenting controller* when finished, which — if it
/// were the sheet root — would tear down the parent sheet (the customer form) too. The host absorbs
/// that dismissal so only the picker closes.
struct ContactPickerView: UIViewControllerRepresentable {
    var onPick: (CNContact) -> Void
    var onCancel: () -> Void = {}

    func makeUIViewController(context: Context) -> PickerHost {
        let host = PickerHost()
        host.makePicker = {
            let picker = CNContactPickerViewController()
            picker.delegate = context.coordinator
            return picker
        }
        return host
    }

    func updateUIViewController(_ host: PickerHost, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class PickerHost: UIViewController {
        var makePicker: (() -> CNContactPickerViewController)?
        private var presented = false
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presented, let picker = makePicker?() else { return }
            presented = true
            present(picker, animated: true)
        }
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (CNContact) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (CNContact) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            onPick(contact)
        }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            onCancel()
        }
    }
}

// MARK: - Export: system new-contact card

/// The system "new contact" card, pre-filled and editable; the user taps Add/Done to save it to their
/// address book (or Cancel). The app never writes contacts directly.
struct NewContactView: UIViewControllerRepresentable {
    let contact: CNMutableContact
    var onFinish: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = CNContactViewController(forNewContact: contact)
        controller.delegate = context.coordinator
        controller.allowsActions = true
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
            onFinish()
        }
    }
}
