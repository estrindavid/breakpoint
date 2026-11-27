import Foundation

/// Shell: snippets in `~/.breakpoint/shell/`, sourced from a marker block in `.zshrc` (created if
/// missing) and in whichever of `.bashrc` / `.bash_profile` exist (never created: a new
/// `.bash_profile` would stop bash reading `.profile`); fish: `~/.config/fish/conf.d/breakpoint.fish`
/// when fish's config folder exists. Always "found" (SPEC §5.5).
public struct ShellIntegration: Integration {
    public let environment: IntegrationEnvironment
    public init(environment: IntegrationEnvironment) { self.environment = environment }
    public var id: IntegrationID { .shell }
    public var configFile: URL { zshrc }
    public var zshrc: URL { environment.home.appendingPathComponent(".zshrc") }
    public var bashFiles: [URL] { [".bashrc", ".bash_profile"].map { environment.home.appendingPathComponent($0) } }
    public var rcFiles: [URL] { [zshrc] + bashFiles }
    public var fishFolder: URL { environment.home.appendingPathComponent(".config/fish", isDirectory: true) }
    public var fishSnippet: URL { fishFolder.appendingPathComponent("conf.d/breakpoint.fish") }
    public func detect() -> Bool { true }

    var paths: BreakpointPaths { environment.paths }

    static func blockBody(snippet: String, file: String) -> String {
        """
        # Added by Breakpoint (long-running commands). Remove with: ~/.breakpoint/bin/breakpoint uninstall shell
        if [ -r "$HOME/.breakpoint/shell/\(file)" ]; then \(snippet) "$HOME/.breakpoint/shell/\(file)"; fi
        """
    }

    static let zshBlockBody = blockBody(snippet: "source", file: "breakpoint.zsh")
    static let bashBlockBody = blockBody(snippet: ".", file: "breakpoint.bash")

    private func fileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The rc files install edits and the body each gets.
    private var wantedBlocks: [(URL, String)] {
        [(zshrc, Self.zshBlockBody)] + bashFiles.filter(fileExists).map { ($0, Self.bashBlockBody) }
    }

    private func config(_ url: URL) -> ConfigFile { ConfigFile(url: url, tool: id, environment: environment) }

    private func malformed(_ url: URL) -> IntegrationError {
        .unparseableFile(url, reason: "it has a Breakpoint block with a missing marker line")
    }

