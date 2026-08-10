/* ff-runcard.js — canonical run-card / run-header renderer (ADR-019).

   Plain ES5, no modules/imports: this file is never loaded at runtime by
   either host. It is copied VERBATIM, byte-for-byte, into two places —
   ff-dashboard.html's <script> (surface:"dashboard") and the chat widget
   ff-widget.sh emits (surface:"chat") — between "ff-runcard:begin" and
   "ff-runcard:end" marker comments. A test byte-compares both copies against
   this file; touching one without the other fails the build. Only two
   globals are defined: `ffRunCard` and `FF_RUNCARD_CSS`. No event handlers,
   no fetch, no localStorage, no Date.now/clock reads — every value the
   render needs (including any "how stale is this" age) is precomputed and
   passed IN via runDoc, because the module renders state, never behaviour.

   WIRE FORMAT — runDoc:
   {
     run: string,                  // run id/name (title)
     repo: string,                 // repo path (path line)
     repo_label: string,           // short label — not rendered by this
                                    // module; carried through for the host's
                                    // own breadcrumb/chrome around the card.
     orchestrator: string|falsy,   // orchestrator model id; falsy renders the
                                    // dashed "orchestrator unrecorded" badge
                                    // rather than guessing (see orchBadge).
     waves: array|undefined,       // non-empty => "wave" badge shown
     summary: {
       state: "running"|"stalled"|"failed"|"done"|other,
       idle_s: number,             // FINAL — caller has already folded any
                                    // live "how long since last activity"
                                    // age into this; only used when state is
                                    // "stalled".
       elapsed_s: number,          // FINAL likewise — already includes live
                                    // age for in-flight runs.
       counts: { running?, stalled?, failed?, ... },
       lane_count: number,
       tokens_total: number,
       tokens_out: number,
       models: string[],           // brand chip list + chart legend
       model_ids: string[],        // "lanes ran …" line
     },
     lanes: [{ id, model, model_id, state, tokens_total }],
                                    // one pip + one chart bar per lane
     cost: { display: string, title: string } | undefined,
                                    // PRE-FORMATTED by the caller (≈/* cost
                                    // honesty markers, any currency
                                    // conversion — the module never touches
                                    // money, only prints what it is given).
                                    // Omit to render "—" with no title.
   }

   opts: { surface: "dashboard" | "chat" }
     Selects nothing in the JS — it only stamps `data-surface` on the root
     element so the HOST's own CSS can map the `--ffc-*` custom properties
     this module's rules read to that host's real palette. Without a host
     mapping the light/dark fallbacks baked into FF_RUNCARD_CSS below (the
     dashboard's own current colours) still render correctly on their own.
*/
var ffRunCard, FF_RUNCARD_CSS;
(function () {
  "use strict";

  function esc(t) {
    if (t === null || t === undefined) t = "";
    return String(t).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;" }[c];
    });
  }

  function tok(n) {
    if (!n) return "—";
    if (n >= 1e9) return (n / 1e9).toFixed(2) + "B";
    if (n >= 1e6) return (n / 1e6).toFixed(1) + "M";
    if (n >= 1e3) return (n / 1e3).toFixed(1) + "k";
    return String(n);
  }

  function pad2(n) { n = String(n); return n.length < 2 ? "0" + n : n; }

  function fmt(s) {
    if (s === null || s === undefined) return "—";
    if (s >= 86400) return Math.floor(s / 86400) + "d" + pad2(Math.floor((s % 86400) / 3600)) + "h";
    if (s >= 3600) return Math.floor(s / 3600) + "h" + pad2(Math.floor((s % 3600) / 60)) + "m";
    if (s >= 60) return Math.floor(s / 60) + "m" + pad2(s % 60) + "s";
    return s + "s";
  }

  var DARK = window.matchMedia("(prefers-color-scheme: dark)");

  /* Per-model identity (letter + light colour + dark colour). Own copy of
     the dashboard's MODEL_HUES/BRAND tables — this module is embedded into
     hosts (the chat widget) that have no other copy to borrow from, so it
     cannot reference the dashboard's globals even when it happens to run
     alongside them. Keep in step with ff-dashboard.html's MODEL_HUES/BRAND
     by hand; a future shared-registry extraction is out of scope for this
     ADR (ADR-019 only unifies the RENDERER, not the data tables). */
  var MODEL_HUES = {
    glm:   ["G", "#7f77dd", "#9d95f0"], codex: ["C", "#0f6e56", "#2fb894"],
    sonnet:["S", "#d85a30", "#ef7f52"], opus:  ["O", "#ba7517", "#dfa03c"],
    haiku: ["H", "#d4537e", "#ec7ba0"], fable: ["F", "#378add", "#6bb0ef"],
    grok:  ["X", "#534ab7", "#8a80e8"], native:["N", "#6a8caf", "#90b0d0"],
    pi:    ["P", "#1f8a9c", "#4fc3d9"]
  };

  function modelOf(b) {
    var e = MODEL_HUES[b] || ["?", "#888780", "#a3a199"];
    return [e[0], DARK.matches ? e[2] : e[1]];
  }

  var BRAND = {
    openai: ["0 0 256 260", '<path d="M239.184 106.203a64.716 64.716 0 0 0-5.576-53.103C219.452 28.459 191 15.784 163.213 21.74A65.586 65.586 0 0 0 52.096 45.22a64.716 64.716 0 0 0-43.23 31.36c-14.31 24.602-11.061 55.634 8.033 76.74a64.665 64.665 0 0 0 5.525 53.102c14.174 24.65 42.644 37.324 70.446 31.36a64.72 64.72 0 0 0 48.754 21.744c28.481.025 53.714-18.361 62.414-45.481a64.767 64.767 0 0 0 43.229-31.36c14.137-24.558 10.875-55.423-8.083-76.483Zm-97.56 136.338a48.397 48.397 0 0 1-31.105-11.255l1.535-.87 51.67-29.825a8.595 8.595 0 0 0 4.247-7.367v-72.85l21.845 12.636c.218.111.37.32.409.563v60.367c-.056 26.818-21.783 48.545-48.601 48.601Zm-104.466-44.61a48.345 48.345 0 0 1-5.781-32.589l1.534.921 51.722 29.826a8.339 8.339 0 0 0 8.441 0l63.181-36.425v25.221a.87.87 0 0 1-.358.665l-52.335 30.184c-23.257 13.398-52.97 5.431-66.404-17.803ZM23.549 85.38a48.499 48.499 0 0 1 25.58-21.333v61.39a8.288 8.288 0 0 0 4.195 7.316l62.874 36.272-21.845 12.636a.819.819 0 0 1-.767 0L41.353 151.53c-23.211-13.454-31.171-43.144-17.804-66.405v.256Zm179.466 41.695-63.08-36.63L161.73 77.86a.819.819 0 0 1 .768 0l52.233 30.184a48.6 48.6 0 0 1-7.316 87.635v-61.391a8.544 8.544 0 0 0-4.4-7.213Zm21.742-32.69-1.535-.922-51.619-30.081a8.39 8.39 0 0 0-8.492 0L99.98 99.808V74.587a.716.716 0 0 1 .307-.665l52.233-30.133a48.652 48.652 0 0 1 72.236 50.391v.205ZM88.061 139.097l-21.845-12.585a.87.87 0 0 1-.41-.614V65.685a48.652 48.652 0 0 1 79.757-37.346l-1.535.87-51.67 29.825a8.595 8.595 0 0 0-4.246 7.367l-.051 72.697Zm11.868-25.58 28.138-16.217 28.188 16.218v32.434l-28.086 16.218-28.188-16.218-.052-32.434Z"/>'],
    claude: ["0 0 24 24", '<path d="m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"/>'],
    chatglm: ["0 0 24 24", '<path d="M9.917 2c4.906 0 10.178 3.947 8.93 10.58-.014.07-.037.14-.057.21l-.003-.277c-.083-3-1.534-8.934-8.87-8.934-3.393 0-8.137 3.054-7.93 8.158-.04 4.778 3.555 8.4 7.95 8.332l.073-.001c1.2-.033 2.763-.429 3.1-1.657.063-.031.26.534.268.598.048.256.112.369.192.34.981-.348 2.286-1.222 1.952-2.38-.176-.61-1.775-.147-1.921-.347.418-.979 2.234-.926 3.153-.716.443.102.657.38 1.012.442.29.052.981-.2.96.242C17.226 19.632 13.833 22 9.918 22 3.654 22 0 16.574 0 11.737 0 5.947 4.959 2 9.917 2zM9.9 5.3c.484 0 1.125.225 1.38.585 3.669.145 4.313 2.686 4.694 5.444.255 1.838.315 2.3.182 1.387l.083.59c.068.448.554.737.982.516.144-.075.254-.231.328-.47a.2.2 0 01.258-.13l.625.22a.2.2 0 01.124.238 2.172 2.172 0 01-.51.92c-.878.917-2.757.664-3.08-.62-.14-.554-.055-.626-.345-1.242-.292-.621-1.238-.709-1.69-.295-.345.315-.407.805-.406 1.282L12.6 15.9a.9.9 0 01-.9.9h-1.4a.9.9 0 01-.9-.9v-.65a1.15 1.15 0 10-2.3 0v.65a.9.9 0 01-.9.9H4.8a.9.9 0 01-.9-.9l.035-3.239c.012-1.884.356-3.658 2.47-4.134.2-.045.252.13.29.342.025.154.043.252.053.294.701 3.058 1.75 4.299 3.144 3.722l.66-.331.254-.13c.158-.082.25-.131.276-.15.012-.01-.165-.206-.407-.464l-1.012-1.067a8.925 8.925 0 01-.199-.216c-.047-.034-.116.068-.208.306-.074.157-.251.252-.272.326-.013.058.108.298.362.72.164.288.22.508-.31.343-1.04-.8-1.518-2.273-1.684-3.725-.004-.035-.162-1.913-.162-1.913a1.2 1.2 0 011.113-1.281L9.9 5.3zm12.994 8.68c.037.697-.403.704-1.213.591l-1.783-.276c-.265-.053-.385-.099-.313-.147.47-.315 3.268-.93 3.31-.168zm-.915-.083l-.926.042c-.85.077-1.452.24.338.336l.103.003c.815.012 1.264-.359.485-.381zm1.667-3.601h.01c.79.398.067 1.03-.65 1.393-.14.07-.491.176-1.052.315-.241.04-.457.092-.333.16l.01.005c1.952.958-3.123 1.534-2.495 1.285l.38-.148c.68-.266 1.614-.682 1.666-1.337.038-.48 1.253-.442 1.493-.968.048-.106 0-.236-.144-.389-.05-.047-.094-.094-.107-.148-.073-.305.7-.431 1.222-.168zm-2.568-.474c-.135 1.198-2.479 4.192-1.949 2.863l.017-.042c.298-.717.376-2.221 1.337-3.221.25-.26.636.035.595.4zm-7.976-.253c.02-.694 1.002-.968 1.346-.347.01-1.274-1.941-.768-1.346.347z" />'],
    grok: ["0 0 1024 1024", '<path d="M395.479 633.828L735.91 381.105C752.599 368.715 776.454 373.548 784.406 392.792C826.26 494.285 807.561 616.253 724.288 699.996C641.016 783.739 525.151 802.104 419.247 760.277L303.556 814.143C469.49 928.202 670.987 899.995 796.901 773.282C896.776 672.843 927.708 535.937 898.785 412.476L899.047 412.739C857.105 231.37 909.358 158.874 1016.4 10.6326C1018.93 7.11771 1021.47 3.60279 1024 0L883.144 141.651V141.212L395.392 633.916"/> <path d="M325.226 695.251C206.128 580.84 226.662 403.776 328.285 301.668C403.431 226.097 526.549 195.254 634.026 240.596L749.454 186.994C728.657 171.88 702.007 155.623 671.424 144.2C533.19 86.9942 367.693 115.465 255.323 228.382C147.234 337.081 113.244 504.215 171.613 646.833C215.216 753.423 143.739 828.818 71.7385 904.916C46.2237 931.893 20.6216 958.87 0 987.429L325.139 695.339"/>'],
  };
  var BRAND_OF = { codex: "openai", sonnet: "claude", opus: "claude", haiku: "claude", fable: "claude", native: "claude", glm: "chatglm", grok: "grok" };

  function brandMark(model, col) {
    var g = BRAND[BRAND_OF[model]];
    if (g) return '<svg class="ffrc-mark" viewBox="' + g[0] + '" style="color:' + col + '" aria-hidden="true">' + g[1] + '</svg>';
    var letter = ((model || "?").charAt(0) || "?").toUpperCase();
    return '<span class="ffrc-mark ffrc-mark-letter" style="background:' + col + '">' + letter + '</span>';
  }

  var ICO = {
    folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    cpu: '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3"/>'
  };
  function ico(name) {
    return '<svg class="ffrc-i" viewBox="0 0 24 24" aria-hidden="true">' + (ICO[name] || "") + '</svg>';
  }

  function stateTag(state, idle) {
    if (state === "running") return '<span class="ffrc-tag ffrc-tag-run">running</span>';
    if (state === "stalled") return '<span class="ffrc-tag ffrc-tag-stall">stalled ' + fmt(idle) + '</span>';
    if (state === "failed") return '<span class="ffrc-tag ffrc-tag-fail">failed</span>';
    if (state === "done") return '<span class="ffrc-tag">done</span>';
    return "";
  }

  /* Orchestrator badge. Unrecorded stays dashed and says so — nothing in a
     Claude Code session's environment exposes its own model to child
     processes, so a confident-looking wrong answer here would be pure
     invention (mirrors ff-dashboard.html's original orchBadge doctrine). */
  function orchBadge(name) {
    if (!name) {
      return '<div class="ffrc-orch ffrc-orch-unknown" title="Nothing in a Claude Code session&#39;s environment exposes its own model, so this has to be supplied at spawn time: set FLEETFLOW_ORCHESTRATOR, or pass ff-spawn --orchestrator. Runs predating that stay unrecorded rather than guessed.">'
        + ico("cpu") + '<b>orchestrator unrecorded</b><span>who drove this fleet</span></div>';
    }
    var col = modelOf(name)[1];
    return '<div class="ffrc-orch" style="border-color:' + col + '">' + brandMark(name, col)
      + '<b style="color:' + col + '">' + esc(name) + '</b><span>orchestrating</span></div>';
  }

  function brandLegend(models) {
    if (!models || models.length < 2) return "";
    var out = "";
    for (var i = 0; i < models.length; i++) {
      var b = models[i], c = modelOf(b)[1];
      out += '<span style="color:' + c + '">' + brandMark(b, c) + '<span class="ffrc-legend-name">' + esc(b) + '</span></span>';
    }
    return '<div class="ffrc-legend">' + out + '</div>';
  }

  function columnChart(items, label, showX) {
    if (!items.length) return "";
    var max = 1, i, item;
    for (i = 0; i < items.length; i++) if (items[i].value > max) max = items[i].value;
    var peak = items[0];
    for (i = 0; i < items.length; i++) if (items[i].value > peak.value) peak = items[i];
    var bars = "";
    for (i = 0; i < items.length; i++) {
      item = items[i];
      var h = item.value > 0 ? Math.max(3, Math.round(item.value / max * 72)) : 2;
      bars += '<div class="ffrc-bar ' + (item.state || "") + '" style="height:' + h + 'px;background:' + item.color + ';'
        + (item.value ? "" : "opacity:.25;") + '" title="' + esc(item.name) + ' — ' + tok(item.value) + ' tokens · ' + esc(item.state || "") + '"></div>';
    }
    var xs = "";
    if (showX && items.length <= 26) {
      var spans = "";
      for (i = 0; i < items.length; i++) spans += '<span title="' + esc(items[i].name) + '">' + esc(items[i].name) + '</span>';
      xs = '<div class="ffrc-chart-x">' + spans + '</div>';
    }
    return '<div class="ffrc-chart"><div class="ffrc-chart-h"><span>' + esc(label) + '</span>'
      + '<span class="ffrc-chart-pk">peak ' + esc(peak.name) + ' · ' + tok(peak.value) + '</span></div>'
      + '<div class="ffrc-cols-chart">' + bars + '</div>' + xs + '</div>';
  }

  ffRunCard = function (runDoc, opts) {
    var surface = (opts && opts.surface) || "dashboard";
    var s = (runDoc && runDoc.summary) || {};
    var lanes = (runDoc && runDoc.lanes) || [];
    var waves = (runDoc && runDoc.waves) || [];
    var counts = s.counts || {};
    var running = counts.running || 0, stalled = counts.stalled || 0, failed = counts.failed || 0;
    var models = s.models || [], modelIds = s.model_ids || [];
    var i;

    var chartItems = [];
    for (i = 0; i < lanes.length; i++) {
      var l = lanes[i];
      chartItems.push({ name: l.id, value: l.tokens_total || 0, color: modelOf(l.model)[1], state: l.state });
    }
    var chart = columnChart(chartItems, "tokens per lane", true) + brandLegend(models);

    var pips = "";
    for (i = 0; i < lanes.length; i++) {
      pips += '<div class="ffrc-sq ' + esc(lanes[i].state) + '" title="' + esc(lanes[i].id) + ' — ' + esc(lanes[i].state) + '"></div>';
    }

    var chips = "";
    for (i = 0; i < models.length; i++) {
      var b = models[i], col = modelOf(b)[1];
      chips += '<span class="ffrc-tag ffrc-brand-tag" style="border-color:' + col + ';color:' + col + '">'
        + brandMark(b, col) + esc(b) + '</span>';
    }

    var laneRanLine = modelIds.length
      ? '<div class="ffrc-path ffrc-mono">' + ico("cpu") + 'lanes ran ' + esc(modelIds.join(", ")) + '</div>'
      : "";

    var costCell = runDoc.cost
      ? '<div class="ffrc-stat" title="' + esc(runDoc.cost.title || "") + '"><b>' + esc(runDoc.cost.display || "—") + '</b><span>cost</span></div>'
      : "";

    return '<div class="ffrc" data-surface="' + esc(surface) + '">'
      + orchBadge(runDoc.orchestrator)
      + '<div class="ffrc-rhead-r"><h2 class="ffrc-mono">' + esc(runDoc.run) + '</h2>'
      + (waves.length ? '<span class="ffrc-tag">wave</span>' : "")
      + stateTag(s.state, s.idle_s)
      + chips + '</div>'
      + '<div class="ffrc-path ffrc-mono">' + ico("folder") + esc(runDoc.repo) + '</div>'
      + laneRanLine
      + '<div class="ffrc-sq-row" style="margin-top:9px">' + pips + '</div>'
      + chart
      + '<div class="ffrc-stats ffrc-mono">'
      + '<div class="ffrc-stat"><b>' + (s.lane_count || 0) + '</b><span>lanes</span></div>'
      + '<div class="ffrc-stat"><b>' + fmt(s.elapsed_s) + '</b><span>elapsed</span></div>'
      + '<div class="ffrc-stat"><b>' + tok(s.tokens_total) + '</b><span>tokens</span></div>'
      + '<div class="ffrc-stat"><b>' + tok(s.tokens_out) + '</b><span>output</span></div>'
      + costCell
      + (running ? '<div class="ffrc-stat ffrc-stat-ok"><b>' + running + '</b><span>running</span></div>' : "")
      + (stalled ? '<div class="ffrc-stat ffrc-stat-warn"><b>' + stalled + '</b><span>stalled</span></div>' : "")
      + (failed ? '<div class="ffrc-stat ffrc-stat-bad"><b>' + failed + '</b><span>failed</span></div>' : "")
      + '</div></div>';
  };

  /* Scoped under .ffrc only. Custom-property fallbacks below ARE the
     dashboard's current light/dark palette (ff-dashboard.html :root), so the
     card renders correctly even with zero host mapping; a host (dashboard or
     chat) additionally maps --ffc-* to its own real tokens for exact parity
     via a `.ffrc[data-surface="…"]` rule OUTSIDE this module. */
  FF_RUNCARD_CSS = "" +
    ".ffrc{--ffc-surface:#fff;--ffc-surface-1:#f2f1ed;--ffc-border:#e4e2dd;" +
    "--ffc-text-primary:#1a1a17;--ffc-text-secondary:#5c5a54;--ffc-text-muted:#8a887f;" +
    "--ffc-run:#378add;--ffc-run-rgb:55,138,221;--ffc-ok:#1d9e75;--ffc-bad:#e24b4a;--ffc-warn:#c8871b;--ffc-idle:#d3d1c7;" +
    "--ffc-bg-success:#e2f4ec;--ffc-text-success:#0f6e56;--ffc-bg-bad:#fbe6e5;--ffc-bg-warn:#fbf0dc;" +
    "--ffc-on-solid:#fff;--ffc-r-lg:12px;--ffc-r-md:6px;--ffc-r-sm:4px;--ffc-r-pill:20px;" +
    "--ffc-font-mono:ui-monospace,\"Cascadia Code\",Consolas,monospace;}" +
    "@media (prefers-color-scheme:dark){.ffrc{--ffc-surface:#262624;--ffc-surface-1:#222220;--ffc-border:#3a3936;" +
    "--ffc-text-primary:#ececea;--ffc-text-secondary:#b6b4ac;--ffc-text-muted:#8f8d85;" +
    "--ffc-run:#5aa0e6;--ffc-run-rgb:90,160,230;--ffc-ok:#35b98d;--ffc-bad:#f0706e;--ffc-warn:#e0a233;--ffc-idle:#444441;" +
    "--ffc-bg-success:#183a30;--ffc-text-success:#5fc9a4;--ffc-bg-bad:#3d2020;--ffc-bg-warn:#3a2f1a;--ffc-on-solid:#17170f;}}" +
    ".ffrc-mono{font-family:var(--ffc-font-mono);}" +
    ".ffrc-i{width:14px;height:14px;stroke:currentColor;fill:none;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;flex:none;vertical-align:middle;}" +
    ".ffrc-orch{display:inline-flex;align-items:center;gap:7px;margin-bottom:9px;padding:3px 10px 3px 7px;" +
    "border:1px solid var(--ffc-border);border-radius:var(--ffc-r-pill);background:var(--ffc-surface-1);font-size:12px;}" +
    ".ffrc-orch .ffrc-mark{width:16px;height:16px;}" +
    ".ffrc-orch b{font-weight:600;letter-spacing:-.01em;color:var(--ffc-text-primary);}" +
    ".ffrc-orch span{color:var(--ffc-text-muted);font-size:11px;}" +
    ".ffrc-orch-unknown{border-style:dashed;}" +
    ".ffrc-rhead-r{display:flex;align-items:center;gap:9px;flex-wrap:wrap;}" +
    ".ffrc-rhead-r h2{font-size:19px;font-weight:600;letter-spacing:-.02em;color:var(--ffc-text-primary);margin:0;}" +
    ".ffrc-path{color:var(--ffc-text-muted);font-size:11px;word-break:break-all;display:flex;align-items:center;gap:5px;margin-top:5px;}" +
    ".ffrc-chart{margin:13px 0 3px;}" +
    ".ffrc-chart-h{display:flex;align-items:baseline;gap:8px;font-size:10px;color:var(--ffc-text-muted);" +
    "text-transform:uppercase;letter-spacing:.07em;margin-bottom:5px;}" +
    ".ffrc-chart-pk{margin-left:auto;text-transform:none;letter-spacing:0;font-family:var(--ffc-font-mono);}" +
    ".ffrc-cols-chart{display:flex;align-items:flex-end;gap:3px;height:74px;border-bottom:1px solid var(--ffc-border);padding-bottom:1px;}" +
    ".ffrc-bar{flex:1;min-width:3px;border-radius:2px 2px 0 0;min-height:2px;position:relative;cursor:default;transition:filter .1s;}" +
    ".ffrc-bar:hover{filter:brightness(1.25);}" +
    ".ffrc-bar.failed{outline:1.5px solid var(--ffc-bad);outline-offset:-1.5px;}" +
    ".ffrc-bar.stalled{outline:1.5px solid var(--ffc-warn);outline-offset:-1.5px;}" +
    ".ffrc-bar.running{animation:ffrcPulse 1.4s ease-in-out infinite;}" +
    ".ffrc-chart-x{display:flex;gap:3px;margin-top:4px;font-size:9px;color:var(--ffc-text-muted);font-family:var(--ffc-font-mono);}" +
    ".ffrc-chart-x span{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;text-align:center;}" +
    ".ffrc-stats{display:flex;gap:18px;flex-wrap:wrap;margin-top:12px;}" +
    ".ffrc-stat b{display:block;font-size:19px;font-weight:600;letter-spacing:-.02em;color:var(--ffc-text-primary);}" +
    ".ffrc-stat span{font-size:10px;color:var(--ffc-text-muted);text-transform:uppercase;letter-spacing:.06em;}" +
    ".ffrc-stat-warn b{color:var(--ffc-warn);}.ffrc-stat-bad b{color:var(--ffc-bad);}.ffrc-stat-ok b{color:var(--ffc-ok);}" +
    ".ffrc-legend{display:flex;gap:11px;flex-wrap:wrap;margin-top:10px;font-size:11px;color:var(--ffc-text-muted);align-items:center;}" +
    ".ffrc-legend span{display:inline-flex;align-items:center;gap:5px;}" +
    ".ffrc-legend-name{color:var(--ffc-text-secondary);}" +
    ".ffrc-mark{width:15px;height:15px;flex:none;fill:currentColor;}" +
    ".ffrc-mark-letter{width:15px;height:15px;border-radius:var(--ffc-r-sm);display:inline-flex;align-items:center;justify-content:center;" +
    "color:#fff;font-size:9px;font-weight:700;font-family:var(--ffc-font-mono);}" +
    ".ffrc-tag{font-size:10px;border-radius:var(--ffc-r-sm);padding:0 5px;border:1px solid var(--ffc-border);" +
    "color:var(--ffc-text-muted);flex:none;display:inline-flex;align-items:center;}" +
    ".ffrc-brand-tag{gap:4px;padding:1px 6px;}" +
    ".ffrc-tag-run{background:var(--ffc-bg-success);color:var(--ffc-text-success);border:0;font-weight:600;}" +
    ".ffrc-tag-stall{background:var(--ffc-bg-warn);color:var(--ffc-warn);border:0;font-weight:600;}" +
    ".ffrc-tag-fail{background:var(--ffc-bg-bad);color:var(--ffc-bad);border:0;font-weight:600;}" +
    ".ffrc-sq-row{display:flex;gap:3px;flex-wrap:wrap;}" +
    ".ffrc-sq{width:8px;height:8px;border-radius:1.5px;background:var(--ffc-idle);flex:none;display:inline-block;}" +
    ".ffrc-sq.running{background:var(--ffc-run);animation:ffrcPulse 1.1s ease-in-out infinite;}" +
    ".ffrc-sq.done{background:var(--ffc-ok);}.ffrc-sq.failed{background:var(--ffc-bad);}" +
    ".ffrc-sq.stalled{background:var(--ffc-warn);}" +
    "@keyframes ffrcPulse{50%{opacity:.3}}";
})();
