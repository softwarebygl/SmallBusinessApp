//
//  PhotoNamingTests.swift
//  GLSmallBusinessTests — Domain
//
//  Picked photos are numbered within their record ("Photo 1", "Photo 2", …) instead of all
//  being called "Photo" (audit 2026-10-03 F13): the name is the file name a customer receives.
//

import Foundation
import SwiftData
import Testing
@testable import GLSmallBusiness

@MainActor
@Suite(.serialized)
struct PhotoNamingTests {

    @Test func pickedPhotosAreNumberedWithinTheirRecord() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(in: context)
        let job = TS.job("Tile", start: .now, in: context)
        context.saveChanges()

        try DomainState.subscribed.run {
            let first = try DocumentService.attachPhotos([Data([1]), Data([2]), Data([3])],
                                                         to: .invoice(invoice), in: context)
            #expect(first.map(\.name) == [1, 2, 3].map { mbLoc("Photo \($0)") })
            #expect(first.first?.name.hasSuffix(" 1") == true)

            // A later pick continues the count; it never reuses a number already on the record.
            let more = try DocumentService.attachPhotos([Data([4]), Data([5])], to: .invoice(invoice), in: context)
            #expect(more.map(\.name) == [4, 5].map { mbLoc("Photo \($0)") })

            // Each record counts on its own.
            let jobPhotos = try DocumentService.attachPhotos([Data([6])], to: .job(job), in: context)
            #expect(jobPhotos.map(\.name) == [mbLoc("Photo \(1)")])
        }
        #expect(Set(invoice.photos.map(\.name)).count == 5, "five photos, five names")
    }

    @Test func aTakenNumberIsSkipped() throws {
        let context = try DomainFixtures.context()
        let invoice = TS.invoice(in: context)
        // Imported from a job, already named "Photo 2".
        context.insert(JobAttachment(kind: .photo, name: mbLoc("Photo \(2)"), data: Data([9]), invoice: invoice))
        context.saveChanges()

        let added = try DomainState.subscribed.run {
            try DocumentService.attachPhotos([Data([1]), Data([2])], to: .invoice(invoice), in: context)
        }
        #expect(Set(invoice.photos.map(\.name)).count == 3, "no two photos share a name")
        #expect(!added.map(\.name).contains(mbLoc("Photo \(2)")))
    }
}
