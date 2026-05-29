import Foundation

/// A request from a plugin's `utils.*` dialog call (msgbox / inputbox / editbox /
/// choose / file pickers). The app fulfils it with a native modal and returns a
/// ``ScriptDialogResult`` **synchronously** (the calling plugin blocks on the
/// result, as MUSHclient's dialogs do). Value types so MudCore stays UI-free.
public enum ScriptDialog: Sendable, Equatable {
    /// `utils.msgbox` — an alert. `buttons` is MUSHclient's code: 0 = OK,
    /// 1 = OK/Cancel, 3 = Yes/No/Cancel, 4 = Yes/No.
    case message(text: String, title: String, buttons: Int)
    /// `utils.inputbox` (single line) and `utils.editbox` (multiline).
    case input(prompt: String, title: String, defaultText: String, multiline: Bool)
    /// `utils.choose` — pick one of `items`; the result is the 1-based index.
    case choose(prompt: String, title: String, items: [String])
    /// `utils.filepicker` (file) / `utils.directorypicker` (folder).
    case openFile(message: String, chooseDirectory: Bool)
}

/// The outcome of a ``ScriptDialog`` (a `nil` payload = the user cancelled).
public enum ScriptDialogResult: Sendable, Equatable {
    case button(String) // msgbox → "ok" / "cancel" / "yes" / "no"
    case text(String?) // input / edit → the entered text
    case index(Int?) // choose → 1-based selected index
    case path(String?) // file / directory → the chosen path
}

/// App-provided hook that fulfils a ``ScriptDialog`` with a native modal,
/// synchronously. `nil` when no provider is set (dialogs then degrade to a safe
/// default: cancelled, or "ok" for msgbox).
public typealias ScriptDialogProvider = @Sendable (ScriptDialog) -> ScriptDialogResult
