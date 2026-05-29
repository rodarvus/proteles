import Foundation

/// Plugin outbound HTTP (`async`): perform a `.httpRequest` effect off the
/// effect pipeline and re-enter the engine to fire the plugin's callback.
extension SessionController {
    /// Run the request in a detached task (so the network call doesn't block
    /// effect application), then re-enter the script engine with the response to
    /// fire the plugin's stored Lua callback and apply its effects. Allowed
    /// freely (MUSHclient parity). See `LuaRuntime+HTTP`.
    func performHTTPRequest(_ request: HTTPRequest) {
        guard let scriptEngine else { return }
        let client = httpClient
        Task { [weak self] in
            let response = await client.perform(request)
            let effects = await scriptEngine.completeHTTP(request, response)
            await self?.applyScriptEffects(effects)
        }
    }
}
