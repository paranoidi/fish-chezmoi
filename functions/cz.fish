function __cz_modified_files
    chezmoi status | awk '$1 ~ /^[ M]/ {print $2}'
end

function __cz_deleted_files
    chezmoi status | awk '$1 ~ /^D/ {print $2}'
end

function __cz_is_template_source --argument-names source_path
    string match -rq '(^|\\.)tmpl($|\\.)' -- "$source_path"
end

function __cz_wide_emoji --argument-names emoji
    if set -q TMUX
        echo -n "$emoji "
    else
        echo -n "$emoji  "
    end
end

function __cz_status_without_template_sources
    chezmoi status | while read -l line
        set target_path (string trim -- "$line" | string replace -r '^\S+\s+' '')
        set source_path (chezmoi source-path "$HOME/$target_path" 2>/dev/null)

        if test $status -eq 0; and __cz_is_template_source "$source_path"
            continue
        end

        # Chezmoi uses " R" for run-on-apply scripts; avoid confusion with Removed.
        if string match -rq '^ R' -- "$line"
            echo (string replace -r '^ R' '🚀' -- "$line")
        else if string match -rq '^ M' -- "$line"
            # Filter out false-positive " M" entries where the file content
            # is actually identical but chezmoi flags it (e.g. execute-bit
            # mismatches between source and destination, or files restored
            # to identical content). Only show if there's a real diff.
            # Mode-only diffs (execute-bit changes) produce header lines but no
            # content hunks. Check for actual content changes by looking for @@ hunk headers.
            if not chezmoi diff --reverse --exclude=scripts "$HOME/$target_path" 2>/dev/null | string match -rq '@@'
                continue
            end
            echo "$line"
        else
            echo "$line"
        end
    end
end

function __cz_source_dir
    chezmoi execute-template '{{ .chezmoi.sourceDir }}'
end

function __cz_is_initialized
    set -l sd (chezmoi source-path 2>/dev/null)
    test -n "$sd" -a -d "$sd"
end

function __cz_help_workflow_commands
    echo -e "  cz \e[1mu\e[0mpdate           → Pull latest state + apply to \$HOME"
    echo -e "  cz \e[1ma\e[0mdd [file]       → Add all local changes into chezmoi (excl. templates) or given file"
    echo -e "  cz \e[1mb\e[0macktrack <file> → Restore file to chezmoi-managed state (discard local changes)"
    echo -e "  cz \e[1ms\e[0mtatus           → Show status diff"
    echo -e "  cz \e[1md\e[0miff             → Show detailed diff"
    echo -e "  cz \e[1mr\e[0mecord [msg]     → Add all changes + git commit [message]"
    echo -e "  cz \e[1mp\e[0mush             → Push commits to remote"
    echo -e "  cz \e[1mf\e[0mull [msg]       → Full sync cycle [message]"
    echo -e "  cz \e[1mc\e[0mlean            → Offer to remove deleted files (git deletes; renames not covered)"
    echo -e "  cz \e[1mg\e[0mit              → cd into chezmoi source directory"
end

function __cz_help_init_command
    echo -e "  cz \e[1mi\e[0mnit <username>  → Bootstrap chezmoi from GitHub dotfiles repo"
end

function __cz_git_repo_summary
    set -l sd (__cz_source_dir)

    if not test -d "$sd"
        echo "🚫 chezmoi source directory not found: $sd"
        return 1
    end

    if not git -C "$sd" rev-parse --is-inside-work-tree >/dev/null 2>&1
        echo "🚫 Not a git repository: $sd"
        return 1
    end

    # Branch info
    set -l branch (git -C "$sd" rev-parse --abbrev-ref HEAD 2>/dev/null)
    #printf "🔀 chezmoi git [%s]" "$branch"

    # Ahead/behind
    if git -C "$sd" rev-parse --abbrev-ref @{upstream} >/dev/null 2>&1
        set -l ahead (git -C "$sd" rev-list --count @{upstream}..HEAD 2>/dev/null)
        set -l behind (git -C "$sd" rev-list --count HEAD..@{upstream} 2>/dev/null)
        if test "$ahead" -gt 0; or test "$behind" -gt 0
            printf "🔀 git %s↑ %s↓" "$ahead" "$behind"
        end
    end
    echo ""

    set -l has_any 0

    # Staged changes
    set -l staged (git -C "$sd" diff --cached --name-status 2>/dev/null)
    if test -n "$staged"
        if test $has_any -eq 1
            echo ""
        end
        set has_any 1
        __cz_git_repo_section_header "staged" "33"
        for line in $staged
            echo "$line" | string replace -r '^([^	]+)	' '$1  '
        end
    end

    # Unstaged modified
    set -l modified (git -C "$sd" diff --name-only 2>/dev/null)
    if test -n "$modified"
        if test $has_any -eq 1
            echo ""
        end
        set has_any 1
        __cz_git_repo_section_header "unstaged" "36"
        for f in $modified
            echo "$f" | string replace -r '^' 'M  '
        end
    end

    # Untracked
    set -l untracked (git -C "$sd" ls-files --others --exclude-standard 2>/dev/null | string match -rv '^.chezmoi')
    if test -n "$untracked"
        if test $has_any -eq 1
            echo ""
        end
        set has_any 1
        __cz_git_repo_section_header "untracked" "90"
        for f in $untracked
            echo "$f" | string replace -r '^' '?  '
        end
    end

    if test $has_any -eq 0
        return 2
    end

    return 0
