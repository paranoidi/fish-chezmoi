# fish-chezmoi

A fish shell plugin providing `cz` — a chezmoi workflow helper for managing dotfiles.

## Installation

### With [fisher](https://github.com/jorgebucaran/fisher)

```fish
fisher install paranoidi/fish-chezmoi
```

### Manual

Place `functions/cz.fish` in your fish config functions directory:

```fish
cp functions/cz.fish ~/.config/fish/functions/
```

## Usage

```
cz - chezmoi workflow helper

Commands:
  cz u[pdate]           Pull latest state + apply to $HOME
  cz a[dd] [file]       Add all local changes into chezmoi (excl. templates) or given file
  cz b[acktrack] <file> Restore file to chezmoi-managed state (discard local changes)
  cz s[tatus]           Show status diff
  cz d[iff]             Show detailed diff
  cz r[ecord] [msg]     Add all changes + git commit [message]
  cz p[ush]             Push commits to remote
  cz f[ull] [msg]       Full sync cycle [message]
  cz c[lean]            Offer to remove deleted files (git deletes; renames not covered)
  cz g[it]              cd into chezmoi source directory
```

## Hooks

After `cz update` finishes its chezmoi sync (`chezmoi update` + `chezmoi apply`), it
automatically discovers and runs every function matching `__cz_hook_update_*`. This
lets you chain arbitrary post-update tasks without touching the plugin itself.

Define a function anywhere on your fish function path:

```fish
function __cz_hook_update_fisher
    fisher_sync
end
```

The example above syncs [fisher](https://github.com/jorgebucaran/fisher) plugins every
time `cz update` runs. You can add as many hooks as you like — each one is called in
discovery order.

## Dependencies

- [chezmoi](https://www.chezmoi.io/) — dotfile manager
- git
- fish shell 3.4+

## License

MIT
