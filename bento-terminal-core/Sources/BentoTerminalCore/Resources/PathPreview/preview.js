"use strict";
// File-preview renderer: code (hljs) + markdown (markdown-it). The native
// side calls bentoRender(payload) after the template loads; payload =
// {name, text, line, dark}. Content arrives as a JS value (JSON), never as
// interpolated HTML — everything we inject goes through escaping or
// markdown-it with html:false.

const LANG_BY_EXT = {
  swift: "swift", go: "go", rs: "rust", py: "python", rb: "ruby",
  js: "javascript", jsx: "javascript", mjs: "javascript", cjs: "javascript",
  ts: "typescript", tsx: "typescript", java: "java", kt: "kotlin", kts: "kotlin",
  c: "c", h: "c", cpp: "cpp", cc: "cpp", cxx: "cpp", hpp: "cpp", hh: "cpp",
  m: "objectivec", mm: "objectivec", cs: "csharp", php: "php",
  sh: "bash", bash: "bash", zsh: "bash", json: "json", jsonl: "json",
  yaml: "yaml", yml: "yaml", toml: "ini", ini: "ini", conf: "ini",
  xml: "xml", html: "xml", htm: "xml", svg: "xml", plist: "xml",
  css: "css", scss: "scss", less: "less", sql: "sql", diff: "diff",
  patch: "diff", lua: "lua", pl: "perl", r: "r", scala: "scala",
  dart: "dart", ex: "elixir", exs: "elixir", erl: "erlang",
  ps1: "powershell", tex: "latex", vim: "vim", gradle: "gradle",
  cmake: "cmake", proto: "protobuf", graphql: "graphql", tf: "ini",
  mk: "makefile", entitlements: "xml", strings: "swift", log: "plaintext",
};
const LANG_BY_NAME = {
  makefile: "makefile", gnumakefile: "makefile", dockerfile: "dockerfile",
  cmakelists_txt: "cmake",
};
const MARKDOWN_EXTS = new Set(["md", "markdown", "mdown", "mkd"]);
const HILIGHT_MAX = 200000;   // beyond this, plain text (hljs gets slow)
const AUTO_MAX = 60000;       // auto-detection budget for unknown extensions

function escapeHtml(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function extOf(name) {
  const i = name.lastIndexOf(".");
  return i > 0 ? name.slice(i + 1).toLowerCase() : "";
}

function bentoSetTheme(dark) {
  document.documentElement.dataset.theme = dark ? "dark" : "light";
  document.getElementById("hl-light").disabled = !!dark;
  document.getElementById("hl-dark").disabled = !dark;
}

function highlightedCode(name, text) {
  const lang = LANG_BY_EXT[extOf(name)]
    || LANG_BY_NAME[name.toLowerCase().replace(/\./g, "_")];
  if (text.length <= HILIGHT_MAX && lang && hljs.getLanguage(lang)) {
    try {
      return hljs.highlight(text, { language: lang, ignoreIllegals: true }).value;
    } catch (e) { /* fall through */ }
  }
  if (text.length <= AUTO_MAX && !lang) {
    try {
      const auto = hljs.highlightAuto(text);
      if (auto.relevance >= 5) { return auto.value; }
    } catch (e) { /* fall through */ }
  }
  return escapeHtml(text);
}

function renderCode(root, payload) {
  const html = highlightedCode(payload.name, payload.text);
  const lineCount = payload.text.split("\n").length;
  let gutter = "";
  for (let i = 1; i <= lineCount; i++) { gutter += i + "\n"; }
  root.innerHTML =
    '<div class="code-wrap"><div id="linemark"></div>' +
    '<pre class="gutter">' + gutter + "</pre>" +
    '<pre class="code"><code class="hljs">' + html + "</code></pre></div>";

  if (payload.line && payload.line >= 1 && payload.line <= lineCount) {
    const codeEl = document.querySelector(".code");
    const lh = parseFloat(getComputedStyle(codeEl).lineHeight) || 18;
    const padTop = parseFloat(getComputedStyle(codeEl).paddingTop) || 8;
    const top = padTop + (payload.line - 1) * lh;
    const mark = document.getElementById("linemark");
    mark.style.top = top + "px";
    mark.style.height = lh + "px";
    mark.style.display = "block";
    window.scrollTo(0, Math.max(0, top - window.innerHeight / 3));
  }
}

const md = window.markdownit({
  html: false,          // raw HTML in the file stays inert text
  linkify: true,
  highlight: function (str, lang) {
    if (lang && hljs.getLanguage(lang)) {
      try {
        return hljs.highlight(str, { language: lang, ignoreIllegals: true }).value;
      } catch (e) { /* fall through */ }
    }
    return "";
  },
});
// Remote files can't serve their images (and we never load the network) —
// show a quiet stub with the alt text instead of a broken-image icon.
md.renderer.rules.image = function (tokens, idx) {
  const t = tokens[idx];
  const label = t.content || t.attrGet("src") || "image";
  return '<span class="img-stub">🖼 ' + escapeHtml(label) + "</span>";
};

function renderMarkdown(root, payload) {
  root.innerHTML = '<div class="markdown">' + md.render(payload.text) + "</div>";
}

function bentoRender(payload) {
  bentoSetTheme(payload.dark);
  const root = document.getElementById("root");
  window.scrollTo(0, 0);
  try {
    if (MARKDOWN_EXTS.has(extOf(payload.name))) {
      renderMarkdown(root, payload);
    } else {
      renderCode(root, payload);
    }
  } catch (e) {
    // Never a blank panel: worst case is plain escaped text.
    root.innerHTML = '<pre class="code">' + escapeHtml(payload.text) + "</pre>";
  }
}
