/**
 * PC 건강검진 - 랜딩 페이지 i18n 로더
 *
 * 동작:
 *  1. URL ?lang=XX 있으면 그걸로
 *  2. 없으면 localStorage에 저장된 선호
 *  3. 없으면 navigator.language 추론
 *  4. 그것도 실패하면 기본값(ko)
 *
 * 번역 추가 방법:
 *  docs/i18n/<code>.json 파일 만들고 SUPPORTED에 추가만 하면 됨.
 */

const SUPPORTED = ['ko', 'en', 'ja'];
const DEFAULT_LANG = 'ko';
const STORAGE_KEY = 'pch.lang';

// ----- 언어 결정 -----
function detectLanguage() {
  // 1. URL 파라미터
  const urlParams = new URLSearchParams(window.location.search);
  const fromUrl = urlParams.get('lang');
  if (fromUrl && SUPPORTED.includes(fromUrl)) return fromUrl;

  // 2. localStorage
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored && SUPPORTED.includes(stored)) return stored;
  } catch (e) { /* Safari 프라이빗 모드 등 */ }

  // 3. 브라우저 언어
  const browserLang = (navigator.language || navigator.userLanguage || '').toLowerCase();
  for (const code of SUPPORTED) {
    if (browserLang.startsWith(code)) return code;
  }

  // 4. 기본
  return DEFAULT_LANG;
}

// ----- 번역 로드 -----
async function loadTranslations(lang) {
  try {
    const res = await fetch(`i18n/${lang}.json`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.json();
  } catch (e) {
    console.error(`번역 로드 실패 (${lang}):`, e);
    if (lang !== DEFAULT_LANG) {
      return loadTranslations(DEFAULT_LANG); // fallback
    }
    return {};
  }
}

// ----- 점 표기법으로 중첩 객체 조회 ("hero.title" → obj.hero.title) -----
function getNested(obj, path) {
  return path.split('.').reduce((acc, key) => acc?.[key], obj);
}

// ----- HTML sanitizer (allowlist 기반) -----
// 번역 JSON은 레포 owner가 머지하지만, 커뮤니티 PR을 받는 경로이므로
// defense-in-depth로 클라이언트 측 필터를 둠.
//  - 허용 태그: 타이포그래피용 인라인 요소만
//  - 허용 속성: A의 href/target/rel, SPAN의 class, 그 외 모두 제거
//  - 위험 URL 스킴(javascript:, data:, vbscript:) 제거
//  - target="_blank"인 A에는 rel="noopener noreferrer" 강제
const ALLOWED_TAGS = new Set(['EM', 'STRONG', 'CODE', 'A', 'SPAN', 'BR']);
const ALLOWED_ATTRS = {
  A: ['href', 'target', 'rel'],
  SPAN: ['class'],
};
const DANGEROUS_URL = /^\s*(javascript|data|vbscript):/i;

function sanitizeHTML(input) {
  // <template>은 파싱하더라도 <script>를 실행하지 않으므로 안전한 파싱 컨테이너.
  const tmpl = document.createElement('template');
  tmpl.innerHTML = String(input);

  function walk(node) {
    // 역순 순회: removeChild가 인덱스를 무효화하지 않도록.
    for (let i = node.childNodes.length - 1; i >= 0; i--) {
      const child = node.childNodes[i];
      if (child.nodeType === Node.ELEMENT_NODE) {
        if (!ALLOWED_TAGS.has(child.tagName)) {
          node.replaceChild(document.createTextNode(child.textContent || ''), child);
          continue;
        }
        const allowed = ALLOWED_ATTRS[child.tagName] || [];
        for (let j = child.attributes.length - 1; j >= 0; j--) {
          const attr = child.attributes[j];
          if (!allowed.includes(attr.name)) {
            child.removeAttribute(attr.name);
            continue;
          }
          if (attr.name === 'href' && DANGEROUS_URL.test(attr.value)) {
            child.removeAttribute('href');
          }
        }
        // target=_blank + 외부 링크 → opener를 통한 tabnabbing 방지.
        if (child.tagName === 'A' && child.getAttribute('target') === '_blank') {
          child.setAttribute('rel', 'noopener noreferrer');
        }
        // TODO(2nd-pass-audit-2026-05-21): target 없는 외부 링크에는 rel noopener
        // 강제 안 함. 같은 탭 이동이라 tabnabbing 위험은 낮지만, 차후 일관성
        // 차원에서 모든 cross-origin <a>에 rel 보강 검토.
        walk(child);
      } else if (child.nodeType !== Node.TEXT_NODE) {
        // 코멘트 노드 등을 통한 조건부 컴파일/HTML 파서 트릭 차단.
        node.removeChild(child);
      }
    }
  }

  walk(tmpl.content);
  return tmpl.innerHTML;
}

// ----- DOM 적용 -----
function applyTranslations(translations) {
  // 텍스트 노드
  document.querySelectorAll('[data-i18n]').forEach(el => {
    const key = el.getAttribute('data-i18n');
    const value = getNested(translations, key);
    if (typeof value !== 'string') return;

    // <title>, <meta>는 content / innerText 다름
    if (el.tagName === 'META') {
      el.setAttribute('content', value);
    } else if (el.tagName === 'TITLE') {
      el.textContent = value;
      document.title = value;
    } else {
      // 번역 문자열은 allowlist sanitizer를 통과시킨 뒤 innerHTML 주입.
      // 허용 태그 외(script/iframe/img/on*=/javascript:)는 제거됨.
      el.innerHTML = sanitizeHTML(value);
    }
  });

  // placeholder, title, alt 속성 지원 (data-i18n-attr="placeholder:hero.placeholder,title:x.y")
  document.querySelectorAll('[data-i18n-attr]').forEach(el => {
    const spec = el.getAttribute('data-i18n-attr');
    spec.split(',').forEach(pair => {
      const [attr, key] = pair.split(':').map(s => s.trim());
      const value = getNested(translations, key);
      if (typeof value === 'string') {
        el.setAttribute(attr, value);
      }
    });
  });
}

// ----- 언어 전환 -----
async function switchLanguage(lang) {
  if (!SUPPORTED.includes(lang)) return;

  const translations = await loadTranslations(lang);
  applyTranslations(translations);

  document.documentElement.lang = lang;

  try {
    localStorage.setItem(STORAGE_KEY, lang);
  } catch (e) { /* 프라이빗 모드 */ }

  // 버튼 활성화 상태 업데이트
  document.querySelectorAll('.lang-btn').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.lang === lang);
  });

  // URL 업데이트 (히스토리 쌓지 않게 replaceState)
  const url = new URL(window.location);
  url.searchParams.set('lang', lang);
  window.history.replaceState({}, '', url);
}

// ----- 초기화 -----
document.addEventListener('DOMContentLoaded', () => {
  const initialLang = detectLanguage();
  switchLanguage(initialLang);

  // 언어 버튼 클릭 이벤트
  document.querySelectorAll('.lang-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      switchLanguage(btn.dataset.lang);
    });
  });
});