end

function __cz_git_repo_section_header
    set -l label $argv[1]
    set -l color $argv[2]
    printf "\033[%sm◆ %s\033[0m\n" "$color" "$label"
end

function __cz_rel_path_in_head --argument-names sd rel_path
    git -C "$sd" cat-file -e "HEAD:$rel_path" 2>/dev/null
end

function __cz_clean_resolve_target --argument-names sd rel_path
    set -l D (git -C "$sd" log --diff-filter=D -1 --pretty=%H -- -- "$rel_path" 2>/dev/null)
    test -n "$D"; or return 1
    if not git -C "$sd" rev-parse --verify -q "$D^" >/dev/null 2>&1
        return 1
    end
    set -l parent (git -C "$sd" rev-parse "$D^")

    set -l item_tmp (mktemp -d)
    set -l dst "$item_tmp/$rel_path"
    mkdir -p (path dirname "$dst"); or begin
        rm -rf "$item_tmp"
        return 1
    end

    if not git -C "$sd" show "$parent:$rel_path" >"$dst" 2>/dev/null
        rm -rf "$item_tmp"
        return 1
    end

    set -l target (chezmoi target-path -S "$item_tmp" -D "$HOME" "$dst" 2>/dev/null)
    set -l st $status
    rm -rf "$item_tmp"
    if test $st -ne 0; or test -z "$target"
        return 1
    end
    printf '%s' "$target"
end

function __cz_clean_decline_file --argument-names sd
    printf '%s' "$sd/.chezmoi/cz_clean_declines"
end

function __cz_clean_commit_declines
    set -l sd $argv[1]
    set -l pending $argv[2..-1]

    if test (count $pending) -eq 0
        return 0
    end

    set -l decline_f (__cz_clean_decline_file "$sd")
    set -l existing
    if test -f "$decline_f"
        set existing (string trim <$decline_f | string match -rv '^$')
    end

    set -l merged (printf '%s\n' $existing $pending | string trim | string match -rv '^$' | sort -u)

    mkdir -p (path dirname "$decline_f")
    printf '%s\n' $merged >"$decline_f"

    if not chezmoi git -- add .chezmoi/cz_clean_declines
        echo "🚫 chezmoi git add failed for .chezmoi/cz_clean_declines"
        return 1
    end

    if chezmoi git -- diff --staged --quiet
        echo (__cz_wide_emoji "ℹ️")"Decline manifest unchanged in git (paths already recorded)"
        return 0
    end

    if chezmoi git -- commit -m "cz clean: record keep-local declines"
        echo "🏆 Recorded keep-local declines in chezmoi git"
        return 0
    end

    echo "🚫 chezmoi git commit failed; fix or run cz record"
    return 1
end

