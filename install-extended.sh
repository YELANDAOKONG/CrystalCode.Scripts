#!/usr/bin/env sh
# Extended installer: everything install.sh does, then fills an empty plugins
# directory with the web plugin and an empty providers or themes directory
# with the default catalog. A directory that already has entries is never
# touched, so running this again is safe.

set -eu

repository="YELANDAOKONG/CrystalCode"
plugin_repository="YELANDAOKONG/CrystalCode.Plugins.Web"
plugin_directory_name="web"
web_repository="YELANDAOKONG/CrystalCode.Web"
web_archive_name="CrystalCode-Web.zip"
scripts_base="https://raw.githubusercontent.com/YELANDAOKONG/CrystalCode.Scripts/master"
defaults_base="https://raw.githubusercontent.com/YELANDAOKONG/CrystalCode.Defaults/master"
crystal_home="${CRYSTAL_HOME:-${HOME:?HOME must be set}/.crystal}"
extras_failed=0
install_directory="${HOME:?HOME must be set}/.crystal/binaries/code"
binary_name="CrystalCode"

# Mineral palette from CrystalCode.Display Theme: grey42, lightsteelblue, indianred.
# A non-terminal, NO_COLOR, or TERM=dumb keeps the plain status lines.
styled=false
MUTED=
ACCENT=
FAIL=
NC=
cursor_hidden=false
download_pid=
card_kind=
docs_url="https://github.com/${repository}/blob/master/docs/user-guide.md"

if [ -t 1 ] && [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    styled=true
    MUTED=$(printf '\033[38;5;242m')
    NC=$(printf '\033[0m')
    if [ "${COLORTERM:-}" = "truecolor" ] || [ "${COLORTERM:-}" = "24bit" ]; then
        ACCENT=$(printf '\033[38;2;176;196;222m')
        FAIL=$(printf '\033[38;2;205;92;92m')
    else
        ACCENT=$(printf '\033[38;5;152m')
        FAIL=$(printf '\033[38;5;167m')
    fi
fi

fail() {
    restore_cursor
    if [ "$styled" = true ] && [ -t 2 ]; then
        printf '%s%s%s\n' "$FAIL" "$1" "$NC" >&2
    else
        printf '%s\n' "$1" >&2
    fi
    exit 1
}

# Dash has no RETURN trap. The EXIT cleanup also restores the cursor when a
# download is interrupted while it is hidden.
restore_cursor() {
    if [ "${cursor_hidden:-false}" = true ]; then
        printf '\033[?25h\n' >&2
        cursor_hidden=false
    fi
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        fail "Required command not found: $1"
    fi
}

# Command substitution drops a trailing newline, so a non-empty result
# means the file does not end with one. Without this, the installer
# comment is appended onto the last profile line.
ensure_trailing_newline() {
    if [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]; then
        printf '\n' >> "$1"
    fi
}

configure_path() {
    profile_path=""
    profile_comment="# Crystal Code CLI (Installer)"

    case "${SHELL:-sh}" in
        */zsh | zsh)
            profile_path="$HOME/.zshrc"
            ;;
        */bash | bash)
            profile_path="$HOME/.bashrc"
            ;;
    esac

    if [ -z "$profile_path" ]; then
        if [ "$styled" = true ]; then
            card_kind="direct"
            return
        fi

        printf 'Installed %s. Start Crystal Code with: %s\n' "$binary_name" "${install_directory}/${binary_name}"
        return
    fi

    path_export="export PATH=\"${install_directory}:\$PATH\""
    command_alias="alias crystal=${binary_name}"
    comment_exists=false
    path_exists=false
    alias_exists=false

    if [ -f "$profile_path" ] && grep -F -x "$profile_comment" "$profile_path" >/dev/null 2>&1; then
        comment_exists=true
    fi

    if [ -f "$profile_path" ] && grep -F -x "$path_export" "$profile_path" >/dev/null 2>&1; then
        path_exists=true
    fi

    if [ -f "$profile_path" ] && grep -F -x "$command_alias" "$profile_path" >/dev/null 2>&1; then
        alias_exists=true
    fi

    if [ "$comment_exists" = true ] && [ "$path_exists" = true ] && [ "$alias_exists" = true ]; then
        if [ "$styled" = true ]; then
            card_kind="ready"
            return
        fi

        printf 'Crystal Code is already configured in %s.\n' "$profile_path"
        printf 'Start Crystal Code with: crystal\n'
        return
    fi

    ensure_trailing_newline "$profile_path"
    if [ "$(uname -s)" = "Linux" ]; then
        printf '\n\n\n' >> "$profile_path"
    fi

    # Write a complete block when updating a partial or legacy configuration.
    # A later alias definition intentionally supersedes the legacy absolute-path alias.
    printf '%s\n' "$profile_comment" >> "$profile_path"
    printf '%s\n' "$path_export" >> "$profile_path"
    printf '%s\n' "$command_alias" >> "$profile_path"
    printf '\n\n' >> "$profile_path"

    if [ "$styled" = true ]; then
        card_kind="configured"
        return
    fi

    printf 'Configured Crystal Code in %s.\n' "$profile_path"
    printf 'Open a new terminal or run: . %s\n' "$profile_path"
    printf 'Start Crystal Code with: crystal\n'
}

