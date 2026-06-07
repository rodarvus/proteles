public extension ScriptEngine {
    /// Tell the runtime the per-character `Databases/<character>/` directory that
    /// `proteles.databaseDir()` should return, so a plugin can keep its SQLite DB
    /// flat in the shared Databases tree (#43/#44). Called by the session once the
    /// character is known.
    func setDatabasesDirectory(_ path: String) async {
        await runtime.setDatabasesDirectory(path)
    }
}