function __cz_clean
    set -l sd (__cz_source_dir)

    if not test -d "$sd"
        echo "🚫 chezmoi source directory not found: $sd"
        return 1
    end

    if not git -C "$sd" rev-parse --is-inside-work-tree >/dev/null 2>&1
        echo "🚫 Not a git repository: $sd"
        return 1
    end

    set -l rel_paths (
        git -C "$sd" log --all --diff-filter=D --name-only --pretty=format: |
        string trim |
        string match -rv '^$' |
        sort -u
    )

    if test (count $rel_paths) -eq 0
        echo (__cz_wide_emoji "ℹ️")"No deleted source paths in git history"
        return 0
    end

    set -l decline_f (__cz_clean_decline_file "$sd")
    set -l declined_paths
    if test -f "$decline_f"
        set declined_paths (string trim <$decline_f | string match -rv '^$')
    end

    set -l prompted 0
    set -l removed 0
    set -l aborted 0
    set -l pending_declines

    for rel_path in $rel_paths
        if __cz_rel_path_in_head "$sd" "$rel_path"
            continue
        end

        if contains -- "$rel_path" $declined_paths
            echo (__cz_wide_emoji "⏭️")"$rel_path (keep-local, recorded earlier)"
            continue
        end

        set -l target (__cz_clean_resolve_target "$sd" "$rel_path")
        if test $status -ne 0; or test -z "$target"
            continue
        end

        if not test -e "$target"
            continue
        end

        if chezmoi source-path "$target" >/dev/null 2>&1
            continue
        end

        set -l D (git -C "$sd" log --diff-filter=D -1 --pretty=%H -- -- "$rel_path" 2>/dev/null)
        set -l subj (git -C "$sd" log -1 --pretty=%s "$D" 2>/dev/null)

        echo ""
        echo "Removed from repo : $rel_path"
        echo "Deleting commit   : $subj"
        echo "Still on disk     : $target"

        read -P "Remove this path? [y/N/q] " ans

        if string match -q -i q -- "$ans"
            set aborted 1
            echo "Stopped."
            break
        end

        if string match -q -i y -- "$ans"
            if test -d "$target"
                rm -rf "$target"
            else
                rm -f "$target"
            end
            echo "💀 Removed"
            set prompted (math $prompted + 1)
            set removed (math $removed + 1)
        else
            set prompted (math $prompted + 1)
            read -P "Record this keep-local choice in chezmoi git? [y/N] " record_one
            if string match -q -i y -- "$record_one"
                set -a pending_declines $rel_path
            end
        end
    end

    __cz_clean_commit_declines "$sd" $pending_declines
    set -l commit_st $status

    echo ""
    if test $aborted -eq 1
        echo "🏆 cz clean stopped ($removed removed, "(math $prompted - $removed)" skipped before quit)"
        test $commit_st -eq 0; or return 1
        return 0
    end

    if test $prompted -eq 0
        echo (__cz_wide_emoji "ℹ️")"No leftover files on disk for historical source deletes (or all still managed / back in HEAD)"
        test $commit_st -eq 0; or return 1
        return 0
    end

    echo "🏆 cz clean finished ($removed removed, "(math $prompted - $removed)" skipped)"
    test $commit_st -eq 0; or return 1
    return 0
end

function __cz_import_changes
    set files (__cz_modified_files)

    if test (count $files) -eq 0
        echo (__cz_wide_emoji "⚠️")"No modified files"
        return 1
    end

    for f in $files
        set source_path (chezmoi source-path "$HOME/$f" 2>/dev/null)
        if test $status -ne 0
            echo "🚫 $f (could not resolve chezmoi source)"
            continue
        end

        if __cz_is_template_source "$source_path"
            echo (__cz_wide_emoji "⏭️")"$f (template source, skipped)"
            continue
        end

        echo "💾 $f"
        chezmoi add "$HOME/$f"
    end

    return 0
end