print_card() {
    printf '\n'
    printf '%s┌─────────┐%s\n' "$MUTED" "$NC"
    printf '%s│ %scrystal%s │%s\n' "$MUTED" "$ACCENT" "$MUTED" "$NC"
    printf '%s└─────────┘%s\n' "$MUTED" "$NC"
    printf '\n'
    printf 'Installed %s to %s%s%s\n' "$archive_name" "$ACCENT" "$install_directory" "$NC"

    case "$card_kind" in
        ready)
            printf 'Crystal Code is already configured in %s%s%s.\n' "$ACCENT" "$profile_path" "$NC"
            printf 'Start Crystal Code with: %scrystal%s\n' "$ACCENT" "$NC"
            start_command="crystal"
            ;;
        configured)
            printf 'Configured Crystal Code in %s%s%s.\n' "$ACCENT" "$profile_path" "$NC"
            printf 'Open a new terminal or run: %s. %s%s\n' "$ACCENT" "$profile_path" "$NC"
            printf 'Start Crystal Code with: %scrystal%s\n' "$ACCENT" "$NC"
            start_command="crystal"
            ;;
        *)
            printf 'Installed %s. Start Crystal Code with: %s%s%s\n' \
                "$binary_name" "$ACCENT" "${install_directory}/${binary_name}" "$NC"
            start_command="${install_directory}/${binary_name}"
            ;;
    esac

    printf '\n'
    printf '%scd <project>%s  %s# Open a repository%s\n' "$ACCENT" "$NC" "$MUTED" "$NC"
    if [ "$start_command" = "crystal" ]; then
        # Pad to the same column as "cd <project>".
        printf '%scrystal%s       %s# Start Crystal Code%s\n' "$ACCENT" "$NC" "$MUTED" "$NC"
    else
        printf '%s%s%s  %s# Start Crystal Code%s\n' "$ACCENT" "$start_command" "$NC" "$MUTED" "$NC"
    fi
    printf '\n'
    printf '%sFor more information visit %s%s\n' "$MUTED" "$NC" "$docs_url"
    printf '\n'
}

# musl libc prints its banner to stderr and exits non-zero for ldd --version.
is_musl() {
    if [ -f /etc/alpine-release ]; then
        return 0
    fi

    command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl
}

detect_asset() {
    operating_system="$(uname -s)"
    architecture="$(uname -m)"

    case "$operating_system" in
        Linux)
            libc_suffix=
            if is_musl; then
                libc_suffix="musl-"
            fi

            case "$architecture" in
                x86_64 | amd64)
                    printf '%s\n' "linux-${libc_suffix}x64"
                    ;;
                aarch64 | arm64)
                    printf '%s\n' "linux-${libc_suffix}arm64"
                    ;;
                *)
                    fail "Unsupported Linux architecture: $architecture"
                    ;;
            esac
            ;;
        Darwin)
            case "$architecture" in
                arm64)
                    printf '%s\n' "macos-arm64"
                    ;;
                x86_64)
                    if [ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" = "1" ]; then
                        printf '%s\n' "macos-arm64"
                    else
                        printf '%s\n' "macos-x64"
                    fi
                    ;;
                *)
                    fail "Unsupported macOS architecture: $architecture"
                    ;;
            esac
            ;;
        *)
            fail "Unsupported operating system: $operating_system"
            ;;
    esac
}

