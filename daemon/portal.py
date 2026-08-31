#!/usr/bin/env python3
"""org.freedesktop.impl.portal.FileChooser backend that answers with Neovim + oil.

xdg-desktop-portal hands us a request over D-Bus, we open a terminal running
Neovim, and whatever oil returns becomes the dialog's answer. The Neovim side
lives in ../lua/oil-filechooser.

Two things are deliberate here:

* The request reaches Neovim as a JSON file pointed at by
  $OIL_FILECHOOSER_REQUEST -- never interpolated into a `-c "lua ..."` chunk.
  Every string in a request (title, current_name, filter names) comes from
  whichever application opened the dialog, so it is untrusted; a filename taken
  straight from a Content-Disposition header must not be able to become code.

* Dialogs are asynchronous. The D-Bus method call is answered from the child
  watch, not from a blocking wait, so a second application asking for a file
  while one dialog is open gets its own window instead of queueing behind it.
"""

import json
import os
import shutil
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

APP = "oil-filechooser"
BUS_NAME = f"org.freedesktop.impl.portal.desktop.{APP}"
OBJECT_PATH = "/org/freedesktop/portal/desktop"
FILECHOOSER_IFACE = "org.freedesktop.impl.portal.FileChooser"
REQUEST_IFACE = "org.freedesktop.impl.portal.Request"

# Response codes from the portal spec.
SUCCESS, CANCELLED, OTHER = 0, 1, 2

FILECHOOSER_XML = f"""
<node>
  <interface name="{FILECHOOSER_IFACE}">
    <property name="version" type="u" access="read"/>
    <method name="OpenFile">
      <arg type="o" name="handle" direction="in"/>
      <arg type="s" name="app_id" direction="in"/>
      <arg type="s" name="parent_window" direction="in"/>
      <arg type="s" name="title" direction="in"/>
      <arg type="a{{sv}}" name="options" direction="in"/>
      <arg type="u" name="response" direction="out"/>
      <arg type="a{{sv}}" name="results" direction="out"/>
    </method>
    <method name="SaveFile">
      <arg type="o" name="handle" direction="in"/>
      <arg type="s" name="app_id" direction="in"/>
      <arg type="s" name="parent_window" direction="in"/>
      <arg type="s" name="title" direction="in"/>
      <arg type="a{{sv}}" name="options" direction="in"/>
      <arg type="u" name="response" direction="out"/>
      <arg type="a{{sv}}" name="results" direction="out"/>
    </method>
    <method name="SaveFiles">
      <arg type="o" name="handle" direction="in"/>
      <arg type="s" name="app_id" direction="in"/>
      <arg type="s" name="parent_window" direction="in"/>
      <arg type="s" name="title" direction="in"/>
      <arg type="a{{sv}}" name="options" direction="in"/>
      <arg type="u" name="response" direction="out"/>
      <arg type="a{{sv}}" name="results" direction="out"/>
    </method>
  </interface>
</node>
"""

REQUEST_XML = f"""
<node>
  <interface name="{REQUEST_IFACE}">
    <method name="Close"/>
  </interface>
</node>
"""

# Only used when the config file is missing
FALLBACK_TERMINALS = [
    ["kitty", "--class", APP, "-e"],
    ["ghostty", f"--class={APP}", "-e"],
    ["foot", f"--app-id={APP}", "-e"],
    ["wezterm", "start", "--class", APP, "--"],
    ["alacritty", "--class", APP, "-e"],
]


def log(*args):
    print(f"{APP}:", *args, file=sys.stderr, flush=True)


def config_path():
    base = GLib.get_user_config_dir()
    return os.path.join(base, APP, "config.json")


def load_config():
    """Read the config the Neovim plugin writes, falling back to a usable default.

    Re-read per request, so changing the plugin's options only costs a Neovim
    restart rather than a daemon restart.
    """
    config = {}
    try:
        with open(config_path(), encoding="utf-8") as fh:
            config = json.load(fh)
    except FileNotFoundError:
        pass
    except (OSError, ValueError) as err:
        log(f"ignoring unreadable config: {err}")

    terminal = config.get("terminal")
    if not terminal:
        terminal = next(
            (t for t in FALLBACK_TERMINALS if shutil.which(t[0])),
            FALLBACK_TERMINALS[0],
        )
    return {
        "terminal": [str(a) for a in terminal],
        "editor": [str(a) for a in config.get("editor") or ["nvim"]],
    }


