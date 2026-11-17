import Foundation
import Testing
@testable import AmusoKit

struct DeviceDescriptionTests {
  @Test func readsTheEra300() throws {
    let description = try DeviceDescription.parse(try Fixtures.data("DeviceDescription-Era300.xml"))
    #expect(description.modelName == "Sonos Era 300")
    #expect(description.modelNumber == "S41")
    #expect(description.roomName == "Véranda")
    #expect(description.uuid == "RINCON_000E58A0000101400")
    #expect(AtmosCapability.isCapable(description))
  }

  @Test func onlySpatialModelsAreAtmosCapable() {
    func capable(_ model: String) -> Bool {
      AtmosCapability.isCapable(DeviceDescription(modelName: model))
    }
    #expect(capable("Sonos Arc"))
    #expect(capable("Sonos Arc Ultra"))
    #expect(capable("Sonos Beam (Gen 2)"))
    #expect(!capable("Sonos Sub Mini"))
    #expect(!capable("Sonos One"))
    #expect(!AtmosCapability.isCapable(nil))
  }
}