# GNU sed flushes with -u. BSD sed flushes with -l. The padded fallback
# forces a flush where neither flag exists.
unbuffered_sed() {
    if echo | sed -u -e '' >/dev/null 2>&1; then
        sed -nu "$@"
    elif echo | sed -l -e '' >/dev/null 2>&1; then
        sed -nl "$@"
    else
        pad=$(printf '\n%512s' '')
        sed -ne "s/\$/${pad}/" "$@"
    fi
}

is_uint() {
    case "$1" in
        '' | *[!0-9]*)
            return 1
            ;;
    esac
    return 0
}

render_bar() {
    received=$1
    total=$2
    if ! is_uint "$received" || ! is_uint "$total" || [ "$total" -le 0 ]; then
        return 0
    fi

    width=50
    percent=$((received * 100 / total))
    if [ "$percent" -gt 100 ]; then
        percent=100
    fi
    if [ "$percent" -eq "${last_percent:--1}" ]; then
        return 0
    fi
    last_percent=$percent

    on=$((percent * width / 100))
    off=$((width - on))
    filled=
    empty=
    i=0
    while [ "$i" -lt "$on" ]; do
        filled="${filled}━"
        i=$((i + 1))
    done
    i=0
    while [ "$i" -lt "$off" ]; do
        empty="${empty}─"
        i=$((i + 1))
    done

    # stderr is unbuffered, so a carriage return redraws the same line.
    printf '\r%s%s%s %3d%%%s' "$ACCENT" "$filled" "$empty" "$percent" "$NC" >&2
}

# curl's ascii trace reports Content-Length and each received block.
# sed keeps only those lines, and the shell redraws one bar from them.
# Arguments: URL, destination file.
download_with_progress() {
    transfer_url=$1
    transfer_path=$2

    if [ "$styled" != true ] || ! command -v mkfifo >/dev/null 2>&1 || ! command -v sed >/dev/null 2>&1; then
        return 1
    fi

    trace_path="${working_directory}/download.trace"
    rm -f "$trace_path"
    if ! mkfifo "$trace_path"; then
        return 1
    fi

    printf '\033[?25l' >&2
    cursor_hidden=true

    # stderr stays quiet here. A failed attempt falls back to curl, and an
    # interrupt must not print a write error after the temp directory is gone.
    curl --fail --location --silent --trace-ascii "$trace_path" --output "$transfer_path" "$transfer_url" 2>/dev/null &
    download_pid=$!

    length=0
    bytes=0
    last_percent=-1
    unbuffered_sed \
        -e 'y/ACDEGHLNORTV/acdeghlnortv/' \
        -e '/^0000: content-length:/p' \
        -e '/^<= recv data/p' \
        "$trace_path" | while IFS= read -r line; do
        case "$line" in
            "0000: content-length:"*)
                length=${line#0000: content-length:}
                length=${length# }
                length=${length%%[!0-9]*}
                bytes=0
                ;;
            "<= recv data,"*)
                size=${line#<= recv data,}
                size=${size# }
                size=${size%%[!0-9]*}
                if is_uint "$size" && is_uint "$length" && [ "$length" -gt 0 ]; then
                    bytes=$((bytes + size))
                    render_bar "$bytes" "$length"
                fi
                ;;
        esac
    done || true

    download_status=0
    if [ -n "${download_pid:-}" ]; then
        wait "$download_pid" || download_status=$?
        download_pid=
    else
        # The interrupt trap already reaped the downloader.
        download_status=130
    fi

    if [ "$download_status" -ne 0 ]; then
        restore_cursor
        # 128+signal means the download was interrupted. Do not start another curl.
        if [ "$download_status" -gt 128 ]; then
            exit "$download_status"
        fi
        return 1
    fi

    final_size=$(wc -c < "$transfer_path" | tr -d '[:space:]') || final_size=0
    if is_uint "$final_size" && [ "$final_size" -gt 0 ]; then
        last_percent=-1
        render_bar "$final_size" "$final_size"
    fi
    printf '\n' >&2
    printf '\033[?25h' >&2
    cursor_hidden=false
    return 0
}

# Downloads one archive with a progress bar on a terminal and plain curl
# output elsewhere. Returns non-zero on failure so the caller picks the message.
# Arguments: URL, destination file, display name.
download_archive() {
    archive_url=$1
    archive_destination=$2
    archive_label=$3

    if [ "$styled" = true ]; then
        if ! download_with_progress "$archive_url" "$archive_destination"; then
            if ! curl -# --fail --show-error --location --output "$archive_destination" "$archive_url"; then
                return 1
            fi
            printf '\n'
        fi
    else
        printf 'Downloading %s...\n' "$archive_label"
        if ! curl --fail --location --show-error --output "$archive_destination" "$archive_url"; then
            return 1
        fi
    fi
}

# Prints one result line. Kinds: ok, skip, fail. A failure is counted and sent
# to stderr, but it never stops the installer: Crystal Code is already in place.
# Arguments: kind, label, message.
report_step() {
    step_kind=$1
    step_label=$2
    step_message=$3

    case "$step_kind" in
        ok)
            step_tag="done"
            step_color=$ACCENT
            ;;
        skip)
            step_tag="skip"
            step_color=$MUTED
            ;;
        *)
            step_tag="fail"
            step_color=$FAIL
            extras_failed=$((extras_failed + 1))
            ;;
    esac

    if [ "$step_tag" = fail ]; then
        printf '  %s[%s]%s %-9s %s\n' "$step_color" "$step_tag" "$NC" "$step_label" "$step_message" >&2
    else
        printf '  %s[%s]%s %-9s %s\n' "$step_color" "$step_tag" "$NC" "$step_label" "$step_message"
    fi
}

