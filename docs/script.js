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
      // HTML 포함할 수 있게 innerHTML 사용. 신뢰된 JSON이므로 XSS 이슈 없음.
      el.innerHTML = value;
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