    private func readOwned(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    public func status() -> IntegrationInstallState {
        do {
            var present = false
            var complete = true
            for url in rcFiles {
                let text = try config(url).read() ?? ""
                let body: String?
                do {
                    body = try MarkerBlockEditor.body(in: text)
                } catch {
                    return .unreadable(reason: "\(url.lastPathComponent) has a Breakpoint block with a missing marker line.")
                }
                let wanted = wantedBlocks.first { $0.0 == url }?.1
                if let body {
                    present = true
                    if body != wanted {
                        if wanted != nil { return .modified }
                        complete = false
                    }
                } else if wanted != nil {
                    complete = false
                }
            }
            if let fish = readOwned(fishSnippet) {
                present = true
                if fish != ShellSnippets.fish { complete = false }
            } else if isFolder(fishFolder) {
                complete = false
            }
            guard present else { return .notInstalled }
            if readOwned(paths.shellZshSnippet) != ShellSnippets.zsh || readOwned(paths.shellBashSnippet) != ShellSnippets.bash {
                complete = false
            }
            return complete ? .installed : .outdated
        } catch let error as IntegrationError {
            return .unreadable(reason: error.statusSentence)
        } catch {
            return .unreadable(reason: "A shell startup file could not be read.")
        }
    }

    public func install() throws -> InstallReport {
        // Check every file before changing any.
        for (url, _) in wantedBlocks {
            if let text = try config(url).read() {
                guard (try? MarkerBlockEditor.ranges(in: text)) != nil else { throw malformed(url) }
            }
        }
        if fileExists(fishSnippet), let text = readOwned(fishSnippet), !text.hasPrefix(ShellSnippets.fishHeader) {
            throw IntegrationError.io("\(PathDisplay.abbreviatingHome(fishSnippet.path, home: environment.home.path)) belongs to something else, so Breakpoint left it alone.")
        }
        try environment.ensureCLICopy()

        var report = InstallReport()
        do {
            try FileManager.default.createDirectory(at: paths.shellDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
            for (url, text) in [(paths.shellZshSnippet, ShellSnippets.zsh), (paths.shellBashSnippet, ShellSnippets.bash)]
                where readOwned(url) != text {
                try AtomicFile.write(Data(text.utf8), to: url, mode: 0o644)
                report.changedFiles.append(url)
            }
        } catch let error as IntegrationError {
            throw error
        } catch {
            throw IntegrationError.io("Could not write the shell snippets in \(paths.shellDirectory.path).")
        }

        for (url, body) in wantedBlocks {
            let file = config(url)
            var original: String?
            let change = try file.update { text in
                original = text
                do {
                    return try MarkerBlockEditor.upsertChecked(body: body, in: text ?? "")
                } catch {
                    throw malformed(url)
                }
            }
            if let change {
                if original?.isBlank ?? true { file.remember(original: original) }
                report.changedFiles.append(change.file)
                if let backup = change.backup { report.backups.append(backup) }
            }
        }

        if isFolder(fishFolder), readOwned(fishSnippet) != ShellSnippets.fish {
            try CreatedDirectory.ensure(fishSnippet.deletingLastPathComponent(), environment: environment)
            try AtomicFile.write(Data(ShellSnippets.fish.utf8), to: fishSnippet, mode: 0o644)
            report.changedFiles.append(fishSnippet)
        }

        report.notes.append("Open a new terminal window to start.")
        if !bashFiles.contains(where: fileExists) {
            report.notes.append("No ~/.bashrc or ~/.bash_profile was found, so bash was left alone.")
        }
        return report
    }

    public func uninstall() throws -> InstallReport {
        var report = InstallReport()
        for url in rcFiles {
            let file = config(url)
            let record = file.ledgerRecord()
            let change = try file.update { text in
                guard let text else { return nil }
                let removed: String
                do {
                    removed = try MarkerBlockEditor.removeChecked(from: text)
                } catch {
                    throw malformed(url)
                }
                guard removed != text else { return text }
                if let record, record.hasOriginal, removed.isBlank { return record.original }
                return removed
            }
            if record != nil { file.forgetRecord() }
            if let change {
                report.changedFiles.append(change.file)
                if let backup = change.backup { report.backups.append(backup) }
            }
        }
        if let text = readOwned(fishSnippet), text.hasPrefix(ShellSnippets.fishHeader) {
            try? FileManager.default.removeItem(at: fishSnippet)
            report.changedFiles.append(fishSnippet)
            CreatedDirectory.removeIfEmpty(fishSnippet.deletingLastPathComponent(), environment: environment)
        }
        for url in [paths.shellZshSnippet, paths.shellBashSnippet] where fileExists(url) {
            try? FileManager.default.removeItem(at: url)
            report.changedFiles.append(url)
        }
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: paths.shellDirectory.path), contents.isEmpty {
            try? FileManager.default.removeItem(at: paths.shellDirectory)
        }
        return report
    }
}

/// The shell snippets (research §5, plus `--session` with the shell's PID). Each sends only the
/// command's name (skipping `VAR=value` prefixes and wrappers such as `sudo` or `time`), never its
/// arguments; does nothing in non-interactive shells or when the CLI is missing; runs the CLI in
/// the background with output discarded; guards against double loading; and preserves `$?`.
public enum ShellSnippets {
    static let header = "# Breakpoint shell integration (generated by Breakpoint; reinstalling replaces this file).\n"
        + "# Sends the name of each command you run (its first word only) to the Breakpoint app.\n"

