#!/usr/bin/env python3
"""Send a FileChooser request, the way a real application would.

    tests/request.py open --multiple --filter '*.png' --folder ~/Pictures
    tests/request.py save --name notes.md
    tests/request.py save-files a.txt b.txt
    tests/request.py --portal open        # through xdg-desktop-portal, end to end

`gdbus call` is not a substitute for this: its command line parser mangles a
bytestring inside a variant (`<b'/some/path'>` arrives as pointer garbage), and
`current_folder` is exactly that type.
"""

import argparse
import os
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

BACKEND = (
    "org.freedesktop.impl.portal.desktop.oil-filechooser",
    "/org/freedesktop/portal/desktop",
    "org.freedesktop.impl.portal.FileChooser",
)
FRONTEND = (
    "org.freedesktop.portal.Desktop",
    "/org/freedesktop/portal/desktop",
    "org.freedesktop.portal.FileChooser",
)


def variant_dict(pairs):
    builder = GLib.VariantBuilder.new(GLib.VariantType.new("a{sv}"))
    for key, value in pairs:
        entry = GLib.VariantBuilder.new(GLib.VariantType.new("{sv}"))
        entry.add_value(GLib.Variant("s", key))
        entry.add_value(GLib.Variant.new_variant(value))
        builder.add_value(entry.end())
    return builder.end()


def build_options(args):
    options = []
    if args.multiple:
        options.append(("multiple", GLib.Variant("b", True)))
    if args.directory:
        options.append(("directory", GLib.Variant("b", True)))
    if args.folder:
        path = os.path.abspath(os.path.expanduser(args.folder))
        options.append(("current_folder", GLib.Variant.new_bytestring(os.fsencode(path) + b"\0")))
    if args.name:
        options.append(("current_name", GLib.Variant("s", args.name)))
    if args.filter:
        globs = [(0, pattern) for pattern in args.filter]
        options.append(("filters", GLib.Variant("a(sa(us))", [("Test filter", globs)])))
    if args.files:
        options.append(("files", GLib.Variant.new_bytestring_array(args.files)))
    return variant_dict(options)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("method", choices=["open", "save", "save-files"])
    parser.add_argument("files", nargs="*", help="names for save-files")
    parser.add_argument("--portal", action="store_true", help="go through xdg-desktop-portal")
    parser.add_argument("--multiple", action="store_true")
    parser.add_argument("--directory", action="store_true")
    parser.add_argument("--folder")
    parser.add_argument("--name")
    parser.add_argument("--filter", action="append")
    args = parser.parse_args()

    method = {"open": "OpenFile", "save": "SaveFile", "save-files": "SaveFiles"}[args.method]
    options = build_options(args)
    connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)

    if args.portal:
        name, path, iface = FRONTEND
        params = GLib.Variant.new_tuple(GLib.Variant("s", ""), GLib.Variant("s", "Test"), options)
    else:
        name, path, iface = BACKEND
        params = GLib.Variant.new_tuple(
            GLib.Variant("o", "/org/freedesktop/portal/desktop/request/test/1"),
            GLib.Variant("s", "org.test.App"),
            GLib.Variant("s", ""),
            GLib.Variant("s", "Test"),
            options,
        )

    result = connection.call_sync(name, path, iface, method, params, None, 0, GLib.MAXINT, None)

    if not args.portal:
        response, results = result.unpack()
        print(f"response={response} {results}")
        return 0 if response == 0 else 1

    # The frontend answers immediately with a handle and signals the result.
    handle = result.unpack()[0]
    loop = GLib.MainLoop()
    state = {}

    def on_response(_conn, _sender, _path, _iface, _signal, params):
        state["response"], state["results"] = params.unpack()
        loop.quit()

    connection.signal_subscribe(
        "org.freedesktop.portal.Desktop",
        "org.freedesktop.portal.Request",
        "Response",
        handle,
        None,
        Gio.DBusSignalFlags.NONE,
        on_response,
    )
    loop.run()
    print(f"response={state['response']} {state['results']}")
    return 0 if state["response"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
