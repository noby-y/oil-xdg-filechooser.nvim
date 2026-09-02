# oil-filechooser

This plugin uses [Oil.nvim](https://github.com/stevearc/oil.nvim) (also works with [Canola.nvim](https://github.com/barrettruth/canola.nvim)) as the system file dialog.
Every application that asks the XDG portal for a file - browser upload
buttons, Save As dialogs, etc - gets an oil buffer in a floating
terminal instead of the GTK chooser.

When you install the plugin it registers itself with
`xdg-desktop-portal` on startup and keeps that registration in step with its
options; nothing is written outside `$HOME` and nothing needs root.

https://github.com/user-attachments/assets/39f85590-5096-4d58-a823-fdf5ad02f223

## Installation

<details>
<summary>With <a href="https://github.com/folke/lazy.nvim">lazy.nvim</a></summary>

```lua
{
    'noby-y/oil-xdg-filechooser.nvim',
    lazy = false,
    -- dependencies = { 'stevearc/oil.nvim' }, -- both plugins work
    dependencies = { 'barrettruth/canola.nvim' },
    opts = {},
}
```

</details>

<details>
<summary>With <code>vim.pack</code> (Neovim 0.12+)</summary>

```lua
vim.pack.add({
    -- 'https://github.com/stevearc/oil.nvim', -- both plugins work
    'https://github.com/barrettruth/canola.nvim',
    'https://github.com/noby-y/oil-xdg-filechooser.nvim',
})

require('oil-filechooser').setup({})
```

</details>

Requires `python-gobject` (the daemon is a GDBus service), systemd user
services, and a terminal.

## Using it

The dialog opens on the folder the application asked for, or the one it last
used.

| Key | Action |
| --- | --- |
| `<CR>` | Return the file under the cursor. On a directory, descend as usual. |
| `<CR>` (visual) | Return every file in the range. Multi-select requests only. |
| `<Tab>` | Mark a file. Multi-select requests only, and the only way to pick from two directories. |
| `<C-y>` | Return the directory you are in. For a save request, ask for a filename in it first. |
| `q` | Cancel. Quitting Neovim in any other way does the same. |

It is an ordinary Neovim: rename, delete and create files in the oil buffer,
open a terminal, edit something on the way. The application stays blocked until
the process exits.

If the file you return matches none of the request's filters you are asked to
confirm, because the application is free to reject it - usually silently.

## Default config

```lua
{
    keymaps = {
        accept = '<CR>',
        accept_dir = '<C-y>',
        toggle_mark = '<Tab>',
        cancel = 'q',
    },

    -- show what was asked for + keymaps above the buffer
    winbar = true,
    -- ask before selecting a filetype that doesn't match the request
    confirm_filter_mismatch = true,
    -- auto-install (sync) on each startup (run `:OilFileChooser install` otherwise)
    auto_install = true,
    -- also point ~/.config/xdg-desktop-portal at it
    manage_portal_preference = true,
}
```

`:OilFileChooser` command has 3 arguments:
- `status` prints what is installed and what is off-sync
- `install` and `uninstall` will manually add/remove the necessary files for portal preference / filechooser service. Uninstalling hands the dialog back to GTK.

The daemon picks a terminal based on `$TERMINAL` env var and uses it if it's set to
something on `$PATH`; otherwise it falls back to the first terminal found from:
`kitty`, `ghostty`, `wezterm`, `foot`, `alacritty`, in that order.
A `$TERMINAL` outside that list still works, but without the window-class flag used for WM rules.

The flag sets the window class (app-id on Wayland) to `oil-filechooser`, which
is what a WM rule matches on - a dialog is worth floating and centring (example with Hyprland):

```lua
hl.window_rule({
	name = 'oil-filechooser',
	match = { class = '^(oil-filechooser)$' },

	float = true,
	size = '(monitor_w*0.8) (monitor_h*0.8)',
	move = '(monitor_w*0.1) (monitor_h*0.1)',
})
```


## How it works

1. An application asks `xdg-desktop-portal` for a file. The portal's config
   names this backend, and D-Bus activation starts `daemon/portal.py`.
2. The daemon writes the request to a JSON file, points
   `$OIL_FILECHOOSER_REQUEST` at it and launches the terminal.
3. This plugin sees that variable, opens oil and installs the keymaps above.
   Confirming writes the chosen paths to a response file and quits.
4. The daemon turns those paths into `file://` URIs and answers the D-Bus call.
   No response file means the user cancelled.

Dialogs are answered from a child watch rather than a blocking wait, so two
applications asking at once get two windows. `org.freedesktop.impl.portal.Request.Close`
is honoured, so an application that gives up takes its dialog with it.

## Files it writes

| Path | Purpose |
| --- | --- |
| `~/.local/share/xdg-desktop-portal/portals/oil-filechooser.portal` | Declares the backend |
| `~/.local/share/dbus-1/services/org.freedesktop.impl.portal.desktop.oil-filechooser.service` | D-Bus activation |
| `~/.config/systemd/user/oil-filechooser.service` | The unit, enabled `WantedBy=xdg-desktop-portal.service` |
| `~/.config/xdg-desktop-portal/portals.conf` and `<desktop>-portals.conf` | Routes `FileChooser` here, keeping the existing `default=` chain |

## Testing

`tests/request.py` sends a request the way an application would:

```sh
tests/request.py open --multiple --filter '*.png' --folder ~/Pictures
tests/request.py save --name notes.md
tests/request.py --portal open          # through xdg-desktop-portal, end to end
```