    /// Shared by zsh and bash (3.2+): sets REPLY to the command's name — the first word that is not
    /// a `VAR=value` assignment (quotes respected, so a quoted value never leaks), an option or a
    /// wrapper such as `sudo`; stops at `;`, `|` or `&`. Looks at the first 512 characters only.
    static let commandName = #"""
    __bp_command_name() {
      local line=${1:0:512} word="" c q="" i=0 n
      n=${#line}
      REPLY=""
      while [[ $i -le $n ]]; do
        c=${line:$i:1}
        i=$((i + 1))
        if [[ -n $q ]]; then
          word=$word$c
          [[ $c == "$q" ]] && q=""
        elif [[ $c == "'" || $c == '"' ]]; then
          q=$c
          word=$word$c
        elif [[ -z $c || $c == " " || $c == $'\t' || $c == $'\n' || $c == ";" || $c == "|" || $c == "&" ]]; then
          if [[ -n $word ]]; then
            case $word in
              *=*|-*|sudo|time|nohup|env|command|builtin|exec|noglob|nice) word="" ;;
              *) REPLY=$word; return 0 ;;
            esac
          fi
          [[ $c == ";" || $c == "|" || $c == "&" ]] && return 0
        else
          word=$word$c
        fi
      done
      return 0
    }
    """#

    public static let zsh = header + #"""
    [[ -o interactive ]] || return 0
    (( ${+__bp_loaded} )) && return 0
    zmodload zsh/datetime 2>/dev/null || return 0
    typeset -g __bp_loaded=1
    typeset -g __bp_bin="$HOME/.breakpoint/bin/breakpoint"
    typeset -g __bp_t0="" __bp_name=""
    autoload -Uz add-zsh-hook

    """# + commandName + #"""


    __bp_preexec() {
      __bp_t0=$EPOCHREALTIME
      __bp_command_name "$1"
      __bp_name=$REPLY
      [[ -n $__bp_name && -x $__bp_bin ]] || return 0
      "$__bp_bin" emit commandStarted --source shell --session "$$" --cwd "$PWD" --title "$__bp_name" &>/dev/null &!
    }

    __bp_precmd() {
      local ec=$?
      [[ -n $__bp_t0 ]] || return $ec
      local -i ms; ms=$(( (EPOCHREALTIME - __bp_t0) * 1000 ))
      __bp_t0=""
      (( ms >= 2000 )) || return $ec
      [[ -n $__bp_name && -x $__bp_bin ]] || return $ec
      "$__bp_bin" emit commandFinished --source shell --session "$$" --cwd "$PWD" --title "$__bp_name" \
        --duration-ms $ms --exit-code $ec &>/dev/null &!
      return $ec
    }

