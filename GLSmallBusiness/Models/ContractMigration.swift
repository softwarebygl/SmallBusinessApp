//
//  ContractMigration.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 10/7/26.
//
//  Seamlessly migrates existing ScheduledJob records into first-class Contracts
//  so no user schedules, documents, photos, or data are lost (Ruling 7).
//

import Foundation
import SwiftData

enum ContractMigration {
    private static let didRunKey = "mb.didMigrateJobsToContracts_v1"
    private static let didHealServiceAddressKey = "mb.didHealContractServiceAddresses_v1"

    @MainActor
    static func runIfNeeded(_ context: ModelContext) {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: didRunKey) {
            let foundJobs = backfill(context)
            if foundJobs {
                defaults.set(true, forKey: didRunKey)
            }
        }
        if !defaults.bool(forKey: didHealServiceAddressKey) {
            healServiceAddresses(context)
            defaults.set(true, forKey: didHealServiceAddressKey)
        }
    }

    @MainActor
    static func healServiceAddresses(_ context: ModelContext) {
        let contracts = (try? context.fetch(FetchDescriptor<Contract>())) ?? []
        guard !contracts.isEmpty else { return }

        var changed = false
        for contract in contracts {
            let trueSite: Address? = {
                if let est = contract.estimate, !est.serviceAddress.isEmpty { return est.serviceAddress }
                if let jobEst = contract.scheduledJob?.estimate, !jobEst.serviceAddress.isEmpty { return jobEst.serviceAddress }
                if let jobInv = contract.scheduledJob?.invoice, !jobInv.serviceAddress.isEmpty { return jobInv.serviceAddress }
                if let job = contract.scheduledJob, !job.serviceAddress.isEmpty { return job.serviceAddress }
                return nil
            }()

            guard let site = trueSite, !site.isEmpty else { continue }

            let customerBilling = contract.customer?.address ?? Address()
            let customerService = contract.customer?.serviceAddress ?? Address()

            let wasDefaultedToCustomerOffice = (!customerBilling.isEmpty && contract.serviceAddress == customerBilling)
                || (!customerService.isEmpty && contract.serviceAddress == customerService)

            if contract.serviceAddress.isEmpty || wasDefaultedToCustomerOffice {
                if contract.serviceAddress != site {
                    contract.serviceAddress = site
                    changed = true
                }
            }

            if let job = contract.scheduledJob {
                let jobWasDefaulted = (!customerBilling.isEmpty && job.serviceAddress == customerBilling)
                    || (!customerService.isEmpty && job.serviceAddress == customerService)
                if job.serviceAddress.isEmpty || jobWasDefaulted {
                    if job.serviceAddress != site {
                        job.serviceAddress = site
                        changed = true
                    }
                }
            }
        }

        if changed {
            context.saveChanges()
        }
    }

    @MainActor
    @discardableResult
    static func backfill(_ context: ModelContext) -> Bool {
        let jobs = (try? context.fetch(FetchDescriptor<ScheduledJob>())) ?? []
        guard !jobs.isEmpty else { return false }

        var existingContracts = (try? context.fetch(FetchDescriptor<Contract>())) ?? []

        for job in jobs {
            // Skip if already linked to a contract
            if job.contract != nil { continue }

            let alreadyMigrated = existingContracts.contains {
                $0.title == job.title && $0.startDate == job.startDate && $0.customerName == job.customerName
            }
            if alreadyMigrated { continue }

            let contractNumber = Contract.nextNumber(after: existingContracts)
            let contractStatus: ContractStatus
            switch job.status {
            case .completed: contractStatus = .completed
            case .inProgress: contractStatus = .inProgress
            case .scheduled: contractStatus = .signed
            }

            let siteAddress: Address = {
                if !job.serviceAddress.isEmpty { return job.serviceAddress }
                if let est = job.estimate, !est.serviceAddress.isEmpty { return est.serviceAddress }
                if let inv = job.invoice, !inv.serviceAddress.isEmpty { return inv.serviceAddress }
                return Address()
            }()

            let contract = Contract(
                number: contractNumber,
                title: job.title,
                customerName: job.customerName,
                startDate: job.startDate,
                durationDays: job.durationDays,
                isAllDay: job.isAllDay,
                startTime: job.startTime,
                durationMinutes: job.durationMinutes,
                notes: job.notes,
                serviceAddress: siteAddress,
                agreedPrice: job.agreedPrice,
                status: contractStatus,
                customer: job.customer,
                estimate: job.estimate
            )
            contract.createdAt = job.createdAt
            contract.completedAt = job.completedAt
            contract.scheduledJob = job
            job.contract = contract
            if job.serviceAddress.isEmpty && !siteAddress.isEmpty {
                job.serviceAddress = siteAddress
            }

            // If the job had an accepted estimate, copy its line item groups
            if let estimate = job.estimate {
                for (gIdx, group) in estimate.sortedGroups.enumerated() {
                    let contractGroup = ContractGroup(name: group.name, note: group.note, sortIndex: gIdx)
                    contractGroup.contract = contract
                    context.insert(contractGroup)
                    for (lIdx, line) in group.sortedLineItems.enumerated() {
                        let contractLine = ContractLineItem(
                            name: line.name,
                            details: line.details,
                            quantity: line.quantity,
                            unit: line.unit,
                            unitPrice: line.unitPrice,
                            kind: line.kind,
                            isTaxable: line.isTaxable,
                            sortIndex: lIdx
                        )
                        contractLine.group = contractGroup
                        context.insert(contractLine)
                    }
                }
            }

            // Link existing billing invoices to this contract
            if let billingInvoices = job.billingInvoices {
                for inv in billingInvoices {
                    inv.contract = contract
                }
            }

            // Link receipts
            if let receipts = job.receipts {
                for r in receipts {
                    r.contract = contract
                }
            }

            // Link attachments
            if let attachments = job.attachments {
                for a in attachments {
                    a.contract = contract
                }
            }

            context.insert(contract)
            existingContracts.append(contract)
        }

        context.saveChanges()
        return true
    }
}