# A line that the next result replaces. Plain output has no such line, because
# the download prints its own.
# Arguments: label, message.
announce_step() {
    if [ "$styled" = true ]; then
        printf '  %s[....]%s %-9s %s\n' "$MUTED" "$NC" "$1" "$2" >&2
    fi
}

erase_lines() {
    printf '\033[%dA\r\033[J' "$1" >&2
}

clear_line() {
    if [ "$styled" = true ]; then
        printf '\r\033[2K' >&2
    fi
}

# Redraws one inline bar that carries its own label.
# Arguments: label, received, total.
render_count_bar() {
    if [ "$styled" != true ]; then
        return 0
    fi

    count_width=30
    count_on=$(($2 * count_width / $3))
    count_filled=
    count_empty=
    count_index=0
    while [ "$count_index" -lt "$count_width" ]; do
        if [ "$count_index" -lt "$count_on" ]; then
            count_filled="${count_filled}━"
        else
            count_empty="${count_empty}─"
        fi
        count_index=$((count_index + 1))
    done

    printf '\r\033[2K  %s[....]%s %-9s %s%s%s%s %s/%s' \
        "$MUTED" "$NC" "$1" "$ACCENT" "$count_filled" "$count_empty" "$NC" "$2" "$3" >&2
}

# Returns 0 for a missing or empty directory, 1 when it has entries, and 2
# when the path exists but is not a directory.
directory_state() {
    if [ ! -e "$1" ]; then
        return 0
    fi
    if [ ! -d "$1" ]; then
        return 2
    fi
    if [ -n "$(ls -A "$1" 2>/dev/null)" ]; then
        return 1
    fi
    return 0
}

# Downloads a small file. The curl message is kept in fetch_error.
# Arguments: URL, destination file.
fetch_file() {
    if fetch_error=$(curl --fail --location --silent --show-error \
        --retry 2 --retry-delay 1 --connect-timeout 15 --max-time 120 \
        --output "$2" "$1" 2>&1); then
        return 0
    fi

    # curl may print several lines. The last one names the cause.
    fetch_error=$(printf '%s' "$fetch_error" | tail -n 1)
    return 1
}

