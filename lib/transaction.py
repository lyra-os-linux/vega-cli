#!/usr/bin/python3
"""One Vega transaction on one D-Bus connection; no polling or mutation retry."""
import argparse
from collections import deque
import json
import math
import re
import signal
import sys
import time

import gi
gi.require_version('Gio', '2.0')
from gi.repository import Gio, GLib

NAME = 'org.lyraos.Vega1'
PATH = '/org/lyraos/Vega1'
BUS = 'org.freedesktop.DBus'
BUS_PATH = '/org/freedesktop/DBus'


class Transaction:
    def __init__(self, connection, interface, method, finished, parameters,
                 timeout=900, call_timeout=30):
        self.connection = connection
        self.interface = f'{NAME}.{interface}'
        self.method, self.finished, self.parameters = method, finished, parameters
        self.deadline = time.monotonic() + timeout
        self.call_timeout = call_timeout
        self.owner = None
        self.tx_id = None
        self.result = None
        self.early = deque()
        self.key_pending = None
        self.loop = GLib.MainLoop()
        self.cancel = Gio.Cancellable()
        self.subscriptions = []
        self.sources = []

    def milliseconds(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Tempo esgotado; resultado da transação não confirmado.')
        return max(1, math.ceil(min(remaining, self.call_timeout) * 1000))

    def bus_call(self, method, parameters, reply_type):
        return self.connection.call_sync(BUS, BUS_PATH, BUS, method, parameters,
                                         GLib.VariantType.new(reply_type),
                                         Gio.DBusCallFlags.NONE, self.milliseconds(), self.cancel)

    def subscribe(self, sender, interface, member, path, arg0, callback):
        self.subscriptions.append(self.connection.signal_subscribe(
            sender, interface, member, path, arg0, Gio.DBusSignalFlags.NO_MATCH_RULE,
            callback, None))
        fields = dict(type='signal', sender=sender, interface=interface, member=member, path=path)
        if arg0 is not None:
            fields['arg0'] = arg0
        rule = ','.join(f"{key}='{value}'" for key, value in fields.items())
        # NO_MATCH_RULE above installs the local handler first. The explicit,
        # synchronous AddMatch reply is the broker handshake before any mutation.
        self.bus_call('AddMatch', GLib.Variant('(s)', (rule,)), '()')

    def finish(self, success, message, key_pending=None):
        if self.result is None:
            self.result = dict(success=success, message=message,
                               transaction_id=self.tx_id, key_pending=key_pending)
            self.cancel.cancel()
            self.loop.quit()
        return GLib.SOURCE_REMOVE

    def owner_changed(self, _conn, _sender, _path, _iface, _signal, parameters, _data):
        name, old, new = parameters.unpack()
        if name == NAME and self.owner and old == self.owner and new != self.owner:
            self.finish(False, 'O vegad foi reiniciado ou perdeu o nome D-Bus; resultado não confirmado. Não repita a operação automaticamente.')

    def event(self, _conn, sender, path, interface, member, parameters, _data):
        if self.result is not None:
            return
        if time.monotonic() >= self.deadline:
            self.finish(False, 'Tempo esgotado; resultado da transação não confirmado.')
            return
        if (sender, path, interface) != (self.owner, PATH, self.interface):
            return
        expected = '(ussss)' if member == 'RepoKeyPending' else '(ubs)'
        if parameters.get_type_string() != expected:
            self.finish(False, 'Sinal de transação inválido recebido do vegad.')
            return
        event = (member, parameters.unpack())
        if self.tx_id is None:
            if len(self.early) >= 256:
                self.finish(False, 'Excesso de sinais antes da resposta do vegad; resultado não confirmado.')
            else:
                self.early.append(event)
        else:
            self.consume(*event)

    def consume(self, member, values):
        if values[0] != self.tx_id:
            return
        if member == 'RepoKeyPending':
            self.key_pending = list(values[1:])
        else:
            success, message = values[1:]
            self.finish(success, message or ('' if success else 'A transação falhou sem detalhes do vegad.'),
                        self.key_pending if not success else None)

    def called(self, connection, result, _data):
        try:
            reply = connection.call_finish(result)
            if self.result is not None:
                return
            self.milliseconds()
            self.tx_id = reply.unpack()[0]
            if self.tx_id == 0:
                raise ValueError('ID de transação inválido recebido do vegad.')
            while self.early and self.result is None:
                self.consume(*self.early.popleft())
        except Exception as error:
            self.finish(False, str(error))

    def run(self):
        try:
            self.connection.set_exit_on_close(False)
            self.connection.connect('closed', lambda *_: self.finish(
                False, 'Conexão D-Bus encerrada; resultado da transação não confirmado.'))
            self.subscribe(BUS, BUS, 'NameOwnerChanged', BUS_PATH, NAME, self.owner_changed)
            try:
                self.owner = self.bus_call('GetNameOwner', GLib.Variant('(s)', (NAME,)), '(s)').unpack()[0]
            except GLib.Error as error:
                if Gio.DBusError.get_remote_error(error) != 'org.freedesktop.DBus.Error.NameHasNoOwner':
                    raise
                self.bus_call('StartServiceByName', GLib.Variant('(su)', (NAME, 0)), '(u)')
                self.owner = self.bus_call('GetNameOwner', GLib.Variant('(s)', (NAME,)), '(s)').unpack()[0]
            self.subscribe(self.owner, self.interface, self.finished, PATH, None, self.event)
            if self.interface == f'{NAME}.Software' and self.method == 'AddRepo':
                self.subscribe(self.owner, self.interface, 'RepoKeyPending', PATH, None, self.event)
            owner = self.bus_call('GetNameOwner', GLib.Variant('(s)', (NAME,)), '(s)').unpack()[0]
            # Dispatch queued ownership changes before sending the method.
            context = GLib.MainContext.default()
            while context.pending() and self.result is None:
                context.iteration(False)
                self.milliseconds()
            if owner != self.owner:
                raise RuntimeError('O proprietário do vegad mudou antes da chamada.')
            if self.result is not None:
                return self.result
            self.sources.append(GLib.timeout_add(max(1, math.ceil((self.deadline - time.monotonic()) * 1000)),
                                                 self.finish, False, 'Tempo esgotado; resultado da transação não confirmado.'))
            for signum in (signal.SIGINT, signal.SIGTERM):
                self.sources.append(GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signum, lambda *_: self.finish(
                                                        False, 'Espera interrompida; resultado da transação não confirmado.')))
            self.connection.call(self.owner, PATH, self.interface, self.method, self.parameters,
                                 GLib.VariantType.new('(u)'), Gio.DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION,
                                 self.milliseconds(), self.cancel, self.called, None)
            self.loop.run()
        except Exception as error:
            self.finish(False, str(error))
        finally:
            self.cancel.cancel()
            for subscription in self.subscriptions:
                self.connection.signal_unsubscribe(subscription)
            for source in self.sources:
                if GLib.MainContext.default().find_source_by_id(source):
                    GLib.source_remove(source)
            # Dedicated connection: closing removes all match rules even if a
            # setup call failed. There is no detached listener to outlive us.
            if not self.connection.is_closed():
                self.connection.close_sync(None)
        return self.result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=float, default=900)
    parser.add_argument('--call-timeout', type=float, default=30)
    parser.add_argument('interface')
    parser.add_argument('method')
    parser.add_argument('finished')
    parser.add_argument('signature', nargs='?', default='')
    parser.add_argument('arguments', nargs='*')
    args = parser.parse_args()
    try:
        for name in (args.interface, args.method, args.finished):
            if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', name):
                raise ValueError('Nome de método/interface/sinal inválido.')
        for value in (args.timeout, args.call_timeout):
            if not math.isfinite(value) or not 0 < value <= 86400:
                raise ValueError('Timeout inválido.')
        # Current CLI transaction methods take only string arguments (or none).
        # Reject other signatures before connecting, never interpret shell data.
        if args.signature != 's' * len(args.arguments):
            raise ValueError('Assinatura de transação não suportada.')
        parameters = GLib.Variant(f'({args.signature})', tuple(args.arguments))
        address = Gio.dbus_address_get_for_bus_sync(Gio.BusType.SYSTEM, None)
        connection = Gio.DBusConnection.new_for_address_sync(
            address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
            None, None)
        result = Transaction(connection, args.interface, args.method, args.finished,
                             parameters, args.timeout, args.call_timeout).run()
    except Exception as error:
        result = dict(success=False, message=str(error), key_pending=None, transaction_id=None)
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result['success'] else 1


if __name__ == '__main__':
    sys.exit(main())