def runtime_dir():
    path = os.path.join(GLib.get_user_runtime_dir(), APP)
    os.makedirs(path, mode=0o700, exist_ok=True)
    return path


def decode_path(raw):
    """A portal `ay` path -> str.

    Anything that is not valid UTF-8 is replaced rather than kept as a
    surrogate: the result has to survive a round trip through JSON, and a path
    Neovim cannot represent is no use to us anyway.
    """
    return bytes(raw).rstrip(b"\0").decode("utf-8", "replace")


def unpack(variant):
    """GVariant -> plain Python, with the portal's byte-string conventions applied.

    `ay` is how the portal spells a filesystem path (NUL-terminated, not
    necessarily UTF-8); left to GLib.Variant.unpack it would come back as a list
    of integers.

    Children are taken with get_child_value rather than by iterating: iteration
    unpacks as it goes and would lose the type information this depends on.
    """
    kind = variant.get_type_string()
    if kind == "v":
        return unpack(variant.get_variant())
    if kind == "ay":
        return decode_path(variant.get_bytestring())
    if kind.startswith("a{"):
        entries = {}
        for index in range(variant.n_children()):
            entry = variant.get_child_value(index)
            entries[unpack(entry.get_child_value(0))] = unpack(entry.get_child_value(1))
        return entries
    if kind.startswith("a") or kind.startswith("("):
        return [unpack(variant.get_child_value(i)) for i in range(variant.n_children())]
    return variant.unpack()


def parse_filter(entry):
    """(sa(us)) -> {name, globs}; `kind` is 0 for a glob, 1 for a mimetype."""
    if not entry or len(entry) < 2:
        return None
    name, patterns = entry[0], entry[1]
    return {
        "name": name,
        "globs": [
            {"kind": pattern[0], "pattern": pattern[1]}
            for pattern in patterns
            if len(pattern) >= 2
        ],
    }


def parse_options(raw):
    """The subset of the FileChooser options the Neovim side knows what to do with."""
    options = {}
    for key in ("multiple", "directory", "modal"):
        if isinstance(raw.get(key), bool):
            options[key] = raw[key]
    for key in ("accept_label", "current_name", "current_folder", "current_file"):
        if isinstance(raw.get(key), str):
            options[key] = raw[key]
    if isinstance(raw.get("files"), list):
        options["files"] = [f for f in raw["files"] if isinstance(f, str)]
    if isinstance(raw.get("filters"), list):
        options["filters"] = [f for f in map(parse_filter, raw["filters"]) if f]
    if raw.get("current_filter"):
        current = parse_filter(raw["current_filter"])
        if current:
            options["current_filter"] = current
    return options


def to_uri(path):
    if not os.path.isabs(path):
        path = os.path.join(GLib.get_home_dir(), path)
    return GLib.filename_to_uri(os.path.normpath(path), None)


class Dialog:
    """One in-flight request: a Neovim process and the D-Bus call it will answer."""

    def __init__(self, handle, method, invocation):
        self.handle = handle
        self.method = method
        self.invocation = invocation
        self.request_file = None
        self.response_file = None
        self.process = None
        self.registration = 0
        self.closed = False

    def cleanup(self):
        for path in (self.request_file, self.response_file):
            if path:
                try:
                    os.unlink(path)
                except OSError:
                    pass

    def answer(self, response, results=None):
        if self.invocation is None:
            return
        invocation, self.invocation = self.invocation, None
        payload = GLib.Variant(
            "(ua{sv})",
            (response, {k: GLib.Variant("as", v) for k, v in (results or {}).items()}),
        )
        invocation.return_value(payload)


