"""Standalone tmux checks; optionally exercise SSH to an allocated compute node."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]


class Server:
    def __init__(self, user_home=None):
        self.work = Path(tempfile.mkdtemp(prefix='ct-test-'))
        self.socket = self.work / 'tmux.sock'
        self.env = dict(os.environ)
        self.env.pop('TMUX', None)
        self.env.pop('TMUX_PANE', None)
        if user_home:
            self.env['HOME'] = str(user_home)
        self.tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'ct-test', 'sleep 180')
        self.pid = self.tmux('display-message', '-p', '#{pid}')
        self.pane = self.tmux('display-message', '-p', '#{pane_id}')
        self.name = self.tmux('display-message', '-p', '#{host}-#{pid}')
        self.cache = Path(self.env['HOME']) / '.cache/claude-tmux' / self.name
        self.env.update(TMUX=str(self.socket) + ',' + self.pid + ',0', TMUX_PANE=self.pane)

    def tmux(self, *args):
        return subprocess.run(['tmux', '-S', str(self.socket), *args], env=self.env,
                              text=True, capture_output=True, check=True).stdout.strip()

    def hook(self, event, **fields):
        output = subprocess.run([str(REPO / 'bin/claude-tmux-codex')], env=self.env,
                                input=json.dumps(dict(hook_event_name=event, **fields)),
                                text=True, capture_output=True, check=True)
        assert output.stdout == '{}\n', output.stdout

    def state(self):
        return (self.cache / ('pane-' + self.pane.lstrip('%'))).read_text().split('\t')[0]

    def close(self):
        subprocess.run(['tmux', '-S', str(self.socket), 'kill-server'], env=self.env,
                       capture_output=True)
        if self.cache.exists():
            shutil.rmtree(self.cache)
        shutil.rmtree(self.work)


def check_local():
    with tempfile.TemporaryDirectory(prefix='ct-home-') as user_home:
        servers = []
        try:
            first = Server(user_home)
            servers.append(first)
            second = Server(user_home)
            servers.append(second)
            first.hook('SessionStart')
            assert first.state() == 'idle'
            first.hook('UserPromptSubmit')
            assert first.state() == 'running'
            first.hook('PreToolUse', tool_name='request_user_input')
            assert first.state() == 'asking'
            assert '#f7768e' in first.tmux('show-options', '-w', '-v', 'window-status-style')
            assert '#f7768e' in first.tmux('show-options', '-w', '-v', 'window-status-current-style')
            second.hook('UserPromptSubmit')
            assert first.state() == 'asking' and second.state() == 'running'
            for server in servers:
                subprocess.run([str(REPO / 'bin/claude-tmux-status')], env=server.env,
                               text=True, capture_output=True, check=True)
            assert first.state() == 'asking' and second.state() == 'running'
            first.hook('Stop')
            assert first.state() == 'idle'
            first.hook('PreToolUse', tool_name='request_user_input')
            assert first.state() == 'asking'
            first.hook('SessionEnd')
            assert not (first.cache / ('pane-' + first.pane.lstrip('%'))).exists()
            print('PASS: Codex lifecycle, tinting, and separate tmux servers.')
        finally:
            for server in servers:
                server.close()


def check_installer():
    with tempfile.TemporaryDirectory(prefix='ct-install-') as temporary:
        user_home = Path(temporary)
        env = dict(os.environ, HOME=temporary, CODEX_HOME=str(user_home / '.codex'),
                   XDG_CONFIG_HOME=str(user_home / '.config'),
                   XDG_DATA_HOME=str(user_home / '.local/share'), TMUX_TMPDIR=temporary)
        env.pop('TMUX', None)
        env.pop('TMUX_PANE', None)
        sentinel = {'type': 'command', 'command': 'printf unrelated'}
        paths = [user_home / '.claude/settings.json', user_home / '.codex/hooks.json']
        for path in paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({'keep': True, 'hooks': {'Stop': [{'hooks': [sentinel]}]}}))
        subprocess.run(['sh', str(REPO / 'install.sh')], env=env, check=True, capture_output=True)
        first = [json.loads(path.read_text()) for path in paths]
        subprocess.run(['sh', str(REPO / 'install.sh')], env=env, check=True, capture_output=True)
        assert first == [json.loads(path.read_text()) for path in paths]
        assert (user_home / '.local/bin/claude-tmux-ssh').is_file()
        assert (user_home / '.tmux.conf').read_text().count('# >>> claude-tmux >>>') == 1
        subprocess.run(['sh', str(REPO / 'uninstall.sh')], env=env, check=True, capture_output=True)
        for path in paths:
            data = json.loads(path.read_text())
            assert data['keep'] is True
            assert data['hooks']['Stop'] == [{'hooks': [sentinel]}]
        assert not (user_home / '.local/bin/claude-tmux-ssh').exists()
        print('PASS: isolated install/reinstall/uninstall preserves unrelated hooks.')


def check_remote(host):
    server = Server()
    # Shared-home path exercises whitespace, apostrophes, shell metacharacters,
    # and a trailing newline without executing any of the directory name.
    work = Path(tempfile.mkdtemp(prefix='ct-path-', dir=Path.home() / '.cache'))
    directory = work / "a user's $(touch SHOULD_NOT_EXIST) directory\n"
    directory.mkdir()
    try:
        commands = '\n'.join([
            'printf "REMOTE_SERVER="; tmux display-message -p "#{host}-#{pid}"',
            'printf "REMOTE_PANE=%s\\n" "$TMUX_PANE"',
            'printf "REMOTE_SOCKET=%s\\n" "$TMUX"',
            'test "$PWD" = ' + shlex.quote(str(directory)) + ' && printf "DIRECTORY_OK\\n"',
            'printf %s ' + shlex.quote(json.dumps({'hook_event_name': 'PreToolUse', 'tool_name': 'request_user_input'}))
            + ' | ' + shlex.quote(str(REPO / 'bin/claude-tmux-codex')),
            'exit', ''
        ])
        result = subprocess.run([str(REPO / 'bin/claude-tmux-ssh'), host, str(directory)],
                                env=server.env, input=commands, text=True, capture_output=True,
                                timeout=60)
        assert result.returncode == 0, result.stderr
        assert 'REMOTE_SERVER=' + server.name in result.stdout, result.stdout + result.stderr
        assert 'REMOTE_PANE=' + server.pane in result.stdout, result.stdout
        assert 'DIRECTORY_OK' in result.stdout, result.stdout
        assert not (work / 'SHOULD_NOT_EXIST').exists()
        assert server.state() == 'asking'
        assert '#f7768e' in server.tmux('show-options', '-w', '-v', 'window-status-style')
        assert '#f7768e' in server.tmux('show-options', '-w', '-v', 'window-status-current-style')
        remote_socket = next(line.split('=', 1)[1].rsplit(',', 2)[0]
                             for line in result.stdout.splitlines() if line.startswith('REMOTE_SOCKET='))
        subprocess.run(['ssh', '-n', '-o', 'BatchMode=yes', host,
                        'test ! -e ' + shlex.quote(str(Path(remote_socket).parent))], check=True, timeout=20)
        print('PASS: real SSH socket forwarding, remote Codex hook, directory quoting, and cleanup.')
    finally:
        server.close()
        shutil.rmtree(work)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--remote-host', help='exact allocated compute host with shared home; run from login node')
    args = parser.parse_args()
    check_local()
    check_installer()
    if args.remote_host:
        check_remote(args.remote_host)
