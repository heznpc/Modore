"""GitHub Pages 랜딩(docs/)의 접근성 계약 테스트.

리포트 생성기와 달리 정적 파일이므로 직접 파싱해 WCAG 관련 불변식을 강제한다.
수정 전 코드에서는 실패하고, 접근성 수정이 통과시킨다.
"""
import re
from pathlib import Path

import pytest

DOCS = Path(__file__).resolve().parent.parent / "docs"


@pytest.fixture(scope="module")
def index_html() -> str:
    return (DOCS / "index.html").read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def style_css() -> str:
    return (DOCS / "style.css").read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def script_js() -> str:
    return (DOCS / "script.js").read_text(encoding="utf-8")


def test_exactly_one_main_landmark(index_html):
    assert len(re.findall(r"<main\b", index_html)) == 1


def test_skip_link_is_first_focusable(index_html):
    body = index_html.split("<body>", 1)[1]
    first = re.search(r"<(a|button)\b[^>]*>", body, re.IGNORECASE)
    assert first is not None
    tag = first.group(0)
    assert 'class="skip-link"' in tag and 'href="#' in tag


def test_language_buttons_expose_pressed_state(index_html, script_js):
    lang_buttons = re.findall(r'<button class="lang-btn[^"]*"[^>]*>', index_html)
    assert lang_buttons, "language buttons not found"
    assert all("aria-pressed=" in b for b in lang_buttons)
    # The switcher must keep aria-pressed in sync, not just the CSS class.
    assert "aria-pressed" in script_js


def test_reduced_motion_gates_the_animations(style_css):
    assert "prefers-reduced-motion" in style_css
    block = re.search(
        r"@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{(.+?)\}\s*\}",
        style_css,
        re.DOTALL,
    )
    assert block is not None, "reduced-motion media query missing"
    body = block.group(1)
    assert ".pulse" in body and ".ticker-track" in body
    assert "animation: none" in body


def test_focus_visible_styles_present(style_css):
    assert ":focus-visible" in style_css


def _luminance(hex6: str) -> float:
    r, g, b = (int(hex6[i:i + 2], 16) / 255 for i in (0, 2, 4))

    def lin(c: float) -> float:
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

    r, g, b = lin(r), lin(g), lin(b)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def _contrast(a: str, b: str) -> float:
    la, lb = _luminance(a), _luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def _css_var(css: str, name: str) -> str:
    match = re.search(rf"{re.escape(name)}:\s*#([0-9a-fA-F]{{6}})", css)
    assert match is not None, f"{name} not found"
    return match.group(1).lower()


def test_subtle_text_meets_aa_contrast(style_css):
    subtle = _css_var(style_css, "--text-subtle")
    bg = _css_var(style_css, "--bg")
    ratio = _contrast(subtle, bg)
    assert ratio >= 4.5, f"--text-subtle on --bg is {ratio:.2f}:1 (< 4.5 AA)"