    add-zsh-hook preexec __bp_preexec
    add-zsh-hook precmd __bp_precmd
    # Run first so $? is the user's command status even if other precmd hooks change it.
    precmd_functions=(__bp_precmd ${precmd_functions:#__bp_precmd})

    """#

    public static let bash = header + #"""
    [[ $- == *i* ]] || return 0
    [[ -n ${__bp_loaded-} ]] && return 0
    __bp_loaded=1
    __bp_bin="$HOME/.breakpoint/bin/breakpoint"
    __bp_t0=""; __bp_name=""; __bp_armed=0

    """# + commandName + #"""


    __bp_now_ms() {  # bash 5+: EPOCHREALTIME; bash 3.2: whole seconds
      if [[ -n ${EPOCHREALTIME-} ]]; then local t=${EPOCHREALTIME/[.,]/}; REPLY=$(( t / 1000 ));
      else REPLY=$(( SECONDS * 1000 )); fi
    }

    __bp_preexec() {
      __bp_now_ms; __bp_t0=$REPLY
      __bp_command_name "$1"
      __bp_name=$REPLY
      [[ -n $__bp_name && -x $__bp_bin ]] || return 0
      ( "$__bp_bin" emit commandStarted --source shell --session "$$" --cwd "$PWD" --title "$__bp_name" >/dev/null 2>&1 & )
    }

    __bp_precmd() {
      local ec=$?
      [[ -n $__bp_t0 ]] || return $ec
      __bp_now_ms
      local ms=$(( REPLY - __bp_t0 )); __bp_t0=""
      (( ms >= 2000 )) || return $ec
      [[ -n $__bp_name && -x $__bp_bin ]] || return $ec
      ( "$__bp_bin" emit commandFinished --source shell --session "$$" --cwd "$PWD" --title "$__bp_name" \
          --duration-ms "$ms" --exit-code "$ec" >/dev/null 2>&1 & )
      return $ec
    }

    if [[ -n ${bash_preexec_imported-} ]]; then
      # bash-preexec is loaded (iTerm2 shell integration and others ship it): use its arrays.
      preexec_functions+=(__bp_preexec)
      precmd_functions=(__bp_precmd "${precmd_functions[@]}")
    elif [[ -z $(trap -p DEBUG) ]]; then
      # Minimal fallback, only when no DEBUG trap exists: the first simple command after a prompt.
      __bp_debug() {
        [[ $__bp_armed == 1 ]] || return 0
        [[ -n ${COMP_LINE-} ]] && return 0
        __bp_armed=0
        case $BASH_COMMAND in __bp_*) return 0 ;; esac
        __bp_preexec "$BASH_COMMAND"
        return 0
      }
      __bp_arm() { __bp_armed=1; }
      trap '__bp_debug' DEBUG
      # Capture $? first; arm last, after any other PROMPT_COMMAND entries. Newlines join the
      # parts, so the user's command stays valid whatever it ends with (`;`, `&`, a newline).
      if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
        PROMPT_COMMAND=(__bp_precmd "${PROMPT_COMMAND[@]}" __bp_arm)
      else
        __bp_nl=$'\n'
        PROMPT_COMMAND="__bp_precmd${__bp_nl}${PROMPT_COMMAND:+$PROMPT_COMMAND$__bp_nl}__bp_arm"
        unset __bp_nl
      fi
    fi

    """#

    static let fishHeader = "# Breakpoint shell integration (generated by Breakpoint; reinstalling replaces this file).\n"

    public static let fish = fishHeader + #"""
    # Sends the name of each command you run (its first word only) to the Breakpoint app.
    status is-interactive; or exit
    set -q __bp_loaded; and exit
    set -g __bp_loaded 1
    set -g __bp_bin $HOME/.breakpoint/bin/breakpoint
    set -g __bp_name ""

    function __bp_command_name
        for word in (string split ' ' -- $argv[1])
            test -n "$word"; or continue
            if string match -q -- '*=*' $word
                # A quoted value can hold spaces (and a secret): never guess past it.
                string match -q -- "*'*" $word; or string match -q -- '*"*' $word; and return 0
                continue
            end
            string match -q -- '-*' $word; and continue
            contains -- $word sudo time nohup env command builtin exec nice; and continue
            echo $word
            return 0
        end
    end

    function __bp_preexec --on-event fish_preexec
        set -g __bp_name (__bp_command_name $argv[1])
        test -n "$__bp_name"; and test -x $__bp_bin; or return
        command $__bp_bin emit commandStarted --source shell --session $fish_pid --cwd $PWD --title $__bp_name >/dev/null 2>&1 &
        disown 2>/dev/null
    end

    function __bp_postexec --on-event fish_postexec
        set -l ec $status
        test "$CMD_DURATION" -ge 2000 2>/dev/null; or return
        test -n "$__bp_name"; and test -x $__bp_bin; or return
        command $__bp_bin emit commandFinished --source shell --session $fish_pid --cwd $PWD --title $__bp_name \
            --duration-ms $CMD_DURATION --exit-code $ec >/dev/null 2>&1 &
        disown 2>/dev/null
    end

    """#
}
