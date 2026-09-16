#!/usr/bin/python3
"""Disposable D-Bus service: only emits fixtures, never performs operations."""
import json
import os
from pathlib import Path
import sys
import gi
gi.require_version('Gio', '2.0')
from gi.repository import Gio, GLib

NAME, PATH = 'org.lyraos.Vega1', '/org/lyraos/Vega1'
mode, log_path = sys.argv[1:]
flags = Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION
connection = Gio.DBusConnection.new_for_address_sync(os.environ['DBUS_SYSTEM_BUS_ADDRESS'], flags, None, None)
connection.set_exit_on_close(False)
loop = GLib.MainLoop()
event_interface = NAME + '.Software'
finished_signal = 'TransactionFinished'

def bus(conn, method, signature, values):
    return conn.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                          method, GLib.Variant(signature, values), None, Gio.DBusCallFlags.NONE, 1000, None)

def emit(conn, tx=7, success=True, message='finished', path=PATH):
    conn.emit_signal(None, path, event_interface, finished_signal,
                     GLib.Variant('(ubs)', (tx, success, message)))
    conn.flush_sync(None)

def key(conn, tx, repo):
    conn.emit_signal(None, PATH, NAME + '.Software', 'RepoKeyPending',
                     GLib.Variant('(ussss)', (tx, repo, 'key-id', 'fingerprint', 'signer')))

def called(conn, sender, path, interface, method, parameters, invocation):
    global event_interface, finished_signal
    event_interface = interface
    finished_signal = {'RunBackupNow': 'BackupFinished', 'RestoreSnapshot': 'RestoreFinished'}.get(method, 'TransactionFinished')
    with Path(log_path).open('a') as log:
        log.write(json.dumps({'sender': sender, 'method': method, 'args': parameters.unpack()}) + '\n')
    if mode == 'error':
        invocation.return_dbus_error('org.freedesktop.PolicyKit1.Error.NotAuthorized', 'authorization refused')
        return
    if mode == 'silent-call':
        return
    if mode == 'invalid-reply':
        invocation.return_value(GLib.Variant('(u)', (0,)))
        return
    if mode in ('immediate', 'interleaved', 'key'):
        if mode != 'immediate':
            key(conn, 99, 'other')
            emit(conn, 99, False, 'unrelated failure')
        if mode == 'key':
            key(conn, 7, 'repo')
        emit(conn, 7, mode != 'key', 'own key' if mode == 'key' else 'finished before reply')
    invocation.return_value(GLib.Variant('(u)', (7,)))
    if mode == 'failure':
        emit(conn, 7, False, 'operation failed')
    elif mode == 'delayed':
        emit(conn, 99, False, 'unrelated failure')
        GLib.timeout_add(30, lambda: emit(conn, 7, True, 'own completion'))
    elif mode == 'release':
        bus(conn, 'ReleaseName', '(s)', (NAME,))
    elif mode == 'replace':
        bus(conn, 'ReleaseName', '(s)', (NAME,))
        replacement = Gio.DBusConnection.new_for_address_sync(os.environ['DBUS_SYSTEM_BUS_ADDRESS'], flags, None, None)
        bus(replacement, 'RequestName', '(su)', (NAME, 0))
        emit(replacement, 7, True, 'replacement success')
    elif mode == 'disconnect':
        conn.close_sync(None)
    elif mode == 'forged':
        other = Gio.DBusConnection.new_for_address_sync(os.environ['DBUS_SYSTEM_BUS_ADDRESS'], flags, None, None)
        emit(other, 7, True, 'forged success')
        emit(conn, 7, True, 'wrong path', PATH + '/wrong')
    elif mode == 'flood':
        def flood():
            emit(conn, 99, True, 'unrelated')
            return GLib.SOURCE_CONTINUE
        GLib.timeout_add(5, flood)

xml = '''<node><interface name="org.lyraos.Vega1.Software">
<method name="Start"><arg type="u" direction="out"/></method>
<method name="InstallNvidia"><arg type="b" direction="in"/><arg type="u" direction="out"/></method>
<method name="AddRepo"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="u" direction="out"/></method>
</interface><interface name="org.lyraos.Vega1.Backup">
<method name="RunBackupNow"><arg type="s" direction="in"/><arg type="u" direction="out"/></method>
<method name="RestoreSnapshot"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="u" direction="out"/></method>
</interface></node>'''
info = Gio.DBusNodeInfo.new_for_xml(xml)
for interface in info.interfaces:
    connection.register_object(PATH, interface, called, None, None)
bus(connection, 'RequestName', '(su)', (NAME, 0))
print(connection.get_unique_name(), flush=True)
loop.run()