# A manifest line must be a plain *.json file name. It becomes a URL segment and
# a path under the target directory, so nothing else is allowed through.
is_catalog_file_name() {
    case "$1" in
        '' | .* | *[!A-Za-z0-9._-]*)
            return 1
            ;;
        *.json)
            return 0
            ;;
    esac
    return 1
}

# Fills an empty directory with every file named by a manifest. Files go to a
# staging directory first, so a failed download leaves the target untouched and
# a later run tries again.
# Arguments: label, manifest name, remote directory, target directory.
install_catalog() {
    catalog_label=$1
    catalog_manifest=$2
    catalog_remote=$3
    catalog_target=$4

    catalog_state=0
    directory_state "$catalog_target" || catalog_state=$?
    case "$catalog_state" in
        1)
            report_step skip "$catalog_label" "${catalog_target} already has files"
            return 0
            ;;
        2)
            report_step fail "$catalog_label" "${catalog_target} exists and is not a directory"
            return 0
            ;;
    esac

    manifest_path="${working_directory}/${catalog_manifest}"
    if ! fetch_file "${scripts_base}/${catalog_manifest}" "$manifest_path"; then
        report_step fail "$catalog_label" "Could not download ${catalog_manifest}: ${fetch_error}"
        return 0
    fi

    # Strip carriage returns so a manifest saved on Windows still works.
    file_list="${manifest_path}.list"
    : > "$file_list"
    while IFS= read -r manifest_line || [ -n "$manifest_line" ]; do
        manifest_line=$(printf '%s' "$manifest_line" | tr -d '\r')
        if [ -z "$manifest_line" ]; then
            continue
        fi
        if ! is_catalog_file_name "$manifest_line"; then
            report_step fail "$catalog_label" "${catalog_manifest} has an invalid file name: ${manifest_line}"
            return 0
        fi
        printf '%s\n' "$manifest_line" >> "$file_list"
    done < "$manifest_path"

    catalog_total=$(wc -l < "$file_list" | tr -d '[:space:]')
    if [ "$catalog_total" -eq 0 ]; then
        report_step fail "$catalog_label" "${catalog_manifest} lists no files"
        return 0
    fi

    staging_directory="${working_directory}/stage-${catalog_label}"
    mkdir -p "$staging_directory"
    catalog_index=0
    if [ "$styled" != true ]; then
        printf 'Downloading %s files (%s)...\n' "$catalog_label" "$catalog_total"
    fi
    while IFS= read -r catalog_file; do
        render_count_bar "$catalog_label" "$catalog_index" "$catalog_total"
        if ! fetch_file "${defaults_base}/${catalog_remote}/${catalog_file}" "${staging_directory}/${catalog_file}"; then
            clear_line
            report_step fail "$catalog_label" "Could not download ${catalog_file}: ${fetch_error}"
            return 0
        fi
        if [ ! -s "${staging_directory}/${catalog_file}" ]; then
            clear_line
            report_step fail "$catalog_label" "${catalog_file} downloaded empty"
            return 0
        fi
        catalog_index=$((catalog_index + 1))
    done < "$file_list"
    clear_line

    if ! mkdir -p "$catalog_target"; then
        report_step fail "$catalog_label" "Could not create ${catalog_target}"
        return 0
    fi

    if ! cp "$staging_directory"/*.json "$catalog_target"/; then
        # The directory was empty before this step, so removing only what the
        # manifest names restores it.
        while IFS= read -r catalog_file; do
            rm -f "${catalog_target}/${catalog_file}"
        done < "$file_list"
        rmdir "$catalog_target" 2>/dev/null || true
        report_step fail "$catalog_label" "Could not write files to ${catalog_target}"
        return 0
    fi

    report_step ok "$catalog_label" "Installed ${catalog_total} files to ${catalog_target}"
    }

install_themes() {
    install_catalog themes themes.txt themes "${crystal_home}/themes"
}

install_providers() {
    install_catalog providers providers.txt providers "${crystal_home}/providers"
}

# Installs the latest web plugin into plugins/web when plugins/ is empty. The
# release archive is built per platform with the same names as the core
# archives, so the detected asset applies here too.
install_plugin() {
    plugins_directory="${crystal_home}/plugins"
    plugin_target="${plugins_directory}/${plugin_directory_name}"

    plugin_state=0
    directory_state "$plugins_directory" || plugin_state=$?
    case "$plugin_state" in
        1)
            report_step skip plugins "${plugins_directory} already has entries"
            return 0
            ;;
        2)
            report_step fail plugins "${plugins_directory} exists and is not a directory"
            return 0
            ;;
    esac

    plugin_archive_name="CrystalCode.Web-${asset}.zip"
    plugin_archive_path="${working_directory}/${plugin_archive_name}"
    plugin_url="https://github.com/${plugin_repository}/releases/latest/download/${plugin_archive_name}"

    announce_step plugins "Downloading ${plugin_archive_name}"
    if ! download_archive "$plugin_url" "$plugin_archive_path" "$plugin_archive_name"; then
        if [ "$styled" = true ]; then
            erase_lines 2
        fi
        report_step fail plugins "Could not download ${plugin_archive_name} from the latest release"
        return 0
    fi
    if [ "$styled" = true ]; then
        erase_lines 2
    fi

    plugin_extraction="${working_directory}/plugin"
    mkdir -p "$plugin_extraction"
    if ! unzip -qo "$plugin_archive_path" -d "$plugin_extraction"; then
        report_step fail plugins "Could not extract ${plugin_archive_name}"
        return 0
    fi

    plugin_manifest="$(find "$plugin_extraction" -type f -name plugin.json -print | head -n 1)"
    if [ -z "$plugin_manifest" ]; then
        report_step fail plugins "${plugin_archive_name} does not contain plugin.json"
        return 0
    fi

    plugin_source="$(dirname "$plugin_manifest")"
    if [ ! -f "${plugin_source}/CrystalCode.Web.dll" ]; then
        report_step fail plugins "${plugin_archive_name} does not contain CrystalCode.Web.dll"
        return 0
    fi

    # The manifest ships enabled. Make that true even if a release changes it.
    if grep -Eq '"enabled"[[:space:]]*:[[:space:]]*false' "$plugin_manifest"; then
        if ! sed 's/\("enabled"[[:space:]]*:[[:space:]]*\)false/\1true/' "$plugin_manifest" > "${plugin_manifest}.tmp" ||
            ! mv "${plugin_manifest}.tmp" "$plugin_manifest"; then
            report_step fail plugins "Could not enable the plugin in plugin.json"
            return 0
        fi
    fi

    if ! mkdir -p "$plugin_target" || ! cp -R "$plugin_source"/. "$plugin_target"/; then
        # plugins/ was empty before this step, so the plugin directory is ours.
        rm -rf -- "$plugin_target"
        rmdir "$plugins_directory" 2>/dev/null || true
        report_step fail plugins "Could not write files to ${plugin_target}"
        return 0
    fi

    report_step ok plugins "Installed ${plugin_directory_name} to ${plugin_target}"

    # Discovery is on by default. Only an explicit false in config.json turns it off.
    if [ -f "${crystal_home}/config.json" ] &&
        grep -Eq '"plugins"[[:space:]]*:[[:space:]]*false' "${crystal_home}/config.json"; then
        printf '  %s[note]%s %-9s Plugin discovery is off in config.json. Run /plugins on in Crystal Code.\n' \
            "$MUTED" "$NC" plugins
    fi
}

# Installs the latest web client into web/ when it is missing or empty. The
# archive holds the built site at its root, so it extracts straight into web/.
install_web() {
    web_target="${crystal_home}/web"

    web_state=0
    directory_state "$web_target" || web_state=$?
    case "$web_state" in
        1)
            report_step skip web "${web_target} already has files"
            return 0
            ;;
        2)
            report_step fail web "${web_target} exists and is not a directory"
            return 0
            ;;
    esac

    web_archive_path="${working_directory}/${web_archive_name}"
    web_url="https://github.com/${web_repository}/releases/latest/download/${web_archive_name}"

    announce_step web "Downloading ${web_archive_name}"
    if ! download_archive "$web_url" "$web_archive_path" "$web_archive_name"; then
        if [ "$styled" = true ]; then
            erase_lines 2
        fi
        report_step fail web "Could not download ${web_archive_name} from the latest release"
        return 0
    fi
    if [ "$styled" = true ]; then
        erase_lines 2
    fi

    web_extraction="${working_directory}/web"
    mkdir -p "$web_extraction"
    if ! unzip -qo "$web_archive_path" -d "$web_extraction"; then
        report_step fail web "Could not extract ${web_archive_name}"
        return 0
    fi

    if [ ! -f "${web_extraction}/index.html" ]; then
        report_step fail web "${web_archive_name} does not contain index.html"
        return 0
    fi

    if ! mkdir -p "$web_target" || ! cp -R "$web_extraction"/. "$web_target"/; then
        # web/ was missing or empty before this step, so it is ours to remove.
        rm -rf -- "$web_target"
        report_step fail web "Could not write files to ${web_target}"
        return 0
    fi

    report_step ok web "Installed web client to ${web_target}"
}

install_extras() {
    printf '\n%sSetting up web, plugins, providers, and themes...%s\n\n' "$MUTED" "$NC"
    install_web
    install_plugin
    install_providers
    install_themes

    if [ "$extras_failed" -gt 0 ]; then
        printf '\n' >&2
        if [ "$styled" = true ]; then
            printf '%sCrystal Code is installed, but %s extra step(s) did not finish.%s\n' "$FAIL" "$extras_failed" "$NC" >&2
        else
            printf 'Crystal Code is installed, but %s extra step(s) did not finish.\n' "$extras_failed" >&2
        fi
        printf 'Run this installer again after fixing the cause. Finished steps are skipped.\n' >&2
    fi
}

require_command curl
require_command unzip
require_command mktemp
require_command grep
require_command tail
require_command tr
require_command mv

asset="$(detect_asset)"
archive_name="CrystalCode-${asset}.zip"
download_url="https://github.com/${repository}/releases/latest/download/${archive_name}"
working_directory="$(mktemp -d "${TMPDIR:-/tmp}/crystalcode.XXXXXX")"
archive_path="${working_directory}/${archive_name}"
extraction_directory="${working_directory}/extracted"

cleanup() {
    restore_cursor
    if [ -n "${download_pid:-}" ]; then
        kill "$download_pid" 2>/dev/null || true
        wait "$download_pid" 2>/dev/null || true
        download_pid=
    fi
    if [ -n "${working_directory:-}" ]; then
        rm -rf -- "$working_directory"
        working_directory=
    fi
}

# A signal trap that returns lets the script continue into wait and a second
# curl against the directory cleanup just removed.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

if [ "$styled" = true ]; then
    printf '%sInstalling Crystal Code...%s\n\n' "$MUTED" "$NC"
fi
if ! download_archive "$download_url" "$archive_path" "$archive_name"; then
    fail "Could not download ${archive_name} from the latest release."
fi

if [ "$styled" != true ]; then
    printf 'Extracting %s...\n' "$archive_name"
fi
mkdir -p "$extraction_directory"
if ! unzip -q "$archive_path" -d "$extraction_directory"; then
    fail "Could not extract ${archive_name}."
fi

published_binary="$(find "$extraction_directory" -type f -name "$binary_name" -print | head -n 1)"
if [ -z "$published_binary" ]; then
    fail "The archive does not contain ${binary_name}."
fi

published_directory="$(dirname "$published_binary")"
if [ "$styled" != true ]; then
    printf 'Installing Crystal Code files...\n'
fi
mkdir -p "$install_directory"
cp -R "$published_directory"/. "$install_directory"/
chmod 755 "${install_directory}/${binary_name}"

if [ "$styled" = true ]; then
    configure_path
    install_extras
    print_card
else
    printf 'Installed %s to %s\n' "$archive_name" "$install_directory"
    printf 'Configuring PATH...\n'
    configure_path
    install_extras
fi
