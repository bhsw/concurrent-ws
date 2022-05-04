import Foundation

// TODO:
// General approach:
//  1. Accept a connection from the listener.
//  2. Read the HTTP request from the client.
//  3. Package it up into a request event that gives the event handler a Request object with the following:
//      - HTTP method
//      - Path or URL
//      - Whether an upgrade to WebSocket is being requested, and if so, the list of subprotocols understood by the client
//      - Any extra headers
//      - An async method to complete the WebSocket handshake and return a `WebSocket` instance
//      - A method that can be called instead to send a generic HTTP response to the client
extension WebSocket {
  public enum ServerError: Error {
    case listenerFailed(reason: String, underlyingError: Error)
  }
}
