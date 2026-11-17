import Foundation
import Testing
@testable import AmusoKit

struct SoapResponseTests {
  /// What a player answered to metadata it could not reconcile with its URI.
  private static let fault = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\""
    + " s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><s:Fault>"
    + "<faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail>"
    + "<UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>800</errorCode></UPnPError>"
    + "</detail></s:Fault></s:Body></s:Envelope>"

  @Test func readsTheValuesOfAResponse() throws {
    let response = try SoapResponse.parse(
      try Fixtures.data("GetTransportInfo.xml"),
      status: 200,
      action: SoapAction(service: .avTransport, name: "GetTransportInfo")
    )
    #expect(response["CurrentTransportState"] == "PAUSED_PLAYBACK")
    #expect(response["CurrentTransportStatus"] == "OK")
    #expect(response.int("CurrentSpeed") == 1)
  }

  @Test func aFaultBecomesAnErrorWithItsCode() throws {
    let action = SoapAction(service: .avTransport, name: "AddMultipleURIsToQueue")
    let expected = SonosError.fault(SoapFault(httpStatus: 500, upnpErrorCode: 800), action: "AddMultipleURIsToQueue")
    #expect(throws: expected) {
      try SoapResponse.parse(Data(Self.fault.utf8), status: 500, action: action)
    }
  }

  @Test func theEnvelopeEscapesArguments() {
    let action = SoapAction(service: .avTransport, name: "SetAVTransportURI", arguments: [
      (name: "InstanceID", value: "0"),
      (name: "CurrentURI", value: "x-sonos-http:song%3a1.mp4?sid=204&flags=8232"),
      (name: "CurrentURIMetaData", value: "<DIDL-Lite/>")
    ])
    let envelope = action.envelope()
    #expect(envelope.contains("<u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"))
    #expect(envelope.contains("<CurrentURI>x-sonos-http:song%3a1.mp4?sid=204&amp;flags=8232</CurrentURI>"))
    #expect(envelope.contains("<CurrentURIMetaData>&lt;DIDL-Lite/&gt;</CurrentURIMetaData>"))
    #expect(action.soapActionHeader == "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"")
  }

  @Test func servicePathsFollowTheSonosLayout() {
    #expect(UPnPService.avTransport.controlPath == "/MediaRenderer/AVTransport/Control")
    #expect(UPnPService.avTransport.eventPath == "/MediaRenderer/AVTransport/Event")
    #expect(UPnPService.contentDirectory.controlPath == "/MediaServer/ContentDirectory/Control")
    #expect(UPnPService.zoneGroupTopology.controlPath == "/ZoneGroupTopology/Control")
  }
}