function cz

    set cmd $argv[1]

    if test -z "$cmd"
        set cmd help
    end

    if test "$cmd" = -h
        set cmd help-full
    end

    switch $cmd

    # ------------------------------------------------------------
    # HELP
    # ------------------------------------------------------------
    case help
        echo "cz - chezmoi workflow helper"
        echo ""
        echo "Commands:"
        if __cz_is_initialized
            __cz_help_workflow_commands
        else
            __cz_help_init_command
        end
        return 0

    # ------------------------------------------------------------
    # HELP FULL (-h)
    # ------------------------------------------------------------
    case help-full
        echo "cz - chezmoi workflow helper"
        echo ""
        echo "Commands:"
        __cz_help_workflow_commands
        __cz_help_init_command
        return 0

    # ------------------------------------------------------------
    # UPDATE (repo → home)
    # ------------------------------------------------------------
    case update u
        echo "🌐 cz update"

        chezmoi update
        chezmoi apply

        for hook in (functions --all | string match '__cz_hook_update_*')
            echo "⚓️ Hook: $hook"
            $hook
        end

        echo "🏆 Update complete"
        return 0

    # ------------------------------------------------------------
    # ADD (home → repo)
    # ------------------------------------------------------------
    case add a
        set file $argv[2]

        if test -n "$file"
            echo "🏠 cz add - Adding $file"
            chezmoi add "$file"
            echo "🏆 Add complete"
            return 0
        end

        echo "🏠 cz add - Importing local changes into chezmoi"

        __cz_import_changes

        # deletion handling
        set deleted (__cz_deleted_files)
        if test (count $deleted) -gt 0
            echo ""
            echo (__cz_wide_emoji "⚠️")"Deleted files detected:"
            for f in $deleted
                echo "   - $f"
            end

            read -P "❓ Remove these from chezmoi source as well? [y/N] " confirm
            if string match -q -i y -- "$confirm"
                for f in $deleted
                    echo "💀 $f"
                    chezmoi forget "$HOME/$f"
                end
            end
        end

        echo "🏆 Add complete"
        return 0

    # ------------------------------------------------------------
    # BACKTRACK (repo → home, single file)
    # ------------------------------------------------------------
    case backtrack b
        set file $argv[2]

        if test -z "$file"
            echo "Usage: cz backtrack <file>"
            return 1
        end

        echo "⏪ cz backtrack — restoring $file"
        chezmoi apply "$file"
        echo "🏆 Restored"
        return 0

    # ------------------------------------------------------------
    # STATUS
    # ------------------------------------------------------------
    case status s
        echo "🏠 cz status"
        __cz_git_repo_summary
        set -l gs $status
        switch $gs
        case 0
        case 2
            # clean — no separator needed before pending heading
        case 1
            return 1
        case '*'
            return $gs
        end
        # Only show pending section when there are actual pending files
        set -l pending (__cz_status_without_template_sources)
        if test -n "$pending"
            # Add blank line separator only when the repo summary had sections
            # (gs=0). When clean (gs=2), __cz_git_repo_summary already emitted
            # a blank line at line 79, so adding another would double it.
            if test $gs -eq 0
                echo ""
            end
            __cz_git_repo_section_header "pending" "35"
            printf '%s\n' $pending
        end
        return 0

    # ------------------------------------------------------------
    # DIFF
    # ------------------------------------------------------------
    case diff d
        echo "🏠 cz diff"
        # Reverse diff direction so local additions appear as '+' (green).
        # Exclude run scripts (R entries) — they have no meaningful diff content.
        chezmoi diff --reverse --exclude=scripts
        return 0

    # ------------------------------------------------------------
    # RECORD (safe + smart)
    # ------------------------------------------------------------
    case record r
        echo "💾 cz record"

        set modified (__cz_modified_files)
        if test (count $modified) -gt 0
            __cz_import_changes
        end

        set deleted (__cz_deleted_files)

        if test (count $deleted) -gt 0
            echo ""
            echo (__cz_wide_emoji "⚠️")"Deleted files detected (not auto-handled in record):"
            for f in $deleted
                echo "  - $f"
            end
            echo "Run 'cz add' if you want to process deletions."
        end

        # check if anything actually staged in git
        if not chezmoi git -- status --porcelain | string length -q
            echo (__cz_wide_emoji "ℹ️")"Nothing to record"
            return 0
        end

        set msg (string join ' ' $argv[2..-1])
        if test -z "$msg"
            set msg "Update dotfiles"
        end

        chezmoi git -- add -A
        chezmoi git -- commit -m "$msg"

        echo "🏆 Recorded"
        return 0

    # ------------------------------------------------------------
    # PUSH (repo → remote)
    # ------------------------------------------------------------
    case push p
        echo "🌐 cz push"
        chezmoi git -- push
        echo "🚀 Pushed"
        return 0

    # ------------------------------------------------------------
    # FULL (full pipeline)
    # ------------------------------------------------------------
    case full f
        echo "🏠 cz full"

        set msg (string join ' ' $argv[2..-1])
        if test -z "$msg"
            set msg "Full sync dotfiles"
        end

        cz update
        cz add
        cz record "$msg"
        cz push

        echo "🏆 Full sync complete"
        return 0

    # ------------------------------------------------------------
    # GIT (cd into chezmoi source)
    # ------------------------------------------------------------
    case git g
        chezmoi cd
        return 0

    # ------------------------------------------------------------
    # CLEAN (HOME leftovers after source file deleted in git)
    # ------------------------------------------------------------
    case clean c
        echo "🧹 cz clean — stale targets from git delete history"
        __cz_clean
        return $status

    # ------------------------------------------------------------
    # INIT (bootstrap chezmoi from GitHub)
    # ------------------------------------------------------------
    case init i
        set -l username $argv[2]

        if test -z "$username"
            echo "Usage: cz init <github-username>"
            return 1
        end

        echo "🚀 cz init — bootstrapping chezmoi from github.com/$username"
        set -l _cz_init_script (curl -fsLS https://get.chezmoi.io | string collect)
        sh -c "$_cz_init_script" -- init --apply "$username"
        return $status

    # ------------------------------------------------------------
    # UNKNOWN
    # ------------------------------------------------------------
    case '*'
        echo "Unknown command: cz $cmd"
        echo "Run: cz help"
        return 1
    end
end
