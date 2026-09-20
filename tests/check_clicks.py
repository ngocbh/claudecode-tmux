"""Exercise real terminal mouse input on an isolated tmux server."""
import argparse
import fcntl
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time

REPO = Path(__file__).resolve().parents[1]


def check(binary):
    with tempfile.TemporaryDirectory(prefix='ct-click-') as temporary:
        root = Path(temporary)
        (root / 'bin').mkdir()
        (root / 'bin/tmux').symlink_to(Path(binary).resolve())
        config = root / '.config/claude-tmux'
        config.mkdir(parents=True)
        (config / 'config').write_text('CT_CLICKABLE=1\n')
        env = dict(os.environ, HOME=temporary, TERM='xterm-256color',
                   XDG_CONFIG_HOME=str(root / '.config'),
                   CODEX_HOME=str(root / '.codex'), TMUX_TMPDIR=temporary,
                   PATH=str(root / 'bin') + ':' + os.environ['PATH'])
        env.pop('TMUX', None)
        env.pop('TMUX_PANE', None)
        subprocess.run(['sh', str(REPO / 'install.sh')], env=env,
                       check=True, capture_output=True)
        socket = str(root / 'sock')

        def tmux(*args):
            return subprocess.check_output([binary, '-S', socket, *args],
                                           env=env, text=True).strip()

        master = slave = None
        client = None
        try:
            tmux('-f', str(root / '.tmux.conf'), 'new-session', '-d',
                 '-s', 'origin', 'sleep 180')
            tmux('new-window', '-d', '-t', 'origin', '-n', 'second', 'sleep 180')
            tmux('new-session', '-d', '-s', 'target', 'sleep 180')
            target = tmux('display-message', '-p', '-t', 'target', '#{window_id}')
            pane = tmux('display-message', '-p', '-t', 'target', '#{pane_id}')
            writer_env = dict(env, TMUX=socket + ',' + tmux('display-message', '-p', '#{pid}') + ',0',
                              TMUX_PANE=pane)
            subprocess.run([str(root / '.local/bin/claude-tmux-jump'), '--supported'],
                           env=writer_env, check=True)
            subprocess.run([str(root / '.local/bin/claude-tmux-state'), 'running'],
                           env=writer_env, check=True)
            tmux('set', '-g', 'status-left', '')
            tmux('set', '-g', 'status-right', '#(' + str(root / '.local/bin/claude-tmux-status') + ')')
            tmux('set', '-g', 'window-status-format', '#I:#W')
            tmux('set', '-g', 'window-status-current-format', '#I:#W')
            tmux('set', '-g', 'status-justify', 'left')
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 120, 0, 0))

            def terminal():
                os.setsid()
                fcntl.ioctl(0, termios.TIOCSCTTY, 0)

            client = subprocess.Popen([binary, '-S', socket, 'attach', '-t', 'origin'],
                                      env=env, stdin=slave, stdout=slave, stderr=slave,
                                      preexec_fn=terminal)

            def drain(seconds):
                output = b''
                end = time.monotonic() + seconds
                while time.monotonic() < end:
                    if select.select([master], [], [], min(0.05, end-time.monotonic()))[0]:
                        output += os.read(master, 65536)
                return output

            screen = drain(2)
            assert b'target' in screen, repr(screen[-1000:])

            def click(x):
                # SGR mouse coordinates are one-based, on the bottom status row.
                os.write(master, ('\x1b[<0;{};24M\x1b[<0;{};24m'.format(x, x)).encode())
                drain(0.5)

            # The target chip occupies the rightmost 13 columns including spaces/separator.
            click(112)
            actual = tmux('list-clients', '-F', '#{session_name}')
            assert actual == 'target', 'chip click left client in ' + actual
            assert tmux('display-message', '-p', '-t', 'target', '#{window_id}') == target
            tmux('switch-client', '-t', 'origin')
            drain(0.5)
            click(11)  # The second normal window tab must still be clickable.
            assert tmux('display-message', '-p', '-t', 'origin', '#{window_name}') == 'second'
            print('PASS: actual chip click switches sessions; normal window-tab click still works (' + tmux('display-message', '-p', '#{version}') + ').')
        finally:
            subprocess.run([binary, '-S', socket, 'kill-server'], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if client:
                client.wait(timeout=5)
            for fd in (master, slave):
                if fd is not None:
                    os.close(fd)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tmux', help='absolute path to tmux executable')
    check(parser.parse_args().tmux)
