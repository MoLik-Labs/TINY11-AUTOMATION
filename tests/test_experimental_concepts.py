"""Regressions for the independently branded experimental integrations."""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_pico_pins_release_and_architecture_digests_and_does_not_execute():
    script = (ROOT / 'scripts/get-pico-builder.ps1').read_text(encoding='utf-8')
    assert 'winui-v0.2.0' in script
    assert '88f4b958d45b87601b3dbc97c089712a3cedc7820744f980379055de604b5766' in script
    assert '44e7458b2227eb181af3cb6a55e0d103f836a2f0af85178065b235e9f028055f' in script
    assert script.index('Get-FileHash') < script.index('Expand-Archive') < script.index('[IO.Directory]::Move')
    assert "if ($actual -ne $asset.Sha256)" in script
    assert not re.search(r'(?i)\b(Start-Process|Invoke-Expression)\b', script)


def test_flow_shell_controls_and_accessible_focus():
    harness = r'''
const assert = require('assert');
const elements = Object.fromEntries(['window','show','close','clock'].map(id => [id, {
  hidden: false, textContent: '', handlers: {}, focused: false,
  addEventListener(event, handler) { this.handlers[event] = handler; },
  focus() { this.focused = true; }
}]));
global.document = { getElementById: id => elements[id] };
global.setInterval = () => {};
require('./flow-preview/shell.js');
assert(elements.clock.textContent);
elements.close.handlers.click();
assert(elements.window.hidden && elements.show.focused);
elements.show.handlers.click();
assert(!elements.window.hidden && elements.close.focused);
'''
    subprocess.run(['node', '-e', harness], cwd=ROOT, check=True)


def test_flow_describes_its_limits_and_has_local_assets_only():
    html = (ROOT / 'flow-preview/index.html').read_text(encoding='utf-8')
    assert 'does not launch or install applications' in html
    assert 'Not supported by this prototype' in html
    assert 'https://' not in html and 'http://' not in html
    assert 'aria-label="Close compatibility window"' in html
    assert 'aria-label="Open compatibility overview"' in html


def test_flow_about_link_resolves_inside_preview():
    html = (ROOT / 'flow-preview/index.html').read_text(encoding='utf-8')
    assert 'href="about.html"' in html
    about = (ROOT / 'flow-preview/about.html').read_text(encoding='utf-8')
    assert 'cannot install or run' in about
    assert 'href="index.html"' in about