class Backend:
    def __init__(self, connection):
        self.connection = connection
        self.filechooser_info = Gio.DBusNodeInfo.new_for_xml(FILECHOOSER_XML).interfaces[0]
        self.request_info = Gio.DBusNodeInfo.new_for_xml(REQUEST_XML).interfaces[0]
        self.dialogs = {}

        connection.register_object_with_closures2(
            OBJECT_PATH,
            self.filechooser_info,
            self.on_method_call,
            self.on_get_property,
            None,
        )

    # NOTE: D-Bus entry points

    def on_get_property(self, _conn, _sender, _path, _iface, name):
        if name == "version":
            return GLib.Variant("u", 3)
        return None

    def on_method_call(self, _conn, _sender, _path, _iface, method, params, invocation):
        if method not in ("OpenFile", "SaveFile", "SaveFiles"):
            invocation.return_error_literal(
                Gio.dbus_error_quark(),
                Gio.DBusError.UNKNOWN_METHOD,
                f"unknown method {method}",
            )
            return
        try:
            handle, app_id, _parent, title, options = unpack(params)
            self.start(handle, method, app_id, title, options, invocation)
        except Exception as err:  # a failed dialog must not take the daemon down
            log(f"{method} failed: {err}")
            invocation.return_value(GLib.Variant("(ua{sv})", (OTHER, {})))

    def on_request_call(self, _conn, _sender, path, _iface, method, _params, invocation):
        """Close() on the request handle: the application gave up on the dialog."""
        if method != "Close":
            invocation.return_error_literal(
                Gio.dbus_error_quark(), Gio.DBusError.UNKNOWN_METHOD, method
            )
            return
        invocation.return_value(None)
        dialog = self.dialogs.get(path)
        if dialog:
            dialog.closed = True
            if dialog.process:
                dialog.process.force_exit()

    # NOTE: Dialog lifecycle

    def start(self, handle, method, app_id, title, raw_options, invocation):
        config = load_config()
        dialog = Dialog(handle, method, invocation)

        directory = runtime_dir()
        stamp = f"{os.getpid()}-{id(dialog):x}"
        dialog.request_file = os.path.join(directory, f"request-{stamp}.json")
        dialog.response_file = os.path.join(directory, f"response-{stamp}.json")

        request = {
            "method": method,
            "app_id": app_id,
            "title": title,
            "handle": handle,
            "response": dialog.response_file,
            "options": parse_options(raw_options),
        }
        with open(os.open(dialog.request_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w", encoding="utf-8") as fh:
            json.dump(request, fh)

        launcher = Gio.SubprocessLauncher.new(Gio.SubprocessFlags.NONE)
        launcher.setenv("OIL_FILECHOOSER_REQUEST", dialog.request_file, True)
        try:
            dialog.process = launcher.spawnv(config["terminal"] + config["editor"])
        except GLib.Error:
            # Nothing will ever read the request file if the terminal is missing.
            dialog.cleanup()
            raise

        # Exporting the Request object is what makes Close() reachable; without
        # it an application that gives up leaves the dialog on screen forever.
        try:
            dialog.registration = self.connection.register_object_with_closures2(
                handle, self.request_info, self.on_request_call, None, None
            )
        except GLib.Error as err:
            log(f"could not export request {handle}: {err}")

        self.dialogs[handle] = dialog
        dialog.process.wait_async(None, self.on_exit, dialog)

    def on_exit(self, process, result, dialog):
        try:
            process.wait_finish(result)
        except GLib.Error as err:
            log(f"editor failed: {err}")

        self.dialogs.pop(dialog.handle, None)
        if dialog.registration:
            self.connection.unregister_object(dialog.registration)

        if dialog.closed:
            dialog.cleanup()
            dialog.answer(OTHER)
            return

        paths = self.read_response(dialog)
        dialog.cleanup()
        if not paths:
            dialog.answer(CANCELLED)
            return
        if dialog.method == "SaveFile":
            paths = paths[:1]
        dialog.answer(SUCCESS, {"uris": [to_uri(p) for p in paths]})

    @staticmethod
    def read_response(dialog):
        try:
            with open(dialog.response_file, encoding="utf-8") as fh:
                payload = json.load(fh)
        except FileNotFoundError:
            return []
        except (OSError, ValueError) as err:
            log(f"unreadable response: {err}")
            return []
        if payload.get("response", SUCCESS) != SUCCESS:
            return []
        return [p for p in payload.get("paths") or [] if isinstance(p, str) and p]


def main():
    loop = GLib.MainLoop()
    connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    Backend(connection)

    def on_lost(_conn, name):
        log(f"lost bus name {name}")
        loop.quit()

    Gio.bus_own_name_on_connection(
        connection,
        BUS_NAME,
        Gio.BusNameOwnerFlags.NONE,
        None,
        on_lost,
    )
    loop.run()


if __name__ == "__main__":
    main()
